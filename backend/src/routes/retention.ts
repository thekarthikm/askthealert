/**
 * POST /admin/retention/rollup — Execute telemetry retention rollup.
 *
 * Rolls up old telemetry events into daily summaries and deletes the
 * raw events. This keeps the telemetry_events table lean while preserving
 * aggregate statistics in telemetry_daily_rollup.
 *
 * Can be called:
 *   - Manually from the Authority Console admin panel
 *   - Via a cron job (e.g. pg_cron or external scheduler)
 *   - On demand for maintenance
 *
 * GET  /admin/retention/stats — View current retention statistics.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";

export const retentionRouter = Router();

const rollupSchema = z.object({
  /** Number of days to keep raw telemetry. Default 30. */
  daysToKeep: z.coerce.number().int().min(1).max(365).default(30),
});

/**
 * POST /admin/retention/rollup
 *
 * Execute the telemetry rollup: aggregate events older than N days
 * into daily summaries, then delete the raw events.
 */
retentionRouter.post("/rollup", async (req, res) => {
  const parsed = rollupSchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request", details: parsed.error.issues });
    return;
  }

  const { daysToKeep } = parsed.data;
  const supabase = getSupabase();

  try {
    const { data, error } = await supabase.rpc("rollup_telemetry", {
      days_to_keep: daysToKeep,
    });

    if (error) {
      console.error("Retention rollup failed:", error);
      res.status(500).json({ error: "Rollup failed", details: error.message });
      return;
    }

    const result = Array.isArray(data) && data.length > 0 ? data[0] : data;

    res.status(200).json({
      success: true,
      daysToKeep,
      rolledUp: result?.rolled_up ?? 0,
      deleted: result?.deleted ?? 0,
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    console.error("Retention rollup error:", err);
    res.status(500).json({ error: "Rollup failed" });
  }
});

/**
 * GET /admin/retention/stats
 *
 * Returns current retention statistics:
 *   - Total raw events
 *   - Oldest raw event
 *   - Total rollup records
 *   - Rollup date range
 */
retentionRouter.get("/stats", async (_req, res) => {
  const supabase = getSupabase();

  try {
    // Raw event count and oldest timestamp
    const { data: rawStats, error: rawErr } = await supabase
      .from("telemetry_events")
      .select("server_timestamp")
      .order("server_timestamp", { ascending: true })
      .limit(1);

    const { count: rawCount } = await supabase
      .from("telemetry_events")
      .select("*", { count: "exact", head: true });

    // Rollup count
    const { count: rollupCount } = await supabase
      .from("telemetry_daily_rollup")
      .select("*", { count: "exact", head: true });

    // Rollup date range
    const { data: rollupRange } = await supabase
      .from("telemetry_daily_rollup")
      .select("event_date")
      .order("event_date", { ascending: true })
      .limit(1);

    const { data: rollupRangeEnd } = await supabase
      .from("telemetry_daily_rollup")
      .select("event_date")
      .order("event_date", { ascending: false })
      .limit(1);

    res.status(200).json({
      rawEvents: {
        count: rawCount ?? 0,
        oldestTimestamp: rawStats?.[0]?.server_timestamp ?? null,
      },
      rollup: {
        count: rollupCount ?? 0,
        dateRange: {
          start: rollupRange?.[0]?.event_date ?? null,
          end: rollupRangeEnd?.[0]?.event_date ?? null,
        },
      },
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    console.error("Retention stats error:", err);
    res.status(500).json({ error: "Failed to fetch retention stats" });
  }
});
