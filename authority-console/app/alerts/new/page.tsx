/**
 * Alert Composer — Create and send a new alert push notification.
 *
 * Features:
 * - Incident code, title, body, severity, region
 * - Targeting: all devices, by device label, or by region
 * - Preview before sending
 * - Sends via backend POST /alerts
 */

"use client";

import { useState, useEffect } from "react";
import { sendAlert, listIncidents, type IncidentSummary } from "../../../lib/api";
import type { AlertSeverity } from "@askthealert/shared";
import Link from "next/link";

type TargetingMode = "all" | "label" | "region";

export default function NewAlertPage() {
  const [incidentCode, setIncidentCode] = useState("");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [severity, setSeverity] = useState<AlertSeverity>("warning");
  const [region, setRegion] = useState("Waterloo Region");
  const [targetingMode, setTargetingMode] = useState<TargetingMode>("all");
  const [targetLabel, setTargetLabel] = useState("");
  const [targetRegion, setTargetRegion] = useState("");
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showPreview, setShowPreview] = useState(false);
  const [existingIncidents, setExistingIncidents] = useState<IncidentSummary[]>([]);

  // Fetch existing incidents for code suggestions
  useEffect(() => {
    listIncidents(10)
      .then((data) => setExistingIncidents(data.incidents))
      .catch(() => {});
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();

    if (showPreview) {
      // Actually send
      setSending(true);
      setResult(null);
      setError(null);

      try {
        let targeting: "all" | string[] | { label: string };
        if (targetingMode === "label" && targetLabel) {
          targeting = { label: targetLabel };
        } else if (targetingMode === "region" && targetRegion) {
          // Region targeting uses label matching on device label
          targeting = { label: targetRegion };
        } else {
          targeting = "all";
        }

        const resp = await sendAlert({
          incidentCode,
          title,
          severity,
          body,
          region,
          targeting,
        });
        setResult(
          `Alert sent to ${resp.sent}/${resp.total} device(s). ${resp.pruned} pruned.`
        );
        setShowPreview(false);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : "Failed to send alert");
      } finally {
        setSending(false);
      }
    } else {
      setShowPreview(true);
    }
  }

  function handleBack() {
    setShowPreview(false);
    setResult(null);
    setError(null);
  }

  const severityInfo: Record<AlertSeverity, { color: string; bg: string; description: string }> = {
    info: {
      color: "text-blue-700",
      bg: "bg-blue-50 border-blue-200",
      description: "General information, no immediate action needed",
    },
    warning: {
      color: "text-yellow-700",
      bg: "bg-yellow-50 border-yellow-200",
      description: "Potential danger, prepare to take action",
    },
    critical: {
      color: "text-red-700",
      bg: "bg-red-50 border-red-200",
      description: "Immediate danger, take protective action now",
    },
  };

  return (
    <div className="max-w-2xl space-y-6">
      <div className="flex items-center gap-3">
        <Link
          href="/"
          className="text-gray-400 hover:text-gray-600 transition-colors"
        >
          &larr;
        </Link>
        <div>
          <h1 className="text-2xl font-bold">Send Alert</h1>
          <p className="text-gray-500 mt-1">
            Create a new incident and push a notification to citizens.
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
              onClick={() => {
                setResult(null);
                setIncidentCode("");
                setTitle("");
                setBody("");
              }}
              className="text-sm text-gray-600 hover:underline"
            >
              Send Another
            </button>
          </div>
        </div>
      )}

      {showPreview && !result && (
        <AlertPreview
          incidentCode={incidentCode}
          title={title}
          severity={severity}
          body={body}
          region={region}
          targetingMode={targetingMode}
          targetLabel={targetLabel}
          targetRegion={targetRegion}
          sending={sending}
          error={error}
          onConfirm={handleSubmit}
          onBack={handleBack}
        />
      )}

      {!showPreview && !result && (
        <form onSubmit={handleSubmit} className="space-y-5">
          {/* Existing incidents hint */}
          {existingIncidents.length > 0 && (
            <div className="bg-gray-50 border border-gray-200 rounded-lg p-3">
              <p className="text-xs text-gray-500 mb-1">Existing incidents:</p>
              <div className="flex flex-wrap gap-2">
                {existingIncidents.map((inc) => (
                  <button
                    key={inc.incidentCode}
                    type="button"
                    onClick={() => {
                      setIncidentCode(inc.incidentCode);
                      setTitle(inc.title);
                      setRegion(inc.region);
                      setSeverity(inc.severity as AlertSeverity);
                    }}
                    className="text-xs bg-white border border-gray-200 px-2 py-1 rounded hover:bg-gray-100 transition-colors"
                  >
                    {inc.incidentCode}
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* Incident Code */}
          <Field label="Incident Code" required>
            <input
              type="text"
              value={incidentCode}
              onChange={(e) => setIncidentCode(e.target.value)}
              placeholder="TOR-2026-0214-001"
              className="input"
              required
            />
            <p className="text-xs text-gray-400 mt-1">
              Unique identifier for this incident. Use existing code to add to an active incident.
            </p>
          </Field>

          {/* Title */}
          <Field label="Title" required>
            <input
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Tornado Warning – Waterloo Region"
              className="input"
              required
            />
          </Field>

          {/* Severity */}
          <Field label="Severity" required>
            <div className="space-y-2">
              {(["info", "warning", "critical"] as AlertSeverity[]).map((sev) => (
                <label
                  key={sev}
                  className={`flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors ${
                    severity === sev
                      ? severityInfo[sev].bg
                      : "border-gray-200 hover:bg-gray-50"
                  }`}
                >
                  <input
                    type="radio"
                    name="severity"
                    value={sev}
                    checked={severity === sev}
                    onChange={() => setSeverity(sev)}
                    className="accent-red-600"
                  />
                  <div>
                    <span
                      className={`font-medium text-sm capitalize ${
                        severity === sev ? severityInfo[sev].color : "text-gray-700"
                      }`}
                    >
                      {sev}
                    </span>
                    <p className="text-xs text-gray-500">
                      {severityInfo[sev].description}
                    </p>
                  </div>
                </label>
              ))}
            </div>
          </Field>

          {/* Body */}
          <Field label="Alert Body" required>
            <textarea
              value={body}
              onChange={(e) => setBody(e.target.value)}
              placeholder="Environment Canada has issued a Tornado Warning for Waterloo Region. Take shelter immediately in the lowest floor of a sturdy building..."
              className="input min-h-[120px]"
              required
            />
            <p className="text-xs text-gray-400 mt-1">
              {body.length}/500 characters. This text is read aloud by the voice assistant.
            </p>
          </Field>

          {/* Region */}
          <Field label="Region" required>
            <input
              type="text"
              value={region}
              onChange={(e) => setRegion(e.target.value)}
              className="input"
              required
            />
          </Field>

          {/* Targeting */}
          <Field label="Targeting">
            <div className="space-y-3">
              <div className="flex gap-4">
                {(
                  [
                    { value: "all", label: "All Devices", desc: "Send to all registered devices" },
                    { value: "label", label: "By Label", desc: "Target specific device(s) by label" },
                    { value: "region", label: "By Region", desc: "Target devices in a specific region" },
                  ] as const
                ).map((opt) => (
                  <label
                    key={opt.value}
                    className={`flex-1 flex items-center gap-2 p-3 rounded-lg border cursor-pointer transition-colors ${
                      targetingMode === opt.value
                        ? "border-blue-500 bg-blue-50"
                        : "border-gray-200 hover:bg-gray-50"
                    }`}
                  >
                    <input
                      type="radio"
                      name="targeting"
                      value={opt.value}
                      checked={targetingMode === opt.value}
                      onChange={() => setTargetingMode(opt.value)}
                      className="accent-blue-600"
                    />
                    <div>
                      <span className="text-sm font-medium">{opt.label}</span>
                      <p className="text-xs text-gray-500">{opt.desc}</p>
                    </div>
                  </label>
                ))}
              </div>

              {targetingMode === "label" && (
                <input
                  type="text"
                  value={targetLabel}
                  onChange={(e) => setTargetLabel(e.target.value)}
                  placeholder="e.g. Karthik's iPhone"
                  className="input"
                />
              )}
              {targetingMode === "region" && (
                <input
                  type="text"
                  value={targetRegion}
                  onChange={(e) => setTargetRegion(e.target.value)}
                  placeholder="e.g. Waterloo Region"
                  className="input"
                />
              )}
            </div>
          </Field>

          {/* Submit */}
          <div className="flex gap-3 pt-2">
            <button
              type="submit"
              className="bg-red-600 text-white px-6 py-2.5 rounded-lg font-medium hover:bg-red-700 transition-colors"
            >
              Preview &amp; Send
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
      )}
    </div>
  );
}

// ── Alert Preview ──────────────────────────────────────────

function AlertPreview({
  incidentCode,
  title,
  severity,
  body,
  region,
  targetingMode,
  targetLabel,
  targetRegion,
  sending,
  error,
  onConfirm,
  onBack,
}: {
  incidentCode: string;
  title: string;
  severity: AlertSeverity;
  body: string;
  region: string;
  targetingMode: TargetingMode;
  targetLabel: string;
  targetRegion: string;
  sending: boolean;
  error: string | null;
  onConfirm: (e: React.FormEvent) => void;
  onBack: () => void;
}) {
  const targetingText =
    targetingMode === "label" && targetLabel
      ? `Device label: ${targetLabel}`
      : targetingMode === "region" && targetRegion
      ? `Region: ${targetRegion}`
      : "All registered devices";

  const severityColors: Record<string, string> = {
    critical: "border-red-500 bg-red-50",
    warning: "border-yellow-500 bg-yellow-50",
    info: "border-blue-500 bg-blue-50",
  };

  return (
    <div className="space-y-4">
      <div
        className={`rounded-lg border-2 p-6 ${
          severityColors[severity] ?? "border-gray-300"
        }`}
      >
        <div className="flex items-center gap-2 mb-3">
          <span className="text-sm font-mono text-gray-500">{incidentCode}</span>
          <span
            className={`text-xs px-2 py-0.5 rounded-full font-bold uppercase ${
              severity === "critical"
                ? "bg-red-200 text-red-800"
                : severity === "warning"
                ? "bg-yellow-200 text-yellow-800"
                : "bg-blue-200 text-blue-800"
            }`}
          >
            {severity}
          </span>
        </div>
        <h3 className="text-xl font-bold mb-2">{title}</h3>
        <p className="text-gray-700 leading-relaxed">{body}</p>
        <div className="flex items-center gap-4 mt-4 text-sm text-gray-500">
          <span>Region: {region}</span>
          <span>Target: {targetingText}</span>
        </div>
      </div>

      <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-sm text-amber-800">
        This will send a push notification to <strong>{targetingText.toLowerCase()}</strong>.
        This action cannot be undone.
      </div>

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-3 text-sm text-red-700">
          {error}
        </div>
      )}

      <div className="flex gap-3">
        <button
          onClick={onConfirm}
          disabled={sending}
          className="bg-red-600 text-white px-6 py-2.5 rounded-lg font-medium hover:bg-red-700 disabled:opacity-50 transition-colors"
        >
          {sending ? "Sending..." : "Confirm & Send"}
        </button>
        <button
          onClick={onBack}
          disabled={sending}
          className="border border-gray-300 text-gray-700 px-6 py-2.5 rounded-lg font-medium hover:bg-gray-50 disabled:opacity-50 transition-colors"
        >
          Edit
        </button>
      </div>
    </div>
  );
}

// ── Field Helper ────────────────────────────────────────────

function Field({
  label,
  required,
  children,
}: {
  label: string;
  required?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div>
      <label className="block text-sm font-medium text-gray-700 mb-1">
        {label}
        {required && <span className="text-red-500 ml-0.5">*</span>}
      </label>
      {children}
    </div>
  );
}
