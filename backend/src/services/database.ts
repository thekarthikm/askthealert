/**
 * Supabase Postgres client — single instance per process.
 *
 * Backend storage is Supabase Postgres only; SQLite is not used on the server.
 * pgvector extension is used for online RAG embeddings.
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { env } from "../config/env.js";

let _client: SupabaseClient | null = null;

/**
 * Returns the singleton Supabase client.
 * Uses the service-role key for full backend access (bypasses RLS).
 */
export function getSupabase(): SupabaseClient {
  if (!_client) {
    _client = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return _client;
}
