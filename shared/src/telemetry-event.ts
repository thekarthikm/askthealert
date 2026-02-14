/**
 * TelemetryEvent — anonymous usage telemetry sent from iOS to backend.
 *
 * - eventId is client-generated UUID for idempotency (at-least-once uploads).
 * - deviceTimestamp is set by the client; serverTimestamp is set on ingest.
 * - PII-minimized: no names/addresses; phone numbers redacted before storage.
 *
 * Shared between backend, Authority Console, and iOS (mirrored in Swift).
 */

/** Possible event types in the telemetry stream. */
export type TelemetryEventType =
  | "received"
  | "opened"
  | "spoke"
  | "question"
  | "satisfaction";

/** Optional payload fields that vary by event type. */
export interface TelemetryPayload {
  /** Rule-based intent label (e.g. "shelter_guidance"). Present for "question" events. */
  intentLabel?: string;

  /**
   * Normalized, PII-minimized snippet of the user's question.
   * No names/addresses; phone numbers redacted.
   * Present for "question" events.
   */
  shortText?: string;

  /** User satisfaction response. Present for "satisfaction" events. */
  satisfactionYesNo?: boolean;

  /**
   * Situational blocker the user reported (e.g. driving, in a condo).
   * Present when voice classification or UI chips identify one.
   */
  actionBlocker?: "driving" | "condo" | "kids" | "disability";
}

/** A single telemetry event. */
export interface TelemetryEvent {
  /** Client-generated UUID — server dedupes on this for idempotency. */
  eventId: string;

  /** The incident this event relates to. */
  incidentCode: string;

  /** What happened. */
  eventType: TelemetryEventType;

  /** ISO 8601 timestamp from the device clock. */
  deviceTimestamp: string;

  /** Variable payload depending on eventType. */
  payload: TelemetryPayload;
}

/**
 * Server-augmented telemetry event (after ingest).
 * Adds serverTimestamp for ordering and retention.
 */
export interface StoredTelemetryEvent extends TelemetryEvent {
  /** ISO 8601 timestamp set by the server on ingest. */
  serverTimestamp: string;
}
