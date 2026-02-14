/**
 * Satisfaction & ActionBlocker Policy Routes
 *
 * GET  /satisfaction/policy — Returns when/how satisfaction is asked
 * GET  /satisfaction/:incidentCode — Get satisfaction stats for an incident
 * GET  /satisfaction/:incidentCode/blockers — Get action blocker breakdown
 *
 * Satisfaction prompt policy:
 *   - Ask after the first complete answer (post-first-response)
 *   - Ask again at end of conversation (session end / user says goodbye)
 *   - Maximum 2 prompts per session to avoid survey fatigue
 *   - Simple yes/no format for voice interaction
 *
 * ActionBlocker classification:
 *   - Set via voice classification keywords in the VoiceAgentService
 *   - Categories: driving, condo (high-rise/no basement), kids, disability
 *   - Helps authorities understand situational constraints
 *   - Out of scope for demo: full NLU classification — we use keyword matching
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";

export const satisfactionRouter = Router();

/** The satisfaction prompt policy — defines when and how to ask. */
const SATISFACTION_POLICY = {
  version: "1.0.0",

  /** When to show satisfaction prompts. */
  triggers: [
    {
      id: "post_first_response",
      description: "After the voice agent delivers its first complete answer",
      prompt: "Was that answer helpful?",
      voicePrompt: "Was that helpful? You can say yes or no.",
      timing: "immediately_after_first_answer",
    },
    {
      id: "session_end",
      description: "When the user ends the voice session or says goodbye",
      prompt: "Overall, was the voice assistant helpful?",
      voicePrompt: "Before you go — was the voice assistant helpful overall? Yes or no.",
      timing: "on_session_end",
    },
  ],

  /** Maximum number of satisfaction prompts per session. */
  maxPromptsPerSession: 2,

  /** Response format. */
  responseFormat: "yes_no",

  /** ActionBlocker detection keywords. */
  actionBlockerKeywords: {
    driving: [
      "driving", "in the car", "on the road", "behind the wheel",
      "can't pull over", "highway", "in traffic",
    ],
    condo: [
      "condo", "apartment", "high rise", "high-rise", "no basement",
      "upper floor", "penthouse", "top floor", "don't have a basement",
    ],
    kids: [
      "kids", "children", "baby", "toddler", "infant", "my child",
      "with kids", "young children", "school age",
    ],
    disability: [
      "wheelchair", "disabled", "disability", "mobility issue",
      "can't walk", "blind", "deaf", "hearing impaired", "mobility",
      "crutches", "walker",
    ],
  },

  /** How actionBlocker is detected. */
  detectionMethod: "keyword_matching_in_voice_transcript",
  detectionNote:
    "The iOS VoiceAgentService scans each user utterance for actionBlocker keywords. " +
    "When detected, the blocker is recorded in the telemetry question event. " +
    "The voice agent also adapts its response (e.g., 'Since you're driving...'). " +
    "Full NLU classification is out of scope for the demo.",
};

/**
 * GET /satisfaction/policy
 *
 * Returns the satisfaction prompt policy and actionBlocker configuration.
 */
satisfactionRouter.get("/policy", (_req, res) => {
  res.status(200).json(SATISFACTION_POLICY);
});

const paramsSchema = z.object({
  incidentCode: z.string().min(1),
});

/**
 * GET /satisfaction/:incidentCode
 *
 * Returns satisfaction statistics for an incident:
 *   - Total responses
 *   - Yes / No counts
 *   - Satisfaction rate (percentage)
 */
satisfactionRouter.get("/:incidentCode", async (req, res) => {
  const paramParsed = paramsSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;
  const supabase = getSupabase();

  const { data, error } = await supabase
    .from("telemetry_events")
    .select("satisfaction_yes_no")
    .eq("incident_code", incidentCode)
    .eq("event_type", "satisfaction")
    .not("satisfaction_yes_no", "is", null);

  if (error) {
    console.error("Failed to fetch satisfaction data:", error);
    res.status(500).json({ error: "Failed to fetch satisfaction data" });
    return;
  }

  const responses = data ?? [];
  const yesCount = responses.filter((r) => r.satisfaction_yes_no === true).length;
  const noCount = responses.filter((r) => r.satisfaction_yes_no === false).length;
  const total = yesCount + noCount;

  res.status(200).json({
    incidentCode,
    total,
    yes: yesCount,
    no: noCount,
    satisfactionRate: total > 0 ? Math.round((yesCount / total) * 100) : null,
    timestamp: new Date().toISOString(),
  });
});

/**
 * GET /satisfaction/:incidentCode/blockers
 *
 * Returns action blocker breakdown for an incident.
 */
satisfactionRouter.get("/:incidentCode/blockers", async (req, res) => {
  const paramParsed = paramsSchema.safeParse(req.params);
  if (!paramParsed.success) {
    res.status(400).json({ error: "Invalid incident code" });
    return;
  }

  const { incidentCode } = paramParsed.data;
  const supabase = getSupabase();

  const { data, error } = await supabase
    .from("telemetry_events")
    .select("action_blocker")
    .eq("incident_code", incidentCode)
    .not("action_blocker", "is", null);

  if (error) {
    console.error("Failed to fetch blocker data:", error);
    res.status(500).json({ error: "Failed to fetch blocker data" });
    return;
  }

  const blockers = data ?? [];
  const breakdown: Record<string, number> = {};

  for (const b of blockers) {
    const key = b.action_blocker as string;
    breakdown[key] = (breakdown[key] ?? 0) + 1;
  }

  res.status(200).json({
    incidentCode,
    total: blockers.length,
    breakdown,
    timestamp: new Date().toISOString(),
  });
});
