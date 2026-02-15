/**
 * SetupView — One-time first-launch setup screen.
 *
 * Shown ONLY on the very first launch after app install.
 * Downloads all AI models (LLM, STT, TTS) and caches them locally.
 * Once complete, this view never appears again — the app goes straight
 * to ContentView on all future launches.
 *
 * The user cannot skip or dismiss this screen. Models must be ready
 * before the app is usable, because when an emergency alert arrives,
 * the voice agent must start instantly with zero download wait.
 */

import SwiftUI
import AVFoundation

struct SetupView: View {
    @EnvironmentObject var manager: RunAnywhereManager
    @State private var hasStarted = false
    @State private var micGranted = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.red)

            Text("Ask the Alert")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Setting up offline AI voice assistant")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            // Progress section
            VStack(spacing: 16) {
                // Overall progress bar
                ProgressView(value: manager.downloadProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .frame(width: 260)

                // Status text
                Text(manager.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(height: 20)

                // Individual model status
                VStack(spacing: 8) {
                    setupRow(icon: "text.bubble.fill", label: "Language Model", status: manager.status.llmStatus)
                    setupRow(icon: "mic.fill", label: "Speech Recognition", status: manager.status.sttStatus)
                    setupRow(icon: "speaker.wave.2.fill", label: "Voice Synthesis", status: manager.status.ttsStatus)
                    setupRow(icon: "waveform", label: "Voice Detection", status: manager.status.vadStatus)
                }
                .padding(.horizontal, 40)
            }

            // Error message
            if let error = manager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.1))
                )
                .padding(.horizontal, 32)

                // Retry button on error
                Button("Retry Setup") {
                    manager.errorMessage = nil
                    Task {
                        await manager.performFirstTimeSetup()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Text("This only happens once. Models are stored\nlocally for instant offline use.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .task {
            guard !hasStarted else { return }
            hasStarted = true

            // Request microphone permission up-front during setup,
            // so it's already granted when an alert arrives.
            let micStatus = AVAudioApplication.shared.recordPermission
            if micStatus == .undetermined {
                micGranted = await AVAudioApplication.requestRecordPermission()
            } else {
                micGranted = (micStatus == .granted)
            }

            await manager.performFirstTimeSetup()
        }
    }

    private func setupRow(icon: String, label: String, status: ModelReadiness) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(statusColor(status))
                .frame(width: 24)

            Text(label)
                .font(.caption)

            Spacer()

            statusIndicator(status)
        }
    }

    private func statusColor(_ status: ModelReadiness) -> Color {
        switch status {
        case .ready: return .green
        case .downloading, .loading: return .orange
        case .failed: return .red
        case .notDownloaded, .downloaded: return .gray
        }
    }

    @ViewBuilder
    private func statusIndicator(_ status: ModelReadiness) -> some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .downloading, .loading:
            ProgressView()
                .scaleEffect(0.6)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.gray)
                .font(.caption)
        }
    }
}

#Preview {
    SetupView()
        .environmentObject(RunAnywhereManager.shared)
}
