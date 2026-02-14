/**
 * SafetyEscalationView — 911 emergency call button and safety guardrails UI.
 *
 * Always visible during an active incident as a prominent action.
 * Provides:
 * - "Call 911" button with confirmation dialog
 * - Safety guardrails text
 * - Disclaimer that the AI cannot contact authorities
 */

import SwiftUI

struct SafetyEscalationView: View {
    @Binding var showCall911Sheet: Bool
    var onConfirmCall: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Emergency call button — always visible
            Button(action: { showCall911Sheet = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "phone.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Emergency: Call 911")
                            .font(.headline)
                        Text("If you are in immediate danger")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.red)
                )
            }

            // Guardrails disclaimer
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("This AI cannot contact authorities for you. For emergencies, call 911 directly.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Standalone 911 confirmation dialog.
struct Call911ConfirmationView: View {
    @Binding var isPresented: Bool
    var onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Warning icon
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "phone.fill.arrow.up.right")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
            }

            Text("Call 911?")
                .font(.title2)
                .fontWeight(.bold)

            Text("This will open your phone dialer to call 911 emergency services. Only call if you or someone near you is in immediate danger.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(spacing: 12) {
                Button(action: {
                    isPresented = false
                    onConfirm()
                }) {
                    Text("Call 911 Now")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.red)
                        )
                }

                Button(action: { isPresented = false }) {
                    Text("Cancel")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
    }
}

#Preview {
    VStack(spacing: 32) {
        SafetyEscalationView(
            showCall911Sheet: .constant(false),
            onConfirmCall: {}
        )
        .padding()

        Call911ConfirmationView(
            isPresented: .constant(true),
            onConfirm: {}
        )
        .padding()
    }
}
