/**
 * POST /retrieve — Online RAG retrieval endpoint (Supabase pgvector).
 *
 * Returns top_k chunks + metadata for a query.
 * Strategy:
 *   1. If embedding is provided in request, use pgvector cosine similarity (match_rag_chunks RPC)
 *   2. Otherwise, fall back to full-text search (search_rag_chunks_text RPC)
 *   3. Authority updates for the incident override baseline guidance
 *
 * The iOS client calls this with a 400–800 ms timeout; we must respond fast.
 */

import { Router } from "express";
import { z } from "zod";
import { getSupabase } from "../services/database.js";

export const retrieveRouter = Router();

const retrieveSchema = z.object({
  query: z.string().min(1),
  incidentCode: z.string().min(1),
  topK: z.coerce.number().int().min(1).max(10).default(5),
  /** Optional: pre-computed embedding vector (384 dimensions for gte-small). */
  embedding: z.array(z.number()).length(384).optional(),
  /** Optional: filter by hazard tag (e.g. "tornado"). */
  hazardFilter: z.string().optional(),
});

/** Shape of a chunk returned from the search. */
export interface RetrievedChunk {
  id: string;
  title: string;
  content: string;
  hazardTags: string[];
  regionTags: string[];
  citation: string;
  isAuthorityUpdate: boolean;
  similarity: number;
}

retrieveRouter.post("/", async (req, res) => {
  const parsed = retrieveSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request", details: parsed.error.issues });
    return;
  }

  const { query, incidentCode, topK, embedding, hazardFilter } = parsed.data;
  const supabase = getSupabase();

  let chunks: RetrievedChunk[] = [];

  try {
    if (embedding && embedding.length === 384) {
      // Strategy 1: pgvector cosine similarity search
      const { data, error } = await supabase.rpc("match_rag_chunks", {
        query_embedding: embedding,
        match_count: topK,
        match_threshold: 0.3,
        filter_incident_code: incidentCode,
        filter_hazard_tag: hazardFilter ?? null,
      });

      if (error) {
        console.error("pgvector search failed, falling back to text:", error.message);
        // Fall through to text search
      } else if (data && data.length > 0) {
        chunks = (data as any[]).map(mapChunk);
      }
    }

    // Strategy 2: Full-text search fallback (when no embedding or pgvector returned nothing)
    if (chunks.length === 0) {
      const { data, error } = await supabase.rpc("search_rag_chunks_text", {
        search_query: query,
        match_count: topK,
        filter_incident_code: incidentCode,
        filter_hazard_tag: hazardFilter ?? null,
      });

      if (error) {
        console.error("Text search failed:", error.message);
        // Continue with empty chunks — client has offline fallback
      } else if (data) {
        chunks = (data as any[]).map(mapChunk);
      }
    }

    // Fetch authority updates for the incident (override baseline)
    const { data: authorityUpdates } = await supabase
      .from("updates")
      .select("update_text, timestamp")
      .eq("incident_code", incidentCode)
      .order("timestamp", { ascending: false })
      .limit(5);

    // If there are authority updates, create synthetic chunks at the top
    const updateChunks: RetrievedChunk[] = (authorityUpdates ?? []).map((u, idx) => ({
      id: `authority-update-${incidentCode}-${idx}`,
      title: `Authority Update (${new Date(u.timestamp).toLocaleTimeString()})`,
      content: u.update_text,
      hazardTags: [],
      regionTags: [],
      citation: "Authority Console — Live Update",
      isAuthorityUpdate: true,
      similarity: 1.0, // Authority updates always highest priority
    }));

    // Merge: authority updates first, then search results (deduplicated)
    const seen = new Set<string>();
    const merged: RetrievedChunk[] = [];

    for (const chunk of updateChunks) {
      if (!seen.has(chunk.id)) {
        seen.add(chunk.id);
        merged.push(chunk);
      }
    }
    for (const chunk of chunks) {
      if (!seen.has(chunk.id)) {
        seen.add(chunk.id);
        merged.push(chunk);
      }
    }

    res.status(200).json({
      chunks: merged.slice(0, topK + updateChunks.length), // Allow extra slots for updates
      authorityUpdates: (authorityUpdates ?? []).map((u) => ({
        updateText: u.update_text,
        timestamp: u.timestamp,
      })),
    });
  } catch (err) {
    console.error("Retrieve error:", err);
    res.status(500).json({ error: "Retrieval failed" });
  }
});

/** Map a Supabase row to a RetrievedChunk. */
function mapChunk(row: any): RetrievedChunk {
  return {
    id: row.id,
    title: row.title,
    content: row.content,
    hazardTags: row.hazard_tags ?? [],
    regionTags: row.region_tags ?? [],
    citation: row.citation ?? "",
    isAuthorityUpdate: row.is_authority_update ?? false,
    similarity: row.similarity ?? 0,
  };
}
