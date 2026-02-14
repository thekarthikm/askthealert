/**
 * ContentView — Root view of the app.
 *
 * Shows a minimal home screen with the app branding.
 * When a push notification arrives (or deep link), presents IncidentView
 * as a full-screen cover for the voice-first interaction.
 *
 * Also shows:
 * - Model readiness status
 * - Notification permission warning if denied
 * - Pending incidents badge
 */

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var networkMonitor: NetworkMonitor

    var body: some View {
        ZStack {
            // Background
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // App branding
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)

                Text("Ask the Alert")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Voice-first emergency information")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Status section
                VStack(spacing: 12) {
                    // Status indicators row
                    HStack(spacing: 16) {
                        // Model readiness indicator
                        modelReadinessView

                        // Network status indicator
                        networkStatusView
                    }

                    // Notification permission warning
                    if !appState.notificationPermissionGranted {
                        notificationPermissionWarning
                    }

                    // Offline warning
                    if !networkMonitor.isConnected {
                        offlineWarning
                    }

                    // Latest alert card
                    if let alert = appState.latestAlert {
                        alertCard(alert)
                    } else {
                        Text("No active alerts")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    // Pending incidents
                    if !appState.pendingIncidentCodes.isEmpty {
                        pendingIncidentsBadge
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
        }
        .fullScreenCover(isPresented: $appState.showIncidentView) {
            if let code = appState.activeIncidentCode {
                IncidentView(
                    incidentCode: code,
                    alert: appState.alertFor(incidentCode: code)
                )
                .environmentObject(appState)
            }
        }
    }

    // MARK: - Model Readiness

    private var modelReadinessView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.modelsReady ? .green : .orange)
                .frame(width: 8, height: 8)

            Text(appState.modelsReady ? "Offline Ready" : "Preparing AI Models…")
                .font(.caption)
                .foregroundStyle(appState.modelsReady ? .green : .orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(appState.modelsReady ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }

    // MARK: - Network Status

    private var networkStatusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(networkMonitor.isConnected ? .blue : .gray)
                .frame(width: 8, height: 8)

            Text(networkMonitor.connectionDescription)
                .font(.caption)
                .foregroundStyle(networkMonitor.isConnected ? .blue : .gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(networkMonitor.isConnected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
        )
    }

    // MARK: - Offline Warning

    private var offlineWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.gray)

            VStack(alignment: .leading, spacing: 2) {
                Text("Offline Mode")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Voice assistant works offline. Telemetry will sync when connected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
    }

    // MARK: - Notification Permission Warning

    private var notificationPermissionWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications Disabled")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("You won't receive emergency alerts. Enable in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Enable") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: - Alert Card

    private func alertCard(_ alert: AlertModel) -> some View {
        Button(action: {
            appState.navigateToIncident(code: alert.incidentCode)
        }) {
            VStack(spacing: 4) {
                HStack {
                    Circle()
                        .fill(severityColor(alert.severity))
                        .frame(width: 8, height: 8)
                    Text(alert.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(alert.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(severityColor(alert.severity).opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pending Incidents Badge

    private var pendingIncidentsBadge: some View {
        HStack {
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(.red)
            Text("\(appState.pendingIncidentCodes.count) more alert\(appState.pendingIncidentCodes.count > 1 ? "s" : "") pending")
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.red.opacity(0.1))
        )
    }

    // MARK: - Helpers

    private func severityColor(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(NetworkMonitor.shared)
}
