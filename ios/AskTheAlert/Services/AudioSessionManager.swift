/**
 * AudioSessionManager — Centralized audio session management.
 *
 * Handles:
 * - AVAudioSession configuration for voice interaction
 * - Ringer/silent mode behavior (override to play through speaker)
 * - Bluetooth audio routing
 * - Audio ducking (reduce other apps' volume)
 * - Phone call interruption handling
 * - Audio route changes (headphones plugged/unplugged)
 * - Audio session activation/deactivation
 *
 * This manager ensures the audio session is configured correctly
 * for the voice agent pipeline (simultaneous recording + playback).
 */

import AVFoundation
import Combine

@MainActor
class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    // MARK: Published State

    /// Whether the audio session is currently active.
    @Published var isActive: Bool = false

    /// Whether the session was interrupted (e.g., phone call).
    @Published var isInterrupted: Bool = false

    /// Current audio route description.
    @Published var currentRoute: String = "Speaker"

    /// Whether headphones/BT are connected.
    @Published var isExternalAudioConnected: Bool = false

    // MARK: Callbacks

    /// Called when an audio interruption begins (e.g., phone call).
    var onInterruptionBegan: (() -> Void)?

    /// Called when an audio interruption ends and we should resume.
    var onInterruptionEnded: ((Bool) -> Void)?  // Bool = shouldResume

    /// Called when audio route changes.
    var onRouteChange: ((AVAudioSession.RouteChangeReason) -> Void)?

    // MARK: Private

    private let session = AVAudioSession.sharedInstance()

    // MARK: - Configuration

    /// Configure the audio session for voice interaction.
    /// Call before starting the voice agent.
    func configureForVoiceChat() throws {
        // Category: .playAndRecord — allows simultaneous mic input and speaker output
        // Mode: .voiceChat — optimized for voice communication
        // Options:
        //   .defaultToSpeaker — plays through speaker even in silent mode
        //   .allowBluetooth — supports BT headsets for both input and output
        //   .duckOthers — reduces volume of other audio apps during our session
        //   .interruptSpokenAudioAndMixWithOthers — interrupts spoken audio (e.g., podcasts)
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .duckOthers,
            ]
        )

        // Set preferred sample rate for Whisper STT (16kHz)
        try session.setPreferredSampleRate(16000)

        // Set preferred I/O buffer duration for low latency
        try session.setPreferredIOBufferDuration(0.005) // 5ms

        // Activate the session
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isActive = true

        // Register for notifications
        registerForNotifications()

        // Update route info
        updateRouteInfo()

        print("🔊 Audio session configured for voice chat")
    }

    /// Reconfigure audio session after an interruption.
    func reconfigure() throws {
        guard isActive else { return }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isInterrupted = false
        print("🔊 Audio session reconfigured after interruption")
    }

    /// Deactivate the audio session.
    /// Call when the voice agent stops.
    func deactivate() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isActive = false
            print("🔇 Audio session deactivated")
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error)")
        }

        unregisterForNotifications()
    }

    // MARK: - Route Management

    /// Check if headphones or Bluetooth are connected.
    private func updateRouteInfo() {
        let outputs = session.currentRoute.outputs
        isExternalAudioConnected = outputs.contains { port in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(port.portType)
        }

        if let output = outputs.first {
            switch output.portType {
            case .builtInSpeaker:
                currentRoute = "Speaker"
            case .headphones:
                currentRoute = "Headphones"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                currentRoute = "Bluetooth: \(output.portName)"
            default:
                currentRoute = output.portName
            }
        }
    }

    // MARK: - Notification Handling

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: session
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
    }

    private func unregisterForNotifications() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: session)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            isInterrupted = true
            print("🔇 Audio interruption began (e.g., phone call, Siri)")
            onInterruptionBegan?()

        case .ended:
            var shouldResume = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            }

            if shouldResume {
                isInterrupted = false
                print("🔊 Audio interruption ended — resuming")
            } else {
                print("🔇 Audio interruption ended — NOT resuming (user action needed)")
            }

            onInterruptionEnded?(shouldResume)

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        updateRouteInfo()

        switch reason {
        case .newDeviceAvailable:
            print("🎧 New audio device connected: \(currentRoute)")
        case .oldDeviceUnavailable:
            print("🎧 Audio device disconnected, switching to: \(currentRoute)")
        case .categoryChange:
            print("🔊 Audio category changed")
        case .override:
            print("🔊 Audio route overridden")
        default:
            break
        }

        onRouteChange?(reason)
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        print("⚠️ Media services were reset — reconfiguring audio session")
        isActive = false
        isInterrupted = false

        // Attempt to reconfigure
        do {
            try configureForVoiceChat()
        } catch {
            print("❌ Failed to reconfigure audio session after media reset: \(error)")
        }
    }
}
