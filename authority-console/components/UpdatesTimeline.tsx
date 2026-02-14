/**
 * UpdatesTimeline — Chronological list of published updates for an incident.
 *
 * Shows each update with timestamp and source badge.
 */

"use client";

interface UpdateEntry {
  updateText: string;
  timestamp: string;
  source: string;
}

interface UpdatesTimelineProps {
  updates: UpdateEntry[];
}

export function UpdatesTimeline({ updates }: UpdatesTimelineProps) {
  if (updates.length === 0) {
    return (
      <div className="bg-white rounded-lg border border-gray-200 p-6 text-center text-gray-400">
        No updates published yet.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {updates.map((update, idx) => {
        const ts = new Date(update.timestamp);
        return (
          <div
            key={`${update.timestamp}-${idx}`}
            className="bg-white rounded-lg border border-gray-200 p-4"
          >
            <div className="flex items-center justify-between mb-2">
              <div className="flex items-center gap-2">
                <span className="text-xs text-gray-400">
                  {ts.toLocaleDateString()} {ts.toLocaleTimeString()}
                </span>
                <SourceBadge source={update.source} />
              </div>
            </div>
            <p className="text-sm text-gray-700 leading-relaxed">
              {update.updateText}
            </p>
          </div>
        );
      })}
    </div>
  );
}

function SourceBadge({ source }: { source: string }) {
  const styles =
    source === "authority_console"
      ? "bg-blue-50 text-blue-700 border-blue-200"
      : "bg-gray-50 text-gray-600 border-gray-200";

  return (
    <span className={`text-xs px-2 py-0.5 rounded-full border ${styles}`}>
      {source === "authority_console" ? "Console" : "Broadcast"}
    </span>
  );
}
