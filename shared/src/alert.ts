/**
 * Alert — issued by authority to citizens via push notification.
 *
 * Shared between backend, Authority Console, and iOS (mirrored in Swift).
 */

/** Severity levels for an alert. */
export type AlertSeverity = "info" | "warning" | "critical";

/** Canonical alert payload. */
export interface Alert {
  /** Unique incident identifier (e.g. "TOR-2026-0214-001"). */
  incidentCode: string;

  /** Human-readable title (e.g. "Tornado Warning – Waterloo Region"). */
  title: string;

  /** Urgency level driving UI treatment and voice tone. */
  severity: AlertSeverity;

  /** Descriptive body text for the notification and voice agent context. */
  body: string;

  /** Geographic region (e.g. "Waterloo Region"). */
  region: string;

  /** ISO 8601 timestamp of when the alert was issued. */
  timestamp: string;
}

/**
 * Push notification payload envelope sent via APNs.
 * The `aps` key is added by the APNs service; this is the custom data portion.
 */
export interface AlertPushPayload {
  incidentCode: string;
  title: string;
  body: string;
  severity: AlertSeverity;
  type: "alert";
}
