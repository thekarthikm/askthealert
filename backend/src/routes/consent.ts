/**
 * Telemetry Consent & PII Minimization Routes
 *
 * GET  /consent/policy — Returns the telemetry consent policy text and config
 * POST /consent/check  — Validates PII content in a text sample (for client preview)
 *
 * The iOS app must show the consent prompt ("By continuing, you agree to share
 * anonymous usage telemetry") before sending any telemetry. The backend enforces
 * consent_given on each event, and applies PII redaction as a safety net.
 *
 * This is a defense-in-depth approach: the client is responsible for showing
 * the consent UX, the backend verifies and enforces.
 */

import { Router } from "express";
import { z } from "zod";
import { redactPII, containsPII } from "../services/piiRedaction.js";

export const consentRouter = Router();

/** The telemetry consent policy — defines what data is collected and how. */
const CONSENT_POLICY = {
  version: "1.0.0",
  effectiveDate: "2026-02-14",

  /** Short consent prompt for the iOS app. */
  promptText:
    "By continuing, you agree to share anonymous usage telemetry to help authorities " +
    "understand what citizens need during emergencies. No names, addresses, or personal " +
    "identifiers are stored.",

  /** Detailed policy for settings / about screen. */
  detailedPolicy: [
    "We collect anonymous telemetry to help emergency authorities understand citizen needs.",
    "Data collected includes: alert interactions (opened, spoke), question topics (categorized by intent), and satisfaction responses.",
    "We do NOT collect: names, addresses, phone numbers, email addresses, or any other personal identifiers.",
    "All text is automatically sanitized to remove any accidentally included personal information before storage.",
    "Telemetry is associated with incident codes only — not with your device identity.",
    "You can withdraw consent at any time in Settings. Previously collected data will be retained in anonymized aggregate form only.",
    "Data is retained for 30 days in raw form, then rolled up into anonymous daily summaries.",
  ],

  /** What data is collected by event type. */
  dataCollected: {
    received: "Alert was delivered to device (no content stored)",
    opened: "User opened the alert detail screen (no content stored)",
    spoke: "User initiated a voice interaction (no speech content stored)",
    question: "User asked a question — only the intent category and sanitized topic are stored, never the full transcript",
    satisfaction: "User responded to satisfaction prompt — yes/no only",
  },

  /** PII categories that are redacted. */
  piiRedacted: [
    "Phone numbers",
    "Email addresses",
    "Social Insurance Numbers (SIN)",
    "Street addresses",
    "Names (when preceded by common phrases like 'my name is')",
    "Postal codes",
  ],

  /** Configuration for the consent UX. */
  config: {
    /** When to show consent prompt. */
    showPrompt: "first_incident_open",
    /** Whether consent is required to use the app. */
    required: false,
    /** Whether telemetry works without consent. */
    appWorksWithoutConsent: true,
    /** Retention period for raw events. */
    retentionDays: 30,
  },
};

/**
 * GET /consent/policy
 *
 * Returns the consent policy, prompt text, and configuration.
 * The iOS app fetches this on first launch or when policy version changes.
 */
consentRouter.get("/policy", (_req, res) => {
  res.status(200).json(CONSENT_POLICY);
});

const checkSchema = z.object({
  text: z.string().min(1).max(1000),
});

/**
 * POST /consent/check
 *
 * Client-side PII preview: sends a text sample and gets back whether PII
 * was detected and the redacted version. Useful for the iOS app to show
 * the user what would be stored.
 */
consentRouter.post("/check", (req, res) => {
  const parsed = checkSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request", details: parsed.error.issues });
    return;
  }

  const { text } = parsed.data;
  const hasPII = containsPII(text);
  const redacted = redactPII(text);

  res.status(200).json({
    containsPII: hasPII,
    redactedText: redacted,
    originalLength: text.length,
    redactedLength: redacted.length,
  });
});
