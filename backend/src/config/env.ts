/**
 * Environment configuration — loaded once at startup.
 *
 * Validates all required env vars with Zod so the server fails fast
 * with a clear message instead of crashing mid-request.
 */

import "dotenv/config";
import { z } from "zod";

const envSchema = z.object({
  PORT: z.coerce.number().int().positive().default(3001),
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),

  // Supabase
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1),

  // APNs
  APNS_KEY_PATH: z.string().min(1),
  APNS_KEY_ID: z.string().min(1),
  APNS_TEAM_ID: z.string().min(1),
  APNS_BUNDLE_ID: z.string().min(1).default("com.askthealert.app"),
  APNS_ENVIRONMENT: z.enum(["development", "production"]).default("development"),

  // Console auth
  CONSOLE_AUTH_SECRET: z.string().min(1),
});

function loadEnv() {
  const result = envSchema.safeParse(process.env);
  if (!result.success) {
    console.error("❌ Invalid environment variables:");
    for (const issue of result.error.issues) {
      console.error(`   ${issue.path.join(".")}: ${issue.message}`);
    }
    process.exit(1);
  }
  return result.data;
}

export const env = loadEnv();
export type Env = z.infer<typeof envSchema>;
