/**
 * ModelDownloadView — Model download progress and readiness UI.
 *
 * Shows download progress for RunAnywhere AI models.
 * Displays individual model status (LLM, STT, TTS, VAD).
 * Provides "Offline Ready" indicator when all models are cached.
 * Allows manual re-download if models are corrupted or outdated.
 */

import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var manager: RunAnywhereManager

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(.blue)
                Text("AI Models")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            // Individual model status
            VStack(spacing: 12) {
                ModelStatusRow(
                    icon: "text.bubble.fill",
                    label: "Language Model (LLM)",
                    status: manager.status.llmStatus,
                    detail: "Llama 3.2 1B — Q4"
                )
                ModelStatusRow(
                    icon: "mic.fill",
                    label: "Speech-to-Text (STT)",
                    status: manager.status.sttStatus,
                    detail: "Whisper Base — ONNX"
                )
                ModelStatusRow(
                    icon: "speaker.wave.2.fill",
                    label: "Text-to-Speech (TTS)",
                    status: manager.status.ttsStatus,
                    detail: "Piper US English"
                )
                ModelStatusRow(
                    icon: "waveform",
                    label: "Voice Detection (VAD)",
                    status: manager.status.vadStatus,
                    detail: "Energy-based"
                )
            }

            // Overall progress bar (when downloading)
            if manager.status.isLoading {
                VStack(spacing: 8) {
                    ProgressView(value: manager.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue)

                    Text(manager.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Error message
            if let error = manager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.1))
                )
            }

            // Re-download button
            if manager.status.isReady {
                Button(action: {
                    Task {
                        await manager.redownloadModels()
                    }
                }) {
                    Label("Re-download Models", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(manager.status.isReady ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(manager.status.isReady ? "Offline Ready" : "Preparing")
                .font(.caption)
                .foregroundStyle(manager.status.isReady ? .green : .orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(manager.status.isReady ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }
}

// MARK: - Model Status Row

private struct ModelStatusRow: View {
    let icon: String
    let label: String
    let status: ModelReadiness
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(statusColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            statusIndicator
        }
    }

    private var statusColor: Color {
        switch status {
        case .ready: return .green
        case .downloading, .loading: return .orange
        case .failed: return .red
        case .notDownloaded, .downloaded: return .gray
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading, .loading:
            ProgressView()
                .scaleEffect(0.7)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.gray)
        case .downloaded:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.blue)
        }
    }
}

#Preview {
    ModelDownloadView(manager: RunAnywhereManager.shared)
        .padding()
}
