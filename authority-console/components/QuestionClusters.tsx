/**
 * QuestionClusters — Shows citizen questions grouped by intent.
 *
 * Highlights confusion hotspots with a flag. Authority can click "Publish
 * Update" to address the top concern. Data wired in Phase 5.
 */

"use client";

import type { IntentCluster, IntentCategory } from "@askthealert/shared";
import { INTENT_LABELS } from "@askthealert/shared";
import Link from "next/link";

interface QuestionClustersProps {
  clusters: IntentCluster[];
  incidentCode: string;
  loading: boolean;
}

export function QuestionClusters({
  clusters,
  incidentCode,
  loading,
}: QuestionClustersProps) {
  if (loading) {
    return (
      <div className="space-y-3">
        {[...Array(3)].map((_, i) => (
          <div
            key={i}
            className="bg-white rounded-lg border border-gray-200 p-4 animate-pulse"
          >
            <div className="h-4 bg-gray-200 rounded w-1/3 mb-2" />
            <div className="h-3 bg-gray-200 rounded w-2/3" />
          </div>
        ))}
      </div>
    );
  }

  if (clusters.length === 0) {
    return (
      <div className="bg-white rounded-lg border border-gray-200 p-6 text-center text-gray-400">
        No questions yet. Clusters will appear as citizens start talking.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {clusters.map((cluster) => (
        <ClusterCard
          key={cluster.intent}
          cluster={cluster}
          incidentCode={incidentCode}
        />
      ))}
    </div>
  );
}

function ClusterCard({
  cluster,
  incidentCode,
}: {
  cluster: IntentCluster;
  incidentCode: string;
}) {
  const label = INTENT_LABELS[cluster.intent];

  return (
    <div
      className={`bg-white rounded-lg border p-4 ${
        cluster.confusionFlag
          ? "border-yellow-400 bg-yellow-50"
          : "border-gray-200"
      }`}
    >
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center gap-2">
          <span className="font-semibold text-sm">{label}</span>
          <span className="bg-gray-100 text-gray-600 text-xs px-2 py-0.5 rounded-full">
            {cluster.count}
          </span>
          {cluster.confusionFlag && (
            <span className="bg-yellow-200 text-yellow-800 text-xs px-2 py-0.5 rounded-full font-medium">
              Confusion hotspot
            </span>
          )}
        </div>
        <Link
          href={`/updates?incidentCode=${incidentCode}&intent=${cluster.intent}`}
          className="text-xs text-blue-600 hover:text-blue-800 font-medium"
        >
          Publish Update
        </Link>
      </div>
      <ul className="text-sm text-gray-600 space-y-1">
        {cluster.examples.map((ex, i) => (
          <li key={i} className="truncate">
            &ldquo;{ex}&rdquo;
          </li>
        ))}
      </ul>
    </div>
  );
}
