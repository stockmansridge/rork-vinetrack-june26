-- 214: Shared persistence for OPERATIONAL DEFAULT RATES on saved chemicals.
--
-- WHAT THIS IS
--   `registered_uses` records every rate the regulator approved. It is label
--   evidence: immutable, complete, and silent on what this vineyard actually
--   does. An operator, though, has ONE amount they normally use for a product,
--   and that choice has never been persisted anywhere. Every client therefore
--   re-guessed it from whatever was to hand, and the guesses disagreed.
--
--   `default_rates` is where the choice lives. It records WHICH authoritative
--   rate was chosen — never a new rate. It confers no authority: if it is
--   absent, wrong or unreadable, the label evidence is untouched and every
--   spray calculation still has everything it needs.
--
-- WHAT NULL MEANS
--   `default_rates IS NULL` means "no shared default has been recorded for
--   this Saved Chemical". It does NOT mean "this product has no rates".
--   Inside a non-null object, `per_hectare: null` means "no operational
--   default is recorded for the per-hectare basis" — again saying nothing
--   about what the label offers. Authoritative availability is answered by
--   `registered_uses`, and only by `registered_uses`.
--
-- NO BACKFILL. THIS IS THE POINT OF THE COLUMN.
--   Existing rows stay NULL. Nothing here derives a default from
--   `rate_per_ha`, `rates`, `registered_uses` or any previous UI
--   recommendation state.
--
--   Those sources cannot recover the operator's historical choice. A legacy
--   `rate_per_ha` is a bare number with no link to a printed direction, and a
--   label commonly states the SAME number under several directions (VICOL,
--   APVMA 33182, says 3 L/100 L for both European Red Mites and Grapevine
--   Scale). Matching on the number therefore resolves to whichever sorted
--   first. Backfilling would not recover a choice; it would manufacture one,
--   and stamp it with a provenance the data cannot support. An honest empty
--   is worth more than an invented history, so the operator is asked once
--   rather than told something untrue forever.
--
-- SHAPE (v1) — full semantics live in the shared application validator,
-- `supabase/functions/chemical-info-lookup/default_rates.ts`.
--   {
--     "version": 1,
--     "per_hectare": null | {
--       "option_key":    "default_option_v1_<32 hex>",
--       "rate_ids":      ["rate_v1_<32 hex>", ...],   -- ALWAYS an array
--       "basis":         "per_hectare",               -- must match its slot
--       "unit":          "L",                         -- the LABEL rate unit
--       "value":         3,    | null,                -- single amount
--       "min_value":     null  | 1,                   -- or a true range
--       "max_value":     null  | 2,
--       "source":        "operator" | "recommended",  -- provenance only
--       "selected_at":   "2026-08-26T00:00:00Z" | null,
--       "label_version": "2024-03" | null
--     },
--     "per_100_litres": null | { ... }
--   }
--
--   `rate_ids` is an array because one operational amount can be supported by
--   several distinct printed directions (the VICOL case above). Collapsing it
--   to a singular `rate_id` would discard a direction the operator is
--   entitled to rely on.
--
--   The two bases are INDEPENDENT. One is never manufactured from the other:
--   converting between them needs a water volume that belongs to the JOB, not
--   to the product.
--
-- AUTHORITATIVE VS COMPATIBILITY
--   Once clients read this column, `default_rates` is the authoritative shared
--   persistence for operational defaults, and `rate_per_ha` / `rates` remain
--   compatibility projections only. This migration establishes STORAGE ONLY —
--   no client read/write precedence changes here.
--
-- SAFETY CONTRACT
--   * Purely ADDITIVE: one nullable column. No existing column is dropped,
--     renamed, retyped or rewritten.
--   * No RLS change, no new policy, no new grant. The column is reachable
--     exactly wherever `saved_chemicals` already is, by exactly the same
--     roles, and introduces no service-role-only dependency.
--   * No trigger, no default value, no backfill.
--   * Historical spray records are untouched — a default is a preference about
--     future work and says nothing about what was applied.
--   * Idempotent; single transaction.
--
-- CHECK CONSTRAINT
--   Only that the value is a JSON object. The v1 semantics (version, basis /
--   slot agreement, rate-id prefixes, amount shape, option-key derivation) are
--   owned by the shared application validator, which both the Portal and iOS
--   consume. Encoding an evolving contract as a large SQL CHECK would freeze
--   it in the one place that is hardest to change, and would reject a v2
--   object that a newer client is entitled to write. This mirrors the sql/194
--   decision to constrain closed vocabularies only.

begin;

-- ---------------------------------------------------------------------------
-- 1. The column
-- ---------------------------------------------------------------------------

alter table public.saved_chemicals
  -- Nullable, no default. A row that has never recorded a choice must be
  -- distinguishable from one that recorded an empty contract: `{}` would be a
  -- statement, and no such statement has been made.
  add column if not exists default_rates jsonb;

comment on column public.saved_chemicals.default_rates is
  'Operator''s chosen operational default rate(s), versioned JSON (v1) with '
  'independent per_hectare / per_100_litres slots. NULL = no default recorded '
  '(NOT "no label rates exist" — that is answered by registered_uses). Each '
  'selection cites one or more D1 rate_v1_ registered rate identities in '
  'rate_ids, plus a snapshot of the LABEL amount and unit. Never backfilled '
  'from rate_per_ha or rates: those cannot recover which printed direction the '
  'operator chose. Validated by '
  'supabase/functions/chemical-info-lookup/default_rates.ts (sql/214).';

-- ---------------------------------------------------------------------------
-- 2. Conservative shape guard
-- ---------------------------------------------------------------------------
--
-- An array, string, number or bare `null` JSON scalar is not a contract in any
-- version, so rejecting them costs no forward compatibility. Everything
-- beyond this is the application validator's job.

do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_default_rates_object_check
    check (default_rates is null or jsonb_typeof(default_rates) = 'object');
exception
  when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Deliberate non-actions
-- ---------------------------------------------------------------------------
--
--   * NO update statement. Every pre-existing row keeps default_rates = NULL.
--   * NO index. Defaults are read with the chemical row that owns them and are
--     never a search key; an index would cost writes and buy nothing.
--   * NO RLS policy. Column-level access follows the table's existing policies.
--   * NO grant. `saved_chemicals` grants are table-wide and already cover it.

commit;
