/**
 * Incident — Aggregates an alert with its updates on the iOS side.
 */

import Foundation

/// Status of an incident.
enum IncidentStatus: String, Codable {
    case active
    case resolved
    case archived
}

/// An incident representing the local state of an alert + updates.
struct IncidentModel: Identifiable, Equatable {
    let incidentCode: String
    var status: IncidentStatus
    var alert: AlertModel
    var updates: [UpdateModel]
    let createdAt: Date
    var lastActivityAt: Date

    var id: String { incidentCode }
}
