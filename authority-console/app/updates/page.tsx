/**
 * Update Composer — Publish a follow-up update for an active incident.
 *
 * Features:
 * - Incident selector dropdown (no manual typing needed)
 * - Pre-fill from URL query params (incidentCode, intent)
 * - Suggested update templates based on intent
 * - Sends via backend POST /updates
 * - Shows result with link to incident dashboard
 */

"use client";

import { useState, useEffect } from "react";
import { useSearchParams } from "next/navigation";
import Link from "next/link";
import {
  publishUpdate,
  listIncidents,
  getClusters,
  type IncidentSummary,
  type ClustersResponse,
} from "../../lib/api";

// Template suggestions for common intents
const INTENT_TEMPLATES: Record<string, string> = {
  shelter_guidance:
    "Updated Shelter Guidance: The nearest public shelter is now open at [LOCATION]. Please bring essential supplies. If you cannot reach a shelter, move to the lowest interior room of a sturdy building.",
  evacuation_guidance:
    "Evacuation Update: Evacuation routes have been updated. Use [ROUTE] to exit the affected area. Avoid [BLOCKED ROUTES]. Emergency personnel are directing traffic at key intersections.",
  area_zone_affected:
    "Affected Area Update: The affected zone has been [expanded/reduced] to include [AREAS]. Residents in [NEW AREAS] should [take action].",
  duration_status:
    "Status Update: The current situation is [improving/stable/worsening]. The warning is expected to remain in effect until [TIME]. We will provide updates as conditions change.",
  road_closures_travel:
    "Travel Update: The following roads are currently closed: [ROADS]. Alternate routes: [ALTERNATIVES]. Conditions are expected to [improve/persist] for the next [TIME PERIOD].",
  water_utilities:
    "Utility Update: [Water/Power/Gas] service has been [restored/disrupted] in [AREAS]. Expected restoration time: [TIME]. If you experience an outage, please report it to [CONTACT].",
  medical_immediate_danger:
    "URGENT: If you are in immediate danger, call 911. Do not attempt to return to damaged areas. First aid stations are available at [LOCATIONS].",
  general_clarification:
    "Clarification: To address common questions - [CLARIFICATION]. For more information, visit [URL] or call [PHONE].",
};

