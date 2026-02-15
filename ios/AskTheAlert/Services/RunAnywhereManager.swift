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

/// Model IDs and download URLs for each pipeline component.
/// Uses the same proven models from the RunAnywhere Playground starter app.
/// Ref: https://github.com/RunanywhereAI/runanywhere-sdks/tree/main/Playground/swift-starter-app
enum ModelConfig {
    // -- Model IDs (must match IDs passed to registerModel) ----------------
    /// LiquidAI LFM2 350M Q4_K_M — compact, fast LLM for emergency responses.
    static let llmModelId = "lfm2-350m-q4_k_m"
    /// Sherpa Whisper Tiny (English) — fast on-device STT.
    static let sttModelId = "sherpa-onnx-whisper-tiny.en"
    /// Piper TTS US English Lessac Medium — natural neural voice.
    static let ttsVoiceId = "vits-piper-en_US-lessac-medium"

    // -- Download URLs -----------------------------------------------------
    static let llmURL = "https://huggingface.co/LiquidAI/LFM2-350M-GGUF/resolve/main/LFM2-350M-Q4_K_M.gguf"
    static let sttURL = "https://github.com/RunanywhereAI/sherpa-onnx/releases/download/runanywhere-models-v1/sherpa-onnx-whisper-tiny.en.tar.gz"
    static let ttsURL = "https://github.com/RunanywhereAI/sherpa-onnx/releases/download/runanywhere-models-v1/vits-piper-en_US-lessac-medium.tar.gz"
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

    /// Whether the one-time model setup (download) has been completed.
    /// Persisted in UserDefaults so it survives app restarts.
    @Published var setupComplete: Bool

    // MARK: Private State

    private var isInitialized = false
    private static let setupCompleteKey = "RunAnywhereModelsSetupComplete"

    private init() {
        self.setupComplete = UserDefaults.standard.bool(forKey: Self.setupCompleteKey)
    }

    // MARK: - SDK Initialization (internal, registers modules + SDK)

    /// Register modules, initialize the SDK core, and register model URLs.
    /// Does NOT download or load models.
    private func initializeSDK() throws {
        guard !isInitialized else { return }

        // 1. Register backend modules (LlamaCPP for LLM, ONNX for STT/TTS)
        LlamaCPP.register()
        ONNX.register()

        // 2. Initialize the SDK
        #if DEBUG
        try RunAnywhere.initialize(
            environment: .development
        )
        RunAnywhere.setLogLevel(.debug)
        RunAnywhere.setDebugMode(true)
        #else
        try RunAnywhere.initialize(
            apiKey: ProcessInfo.processInfo.environment["RUNANYWHERE_API_KEY"] ?? "",
            baseURL: "https://api.runanywhere.ai",
            environment: .production
        )
        #endif

        // 3. Register models with download URLs
        //    This tells the SDK *where* to fetch each model from.
        //    Pattern follows the official Playground starter app.
        Self.registerModels()

        isInitialized = true
    }

    // MARK: - Model Registration

    /// Register all models with the SDK so `downloadModel()` knows where to fetch them.
    /// Must be called AFTER `RunAnywhere.initialize()` and BEFORE any download/load calls.
    /// Ref: Playground/swift-starter-app/LocalAIPlayground/Services/ModelService.swift
    private static func registerModels() {
        // LLM — LiquidAI LFM2 350M (GGUF format, runs via LlamaCPP)
        if let llmURL = URL(string: ModelConfig.llmURL) {
            RunAnywhere.registerModel(
                id: ModelConfig.llmModelId,
                name: "LiquidAI LFM2 350M Q4_K_M",
                url: llmURL,
                framework: .llamaCpp,
                memoryRequirement: 250_000_000
            )
        }

        // STT — Sherpa Whisper Tiny English (ONNX format, tar.gz archive)
        if let sttURL = URL(string: ModelConfig.sttURL) {
            RunAnywhere.registerModel(
                id: ModelConfig.sttModelId,
                name: "Sherpa Whisper Tiny (ONNX)",
                url: sttURL,
                framework: .onnx,
                modality: .speechRecognition,
                artifactType: .archive(.tarGz, structure: .nestedDirectory),
                memoryRequirement: 75_000_000
            )
        }

        // TTS — Piper US English Lessac Medium (ONNX format, tar.gz archive)
        if let ttsURL = URL(string: ModelConfig.ttsURL) {
            RunAnywhere.registerModel(
                id: ModelConfig.ttsVoiceId,
                name: "Piper TTS (US English - Lessac Medium)",
                url: ttsURL,
                framework: .onnx,
                modality: .speechSynthesis,
                artifactType: .archive(.tarGz, structure: .nestedDirectory),
                memoryRequirement: 65_000_000
            )
        }

        print("✅ Models registered: LLM (\(ModelConfig.llmModelId)), STT (\(ModelConfig.sttModelId)), TTS (\(ModelConfig.ttsVoiceId))")
    }

