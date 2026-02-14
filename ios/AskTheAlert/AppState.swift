/**
 * AppState — Observable global app state.
 *
 * Manages:
 * - Navigation (active incident)
 * - Push-driven deep links
 * - Multiple incidents (second alert while incident active)
 * - Notification permission state
 * - Model readiness state
 */

import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    /// Currently active incident code (nil when no incident is selected).
    @Published var activeIncidentCode: String? = nil

    /// Whether the incident view should be presented.
    @Published var showIncidentView: Bool = false

    /// The latest alert received via push (title + body for display).
    @Published var latestAlert: AlertModel? = nil

    /// All known incidents (supports multiple concurrent alerts).
    @Published var incidents: [String: AlertModel] = [:]

    /// Whether notification permission has been granted.
    @Published var notificationPermissionGranted: Bool = true

    /// Queue of incident codes that arrived while another incident was active.
    @Published var pendingIncidentCodes: [String] = []

    /// Whether models are ready for offline use.
    @Published var modelsReady: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Listen for push notification delivery
        NotificationCenter.default.publisher(for: .didReceivePushNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let userInfo = notification.userInfo,
                      let code = userInfo["incidentCode"] as? String else { return }

                let type = userInfo["type"] as? String ?? "alert"
                let alert = userInfo["alert"] as? AlertModel

                if type == "alert" {
                    self.handleNewAlert(code: code, alert: alert)
                }
                // Updates are handled by IncidentViewModel directly
            }
            .store(in: &cancellables)

        // Listen for notification permission denial
        NotificationCenter.default.publisher(for: .notificationPermissionDenied)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.notificationPermissionGranted = false
            }
            .store(in: &cancellables)

        // Observe model readiness
        RunAnywhereManager.shared.$status
            .receive(on: DispatchQueue.main)
            .map(\.isReady)
            .assign(to: &$modelsReady)
    }

    // MARK: - Alert Handling

    /// Handle a new alert push notification.
    private func handleNewAlert(code: String, alert: AlertModel?) {
        // Store the alert
        if let alert = alert {
            incidents[code] = alert
            latestAlert = alert
        }

        if showIncidentView && activeIncidentCode != code {
            // Another incident is already active — queue this one
            if !pendingIncidentCodes.contains(code) {
                pendingIncidentCodes.append(code)
            }
        } else {
            // Navigate to this incident
            navigateToIncident(code: code)
        }
    }

    /// Navigate to an incident (called from push, deep link, or manual navigation).
    func navigateToIncident(code: String) {
        activeIncidentCode = code
        showIncidentView = true
    }

    /// Dismiss the incident view.
    func dismissIncident() {
        showIncidentView = false

        // If there are pending incidents, show the next one
        if let nextCode = pendingIncidentCodes.first {
            pendingIncidentCodes.removeFirst()
            // Small delay so the dismiss animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.navigateToIncident(code: nextCode)
            }
        } else {
            // Keep activeIncidentCode for context; clear if needed
        }
    }

    /// Get the alert model for an incident code.
    func alertFor(incidentCode: String) -> AlertModel? {
        return incidents[incidentCode]
    }
}
