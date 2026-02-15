/**
 * Alert Composer — Create and send a new alert push notification.
 *
 * Simplified for hackathon:
 * - Auto-generates a unique incident code
 * - Always sends to ALL eligible devices
 * - Simple form: title, severity, body, region
 * - Preview before sending
 */

"use client";

import { useState } from "react";
import { sendAlert } from "../../../lib/api";
import type { AlertSeverity } from "@askthealert/shared";
import Link from "next/link";

/** Generate a unique incident code like TOR-2026-0214-003 */
function generateIncidentCode(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  const seq = String(Math.floor(Math.random() * 900) + 100); // 3-digit random
  return `TOR-${year}-${month}${day}-${seq}`;
}

export default function NewAlertPage() {
  const [incidentCode] = useState(generateIncidentCode);
  const [title, setTitle] = useState("Tornado Warning \u2013 Waterloo Region");
  const [body, setBody] = useState("");
  const [severity, setSeverity] = useState<AlertSeverity>("critical");
  const [region, setRegion] = useState("Waterloo Region");
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showPreview, setShowPreview] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();

    if (showPreview) {
      setSending(true);
      setResult(null);
      setError(null);

      try {
        const resp = await sendAlert({
          incidentCode,
          title,
          severity,
          body,
          region,
          targeting: "all",
        });

        setResult(
          `Alert sent to ${resp.sent} of ${resp.total} device(s).${resp.pruned > 0 ? ` ${resp.pruned} invalid token(s) pruned.` : ""}`
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
            Create a new incident and push a notification to all citizens.
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
            <Link
              href="/alerts/new"
              className="text-sm text-gray-600 hover:underline"
            >
              Send Another Alert
            </Link>
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
          sending={sending}
          error={error}
          onConfirm={handleSubmit}
          onBack={handleBack}
        />
      )}

      {!showPreview && !result && (
        <form onSubmit={handleSubmit} className="space-y-5">
          {/* Auto-generated incident code (read-only) */}
          <div className="bg-gray-50 border border-gray-200 rounded-lg p-3 flex items-center justify-between">
            <div>
              <p className="text-xs text-gray-500">Incident Code (auto-generated)</p>
              <p className="font-mono text-sm font-bold text-gray-800">{incidentCode}</p>
            </div>
          </div>

          {/* Title */}
          <Field label="Title" required>
            <input
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Tornado Warning \u2013 Waterloo Region"
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

          {/* Info: sends to all devices */}
          <div className="bg-blue-50 border border-blue-200 rounded-lg p-3 text-sm text-blue-700">
            This alert will be sent as a push notification to <strong>all eligible devices</strong>.
          </div>

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
  sending: boolean;
  error: string | null;
  onConfirm: (e: React.FormEvent) => void;
  onBack: () => void;
}) {

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
          <span>Target: All eligible devices</span>
        </div>
      </div>

      <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-sm text-amber-800">
        This will send a push notification to <strong>all eligible devices</strong>.
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
