/**
 * AskTheAlertApp — Main app entry point.
 *
 * Flow:
 * 1. First launch after install → SetupView (downloads AI models, one-time only)
 * 2. Every subsequent launch → ContentView (models load from cache, near-instant)
 * 3. Push notification arrives → IncidentView (voice agent starts immediately)
 *
 * Models are downloaded ONCE at first launch and cached permanently on disk.
 * The SetupView never appears again after the initial setup completes.
 */

import SwiftUI

@main
struct AskTheAlertApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var runAnywhereManager = RunAnywhereManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if runAnywhereManager.setupComplete {
                    // Normal app — models already cached from first launch
                    ContentView()
                        .environmentObject(appState)
                        .environmentObject(networkMonitor)
                        .onOpenURL { url in
                            if url.scheme == "askthealert",
                               url.host == "incident",
                               let code = url.pathComponents.dropFirst().first {
                                appState.navigateToIncident(code: String(code))
                            }
                        }
                        .task {
                            // Load cached models into memory (fast, no download)
                            await runAnywhereManager.loadCachedModels()
                        }
                } else {
                    // First launch after install — one-time model download
                    SetupView()
                        .environmentObject(runAnywhereManager)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                Task { await TelemetryService.shared.flushNow() }
            case .active:
                Task { await TelemetryService.shared.flushNow() }
            default:
                break
            }
        }
    }
}
