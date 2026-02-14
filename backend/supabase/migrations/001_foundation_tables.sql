-- =============================================================================
-- Ask the Alert — Foundation Tables + Phase 4 enhancements
--
-- Backend storage is Supabase Postgres only. SQLite is not used on the server.
-- pgvector extension enabled for online RAG embedding search.
--
-- Applied to Supabase on 2026-02-14 via MCP migration tool.
-- =============================================================================

-- Enable pgvector extension for embedding search
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;

-- =============================================================================
-- Devices — Registered iOS device tokens for push notifications
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.devices (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    device_token TEXT NOT NULL UNIQUE,
    environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
    label TEXT,
    invalidated BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_devices_active ON public.devices (invalidated) WHERE invalidated = FALSE;

-- =============================================================================
-- Alerts — Alerts issued by authorities
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.alerts (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    incident_code TEXT NOT NULL,
    title TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    body TEXT NOT NULL,
    region TEXT NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_alerts_incident_code ON public.alerts (incident_code);

-- =============================================================================
-- Updates — Follow-up updates published by authorities
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.updates (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    incident_code TEXT NOT NULL,
    update_text TEXT NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('broadcast', 'authority_console')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_updates_incident ON public.updates (incident_code, timestamp DESC);

-- =============================================================================
-- Telemetry Events — Anonymous usage telemetry from iOS
-- PII-minimized: no names/addresses. Phone numbers redacted before storage.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.telemetry_events (
    event_id UUID PRIMARY KEY,
    incident_code TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (event_type IN ('received', 'opened', 'spoke', 'question', 'satisfaction')),
    device_timestamp TIMESTAMPTZ NOT NULL,
    server_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    intent_label TEXT,
    short_text TEXT,
    satisfaction_yes_no BOOLEAN,
    action_blocker TEXT CHECK (action_blocker IS NULL OR action_blocker IN ('driving', 'condo', 'kids', 'disability')),
    consent_given BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_telemetry_incident ON public.telemetry_events (incident_code, server_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_telemetry_event_type ON public.telemetry_events (event_type, incident_code);
CREATE INDEX IF NOT EXISTS idx_telemetry_intent ON public.telemetry_events (intent_label) WHERE intent_label IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_telemetry_created ON public.telemetry_events (created_at);

-- =============================================================================
-- RAG Chunks — Online retrieval corpus with pgvector embeddings (384 dim gte-small)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.rag_chunks (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    hazard_tags TEXT[] DEFAULT '{}',
    region_tags TEXT[] DEFAULT '{}',
    citation TEXT,
    is_authority_update BOOLEAN NOT NULL DEFAULT FALSE,
    incident_code TEXT,
    embedding extensions.vector(384),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rag_chunks_content_fts ON public.rag_chunks USING gin (to_tsvector('english', content));
CREATE INDEX IF NOT EXISTS idx_rag_chunks_embedding ON public.rag_chunks
    USING hnsw (embedding extensions.vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_incident ON public.rag_chunks (incident_code) WHERE incident_code IS NOT NULL;

-- =============================================================================
-- Aggregated Intent Clusters — Rolled up from telemetry for dashboard
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.aggregated_clusters (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    incident_code TEXT NOT NULL,
    intent_label TEXT NOT NULL,
    question_count INTEGER NOT NULL DEFAULT 0,
    example_questions TEXT[] DEFAULT '{}',
    confusion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (incident_code, intent_label)
);

CREATE INDEX IF NOT EXISTS idx_clusters_incident ON public.aggregated_clusters (incident_code);

-- =============================================================================
-- Telemetry Retention — Daily rollup summary table
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.telemetry_daily_rollup (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    incident_code TEXT NOT NULL,
    event_date DATE NOT NULL,
    event_type TEXT NOT NULL,
    event_count INTEGER NOT NULL DEFAULT 0,
    intent_label TEXT,
    intent_count INTEGER DEFAULT 0,
    UNIQUE (incident_code, event_date, event_type, intent_label)
);

CREATE INDEX IF NOT EXISTS idx_rollup_incident_date ON public.telemetry_daily_rollup (incident_code, event_date DESC);

-- =============================================================================
-- Row Level Security (RLS) — defense in depth
-- =============================================================================
-- Backend uses service_role key which bypasses RLS entirely.
-- RLS enabled with NO permissive policies = anon/authenticated roles denied.

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.updates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.telemetry_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rag_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aggregated_clusters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.telemetry_daily_rollup ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- RPC Functions
-- =============================================================================

-- 1. Vector similarity search for RAG retrieval
CREATE OR REPLACE FUNCTION public.match_rag_chunks(
    query_embedding extensions.vector(384),
    match_count INTEGER DEFAULT 5,
    match_threshold FLOAT DEFAULT 0.5,
    filter_incident_code TEXT DEFAULT NULL,
    filter_hazard_tag TEXT DEFAULT NULL
)
RETURNS TABLE (
    id UUID,
    title TEXT,
    content TEXT,
    hazard_tags TEXT[],
    region_tags TEXT[],
    citation TEXT,
    is_authority_update BOOLEAN,
    incident_code TEXT,
    similarity FLOAT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
    RETURN QUERY
    SELECT
        rc.id,
        rc.title,
        rc.content,
        rc.hazard_tags,
        rc.region_tags,
        rc.citation,
        rc.is_authority_update,
        rc.incident_code,
        (1 - (rc.embedding <=> query_embedding))::FLOAT AS similarity
    FROM public.rag_chunks rc
    WHERE
        rc.embedding IS NOT NULL
        AND (1 - (rc.embedding <=> query_embedding)) >= match_threshold
        AND (filter_incident_code IS NULL OR rc.incident_code IS NULL OR rc.incident_code = filter_incident_code)
        AND (filter_hazard_tag IS NULL OR filter_hazard_tag = ANY(rc.hazard_tags))
    ORDER BY rc.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- 2. Text-based fallback search for RAG
CREATE OR REPLACE FUNCTION public.search_rag_chunks_text(
    search_query TEXT,
    match_count INTEGER DEFAULT 5,
    filter_incident_code TEXT DEFAULT NULL,
    filter_hazard_tag TEXT DEFAULT NULL
)
RETURNS TABLE (
    id UUID,
    title TEXT,
    content TEXT,
    hazard_tags TEXT[],
    region_tags TEXT[],
    citation TEXT,
    is_authority_update BOOLEAN,
    incident_code TEXT,
    similarity FLOAT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        rc.id,
        rc.title,
        rc.content,
        rc.hazard_tags,
        rc.region_tags,
        rc.citation,
        rc.is_authority_update,
        rc.incident_code,
        ts_rank(to_tsvector('english', rc.content), plainto_tsquery('english', search_query))::FLOAT AS similarity
    FROM public.rag_chunks rc
    WHERE
        to_tsvector('english', rc.content) @@ plainto_tsquery('english', search_query)
        AND (filter_incident_code IS NULL OR rc.incident_code IS NULL OR rc.incident_code = filter_incident_code)
        AND (filter_hazard_tag IS NULL OR filter_hazard_tag = ANY(rc.hazard_tags))
    ORDER BY similarity DESC
    LIMIT match_count;
END;
$$;

-- 3. Telemetry rollup function
CREATE OR REPLACE FUNCTION public.rollup_telemetry(days_to_keep INTEGER DEFAULT 30)
RETURNS TABLE (rolled_up BIGINT, deleted BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    cutoff_date TIMESTAMPTZ;
    rows_rolled BIGINT := 0;
    rows_deleted BIGINT := 0;
BEGIN
    cutoff_date := NOW() - (days_to_keep || ' days')::INTERVAL;

    INSERT INTO public.telemetry_daily_rollup (incident_code, event_date, event_type, event_count, intent_label, intent_count)
    SELECT
        te.incident_code,
        DATE(te.server_timestamp) AS event_date,
        te.event_type,
        COUNT(*)::INTEGER AS event_count,
        te.intent_label,
        COUNT(*) FILTER (WHERE te.intent_label IS NOT NULL)::INTEGER AS intent_count
    FROM public.telemetry_events te
    WHERE te.server_timestamp < cutoff_date
    GROUP BY te.incident_code, DATE(te.server_timestamp), te.event_type, te.intent_label
    ON CONFLICT (incident_code, event_date, event_type, intent_label)
    DO UPDATE SET
        event_count = telemetry_daily_rollup.event_count + EXCLUDED.event_count,
        intent_count = telemetry_daily_rollup.intent_count + EXCLUDED.intent_count;

    GET DIAGNOSTICS rows_rolled = ROW_COUNT;

    DELETE FROM public.telemetry_events WHERE server_timestamp < cutoff_date;
    GET DIAGNOSTICS rows_deleted = ROW_COUNT;

    RETURN QUERY SELECT rows_rolled, rows_deleted;
END;
$$;

-- 4. Refresh intent clusters for an incident
CREATE OR REPLACE FUNCTION public.refresh_intent_clusters(p_incident_code TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.aggregated_clusters WHERE incident_code = p_incident_code;

    INSERT INTO public.aggregated_clusters (incident_code, intent_label, question_count, example_questions, confusion_flag, last_updated)
    SELECT
        p_incident_code,
        COALESCE(te.intent_label, 'other_unclear'),
        COUNT(*)::INTEGER,
        ARRAY(
            SELECT sub.short_text
            FROM public.telemetry_events sub
            WHERE sub.incident_code = p_incident_code
              AND sub.event_type = 'question'
              AND COALESCE(sub.intent_label, 'other_unclear') = COALESCE(te.intent_label, 'other_unclear')
              AND sub.short_text IS NOT NULL
            ORDER BY sub.server_timestamp DESC
            LIMIT 5
        ),
        (COUNT(*) >= 3 AND COUNT(*)::FLOAT / GREATEST(
            (SELECT COUNT(*) FROM public.telemetry_events
             WHERE incident_code = p_incident_code AND event_type = 'question')::FLOAT,
            1.0
        ) > 0.3),
        NOW()
    FROM public.telemetry_events te
    WHERE te.incident_code = p_incident_code
      AND te.event_type = 'question'
    GROUP BY COALESCE(te.intent_label, 'other_unclear');
END;
$$;

-- 5. PII redaction function
CREATE OR REPLACE FUNCTION public.redact_pii(input_text TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
BEGIN
    IF input_text IS NULL THEN RETURN NULL; END IF;
    input_text := regexp_replace(input_text, '\+?1?[-.\s]?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}', '[PHONE]', 'g');
    input_text := regexp_replace(input_text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[EMAIL]', 'g');
    input_text := regexp_replace(input_text, '\b\d{3}[-\s]?\d{3}[-\s]?\d{3}\b', '[SIN]', 'g');
    input_text := regexp_replace(input_text, '\b\d{1,5}\s+[A-Za-z]+\s+(Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Boulevard|Blvd|Lane|Ln|Court|Ct|Way|Place|Pl|Crescent|Cres)\b', '[ADDRESS]', 'gi');
    RETURN input_text;
END;
$$;
