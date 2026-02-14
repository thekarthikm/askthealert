/**
 * RunAnywhereManager — RunAnywhere SDK initialization & model management.
 *
 * All RunAnywhere integration lives in this file.
 * Do not create a separate RunAnywhereIntegration.swift.
 *
 * **Location**: ios/AskTheAlert/Services/RunAnywhereManager.swift
 *
 * Responsibilities:
 * - SDK initialization with LlamaCPP + ONNX module registration
 * - Model download with progress tracking (LLM, STT, TTS)
 * - Model loading and warm-up for low-latency first inference
 * - Voice Agent Pipeline initialization (VAD → STT → LLM → TTS)
 * - Readiness gating (do not start voice session until models ready)
 * - Model lifecycle events for UI feedback
 *
 * **System Requirements** (confirm on hackathon day):
 * - iOS 17.0+
 * - Swift 5.9+
 * - Xcode 15.2+
 * - Check current requirements at https://docs.runanywhere.ai/swift/introduction
 */

import Foundation
import Combine
import RunAnywhere
import LlamaCPPRuntime
import ONNXRuntime

// MARK: - Model Configuration

/// Model IDs for each pipeline component.
enum ModelConfig {
    /// Compact LLM for low-latency emergency responses.
    static let llmModelId = "llama-3.2-1b-instruct-q4"
    /// Whisper base for balanced accuracy/speed STT.
    static let sttModelId = "whisper-base-onnx"
    /// Piper US English neural voice for TTS.
    static let ttsVoiceId = "piper-en-us-amy"
}

// MARK: - Model Readiness

/// Model readiness states.
enum ModelReadiness: String, Sendable {
    case notDownloaded = "Not Downloaded"
    case downloading = "Downloading…"
    case downloaded = "Downloaded"
    case loading = "Loading…"
    case ready = "Ready"
    case failed = "Failed"
}

/// Aggregate readiness of all required models.
struct RunAnywhereStatus: Sendable {
    var sttStatus: ModelReadiness = .notDownloaded
    var llmStatus: ModelReadiness = .notDownloaded
    var ttsStatus: ModelReadiness = .notDownloaded
    var vadStatus: ModelReadiness = .notDownloaded

    /// True when all models are ready for inference.
    var isReady: Bool {
        sttStatus == .ready && llmStatus == .ready && ttsStatus == .ready && vadStatus == .ready
    }

    /// True if any model is still downloading or loading.
    var isLoading: Bool {
        [sttStatus, llmStatus, ttsStatus, vadStatus].contains(where: {
            $0 == .downloading || $0 == .loading
        })
    }

    /// Human-readable summary.
    var summary: String {
        if isReady { return "All models ready — offline ready" }
        return [
            "LLM: \(llmStatus.rawValue)",
            "STT: \(sttStatus.rawValue)",
            "TTS: \(ttsStatus.rawValue)",
            "VAD: \(vadStatus.rawValue)",
        ].joined(separator: " | ")
    }
}

// MARK: - RunAnywhereManager

@MainActor
class RunAnywhereManager: ObservableObject {
    static let shared = RunAnywhereManager()

    // MARK: Published State

    /// Current model readiness status.
    @Published var status = RunAnywhereStatus()

    /// Download progress (0.0–1.0) for the overall model download.
    @Published var downloadProgress: Float = 0.0

    /// Human-readable status message for the UI.
    @Published var statusMessage: String = "Initializing…"

    /// Error message if initialization fails.
    @Published var errorMessage: String?

    /// Whether the voice agent pipeline is initialized and ready.
    @Published var voiceAgentReady: Bool = false

    // MARK: Private State

    private var isInitialized = false

    // MARK: - SDK Initialization

    /// Initialize the RunAnywhere SDK, register modules, download and load all models.
    /// Call once at app launch or when first entering IncidentView.
    func initialize() async {
        guard !isInitialized else { return }

        do {
            statusMessage = "Registering AI modules…"

            // 1. Register backend modules
            LlamaCPP.register()
            ONNX.register()

            // 2. Initialize the SDK
            try RunAnywhere.initialize(
                apiKey: " ",
                baseURL: "https://api.runanywhere.ai",
                environment: .production
            )

            isInitialized = true
            statusMessage = "SDK initialized. Downloading models…"

            // 3. Download and load all models
            await downloadAndLoadAllModels()

            // 4. Initialize Voice Agent Pipeline
            await initializeVoiceAgent()

        } catch {
            errorMessage = "SDK initialization failed: \(error.localizedDescription)"
            statusMessage = "Initialization failed"
            print("❌ RunAnywhere initialization failed: \(error)")
        }
    }

