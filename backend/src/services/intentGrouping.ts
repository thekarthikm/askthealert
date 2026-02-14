/**
 * Rule-based intent grouping service.
 *
 * Categorises citizen questions into intent buckets using keyword/phrase
 * pattern matching with confidence scoring. No ML, no embeddings — reliable,
 * fast, and demo-friendly.
 */

import type { IntentCategory, IntentCluster } from "@askthealert/shared";
import { INTENT_LABELS } from "@askthealert/shared";

/** A pattern rule for a single intent. */
interface PatternRule {
  intent: IntentCategory;
  /** Lowercase phrases/keywords. */
  patterns: string[];
  /** Base confidence when any pattern matches. */
  baseConfidence: number;
}

const RULES: PatternRule[] = [
  {
    intent: "shelter_guidance",
    patterns: [
      "where to shelter", "shelter in place", "safe room", "basement",
      "lowest level", "windowless room", "interior room", "take shelter",
      "go to basement", "where do i go", "where should i go",
    ],
    baseConfidence: 0.85,
  },
  {
    intent: "evacuation_guidance",
    patterns: [
      "should i leave", "evacuation route", "when to evacuate", "evacuate",
      "leave my home", "get out", "leave the area", "should i stay or go",
    ],
    baseConfidence: 0.85,
  },
  {
    intent: "area_zone_affected",
    patterns: [
      "am i in the area", "which neighborhoods", "zone boundaries",
      "affected area", "is my area", "which zone", "my neighbourhood",
      "is waterloo", "is kitchener", "my street",
    ],
    baseConfidence: 0.80,
  },
  {
    intent: "duration_status",
    patterns: [
      "how long", "when will it end", "current status", "is it over",
      "still active", "how much longer", "when is it safe", "all clear",
    ],
    baseConfidence: 0.80,
  },
  {
    intent: "road_closures_travel",
    patterns: [
      "roads closed", "can i drive", "travel safe", "highway", "road closure",
      "driving", "commute", "traffic", "route", "bridge",
    ],
    baseConfidence: 0.80,
  },
  {
    intent: "water_utilities",
    patterns: [
      "water safe", "power outage", "utilities", "electricity", "gas leak",
      "drinking water", "boil water", "hydro", "water main",
    ],
    baseConfidence: 0.75,
  },
  {
    intent: "reporting_witnessing",
    patterns: [
      "i saw", "report", "witness", "spotted", "i see a", "there is a",
      "funnel cloud", "debris", "damage",
    ],
    baseConfidence: 0.75,
  },
  {
    intent: "medical_immediate_danger",
    patterns: [
      "injured", "emergency", "911", "call 911", "bleeding", "trapped",
      "help me", "someone is hurt", "medical", "ambulance", "fire",
    ],
    baseConfidence: 0.95,
  },
  {
    intent: "general_clarification",
    patterns: [
      "what does", "what is a", "explain", "clarify", "mean", "what do i do",
      "i don't understand", "confused", "what's the difference",
    ],
    baseConfidence: 0.60,
  },
];

/** Normalise text for matching: lowercase, strip punctuation, collapse whitespace. */
function normalise(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Classify a single question text. Returns the best intent + confidence. */
export function classifyIntent(
  text: string
): { intent: IntentCategory; confidence: number } {
  const norm = normalise(text);
  let bestIntent: IntentCategory = "other_unclear";
  let bestConfidence = 0;

  for (const rule of RULES) {
    let matchCount = 0;
    for (const pattern of rule.patterns) {
      if (norm.includes(pattern)) {
        matchCount++;
      }
    }
    if (matchCount > 0) {
      // Boost confidence slightly for multiple pattern matches
      const confidence = Math.min(
        rule.baseConfidence + (matchCount - 1) * 0.05,
        1.0
      );
      if (confidence > bestConfidence) {
        bestConfidence = confidence;
        bestIntent = rule.intent;
      }
    }
  }

  return { intent: bestIntent, confidence: bestConfidence };
}

/**
 * Detect confusion flags for an incident's question set.
 *
 * A confusion flag is raised when:
 * - "what does X mean" appears repeatedly for the same incident
 * - Repeat rate for an intent exceeds a threshold
 */
export function detectConfusion(
  questions: Array<{ text: string; intent: IntentCategory }>
): Set<IntentCategory> {
  const confusedIntents = new Set<IntentCategory>();
  const intentCounts = new Map<IntentCategory, number>();

  for (const q of questions) {
    intentCounts.set(q.intent, (intentCounts.get(q.intent) ?? 0) + 1);
  }

  // Flag intents with high repeat rate (>= 3 questions, > 30% of total)
  const total = questions.length;
  for (const [intent, count] of intentCounts) {
    if (count >= 3 && count / total > 0.3) {
      confusedIntents.add(intent);
    }
  }

  // Flag explicit "what does X mean" confusion
  const clarificationCount = intentCounts.get("general_clarification") ?? 0;
  if (clarificationCount >= 2) {
    confusedIntents.add("general_clarification");
  }

  return confusedIntents;
}

/**
 * Build intent clusters from a set of classified questions.
 *
 * Returns one IntentCluster per category that has at least one question,
 * with up to 5 example questions and a confusion flag.
 */
export function buildIntentClusters(
  questions: Array<{ text: string; intent: IntentCategory }>
): IntentCluster[] {
  const buckets = new Map<IntentCategory, string[]>();

  for (const q of questions) {
    const existing = buckets.get(q.intent) ?? [];
    existing.push(q.text);
    buckets.set(q.intent, existing);
  }

  const confusedIntents = detectConfusion(questions);

  const clusters: IntentCluster[] = [];
  for (const [intent, texts] of buckets) {
    clusters.push({
      intent,
      count: texts.length,
      examples: texts.slice(0, 5),
      confusionFlag: confusedIntents.has(intent),
    });
  }

  // Sort by count descending
  clusters.sort((a, b) => b.count - a.count);
  return clusters;
}
