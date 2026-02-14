/**
 * Device registration types — iOS app registers its APNs token with the backend.
 *
 * Shared between backend and iOS (mirrored in Swift).
 */

/** Payload sent by iOS to POST /devices to register for push notifications. */
export interface DeviceRegistrationRequest {
  /** The APNs device token (hex string). */
  deviceToken: string;

  /** "development" or "production" — must match APNs environment. */
  environment: "development" | "production";

  /** Optional human label for demo targeting (e.g. "Karthik's iPhone"). */
  label?: string;
}

/** Stored device record in Supabase. */
export interface Device {
  /** Server-generated UUID primary key. */
  id: string;

  /** APNs device token. */
  deviceToken: string;

  /** APNs environment this token is valid for. */
  environment: "development" | "production";

  /** Optional human label. */
  label?: string;

  /** ISO 8601 timestamp of first registration. */
  createdAt: string;

  /** ISO 8601 timestamp of last registration / token refresh. */
  updatedAt: string;

  /** If true, APNs has reported this token as invalid; prune on next send. */
  invalidated: boolean;
}
