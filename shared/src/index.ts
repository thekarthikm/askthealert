/**
 * @askthealert/shared — canonical types shared across backend, Authority Console, and iOS.
 *
 * Import from this barrel:
 *   import { Alert, TelemetryEvent, IntentCategory, ... } from "@askthealert/shared";
 */

// Alert
export type { Alert, AlertSeverity, AlertPushPayload } from "./alert.js";

// Update
export type { Update, UpdateSource, UpdatePushPayload } from "./update.js";

// Telemetry
export type {
  TelemetryEvent,
  TelemetryEventType,
  TelemetryPayload,
  StoredTelemetryEvent,
} from "./telemetry-event.js";

// Intent grouping
export type { IntentCategory, IntentCluster } from "./intent.js";
export { INTENT_LABELS } from "./intent.js";

// Device registration
export type {
  DeviceRegistrationRequest,
  Device,
} from "./device.js";

// Incident
export type { Incident, IncidentStatus } from "./incident.js";