    // MARK: - Model Download & Loading

    /// Download and load all required models (LLM, STT, TTS) with progress tracking.
    private func downloadAndLoadAllModels() async {
        // Download LLM
        await downloadModel(
            modelId: ModelConfig.llmModelId,
            label: "LLM",
            updateStatus: { [weak self] s in self?.status.llmStatus = s }
        )

        // Download STT
        await downloadModel(
            modelId: ModelConfig.sttModelId,
            label: "STT",
            updateStatus: { [weak self] s in self?.status.sttStatus = s }
        )

        // Load TTS voice
        await loadTTSVoice()

        // Initialize VAD
        await initializeVAD()

        // Update overall progress
        updateOverallProgress()

        if status.isReady {
            statusMessage = "All models ready — offline ready"
        }
    }

    /// Download a single model with progress tracking.
    private func downloadModel(
        modelId: String,
        label: String,
        updateStatus: @escaping @MainActor (ModelReadiness) -> Void
    ) async {
        updateStatus(.downloading)
        statusMessage = "Downloading \(label) model…"

        do {
            try await RunAnywhere.downloadModel(modelId)
            updateStatus(.downloaded)
            statusMessage = "Loading \(label) model…"
            updateStatus(.loading)

            // Load the model into memory
            if label == "LLM" {
                try await RunAnywhere.loadModel(modelId)
            } else if label == "STT" {
                try await RunAnywhere.loadSTTModel(modelId)
            }

            updateStatus(.ready)
            statusMessage = "\(label) ready"
            print("✅ \(label) model loaded: \(modelId)")
        } catch {
            updateStatus(.failed)
            let msg = "\(label) model failed: \(error.localizedDescription)"
            errorMessage = msg
            print("❌ \(msg)")
        }

        updateOverallProgress()
    }

    /// Load the TTS voice.
    private func loadTTSVoice() async {
        status.ttsStatus = .downloading
        statusMessage = "Loading TTS voice…"

        do {
            try await RunAnywhere.loadTTSVoice(ModelConfig.ttsVoiceId)
            status.ttsStatus = .ready
            statusMessage = "TTS voice ready"
            print("✅ TTS voice loaded: \(ModelConfig.ttsVoiceId)")
        } catch {
            // Fallback: TTS will use AVSpeechSynthesizer (system voice)
            status.ttsStatus = .ready // Mark as ready since we have fallback
            statusMessage = "TTS: using system voice (fallback)"
            print("⚠️ Neural TTS failed, will use system AVSpeechSynthesizer: \(error.localizedDescription)")
        }

        updateOverallProgress()
    }

    /// Initialize VAD for voice activity detection.
    private func initializeVAD() async {
        status.vadStatus = .loading
        statusMessage = "Initializing voice detection…"

        do {
            let vadConfig = VADConfiguration(
                energyThreshold: 0.5,
                sampleRate: 16000,
                frameLength: 0.032
            )
            try await RunAnywhere.initializeVAD(vadConfig)
            status.vadStatus = .ready
            print("✅ VAD initialized")
        } catch {
            status.vadStatus = .failed
            print("❌ VAD initialization failed: \(error.localizedDescription)")
        }

        updateOverallProgress()
    }

    // MARK: - Voice Agent Pipeline

    /// Initialize the Voice Agent Pipeline with all loaded models.
    private func initializeVoiceAgent() async {
        guard status.sttStatus == .ready,
              status.llmStatus == .ready,
              status.ttsStatus == .ready else {
            print("⚠️ Cannot initialize voice agent — not all models ready")
            return
        }

        do {
            let config = VoiceAgentConfiguration(
                sttModelId: ModelConfig.sttModelId,
                llmModelId: ModelConfig.llmModelId,
                ttsVoice: ModelConfig.ttsVoiceId,
                vadSampleRate: 16000,
                vadFrameLength: 0.032,
                vadEnergyThreshold: 0.5
            )
            try await RunAnywhere.initializeVoiceAgent(config)
            voiceAgentReady = true
            print("✅ Voice Agent Pipeline initialized")
        } catch {
            // If voice agent init fails, components are still usable individually
            voiceAgentReady = false
            print("⚠️ Voice Agent Pipeline init failed (components usable individually): \(error)")
        }
    }