    // MARK: - First-Time Setup (called once after install)

    /// One-time setup: downloads models from the network, loads them into memory,
    /// initializes the voice agent, and persists a flag so this never runs again.
    /// Shows progress UI via published properties.
    func performFirstTimeSetup() async {
        do {
            statusMessage = "Registering AI modules…"
            try initializeSDK()

            statusMessage = "Downloading AI models…"
            await loadAllModels()
            await initializeVoiceAgent()
            await warmup()

            if status.isReady {
                // Persist so we never download again
                UserDefaults.standard.set(true, forKey: Self.setupCompleteKey)
                setupComplete = true
                statusMessage = "Setup complete — offline ready"
                print("✅ First-time setup complete. Models cached for future launches.")
            }
        } catch {
            errorMessage = "Setup failed: \(error.localizedDescription)"
            statusMessage = "Setup failed"
            print("❌ First-time setup failed: \(error)")
        }
    }

    // MARK: - Subsequent Launch (fast, loads from cache)

    /// Called on every app launch AFTER first-time setup is done.
    /// Models are already downloaded and cached on disk — this just loads
    /// them into memory. Should be near-instant.
    func loadCachedModels() async {
        do {
            try initializeSDK()

            statusMessage = "Loading cached models…"
            await loadAllModels()
            await initializeVoiceAgent()

            if status.isReady {
                statusMessage = "All models ready — offline ready"
            }
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            statusMessage = "Load failed"
            print("❌ loadCachedModels failed: \(error)")
        }
    }

    // MARK: - Model Loading

    /// Download (if needed) and load all required models (LLM, STT, TTS) + initialize VAD.
    ///
    /// For each model the pattern is (from the official Playground):
    ///   1. Try `load*()` first — succeeds instantly if already cached on disk.
    ///   2. If load fails, call `downloadModel()` (returns AsyncStream of progress).
    ///   3. After download completes, call `load*()` again.
    ///
    /// `downloadModel()` is the **universal** download method for all model types.
    /// The SDK knows the type from the `modality` set during `registerModel()`.
    ///
    /// Ref: Playground/swift-starter-app/LocalAIPlayground/Services/ModelService.swift
    private func loadAllModels() async {
        // 1. LLM ──────────────────────────────────────────────────────────────
        await downloadAndLoad(
            label: "Language Model",
            modelId: ModelConfig.llmModelId,
            setStatus: { self.status.llmStatus = $0 },
            loadFn: { try await RunAnywhere.loadModel(ModelConfig.llmModelId) }
        )
        updateOverallProgress()

        // 2. STT (Whisper) ────────────────────────────────────────────────────
        await downloadAndLoad(
            label: "Speech Recognition",
            modelId: ModelConfig.sttModelId,
            setStatus: { self.status.sttStatus = $0 },
            loadFn: { try await RunAnywhere.loadSTTModel(ModelConfig.sttModelId) }
        )
        updateOverallProgress()

        // 3. TTS (Piper) ─────────────────────────────────────────────────────
        await downloadAndLoad(
            label: "Voice Synthesis",
            modelId: ModelConfig.ttsVoiceId,
            setStatus: { self.status.ttsStatus = $0 },
            loadFn: { try await RunAnywhere.loadTTSVoice(ModelConfig.ttsVoiceId) },
            fallbackOnFailure: true  // Falls back to AVSpeechSynthesizer
        )
        updateOverallProgress()

        // 4. VAD (energy-based — no download needed) ─────────────────────────
        status.vadStatus = .loading
        statusMessage = "Initializing voice detection…"
        do {
            try await RunAnywhere.initializeVAD(
                VADConfiguration(
                    energyThreshold: 0.5,
                    sampleRate: 16000,
                    frameLength: 0.032
                )
            )
            status.vadStatus = .ready
            print("✅ VAD initialized")
        } catch {
            status.vadStatus = .failed
            print("❌ VAD initialization failed: \(error.localizedDescription)")
        }
        updateOverallProgress()

        // Final status
        if status.isReady {
            statusMessage = "All models ready — offline ready"
        }
    }

