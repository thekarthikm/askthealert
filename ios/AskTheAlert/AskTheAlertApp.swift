/**
 * AskTheAlertApp — Main app entry point.
 *
 * - Registers for remote notifications on launch.
 * - Sets up the AppDelegate for APNs token and push handling.
 * - Initializes RunAnywhere SDK for model downloading.
 * - Deep-links incoming alert pushes to IncidentView.
 * - Monitors scene phase for background telemetry flush.
 *
 * Phase 6 enhancement:
 * - Scene phase monitoring for telemetry flush on background
 * - NetworkMonitor initialization via environment object
 */

import SwiftUI

@main
struct AskTheAlertApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(networkMonitor)
                .onOpenURL { url in
                    // Handle deep links: askthealert://incident/{incidentCode}
                    if url.scheme == "askthealert",
                       url.host == "incident",
                       let code = url.pathComponents.dropFirst().first {
                        appState.navigateToIncident(code: String(code))
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Flush telemetry when app goes to background
                Task {
                    await TelemetryService.shared.flushNow()
                }
            case .active:
                // When returning to foreground, attempt to flush any queued telemetry
                Task {
                    await TelemetryService.shared.flushNow()
                }
            default:
                break
            }
        }
    }
}
