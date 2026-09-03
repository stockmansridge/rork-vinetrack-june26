-- 222 — `saved_chemicals.rate_per_ha` becomes a NULLABLE legacy projection.
--
-- ADDITIVE AND NON-DESTRUCTIVE. No column is dropped, renamed, retyped or
-- repurposed. No stored value is rewritten. Running this twice is a no-op.
--
-- ---------------------------------------------------------------------------
-- The problem
-- ---------------------------------------------------------------------------
--
-- The live schema declares:
--
--   saved_chemicals.rate_per_ha double precision NOT NULL DEFAULT 0
--
-- That constraint is incompatible with the structured rate contract added in
-- sql/214. `default_rates` records the operator's CONFIRMED operational rate,
-- and a confirmed rate is frequently not a per-hectare scalar at all:
--
--   2–3 L/100 L   (SACOA Stifle and many other registered products)
--
-- There is no truthful `rate_per_ha` for that rate. Not 2. Not 3. Not 2.5.
-- Not 0. A per-100 L rate becomes a per-hectare amount only after a water
-- volume is chosen, and that volume belongs to the JOB, not to the product.
--
-- Because the column is NOT NULL DEFAULT 0, a writer that honestly omits
-- `rate_per_ha` does not get "no value" — PostgreSQL manufactures `0`. A
-- fabricated zero is indistinguishable, on read, from a genuine operator
-- decision to record zero, and it is exactly as wrong as writing the range's
-- minimum, maximum or midpoint. The database was forcing clients to lie.
--
-- ---------------------------------------------------------------------------
-- What this migration does
-- ---------------------------------------------------------------------------
--
-- Both statements are required, and neither is sufficient alone:
--
--   * DROP NOT NULL lets a row hold "there is no valid per-hectare scalar".
--   * DROP DEFAULT stops an omitted column from silently becoming 0 again.
--
-- Dropping only the NOT NULL would leave the default in place, so omission
-- would still manufacture a zero and the bug would survive the migration.
--
-- ---------------------------------------------------------------------------
-- What this migration deliberately does NOT do
-- ---------------------------------------------------------------------------
--
-- NO BACKFILL. Existing `0` values are left exactly as they are.
--
--   A stored zero has two indistinguishable origins: a value PostgreSQL
--   manufactured because a client omitted the column, and a value a legacy
--   client genuinely wrote. Nothing in the row separates them — there is no
--   provenance column, no write timestamp scoped to this field, and no link
--   from the scalar back to a printed label direction. Rewriting every zero
--   to NULL would therefore destroy real data in order to clean up fabricated
--   data, and rewriting none of them preserves both. Historical cleanup needs
--   evidence this migration does not have, so it stays a separate exercise.
--
-- NO REPLACEMENT DEFAULT. The absence of a value is the point.
--
-- NO CONVERSION between rate bases. Per-100 L never becomes per-hectare here
-- or anywhere else in the stack.
--
-- ---------------------------------------------------------------------------
-- The projection rule this enables (enforced in application code)
-- ---------------------------------------------------------------------------
--
-- `rate_per_ha` may carry a value ONLY when the authoritative structured rate
-- is a genuine single scalar on the per-hectare basis:
--
--   2 L/ha          -> 2
--   2–3 L/ha        -> NULL   (a range has no single scalar)
--   2 L/100 L       -> NULL   (wrong basis; conversion needs a job volume)
--   2–3 L/100 L     -> NULL
--   250 mL/100 L    -> NULL
--   unconfirmed     -> NULL
--   no rate         -> NULL
--
-- It is never derived from a minimum, maximum, midpoint, first option, zero,
-- carrier volume, treated area or label text.
--
-- ---------------------------------------------------------------------------
-- Safety
-- ---------------------------------------------------------------------------
--
--   * Relaxing a constraint cannot fail against existing rows: every current
--     value already satisfies "nullable double precision".
--   * No table rewrite. Both forms are catalogue-only changes and take a brief
--     ACCESS EXCLUSIVE lock, so this is safe on a live table.
--   * No RLS change, no new policy, no new grant, no trigger.
--   * Older clients that still send a number keep working unchanged.

BEGIN;

ALTER TABLE public.saved_chemicals
  ALTER COLUMN rate_per_ha DROP NOT NULL;

ALTER TABLE public.saved_chemicals
  ALTER COLUMN rate_per_ha DROP DEFAULT;

COMMENT ON COLUMN public.saved_chemicals.rate_per_ha IS
  'LEGACY COMPATIBILITY PROJECTION ONLY (sql/222). Authoritative operational '
  'rate is default_rates (sql/214). May hold a value only when the confirmed '
  'rate is a genuine single scalar on the per-hectare basis. NULL means "no '
  'valid per-hectare scalar exists" — never "no rate": that is answered by '
  'default_rates and registered_uses. Never derive from a range minimum, '
  'maximum, midpoint, first option, zero, or a per-100 L conversion.';

COMMIT;
