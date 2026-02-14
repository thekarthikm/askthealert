/**
 * POST /telemetry — Ingest telemetry events from iOS.
 *
 * Supports batch upload (array of events, 1–100 per request).
 * Idempotent: duplicate eventIds are ignored (upsert on event_id).
 * Server sets serverTimestamp on ingest.
 * PII minimization: redacts phone numbers, emails, SINs, addresses from shortText.
 * Consent field: only stores events where consentGiven is true (or defaults true).
 *
 * After ingest, refreshes intent clusters for affected incidents.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";
import { classifyIntent } from "../services/intentGrouping.js";
import { redactPII } from "../services/piiRedaction.js";

export const telemetryRouter = Router();

const eventSchema = z.object({
  eventId: z.string().uuid(),
  incidentCode: z.string().min(1),
  eventType: z.enum(["received", "opened", "spoke", "question", "satisfaction"]),
  deviceTimestamp: z.string().datetime(),
  /** Whether the user consented to telemetry collection. Defaults true. */
  consentGiven: z.boolean().default(true),
  payload: z.object({
    intentLabel: z.string().optional(),
    shortText: z.string().optional(),
    satisfactionYesNo: z.boolean().optional(),
    actionBlocker: z.enum(["driving", "condo", "kids", "disability"]).optional(),
  }),
});

const batchSchema = z.object({
  events: z.array(eventSchema).min(1).max(100),
});

telemetryRouter.post("/", async (req, res) => {
  const parsed = batchSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request", details: parsed.error.issues });
    return;
  }

  const supabase = getSupabase();
  const serverTimestamp = new Date().toISOString();

  // Track which incidents have question events for cluster refresh
  const incidentsWithQuestions = new Set<string>();

  const rows = parsed.data.events
    .filter((evt) => evt.consentGiven) // Only store if consent given
    .map((evt) => {
      // Server-side intent classification for question events
      let intentLabel = evt.payload.intentLabel;
      if (evt.eventType === "question" && !intentLabel && evt.payload.shortText) {
        const classification = classifyIntent(evt.payload.shortText);
        intentLabel = classification.intent;
      }

      // Track incidents with question events
      if (evt.eventType === "question") {
        incidentsWithQuestions.add(evt.incidentCode);
      }

      // PII redaction on shortText before storage
      const sanitizedText = evt.payload.shortText
        ? redactPII(evt.payload.shortText)
        : null;

      return {
        event_id: evt.eventId,
        incident_code: evt.incidentCode,
        event_type: evt.eventType,
        device_timestamp: evt.deviceTimestamp,
        server_timestamp: serverTimestamp,
        intent_label: intentLabel ?? null,
        short_text: sanitizedText,
        satisfaction_yes_no: evt.payload.satisfactionYesNo ?? null,
        action_blocker: evt.payload.actionBlocker ?? null,
        consent_given: evt.consentGiven,
      };
    });

  if (rows.length === 0) {
    // All events filtered out (no consent)
    res.status(200).json({ ingested: 0, message: "No consented events to ingest" });
    return;
  }

  // Upsert on event_id for idempotency (at-least-once semantics)
  const { error } = await supabase
    .from("telemetry_events")
    .upsert(rows, { onConflict: "event_id", ignoreDuplicates: true });

  if (error) {
    console.error("Telemetry ingest failed:", error);
    res.status(500).json({ error: "Ingest failed" });
    return;
  }

  // Refresh intent clusters for affected incidents (async, non-blocking)
  for (const incidentCode of incidentsWithQuestions) {
    supabase
      .rpc("refresh_intent_clusters", { p_incident_code: incidentCode })
      .then(({ error: clusterErr }) => {
        if (clusterErr) {
          console.error(`Failed to refresh clusters for ${incidentCode}:`, clusterErr.message);
        }
      });
  }

  res.status(200).json({ ingested: rows.length });
});
