/**
 * MicPermissionView — Microphone permission request/denied UX.
 *
 * Shown when microphone access is needed but not yet granted or denied.
 * Explains why the mic is needed for voice-first interaction.
 * Provides a button to request permission or open Settings.
 */

import SwiftUI
import AVFoundation

struct MicPermissionView: View {
    @Binding var isGranted: Bool
    @State private var permissionStatus: AVAudioApplication.RecordPermission = .undetermined

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.slash.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Microphone Access Needed")
                .font(.title2)
                .fontWeight(.bold)

            Text("Ask the Alert uses your microphone to hear your questions about the emergency alert and provide voice guidance.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Privacy note
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("Audio is processed on-device only")
                        .font(.caption)
                }
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.blue)
                    Text("Works completely offline")
                        .font(.caption)
                }
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.orange)
                    Text("Audio is never stored or uploaded")
                        .font(.caption)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, 32)

            Spacer()

            if permissionStatus == .denied {
                Button(action: openSettings) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Open Settings")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 32)

                Text("Enable microphone in Settings > Ask the Alert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: requestPermission) {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text("Allow Microphone Access")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 32)
            }

            Spacer()
                .frame(height: 20)
        }
        .onAppear {
            checkPermission()
        }
    }

    private func checkPermission() {
        permissionStatus = AVAudioApplication.shared.recordPermission
        isGranted = permissionStatus == .granted
    }

    private func requestPermission() {
        Task {
            do {
                let granted = try await AVAudioApplication.requestRecordPermission()
                await MainActor.run {
                    self.isGranted = granted
                    if !granted {
                        self.permissionStatus = .denied
                    }
                }
            } catch {
                await MainActor.run {
                    self.isGranted = false
                    self.permissionStatus = .denied
                }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    MicPermissionView(isGranted: .constant(false))
}
