/**
 * APNs push sender — uses @parse/node-apn with token-based authentication.
 *
 * Creates ONE Provider per process (per the library's recommendation).
 * Supports dev vs prod APNs environment via APNS_ENVIRONMENT env var.
 * Token hygiene: callers should prune tokens when APNs reports them invalid.
 */

import apn from "@parse/node-apn";
import { env } from "../config/env.js";
import type { AlertPushPayload, UpdatePushPayload } from "@askthealert/shared";

let _provider: apn.Provider | null = null;

/** Lazily initialise the APNs provider. */
function getProvider(): apn.Provider {
  if (!_provider) {
    _provider = new apn.Provider({
      token: {
        key: env.APNS_KEY_PATH,
        keyId: env.APNS_KEY_ID,
        teamId: env.APNS_TEAM_ID,
      },
      production: env.APNS_ENVIRONMENT === "production",
    });
  }
  return _provider;
}

/** Result of a push send attempt for a single device token. */
export interface PushSendResult {
  deviceToken: string;
  success: boolean;
  /** Present when APNs rejected the push. */
  reason?: string;
  /** If status 410 (Unregistered), this token should be pruned. */
  shouldPrune: boolean;
}

/**
 * Send an alert push notification to a list of device tokens.
 *
 * Returns per-token results so the caller can prune invalid tokens.
 */
export async function sendAlertPush(
  deviceTokens: string[],
  payload: AlertPushPayload
): Promise<PushSendResult[]> {
  const note = new apn.Notification();
  note.expiry = Math.floor(Date.now() / 1000) + 3600; // 1 hour
  note.sound = "default";
  note.alert = { title: payload.title, body: payload.body };
  note.topic = env.APNS_BUNDLE_ID;
  note.payload = {
    incidentCode: payload.incidentCode,
    severity: payload.severity,
    type: payload.type,
  };
  // High priority for alerts
  note.priority = 10;
  note.pushType = "alert";

  return sendNotification(deviceTokens, note);
}

/**
 * Send an update push notification to a list of device tokens.
 */
export async function sendUpdatePush(
  deviceTokens: string[],
  payload: UpdatePushPayload
): Promise<PushSendResult[]> {
  const note = new apn.Notification();
  note.expiry = Math.floor(Date.now() / 1000) + 3600;
  note.sound = "default";
  note.alert = { title: "Update", body: payload.updateText };
  note.topic = env.APNS_BUNDLE_ID;
  note.payload = {
    incidentCode: payload.incidentCode,
    updateText: payload.updateText,
    type: payload.type,
  };
  note.priority = 10;
  note.pushType = "alert";

  return sendNotification(deviceTokens, note);
}

/** Shared send logic with per-token result mapping. */
async function sendNotification(
  deviceTokens: string[],
  note: apn.Notification
): Promise<PushSendResult[]> {
  const provider = getProvider();
  const response = await provider.send(note, deviceTokens);

  const results: PushSendResult[] = [];

  for (const sent of response.sent) {
    results.push({
      deviceToken: sent.device,
      success: true,
      shouldPrune: false,
    });
  }

  for (const failed of response.failed) {
    const reason = failed.response?.reason ?? "Unknown";
    const status = failed.status;
    results.push({
      deviceToken: failed.device,
      success: false,
      reason,
      // Status 410 = Unregistered — token should be pruned
      shouldPrune: status === 410 || String(status) === "410" || reason === "Unregistered",
    });
  }

  return results;
}

/** Graceful shutdown — release APNs connection. */
export function shutdownApns(): void {
  if (_provider) {
    _provider.shutdown();
    _provider = null;
  }
}
