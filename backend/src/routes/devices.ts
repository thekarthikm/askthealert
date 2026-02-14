/**
 * POST /devices — Register an iOS device token for push notifications.
 *
 * The iOS app calls this after receiving its APNs device token.
 * Upserts on deviceToken so re-registrations update the existing record.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";

export const devicesRouter = Router();

const registerSchema = z.object({
  deviceToken: z.string().min(1),
  environment: z.enum(["development", "production"]),
  label: z.string().optional(),
});

devicesRouter.post("/", async (req, res) => {
  const parsed = registerSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request", details: parsed.error.issues });
    return;
  }

  const { deviceToken, environment, label } = parsed.data;
  const supabase = getSupabase();

  const { data, error } = await supabase
    .from("devices")
    .upsert(
      {
        device_token: deviceToken,
        environment,
        label: label ?? null,
        invalidated: false,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "device_token" }
    )
    .select()
    .single();

  if (error) {
    console.error("Device registration failed:", error);
    res.status(500).json({ error: "Registration failed" });
    return;
  }

  res.status(201).json({ device: data });
});
