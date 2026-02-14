/**
 * Incident List / Selector
 *
 * View active or last N incidents; switch context to view details.
 * Fetches real-time data from the backend.
 */

"use client";

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { listIncidents, type IncidentSummary } from "../../lib/api";

export default function IncidentsPage() {
  const [incidents, setIncidents] = useState<IncidentSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchIncidents = useCallback(async () => {
    try {
      const data = await listIncidents(50);
      setIncidents(data.incidents);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load incidents");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchIncidents();
    // Auto-refresh every 15 seconds
    const interval = setInterval(fetchIncidents, 15_000);
    return () => clearInterval(interval);
  }, [fetchIncidents]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Incidents</h1>
          <p className="text-gray-500 mt-1">
            Select an incident to view details, metrics, and publish updates.
          </p>
        </div>
        <div className="flex gap-3">
          <button
            onClick={fetchIncidents}
            className="text-sm text-gray-600 hover:text-gray-900 border border-gray-300 px-3 py-1.5 rounded-lg transition-colors"
          >
            Refresh
          </button>
          <Link
            href="/alerts/new"
            className="bg-red-600 text-white px-4 py-1.5 rounded-lg text-sm font-medium hover:bg-red-700 transition-colors"
          >
            Send Alert
          </Link>
        </div>
      </div>

      {loading && (
        <div className="space-y-3">
          {[...Array(3)].map((_, i) => (
            <div
              key={i}
              className="bg-white rounded-lg border border-gray-200 p-5 animate-pulse"
            >
              <div className="h-5 bg-gray-200 rounded w-1/3 mb-3" />
              <div className="h-4 bg-gray-200 rounded w-2/3 mb-2" />
              <div className="h-3 bg-gray-200 rounded w-1/4" />
            </div>
          ))}
        </div>
      )}

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-red-700 text-sm">
          {error}
        </div>
      )}

      {!loading && !error && incidents.length === 0 && (
        <div className="bg-white rounded-lg border border-gray-200 p-8 text-center">
          <div className="text-gray-400 text-4xl mb-3">📡</div>
          <p className="text-gray-600 font-medium">No incidents yet</p>
          <p className="text-gray-400 text-sm mt-1">
            Send an alert to create the first incident.
          </p>
          <Link
            href="/alerts/new"
            className="inline-block mt-4 bg-red-600 text-white px-4 py-2 rounded-lg text-sm font-medium hover:bg-red-700 transition-colors"
          >
            Send Alert
          </Link>
        </div>
      )}

      {!loading && incidents.length > 0 && (
        <div className="space-y-3">
          {incidents.map((incident) => (
            <IncidentCard key={incident.incidentCode} incident={incident} />
          ))}
        </div>
      )}
    </div>
  );
}

function IncidentCard({ incident }: { incident: IncidentSummary }) {
  const severityColors: Record<string, string> = {
    critical: "bg-red-100 text-red-800 border-red-200",
    warning: "bg-yellow-100 text-yellow-800 border-yellow-200",
    info: "bg-blue-100 text-blue-800 border-blue-200",
  };

  const ts = new Date(incident.timestamp);

  return (
    <Link href={`/incidents/${encodeURIComponent(incident.incidentCode)}`}>
      <div className="bg-white rounded-lg border border-gray-200 p-5 hover:border-gray-300 hover:shadow-sm transition-all cursor-pointer">
        <div className="flex items-start justify-between">
          <div className="flex-1">
            <div className="flex items-center gap-3 mb-1">
              <h3 className="font-semibold text-gray-900">{incident.title}</h3>
              <span
                className={`text-xs px-2 py-0.5 rounded-full border font-medium ${
                  severityColors[incident.severity] ?? "bg-gray-100 text-gray-800"
                }`}
              >
                {incident.severity.toUpperCase()}
              </span>
            </div>
            <p className="text-sm text-gray-600 mb-2 line-clamp-2">
              {incident.body}
            </p>
            <div className="flex items-center gap-4 text-xs text-gray-400">
              <span>Code: {incident.incidentCode}</span>
              <span>Region: {incident.region}</span>
              <span>
                {ts.toLocaleDateString()} {ts.toLocaleTimeString()}
              </span>
            </div>
          </div>

          <div className="flex gap-3 ml-6 flex-shrink-0">
            <MiniStat label="Events" value={incident.telemetry.totalEvents} />
            <MiniStat label="Questions" value={incident.telemetry.questions} />
            <MiniStat label="Updates" value={incident.telemetry.updates} />
          </div>
        </div>
      </div>
    </Link>
  );
}

function MiniStat({ label, value }: { label: string; value: number }) {
  return (
    <div className="text-center">
      <p className="text-lg font-bold text-gray-900">{value}</p>
      <p className="text-xs text-gray-400">{label}</p>
    </div>
  );
}