    // MARK: - Voice Operations

    /// Process a complete voice turn: audio → transcription → LLM response → speech.
    func processVoiceTurn(_ audioData: Data) async throws -> VoiceAgentResult {
        return try await RunAnywhere.processVoiceTurn(audioData)
    }

    /// Transcribe audio to text only (STT).
    func transcribe(_ audioData: Data) async throws -> String {
        return try await RunAnywhere.transcribe(audioData)
    }

    /// Generate an LLM response from text.
    func generateResponse(_ prompt: String, systemPrompt: String? = nil) async throws -> String {
        if let sys = systemPrompt {
            // Use chat with system prompt via generate
            let result = try await RunAnywhere.generate(
                "\(sys)\n\nUser: \(prompt)\n\nAssistant:",
                options: LLMGenerationOptions(
                    maxTokens: 300,
                    temperature: 0.3  // Low temperature for factual emergency guidance
                )
            )
            return result.text
        }
        return try await RunAnywhere.chat(prompt)
    }

    /// Speak text aloud using TTS.
    func speak(_ text: String) async throws {
        try await RunAnywhere.speak(text, options: TTSOptions(
            rate: 0.95,   // Slightly slower for clarity in emergency
            pitch: 1.0,
            volume: 1.0
        ))
    }

    /// Stop any ongoing speech.
    func stopSpeaking() async {
        await RunAnywhere.stopSpeaking()
    }

    /// Check if TTS is currently speaking.
    var isSpeaking: Bool {
        get async {
            await RunAnywhere.isSpeaking
        }
    }

    // MARK: - VAD Operations

    /// Start VAD processing with callbacks.
    func startVAD(
        onSpeechStart: @escaping @Sendable () -> Void,
        onSpeechEnd: @escaping @Sendable () -> Void,
        onAudioBuffer: ((@Sendable ([Float]) -> Void))? = nil
    ) async throws {
        await RunAnywhere.setVADSpeechActivityCallback { @Sendable event in
            switch event {
            case .started:
                onSpeechStart()
            case .ended:
                onSpeechEnd()
            }
        }

        if let bufferCallback = onAudioBuffer {
            await RunAnywhere.setVADAudioBufferCallback(bufferCallback)
        }

        try await RunAnywhere.startVAD()
    }

    /// Stop VAD processing.
    func stopVAD() async throws {
        try await RunAnywhere.stopVAD()
    }

    // MARK: - Cleanup

    /// Clean up all resources.
    func cleanup() async {
        await RunAnywhere.cleanupVoiceAgent()
        await RunAnywhere.cleanupVAD()
        voiceAgentReady = false
    }

    // MARK: - Model Management

    /// Check if all models are downloaded and ready.
    func checkModelAvailability() async -> Bool {
        return status.isReady
    }

    /// Pre-warm models with a dummy inference to reduce first-real-request latency.
    /// Call after models are loaded and before the first user interaction.
    func warmup() async {
        guard status.isReady else { return }

        statusMessage = "Warming up AI models…"

        // Warm up STT with a tiny empty audio buffer
        do {
            let dummyAudio = Data(repeating: 0, count: 3200) // 100ms silence at 16kHz 16-bit
            _ = try await transcribe(dummyAudio)
            print("🔥 STT warmed up")
        } catch {
            print("⚠️ STT warmup failed (non-critical): \(error.localizedDescription)")
        }

        // Warm up LLM with a short prompt
        do {
            _ = try await generateResponse("Hello", systemPrompt: "You are a helpful assistant. Respond with one word.")
            print("🔥 LLM warmed up")
        } catch {
            print("⚠️ LLM warmup failed (non-critical): \(error.localizedDescription)")
        }

        statusMessage = status.summary
        print("🔥 Model warmup complete")
    }

    /// Force re-download models (e.g. after SDK update).
    func redownloadModels() async {
        status = RunAnywhereStatus()
        downloadProgress = 0
        voiceAgentReady = false
        await downloadAndLoadAllModels()
        await initializeVoiceAgent()
    }

    // MARK: - Helpers

    private func updateOverallProgress() {
        let components: [ModelReadiness] = [status.llmStatus, status.sttStatus, status.ttsStatus, status.vadStatus]
        let readyCount = components.filter { $0 == .ready }.count
        downloadProgress = Float(readyCount) / Float(components.count)
    }
}
