/**
 * UpdateModel — Swift mirror of the shared Update type.
 */

import Foundation

/// Where the update originated.
enum UpdateSource: String, Codable {
    case broadcast
    case authorityConsole = "authority_console"
}

/// A follow-up update published by authorities.
struct UpdateModel: Identifiable, Codable, Equatable {
    let incidentCode: String
    let updateText: String
    let timestamp: String
    let source: UpdateSource

    var id: String { "\(incidentCode)_\(timestamp)" }
}