export default function UpdatesPage() {
  const searchParams = useSearchParams();
  const prefilledCode = searchParams.get("incidentCode") ?? "";
  const prefilledIntent = searchParams.get("intent") ?? "";

  const [incidents, setIncidents] = useState<IncidentSummary[]>([]);
  const [incidentCode, setIncidentCode] = useState(prefilledCode);
  const [updateText, setUpdateText] = useState(
    prefilledIntent && INTENT_TEMPLATES[prefilledIntent]
      ? INTENT_TEMPLATES[prefilledIntent]
      : ""
  );
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [clusters, setClusters] = useState<ClustersResponse["clusters"]>([]);
  const [loadingClusters, setLoadingClusters] = useState(false);

  // Fetch incidents
  useEffect(() => {
    listIncidents(20)
      .then((data) => {
        setIncidents(data.incidents);
        if (!incidentCode && data.incidents.length > 0) {
          setIncidentCode(data.incidents[0].incidentCode);
        }
      })
      .catch(() => {});
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // Fetch clusters when incident changes
  useEffect(() => {
    if (!incidentCode) {
      setClusters([]);
      return;
    }
    setLoadingClusters(true);
    getClusters(incidentCode)
      .then((data) => setClusters(data.clusters))
      .catch(() => setClusters([]))
      .finally(() => setLoadingClusters(false));
  }, [incidentCode]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSending(true);
    setResult(null);
    setError(null);

    try {
      const resp = await publishUpdate({
        incidentCode,
        updateText,
        source: "authority_console",
      });
      setResult(
        `Update sent to ${resp.sent}/${resp.total} device(s). ${resp.pruned} pruned.`
      );
      setUpdateText("");
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to publish update");
    } finally {
      setSending(false);
    }
  }

  return (
    <div className="max-w-3xl space-y-6">
      <div className="flex items-center gap-3">
        <Link
          href="/"
          className="text-gray-400 hover:text-gray-600 transition-colors"
        >
          &larr;
        </Link>
        <div>
          <h1 className="text-2xl font-bold">Publish Update</h1>
          <p className="text-gray-500 mt-1">
            Send a follow-up update to citizens about an active incident.
          </p>
        </div>
      </div>

      {result && (
        <div className="bg-green-50 border border-green-200 rounded-lg p-4">
          <p className="text-green-700 text-sm font-medium">{result}</p>
          <div className="mt-3 flex gap-3">
            <Link
              href={`/incidents/${encodeURIComponent(incidentCode)}`}
              className="text-sm text-green-700 font-medium hover:underline"
            >
              View Incident Dashboard &rarr;
            </Link>
            <button
              onClick={() => setResult(null)}
              className="text-sm text-gray-600 hover:underline"
            >
              Send Another Update
            </button>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Main form */}
        <div className="lg:col-span-2">
          <form onSubmit={handleSubmit} className="space-y-4">
            {/* Incident Selector */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Incident <span className="text-red-500">*</span>
              </label>
              {incidents.length > 0 ? (
                <select
                  value={incidentCode}
                  onChange={(e) => setIncidentCode(e.target.value)}
                  className="input"
                  required
                >
                  <option value="">Select an incident...</option>
                  {incidents.map((inc) => (
                    <option key={inc.incidentCode} value={inc.incidentCode}>
                      {inc.title} — {inc.incidentCode}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  type="text"
                  value={incidentCode}
                  onChange={(e) => setIncidentCode(e.target.value)}
                  placeholder="TOR-2026-0214-001"
                  className="input"
                  required
                />
              )}
            </div>

            {/* Update Text */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Update Text <span className="text-red-500">*</span>
              </label>
              <textarea
                value={updateText}
                onChange={(e) => setUpdateText(e.target.value)}
                placeholder="The tornado warning has been downgraded to a tornado watch. Continue to monitor weather conditions..."
                className="input min-h-[180px]"
                required
              />
              <p className="text-xs text-gray-400 mt-1">
                {updateText.length} characters. This text is sent as a push notification
                and read aloud by the voice assistant.
              </p>
            </div>

            <div className="flex gap-3 pt-2">
              <button
                type="submit"
                disabled={sending || !incidentCode || !updateText}
                className="bg-blue-600 text-white px-6 py-2.5 rounded-lg font-medium hover:bg-blue-700 disabled:opacity-50 transition-colors"
              >
                {sending ? "Publishing..." : "Publish Update"}
              </button>
              <Link
                href="/"
                className="border border-gray-300 text-gray-700 px-6 py-2.5 rounded-lg font-medium hover:bg-gray-50 transition-colors"
              >
                Cancel
              </Link>
            </div>

            {error && (
              <div className="bg-red-50 border border-red-200 rounded-lg p-3 text-sm text-red-700">
                {error}
              </div>
            )}
          </form>
        </div>

        {/* Sidebar: Quick templates from clusters */}
        <div className="space-y-4">
          <div>
            <h3 className="text-sm font-semibold text-gray-700 mb-2">
              Quick Templates
            </h3>
            <p className="text-xs text-gray-400 mb-3">
              Click a template to pre-fill the update text based on citizen questions.
            </p>
          </div>

          {loadingClusters && (
            <div className="space-y-2">
              {[...Array(3)].map((_, i) => (
                <div
                  key={i}
                  className="bg-gray-100 rounded-lg p-3 animate-pulse h-16"
                />
              ))}
            </div>
          )}

          {!loadingClusters && clusters.length === 0 && (
            <div className="bg-gray-50 border border-gray-200 rounded-lg p-3 text-xs text-gray-400 text-center">
              No question clusters available yet.
            </div>
          )}

          {!loadingClusters &&
            clusters.map((cluster) => {
              const template = INTENT_TEMPLATES[cluster.intent];
              return (
                <button
                  key={cluster.intent}
                  type="button"
                  onClick={() => {
                    if (template) setUpdateText(template);
                  }}
                  disabled={!template}
                  className={`w-full text-left rounded-lg border p-3 transition-colors ${
                    cluster.confusionFlag
                      ? "border-yellow-400 bg-yellow-50 hover:bg-yellow-100"
                      : "border-gray-200 bg-white hover:bg-gray-50"
                  } ${!template ? "opacity-50 cursor-not-allowed" : "cursor-pointer"}`}
                >
                  <div className="flex items-center justify-between mb-1">
                    <span className="text-xs font-semibold text-gray-700 capitalize">
                      {cluster.intent.replace(/_/g, " ")}
                    </span>
                    <span className="text-xs bg-gray-100 text-gray-600 px-1.5 py-0.5 rounded-full">
                      {cluster.count}
                    </span>
                  </div>
                  {cluster.confusionFlag && (
                    <span className="text-xs text-yellow-700 font-medium">
                      Confusion hotspot
                    </span>
                  )}
                  {cluster.examples.length > 0 && (
                    <p className="text-xs text-gray-500 mt-1 truncate">
                      &ldquo;{cluster.examples[0]}&rdquo;
                    </p>
                  )}
                </button>
              );
            })}
        </div>
      </div>
    </div>
  );
}
