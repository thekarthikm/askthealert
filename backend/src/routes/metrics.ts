/**
 * GET /metrics/:incidentCode — Aggregate telemetry metrics for an incident.
 * GET /metrics/:incidentCode/timeline — Hourly timeline of events.
 *
 * Provides the data backing the Authority Console dashboard.
 * These are point-in-time snapshots (use SSE /stream for real-time).
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";

export const metricsRouter = Router();

const paramsSchema = z.object({
  incidentCode: z.string().min(1),
});

/**
 * GET /metrics/:incidentCode
 *
 * Returns aggregate metrics for the Authority Console dashboard:
 *   - Event counts by type
 *   - Satisfaction breakdown
 *   - Action blocker breakdown
 *   - Active devices (unique question senders)
 *   - First/last event timestamps
 */
metricsRouter.get("/:incidentCode", async (req, res) => {
  const paramParsed = paramsSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;
  const supabase = getSupabase();

  try {
    // All events for this incident
    const { data: events } = await supabase
      .from("telemetry_events")
      .select("event_type, satisfaction_yes_no, action_blocker, server_timestamp")
      .eq("incident_code", incidentCode)
      .order("server_timestamp", { ascending: true });

    if (!events || events.length === 0) {
      res.status(200).json({
        incidentCode,
        counts: { received: 0, opened: 0, spoke: 0, questions: 0, satisfaction: 0 },
        satisfactionBreakdown: { yes: 0, no: 0, rate: null },
        actionBlockers: {},
        timeRange: { first: null, last: null },
        totalEvents: 0,
        timestamp: new Date().toISOString(),
      });
      return;
    }

    const counts: Record<string, number> = {
      received: 0, opened: 0, spoke: 0, questions: 0, satisfaction: 0,
    };
    let satYes = 0;
    let satNo = 0;
    const blockers: Record<string, number> = {};

    for (const evt of events) {
      const type = evt.event_type as string;
      if (type === "question") counts.questions++;
      else if (type in counts) counts[type]++;

      if (type === "satisfaction" && evt.satisfaction_yes_no !== null) {
        if (evt.satisfaction_yes_no) satYes++;
        else satNo++;
      }

      if (evt.action_blocker) {
        blockers[evt.action_blocker] = (blockers[evt.action_blocker] ?? 0) + 1;
      }
    }

    const satTotal = satYes + satNo;

    // Alert info
    const { data: alert } = await supabase
      .from("alerts")
      .select("title, severity, region, timestamp")
      .eq("incident_code", incidentCode)
      .single();

    // Update count
    const { count: updateCount } = await supabase
      .from("updates")
      .select("*", { count: "exact", head: true })
      .eq("incident_code", incidentCode);

    res.status(200).json({
      incidentCode,
      alert: alert ?? null,
      counts,
      satisfactionBreakdown: {
        yes: satYes,
        no: satNo,
        rate: satTotal > 0 ? Math.round((satYes / satTotal) * 100) : null,
      },
      actionBlockers: blockers,
      updateCount: updateCount ?? 0,
      timeRange: {
        first: events[0].server_timestamp,
        last: events[events.length - 1].server_timestamp,
      },
      totalEvents: events.length,
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    console.error("Metrics error:", err);
    res.status(500).json({ error: "Failed to fetch metrics" });
  }
});

/**
 * GET /metrics/:incidentCode/timeline
 *
 * Returns hourly event counts for timeline visualization.
 */
metricsRouter.get("/:incidentCode/timeline", async (req, res) => {
  const paramParsed = paramsSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;
  const supabase = getSupabase();

  try {
    const { data: events } = await supabase
      .from("telemetry_events")
      .select("event_type, server_timestamp")
      .eq("incident_code", incidentCode)
      .order("server_timestamp", { ascending: true });

    if (!events || events.length === 0) {
      res.status(200).json({ incidentCode, timeline: [] });
      return;
    }

    // Group by hour
    const hourlyBuckets = new Map<string, Record<string, number>>();

    for (const evt of events) {
      const date = new Date(evt.server_timestamp);
      const hourKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}T${String(date.getHours()).padStart(2, "0")}:00:00`;

      if (!hourlyBuckets.has(hourKey)) {
        hourlyBuckets.set(hourKey, { received: 0, opened: 0, spoke: 0, questions: 0, satisfaction: 0 });
      }

      const bucket = hourlyBuckets.get(hourKey)!;
      const type = evt.event_type === "question" ? "questions" : evt.event_type;
      if (type in bucket) bucket[type]++;
    }

    const timeline = Array.from(hourlyBuckets.entries()).map(([hour, counts]) => ({
      hour,
      ...counts,
    }));

    res.status(200).json({ incidentCode, timeline });
  } catch (err) {
    console.error("Timeline error:", err);
    res.status(500).json({ error: "Failed to fetch timeline" });
  }
});
