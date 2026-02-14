/**
 * IncidentViewModel — Drives the IncidentView.
 *
 * Coordinates:
 * - Voice agent lifecycle (start/stop listening via RunAnywhere)
 * - Audio level for waveform visualization
 * - Transcript entries from VAD → STT → LLM → TTS pipeline
 * - Telemetry event recording
 * - Update handling (new updates spoken by agent, interrupt vs queue)
 * - Model warmup and "offline ready" gating
 * - Safety escalation UX (Call 911 button, guardrails)
 * - Notification permission flow
 * - Foreground/background push + multiple incidents
 */

import SwiftUI
import Combine

// MARK: - Incident Phase

/// The phase of the incident interaction.
enum IncidentPhase: Equatable {
    /// Models are being downloaded/loaded.
    case preparingModels
    /// Models ready, voice agent starting.
    case starting
    /// Active voice conversation.
    case active
    /// Session ended by user.
    case ended
}

@MainActor
class IncidentViewModel: ObservableObject {
    // MARK: - Published State

    /// Current voice agent state.
    @Published var voiceState: VoiceAgentState = .idle

    /// Current incident phase.
    @Published var phase: IncidentPhase = .preparingModels

    /// Whether the agent is currently listening.
    @Published var isListening: Bool = false

    /// Whether the agent is currently speaking.
    @Published var isSpeaking: Bool = false

    /// Current audio level for waveform (0.0–1.0).
    @Published var audioLevel: Float = 0.0

    /// Transcript entries (user + agent messages).
    @Published var transcriptEntries: [TranscriptEntry] = []

    /// Alert title for display.
    @Published var alertTitle: String = "Loading…"

    /// Alert body for display.
    @Published var alertBody: String = ""

    /// Severity color for UI.
    @Published var severityColor: Color = .orange

    /// Model download progress (0.0–1.0).
    @Published var modelProgress: Float = 0.0

    /// Model readiness summary text.
    @Published var modelStatusText: String = "Preparing AI models…"

    /// Whether models are fully ready.
    @Published var modelsReady: Bool = false

    /// Whether mic permission is granted.
    @Published var micPermissionGranted: Bool = true

    /// Whether notification permission is granted.
    @Published var notificationPermissionGranted: Bool = true

    /// Active error message.
    @Published var errorMessage: String?

    /// Whether the "Call 911" confirmation sheet is showing.
    @Published var showCall911Sheet: Bool = false

    /// Pending authority updates queue.
    @Published var pendingUpdates: [String] = []

    /// Whether an update is being spoken.
    @Published var isSpeakingUpdate: Bool = false

    /// Latest RAG chunks for display or inspection.
    @Published var ragChunks: [RAGChunk] = []

    /// Whether RAG corpus is loaded and ready.
    @Published var ragReady: Bool = false

    /// Whether we're waiting for a satisfaction yes/no response.
    var awaitingSatisfactionResponse: Bool = false

    // MARK: - Private

    private var incidentCode: String = ""
    private var alertModel: AlertModel?
    private var voiceAgent: VoiceAgentService?
    private var cancellables = Set<AnyCancellable>()
    private let runAnywhereManager = RunAnywhereManager.shared
    private let ragService = RAGService.shared

    // MARK: - Lifecycle

    func onAppear(incidentCode: String, alert: AlertModel? = nil) {
        self.incidentCode = incidentCode

        // Record telemetry: incident opened
        TelemetryService.shared.recordEvent(
            incidentCode: incidentCode,
            eventType: .opened
        )

        // Set alert info
        if let alert = alert {
            self.alertModel = alert
            updateAlertDisplay(alert)
        } else {
            alertTitle = "Incident: \(incidentCode)"
            alertBody = "Connecting…"
            severityColor = .orange
        }

        // Check notification permission
        checkNotificationPermission()

        // Observe RunAnywhere manager state
        observeRunAnywhereState()

        // Listen for push updates during active incident
        listenForUpdates()

        // Load RAG corpus and start voice agent
        Task {
            await loadRAGCorpus()
            await startVoiceSession()
        }
    }

    // MARK: - RAG Loading

    /// Load the offline RAG corpus into memory.
    private func loadRAGCorpus() async {
        await ragService.loadOfflineCorpus()
        ragReady = await ragService.isReady
        let count = await ragService.chunkCount
        print("✅ RAG corpus ready: \(count) chunks loaded")
    }

    /// Perform RAG retrieval for the current alert context and return chunks.
    private func fetchInitialRAGContext(alert: AlertModel) async -> [RAGChunk] {
        let query = "\(alert.title) \(alert.body)"
        let chunks = await ragService.retrieve(
            query: query,
            incidentCode: alert.incidentCode,
            topK: 5,
            hazardFilter: "tornado"
        )
        return chunks
    }

