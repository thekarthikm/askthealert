/**
 * TimelineChart — Visualize event counts over time using Recharts.
 *
 * Shows a stacked area chart of event types (received, opened, spoke,
 * questions, satisfaction) per hour.
 */

"use client";

import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";
import type { TimelineEntry } from "../lib/api";

interface TimelineChartProps {
  timeline: TimelineEntry[];
  loading: boolean;
}

const COLORS = {
  received: "#6366f1", // indigo
  opened: "#3b82f6", // blue
  spoke: "#10b981", // emerald
  questions: "#f59e0b", // amber
  satisfaction: "#ef4444", // red
};

export function TimelineChart({ timeline, loading }: TimelineChartProps) {
  if (loading) {
    return (
      <div className="bg-white rounded-lg border border-gray-200 p-6 animate-pulse">
        <div className="h-64 bg-gray-100 rounded" />
      </div>
    );
  }

  if (timeline.length === 0) {
    return (
      <div className="bg-white rounded-lg border border-gray-200 p-6 text-center text-gray-400">
        No timeline data yet. Events will populate as citizens interact.
      </div>
    );
  }

  // Format hour labels
  const chartData = timeline.map((entry) => {
    const date = new Date(entry.hour);
    return {
      ...entry,
      label: date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
    };
  });

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <ResponsiveContainer width="100%" height={300}>
        <AreaChart data={chartData}>
          <CartesianGrid strokeDasharray="3 3" stroke="#f0f0f0" />
          <XAxis
            dataKey="label"
            tick={{ fontSize: 12, fill: "#9ca3af" }}
            tickLine={false}
            axisLine={{ stroke: "#e5e7eb" }}
          />
          <YAxis
            tick={{ fontSize: 12, fill: "#9ca3af" }}
            tickLine={false}
            axisLine={{ stroke: "#e5e7eb" }}
            allowDecimals={false}
          />
          <Tooltip
            contentStyle={{
              borderRadius: "8px",
              border: "1px solid #e5e7eb",
              boxShadow: "0 4px 6px -1px rgba(0,0,0,0.1)",
              fontSize: "13px",
            }}
          />
          <Legend
            wrapperStyle={{ fontSize: "12px", paddingTop: "16px" }}
          />
          <Area
            type="monotone"
            dataKey="received"
            stackId="1"
            stroke={COLORS.received}
            fill={COLORS.received}
            fillOpacity={0.15}
            name="Received"
          />
          <Area
            type="monotone"
            dataKey="opened"
            stackId="2"
            stroke={COLORS.opened}
            fill={COLORS.opened}
            fillOpacity={0.15}
            name="Opened"
          />
          <Area
            type="monotone"
            dataKey="spoke"
            stackId="3"
            stroke={COLORS.spoke}
            fill={COLORS.spoke}
            fillOpacity={0.15}
            name="Voice Sessions"
          />
          <Area
            type="monotone"
            dataKey="questions"
            stackId="4"
            stroke={COLORS.questions}
            fill={COLORS.questions}
            fillOpacity={0.15}
            name="Questions"
          />
          <Area
            type="monotone"
            dataKey="satisfaction"
            stackId="5"
            stroke={COLORS.satisfaction}
            fill={COLORS.satisfaction}
            fillOpacity={0.15}
            name="Satisfaction"
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
