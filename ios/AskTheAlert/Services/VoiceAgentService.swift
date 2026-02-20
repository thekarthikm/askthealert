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
    private var isConversationActive = false
    private var currentTurnTask: Task<Void, Never>?
    private var vadListeningTask: Task<Void, Never>?
    private var speechEndDebounceTask: Task<Void, Never>?

    // -- Audio capture (AVAudioEngine + AsyncStream, Swift 6 safe) --
    // Uses energy-based speech detection (RMS) instead of RunAnywhere VAD.
    // RunAnywhere VAD proved unreliable (detectSpeech always returned false).
    // RMS-based detection is simpler, proven, and used by many voice apps.

    /// AVAudioEngine for microphone capture. Created per listening session.
    private var audioEngine: AVAudioEngine?

    /// Continuation for the async audio stream.
    /// The tap callback yields samples here; the main-actor listening task consumes them.
    /// Using AsyncStream avoids capturing @MainActor self in the tap closure,
    /// which would crash in Swift 6 (dispatch_assert_queue_fail).
    private var audioStreamContinuation: AsyncStream<[Float]>.Continuation?

    /// Accumulated audio samples during active speech.
    /// Float32, 16 kHz, mono — ready for WAV conversion and STT.
    private var speechAudioBuffer: [Float] = []

    /// Whether we are currently accumulating audio (between speech-start and speech-end).
    private var isAccumulatingSpeech = false

    // -- Energy-based speech detection thresholds --
    /// RMS level above which we consider audio to be speech.
    /// iPhone mic at arm's length: silence ~0.001-0.005, speech ~0.03-0.15.
    private let speechStartThreshold: Float = 0.015
    /// Silence duration (seconds) after speech before we finalize the turn.
    private let silenceTimeoutSeconds: TimeInterval = 1.2

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
    
    /// Whether we're waiting for a yes/no satisfaction response (don't process as question).
    private var awaitingSatisfactionResponse: Bool = false

    /// Session start time for timing telemetry.
    private var sessionStartTime: Date?
    
    /// Local transcript file for debugging (using temp directory for reliability)
    private let transcriptFileURL: URL = {
        let temp = FileManager.default.temporaryDirectory
        return temp.appendingPathComponent("askthealert_transcript.txt")
    }()

    /// Maximum time to wait for STT, LLM, or TTS before considering it a failure.
    private let sttTimeout: TimeInterval = 10
    private let llmTimeout: TimeInterval = 15
    private let ttsTimeout: TimeInterval = 20

    /// Default system prompt (no RAG context).
    private static let baseSystemPrompt = """
    Answer tornado safety questions using ONLY the INFORMATION below. Keep answers short (2 sentences).
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
                topK: 7,
                hazardFilter: "tornado"
            )
        } else {
            cachedRAGChunks = ragChunks
        }

        // Build system prompt with alert context, RAG chunks, and updates
        buildSystemPrompt(alert: alert, ragChunks: cachedRAGChunks, updates: updates)
        
        // Clear transcript file for new session
        clearTranscript()
        print("📝 Transcript will be saved to: \(transcriptFileURL.path)")

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

        // Stop audio engine
        stopAudioEngine()

        // Clear audio accumulation
        speechAudioBuffer.removeAll()
        isAccumulatingSpeech = false

        Task {
            await runAnywhereManager.stopSpeaking()
        }

        isListening = false
        isSpeaking = false
        audioLevel = 0
        state = .idle
        onStateChange?(.idle)

        deactivateAudioSession()
    }

    /// Tear down the AVAudioEngine (remove tap, stop, nil out).
    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Finish the async stream so the listening task exits its `for await` loop
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
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

        // Preprocess query for better retrieval
        let preprocessedQuery = preprocessVoiceQuery(query)

        // Retrieve chunks (hybrid: offline + online)
        let ragChunks = await RAGService.shared.retrieve(
            query: preprocessedQuery,
            incidentCode: currentIncidentCode,
            topK: 7,
            hazardFilter: "tornado"
        )

        // Try offline-only if hybrid returned nothing
        let finalChunks = ragChunks.isEmpty
            ? await RAGService.shared.retrieveOffline(query: preprocessedQuery, topK: 7, hazardFilter: "tornado")
            : ragChunks

        // CRITICAL: If new retrieval failed completely, clear cache to trigger fallback
        // Don't merge stale cached chunks when current query gets nothing - this prevents fallback
        if finalChunks.isEmpty {
            cachedRAGChunks = []
        } else {
            // Merge with cached chunks only if we got new results, dedupe by ID
            var mergedChunks = finalChunks
            let newChunkIDs = Set(finalChunks.map { $0.id })
            let oldChunksNotInNew = cachedRAGChunks.filter { !newChunkIDs.contains($0.id) }
            mergedChunks.append(contentsOf: oldChunksNotInNew)
            cachedRAGChunks = Array(mergedChunks.prefix(7))
        }
        
        // Log RAG retrieval success/failure for debugging
        if cachedRAGChunks.isEmpty {
            print("⚠️ RAG RETRIEVAL FAILED: No chunks retrieved for query '\(query)'")
            print("   This indicates either:")
            print("   - Query too dissimilar to corpus (BM25 score too low)")
            print("   - Offline corpus not loaded")
            print("   - Online retrieval timed out and offline also failed")
        } else {
            print("🔍 RAG retrieved \(cachedRAGChunks.count) chunks for query: '\(query)'")
            for chunk in cachedRAGChunks.prefix(2) {
                print("   - \(chunk.title) (score: \(String(format: "%.2f", chunk.similarity)))")
            }
        }
        
        buildSystemPrompt(alert: alert, ragChunks: cachedRAGChunks, updates: authorityUpdates)
    }

    // MARK: - System Prompt Building

    private func buildSystemPrompt(
        alert: AlertModel,
        ragChunks: [RAGChunk],
        updates: [String]
    ) {
        // Build prompt for Qwen2.5 0.5B model: MINIMAL formatting, RAG first for priority
        var promptParts: [String] = [Self.baseSystemPrompt]
        
        // RAG chunks - put FIRST after base prompt (high priority for small model)
        if !ragChunks.isEmpty {
            let chunkTexts = ragChunks.prefix(3).map { chunk in
                // Just raw content, no labels
                chunk.content
            }
            promptParts.append("INFORMATION:\n" + chunkTexts.joined(separator: "\n\n"))
        } else {
            // Fallback: provide minimal essential tornado safety info when RAG fails
            promptParts.append("""
