/**
 * POST /updates — Publish a follow-up update for an active incident.
 *
 * Called by the Authority Console. Stores the update and pushes to all
 * devices that received the original alert.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";
import { sendUpdatePush } from "../services/apns.js";
import type { UpdatePushPayload } from "@askthealert/shared";

export const updatesRouter = Router();

const createUpdateSchema = z.object({
  incidentCode: z.string().min(1),
  updateText: z.string().min(1),
  source: z.enum(["broadcast", "authority_console"]).default("authority_console"),
});

updatesRouter.post("/", async (req, res) => {
  const parsed = createUpdateSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request", details: parsed.error.issues });
    return;
  }

  const { incidentCode, updateText, source } = parsed.data;
  const supabase = getSupabase();
  const timestamp = new Date().toISOString();

  // 1. Store the update
  const { error: updateError } = await supabase.from("updates").insert({
    incident_code: incidentCode,
    update_text: updateText,
    timestamp,
    source,
  });
  if (updateError) {
    console.error("Failed to store update:", updateError);
    res.status(500).json({ error: "Failed to store update" });
    return;
  }

  // 2. Get all valid device tokens
  const { data: devices, error: devicesError } = await supabase
    .from("devices")
    .select("device_token")
    .eq("invalidated", false);

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
  const payload: UpdatePushPayload = {
    incidentCode,
    updateText,
    type: "update",
  };
  const results = await sendUpdatePush(tokens, payload);

  // 4. Prune invalid tokens
  const toPrune = results.filter((r) => r.shouldPrune).map((r) => r.deviceToken);
  if (toPrune.length > 0) {
    await supabase
      .from("devices")
      .update({ invalidated: true, updated_at: new Date().toISOString() })
      .in("device_token", toPrune);
  }

  const sentCount = results.filter((r) => r.success).length;
  res.status(200).json({ sent: sentCount, total: tokens.length, pruned: toPrune.length });
});
