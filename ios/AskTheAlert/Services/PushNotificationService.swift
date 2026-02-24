/**
 * PushNotificationService — Registers the device token with the backend.
 *
 * Called by AppDelegate when APNs delivers a device token.
 * Retries on failure with exponential backoff.
 *
 * Phase 6 enhancements:
 * - Persists the pending token to UserDefaults so registration retries across app restarts
 * - Defers registration when offline and retries when connectivity is restored
 * - More robust error handling with specific HTTP status code checks
 */

import Foundation
import UIKit

actor PushNotificationService {
    static let shared = PushNotificationService()

    /// Backend base URL. In production this comes from a config; for hackathon, hardcoded.
    private static let defaultBackendURL: String = {
        #if targetEnvironment(simulator)
        return "http://localhost:3001"
        #else
        return "http://your-mac-hostname.local:3001"  // Replace with your Mac's mDNS hostname
        #endif
    }()

    private let baseURL: String = {
        if let configured = ProcessInfo.processInfo.environment["API_BASE_URL"], !configured.isEmpty {
            return configured
        }
        return Self.defaultBackendURL
    }()

    private static let pendingTokenKey = "askthealert_pending_device_token"
    private static let registeredTokenKey = "askthealert_registered_device_token"

    private var registeredToken: String?
    private var retryCount = 0
    private let maxRetries = 10

    init() {
        // Load previously registered token (inline, nonisolated-safe for Swift 6)
        let storedToken = UserDefaults.standard.string(forKey: Self.registeredTokenKey)
        let pendingToken = UserDefaults.standard.string(forKey: Self.pendingTokenKey)
        registeredToken = storedToken

        // Check if there's a pending token from a previous failed registration
        if let pending = pendingToken, pending != storedToken {
            Task {
                print("📱 Retrying pending device token registration")
                await self.registerDeviceToken(pending)
            }
        }
    }

    /// Register the device token with the backend.
    func registerDeviceToken(_ token: String) async {
        // Don't re-register the same token
        if token == registeredToken { return }

        // Persist the pending token so we can retry after app restart
        UserDefaults.standard.set(token, forKey: Self.pendingTokenKey)

        let url = URL(string: "\(baseURL)/devices")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif

        let deviceName = await MainActor.run { UIDevice.current.name }
        let body: [String: Any] = [
            "deviceToken": token,
            "environment": environment,
            "label": deviceName,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            let session = URLSession(configuration: config)

            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200...299:
                    registeredToken = token
                    retryCount = 0
                    UserDefaults.standard.set(token, forKey: Self.registeredTokenKey)
                    UserDefaults.standard.removeObject(forKey: Self.pendingTokenKey)
                    print("✅ Device token registered with backend")

                case 409:
                    // Conflict — token already registered, treat as success
                    registeredToken = token
                    retryCount = 0
                    UserDefaults.standard.set(token, forKey: Self.registeredTokenKey)
                    UserDefaults.standard.removeObject(forKey: Self.pendingTokenKey)
                    print("✅ Device token already registered (409 conflict)")

                default:
                    print("⚠️ Device registration returned HTTP \(httpResponse.statusCode)")
                    await retryRegistration(token)
                }
            }
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorNotConnectedToInternet ||
               nsError.code == NSURLErrorNetworkConnectionLost {
                print("📡 Device registration deferred (offline) — will retry when online")
                // Don't increment retry count for offline errors
            } else {
                print("❌ Device registration failed: \(error.localizedDescription)")
                await retryRegistration(token)
            }
        }
    }

    private func retryRegistration(_ token: String) async {
        guard retryCount < maxRetries else {
            print("❌ Max retries (\(maxRetries)) reached for device registration")
            retryCount = 0 // Reset for future attempts
            return
        }

        retryCount += 1
        let delay = UInt64(min(pow(2.0, Double(retryCount)), 60)) * 1_000_000_000 // Max 60s
        print("📱 Retrying device registration in \(retryCount)s (attempt \(retryCount)/\(maxRetries))")
        try? await Task.sleep(nanoseconds: delay)
        await registerDeviceToken(token)
    }
}
