/**
 * MetricsDashboard — Displays telemetry metrics for an incident.
 *
 * Shows real-time counts of received, opened, spoke, satisfaction events.
 * Data fetching is wired in Phase 5 (items 38–39).
 */

"use client";

export interface MetricsData {
  received: number;
  opened: number;
  spoke: number;
  satisfaction: { yes: number; no: number };
  openRate: number; // opened / received
  voiceEngagementRate: number; // spoke / opened
}

interface MetricsDashboardProps {
  data: MetricsData | null;
  loading: boolean;
}

export function MetricsDashboard({ data, loading }: MetricsDashboardProps) {
  if (loading) {
    return (
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        {[...Array(4)].map((_, i) => (
          <div
            key={i}
            className="bg-white rounded-lg border border-gray-200 p-4 animate-pulse"
          >
            <div className="h-4 bg-gray-200 rounded w-1/2 mb-2" />
            <div className="h-8 bg-gray-200 rounded w-1/3" />
          </div>
        ))}
      </div>
    );
  }

  if (!data) {
    return (
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <MetricCard label="Alerts Received" value="—" />
        <MetricCard label="App Opened" value="—" subtext="Open rate: —" />
        <MetricCard label="Voice Sessions" value="—" subtext="Engagement: —" />
        <MetricCard label="Satisfaction" value="—" />
      </div>
    );
  }

  const satisfactionRate =
    data.satisfaction.yes + data.satisfaction.no > 0
      ? Math.round(
          (data.satisfaction.yes /
            (data.satisfaction.yes + data.satisfaction.no)) *
            100
        )
      : 0;

  return (
    <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
      <MetricCard label="Alerts Received" value={String(data.received)} />
      <MetricCard
        label="App Opened"
        value={String(data.opened)}
        subtext={`Open rate: ${Math.round(data.openRate * 100)}%`}
      />
      <MetricCard
        label="Voice Sessions"
        value={String(data.spoke)}
        subtext={`Engagement: ${Math.round(data.voiceEngagementRate * 100)}%`}
      />
      <MetricCard
        label="Satisfaction"
        value={`${satisfactionRate}%`}
        subtext={`${data.satisfaction.yes} yes / ${data.satisfaction.no} no`}
      />
    </div>
  );
}

function MetricCard({
  label,
  value,
  subtext,
}: {
  label: string;
  value: string;
  subtext?: string;
}) {
  return (
    <div className="bg-white rounded-lg border border-gray-200 p-4">
      <p className="text-sm text-gray-500">{label}</p>
      <p className="text-2xl font-bold mt-1">{value}</p>
      {subtext && <p className="text-xs text-gray-400 mt-1">{subtext}</p>}
    </div>
  );
}