    /// Generic helper: try to load a model from cache, download if needed, then load.
    ///
    /// - Parameters:
    ///   - label: Human-readable name for status messages (e.g. "Language Model").
    ///   - modelId: The registered model ID.
    ///   - setStatus: Closure to update the corresponding `ModelReadiness` field.
    ///   - loadFn: The type-specific load call (loadModel / loadSTTModel / loadTTSVoice).
    ///   - fallbackOnFailure: If `true`, mark as `.ready` on failure (TTS has system fallback).
    private func downloadAndLoad(
        label: String,
        modelId: String,
        setStatus: @escaping (ModelReadiness) -> Void,
        loadFn: @escaping () async throws -> Void,
        fallbackOnFailure: Bool = false
    ) async {
        // Step 1: Try to load from cache (instant if already downloaded)
        setStatus(.loading)
        statusMessage = "Loading \(label.lowercased())…"
        do {
            try await loadFn()
            setStatus(.ready)
            print("✅ \(label) loaded from cache: \(modelId)")
            return
        } catch {
            print("ℹ️ \(label) not cached, will download: \(error.localizedDescription)")
        }

        // Step 2: Download from CDN
        setStatus(.downloading)
        statusMessage = "Downloading \(label.lowercased())…"
        do {
            let progressStream = try await RunAnywhere.downloadModel(modelId)
            for await progress in progressStream {
                // Update the overall download bar with per-model progress
                // (Each model contributes ¼ of overall progress)
                statusMessage = "Downloading \(label.lowercased())… \(Int(progress.overallProgress * 100))%"
                if progress.stage == .completed {
                    break
                }
            }
            setStatus(.downloaded)
            print("✅ \(label) downloaded: \(modelId)")
        } catch {
            let msg = "\(label) download failed: \(error.localizedDescription)"
            if fallbackOnFailure {
                setStatus(.ready)
                print("⚠️ \(msg) — using system fallback")
                return
            }
            setStatus(.failed)
            errorMessage = msg
            print("❌ \(msg)")
            return
        }

        // Step 3: Load the freshly-downloaded model into memory
        setStatus(.loading)
        statusMessage = "Loading \(label.lowercased())…"
        do {
            try await loadFn()
            setStatus(.ready)
            print("✅ \(label) loaded: \(modelId)")
        } catch {
            let msg = "\(label) load failed: \(error.localizedDescription)"
            if fallbackOnFailure {
                setStatus(.ready)
                print("⚠️ \(msg) — using system fallback")
                return
            }
            setStatus(.failed)
            errorMessage = msg
            print("❌ \(msg)")
        }
    }

    // MARK: - Voice Agent Pipeline

    /// Initialize the Voice Agent Pipeline with all loaded models.
    /// Ref: https://docs.runanywhere.ai/swift/voice-agent
    private func initializeVoiceAgent() async {
        guard status.sttStatus == .ready,
              status.llmStatus == .ready,
              status.ttsStatus == .ready else {
            print("⚠️ Cannot initialize voice agent — not all models ready")
            return
        }

        do {
            // Models are already loaded above, so use the loaded-models shortcut
            // if available, otherwise pass config explicitly.
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
            statusMessage = "Voice agent ready"
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
            // Build the full prompt string
            var fullPrompt = "\(sys)\n\nUser: \(prompt)\n\nAssistant:"

            // Guard against exceeding LLM batch size (default 512 tokens).
            // Rough estimate: ~4 characters per token. Stay under ~480 tokens
            // to leave room for generation. That's ~1920 chars.
            let maxPromptChars = 1900
            if fullPrompt.count > maxPromptChars {
                // Truncate the system prompt portion (keep the user query intact)
                let userSuffix = "\n\nUser: \(prompt)\n\nAssistant:"
                let maxSysChars = maxPromptChars - userSuffix.count
                let truncatedSys = String(sys.prefix(max(200, maxSysChars)))
                fullPrompt = "\(truncatedSys)\n\nUser: \(prompt)\n\nAssistant:"
                print("⚠️ [LLM] Prompt truncated from \(sys.count + userSuffix.count) to \(fullPrompt.count) chars to fit batch size")
            }

            let result = try await RunAnywhere.generate(
                fullPrompt,
                options: LLMGenerationOptions(
                    maxTokens: 200,       // Reduced from 300 — shorter responses are faster + safer
                    temperature: 0.3      // Low temperature for factual emergency guidance
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
    /// Called automatically at end of first-time setup.
    private func warmup() async {
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
    /// Resets the setup flag so the first-time setup screen shows again.
    func redownloadModels() async {
        // Unload existing models first
        try? await RunAnywhere.unloadModel()
        try? await RunAnywhere.unloadSTTModel()
        try? await RunAnywhere.unloadTTSVoice()
        await RunAnywhere.cleanupVoiceAgent()

        status = RunAnywhereStatus()
        downloadProgress = 0
        voiceAgentReady = false

        // Reset the setup flag
        UserDefaults.standard.set(false, forKey: Self.setupCompleteKey)
        setupComplete = false

        // Re-run setup
        await performFirstTimeSetup()
    }

    // MARK: - Helpers

    private func updateOverallProgress() {
        let components: [ModelReadiness] = [status.llmStatus, status.sttStatus, status.ttsStatus, status.vadStatus]
        let readyCount = components.filter { $0 == .ready }.count
        downloadProgress = Float(readyCount) / Float(components.count)
    }
}
