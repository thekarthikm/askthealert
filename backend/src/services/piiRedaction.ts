/**
 * PII Redaction Service — removes personally identifiable information
 * from telemetry text before storage.
 *
 * Patterns redacted:
 *   - Phone numbers (North American formats)
 *   - Email addresses
 *   - Social Insurance Numbers (SIN)
 *   - Street addresses (common formats)
 *   - Names preceded by common prefixes ("my name is", "I'm", etc.)
 *
 * This runs server-side as a second defence layer. The iOS client should
 * also strip PII before sending, but we enforce it here for safety.
 *
 * ⚠️ SECURITY WARNING (LIMITATIONS):
 * Regex-based PII redaction will MISS edge cases:
 *   - Names without prefixes ("John called 911", "Sarah's location")
 *   - Non-standard address formats ("behind the Walmart on Victoria")
 *   - Location landmarks ("near King and University intersection")
 *   - Uncommon phone formats (international, extensions)
 *   - Embedded identifiers in natural speech patterns
 *
 * For production, consider additional safeguards:
 *   - Text length caps (e.g., max 200 chars per event)
 *   - Allowlist strategy: store only intent_label + topic_summary
 *   - ML-based NER (Named Entity Recognition) for better coverage
 *   - Mandatory client-side stripping before transmission
 *   - Periodic audits of stored text for PII leakage
 */

/** Compiled regex patterns for PII detection. */
const PII_PATTERNS: Array<{ regex: RegExp; replacement: string }> = [
  // Phone numbers: +1 (519) 555-1234, 519-555-1234, 5195551234, etc.
  {
    regex: /\+?1?[-.\s]?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}/g,
    replacement: "[PHONE]",
  },
  // Email addresses
  {
    regex: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g,
    replacement: "[EMAIL]",
  },
  // Social Insurance Number (Canadian SIN): 123 456 789, 123-456-789
  {
    regex: /\b\d{3}[-\s]?\d{3}[-\s]?\d{3}\b/g,
    replacement: "[SIN]",
  },
  // Street addresses: "123 Main Street", "45 King St", etc.
  {
    regex: /\b\d{1,5}\s+[A-Za-z]+\s+(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Boulevard|Blvd|Lane|Ln|Court|Ct|Way|Place|Pl|Crescent|Cres)\b/gi,
    replacement: "[ADDRESS]",
  },
  // Name prefixes: "my name is John", "I'm Sarah", "this is David speaking"
  {
    regex: /\b(?:my name is|i'?m|this is|i am)\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b/gi,
    replacement: "[NAME]",
  },
  // Postal codes (Canadian): K2A 1B3, M5V2T6
  {
    regex: /\b[A-Za-z]\d[A-Za-z]\s?\d[A-Za-z]\d\b/g,
    replacement: "[POSTAL]",
  },
];

/**
 * Redact PII from a text string.
 *
 * @param text - The raw text to sanitize
 * @returns The text with PII replaced by placeholder tokens
 */
export function redactPII(text: string): string {
  if (!text) return text;

  let sanitized = text;
  for (const { regex, replacement } of PII_PATTERNS) {
    sanitized = sanitized.replace(regex, replacement);
  }

  return sanitized;
}

/**
 * Check if text contains any PII.
 *
 * @param text - The text to check
 * @returns true if PII patterns are detected
 */
export function containsPII(text: string): boolean {
  if (!text) return false;

  for (const { regex } of PII_PATTERNS) {
    // Reset lastIndex for global regexes
    regex.lastIndex = 0;
    if (regex.test(text)) {
      regex.lastIndex = 0;
      return true;
    }
  }

  return false;
}
