/**
 * POST /alerts — Send an alert push notification to registered devices.
 *
 * Called by the Authority Console to create a new incident and push to citizens.
 * Supports targeting: "all", specific device tokens, or a label filter.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";
import { sendAlertPush } from "../services/apns.js";
import type { AlertPushPayload } from "@askthealert/shared";

export const alertsRouter = Router();

const createAlertSchema = z.object({
  incidentCode: z.string().min(1),
  title: z.string().min(1),
  severity: z.enum(["info", "warning", "critical"]),
  body: z.string().min(1),
  region: z.string().min(1),
  /** "all" | array of device tokens | { label: string } */
  targeting: z.union([
    z.literal("all"),
    z.array(z.string().min(1)),
    z.object({ label: z.string().min(1) }),
  ]),
});

alertsRouter.post("/", async (req, res) => {
  const parsed = createAlertSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request", details: parsed.error.issues });
    return;
  }

  const { incidentCode, title, severity, body, region, targeting } = parsed.data;
  const supabase = getSupabase();
  const timestamp = new Date().toISOString();

  // 1. Store the alert in Supabase (upsert so retries after push failure don't break)
  const { error: alertError } = await supabase.from("alerts").upsert(
    {
      incident_code: incidentCode,
      title,
      severity,
      body,
      region,
      timestamp,
    },
    { onConflict: "incident_code" }
  );
  if (alertError) {
    console.error("Failed to store alert:", alertError);
    res.status(500).json({ error: "Failed to store alert" });
    return;
  }

  // 2. Resolve target device tokens
  let query = supabase
    .from("devices")
    .select("device_token")
    .eq("invalidated", false);

  if (Array.isArray(targeting)) {
    query = query.in("device_token", targeting);
  } else if (typeof targeting === "object" && "label" in targeting) {
    query = query.eq("label", targeting.label);
  }
  // "all" → no additional filter

  const { data: devices, error: devicesError } = await query;
  if (devicesError) {
    console.error("Failed to fetch devices:", devicesError);
    res.status(500).json({ error: "Failed to fetch devices" });
    return;
  }

  const tokens = (devices ?? []).map((d) => d.device_token as string);
  if (tokens.length === 0) {
    res.status(200).json({ sent: 0, message: "No devices to notify" });
    return;
  }

  // 3. Send push
  const payload: AlertPushPayload = {
    incidentCode,
    title,
    body,
    severity,
    type: "alert",
  };
  console.log(`📤 Sending push to ${tokens.length} device(s) for incident ${incidentCode}`);
  let results;
  try {
    results = await sendAlertPush(tokens, payload);
  } catch (pushError) {
    console.error("❌ APNs push threw an exception:", pushError);
    res.status(500).json({ error: "Push notification delivery failed", details: String(pushError) });
    return;
  }

  // Log every result for debugging
  for (const r of results) {
    if (r.success) {
      console.log(`  ✅ Push delivered to ${r.deviceToken.slice(0, 8)}…`);
    } else {
      console.error(`  ❌ Push FAILED for ${r.deviceToken.slice(0, 8)}… reason: ${r.reason}`);
    }
  }

  // 4. Prune invalid tokens
  const toPrune = results.filter((r) => r.shouldPrune).map((r) => r.deviceToken);
  if (toPrune.length > 0) {
    await supabase
      .from("devices")
      .update({ invalidated: true, updated_at: new Date().toISOString() })
      .in("device_token", toPrune);
    console.log(`Pruned ${toPrune.length} invalid device token(s)`);
  }

  const sentCount = results.filter((r) => r.success).length;
  const failedCount = results.filter((r) => !r.success).length;
  console.log(`📊 Push results: ${sentCount} sent, ${failedCount} failed, ${toPrune.length} pruned`);
  res.status(200).json({ sent: sentCount, total: tokens.length, pruned: toPrune.length });
});