INFORMATION:
Go to your basement immediately. If no basement, go to the lowest floor interior room away from windows. Get under sturdy furniture. Protect your head and neck. In a high-rise, take stairs to lowest floor, use interior hallway. Stay away from windows and exterior walls.
""")
        }
        
        // Alert context (brief)
        promptParts.append("CURRENT SITUATION: \(alert.title)")
        
        // Authority updates (if any, keep brief)
        if !updates.isEmpty {
            let updateText = updates.prefix(2).joined(separator: " ")
            promptParts.append("URGENT: \(updateText)")
        }
        
        systemPrompt = promptParts.joined(separator: "\n\n")
        
        // Debug logging
        let ragInfo = ragChunks.isEmpty ? "NO RAG" : "\(ragChunks.count) chunks"
        print("📋 Prompt: \(systemPrompt.count) chars, \(ragInfo)")
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
            return await AVAudioApplication.requestRecordPermission()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Response Processing
    
    /// Detect if user wants to end the session.
    private func detectEndSessionIntent(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let endPhrases = [
            "i am done",
            "i'm done",
            "that's all",
            "that is all",
            "stop",
            "goodbye",
            "good bye",
            "bye",
            "exit",
            "quit",
            "end session",
            "no more questions",
            "thank you goodbye",
            "thanks bye"
        ]
        
        for phrase in endPhrases {
            if lowercased.contains(phrase) {
                return true
            }
        }
        
        return false
    }
    
    /// Write a line to the local transcript file for debugging.
    private func writeToTranscript(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(timestamp) | \(line)\n"
        
        guard let data = entry.data(using: .utf8) else {
            print("❌ Failed to encode transcript line to UTF8")
            return
        }
        
        do {
            if FileManager.default.fileExists(atPath: transcriptFileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: transcriptFileURL)
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            } else {
                try data.write(to: transcriptFileURL, options: .atomic)
                print("✅ Created transcript file at: \(transcriptFileURL.path)")
            }
        } catch {
            print("❌ Failed to write transcript: \(error.localizedDescription)")
            print("   Attempted path: \(transcriptFileURL.path)")
        }
    }
    
    /// Clear transcript file at start of new session.
    private func clearTranscript() {
        if FileManager.default.fileExists(atPath: transcriptFileURL.path) {
            do {
                try FileManager.default.removeItem(at: transcriptFileURL)
                print("🗑️ Cleared previous transcript file")
            } catch {
                print("⚠️ Failed to clear transcript: \(error.localizedDescription)")
            }
        }
        writeToTranscript("=== NEW SESSION ===")
    }
    
    /// Detect if model hallucinated dangerous or nonsensical advice.
    /// Small models (350M) often make things up - catch and reject these.
    private func containsDangerousHallucination(_ response: String) -> Bool {
        let lowercased = response.lowercased()
        
        // ONLY block if advising to shelter IN car (not just mentioning cars)
        let carShelterPatterns = [
            "go.*car",
            "stay.*car",
            "shelter.*car",
            "backseat",
            "back seat",
            "center.*car"
        ]
        
        for pattern in carShelterPatterns {
            if lowercased.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        // Other dangerous hallucinations
        let dangerousPhrases = [
            "stay outside",
            "go outside",
            "basement is dangerous",
            "basement.*most damage",  // "basement is where tornado causes most damage"
            "read this out loud",  // Echoing system prompt
            "information section",  // Echoing system prompt
            "according to this",  // Meta-reference
            "the user wants"  // Echoing system reasoning
        ]
        
        for phrase in dangerousPhrases {
            if lowercased.contains(phrase) || lowercased.range(of: phrase, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }
    
    /// Enforce maximum 3 sentences to prevent rambling.
    /// Small models (350M) often ignore length instructions, so we truncate post-generation.
    private func enforceResponseLength(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Split by sentence-ending punctuation
        let sentencePattern = #"[.!?]+"#
        guard let regex = try? NSRegularExpression(pattern: sentencePattern) else {
            return trimmed
        }
        
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, range: range)
        
        // If we have 3 or fewer sentences, return as-is
        guard matches.count > 3 else { return trimmed }
        
        // Truncate after 3rd sentence
        let thirdSentenceEnd = matches[2].range.upperBound
        if let swiftRange = Range(NSRange(location: 0, length: thirdSentenceEnd), in: trimmed) {
            return String(trimmed[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return trimmed
    }
    
    // MARK: - Voice Query Preprocessing
    
    /// Preprocess voice queries to improve RAG retrieval quality.
    /// Handles: removing filler words, expanding contractions, normalizing question patterns.
    private func preprocessVoiceQuery(_ query: String) -> String {
        var cleaned = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common filler words and hesitations that don't help retrieval
        let fillers = ["um", "uh", "like", "you know", "i mean", "sort of", "kind of"]
        for filler in fillers {
            cleaned = cleaned.replacingOccurrences(of: " \(filler) ", with: " ")
            cleaned = cleaned.replacingOccurrences(of: "^\(filler) ", with: "", options: .regularExpression)
        }
        
        // Expand common contractions for better matching
        let contractions = [
            "what's": "what is",
            "where's": "where is",
            "how's": "how is",
            "i'm": "i am",
            "we're": "we are",
            "they're": "they are",
            "can't": "cannot",
            "don't": "do not",
            "won't": "will not",
            "shouldn't": "should not",
            "isn't": "is not",
            "aren't": "are not"
        ]
        for (contraction, expanded) in contractions {
            cleaned = cleaned.replacingOccurrences(of: contraction, with: expanded)
        }
        
        // Normalize common question starts to improve retrieval
        if cleaned.hasPrefix("can you tell me ") {
            cleaned = String(cleaned.dropFirst("can you tell me ".count))
        }
        if cleaned.hasPrefix("could you tell me ") {
            cleaned = String(cleaned.dropFirst("could you tell me ".count))
        }
        if cleaned.hasPrefix("do you know ") {
            cleaned = String(cleaned.dropFirst("do you know ".count))
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio Session Management

    /// Configure the audio session for voice interaction.
    /// Handles: ringer/silent mode, Bluetooth, ducking, and interruptions.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .playAndRecord: allows simultaneous input + output
        // .defaultToSpeaker: plays audio through speaker (not earpiece)
        // .allowBluetooth*: supports BT headsets
        // mode: .default (NOT .voiceChat!)
        //   .voiceChat applies aggressive AGC + noise suppression that reduces
        //   mic sensitivity by ~10x (RMS 0.02 instead of 0.15 for normal speech).
        //   .default preserves raw mic levels, which our energy-based detection needs.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
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
            stopAudioEngine()
            speechAudioBuffer.removeAll()
            isAccumulatingSpeech = false
            Task {
                await runAnywhereManager.stopSpeaking()
            }
            isListening = false
            isSpeaking = false
            audioLevel = 0
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

    /// Start listening for speech using AVAudioEngine + energy-based detection.
    ///
    /// **Why energy-based instead of RunAnywhere VAD?**
    /// RunAnywhere's `detectSpeech(in:)` consistently returned `false` for all
    /// audio despite correct init/start/threshold tuning. Energy-based (RMS)
    /// detection is simpler, proven, and used by many production voice apps.
    /// We still use RunAnywhere for STT, LLM, and TTS — just not VAD.
    ///
    /// **Swift 6 concurrency safety**:
    /// The `installTap` closure runs on a realtime audio thread, NOT the main
    /// actor. We use `AsyncStream` + a `nonisolated` static tap handler to
    /// avoid `dispatch_assert_queue_fail` crashes in Swift 6.
    ///
    /// **Speech detection algorithm**:
    /// 1. Compute RMS of each audio chunk (~85ms at 4096 samples / 48kHz).
    /// 2. If RMS > `speechStartThreshold` (0.015) → speech started, accumulate.
    /// 3. If RMS drops below threshold for `silenceTimeoutSeconds` (1.2s) → speech ended.
    /// 4. Convert accumulated samples to WAV → STT → LLM → TTS.
    private func startRecordingWithVAD() async throws {
        // Clear previous state
        speechAudioBuffer.removeAll(keepingCapacity: true)
        isAccumulatingSpeech = false

        // ── CRITICAL: Force-reset the audio session before recording ─────────
        // After RunAnywhere TTS plays audio through its AudioPlaybackManager,
        // the audio route may leave the mic input disconnected. iOS requires
        // an explicit deactivate → reconfigure → reactivate cycle to properly
        // re-route the mic for recording. Without this, AVAudioEngine's input
        // node returns all-zero samples (the exact symptom we observed).
        // Ref: Apple Developer Forums thread/771048, thread/111249
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ [Audio] Session deactivation note: \(error.localizedDescription)")
            // Non-fatal: deactivation can fail if other audio is active
        }

        // Brief pause for iOS audio subsystem to settle the route change
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Re-set category + reactivate — forces iOS to reconnect the mic input
        // Use .default mode (NOT .voiceChat) for full mic sensitivity
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        print("🎙️ [Audio] Session force-reset: deactivated → .playAndRecord → reactivated")

        // ── 1. Set up AVAudioEngine AFTER session is properly configured ─────
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let nativeRate = nativeFormat.sampleRate

        print("🎙️ [Audio] Mic native format: \(nativeRate) Hz, \(nativeFormat.channelCount) ch")

        // ── 2. Create AsyncStream bridge (tap → main actor) ─────────────────
        let (audioStream, continuation) = AsyncStream<[Float]>.makeStream()
        self.audioStreamContinuation = continuation

        // ── 3. Install tap — built via nonisolated static to avoid @MainActor ─
        let tapHandler = Self.makeTapHandler(
            continuation: continuation,
            nativeRate: nativeRate
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nativeFormat,
            block: tapHandler
        )

        // ── 4. Start engine ──────────────────────────────────────────────────
        engine.prepare()
        try engine.start()
        print("🎙️ [Audio] Engine started, tap installed")

        // ── 5. Process audio stream with energy-based speech detection ───────
        let threshold = speechStartThreshold
        let silenceTimeout = silenceTimeoutSeconds
        var chunkCount = 0
        var lastSpeechChunkTime: Date?

        vadListeningTask = Task { [weak self] in
            for await samples in audioStream {
                guard let self = self, self.isConversationActive else { break }

                chunkCount += 1

                // Compute RMS energy for this chunk
                let rms = Self.calculateRMS(samples)
                self.audioLevel = rms

                let isSpeech = rms > threshold

                // Debug logging: first 5 chunks + every 50th + every speech detection
                if chunkCount <= 5 || chunkCount % 50 == 0 || (isSpeech && !self.isAccumulatingSpeech) {
                    print("🎙️ [Audio] #\(chunkCount) | \(samples.count) samples | RMS=\(String(format: "%.4f", rms)) | speech=\(isSpeech)")
                }

                if isSpeech {
                    lastSpeechChunkTime = Date()

                    if !self.isAccumulatingSpeech {
                        // ── Speech just started ──
                        self.isAccumulatingSpeech = true
                        self.speechAudioBuffer.removeAll(keepingCapacity: true)
                        print("🗣️ Speech started (RMS=\(String(format: "%.4f", rms)))")

                        // If agent is currently speaking, interrupt TTS
                        if self.isSpeaking {
                            Task {
                                await self.runAnywhereManager.stopSpeaking()
                            }
                            self.isSpeaking = false
                            self.state = .listening
                            self.onStateChange?(.listening)
                            print("🔇 Interrupted TTS — user started speaking")
                        }
                    }

                    self.speechAudioBuffer.append(contentsOf: samples)

                } else if self.isAccumulatingSpeech {
                    // ── Silence after speech — keep accumulating (trailing buffer) ──
                    self.speechAudioBuffer.append(contentsOf: samples)

                    // Check if silence has lasted long enough to finalize turn
                    if let lastSpeech = lastSpeechChunkTime,
                       Date().timeIntervalSince(lastSpeech) >= silenceTimeout {
                        self.isAccumulatingSpeech = false
                        lastSpeechChunkTime = nil
                        print("🗣️ Speech ended (after \(String(format: "%.1f", silenceTimeout))s silence)")
                        await self.processSpeechTurn()
                        break  // Exit stream loop; processSpeechTurn restarts via startListeningLoop
                    }
                }
            }
            print("🎙️ [Audio] Stream processing ended after \(chunkCount) chunks")
        }

        isListening = true
        print("🎙️ [Audio] Listening for speech… (energy threshold=\(threshold), silence timeout=\(silenceTimeout)s)")
    }

    /// Process a complete speech turn: stop engine → build WAV → STT → LLM → TTS → restart listening.
    private func processSpeechTurn() async {
        guard isConversationActive else { return }

        isListening = false
        audioLevel = 0

        // Stop audio engine (mic off while processing this turn)
        stopAudioEngine()

        // Grab the accumulated audio and clear the buffer
        let capturedSamples = speechAudioBuffer
        speechAudioBuffer.removeAll(keepingCapacity: true)
        isAccumulatingSpeech = false

        // Minimum audio check: ~100ms of audio at 16 kHz = 1600 samples
        guard capturedSamples.count > 1600 else {
            print("ℹ️ Too short audio (\(capturedSamples.count) samples), resuming listening")
            await startListeningLoop()
            return
        }

        // Convert accumulated Float32 samples to 16-bit PCM WAV Data
        let audioData = Self.createWAVData(from: capturedSamples)

        print("🎤 Captured \(capturedSamples.count) samples (\(String(format: "%.1f", Double(capturedSamples.count) / 16000.0))s), WAV size: \(audioData.count) bytes")

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

        // Enhanced logging for debugging
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("👤 USER: \(transcription)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // Write to local transcript file
        writeToTranscript("👤 USER: \(transcription)")

        lastUserText = transcription
        onUserTranscript?(transcription)

        // Minimal question validation: Skip if empty after trimming
        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("⚠️ Transcription was empty, resuming listening")
            await startListeningLoop()
            return
        }
        
        // Check for session-ending intent
        if detectEndSessionIntent(trimmed) {
            print("🛑 User requested to end session")
            let farewell = "Okay, stay safe. You can reopen the app anytime if you need more help."
            lastAgentText = farewell
            onAgentResponse?(farewell)
            await speakAgent(farewell)
            stop()
            return
        }

        lastUserText = trimmed
        onUserTranscript?(trimmed)
        
        // If waiting for satisfaction response, don't process as question
        if awaitingSatisfactionResponse {
            awaitingSatisfactionResponse = false
            // Acknowledge and resume
            let ack = "Thank you for your feedback. Ask me anything else if you need help."
            lastAgentText = ack
            onAgentResponse?(ack)
            
            // Log to telemetry (was missing!)
            TelemetryService.shared.recordAgentResponse(
                incidentCode: currentIncidentCode,
                responseText: ack
            )
            
            await speakAgent(ack)
            await startListeningLoop()
            return
        }

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

        // Post-process: enforce 3-sentence limit and validate for hallucinations
        var cleanedResponse = enforceResponseLength(response)
        var wasHallucination = false
        
        // CRITICAL: Detect dangerous hallucinations before speaking
        if containsDangerousHallucination(cleanedResponse) {
            wasHallucination = true
            print("⚠️⚠️⚠️ HALLUCINATION DETECTED - REPLACED WITH SAFE FALLBACK ⚠️⚠️⚠️")
            print("Original (blocked): \(cleanedResponse)")
            cleanedResponse = "Go to your basement or lowest floor interior room immediately. Stay away from all windows and exterior walls. Call 911 if you need immediate help."
        }
        
        // Enhanced logging for debugging
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🤖 AGENT\(wasHallucination ? " [FALLBACK]" : ""): \(cleanedResponse)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // Write to local transcript file
        writeToTranscript("🤖 AGENT\(wasHallucination ? " [FALLBACK]" : ""): \(cleanedResponse)")
        
        // Record full response to telemetry for quality analysis
        TelemetryService.shared.recordAgentResponse(
            incidentCode: currentIncidentCode,
            responseText: "\(wasHallucination ? "[HALLUCINATION_BLOCKED] " : "")\(cleanedResponse)"
        )
        
        lastAgentText = cleanedResponse
        onAgentResponse?(cleanedResponse)

        // Increment completed turns
        completedTurns += 1

        // === TTS Phase ===
        await speakAgent(cleanedResponse)

        // === Satisfaction prompt after 3+ turns (once per session) ===
        if completedTurns >= 3 && !satisfactionPrompted {
            satisfactionPrompted = true
            awaitingSatisfactionResponse = true
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

        // Sanitize text for TTS (remove markdown, special chars)
        let cleanText = sanitizeForTTS(text)

        do {
            try await runAnywhereManager.speak(cleanText)
        } catch {
            // Fallback: use system AVSpeechSynthesizer
            print("⚠️ RunAnywhere TTS failed, using system voice: \(error)")
            await speakWithSystemVoice(cleanText)
        }

        isSpeaking = false
    }
    
    /// Sanitize text for TTS to prevent reading markdown and special characters aloud.
    private func sanitizeForTTS(_ text: String) -> String {
        var cleaned = text
        
        // CRITICAL: Fix emergency number pronunciation
        // "911" should be "nine one one" not "nine hundred eleven"
        cleaned = cleaned.replacingOccurrences(of: "911", with: "nine one one")
        cleaned = cleaned.replacingOccurrences(of: "9-1-1", with: "nine one one")
        
        // Fix phone numbers by converting each digit to words
        // Pattern: XXX-XXX-XXXX or similar formats
        let digitMap = ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
                       "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine"]
        
        // Match phone numbers: 3-4 digits, dash, 3-4 digits, dash, 3-4 digits
        let phonePattern = #"\b(\d{3,4})-(\d{3,4})-(\d{3,4})\b"#
        if let regex = try? NSRegularExpression(pattern: phonePattern) {
            var result = cleaned
            let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            
            // Process matches in reverse to maintain string indices
            for match in matches.reversed() {
                if let range = Range(match.range, in: cleaned) {
                    let phoneNumber = String(cleaned[range])
                    // Convert each digit to word
                    let spokenPhone = phoneNumber.map { char in
                        if let digit = digitMap[String(char)] {
                            return digit
                        } else if char == "-" {
                            return ""  // Remove dashes
                        }
                        return String(char)
                    }.joined(separator: " ")
                    
                    result = result.replacingCharacters(in: range, with: spokenPhone)
                }
            }
            cleaned = result
        }
        
        // Remove phrases the model might echo from system prompt
        let systemPromptLeakage = [
            "REFERENCE INFORMATION",
            "reference chunks",
            "cite these sources when answering",
            "According to the context",
            "Based on the reference",
            "AUTHORITY UPDATE",
            "PRIORITY"
        ]
        for phrase in systemPromptLeakage {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: "", options: .caseInsensitive)
        }
        
        // Remove markdown bold/italic markers
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        cleaned = cleaned.replacingOccurrences(of: "__", with: "")
        cleaned = cleaned.replacingOccurrences(of: "*", with: "")
        cleaned = cleaned.replacingOccurrences(of: "_", with: "")
        
        // Remove markdown headers
        cleaned = cleaned.replacingOccurrences(of: "###", with: "")
        cleaned = cleaned.replacingOccurrences(of: "##", with: "")
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")
        
        // Remove markdown code blocks and inline code
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")
        
        // Remove brackets that might be read as "open bracket" / "close bracket"
        cleaned = cleaned.replacingOccurrences(of: "[", with: "")
        cleaned = cleaned.replacingOccurrences(of: "]", with: "")
        
        // Remove parentheses around citations or asides (keep content)
        cleaned = cleaned.replacingOccurrences(of: "(", with: "")
        cleaned = cleaned.replacingOccurrences(of: ")", with: "")
        
        // Replace em dash and en dash with natural pause
        cleaned = cleaned.replacingOccurrences(of: "—", with: ", ")
        cleaned = cleaned.replacingOccurrences(of: "–", with: ", ")
        
        // Remove extra whitespace and fix sentence breaks
        cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\n\n", with: ". ")
        cleaned = cleaned.replacingOccurrences(of: "\n", with: ". ")
        
        // Clean up multiple periods or commas
        cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        cleaned = cleaned.replacingOccurrences(of: ",,", with: ",")
        cleaned = cleaned.replacingOccurrences(of: ". .", with: ".")
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
        print("⚠️ Voice failover: \(error.localizedDescription)")

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
        state = .error(error.localizedDescription)
        onError?(error)
        onStateChange?(state)
    }

    // MARK: - Audio Utilities

    /// Build the audio tap handler outside actor isolation.
    ///
    /// Returning the closure from a `nonisolated` static prevents Swift 6
    /// from inferring `@MainActor` on the closure (which would crash on
    /// the realtime audio thread with `dispatch_assert_queue_fail`).
    nonisolated private static func makeTapHandler(
        continuation: AsyncStream<[Float]>.Continuation,
        nativeRate: Double
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            let rawSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

            // Downsample to 16 kHz mono (e.g. 48000 / 16000 = 3)
            let samples: [Float]
            let ratio = nativeRate / 16000.0
            if ratio > 1.01 {
                let step = Int(ratio.rounded())
                samples = stride(from: 0, to: rawSamples.count, by: step).map { rawSamples[$0] }
            } else {
                samples = rawSamples
            }

            continuation.yield(samples)
        }
    }

    /// Calculate RMS of audio samples for level visualization.
    nonisolated private static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    /// Convert Float32 audio samples to a 16-bit PCM WAV file Data.
    ///
    /// This is needed because RunAnywhere's `transcribe()` and `processVoiceTurn()`
    /// expect WAV file data. The VAD's onAudioBuffer provides raw Float32 samples,
    /// so we wrap them in a proper WAV container.
    ///
    /// - Parameters:
    ///   - samples: Float32 audio samples (range -1.0 to 1.0), 16 kHz mono.
    ///   - sampleRate: The sample rate (default 16000 Hz).
    /// - Returns: Complete WAV file as `Data`.
    private static func createWAVData(from samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = UInt32(samples.count) * UInt32(blockAlign)
        let chunkSize: UInt32 = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLittleEndian(&data, chunkSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt sub-chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLittleEndian(&data, UInt32(16))               // Sub-chunk size
        appendLittleEndian(&data, UInt16(1))                // PCM format
        appendLittleEndian(&data, numChannels)
        appendLittleEndian(&data, UInt32(sampleRate))
        appendLittleEndian(&data, byteRate)
        appendLittleEndian(&data, blockAlign)
        appendLittleEndian(&data, bitsPerSample)

        // data sub-chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLittleEndian(&data, dataSize)

        // Audio samples: Float32 → Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * Float(Int16.max))
            appendLittleEndian(&data, int16Value)
        }

        return data
    }

    /// Append a value in little-endian byte order to a Data buffer.
    private static func appendLittleEndian<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
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
