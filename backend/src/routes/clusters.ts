/**
 * GET  /clusters/:incidentCode — Get intent clusters for an incident.
 * POST /clusters/:incidentCode/refresh — Force-refresh clusters from telemetry.
 *
 * Intent clusters are aggregated views of citizen questions grouped by intent.
 * The Authority Console uses these to see what citizens are asking about most.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";
import { classifyIntent, detectConfusion, buildIntentClusters } from "../services/intentGrouping.js";

export const clustersRouter = Router();

const paramsSchema = z.object({
  incidentCode: z.string().min(1),
});

/**
 * GET /clusters/:incidentCode
 *
 * Returns cached intent clusters from the aggregated_clusters table.
 * These are refreshed on each telemetry ingest (question events).
 */
clustersRouter.get("/:incidentCode", async (req, res) => {
  const paramParsed = paramsSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;
  const supabase = getSupabase();

  const { data: clusters, error } = await supabase
    .from("aggregated_clusters")
    .select("*")
    .eq("incident_code", incidentCode)
    .order("question_count", { ascending: false });

  if (error) {
    console.error("Failed to fetch clusters:", error);
    res.status(500).json({ error: "Failed to fetch clusters" });
    return;
  }

  res.status(200).json({
    incidentCode,
    clusters: (clusters ?? []).map((c) => ({
      intent: c.intent_label,
      count: c.question_count,
      examples: c.example_questions ?? [],
      confusionFlag: c.confusion_flag,
      lastUpdated: c.last_updated,
    })),
  });
});

/**
 * POST /clusters/:incidentCode/refresh
 *
 * Force-refreshes clusters by re-reading all question events from telemetry.
 * Uses the Supabase RPC function and also runs server-side classification
 * for any unclassified questions.
 */
clustersRouter.post("/:incidentCode/refresh", async (req, res) => {
  const paramParsed = paramsSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;
  const supabase = getSupabase();

  // Fetch all question events for this incident
  const { data: questions, error } = await supabase
    .from("telemetry_events")
    .select("short_text, intent_label")
    .eq("incident_code", incidentCode)
    .eq("event_type", "question")
    .not("short_text", "is", null);

  if (error) {
    console.error("Failed to fetch questions:", error);
    res.status(500).json({ error: "Failed to fetch questions" });
    return;
  }

  // Re-classify any unclassified questions
  const classified = (questions ?? []).map((q) => {
    let intent = q.intent_label;
    if (!intent && q.short_text) {
      intent = classifyIntent(q.short_text).intent;
    }
    return { text: q.short_text ?? "", intent: intent ?? "other_unclear" };
  });

  // Build clusters using the in-memory grouping service
  const clusters = buildIntentClusters(classified as any);
  const confusedIntents = detectConfusion(classified as any);

  // Also trigger the DB-level refresh for persistence
  await supabase.rpc("refresh_intent_clusters", { p_incident_code: incidentCode });

  res.status(200).json({
    incidentCode,
    clusters: clusters.map((c) => ({
      intent: c.intent,
      count: c.count,
      examples: c.examples,
      confusionFlag: c.confusionFlag || confusedIntents.has(c.intent as any),
    })),
    totalQuestions: classified.length,
  });
});
