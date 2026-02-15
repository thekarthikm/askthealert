/**
 * AppDelegate — Handles APNs registration and push notification delivery.
 *
 * Responsibilities:
 * 1. Request notification permission on first launch.
 * 2. Register device token with backend POST /devices.
 * 3. Handle incoming push payloads and route to the appropriate view.
 * 4. Parse alert/update payloads and forward to AppState.
 * 5. Handle foreground vs background push semantics.
 * 6. Initialize services early: RunAnywhere SDK, RAG corpus, NetworkMonitor.
 *
 * Phase 6 enhancements:
 * - Initialize NetworkMonitor for connectivity awareness
 * - Flush telemetry on app termination
 * - Improved push payload parsing with fallback defaults
 */

import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission(application: application)

        // Initialize NetworkMonitor early for connectivity awareness
        Task { @MainActor in
            _ = NetworkMonitor.shared
        }

        // NOTE: RunAnywhere SDK and model loading is handled by AskTheAlertApp.swift:
        // - First launch: SetupView runs performFirstTimeSetup() (downloads + caches models)
        // - Subsequent launches: ContentView.task runs loadCachedModels() (fast, from cache)
        // Do NOT initialize or load models here to avoid duplicate work.

        // Pre-load RAG corpus at startup so it's ready before the first incident
        Task.detached(priority: .utility) {
            await RAGService.shared.loadOfflineCorpus()
        }

        // Check if app was launched from a notification
        if let remoteNotification = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            handlePushPayload(remoteNotification)
        }

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Flush telemetry before termination
        // Note: This is best-effort; iOS gives limited time here
        Task {
            await TelemetryService.shared.flushNow()
        }
    }

    // MARK: - Permission

    private func requestNotificationPermission(application: UIApplication) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("⚠️ Notification permission error: \(error.localizedDescription)")
                return
            }
            guard granted else {
                print("⚠️ Notification permission denied")
                // Post notification so UI can react
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .notificationPermissionDenied,
                        object: nil
                    )
                }
                return
            }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
    }

    // MARK: - Token Registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("📱 APNs device token: \(tokenString)")

        // Register with backend (with retry and persistence)
        Task {
            await PushNotificationService.shared.registerDeviceToken(tokenString)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("❌ Failed to register for remote notifications: \(error.localizedDescription)")
        #if targetEnvironment(simulator)
        print("ℹ️ Push notifications are not supported in the simulator. Use a real device for demo.")
        #endif
    }

    // MARK: - Foreground Notification Handling

    /// Called when a push arrives while the app is in the foreground.
    /// Show banner + sound, AND route the payload to the active incident or create a new one.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let type = userInfo["type"] as? String ?? "alert"

        if type == "update" {
            // Updates are handled silently — route to active incident
            completionHandler([.sound])
        } else {
            // Alerts show banner + sound
            completionHandler([.banner, .sound])
        }

        // Route the push payload
        handlePushPayload(userInfo)
    }

    // MARK: - Tap on Notification (Background → Foreground)

    /// Called when the user taps a notification to open the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        handlePushPayload(userInfo)
        completionHandler()
    }

    // MARK: - Silent Push (Background Fetch)

    /// Handle silent pushes for background processing.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Record telemetry for received event
        if let incidentCode = userInfo["incidentCode"] as? String {
            TelemetryService.shared.recordEvent(
                incidentCode: incidentCode,
                eventType: .received
            )
        }

        handlePushPayload(userInfo)
        completionHandler(.newData)
    }

    // MARK: - Payload Routing

    private func handlePushPayload(_ userInfo: [AnyHashable: Any]) {
        guard let incidentCode = userInfo["incidentCode"] as? String else { return }
        let type = userInfo["type"] as? String ?? "alert"

        // Parse the full alert model from the payload
        let alert = AlertModel.fromPushPayload(userInfo)

        // Record telemetry
        TelemetryService.shared.recordEvent(
            incidentCode: incidentCode,
            eventType: .received
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .didReceivePushNotification,
                object: nil,
                userInfo: [
                    "incidentCode": incidentCode,
                    "type": type,
                    "alert": alert as Any,
                    "updateText": userInfo["updateText"] as Any,
                ]
            )
        }
    }
}

// MARK: - Notification Name Extensions

extension Notification.Name {
    static let didReceivePushNotification = Notification.Name("didReceivePushNotification")
    static let notificationPermissionDenied = Notification.Name("notificationPermissionDenied")
}
