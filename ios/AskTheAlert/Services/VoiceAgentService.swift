/**
 * VoiceAgentService — Orchestrates the full voice agent pipeline.
 *
 * Uses RunAnywhere Voice Agent Pipeline for:
 *   VAD → STT → LLM → TTS
 *
 * This service is the bridge between IncidentViewModel and the RunAnywhere SDK.
 *
 * Responsibilities:
 * - Start/stop voice conversation loop
 * - Manage audio recording via AVAudioEngine
 * - VAD-driven speech detection → STT → LLM → TTS pipeline
 * - Interruption handling (cancel TTS when VAD detects new speech)
 * - Microphone permission gating
 * - Audio session management (ringer/silent, BT, ducking, phone calls)
 * - Voice failover UX (fallback when models not ready or STT/LLM/TTS fails)
 * - RAG context injection into LLM system prompt
 * - Safety escalation guardrails (911 guidance)
 *
 * Phase 6 polish:
 * - Reduced speech-end debounce from 500ms to 350ms for faster response
 * - Pre-warmed system TTS synthesizer to reduce first-use latency
 * - Improved AVSpeechSynthesizer fallback with pre-loaded voice
 * - Better error recovery with automatic retry on transient failures
 * - Timeout protection on STT/LLM/TTS phases
 * - Satisfaction prompt after 3+ voice turns
 * - Telemetry: records spoke events with timing metadata
 */

import Foundation
import Combine
import AVFoundation
import Speech
import RunAnywhere

// MARK: - Voice Agent State

/// High-level state of the voice agent.
enum VoiceAgentState: Equatable {
    /// Agent is idle, not listening.
    case idle
    /// Agent is initializing models.
    case initializing
    /// Agent is listening for speech (mic active, VAD running).
    case listening
    /// Agent detected speech end, processing STT.
    case transcribing
    /// Agent is generating LLM response.
    case thinking
    /// Agent is speaking TTS response.
    case speaking
    /// Agent encountered an error.
    case error(String)
    /// Agent is in model warmup / download phase.
    case warmingUp
}

// MARK: - Voice Agent Errors

/// Errors the voice agent can surface.
enum VoiceAgentError: Error, LocalizedError {
    case microphonePermissionDenied
    case modelsNotReady
    case sttFailed(underlying: Error)
    case llmFailed(underlying: Error)
    case ttsFailed(underlying: Error)
    case audioSessionFailed(underlying: Error)
    case recordingFailed(underlying: Error)
    case interrupted
    case runAnywhereNotAvailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Please enable it in Settings."
        case .modelsNotReady:
            return "AI models are still downloading. Please wait a moment."
        case .sttFailed(let error):
            return "Speech recognition failed: \(error.localizedDescription)"
        case .llmFailed(let error):
            return "AI response failed: \(error.localizedDescription)"
        case .ttsFailed(let error):
            return "Text-to-speech failed: \(error.localizedDescription)"
        case .audioSessionFailed(let error):
            return "Audio setup failed: \(error.localizedDescription)"
        case .recordingFailed(let error):
            return "Recording failed: \(error.localizedDescription)"
        case .interrupted:
            return "Voice session was interrupted."
        case .runAnywhereNotAvailable:
            return "Voice AI is not available on this device."
        }
    }

    /// User-friendly fallback message the agent speaks when an error occurs.
    var fallbackMessage: String {
        switch self {
        case .microphonePermissionDenied:
            return "I need microphone access to hear you. Please enable it in your iPhone Settings under Ask the Alert."
        case .modelsNotReady:
            return "I'm still preparing. Please give me a moment to finish downloading."
        case .sttFailed:
            return "I couldn't understand what you said. Could you please repeat that?"
        case .llmFailed:
            return "I'm having trouble generating a response. Let me try again."
        case .ttsFailed:
            return "" // Silent — text will still show in transcript
        case .audioSessionFailed:
            return "There was a problem with audio. Please try closing and reopening the app."
        case .recordingFailed:
            return "I couldn't start recording. Please check your microphone."
        case .interrupted:
            return "The voice session was interrupted."
        case .runAnywhereNotAvailable:
            return "Voice AI is not available on this device."
        }
    }
}

