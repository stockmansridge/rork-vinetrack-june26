-- 213 — Exact-registration enrichment cache (Stage C §G)
--
-- WHAT THIS IS
--   A lookup CACHE for the expensive part of a structured chemical lookup:
--   the manufacturer research call, the product-page fetch, the label PDF
--   download and the text extraction. Keyed by exact registration identity.
--
-- WHAT THIS IS NOT
--   It is NOT the Master Chemical catalogue and must never be confused with
--   it. A master row means "a human reviewed and approved this". A row here
--   means "we read these public documents recently, and here is the exact
--   document fingerprint we read them from". Nothing in this table is
--   approved, and nothing in it confers authority: serving from it is exactly
--   equivalent to having just performed the fetch.
--
-- WHY A SEPARATE TABLE
--   Writing enrichment output into master_chemicals would either require
--   review (defeating the purpose of a cache) or silently manufacture
--   approved rows nobody reviewed. Keeping the two apart means the catalogue
--   keeps meaning what it has always meant.
--
-- SAFETY
--   * Service-role only. No anon/authenticated grants, and RLS denies by
--     default, exactly like the suggestion cache (sql/211).
--   * `parser_version` is part of the key, so a parser change retires every
--     entry at once — a fix can never be masked by a result the broken parser
--     produced.
--   * Idempotent: safe to run more than once.

BEGIN;

CREATE TABLE IF NOT EXISTS public.chemical_enrichment_cache (
  -- country:scheme:number::parser_version — the full addressable identity.
  cache_key text PRIMARY KEY,

  -- Identity columns, stored separately from the key so the table can be
  -- inspected and audited by a human without parsing strings.
  registration_country text NOT NULL,
  registration_scheme  text,
  registration_number  text NOT NULL,

  -- The enrichment contract generation that produced this payload.
  parser_version text NOT NULL,

  -- The served enrichment: label URLs, use rows, rates, WHP/REI, provenance.
  payload jsonb NOT NULL,

  created_at   timestamptz NOT NULL DEFAULT now(),
  refreshed_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL
);

-- The only read pattern: one key, unexpired.
CREATE INDEX IF NOT EXISTS chemical_enrichment_cache_expires_idx
  ON public.chemical_enrichment_cache (expires_at);

-- Audit/inspection pattern: "what do we hold for this registration?"
CREATE INDEX IF NOT EXISTS chemical_enrichment_cache_identity_idx
  ON public.chemical_enrichment_cache
     (registration_country, registration_scheme, registration_number);

ALTER TABLE public.chemical_enrichment_cache ENABLE ROW LEVEL SECURITY;

-- No policies are created on purpose. With RLS enabled and no policy, every
-- non-service role is denied. The edge function uses the service role, which
-- bypasses RLS. A cache of public label readings is not user data, but it is
-- also not something any client should read or write directly.

REVOKE ALL ON public.chemical_enrichment_cache FROM anon, authenticated;

COMMENT ON TABLE public.chemical_enrichment_cache IS
  'Lookup cache for exact-registration label enrichment. NOT an approval '
  'mechanism and NOT the Master Chemical catalogue: rows are unreviewed '
  'readings of public documents, retired by parser_version and expires_at.';

COMMIT;
