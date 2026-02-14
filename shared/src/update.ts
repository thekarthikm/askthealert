/**
 * Update — follow-up information published by authorities for an active incident.
 *
 * Shared between backend, Authority Console, and iOS (mirrored in Swift).
 */

/** Where the update originated. */
export type UpdateSource = "broadcast" | "authority_console";

/** Canonical update payload. */
export interface Update {
  /** Incident this update belongs to. */
  incidentCode: string;

  /** The update content that will be spoken by the voice agent. */
  updateText: string;

  /** ISO 8601 timestamp of when the update was published. */
  timestamp: string;

  /** Origin of the update. */
  source: UpdateSource;
}

/**
 * Push notification payload envelope for updates sent via APNs.
 */
export interface UpdatePushPayload {
  incidentCode: string;
  updateText: string;
  type: "update";
}