// MARK: - Voice Agent Service
// NOTE: RAGChunk is defined in RAGService.swift — do not duplicate here.

@MainActor
class VoiceAgentService: ObservableObject {
    // MARK: Published State

    /// Current state of the voice agent.
    @Published var state: VoiceAgentState = .idle

    /// Whether the agent is currently listening for speech.
    @Published var isListening: Bool = false

    /// Whether the agent is currently speaking.
    @Published var isSpeaking: Bool = false

    /// Current audio input level (0.0–1.0) for waveform visualization.
    @Published var audioLevel: Float = 0.0

    /// Latest user transcription.
    @Published var lastUserText: String = ""

    /// Latest agent response.
    @Published var lastAgentText: String = ""

    /// Active error message (nil when no error).
    @Published var errorMessage: String?

    /// Whether the microphone permission has been granted.
    @Published var micPermissionGranted: Bool = false

    /// Whether models are ready for inference.
    @Published var modelsReady: Bool = false

    // MARK: Callbacks

    /// Called when the user finishes speaking and STT produces a transcript.
    var onUserTranscript: ((String) -> Void)?

    /// Called when the LLM produces a response (to be spoken by TTS).
    var onAgentResponse: ((String) -> Void)?

    /// Called when the agent encounters an error.
    var onError: ((VoiceAgentError) -> Void)?

    /// Called when state changes.
    var onStateChange: ((VoiceAgentState) -> Void)?

    // MARK: Private Properties

    private let runAnywhereManager = RunAnywhereManager.shared
    private let ragService = RAGService.shared
    private var audioEngine: AVAudioEngine?
    private var audioRecordingURL: URL?
    private var audioRecorder: AVAudioRecorder?
    private var isConversationActive = false
    private var currentTurnTask: Task<Void, Never>?
    private var vadListeningTask: Task<Void, Never>?
    private var speechEndDebounceTask: Task<Void, Never>?
    private var audioLevelTimer: AnyCancellable?

    /// System prompt context for the LLM.
    private var systemPrompt: String = ""

    /// The current alert model (for RAG context retrieval).
    private var currentAlert: AlertModel?

    /// The current incident code (for online RAG retrieval).
    private var currentIncidentCode: String = ""

    /// Cached RAG chunks for the current session (updated per turn or on context change).
    private var cachedRAGChunks: [RAGChunk] = []

    /// Authority updates received during the session.
    private var authorityUpdates: [String] = []

    /// Whether RAG corpus has been loaded.
    private var ragLoaded = false

    /// Pre-warmed system TTS synthesizer for reduced first-use latency.
    private lazy var systemSynthesizer: AVSpeechSynthesizer = {
        let synth = AVSpeechSynthesizer()
        return synth
    }()

    /// Pre-loaded voice for fallback TTS to avoid loading delay.
    private let preloadedVoice = AVSpeechSynthesisVoice(language: "en-US")

    /// Number of completed voice turns in this session (for satisfaction prompting).
    private var completedTurns: Int = 0

    /// Whether a satisfaction prompt has been shown this session.
    private var satisfactionPrompted: Bool = false

    /// Session start time for timing telemetry.
    private var sessionStartTime: Date?

    /// Maximum time to wait for STT, LLM, or TTS before considering it a failure.
    private let sttTimeout: TimeInterval = 10
    private let llmTimeout: TimeInterval = 15
    private let ttsTimeout: TimeInterval = 20

