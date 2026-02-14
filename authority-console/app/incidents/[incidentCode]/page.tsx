/**
 * Incident Detail Page
 *
 * Full dashboard for a single incident with:
 * - Real-time metrics via SSE
 * - Telemetry timeline chart
 * - Question clusters with confusion hotspots
 * - Updates timeline
 * - Quick actions: Publish Update, Refresh Clusters
 */

"use client";

import { useEffect, useState, useCallback, useRef } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import {
  getMetrics,
  getTimeline,
  getClusters,
  refreshClusters,
  createSSEStream,
  type MetricsResponse,
  type TimelineEntry,
  type ClustersResponse,
} from "../../../lib/api";
import { MetricsDashboard, type MetricsData } from "../../../components/MetricsDashboard";
import { QuestionClusters } from "../../../components/QuestionClusters";
import { TimelineChart } from "../../../components/TimelineChart";
import { UpdatesTimeline } from "../../../components/UpdatesTimeline";

export default function IncidentDetailPage() {
  const params = useParams();
  const incidentCode = decodeURIComponent(params.incidentCode as string);

  const [metricsData, setMetricsData] = useState<MetricsData | null>(null);
  const [rawMetrics, setRawMetrics] = useState<MetricsResponse | null>(null);
  const [timeline, setTimeline] = useState<TimelineEntry[]>([]);
  const [clusters, setClusters] = useState<ClustersResponse["clusters"]>([]);
  const [updates, setUpdates] = useState<
    Array<{ updateText: string; timestamp: string; source: string }>
  >([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sseConnected, setSseConnected] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const sseRef = useRef<EventSource | null>(null);

  /** Transform raw backend metrics to MetricsDashboard format. */
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

  /** Fetch initial data from REST endpoints. */
  const fetchInitialData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [metricsRes, timelineRes, clustersRes] = await Promise.all([
        getMetrics(incidentCode),
        getTimeline(incidentCode),
        getClusters(incidentCode),
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
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load incident data");
    } finally {
      setLoading(false);
    }
  }, [incidentCode, transformMetrics]);

  /** Connect to SSE for real-time updates. */
  const connectSSE = useCallback(() => {
    if (sseRef.current) {
      sseRef.current.close();
    }

    try {
      const es = createSSEStream(incidentCode);
      sseRef.current = es;

      es.addEventListener("metrics", (event) => {
        try {
          const data = JSON.parse(event.data) as MetricsResponse;
          setRawMetrics(data);
          setMetricsData(transformMetrics(data));
        } catch {
          /* ignore parse errors */
        }
      });

      es.addEventListener("clusters", (event) => {
        try {
          const data = JSON.parse(event.data);
          if (data.clusters) {
            setClusters(
              data.clusters.map((c: ClustersResponse["clusters"][number]) => ({
                ...c,
                confusionFlag: c.confusionFlag ?? false,
              }))
            );
          }
        } catch {
          /* ignore parse errors */
        }
      });

      es.addEventListener("updates", (event) => {
        try {
          const data = JSON.parse(event.data);
          if (data.updates) {
            setUpdates(data.updates);
          }
        } catch {
          /* ignore parse errors */
        }
      });

      es.onopen = () => setSseConnected(true);
      es.onerror = () => setSseConnected(false);
    } catch {
      setSseConnected(false);
    }
  }, [incidentCode, transformMetrics]);

  useEffect(() => {
    fetchInitialData();
    connectSSE();

    return () => {
      if (sseRef.current) {
        sseRef.current.close();
        sseRef.current = null;
      }
    };
  }, [fetchInitialData, connectSSE]);

  /** Force refresh clusters from backend. */
  const handleRefreshClusters = async () => {
    setRefreshing(true);
    try {
      const data = await refreshClusters(incidentCode);
      setClusters(
        data.clusters.map((c) => ({
          ...c,
          confusionFlag: c.confusionFlag ?? false,
        }))
      );
    } catch {
      /* continue with existing */
    } finally {
      setRefreshing(false);
    }
  };

  if (error && loading) {
    return (
      <div className="space-y-6">
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-red-700 text-sm">
          {error}
        </div>
        <Link href="/incidents" className="text-sm text-blue-600 hover:underline">
          &larr; Back to Incidents
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <div className="flex items-center gap-3 mb-1">
            <Link
              href="/incidents"
              className="text-gray-400 hover:text-gray-600 transition-colors"
            >
              &larr;
            </Link>
            <h1 className="text-2xl font-bold">
              {rawMetrics?.alert?.title ?? incidentCode}
            </h1>
            {rawMetrics?.alert?.severity && (
              <SeverityBadge severity={rawMetrics.alert.severity} />
            )}
          </div>
          <div className="flex items-center gap-4 text-sm text-gray-500">
            <span>Code: {incidentCode}</span>
            {rawMetrics?.alert?.region && (
              <span>Region: {rawMetrics.alert.region}</span>
            )}
            <span className="flex items-center gap-1">
              <span
                className={`w-2 h-2 rounded-full ${
                  sseConnected ? "bg-green-500" : "bg-gray-300"
                }`}
              />
              {sseConnected ? "Live" : "Polling"}
            </span>
          </div>
        </div>

        <div className="flex gap-3">
          <Link
            href={`/updates?incidentCode=${encodeURIComponent(incidentCode)}`}
            className="bg-blue-600 text-white px-4 py-2 rounded-lg text-sm font-medium hover:bg-blue-700 transition-colors"
          >
            Publish Update
          </Link>
        </div>
      </div>

      {/* Metrics Dashboard */}
      <section>
        <h2 className="text-lg font-semibold mb-3">Real-Time Metrics</h2>
        <MetricsDashboard data={metricsData} loading={loading} />
      </section>

      {/* Additional stats */}
      {rawMetrics && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <StatCard label="Total Events" value={rawMetrics.totalEvents} />
          <StatCard label="Questions" value={rawMetrics.counts?.question ?? 0} />
          <StatCard label="Updates Published" value={rawMetrics.updateCount} />
          <StatCard
            label="Action Blockers"
            value={Object.values(rawMetrics.actionBlockers ?? {}).reduce(
              (a, b) => a + b,
              0
            )}
          />
        </div>
      )}

      {/* Action Blockers Breakdown */}
      {rawMetrics &&
        rawMetrics.actionBlockers &&
        Object.keys(rawMetrics.actionBlockers).length > 0 && (
          <section>
            <h2 className="text-lg font-semibold mb-3">Action Blockers</h2>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              {Object.entries(rawMetrics.actionBlockers).map(([key, value]) => (
                <div
                  key={key}
                  className="bg-white rounded-lg border border-gray-200 p-3 text-center"
                >
                  <p className="text-lg font-bold">{value}</p>
                  <p className="text-xs text-gray-500 capitalize">{key}</p>
                </div>
              ))}
            </div>
          </section>
        )}

      {/* Timeline Chart */}
      <section>
        <h2 className="text-lg font-semibold mb-3">Event Timeline</h2>
        <TimelineChart timeline={timeline} loading={loading} />
      </section>

      {/* Question Clusters */}
      <section>
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-lg font-semibold">Question Clusters</h2>
          <button
            onClick={handleRefreshClusters}
            disabled={refreshing}
            className="text-sm text-blue-600 hover:text-blue-800 disabled:opacity-50 transition-colors"
          >
            {refreshing ? "Refreshing..." : "Refresh Clusters"}
          </button>
        </div>
        <QuestionClusters
          clusters={clusters.map((c) => ({
            intent: c.intent as import("@askthealert/shared").IntentCategory,
            count: c.count,
            examples: c.examples,
            confusionFlag: c.confusionFlag,
          }))}
          incidentCode={incidentCode}
          loading={loading}
        />
      </section>

      {/* Updates Timeline */}
      {updates.length > 0 && (
        <section>
          <h2 className="text-lg font-semibold mb-3">Updates Timeline</h2>
          <UpdatesTimeline updates={updates} />
        </section>
      )}
    </div>
  );
}

function SeverityBadge({ severity }: { severity: string }) {
  const colors: Record<string, string> = {
    critical: "bg-red-100 text-red-800 border-red-200",
    warning: "bg-yellow-100 text-yellow-800 border-yellow-200",
    info: "bg-blue-100 text-blue-800 border-blue-200",
  };

  return (
    <span
      className={`text-xs px-2 py-0.5 rounded-full border font-medium ${
        colors[severity] ?? "bg-gray-100 text-gray-800"
      }`}
    >
      {severity.toUpperCase()}
    </span>
  );
}

function StatCard({ label, value }: { label: string; value: number }) {
  return (
    <div className="bg-white rounded-lg border border-gray-200 p-3">
      <p className="text-xs text-gray-500">{label}</p>
      <p className="text-xl font-bold mt-0.5">{value}</p>
    </div>
  );
}
