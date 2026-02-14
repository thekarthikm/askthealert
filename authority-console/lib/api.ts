/**
 * Backend API client for the Authority Console.
 *
 * Every request sends the console auth secret in the Authorization header.
 * All Phase 4 backend endpoints are wired here.
 */

import type {
  AlertSeverity,
  IntentCluster,
} from "@askthealert/shared";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:3001";
const AUTH_SECRET = process.env.NEXT_PUBLIC_AUTH_SECRET ?? "";

/** Standard headers for every authenticated request. */
function headers(): HeadersInit {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${AUTH_SECRET}`,
  };
}

// ── Alerts ──────────────────────────────────────────────────

export interface SendAlertRequest {
  incidentCode: string;
  title: string;
  severity: AlertSeverity;
  body: string;
  region: string;
  targeting: "all" | string[] | { label: string };
}

export interface SendAlertResponse {
  sent: number;
  total: number;
  pruned: number;
}

export async function sendAlert(
  data: SendAlertRequest
): Promise<SendAlertResponse> {
  const res = await fetch(`${API_URL}/alerts`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(data),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error((err as { error?: string }).error ?? `HTTP ${res.status}`);
  }
  return res.json() as Promise<SendAlertResponse>;
}

// ── Updates ─────────────────────────────────────────────────

export interface PublishUpdateRequest {
  incidentCode: string;
  updateText: string;
  source?: "broadcast" | "authority_console";
}

export interface PublishUpdateResponse {
  sent: number;
  total: number;
  pruned: number;
}

export async function publishUpdate(
  data: PublishUpdateRequest
): Promise<PublishUpdateResponse> {
  const res = await fetch(`${API_URL}/updates`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(data),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error((err as { error?: string }).error ?? `HTTP ${res.status}`);
  }
  return res.json() as Promise<PublishUpdateResponse>;
}

// ── Incidents ───────────────────────────────────────────────

export interface IncidentSummary {
  incidentCode: string;
  title: string;
  severity: AlertSeverity;
  body: string;
  region: string;
  timestamp: string;
  createdAt: string;
  telemetry: {
    totalEvents: number;
    questions: number;
    updates: number;
  };
}

export interface IncidentDetail {
  incidentCode: string;
  alert: {
    title: string;
    severity: AlertSeverity;
    body: string;
    region: string;
    timestamp: string;
  };
  updates: Array<{
    id: string;
    updateText: string;
    timestamp: string;
    source: string;
  }>;
  telemetry: {
    counts: Record<string, number>;
    satisfaction: { yes: number; no: number; rate: number | null };
  };
  clusters: Array<{
    intent: string;
    count: number;
    examples: string[];
    confusionFlag: boolean;
  }>;
}

export async function listIncidents(
  limit = 20
): Promise<{ incidents: IncidentSummary[] }> {
  const res = await fetch(
    `${API_URL}/incidents?limit=${limit}&sort=newest`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<{ incidents: IncidentSummary[] }>;
}

export async function getIncident(
  incidentCode: string
): Promise<IncidentDetail> {
  const res = await fetch(`${API_URL}/incidents/${encodeURIComponent(incidentCode)}`, {
    headers: headers(),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<IncidentDetail>;
}

// ── Metrics ─────────────────────────────────────────────────

export interface MetricsResponse {
  incidentCode: string;
  alert: { title: string; severity: string; region: string; timestamp: string } | null;
  counts: Record<string, number>;
  satisfactionBreakdown: { yes: number; no: number; rate: number | null };
  actionBlockers: Record<string, number>;
  updateCount: number;
  timeRange: { first: string | null; last: string | null };
  totalEvents: number;
  timestamp: string;
}

export interface TimelineEntry {
  hour: string;
  received: number;
  opened: number;
  spoke: number;
  questions: number;
  satisfaction: number;
}

export async function getMetrics(
  incidentCode: string
): Promise<MetricsResponse> {
  const res = await fetch(
    `${API_URL}/metrics/${encodeURIComponent(incidentCode)}`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<MetricsResponse>;
}

export async function getTimeline(
  incidentCode: string
): Promise<{ incidentCode: string; timeline: TimelineEntry[] }> {
  const res = await fetch(
    `${API_URL}/metrics/${encodeURIComponent(incidentCode)}/timeline`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<{ incidentCode: string; timeline: TimelineEntry[] }>;
}

// ── Clusters ────────────────────────────────────────────────

export interface ClustersResponse {
  incidentCode: string;
  clusters: Array<{
    intent: string;
    count: number;
    examples: string[];
    confusionFlag: boolean;
    lastUpdated?: string;
  }>;
}

export async function getClusters(
  incidentCode: string
): Promise<ClustersResponse> {
  const res = await fetch(
    `${API_URL}/clusters/${encodeURIComponent(incidentCode)}`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<ClustersResponse>;
}

export async function refreshClusters(
  incidentCode: string
): Promise<ClustersResponse & { totalQuestions: number }> {
  const res = await fetch(
    `${API_URL}/clusters/${encodeURIComponent(incidentCode)}/refresh`,
    { method: "POST", headers: headers() }
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<ClustersResponse & { totalQuestions: number }>;
}

// ── Satisfaction ─────────────────────────────────────────────

export interface SatisfactionResponse {
  incidentCode: string;
  total: number;
  yes: number;
  no: number;
  satisfactionRate: number | null;
}

export async function getSatisfaction(
  incidentCode: string
): Promise<SatisfactionResponse> {
  const res = await fetch(
    `${API_URL}/satisfaction/${encodeURIComponent(incidentCode)}`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<SatisfactionResponse>;
}

// ── Health ──────────────────────────────────────────────────

export interface HealthResponse {
  status: string;
  timestamp: string;
  version?: string;
  environment?: string;
}

export async function checkHealth(): Promise<HealthResponse> {
  const res = await fetch(`${API_URL}/health`);
  return res.json() as Promise<HealthResponse>;
}

// ── SSE Stream ──────────────────────────────────────────────

/**
 * Create an SSE connection for real-time dashboard updates.
 * Returns an EventSource that emits 'metrics', 'clusters', 'updates' events.
 */
export function createSSEStream(incidentCode: string): EventSource {
  const url = `${API_URL}/stream/${encodeURIComponent(incidentCode)}?token=${encodeURIComponent(AUTH_SECRET)}`;
  return new EventSource(url);
}

// ── Auth Validation ─────────────────────────────────────────

/**
 * Validate the auth secret against the backend by calling /health
 * with auth header and a protected endpoint.
 */
export async function validateAuth(secret: string): Promise<boolean> {
  try {
    const res = await fetch(`${API_URL}/incidents?limit=1`, {
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${secret}`,
      },
    });
    return res.ok;
  } catch {
    return false;
  }
}
