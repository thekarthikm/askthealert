/**
 * Seed RAG chunks into Supabase from the iOS offline corpus.
 *
 * Usage: npx tsx scripts/seed-rag-chunks.ts
 *
 * This reads the tornado_guidance.json from the iOS resources and inserts
 * each chunk into the rag_chunks Supabase table. Embeddings are not
 * generated here — they will be computed via edge function or external
 * pipeline. The text-search fallback works without embeddings.
 */

import "dotenv/config";
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env");
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

interface CorpusChunk {
  id: string;
  title: string;
  content: string;
  hazardTags: string[];
  regionTags: string[];
  citation: string;
  keywords: string[];
  synonyms: Record<string, string[]>;
}

async function main() {
  // Read the corpus JSON
  const corpusPath = resolve(
    import.meta.dirname ?? ".",
    "../../ios/AskTheAlert/Resources/tornado_guidance.json"
  );

  console.log(`Reading corpus from: ${corpusPath}`);
  const raw = readFileSync(corpusPath, "utf-8");
  const chunks: CorpusChunk[] = JSON.parse(raw);
  console.log(`Found ${chunks.length} chunks to seed`);

  // Check existing chunks
  const { count: existingCount } = await supabase
    .from("rag_chunks")
    .select("*", { count: "exact", head: true });

  if (existingCount && existingCount > 0) {
    console.log(`Found ${existingCount} existing chunks. Clearing table first...`);
    const { error: deleteError } = await supabase
      .from("rag_chunks")
      .delete()
      .eq("is_authority_update", false)
      .is("incident_code", null);

    if (deleteError) {
      console.error("Failed to clear existing chunks:", deleteError);
      process.exit(1);
    }
    console.log("Cleared existing baseline chunks.");
  }

  // Insert in batches of 10
  const BATCH_SIZE = 10;
  let inserted = 0;

  for (let i = 0; i < chunks.length; i += BATCH_SIZE) {
    const batch = chunks.slice(i, i + BATCH_SIZE).map((chunk) => ({
      title: chunk.title,
      content: chunk.content,
      hazard_tags: chunk.hazardTags,
      region_tags: chunk.regionTags,
      citation: chunk.citation,
      is_authority_update: false,
      incident_code: null,
      // embedding is null — will be computed separately
    }));

    const { error } = await supabase.from("rag_chunks").insert(batch);

    if (error) {
      console.error(`Failed to insert batch ${i / BATCH_SIZE + 1}:`, error);
      process.exit(1);
    }

    inserted += batch.length;
    console.log(`  Inserted batch ${Math.floor(i / BATCH_SIZE) + 1}: ${inserted}/${chunks.length} chunks`);
  }

  // Verify
  const { count: finalCount } = await supabase
    .from("rag_chunks")
    .select("*", { count: "exact", head: true });

  console.log(`\nSeeding complete! ${finalCount} chunks in rag_chunks table.`);
}

main().catch((err) => {
  console.error("Seed failed:", err);
  process.exit(1);
});