    func onDisappear() {
        voiceAgent?.stop()
        voiceAgent = nil
        cancellables.removeAll()
        awaitingSatisfactionResponse = false

        // Flush telemetry immediately (before view is gone)
        Task {
            await TelemetryService.shared.flushNow()
        }
    }

    // MARK: - Voice Session

    private func startVoiceSession() async {
        phase = .preparingModels

        // Ensure SDK is initialized
        if !runAnywhereManager.status.isReady {
            await runAnywhereManager.initialize()
        }

        // Wait until models are ready
        while !runAnywhereManager.status.isReady {
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
            modelProgress = runAnywhereManager.downloadProgress
            modelStatusText = runAnywhereManager.statusMessage
        }

        modelsReady = true
        phase = .starting

        // Create and start voice agent
        let agent = VoiceAgentService()
        self.voiceAgent = agent

        // Set up callbacks
        agent.onUserTranscript = { [weak self] text in
            Task { @MainActor in
                guard let self = self else { return }
                self.addTranscript(role: .user, text: text)

                // Check if this is a satisfaction response (yes/no)
                let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if self.awaitingSatisfactionResponse {
                    self.awaitingSatisfactionResponse = false
                    let satisfied = lowered.contains("yes") || lowered.contains("yeah") ||
                                    lowered.contains("helpful") || lowered.contains("good") ||
                                    lowered.contains("great") || lowered.contains("thanks")
                    TelemetryService.shared.recordSatisfaction(
                        incidentCode: self.incidentCode,
                        satisfied: satisfied
                    )
                } else {
                    // Record telemetry as a question
                    TelemetryService.shared.recordQuestion(
                        incidentCode: self.incidentCode,
                        shortText: String(text.prefix(200))
                    )
                }
            }
        }

        agent.onAgentResponse = { [weak self] text in
            Task { @MainActor in
                self?.addTranscript(role: .agent, text: text)
                // Detect if this is the satisfaction prompt
                if text.contains("Was that information helpful") {
                    self?.awaitingSatisfactionResponse = true
                }
            }
        }

        agent.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(error)
            }
        }

        agent.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.voiceState = state
                switch state {
                case .listening:
                    self?.isListening = true
                    self?.isSpeaking = false
                case .speaking:
                    self?.isListening = false
                    self?.isSpeaking = true
                case .transcribing, .thinking:
                    self?.isListening = false
                    self?.isSpeaking = false
                default:
                    break
                }
            }
        }

        // Observe agent's published properties
        agent.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        agent.$isListening
            .receive(on: DispatchQueue.main)
            .assign(to: &$isListening)

        agent.$isSpeaking
            .receive(on: DispatchQueue.main)
            .assign(to: &$isSpeaking)

        agent.$micPermissionGranted
            .receive(on: DispatchQueue.main)
            .assign(to: &$micPermissionGranted)

        // Build alert for context
        let alert = self.alertModel ?? AlertModel(
            incidentCode: incidentCode,
            title: alertTitle,
            severity: .warning,
            body: alertBody,
            region: "Unknown",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Fetch initial RAG context for this alert
        let initialChunks = await fetchInitialRAGContext(alert: alert)
        self.ragChunks = initialChunks

        phase = .active

        // Start the incident with voice agent, passing RAG context
        await agent.startIncident(
            alert: alert,
            ragChunks: initialChunks,
            updates: pendingUpdates
        )
    }

    // MARK: - Voice Control

    /// Toggle listening state (manual mic button).
    func toggleListening() {
        guard let agent = voiceAgent else { return }

        if agent.isListening || agent.isSpeaking {
            agent.stop()
            isListening = false
            isSpeaking = false
            phase = .ended
        } else {
            // Restart listening with current RAG context
            Task {
                phase = .active
                let alert = self.alertModel ?? AlertModel(
                    incidentCode: incidentCode,
                    title: alertTitle,
                    severity: .warning,
                    body: alertBody,
                    region: "Unknown",
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )

                // Refresh RAG context for the restart
                let chunks = await fetchInitialRAGContext(alert: alert)
                self.ragChunks = chunks

                await agent.startIncident(
                    alert: alert,
                    ragChunks: chunks,
                    updates: pendingUpdates
                )
            }
        }
    }

    /// End the voice session.
    func endSession() {
        voiceAgent?.stop()
        isListening = false
        isSpeaking = false
        phase = .ended

        TelemetryService.shared.recordEvent(
            incidentCode: incidentCode,
            eventType: .spoke  // Session end event
        )
    }

    /// Repeat the last agent response.
    func repeatLastResponse() {
        Task {
            await voiceAgent?.repeatLastResponse()
        }
    }

    // MARK: - Update Handling

    /// Handle an incoming authority update during an active voice session.
    /// Behavior: interrupt current TTS, speak the update immediately, then resume.
    /// Also refreshes RAG context so subsequent queries incorporate the update.
    func handleIncomingUpdate(_ update: UpdateModel) {
        let updateText = update.updateText

        // Add to transcript
        addTranscript(role: .agent, text: "UPDATE: \(updateText)")

        // Update authority updates list and refresh RAG context
        pendingUpdates.append(updateText)
        if let alert = alertModel {
            // Refresh RAG with update context
            Task {
                let refreshedChunks = await ragService.retrieve(
                    query: updateText,
                    incidentCode: alert.incidentCode,
                    topK: 3,
                    hazardFilter: "tornado"
                )
                // Merge refreshed chunks into cached set
                var merged = self.ragChunks
                var seen = Set(merged.map(\.id))
                for chunk in refreshedChunks {
                    if seen.insert(chunk.id).inserted {
                        merged.append(chunk)
                    }
                }
                self.ragChunks = Array(merged.prefix(7)) // Allow slightly more with updates
            }

            voiceAgent?.updateContext(
                alert: alert,
                ragChunks: ragChunks,
                updates: pendingUpdates
            )
        }

        // Speak the update immediately (interrupting current speech if needed)
        Task {
            isSpeakingUpdate = true

            // Cancel any current speech
            await voiceAgent?.cancelSpeech()

            // Speak the update
            let spokenUpdate = "Authority update: \(updateText)"
            do {
                try await runAnywhereManager.speak(spokenUpdate)
            } catch {
                print("⚠️ Failed to speak update: \(error)")
            }

            isSpeakingUpdate = false
        }
    }

    // MARK: - Safety Escalation

    /// Initiate a 911 call (shows confirmation first).
    func call911() {
        showCall911Sheet = true
    }

    /// Actually place the 911 call after confirmation.
    func confirmCall911() {
        showCall911Sheet = false

        // Record telemetry
        TelemetryService.shared.recordEvent(
            incidentCode: incidentCode,
            eventType: .spoke,
            payload: TelemetryPayload(shortText: "911_call_initiated")
        )

        // Open phone dialer
        if let url = URL(string: "tel://911") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Notification Permission

    private func checkNotificationPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationPermissionGranted = settings.authorizationStatus == .authorized
        }
    }

    /// Request notification permission (if not yet granted).
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                self?.notificationPermissionGranted = granted
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                if let error = error {
                    print("⚠️ Notification permission error: \(error)")
                }
            }
        }
    }

    // MARK: - Push Notification Handling (Foreground/Background)

    private func listenForUpdates() {
        // Listen for push notifications while this incident is active
        NotificationCenter.default.publisher(for: .didReceivePushNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let userInfo = notification.userInfo,
                      let code = userInfo["incidentCode"] as? String,
                      let type = userInfo["type"] as? String else { return }

                if type == "update" && code == self.incidentCode {
                    // Update for current incident
                    let updateText = userInfo["updateText"] as? String ?? "New update available."
                    let update = UpdateModel(
                        incidentCode: code,
                        updateText: updateText,
                        timestamp: ISO8601DateFormatter().string(from: Date()),
                        source: .broadcast
                    )
                    self.handleIncomingUpdate(update)
                } else if type == "alert" && code != self.incidentCode {
                    // New alert for a different incident — handled by AppState (multi-incident)
                    // Show a banner within IncidentView
                    self.addTranscript(
                        role: .agent,
                        text: "A new alert has been issued for incident \(code). You can dismiss this view to see it."
                    )
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - RunAnywhere State Observation

    private func observeRunAnywhereState() {
        runAnywhereManager.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.modelsReady = status.isReady
                self?.modelStatusText = status.summary
            }
            .store(in: &cancellables)

        runAnywhereManager.$downloadProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$modelProgress)

        runAnywhereManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in
                if let msg = msg {
                    self?.errorMessage = msg
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Alert Display

    func updateAlertInfo(title: String, body: String, severity: AlertSeverity) {
        alertTitle = title
        alertBody = body
        severityColor = severityColorFor(severity)
    }

    private func updateAlertDisplay(_ alert: AlertModel) {
        alertTitle = alert.title
        alertBody = alert.body
        severityColor = severityColorFor(alert.severity)
    }

    private func severityColorFor(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: - Transcript

    private func addTranscript(role: TranscriptEntry.Role, text: String) {
        let entry = TranscriptEntry(role: role, text: text)
        transcriptEntries.append(entry)
    }

    // MARK: - Error Handling

    private func handleError(_ error: VoiceAgentError) {
        errorMessage = error.localizedDescription

        switch error {
        case .microphonePermissionDenied:
            micPermissionGranted = false
            addTranscript(role: .agent, text: error.fallbackMessage)
        case .modelsNotReady:
            phase = .preparingModels
            addTranscript(role: .agent, text: error.fallbackMessage)
        default:
            addTranscript(role: .agent, text: error.fallbackMessage)
        }
    }
}

// MARK: - Import for UNUserNotificationCenter
import UserNotifications
import UIKit
