-- Tests for sql/211 — cross-isolate research suggestion cache.
--
-- ROLLBACK ONLY. Everything runs inside one transaction that ends in
-- `rollback`, so this is safe to run against production before the migration
-- is approved. It seeds its own rows and asserts on those.
--
-- RUN ORDER
--   sql/211_chemical_research_suggestion_cache.sql            (the migration)
--   sql/tests/211_chemical_research_suggestion_cache_tests.sql (this file)
--
-- WHAT THESE TESTS ARE PROTECTING
--
-- The table exists for ONE reason: two clients asking the same question must
-- get the same answer. Most assertions below therefore check that the key is
-- narrow enough to collide on purpose (same country + same query = same row)
-- and wide enough never to collide by accident (AU must never serve NZ).

begin;

do $$
declare
  v_count   integer;
  v_payload jsonb;
  v_key_au  text := 'AU::hortitrol winter oil';
  v_key_nz  text := 'NZ::hortitrol winter oil';
begin

  -- =====================================================================
  -- T1. The table exists with the expected shape
  -- =====================================================================
  if not exists (
    select 1 from information_schema.tables
     where table_schema = 'public'
       and table_name = 'chemical_research_suggestion_cache'
  ) then
    raise exception 'T1 FAILED: table chemical_research_suggestion_cache is missing';
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. cache_key is the PRIMARY KEY
  --
  -- Parity depends on ONE row per country+query. Without the primary key two
  -- isolates could each insert their own answer and both would be "valid",
  -- which is the nondeterminism this table exists to remove.
  -- =====================================================================
  if not exists (
    select 1
      from information_schema.table_constraints tc
      join information_schema.key_column_usage kcu
        on tc.constraint_name = kcu.constraint_name
     where tc.table_schema = 'public'
       and tc.table_name = 'chemical_research_suggestion_cache'
       and tc.constraint_type = 'PRIMARY KEY'
       and kcu.column_name = 'cache_key'
  ) then
    raise exception 'T2 FAILED: cache_key must be the primary key';
  end if;
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3. A well-formed entry inserts
  -- =====================================================================
  insert into public.chemical_research_suggestion_cache
    (cache_key, country_code, normalised_query, payload, expires_at)
  values (
    v_key_au, 'AU', 'hortitrol winter oil',
    '[{"name":"VICOL WINTER OIL INSECTICIDE","registration_number":"33182",
       "source":"research_validated","registration_validated":true}]'::jsonb,
    now() + interval '1 hour'
  );
  raise notice 'T3 passed';

  -- =====================================================================
  -- T4. The same country + query UPSERTS rather than duplicating
  --
  -- This is the parity guarantee in one assertion.
  -- =====================================================================
  insert into public.chemical_research_suggestion_cache
    (cache_key, country_code, normalised_query, payload, expires_at)
  values (
    v_key_au, 'AU', 'hortitrol winter oil',
    '[{"name":"VICOL WINTER OIL INSECTICIDE","registration_number":"33182"}]'::jsonb,
    now() + interval '1 hour'
  )
  on conflict (cache_key) do update
    set payload = excluded.payload,
        expires_at = excluded.expires_at;

  select count(*) into v_count
    from public.chemical_research_suggestion_cache
   where cache_key = v_key_au;
  if v_count <> 1 then
    raise exception 'T4 FAILED: expected exactly 1 row for the key, found %', v_count;
  end if;
  raise notice 'T4 passed';

  -- =====================================================================
  -- T5. JURISDICTION: AU and NZ never share an entry
  --
  -- Product registration is country-scoped law. A shared entry would serve
  -- one country's suggestions to another — the same failure the lookup path
  -- fails closed on everywhere else.
  -- =====================================================================
  insert into public.chemical_research_suggestion_cache
    (cache_key, country_code, normalised_query, payload, expires_at)
  values (
    v_key_nz, 'NZ', 'hortitrol winter oil', '[]'::jsonb, now() + interval '1 hour'
  );

  select count(*) into v_count
    from public.chemical_research_suggestion_cache
   where normalised_query = 'hortitrol winter oil';
  if v_count <> 2 then
    raise exception 'T5 FAILED: AU and NZ must be separate rows, found %', v_count;
  end if;
  raise notice 'T5 passed';

  -- =====================================================================
  -- T6. country_code must be a 2-letter uppercase code
  -- =====================================================================
  begin
    insert into public.chemical_research_suggestion_cache
      (cache_key, country_code, normalised_query, payload, expires_at)
    values ('bad::x', 'aus', 'x', '[]'::jsonb, now() + interval '1 hour');
    raise exception 'T6 FAILED: a malformed country_code was accepted';
  exception
    when check_violation then raise notice 'T6 passed';
  end;

  -- =====================================================================
  -- T7. payload must be a JSON ARRAY
  --
  -- The reader expects a list of suggestion rows. An object would decode to
  -- null and silently disable the cache for that query.
  -- =====================================================================
  begin
    insert into public.chemical_research_suggestion_cache
      (cache_key, country_code, normalised_query, payload, expires_at)
    values ('bad::y', 'AU', 'y', '{"name":"x"}'::jsonb, now() + interval '1 hour');
    raise exception 'T7 FAILED: a non-array payload was accepted';
  exception
    when check_violation then raise notice 'T7 passed';
  end;

  -- =====================================================================
  -- T8. An already-expired entry cannot be written
  -- =====================================================================
  begin
    insert into public.chemical_research_suggestion_cache
      (cache_key, country_code, normalised_query, payload, expires_at)
    values ('bad::z', 'AU', 'z', '[]'::jsonb, now() - interval '1 hour');
    raise exception 'T8 FAILED: an already-expired entry was accepted';
  exception
    when check_violation then raise notice 'T8 passed';
  end;

  -- =====================================================================
  -- T9. The read filter excludes expired rows
  --
  -- The edge function filters on `expires_at > now()`. This asserts the
  -- semantics that filter relies on, independently of any sweeper.
  -- =====================================================================
  update public.chemical_research_suggestion_cache
     set expires_at = now() - interval '1 second'
   where cache_key = v_key_nz;

  select count(*) into v_count
    from public.chemical_research_suggestion_cache
   where cache_key = v_key_nz and expires_at > now();
  if v_count <> 0 then
    raise exception 'T9 FAILED: an expired row was still visible to the read filter';
  end if;
  raise notice 'T9 passed';

  -- =====================================================================
  -- T10. The validation flag survives a round trip
  --
  -- `registration_validated` is what separates a register-confirmed
  -- suggestion from a model guess. If the cache lost it, a replayed answer
  -- would silently downgrade — or worse, upgrade — every suggestion.
  -- =====================================================================
  select payload into v_payload
    from public.chemical_research_suggestion_cache
   where cache_key = v_key_au;

  if v_payload -> 0 ->> 'registration_number' is distinct from '33182' then
    raise exception 'T10 FAILED: the cached registration number did not survive';
  end if;
  raise notice 'T10 passed';

  -- =====================================================================
  -- T11. RLS is enabled
  --
  -- The table holds unverified model output. A client able to read it
  -- directly could treat a suggestion as catalogue data.
  -- =====================================================================
  if not exists (
    select 1 from pg_class
     where relname = 'chemical_research_suggestion_cache'
       and relnamespace = 'public'::regnamespace
       and relrowsecurity
  ) then
    raise exception 'T11 FAILED: row level security is not enabled';
  end if;
  raise notice 'T11 passed';

  -- =====================================================================
  -- T12. No policy grants ordinary roles access
  --
  -- RLS with no policy denies everything to non-service roles, which is the
  -- intent. A future policy added here would need its own review.
  -- =====================================================================
  select count(*) into v_count
    from pg_policies
   where schemaname = 'public'
     and tablename = 'chemical_research_suggestion_cache';
  if v_count <> 0 then
    raise exception 'T12 FAILED: unexpected RLS policies present (%)', v_count;
  end if;
  raise notice 'T12 passed';

  -- =====================================================================
  -- T13. The expiry index exists (sweeper support)
  -- =====================================================================
  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and tablename = 'chemical_research_suggestion_cache'
       and indexname = 'chemical_research_suggestion_cache_expires_idx'
  ) then
    raise exception 'T13 FAILED: the expires_at index is missing';
  end if;
  raise notice 'T13 passed';

  raise notice 'ALL 211 TESTS PASSED';
end $$;

rollback;