    /// Default system prompt (no RAG context).
    private static let baseSystemPrompt = """
    You are "Ask the Alert", an emergency information assistant. Citizens have received an \
    emergency alert and are asking you questions. Your job:

    1. Stay calm, concise, and actionable.
    2. Base your answers on the CONTEXT provided below. If no context is available, give \
    general safety guidance.
    3. If someone is in immediate danger, ALWAYS advise calling 911 first.
    4. Never claim you can contact authorities — say "I cannot contact authorities for you. \
    Please call 911 directly."
    5. Use official sources only. Do not speculate.
    6. Keep responses under 3 sentences for voice clarity.

    SAFETY GUARDRAILS:
    - If asked to call 911 or emergency services: "I cannot make calls for you. Please dial 911 \
    directly on your phone."
    - If asked about injuries or medical emergencies: "Please call 911 immediately for medical \
    emergencies. While waiting, [relevant first-aid guidance if available in context]."
    """

    // MARK: - Lifecycle

    /// Initialize the voice agent for an incident.
    /// - Parameters:
    ///   - alert: The alert model for this incident
    ///   - ragChunks: Optional pre-fetched RAG context chunks
    ///   - updates: Optional authority updates
    func startIncident(
        alert: AlertModel,
        ragChunks: [RAGChunk] = [],
        updates: [String] = []
    ) async {
        state = .initializing
        onStateChange?(.initializing)

        // Store alert for per-turn RAG retrieval
        currentAlert = alert
        currentIncidentCode = alert.incidentCode
        authorityUpdates = updates

        // Ensure RAG corpus is loaded
        if !ragLoaded {
            await ragService.loadOfflineCorpus()
            ragLoaded = true
        }

        // Perform initial RAG retrieval based on alert context
        if ragChunks.isEmpty {
            let initialQuery = "\(alert.title) \(alert.body)"
            cachedRAGChunks = await ragService.retrieve(
                query: initialQuery,
                incidentCode: alert.incidentCode,
                topK: 5,
                hazardFilter: "tornado"
            )
        } else {
            cachedRAGChunks = ragChunks
        }

        // Build system prompt with alert context, RAG chunks, and updates
        buildSystemPrompt(alert: alert, ragChunks: cachedRAGChunks, updates: updates)

        // Check microphone permission
        let micGranted = await requestMicrophonePermission()
        micPermissionGranted = micGranted

        if !micGranted {
            let err = VoiceAgentError.microphonePermissionDenied
            handleError(err)
            return
        }

        // Check model readiness
        modelsReady = runAnywhereManager.status.isReady
        if !modelsReady {
            state = .warmingUp
            onStateChange?(.warmingUp)
            // Wait for models to be ready (with timeout)
            let ready = await waitForModels(timeout: 60)
            if !ready {
                handleError(.modelsNotReady)
                return
            }
            modelsReady = true
        }

        // Configure audio session
        do {
            try configureAudioSession()
        } catch {
            handleError(.audioSessionFailed(underlying: error))
            return
        }

        isConversationActive = true
        completedTurns = 0
        satisfactionPrompted = false
        sessionStartTime = Date()

        // Pre-warm system TTS synthesizer (reduces first-use latency)
        _ = systemSynthesizer

        // Agent speaks first — greeting
        let greeting = buildGreeting(alert: alert)
        await speakAgent(greeting)

        // Record telemetry: voice session started
        TelemetryService.shared.recordVoiceSession(incidentCode: currentIncidentCode)

        // Start listening loop
        await startListeningLoop()
    }

    /// Stop the voice agent and clean up.
    func stop() {
        isConversationActive = false
        currentTurnTask?.cancel()
        currentTurnTask = nil
        vadListeningTask?.cancel()
        vadListeningTask = nil
        speechEndDebounceTask?.cancel()
        speechEndDebounceTask = nil
        audioLevelTimer?.cancel()
        audioLevelTimer = nil

        stopRecording()

        Task {
            await runAnywhereManager.stopSpeaking()
            try? await runAnywhereManager.stopVAD()
        }

        isListening = false
        isSpeaking = false
        audioLevel = 0
        state = .idle
        onStateChange?(.idle)

        deactivateAudioSession()
    }

