/**
 * GET /stream/:incidentCode — Server-Sent Events (SSE) for real-time
 * Authority Console dashboard updates.
 *
 * The console opens an SSE connection per incident and receives:
 *   - metrics: { opened, spoke, questions, satisfaction } counts
 *   - clusters: question intent clusters with confusion flags
 *   - updates: new authority updates published for the incident
 *
 * Implementation: polling-backed SSE (polls Supabase every 3 seconds).
 * This is more reliable than Supabase Realtime for aggregated views,
 * avoids websocket complexity, and works through corporate proxies.
 *
 * Auth: requires console auth secret in query param for SSE
 * (Authorization header not supported by EventSource).
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";
import { env } from "../config/env.js";

export const streamRouter = Router();

const POLL_INTERVAL_MS = 3_000; // 3 seconds
const HEARTBEAT_INTERVAL_MS = 15_000; // Keep-alive every 15 seconds

/** SSE helper: format event data. */
function sseEvent(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

/** SSE helper: format comment (heartbeat). */
function sseComment(): string {
  return `: heartbeat ${new Date().toISOString()}\n\n`;
}

const paramsSchema = z.object({
  incidentCode: z.string().min(1),
});

streamRouter.get("/:incidentCode", async (req, res) => {
  // Auth via query param (SSE EventSource doesn't support headers)
  const authToken = req.query.token as string | undefined;
  if (!authToken || authToken !== env.CONSOLE_AUTH_SECRET) {
    res.status(403).json({ error: "Invalid or missing token" });
    return;
  }

  const paramParsed = paramsSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;

  // Set SSE headers
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no", // Disable nginx buffering
  });
  res.flushHeaders();

  // Send initial connection event
  res.write(sseEvent("connected", { incidentCode, timestamp: new Date().toISOString() }));

  const supabase = getSupabase();
  let isConnected = true;
  let lastUpdateTimestamp: string | null = null;

  /** Fetch and send current metrics. */
  async function sendMetrics(): Promise<void> {
    if (!isConnected) return;

    try {
      // Count events by type for this incident
      const { data: events } = await supabase
        .from("telemetry_events")
        .select("event_type")
        .eq("incident_code", incidentCode);

      const counts = {
        received: 0,
        opened: 0,
        spoke: 0,
        questions: 0,
        satisfaction: 0,
        satisfactionYes: 0,
        satisfactionNo: 0,
      };

      if (events) {
        for (const evt of events) {
          switch (evt.event_type) {
            case "received": counts.received++; break;
            case "opened": counts.opened++; break;
            case "spoke": counts.spoke++; break;
            case "question": counts.questions++; break;
            case "satisfaction": counts.satisfaction++; break;
          }
        }
      }

      // Get satisfaction breakdown
      const { data: satData } = await supabase
        .from("telemetry_events")
        .select("satisfaction_yes_no")
        .eq("incident_code", incidentCode)
        .eq("event_type", "satisfaction")
        .not("satisfaction_yes_no", "is", null);

      if (satData) {
        counts.satisfactionYes = satData.filter((s) => s.satisfaction_yes_no === true).length;
        counts.satisfactionNo = satData.filter((s) => s.satisfaction_yes_no === false).length;
      }

      res.write(sseEvent("metrics", {
        incidentCode,
        ...counts,
        timestamp: new Date().toISOString(),
      }));
    } catch (err) {
      console.error("SSE metrics fetch error:", err);
    }
  }

  /** Fetch and send intent clusters. */
  async function sendClusters(): Promise<void> {
    if (!isConnected) return;

    try {
      const { data: clusters } = await supabase
        .from("aggregated_clusters")
        .select("*")
        .eq("incident_code", incidentCode)
        .order("question_count", { ascending: false });

      if (clusters && clusters.length > 0) {
        res.write(sseEvent("clusters", {
          incidentCode,
          clusters: clusters.map((c) => ({
            intent: c.intent_label,
            count: c.question_count,
            examples: c.example_questions ?? [],
            confusionFlag: c.confusion_flag,
          })),
          timestamp: new Date().toISOString(),
        }));
      }
    } catch (err) {
      console.error("SSE clusters fetch error:", err);
    }
  }

  /** Fetch and send new authority updates. */
  async function sendNewUpdates(): Promise<void> {
    if (!isConnected) return;

    try {
      let query = supabase
        .from("updates")
        .select("id, update_text, timestamp, source")
        .eq("incident_code", incidentCode)
        .order("timestamp", { ascending: false })
        .limit(10);

      if (lastUpdateTimestamp) {
        query = query.gt("timestamp", lastUpdateTimestamp);
      }

      const { data: updates } = await query;

      if (updates && updates.length > 0) {
        lastUpdateTimestamp = updates[0].timestamp;
        res.write(sseEvent("updates", {
          incidentCode,
          updates: updates.map((u) => ({
            id: u.id,
            updateText: u.update_text,
            timestamp: u.timestamp,
            source: u.source,
          })),
        }));
      }
    } catch (err) {
      console.error("SSE updates fetch error:", err);
    }
  }

  // Initial data push
  await sendMetrics();
  await sendClusters();
  await sendNewUpdates();

  // Polling interval for data updates
  const pollTimer = setInterval(async () => {
    if (!isConnected) return;
    await sendMetrics();
    await sendClusters();
    await sendNewUpdates();
  }, POLL_INTERVAL_MS);

  // Heartbeat to keep connection alive
  const heartbeatTimer = setInterval(() => {
    if (!isConnected) return;
    res.write(sseComment());
  }, HEARTBEAT_INTERVAL_MS);

  // Cleanup on disconnect
  req.on("close", () => {
    isConnected = false;
    clearInterval(pollTimer);
    clearInterval(heartbeatTimer);
  });
});
