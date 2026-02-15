/**
 * IncidentView — The main voice-first incident screen.
 *
 * Layout (top to bottom):
 * 1. Alert banner (severity-colored, title + short body)
 * 2. Model warmup overlay (when models downloading, with progress)
 * 3. Voice waveform visualization (centre, largest element)
 * 4. Voice state indicator (listening / thinking / speaking)
 * 5. Minimal transcript area (scrollable, bottom)
 * 6. Control bar (mic toggle, repeat, 911 call, dismiss)
 *
 * Presented as a full-screen cover when a push arrives.
 * Deep link from push → immediate voice start.
 */

import SwiftUI

struct IncidentView: View {
    let incidentCode: String
    let alert: AlertModel?
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = IncidentViewModel()

    init(incidentCode: String, alert: AlertModel? = nil) {
        self.incidentCode = incidentCode
        self.alert = alert
    }

    var body: some View {
        ZStack {
            // Main content
            VStack(spacing: 0) {
                // ── Alert Banner ────────────────────────────────
                alertBanner

                // ── Voice Interaction Area ─────────────────────
                if viewModel.phase == .preparingModels {
                    modelWarmupView
                } else if !viewModel.micPermissionGranted {
                    micPermissionDeniedView
                } else {
                    voiceInteractionArea
                }

                // ── Transcript ─────────────────────────────────
                TranscriptView(entries: viewModel.transcriptEntries)
                    .frame(height: 180)
                    .padding(.horizontal, 16)

                // ── Control Bar ────────────────────────────────
                controlBar
            }
            .background(Color(.systemBackground))

            // ── 911 Confirmation Sheet ─────────────────────
            if viewModel.showCall911Sheet {
                call911ConfirmationOverlay
            }

            // ── Error Banner ───────────────────────────────
            if let error = viewModel.errorMessage {
                VStack {
                    errorBanner(error)
                    Spacer()
                }
            }
        }
        .onAppear {
            viewModel.onAppear(incidentCode: incidentCode, alert: alert)
        }
        .onDisappear {
            viewModel.onDisappear()
        }
    }

    // MARK: - Alert Banner

    private var alertBanner: some View {
        VStack(spacing: 4) {
            HStack {
                Circle()
                    .fill(viewModel.severityColor)
                    .frame(width: 8, height: 8)
                Text(viewModel.alertTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()

                // Offline ready indicator
                if viewModel.modelsReady {
                    Label("Offline Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                Button(action: {
                    viewModel.endSession()
                    appState.dismissIncident()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            if !viewModel.alertBody.isEmpty {
                Text(viewModel.alertBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(viewModel.severityColor.opacity(0.08))
    }

    // MARK: - Model Warmup View

    private var modelWarmupView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: viewModel.modelProgress)
                .progressViewStyle(.linear)
                .frame(width: 200)

            Text(viewModel.modelStatusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Loading AI models for offline voice assistance…")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mic Permission Denied View

    private var micPermissionDeniedView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Microphone Access Required")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Ask the Alert needs microphone access so you can ask questions about the emergency alert using your voice.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Voice Interaction Area

    private var voiceInteractionArea: some View {
        VStack(spacing: 12) {
            // Waveform — responds to audio input level when listening,
            // shows gentle animation when agent is speaking.
            VoiceWaveformView(
                isListening: viewModel.isListening,
                audioLevel: viewModel.audioLevel,
                isSpeaking: viewModel.isSpeaking
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            // State indicator
            voiceStateIndicator
        }
    }

    private var voiceStateIndicator: some View {
        HStack(spacing: 8) {
            switch viewModel.voiceState {
            case .listening:
                PulsingDot(color: .blue)
                Text("Listening…")
                    .font(.caption)
                    .foregroundStyle(.blue)
            case .transcribing:
                ProgressView()
                    .scaleEffect(0.7)
                Text("Processing speech…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .thinking:
                ProgressView()
                    .scaleEffect(0.7)
                Text("Thinking…")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .speaking:
                PulsingDot(color: .green)
                Text("Speaking…")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .warmingUp:
                ProgressView()
                    .scaleEffect(0.7)
                Text("Warming up…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            default:
                Text("Tap microphone to start")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 24) {
            // Repeat last response
            Button(action: {
                viewModel.repeatLastResponse()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3)
                    Text("Repeat")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .disabled(viewModel.phase != .active)

            // Main mic toggle
            Button(action: {
                viewModel.toggleListening()
            }) {
                ZStack {
                    Circle()
                        .fill(micButtonColor)
                        .frame(width: 72, height: 72)
                        .shadow(color: micButtonColor.opacity(0.3), radius: 8)

                    if viewModel.voiceState == .transcribing || viewModel.voiceState == .thinking {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: micButtonIcon)
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(viewModel.phase == .preparingModels)
            .accessibilityLabel(viewModel.isListening ? "Stop listening" : "Start listening")

            // 911 Emergency Call
            Button(action: {
                viewModel.call911()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "phone.fill")
                        .font(.title3)
                    Text("Call 911")
                        .font(.caption2)
                }
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
    }

    private var micButtonColor: Color {
        switch viewModel.phase {
        case .preparingModels:
            return .gray
        case .active:
            if viewModel.isListening {
                return .red
            } else if viewModel.isSpeaking {
                return .green
            } else {
                return .blue
            }
        case .ended:
            return .blue
        case .starting:
            return .orange
        }
    }

    private var micButtonIcon: String {
        if viewModel.isListening {
            return "mic.fill"
        } else if viewModel.isSpeaking {
            return "speaker.wave.2.fill"
        } else if viewModel.phase == .ended {
            return "mic.slash.fill"
        } else {
            return "mic.fill"
        }
    }

    // MARK: - 911 Confirmation Overlay

    private var call911ConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.showCall911Sheet = false
                }

            VStack(spacing: 20) {
                Image(systemName: "phone.fill.arrow.up.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)

                Text("Call 911?")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("This will open your phone dialer to call emergency services.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    Button("Cancel") {
                        viewModel.showCall911Sheet = false
                    }
                    .buttonStyle(.bordered)

                    Button("Call 911") {
                        viewModel.confirmCall911()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
                    .shadow(radius: 20)
            )
            .padding(40)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button(action: { viewModel.errorMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemYellow).opacity(0.15))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut, value: viewModel.errorMessage)
    }
}

// MARK: - Pulsing Dot (State Indicator)

struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview

#Preview {
    IncidentView(
        incidentCode: "TOR-2026-0214-001",
        alert: AlertModel(
            incidentCode: "TOR-2026-0214-001",
            title: "Tornado Warning — Waterloo Region",
            severity: .critical,
            body: "Take shelter immediately. Move to an interior room on the lowest floor.",
            region: "Waterloo Region",
            timestamp: "2026-02-14T12:00:00Z"
        )
    )
    .environmentObject(AppState())
}