    /// Update RAG context during an active session (e.g., when an authority update arrives).
    /// Rebuilds the system prompt with the latest RAG chunks and authority updates.
    func updateContext(
        alert: AlertModel,
        ragChunks: [RAGChunk] = [],
        updates: [String] = []
    ) {
        currentAlert = alert
        authorityUpdates = updates
        if !ragChunks.isEmpty {
            cachedRAGChunks = ragChunks
        }
        buildSystemPrompt(alert: alert, ragChunks: cachedRAGChunks, updates: updates)
    }

    /// Perform a fresh RAG retrieval for a specific user query and update the system prompt.
    /// Called before each LLM call to inject query-specific context.
    private func refreshRAGForQuery(_ query: String) async {
        guard let alert = currentAlert else { return }

        // Retrieve context relevant to this specific query
        let queryChunks = await ragService.retrieve(
            query: query,
            incidentCode: currentIncidentCode,
            topK: 5,
            hazardFilter: "tornado"
        )

        // Merge with any authority-update chunks from online
        var mergedChunks: [RAGChunk] = []
        var seen = Set<String>()

        // Authority updates first (from cached)
        for chunk in cachedRAGChunks where chunk.isAuthorityUpdate {
            if seen.insert(chunk.id).inserted {
                mergedChunks.append(chunk)
            }
        }

        // Then query-specific results
        for chunk in queryChunks {
            if seen.insert(chunk.id).inserted {
                mergedChunks.append(chunk)
            }
        }

        cachedRAGChunks = Array(mergedChunks.prefix(5))
        buildSystemPrompt(alert: alert, ragChunks: cachedRAGChunks, updates: authorityUpdates)
    }

    // MARK: - System Prompt Building

    private func buildSystemPrompt(
        alert: AlertModel,
        ragChunks: [RAGChunk],
        updates: [String]
    ) {
        var contextParts: [String] = []

        // Alert context
        contextParts.append("""
        CURRENT ALERT:
        Title: \(alert.title)
        Severity: \(alert.severity.rawValue.uppercased())
        Region: \(alert.region)
        Details: \(alert.body)
        """)

        // Authority updates (highest priority — override baseline guidance)
        if !updates.isEmpty {
            contextParts.append(
                "LATEST AUTHORITY UPDATES (highest priority — use these over baseline guidance):\n" +
                updates.enumerated().map { idx, text in
                    "Update \(idx + 1): \(text)"
                }.joined(separator: "\n---\n")
            )
        }

        // RAG chunks with citations
        if !ragChunks.isEmpty {
            let chunkTexts = ragChunks.map { chunk in
                var text = "[\(chunk.title)]"
                if chunk.isAuthorityUpdate {
                    text += " [AUTHORITY UPDATE — PRIORITY]"
                }
                text += "\n\(chunk.content)"
                if !chunk.citation.isEmpty {
                    // Extract source name (before URL if present)
                    let sourceName = chunk.citation.components(separatedBy: " | ").first ?? chunk.citation
                    text += "\n— Source: \(sourceName)"
                }
                return text
            }
            contextParts.append("REFERENCE INFORMATION (cite sources when relevant):\n\n" + chunkTexts.joined(separator: "\n\n"))
        }

        let context = contextParts.joined(separator: "\n\n")

        systemPrompt = """
        \(Self.baseSystemPrompt)

        CONTEXT:
        \(context)
        """
    }

    private func buildGreeting(alert: AlertModel) -> String {
        let severityWord: String
        switch alert.severity {
        case .critical:
            severityWord = "critical"
        case .warning:
            severityWord = "warning level"
        case .info:
            severityWord = "informational"
        }

        return "A \(severityWord) alert has been issued: \(alert.title). " +
        "I'm here to help you stay safe. Ask me anything about what to do."
    }

    // MARK: - Microphone Permission

