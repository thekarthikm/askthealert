/**
 * Ask the Alert — Backend Server
 *
 * Express 5 + TypeScript. Supabase Postgres for storage. APNs for push.
 *
 * Routes:
 *   POST /devices              — Register iOS device token (public)
 *   POST /telemetry            — Ingest telemetry events (public)
 *   GET  /consent/policy       — Telemetry consent policy (public)
 *   POST /consent/check        — PII check preview (public)
 *
 *   POST /alerts               — Send alert push (auth required)
 *   POST /updates              — Publish update push (auth required)
 *   POST /retrieve             — Online RAG retrieval (auth required)
 *   GET  /incidents            — List incidents (auth required)
 *   GET  /incidents/:code      — Incident detail (auth required)
 *   GET  /metrics/:code        — Aggregate metrics (auth required)
 *   GET  /metrics/:code/timeline — Hourly timeline (auth required)
 *   GET  /clusters/:code       — Intent clusters (auth required)
 *   POST /clusters/:code/refresh — Refresh clusters (auth required)
 *   GET  /satisfaction/policy  — Satisfaction policy (auth required)
 *   GET  /satisfaction/:code   — Satisfaction stats (auth required)
 *   GET  /satisfaction/:code/blockers — Action blockers (auth required)
 *   POST /admin/retention/rollup — Retention rollup (auth required)
 *   GET  /admin/retention/stats — Retention stats (auth required)
 *   GET  /stream/:code         — SSE real-time stream (auth via query param)
 *
 *   GET  /health               — Health check (public)
 */

import express from "express";
import cors from "cors";
import helmet from "helmet";
import { env } from "./config/env.js";
import { devicesRouter } from "./routes/devices.js";
import { alertsRouter } from "./routes/alerts.js";
import { updatesRouter } from "./routes/updates.js";
import { telemetryRouter } from "./routes/telemetry.js";
import { retrieveRouter } from "./routes/retrieve.js";
import { streamRouter } from "./routes/stream.js";
import { clustersRouter } from "./routes/clusters.js";
import { metricsRouter } from "./routes/metrics.js";
import { incidentsRouter } from "./routes/incidents.js";
import { retentionRouter } from "./routes/retention.js";
import { consentRouter } from "./routes/consent.js";
import { satisfactionRouter } from "./routes/satisfaction.js";
import { requireConsoleAuth } from "./middleware/auth.js";
import { shutdownApns } from "./services/apns.js";

const app = express();

// ── Global middleware ──────────────────────────────────────
app.use(helmet());
app.use(
  cors({
    origin: true, // Allow all origins (configured per-env in production)
    credentials: true,
  })
);
app.use(express.json({ limit: "1mb" }));

// ── Health check (no auth) ─────────────────────────────────
app.get("/health", (_req, res) => {
  res.json({
    status: "ok",
    timestamp: new Date().toISOString(),
    version: "0.4.0",
    environment: env.NODE_ENV,
  });
});

// ── Public routes ──────────────────────────────────────────
// Device registration comes from iOS (no console auth needed)
app.use("/devices", devicesRouter);

// Telemetry ingest comes from iOS (no console auth needed)
app.use("/telemetry", telemetryRouter);

// Consent policy and PII check (public — iOS fetches on launch)
app.use("/consent", consentRouter);

// ── SSE stream (auth via query param — EventSource limitation) ──
app.use("/stream", streamRouter);

// ── Protected routes (console auth required) ───────────────
app.use("/alerts", requireConsoleAuth, alertsRouter);
app.use("/updates", requireConsoleAuth, updatesRouter);
app.use("/retrieve", requireConsoleAuth, retrieveRouter);
app.use("/incidents", requireConsoleAuth, incidentsRouter);
app.use("/metrics", requireConsoleAuth, metricsRouter);
app.use("/clusters", requireConsoleAuth, clustersRouter);
app.use("/satisfaction", requireConsoleAuth, satisfactionRouter);
app.use("/admin/retention", requireConsoleAuth, retentionRouter);

// ── Error handler ──────────────────────────────────────────
app.use(
  (
    err: Error,
    _req: express.Request,
    res: express.Response,
    _next: express.NextFunction
  ) => {
    console.error("Unhandled error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
);

// ── Start ──────────────────────────────────────────────────
const server = app.listen(env.PORT, () => {
  console.log(`Ask the Alert backend running on port ${env.PORT}`);
  console.log(`   Environment: ${env.NODE_ENV}`);
  console.log(`   APNs: ${env.APNS_ENVIRONMENT}`);
  console.log(`   Routes: /health, /devices, /telemetry, /consent, /alerts, /updates, /retrieve, /incidents, /metrics, /clusters, /satisfaction, /admin/retention, /stream`);
});

// ── Graceful shutdown ──────────────────────────────────────
function gracefulShutdown(signal: string) {
  console.log(`\n${signal} received. Shutting down gracefully…`);
  shutdownApns();
  server.close(() => {
    console.log("Server closed.");
    process.exit(0);
  });
  // Force exit after 10s
  setTimeout(() => process.exit(1), 10_000);
}

process.on("SIGINT", () => gracefulShutdown("SIGINT"));
process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
