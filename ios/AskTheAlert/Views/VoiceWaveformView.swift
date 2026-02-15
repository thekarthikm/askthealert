/**
 * VoiceWaveformView — Animated audio waveform visualization.
 *
 * Shows a pulsing waveform when the voice agent is listening.
 * Shows a gentle wave when the agent is speaking.
 * Shows minimal bars when idle.
 * Responds to audioLevel (0.0–1.0) for visual feedback.
 */

import SwiftUI

struct VoiceWaveformView: View {
    let isListening: Bool
    let audioLevel: Float

    /// Optional: whether the agent is currently speaking (shows different animation).
    var isSpeaking: Bool = false

    /// Number of bars in the waveform.
    private let barCount = 40

    @State private var phases: [Double] = []

    /// SwiftUI-native timer that stays on the MainActor (Swift 6 safe).
    private let animationTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(
                            width: barWidth(totalWidth: geometry.size.width),
                            height: barHeight(index: index, totalHeight: geometry.size.height)
                        )
                        .animation(
                            .easeInOut(duration: 0.12),
                            value: isListening
                        )
                        .animation(
                            .easeInOut(duration: 0.08),
                            value: audioLevel
                        )
                        .animation(
                            .easeInOut(duration: 0.15),
                            value: isSpeaking
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            phases = (0..<barCount).map { _ in Double.random(in: 0...1) }
        }
        .onReceive(animationTimer) { _ in
            updatePhases()
        }
    }

    private var barColor: Color {
        if isListening {
            return .blue
        } else if isSpeaking {
            return .green
        } else {
            return .gray.opacity(0.3)
        }
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        let spacing = CGFloat(barCount - 1) * 2
        return max(2, (totalWidth - spacing) / CGFloat(barCount))
    }

    private func barHeight(index: Int, totalHeight: CGFloat) -> CGFloat {
        let phase = phases.indices.contains(index) ? phases[index] : 0.5
        let maxHeight = totalHeight * 0.7

        if isListening {
            // Listening mode: bars respond to audio level with wave pattern
            let level = CGFloat(audioLevel)
            let normalised = sin(phase * .pi) * level
            let height = maxHeight * 0.1 + maxHeight * 0.9 * normalised
            return max(4, height)
        } else if isSpeaking {
            // Speaking mode: gentle sine wave animation (no user audio level)
            let normalised = sin(phase * .pi) * 0.4 + 0.3
            let height = maxHeight * normalised
            return max(4, height)
        } else {
            // Idle state: minimal bars
            return 4
        }
    }

    private func updatePhases() {
        for i in phases.indices {
            if isSpeaking {
                phases[i] += Double.random(in: 0.03...0.08)
            } else {
                phases[i] += Double.random(in: 0.05...0.15)
            }
            if phases[i] > 2.0 { phases[i] = 0 }
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        VoiceWaveformView(isListening: false, audioLevel: 0)
            .frame(height: 100)
            .padding()

        VoiceWaveformView(isListening: true, audioLevel: 0.6)
            .frame(height: 100)
            .padding()

        VoiceWaveformView(isListening: false, audioLevel: 0, isSpeaking: true)
            .frame(height: 100)
            .padding()
    }
}
