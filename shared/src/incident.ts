/**
 * Incident — represents an active or historical incident (aggregates alerts + updates).
 *
 * Used by backend and Authority Console.
 */

import type { Alert } from "./alert.js";
import type { Update } from "./update.js";

/** Status of an incident from the authority's perspective. */
export type IncidentStatus = "active" | "resolved" | "archived";

/** An incident record. */
export interface Incident {
  /** Unique incident identifier (matches Alert.incidentCode). */
  incidentCode: string;

  /** Current status. */
  status: IncidentStatus;

  /** The original alert that created this incident. */
  alert: Alert;

  /** Ordered list of follow-up updates (newest last). */
  updates: Update[];

  /** ISO 8601 timestamp when the incident was created. */
  createdAt: string;

  /** ISO 8601 timestamp of the most recent activity. */
  lastActivityAt: string;
}
