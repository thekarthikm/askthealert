/**
 * Intent categories for rule-based question grouping.
 *
 * Used by the backend intent-grouping service and displayed in the Authority Console.
 * Shared between backend and Authority Console.
 */

/** All recognised intent categories. */
export type IntentCategory =
  | "shelter_guidance"
  | "evacuation_guidance"
  | "area_zone_affected"
  | "duration_status"
  | "road_closures_travel"
  | "water_utilities"
  | "reporting_witnessing"
  | "medical_immediate_danger"
  | "general_clarification"
  | "other_unclear";

/** Human-readable labels for each intent category. */
export const INTENT_LABELS: Record<IntentCategory, string> = {
  shelter_guidance: "Shelter guidance",
  evacuation_guidance: "Evacuation guidance",
  area_zone_affected: "Area or zone affected",
  duration_status: "Duration and status",
  road_closures_travel: "Road closures and travel safety",
  water_utilities: "Water safety and utilities",
  reporting_witnessing: "Reporting or witnessing something",
  medical_immediate_danger: "Medical or immediate danger",
  general_clarification: "General clarification",
  other_unclear: "Other / unclear",
};

/** A cluster of questions grouped by intent, shown in the Authority Console. */
export interface IntentCluster {
  /** The intent category. */
  intent: IntentCategory;

  /** Total question count for this intent within the incident. */
  count: number;

  /** Up to 5 example questions (PII-minimized). */
  examples: string[];

  /** True if this intent shows signs of confusion (high repeat rate). */
  confusionFlag: boolean;
}