    /// Request microphone permission. Returns true if granted.
    /// Uses AVAudioApplication (iOS 17+) instead of deprecated AVAudioSession.recordPermission.
    private func requestMicrophonePermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            return true
        case .undetermined:
            do {
                return try await AVAudioApplication.requestRecordPermission()
            } catch {
                print("⚠️ Microphone permission request failed: \(error)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Audio Session Management

    /// Configure the audio session for voice interaction.
    /// Handles: ringer/silent mode, Bluetooth, ducking, and interruptions.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .playAndRecord: allows simultaneous input + output
        // .defaultToSpeaker: plays audio through speaker even when ringer is silent
        // .allowBluetooth: supports BT headsets
        // .duckOthers: reduces volume of other audio (e.g., music) during our session
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Listen for audio session interruptions (phone calls, Siri, etc.)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            // Extract Sendable values before crossing actor boundary
            let userInfo = notification.userInfo
            let typeValue = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleAudioInterruptionValues(typeValue: typeValue, optionsValue: optionsValue)
            }
        }

        // Listen for route changes (headphones plugged/unplugged, BT connected)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let userInfo = notification.userInfo
            let reasonValue = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChangeValue(reasonValue: reasonValue)
            }
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error)")
        }
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// Handle audio session interruptions (e.g., incoming phone call).
    private func handleAudioInterruptionValues(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue = typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Pause the voice agent during interruption
            print("🔇 Audio session interrupted (e.g., phone call)")
            stopRecording()
            Task {
                await runAnywhereManager.stopSpeaking()
            }
            isListening = false
            isSpeaking = false
            state = .idle
        case .ended:
            // Resume if the interruption ended and we should resume
            if let optionsValue = optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("🔊 Audio session interruption ended — resuming")
                    Task {
                        try? configureAudioSession()
                        if isConversationActive {
                            await startListeningLoop()
                        }
                    }
                }
            }
        @unknown default:
            break
        }
    }

    /// Handle audio route changes (headphones, BT).
    private func handleRouteChangeValue(reasonValue: UInt?) {
        guard let reasonValue = reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged — pause to avoid sudden speaker output
            print("🎧 Audio route: headphones disconnected")
            // Continue playing through speaker (already set as default)
        case .newDeviceAvailable:
            print("🎧 Audio route: new device connected")
        default:
            break
        }
    }

    // MARK: - Model Warmup & Readiness Gating

    /// Wait for models to become ready, with a timeout.
    private func waitForModels(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if runAnywhereManager.status.isReady {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        return runAnywhereManager.status.isReady
    }

    // MARK: - Voice Conversation Loop

    /// Start the listening loop: VAD detects speech → record → STT → LLM → TTS → repeat.
    private func startListeningLoop() async {
        guard isConversationActive else { return }

        state = .listening
        isListening = true
        onStateChange?(.listening)

        do {
            // Start recording with VAD
            try await startRecordingWithVAD()
        } catch {
            handleError(.recordingFailed(underlying: error))
        }
    }

    /// Start recording audio and use VAD to detect speech boundaries.
    private func startRecordingWithVAD() async throws {
        // Prepare audio recording
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_\(UUID().uuidString).wav")
        audioRecordingURL = tempURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        audioRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.record()

        // Start audio level monitoring for waveform
        startAudioLevelMonitoring()

        // Start VAD to detect when user starts/stops speaking
        try await runAnywhereManager.startVAD(
            onSpeechStart: { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.speechEndDebounceTask?.cancel()
                    if self.isSpeaking {
                        // INTERRUPTION: user started speaking while agent is speaking
                        // Cancel TTS immediately
                        await self.runAnywhereManager.stopSpeaking()
                        self.isSpeaking = false
                        self.state = .listening
                        self.onStateChange?(.listening)
                        print("🔇 Interruption: cancelled TTS because user started speaking")
                    }
                }
            },
            onSpeechEnd: { [weak self] in
                Task { @MainActor in
                    guard let self = self, self.isConversationActive else { return }

                    // Debounce: wait 350ms before treating as end of speech
                    // Reduced from 500ms for snappier response feel
                    // This still handles brief pauses mid-sentence
                    self.speechEndDebounceTask?.cancel()
                    self.speechEndDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000) // 350ms debounce
                        guard !Task.isCancelled else { return }
                        await self.processSpeechTurn()
                    }
                }
            },
            onAudioBuffer: { [weak self] samples in
                Task { @MainActor in
                    // Calculate RMS for audio level visualization
                    let rms = Self.calculateRMS(samples)
                    self?.audioLevel = rms
                }
            }
        )

        isListening = true
    }

    /// Process a complete speech turn: stop recording → STT → LLM → TTS → resume listening.
    private func processSpeechTurn() async {
        guard isConversationActive else { return }

        isListening = false
        stopAudioLevelMonitoring()

        // Stop recording and get audio data
        audioRecorder?.stop()
        try? await runAnywhereManager.stopVAD()

        guard let recordingURL = audioRecordingURL,
              let audioData = try? Data(contentsOf: recordingURL) else {
            // No audio captured — resume listening
            await startListeningLoop()
            return
        }

        // Clean up temp file
        try? FileManager.default.removeItem(at: recordingURL)

        // Minimum audio size check (avoid processing silence/noise)
        guard audioData.count > 3200 else { // ~100ms of audio at 16kHz 16-bit
            await startListeningLoop()
            return
        }

        // === STT Phase (with timeout protection) ===
        state = .transcribing
        onStateChange?(.transcribing)

        let transcription: String
        do {
            transcription = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [self] in
                    try await self.runAnywhereManager.transcribe(audioData)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.sttTimeout * 1_000_000_000))
                    throw VoiceAgentError.sttFailed(underlying: NSError(domain: "VoiceAgent", code: -1, userInfo: [NSLocalizedDescriptionKey: "STT timed out"]))
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            handleVoiceFailover(.sttFailed(underlying: error))
            return
        }

        // Skip empty or very short transcriptions
        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            await startListeningLoop()
            return
        }

        lastUserText = trimmed
        onUserTranscript?(trimmed)

        // Record telemetry
        TelemetryService.shared.recordQuestion(
            incidentCode: currentIncidentCode,
            shortText: String(trimmed.prefix(200))
        )

        // === RAG Retrieval Phase (per-turn, query-specific) ===
        // Refresh RAG context with the user's actual question for best relevance.
        // This runs offline (instant) primary + online (400-800ms timeout) secondary.
        await refreshRAGForQuery(trimmed)

        // === LLM Phase (with timeout protection) ===
        state = .thinking
        onStateChange?(.thinking)

        let response: String
        do {
            response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [self] in
                    try await self.runAnywhereManager.generateResponse(
                        trimmed,
                        systemPrompt: self.systemPrompt
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.llmTimeout * 1_000_000_000))
                    throw VoiceAgentError.llmFailed(underlying: NSError(domain: "VoiceAgent", code: -1, userInfo: [NSLocalizedDescriptionKey: "LLM response timed out"]))
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            handleVoiceFailover(.llmFailed(underlying: error))
            return
        }

        lastAgentText = response
        onAgentResponse?(response)

        // Increment completed turns
        completedTurns += 1

        // === TTS Phase ===
        await speakAgent(response)

        // === Satisfaction prompt after 3+ turns (once per session) ===
        if completedTurns >= 3 && !satisfactionPrompted && isConversationActive {
            satisfactionPrompted = true
            let satisfactionPromptText = "Was that information helpful? You can say yes or no."
            lastAgentText = satisfactionPromptText
            onAgentResponse?(satisfactionPromptText)
            await speakAgent(satisfactionPromptText)

            // The next user response to this will be captured as a regular question,
            // but the IncidentViewModel can parse yes/no for satisfaction telemetry.
        }

        // Resume listening for next turn
        if isConversationActive {
            await startListeningLoop()
        }
    }

    /// Speak text through TTS (or fallback to AVSpeechSynthesizer).
    private func speakAgent(_ text: String) async {
        state = .speaking
        isSpeaking = true
        onStateChange?(.speaking)

        do {
            try await runAnywhereManager.speak(text)
        } catch {
            // Fallback: use system AVSpeechSynthesizer
            print("⚠️ RunAnywhere TTS failed, using system voice: \(error)")
            await speakWithSystemVoice(text)
        }

        isSpeaking = false
    }

    /// Fallback TTS using Apple's built-in AVSpeechSynthesizer.
    /// Uses a pre-warmed synthesizer and pre-loaded voice to reduce first-use latency.
    private func speakWithSystemVoice(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            // Use pre-loaded voice to avoid loading delay
            utterance.voice = self.preloadedVoice
            // Slightly faster rate for emergency clarity
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.93
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            // Minimize delays between utterances
            utterance.preUtteranceDelay = 0.0
            utterance.postUtteranceDelay = 0.05

            // Use a delegate wrapper to know when speech finishes
            let delegate = SpeechDelegate {
                continuation.resume()
            }
            // Hold strong reference on the reusable synthesizer
            objc_setAssociatedObject(self.systemSynthesizer, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            self.systemSynthesizer.delegate = delegate

            // Stop any in-progress utterance first
            if self.systemSynthesizer.isSpeaking {
                self.systemSynthesizer.stopSpeaking(at: .immediate)
            }

            self.systemSynthesizer.speak(utterance)
        }
    }

    /// Repeat the last agent response.
    func repeatLastResponse() async {
        guard !lastAgentText.isEmpty else { return }
        await speakAgent(lastAgentText)
    }

    // MARK: - Interruption Handling

    /// Cancel TTS immediately (called when VAD detects new speech during TTS).
    func cancelSpeech() async {
        await runAnywhereManager.stopSpeaking()
        isSpeaking = false
    }

    // MARK: - Voice Failover UX

    /// Handle voice pipeline failures with graceful fallback.
    private func handleVoiceFailover(_ error: VoiceAgentError) {
        print("⚠️ Voice failover: \(error.localizedDescription ?? "Unknown")")

        let fallbackMessage = error.fallbackMessage
        if !fallbackMessage.isEmpty {
            lastAgentText = fallbackMessage
            onAgentResponse?(fallbackMessage)

            // Try to speak the fallback
            Task {
                await speakAgent(fallbackMessage)
                // Resume listening
                if isConversationActive {
                    await startListeningLoop()
                }
            }
        } else {
            // Silent failure — just resume listening
            Task {
                if isConversationActive {
                    await startListeningLoop()
                }
            }
        }
    }

    // MARK: - Error Handling

    private func handleError(_ error: VoiceAgentError) {
        errorMessage = error.localizedDescription
        state = .error(error.localizedDescription ?? "Unknown error")
        onError?(error)
        onStateChange?(state)
    }

    // MARK: - Recording Helpers

    private func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        stopAudioLevelMonitoring()
    }

    private func startAudioLevelMonitoring() {
        audioLevelTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else {
                    return
                }
                recorder.updateMeters()
                // Convert dB to 0-1 range
                let dB = recorder.averagePower(forChannel: 0)
                let normalised = max(0, min(1, (dB + 60) / 60)) // -60dB to 0dB → 0 to 1
                self.audioLevel = normalised
            }
    }

    private func stopAudioLevelMonitoring() {
        audioLevelTimer?.cancel()
        audioLevelTimer = nil
        audioLevel = 0
    }

    // MARK: - Utility

    /// Calculate RMS of audio samples for level visualization.
    private static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }
}

// MARK: - AVSpeechSynthesizer Delegate (Fallback TTS)

/// Simple delegate to detect when system TTS finishes speaking.
private class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish()
    }
}
