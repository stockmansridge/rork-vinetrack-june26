-- 211: Cross-isolate research suggestion cache — proposal for review
--       (Chemical Search Stage 2 §4).
--
-- ###########################################################################
-- #                                                                         #
-- #   PROPOSAL ONLY — DO NOT RUN AGAINST PRODUCTION UNTIL APPROVED.         #
-- #                                                                         #
-- #   Reviewed and applied together with                                    #
-- #   sql/tests/211_chemical_research_suggestion_cache_tests.sql,           #
-- #   which is rollback-only and safe to run first.                         #
-- #                                                                         #
-- ###########################################################################
--
-- THE PROBLEM
--
--   A chemical search whose query matches NOTHING in the official register
--   falls through to a web/model research pass. That pass is not
--   deterministic: the same query can return different candidate products on
--   different invocations.
--
--   The measured case is "Hortitrol Winter Oil" / AU. The APVMA register
--   returns zero lexical matches, research runs, and:
--
--     Portal reached  VICOL WINTER OIL INSECTICIDE               APVMA 33182
--     iOS reached     SYNERTROL HORTI BOTANICAL OIL CONCENTRATE  APVMA 50067
--
--   Two clients, one query, two different products.
--
--   The function already has a cache (`ingestion/cache.ts`), but it is
--   in-memory and therefore PER EDGE ISOLATE. Portal and iOS routinely land on
--   different isolates, so each ran its own research pass and each cached its
--   own answer. A per-isolate cache cannot produce cross-platform parity by
--   construction — it is a load-shedding device, and was only ever documented
--   as one.
--
-- WHAT THIS MIGRATION DOES
--
--   Adds ONE table so that the same country + normalised query returns the
--   same suggestion set during the cache lifetime, whichever isolate serves
--   the request.
--
--   This is deliberately the smallest mechanism that closes the gap: one
--   table, one keyed read, one upsert, reusing the service-role credentials
--   the function already holds for `master_chemicals`. No new subsystem, no
--   external cache service, no change to the existing in-memory cache (which
--   keeps doing its separate load-shedding job).
--
-- WHAT IT DELIBERATELY IS NOT
--
--   * NOT a catalogue. Nothing here is approved data. A cached row is a
--     record of "what was suggested for this query", never a product record,
--     and must never be read by anything except the search suggestion path.
--   * NOT authoritative. Every payload row is a SUGGESTION. Rows whose
--     registration number the register confirmed are marked
--     `registration_validated: true` by the edge function BEFORE being cached;
--     the cache preserves that distinction rather than creating it.
--   * NOT user data. No vineyard id, no user id, no PII. It is keyed on a
--     product query and a country, and is readable only by the service role.
--
-- CACHE LIFETIME
--
--   One hour (`SUGGESTION_CACHE_TTL_SECONDS` in research_suggestions.ts).
--   Long enough that two clients comparing the same product minutes apart get
--   the same answer; short enough that a register change or an improved
--   research pass is picked up the same day. Expiry is enforced by the READ
--   (`expires_at > now()`), so a stale row can never be served even if the
--   sweeper has not run.
--
-- ROLLBACK
--
--   drop table if exists public.chemical_research_suggestion_cache;
--
--   Safe at any time: the edge function treats a missing table as a cache
--   miss (see `createPostgrestSuggestionStore`), so dropping it degrades
--   behaviour to today's per-isolate nondeterminism and breaks nothing.
--
-- DEPLOY ORDER
--
--   This table may be created BEFORE or AFTER the function deploy — the
--   function fail-softs in both directions. Creating it first is preferred so
--   the parity fix is live the moment the function lands.

begin;

create table if not exists public.chemical_research_suggestion_cache (
  -- "<COUNTRY>::<typography-normalised query>", built by `suggestionCacheKey`.
  -- The country is part of the key and is NEVER merged away: AU and NZ
  -- registers are different law, and a shared entry across them would be a
  -- jurisdiction leak of exactly the kind the lookup path fails closed on.
  cache_key         text primary key,

  -- Denormalised for auditing and for the sweeper. The key is the contract;
  -- these two exist so a human can read the table.
  country_code      text        not null,
  normalised_query  text        not null,

  -- The served suggestion rows, verbatim, INCLUDING each row's
  -- `registration_validated` flag and `source`. Stored as served so a replay
  -- shows exactly what a client received — a payload that had to be
  -- re-derived on read would be a second code path that could disagree.
  payload           jsonb       not null,

  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null,

  constraint chemical_research_suggestion_cache_country_ck
    check (country_code ~ '^[A-Z]{2}$'),
  constraint chemical_research_suggestion_cache_payload_ck
    check (jsonb_typeof(payload) = 'array'),
  -- An entry that expires before it is created is a clock or caller bug, and
  -- would sit in the table forever looking like a valid row.
  constraint chemical_research_suggestion_cache_expiry_ck
    check (expires_at > created_at)
);

comment on table public.chemical_research_suggestion_cache is
  'Cross-isolate stability for chemical search research suggestions '
  '(Stage 2 §4). NOT a catalogue and NOT authoritative: every payload row is '
  'a suggestion requiring explicit user selection. Service-role only.';

comment on column public.chemical_research_suggestion_cache.payload is
  'Served suggestion rows verbatim, including registration_validated. '
  'Validation against the official register happens BEFORE caching.';

-- Sweeper support. Reads already filter on expires_at, so this index serves
-- deletion rather than correctness.
create index if not exists chemical_research_suggestion_cache_expires_idx
  on public.chemical_research_suggestion_cache (expires_at);

-- ---------------------------------------------------------------------------
-- RLS: service role only
-- ---------------------------------------------------------------------------
--
-- No policies are created. With RLS enabled and no policy, ordinary
-- authenticated and anonymous roles can read nothing — which is correct: this
-- table holds unverified model output, and a client that could read it
-- directly would be able to treat a suggestion as catalogue data. The edge
-- function uses the service role, which bypasses RLS.

alter table public.chemical_research_suggestion_cache enable row level security;

revoke all on public.chemical_research_suggestion_cache from anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Optional: scheduled cleanup
-- ---------------------------------------------------------------------------
--
-- Expired rows are never SERVED (the read filters on expires_at), so this is
-- housekeeping only. Run manually, or via pg_cron if it is already enabled —
-- this migration deliberately does not enable an extension.
--
--   delete from public.chemical_research_suggestion_cache
--    where expires_at < now() - interval '1 day';
