/**
 * TelemetryEvent — Swift mirror of the shared TelemetryEvent type.
 *
 * Events are queued locally via CoreData (SQLite-backed under the hood)
 * and uploaded in batches to POST /telemetry.
 *
 * eventId is client-generated UUID for idempotency — the server dedupes.
 */

import Foundation

/// Possible event types.
enum TelemetryEventType: String, Codable {
    case received
    case opened
    case spoke
    case question
    case satisfaction
}

/// Situational blockers reported by citizens.
enum ActionBlocker: String, Codable {
    case driving
    case condo
    case kids
    case disability
}

/// Telemetry event payload fields (varies by event type).
struct TelemetryPayload: Codable, Equatable {
    var intentLabel: String?
    var shortText: String?
    var satisfactionYesNo: Bool?
    var actionBlocker: ActionBlocker?
}

/// A single telemetry event ready for upload.
struct TelemetryEventModel: Identifiable, Codable, Equatable {
    let eventId: String
    let incidentCode: String
    let eventType: TelemetryEventType
    let deviceTimestamp: String
    let payload: TelemetryPayload

    var id: String { eventId }

    /// Create a new event with auto-generated UUID and current timestamp.
    static func create(
        incidentCode: String,
        eventType: TelemetryEventType,
        payload: TelemetryPayload = TelemetryPayload()
    ) -> TelemetryEventModel {
        TelemetryEventModel(
            eventId: UUID().uuidString,
            incidentCode: incidentCode,
            eventType: eventType,
            deviceTimestamp: ISO8601DateFormatter().string(from: Date()),
            payload: payload
        )
    }
}
