/**
 * Authority Console — Main Dashboard
 *
 * Displays:
 * - Incident selector (dropdown of active incidents)
 * - Real-time metrics via SSE (received, opened, spoke, satisfaction)
 * - Event timeline chart
 * - Top question clusters with confusion hotspots
 * - Quick actions: "Send Alert", "Publish Update"
 * - Recent updates feed
 */

"use client";

import { useEffect, useState, useCallback, useRef } from "react";
import Link from "next/link";
import {
  listIncidents,
  getMetrics,
  getTimeline,
  getClusters,
  createSSEStream,
  type IncidentSummary,
  type MetricsResponse,
  type TimelineEntry,
  type ClustersResponse,
} from "../lib/api";
import { MetricsDashboard, type MetricsData } from "../components/MetricsDashboard";
import { QuestionClusters } from "../components/QuestionClusters";
import { TimelineChart } from "../components/TimelineChart";

export default function DashboardPage() {
  const [incidents, setIncidents] = useState<IncidentSummary[]>([]);
  const [selectedIncident, setSelectedIncident] = useState<string>("");
  const [metricsData, setMetricsData] = useState<MetricsData | null>(null);
  const [rawMetrics, setRawMetrics] = useState<MetricsResponse | null>(null);
  const [timeline, setTimeline] = useState<TimelineEntry[]>([]);
  const [clusters, setClusters] = useState<ClustersResponse["clusters"]>([]);
  const [loadingIncidents, setLoadingIncidents] = useState(true);
  const [loadingData, setLoadingData] = useState(false);
  const [sseConnected, setSseConnected] = useState(false);

  const sseRef = useRef<EventSource | null>(null);

  /** Transform raw metrics for the dashboard display component. */
  const transformMetrics = useCallback((raw: MetricsResponse): MetricsData => {
    const received = raw.counts?.received ?? 0;
    const opened = raw.counts?.opened ?? 0;
    const spoke = raw.counts?.spoke ?? 0;
    return {
      received,
      opened,
      spoke,
      satisfaction: {
        yes: raw.satisfactionBreakdown?.yes ?? 0,
        no: raw.satisfactionBreakdown?.no ?? 0,
      },
      openRate: received > 0 ? opened / received : 0,
      voiceEngagementRate: opened > 0 ? spoke / opened : 0,
    };
  }, []);

  /** Fetch list of incidents. */
  useEffect(() => {
    let mounted = true;
    (async () => {
      try {
        const data = await listIncidents(20);
        if (!mounted) return;
        setIncidents(data.incidents);
        if (data.incidents.length > 0 && !selectedIncident) {
          setSelectedIncident(data.incidents[0].incidentCode);
        }
      } catch {
        /* continue with empty list */
      } finally {
        if (mounted) setLoadingIncidents(false);
      }
    })();
    return () => { mounted = false; };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  /** Fetch incident data when selected incident changes. */
  const fetchIncidentData = useCallback(
    async (code: string) => {
      if (!code) return;
      setLoadingData(true);
      try {
        const [metricsRes, timelineRes, clustersRes] = await Promise.all([
          getMetrics(code),
          getTimeline(code),
          getClusters(code),
        ]);
        setRawMetrics(metricsRes);
        setMetricsData(transformMetrics(metricsRes));
        setTimeline(timelineRes.timeline);
        setClusters(
          clustersRes.clusters.map((c) => ({
            ...c,
            confusionFlag: c.confusionFlag ?? false,
          }))
        );
      } catch {
        setMetricsData(null);
        setRawMetrics(null);
        setTimeline([]);
        setClusters([]);
      } finally {
        setLoadingData(false);
      }
    },
    [transformMetrics]
  );

  /** Connect to SSE for real-time updates. */
  const connectSSE = useCallback(
    (code: string) => {
      // Close existing connection
      if (sseRef.current) {
        sseRef.current.close();
        sseRef.current = null;
        setSseConnected(false);
      }
      if (!code) return;

      try {
        const es = createSSEStream(code);
        sseRef.current = es;

        es.addEventListener("metrics", (event) => {
          try {
            const data = JSON.parse(event.data) as MetricsResponse;
            setRawMetrics(data);
            setMetricsData(transformMetrics(data));
          } catch { /* ignore */ }
        });

        es.addEventListener("clusters", (event) => {
          try {
            const data = JSON.parse(event.data);
            if (data.clusters) {
              setClusters(
                data.clusters.map(
                  (c: ClustersResponse["clusters"][number]) => ({
                    ...c,
                    confusionFlag: c.confusionFlag ?? false,
                  })
                )
              );
            }
          } catch { /* ignore */ }
        });

        es.onopen = () => setSseConnected(true);
        es.onerror = () => setSseConnected(false);
      } catch {
        setSseConnected(false);
      }
    },
    [transformMetrics]
  );

  /** When selected incident changes, fetch data and connect SSE. */
  useEffect(() => {
    if (selectedIncident) {
      fetchIncidentData(selectedIncident);
      connectSSE(selectedIncident);
    }
    return () => {
      if (sseRef.current) {
        sseRef.current.close();
        sseRef.current = null;
      }
    };
  }, [selectedIncident, fetchIncidentData, connectSSE]);

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Dashboard</h1>
          <p className="text-gray-500 mt-1">
            Monitor citizen engagement and manage emergency communications.
          </p>
        </div>
        <div className="flex gap-3">
          <Link
            href="/updates"
            className="border border-gray-300 text-gray-700 px-4 py-2 rounded-lg text-sm font-medium hover:bg-gray-50 transition-colors"
          >
            Publish Update
          </Link>
          <Link
            href="/alerts/new"
            className="bg-red-600 text-white px-4 py-2 rounded-lg text-sm font-medium hover:bg-red-700 transition-colors"
          >
            Send Alert
          </Link>
        </div>
      </div>

      {/* Incident Selector */}
      <section>
        <div className="flex items-center gap-4">
          <label className="text-sm font-medium text-gray-700">
            Active Incident:
          </label>
          {loadingIncidents ? (
            <div className="h-9 w-64 bg-gray-100 rounded animate-pulse" />
          ) : incidents.length === 0 ? (
            <span className="text-sm text-gray-400">
              No incidents yet.{" "}
              <Link href="/alerts/new" className="text-blue-600 hover:underline">
                Send an alert
              </Link>{" "}
              to create one.
            </span>
          ) : (
            <select
              value={selectedIncident}
              onChange={(e) => setSelectedIncident(e.target.value)}
              className="input max-w-md"
            >
              {incidents.map((inc) => (
                <option key={inc.incidentCode} value={inc.incidentCode}>
                  {inc.title} — {inc.incidentCode}
                </option>
              ))}
            </select>
          )}
          {selectedIncident && (
            <div className="flex items-center gap-2 text-xs text-gray-400">
              <span
                className={`w-2 h-2 rounded-full ${
                  sseConnected ? "bg-green-500" : "bg-gray-300"
                }`}
              />
              {sseConnected ? "Live Stream" : "Polling"}
            </div>
          )}
        </div>
      </section>

      {/* If we have a selected incident, show data */}
      {selectedIncident && (
        <>
          {/* Metrics Grid */}
          <section>
            <h2 className="text-lg font-semibold mb-3">Real-Time Metrics</h2>
            <MetricsDashboard data={metricsData} loading={loadingData} />
          </section>

          {/* Extra stats row */}
          {rawMetrics && (
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
              <CompactStat label="Total Events" value={rawMetrics.totalEvents} />
              <CompactStat
                label="Questions"
                value={rawMetrics.counts?.question ?? 0}
              />
              <CompactStat
                label="Updates Published"
                value={rawMetrics.updateCount}
              />
              <CompactStat
                label="Action Blockers"
                value={Object.values(rawMetrics.actionBlockers ?? {}).reduce(
                  (a, b) => a + b,
                  0
                )}
              />
            </div>
          )}

          {/* Timeline Chart */}
          <section>
            <h2 className="text-lg font-semibold mb-3">Event Timeline</h2>
            <TimelineChart timeline={timeline} loading={loadingData} />
          </section>

          {/* Question Clusters */}
          <section>
            <div className="flex items-center justify-between mb-3">
              <h2 className="text-lg font-semibold">Top Question Clusters</h2>
              <Link
                href={`/incidents/${encodeURIComponent(selectedIncident)}`}
                className="text-sm text-blue-600 hover:underline"
              >
                View Full Details &rarr;
              </Link>
            </div>
            <QuestionClusters
              clusters={clusters.map((c) => ({
                intent:
                  c.intent as import("@askthealert/shared").IntentCategory,
                count: c.count,
                examples: c.examples,
                confusionFlag: c.confusionFlag,
              }))}
              incidentCode={selectedIncident}
              loading={loadingData}
            />
          </section>
        </>
      )}

      {/* No incident selected — empty state */}
      {!selectedIncident && !loadingIncidents && (
        <div className="bg-white rounded-lg border border-gray-200 p-8 text-center">
          <div className="text-gray-400 text-4xl mb-3">📡</div>
          <p className="text-gray-600 font-medium">No active incidents</p>
          <p className="text-gray-400 text-sm mt-1 max-w-md mx-auto">
            Use &ldquo;Send Alert&rdquo; to create an incident. Metrics, question
            clusters, and updates will appear here in real time.
          </p>
        </div>
      )}
    </div>
  );
}

function CompactStat({ label, value }: { label: string; value: number }) {
  return (
    <div className="bg-white rounded-lg border border-gray-200 p-3">
      <p className="text-xs text-gray-500">{label}</p>
      <p className="text-xl font-bold mt-0.5">{value}</p>
    </div>
  );
}
