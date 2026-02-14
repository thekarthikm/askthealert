/**
 * GET /incidents — List active or recent incidents.
 * GET /incidents/:incidentCode — Get full incident detail.
 *
 * Used by the Authority Console incident list / incident selector.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";

export const incidentsRouter = Router();

const listQuerySchema = z.object({
  /** Max incidents to return. Default 20. */
  limit: z.coerce.number().int().min(1).max(100).default(20),
  /** Sort order. Default newest first. */
  sort: z.enum(["newest", "oldest"]).default("newest"),
});

/**
 * GET /incidents
 *
 * Returns a list of incidents (alerts) with basic telemetry counts.
 * Sorted by creation time (newest first by default).
 */
incidentsRouter.get("/", async (req, res) => {
  const parsed = listQuerySchema.safeParse(req.query);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid query", details: parsed.error.issues });
    return;
  }

  const { limit, sort } = parsed.data;
  const supabase = getSupabase();

  try {
    const { data: alerts, error } = await supabase
      .from("alerts")
      .select("*")
      .order("timestamp", { ascending: sort === "oldest" })
      .limit(limit);

    if (error) {
      console.error("Failed to list incidents:", error);
      res.status(500).json({ error: "Failed to list incidents" });
      return;
    }

    // Enrich with telemetry counts per incident
    const incidents = await Promise.all(
      (alerts ?? []).map(async (alert) => {
        const { count: eventCount } = await supabase
          .from("telemetry_events")
          .select("*", { count: "exact", head: true })
          .eq("incident_code", alert.incident_code);

        const { count: updateCount } = await supabase
          .from("updates")
          .select("*", { count: "exact", head: true })
          .eq("incident_code", alert.incident_code);

        const { count: questionCount } = await supabase
          .from("telemetry_events")
          .select("*", { count: "exact", head: true })
          .eq("incident_code", alert.incident_code)
          .eq("event_type", "question");

        return {
          incidentCode: alert.incident_code,
          title: alert.title,
          severity: alert.severity,
          body: alert.body,
          region: alert.region,
          timestamp: alert.timestamp,
          createdAt: alert.created_at,
          telemetry: {
            totalEvents: eventCount ?? 0,
            questions: questionCount ?? 0,
            updates: updateCount ?? 0,
          },
        };
      })
    );

    res.status(200).json({ incidents });
  } catch (err) {
    console.error("List incidents error:", err);
    res.status(500).json({ error: "Failed to list incidents" });
  }
});

const paramSchema = z.object({
  incidentCode: z.string().min(1),
});

/**
 * GET /incidents/:incidentCode
 *
 * Returns full detail for a single incident: alert info, updates, and telemetry summary.
 */
incidentsRouter.get("/:incidentCode", async (req, res) => {
  const paramParsed = paramSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;
  const supabase = getSupabase();

  try {
    // Alert
    const { data: alert } = await supabase
      .from("alerts")
      .select("*")
      .eq("incident_code", incidentCode)
      .single();

    if (!alert) {
      res.status(404).json({ error: "Incident not found" });
      return;
    }

    // Updates
    const { data: updates } = await supabase
      .from("updates")
      .select("*")
      .eq("incident_code", incidentCode)
      .order("timestamp", { ascending: false });

    // Telemetry summary
    const { data: events } = await supabase
      .from("telemetry_events")
      .select("event_type, satisfaction_yes_no")
      .eq("incident_code", incidentCode);

    const counts: Record<string, number> = {
      received: 0, opened: 0, spoke: 0, questions: 0, satisfaction: 0,
    };
    let satYes = 0;
    let satNo = 0;

    for (const evt of events ?? []) {
      const type = evt.event_type === "question" ? "questions" : evt.event_type;
      if (type in counts) counts[type]++;
      if (evt.event_type === "satisfaction" && evt.satisfaction_yes_no !== null) {
        if (evt.satisfaction_yes_no) satYes++;
        else satNo++;
      }
    }

    // Intent clusters
    const { data: clusters } = await supabase
      .from("aggregated_clusters")
      .select("*")
      .eq("incident_code", incidentCode)
      .order("question_count", { ascending: false });

    res.status(200).json({
      incidentCode,
      alert: {
        title: alert.title,
        severity: alert.severity,
        body: alert.body,
        region: alert.region,
        timestamp: alert.timestamp,
      },
      updates: (updates ?? []).map((u) => ({
        id: u.id,
        updateText: u.update_text,
        timestamp: u.timestamp,
        source: u.source,
      })),
      telemetry: {
        counts,
        satisfaction: {
          yes: satYes,
          no: satNo,
          rate: satYes + satNo > 0 ? Math.round((satYes / (satYes + satNo)) * 100) : null,
        },
      },
      clusters: (clusters ?? []).map((c) => ({
        intent: c.intent_label,
        count: c.question_count,
        examples: c.example_questions ?? [],
        confusionFlag: c.confusion_flag,
      })),
    });
  } catch (err) {
    console.error("Incident detail error:", err);
    res.status(500).json({ error: "Failed to fetch incident" });
  }
});
