-- 212: Remove ONE contaminated search alias from the master catalogue —
--      proposal for review (Chemical Identity Repair, Phase 4).
--
-- ###########################################################################
-- #                                                                         #
-- #   PROPOSAL ONLY — DO NOT RUN AGAINST PRODUCTION UNTIL APPROVED.         #
-- #                                                                         #
-- #   Reviewed and applied together with                                    #
-- #   sql/tests/212_remove_false_master_chemical_alias_tests.sql,           #
-- #   which is read-only and safe to run first.                             #
-- #                                                                         #
-- ###########################################################################
--
-- THE PROBLEM
--
--   public.master_chemicals.common_names is an EXACT-MATCH search key. The
--   resolver (`fetchApprovedMaster`) treats a whole-string alias hit as a
--   definitive identity: one approved row for the country, matched on an
--   alias, IS the product. That is the correct rule — provided every alias in
--   the column was put there by something entitled to make the claim.
--
--   One was not. Until this repair, the edge function's ingestion path built
--   its candidate row like this:
--
--     common_names: aliasSet(productName, requestedName, ...)
--
--   `requestedName` is the phrase the operator typed into the search box.
--
--   So the alias list was self-fulfilling. An operator searched
--   "Hortitrol winter oil"; the lookup — for reasons repaired separately in
--   this change — answered with
--
--     SYNERTROL HORTI BOTANICAL OIL CONCENTRATE, APVMA 50067
--
--   and the typed phrase was written into that row's common_names. From that
--   moment the phrase was no longer a guess. It was an exact alias, matched
--   first, for every user in the country, forever — and because a single
--   deterministic hit also suppressed broader candidate discovery, it
--   guaranteed the operator would never be shown anything else.
--
--   One uncertain lookup became a permanent, confident, unreviewable answer.
--
--   The two products are not related:
--
--     SYNERTROL HORTI BOTANICAL OIL CONCENTRATE   APVMA 50067  DuluxGroup
--     "hortitrol winter oil"                      <- shares no word with it
--
-- WHAT THIS MIGRATION DOES
--
--   Removes exactly ONE string from ONE row's common_names array.
--
--   That is the entire scope. In particular it does NOT:
--
--     * delete, retire or demote APVMA 50067 — the product is real, the
--       registration is valid, and the row is correct about everything
--       except this one alias;
--     * add the phrase to APVMA 33182, or to any other row — moving a bad
--       alias is not removing it, and this migration has no basis for
--       deciding which product the operator meant;
--     * touch registered_product_name, registered_uses, rates, or any
--       verification evidence;
--     * touch any other row, in any other country.
--
--   Deciding which product an ambiguous phrase means is a USER decision. The
--   code change accompanying this migration makes the app ask. This file only
--   removes the contamination that was stopping it from asking.
--
--   The source of the contamination is closed in the same change
--   (`ingestion/ingest.ts`): a typed search phrase can no longer become an
--   alias. Without that fix this migration would be undone by the next
--   search.
--
-- IDEMPOTENT
--
--   Re-running is a no-op: the WHERE clause requires the alias to still be
--   present, so a second run matches zero rows. Safe to run twice, safe to
--   run after a partial failure.
--
-- ROLLBACK
--
--   Restoring the alias would restore the defect, so there is deliberately no
--   rollback statement here. If APVMA 50067 genuinely IS sold as
--   "Hortitrol Winter Oil", that is an alias claim for a human to make with
--   evidence, through the catalogue review flow — not by reverting a cleanup.

-- ONE STATEMENT, ON PURPOSE
--
--   The update and its verification live in a single DO block rather than an
--   explicit BEGIN/COMMIT pair. A DO block is one statement, so a RAISE
--   EXCEPTION anywhere inside it rolls back the update atomically -- in the
--   Supabase SQL editor (which already wraps submitted SQL in its own
--   transaction, making a nested BEGIN redundant at best) and under psql
--   (where autocommit would otherwise let the update survive a failed
--   verification). Same guarantees, no assumptions about the client.
--
--   For the same reason there are no psql meta-commands anywhere in this
--   file: \echo and friends are client-side directives, not SQL. The server
--   sees a stray backslash and rejects the statement.

do $$
declare
  affected integer;
begin
  -- ---- Remove the alias -------------------------------------------------
  -- Belt and braces: this must be one row, and it must be the row we mean.
  update public.master_chemicals
  set common_names = coalesce(
    (
      select array_agg(alias order by ordinality)
      from unnest(common_names) with ordinality as t(alias, ordinality)
      where lower(trim(alias)) <> 'hortitrol winter oil'
    ),
    '{}'::text[]
  )
  where registration_country = 'AU'
    and registration_number = '50067'
    -- Only touch a row that actually carries the contamination, so the
    -- migration is idempotent and its row count is meaningful.
    and exists (
      select 1
      from unnest(common_names) as alias
      where lower(trim(alias)) = 'hortitrol winter oil'
    );

  get diagnostics affected = row_count;

  if affected > 1 then
    raise exception
      'sql/212 expected at most 1 row, matched % — refusing', affected;
  end if;

  raise notice 'sql/212: removed the false alias from % row(s)', affected;

  -- ---- Verify, in the SAME statement -------------------------------------
  -- The row must still exist, still be AU:apvma:50067, and still be intact.
  -- A cleanup that removed a product would be far worse than the alias.
  if not exists (
    select 1
    from public.master_chemicals
    where registration_country = 'AU'
      and registration_number = '50067'
  ) then
    raise exception 'sql/212: APVMA 50067 is missing after cleanup — aborting';
  end if;

  if exists (
    select 1
    from public.master_chemicals
    where registration_country = 'AU'
      and registration_number = '50067'
      and exists (
        select 1
        from unnest(common_names) as alias
        where lower(trim(alias)) = 'hortitrol winter oil'
      )
  ) then
    raise exception 'sql/212: the false alias is still present — aborting';
  end if;

  raise notice 'sql/212: verified — APVMA 50067 intact, false alias gone';
end;
$$;
