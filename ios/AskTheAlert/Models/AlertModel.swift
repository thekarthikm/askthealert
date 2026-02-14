/**
 * AlertModel — Swift mirror of the shared Alert type.
 *
 * Codable for JSON decoding from push payloads and API responses.
 */

import Foundation

/// Severity levels matching the backend.
enum AlertSeverity: String, Codable, CaseIterable {
    case info
    case warning
    case critical
}

/// An alert issued by authorities via push notification.
struct AlertModel: Identifiable, Codable, Equatable {
    let incidentCode: String
    let title: String
    let severity: AlertSeverity
    let body: String
    let region: String
    let timestamp: String

    var id: String { incidentCode }

    /// Parse from APNs push payload (custom data portion).
    static func fromPushPayload(_ userInfo: [AnyHashable: Any]) -> AlertModel? {
        guard let incidentCode = userInfo["incidentCode"] as? String else {
            return nil
        }

        // Try to get title from custom payload or aps.alert
        let customTitle = userInfo["title"] as? String
        let apsAlert = (userInfo["aps"] as? [String: Any])?["alert"]
        let apsTitle: String? = {
            if let alertDict = apsAlert as? [String: Any] {
                return alertDict["title"] as? String
            }
            return nil
        }()
        guard let title = customTitle ?? apsTitle else { return nil }

        let severityString = userInfo["severity"] as? String ?? "warning"
        let severity = AlertSeverity(rawValue: severityString) ?? .warning

        let customBody = userInfo["body"] as? String
        let apsBody: String? = {
            if let alertDict = apsAlert as? [String: Any] {
                return alertDict["body"] as? String
            }
            return nil
        }()
        let body = customBody ?? apsBody ?? ""

        return AlertModel(
            incidentCode: incidentCode,
            title: title,
            severity: severity,
            body: body,
            region: userInfo["region"] as? String ?? "Unknown",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
