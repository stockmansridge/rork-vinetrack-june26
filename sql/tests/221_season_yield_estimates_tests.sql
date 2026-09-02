-- =====================================================================
-- 221_season_yield_estimates_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/221_season_yield_estimates.sql.
-- Everything runs inside ONE transaction that is ROLLED BACK at the end,
-- so no fixture survives and no production row is modified.
--
-- Test map
--   T1  Objects: columns, triggers, table, unique index, RPCs, RLS policies
--   T2  damage_records.vintage — old client omits it (server resolves),
--       new client sends it (preserved), VINEYARD-LOCAL season boundary
--       either side of local midnight (same UTC day, different vintages),
--       moving the observation date re-resolves, deliberate vintage
--       restatement honoured, unrelated edits never move a confirmed
--       vintage, implausible value rejected
--   T3  yield_estimation_sessions.vintage — session_created_at basis,
--       vineyard-local boundary, created_at fallback, payload NEVER consulted
--   T4  Pruning formula — exact tonnes for spur and cane blocks, and the
--       vine-count precedence (override beats area × vines_per_ha)
--   T5  Missing inputs — unavailable estimate + named warnings, NEVER zero
--   T6  Mixed-variety split — planting_group_key identity, duplicate
--       allocations merged, residual "Unallocated variety"
--   T7  Priority — a manual row survives a pruning refresh untouched and is
--       counted as skipped; a pruning row IS refreshed
--   T8  Idempotency — a second refresh inserts nothing new
--   T9  Stale groups — a removed allocation soft-deletes only pruning rows
--   T10 Vintage isolation — refreshing 2027 never touches 2026, and the
--       overview returns only the requested vintage
--   T11 get_season_yield_base_overview — shape, KNOWN vs CANONICAL totals,
--       empty vintage, incomplete vineyard, complete vineyard, base-only
--   T12 Permissions — member reads, operator refreshes, stranger denied,
--       anonymous denied
--   T13 (B3) Allocation reconciliation — 101.8% normalised to 100%, merged
--       duplicates over 100% normalised, numeric-STRING percent parsed,
--       invalid + negative percents excluded and warned, and group tonnes
--       reconciling exactly to block tonnes
--   T14 (B4) Current-vintage-only refresh — public wrapper accepts the
--       current vineyard vintage, rejects historical and future ones, the
--       internal worker still builds isolated fixtures, and a vineyard whose
--       local clock has crossed the boundary resolves locally
--   T15 (B1/B5) Least privilege — internal helpers are not client-callable
--       and the canonical table is client READ-ONLY
--   T16 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 221 season yield estimate tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.season_yield_estimates') is null then
    raise exception 'sql/221_season_yield_estimates.sql has not been applied';
  end if;
end $$;

do $t221$
declare
  u_owner      uuid;
  u_manager    uuid;
  u_supervisor uuid;
  u_operator   uuid;
  u_stranger   uuid;
  v_user       uuid;
  v1         uuid := gen_random_uuid();
  v2         uuid := gen_random_uuid();
  v3         uuid := gen_random_uuid();  -- fully configured (complete overview)
  v4         uuid := gen_random_uuid();  -- timezone crossing the boundary
  bA         uuid := gen_random_uuid();  -- spur, vine override 1000
  bB         uuid := gen_random_uuid();  -- cane, vine override 500
  bC         uuid := gen_random_uuid();  -- no pruning settings
  bD         uuid := gen_random_uuid();  -- mixed variety
  bE         uuid := gen_random_uuid();  -- area × vines_per_ha path
  bF         uuid := gen_random_uuid();  -- allocations totalling 101.8%
  bG         uuid := gen_random_uuid();  -- duplicate groups merging to 120%
  bH         uuid := gen_random_uuid();  -- string / invalid / negative percents
  bI         uuid := gen_random_uuid();  -- v3's single fully configured block
  d1         uuid := gen_random_uuid();
  d2         uuid := gen_random_uuid();
  d3         uuid := gen_random_uuid();
  d4         uuid := gen_random_uuid();
  d5         uuid := gen_random_uuid();
  s1         uuid := gen_random_uuid();
  s2         uuid := gen_random_uuid();
  s3         uuid := gen_random_uuid();
  n          integer;
  v_int      integer;
  v_num      double precision;
  v_txt      text;
  v_bool     boolean;
  v_json     jsonb;
  v_res      jsonb;
  v_area     double precision;
  v_caught   boolean;
  v_sqlstate text;
  v_current  integer;
  k_shiraz   text;
  k_cab      text;
  k_unalloc  text;
  k_merlot   text;
  k_grenache text;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-owner@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-manager@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-supervisor@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-operator@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-stranger@test.local', 'x', now(), now(), now());
  select id into u_owner      from auth.users where email = 't221-owner@test.local';
  select id into u_manager    from auth.users where email = 't221-manager@test.local';
  select id into u_supervisor from auth.users where email = 't221-supervisor@test.local';
  select id into u_operator   from auth.users where email = 't221-operator@test.local';
  select id into u_stranger   from auth.users where email = 't221-stranger@test.local';

  insert into public.profiles (id, email)
  values (u_owner, 't221-owner@test.local'),
         (u_manager, 't221-manager@test.local'),
         (u_supervisor, 't221-supervisor@test.local'),
         (u_operator, 't221-operator@test.local'),
         (u_stranger, 't221-stranger@test.local')
  on conflict (id) do nothing;

  -- Season starts 1 September, so 2026-09-02 AND 2027-03-01 are both Vintage 2027.
  -- v1 carries Australia/Sydney (AEST = UTC+10 in late August) so the
  -- vineyard-local boundary tests have a real offset to cross.
  insert into public.vineyards (id, name, season_start_month, season_start_day, timezone)
  values (v1, 'T221 Vineyard', 9, 1, 'Australia/Sydney'),
         (v2, 'T221 Other Vineyard', 9, 1, 'Australia/Sydney'),
         (v3, 'T221 Complete Vineyard', 9, 1, 'Australia/Sydney'),
         (v4, 'T221 Pacific Vineyard', 9, 1, 'Pacific/Auckland');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v1, u_owner, 'owner'),
    (v1, u_manager, 'manager'),
    (v1, u_supervisor, 'supervisor'),
    (v1, u_operator, 'operator'),
    (v2, u_stranger, 'owner'),
    (v3, u_owner, 'owner'),
    (v4, u_owner, 'owner');

  insert into public.paddocks (id, vineyard_id, name, vine_count_override, variety_allocations)
  values
    (bA, v1, 'T221 Block A', 1000, null),
    (bB, v1, 'T221 Block B', 500, null),
    (bC, v1, 'T221 Block C', 1000, null),
    (bD, v1, 'T221 Block D', 1000, jsonb_build_array(
        jsonb_build_object('id', gen_random_uuid()::text, 'varietyKey', 'shiraz',
                           'name', 'Shiraz', 'clone', 'MV6', 'rootstock', '101-14',
                           'percent', 30),
        jsonb_build_object('id', gen_random_uuid()::text, 'varietyKey', 'shiraz',
                           'name', 'Shiraz', 'clone', 'MV6', 'rootstock', '101-14',
                           'percent', 30),
        jsonb_build_object('id', gen_random_uuid()::text, 'varietyKey', 'cabernet_sauvignon',
                           'name', 'Cabernet Sauvignon', 'percent', 30)
      ));

  -- Block E carries a polygon so the area × vines_per_ha path is exercised.
  insert into public.paddocks (id, vineyard_id, name, polygon_points)
  values (bE, v1, 'T221 Block E', jsonb_build_array(
      jsonb_build_object('latitude', -33.0000, 'longitude', 149.0000),
      jsonb_build_object('latitude', -33.0000, 'longitude', 149.0020),
      jsonb_build_object('latitude', -33.0015, 'longitude', 149.0020),
      jsonb_build_object('latitude', -33.0015, 'longitude', 149.0000)
    ));

  -- (B3) fixtures reproducing the live audit findings.
  --   Block F: two valid allocations totalling 101.8%.
  --   Block G: duplicate Shiraz/MV6/101-14 groups merging to 120%.
  --   Block H: a numeric STRING percent, a non-numeric percent and a
  --            negative percent alongside one good allocation.
  insert into public.paddocks (id, vineyard_id, name, vine_count_override, variety_allocations)
  values
    (bF, v1, 'T221 Block F', 1000, jsonb_build_array(
        jsonb_build_object('varietyKey', 'shiraz', 'name', 'Shiraz',
                           'clone', 'MV6', 'rootstock', '101-14', 'percent', 51.8),
        jsonb_build_object('varietyKey', 'merlot', 'name', 'Merlot', 'percent', 50)
      )),
    (bG, v1, 'T221 Block G', 1000, jsonb_build_array(
        jsonb_build_object('varietyKey', 'shiraz', 'name', 'Shiraz',
                           'clone', 'MV6', 'rootstock', '101-14', 'percent', 60),
        jsonb_build_object('varietyKey', 'shiraz', 'name', 'Shiraz',
                           'clone', 'MV6', 'rootstock', '101-14', 'percent', 60)
      )),
    (bH, v1, 'T221 Block H', 1000, jsonb_build_array(
        jsonb_build_object('varietyKey', 'shiraz', 'name', 'Shiraz',
                           'clone', 'MV6', 'rootstock', '101-14', 'percent', '45.5'),
        jsonb_build_object('varietyKey', 'merlot', 'name', 'Merlot',
                           'percent', 'not a number'),
        jsonb_build_object('varietyKey', 'grenache', 'name', 'Grenache',
                           'percent', -10)
      ));

  -- v3 is deliberately SMALL and fully configured: every row available, so the
  -- overview may publish a canonical total.
  insert into public.paddocks (id, vineyard_id, name, vine_count_override)
  values (bI, v3, 'T221 Block I', 1000);

  insert into public.pruning_yield_settings
    (vineyard_id, paddock_id, prune_method, bunches_per_bud, buds_per_spur,
     spurs_per_vine, buds_per_cane, canes_per_vine, vines_per_ha, bunch_weight_grams)
  values
    (v1, bA, 'spur', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bB, 'cane', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bD, 'spur', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bE, 'spur', 1.5, 2, 6, 10, 4, 2000, 120),
    (v1, bF, 'spur', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bG, 'spur', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bH, 'spur', 1.5, 2, 6, 10, 4, null, 120),
    (v3, bI, 'spur', 1.5, 2, 6, 10, 4, null, 120);

  k_shiraz   := public.planting_group_key('Shiraz', 'MV6', '101-14');
  k_cab      := public.planting_group_key('Cabernet Sauvignon', null, null);
  k_unalloc  := public.planting_group_key('Unallocated variety', null, null);
  k_merlot   := public.planting_group_key('Merlot', null, null);
  k_grenache := public.planting_group_key('Grenache', null, null);

  -- ---- T1. Objects -------------------------------------------------------
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'damage_records' and column_name = 'vintage';
  if n <> 1 then raise exception 'T1: damage_records.vintage missing'; end if;

  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'yield_estimation_sessions' and column_name = 'vintage';
  if n <> 1 then raise exception 'T1: yield_estimation_sessions.vintage missing'; end if;

  select count(*) into n from pg_trigger
   where tgrelid = 'public.damage_records'::regclass and tgname = 'damage_records_resolve_vintage';
  if n <> 1 then raise exception 'T1: damage vintage trigger missing'; end if;

  select count(*) into n from pg_trigger
   where tgrelid = 'public.yield_estimation_sessions'::regclass
     and tgname = 'yield_estimation_sessions_resolve_vintage';
  if n <> 1 then raise exception 'T1: session vintage trigger missing'; end if;

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname in (
     'refresh_pruning_yield_estimates', 'get_season_yield_base_overview',
     '_refresh_pruning_yield_estimates', '_pruning_block_estimate',
     'season_yield_estimate_source_rank', 'soft_delete_season_yield_estimate');
  if n <> 6 then raise exception 'T1: expected 6 RPCs/helpers, found %', n; end if;

  if to_regclass('public.season_yield_estimates_active_key') is null then
    raise exception 'T1: unique active index missing';
  end if;

  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'season_yield_estimates';
  if n <> 4 then raise exception 'T1: expected 4 RLS policies, found %', n; end if;

  select relrowsecurity into v_bool from pg_class where oid = 'public.season_yield_estimates'::regclass;
  if not v_bool then raise exception 'T1: RLS not enabled'; end if;

  -- No second vintage resolver was introduced.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like '%vintage%year%';
  if n <> 2 then
    raise exception 'T1: expected exactly the 2 SQL 119 resolvers, found %', n;
  end if;
  raise notice 'T1 passed';

  -- ---- T2. damage_records.vintage ---------------------------------------
  -- Old client: no vintage sent. 2 Sep 2026 is on/after 1 Sep → Vintage 2027.
  insert into public.damage_records (id, vineyard_id, paddock_id, date, damage_type, damage_percent)
  values (d1, v1, bA, timestamptz '2026-09-02 04:00:00+00', 'Frost', 20);
  select vintage into v_int from public.damage_records where id = d1;
  if v_int <> 2027 then raise exception 'T2: 2026-09-02 resolved to % (expected 2027)', v_int; end if;

  -- Same season, other side of new year.
  insert into public.damage_records (id, vineyard_id, paddock_id, date, damage_type, damage_percent)
  values (d2, v1, bA, timestamptz '2027-03-01 04:00:00+00', 'Hail', 10);
  select vintage into v_int from public.damage_records where id = d2;
  if v_int <> 2027 then raise exception 'T2: 2027-03-01 resolved to % (expected 2027)', v_int; end if;

  -- date_observed wins over date.
  update public.damage_records
     set date_observed = timestamptz '2026-08-31 04:00:00+00'
   where id = d2;
  select vintage into v_int from public.damage_records where id = d2;
  if v_int <> 2026 then
    raise exception 'T2: moving date_observed to 2026-08-31 gave % (expected 2026)', v_int;
  end if;

  -- Vineyard-local season boundary: v1 is Australia/Sydney (AEST = UTC+10
  -- in late August). Both instants below land on 31 August in UTC, so a raw
  -- session-timezone ::date would classify BOTH as Vintage 2026. Converted
  -- to vineyard-local time they straddle local midnight 31 Aug / 1 Sep and
  -- MUST split 2026 / 2027.
  insert into public.damage_records (id, vineyard_id, paddock_id, date, damage_type, damage_percent)
  values (d3, v1, bA, timestamptz '2026-08-31 13:30:00+00', 'Frost', 15);
  select vintage into v_int from public.damage_records where id = d3;
  if v_int <> 2026 then
    raise exception 'T2: 13:30 UTC (23:30 local 31 Aug) resolved to % (expected 2026)', v_int;
  end if;

  insert into public.damage_records (id, vineyard_id, paddock_id, date, damage_type, damage_percent)
  values (d4, v1, bA, timestamptz '2026-08-31 14:30:00+00', 'Frost', 15);
  select vintage into v_int from public.damage_records where id = d4;
  if v_int <> 2027 then
    raise exception 'T2: 14:30 UTC (00:30 local 1 Sep) resolved to % (expected 2027)', v_int;
  end if;

  -- The boundary must also work through the date_observed fallback.
  update public.damage_records
     set date = timestamptz '2026-08-31 13:30:00+00',
         date_observed = timestamptz '2026-08-31 14:30:00+00'
   where id = d3;
  select vintage into v_int from public.damage_records where id = d3;
  if v_int <> 2027 then
    raise exception 'T2: date_observed local boundary gave % (expected 2027)', v_int;
  end if;

  -- New client sends an explicit vintage: preserved verbatim.
  insert into public.damage_records (vineyard_id, paddock_id, date, damage_type, damage_percent, vintage)
  values (v1, bB, timestamptz '2026-09-02 04:00:00+00', 'Frost', 5, 2026)
  returning id, vintage into d5, v_int;
  if v_int <> 2026 then raise exception 'T2: explicit client vintage overwritten (%)', v_int; end if;

  -- An UNRELATED edit must never move a user-confirmed vintage.
  update public.damage_records set damage_percent = 25 where id = d5;
  select vintage into v_int from public.damage_records where id = d5;
  if v_int <> 2026 then
    raise exception 'T2: unrelated edit moved a confirmed vintage to %', v_int;
  end if;

  -- A deliberate restatement alongside a date move is honoured as sent.
  update public.damage_records
     set date = timestamptz '2027-03-01 04:00:00+00', vintage = 2028
   where id = d5;
  select vintage into v_int from public.damage_records where id = d5;
  if v_int <> 2028 then
    raise exception 'T2: deliberate vintage restatement not honoured (%)', v_int;
  end if;

  -- Implausible client value is repaired server-side, never stored.
  insert into public.damage_records (vineyard_id, paddock_id, date, damage_type, damage_percent, vintage)
  values (v1, bB, timestamptz '2026-09-02 04:00:00+00', 'Frost', 5, 1)
  returning vintage into v_int;
  if v_int <> 2027 then raise exception 'T2: implausible vintage not repaired (%)', v_int; end if;

  -- Untouched fields: soft delete, geometry and percent behave exactly as before.
  select damage_percent, deleted_at is null into v_num, v_bool
    from public.damage_records where id = d1;
  if v_num <> 20 or not v_bool then raise exception 'T2: existing damage behaviour changed'; end if;
  raise notice 'T2 passed';

  -- ---- T3. yield_estimation_sessions.vintage -----------------------------
  -- payload deliberately claims a DIFFERENT vintage; the column must ignore it.
  insert into public.yield_estimation_sessions
    (id, vineyard_id, payload, is_completed, session_created_at)
  values (s1, v1, jsonb_build_object('vintage', 1999, 'sampleSites', '[]'::jsonb),
          true, timestamptz '2026-09-02 04:00:00+00');
  select vintage into v_int from public.yield_estimation_sessions where id = s1;
  if v_int <> 2027 then raise exception 'T3: session vintage % (expected 2027)', v_int; end if;

  -- Vineyard-local boundary for sessions too: 14:30 UTC on 31 Aug is
  -- 00:30 local on 1 Sep in Sydney → Vintage 2027, not 2026.
  insert into public.yield_estimation_sessions
    (id, vineyard_id, payload, is_completed, session_created_at)
  values (s3, v1, '{}'::jsonb, true, timestamptz '2026-08-31 14:30:00+00');
  select vintage into v_int from public.yield_estimation_sessions where id = s3;
  if v_int <> 2027 then
    raise exception 'T3: session 14:30 UTC (00:30 local 1 Sep) gave % (expected 2027)', v_int;
  end if;

  -- No session_created_at → created_at fallback.
  insert into public.yield_estimation_sessions
    (id, vineyard_id, payload, is_completed, created_at)
  values (s2, v1, '{}'::jsonb, false, timestamptz '2026-05-05 04:00:00+00');
  select vintage into v_int from public.yield_estimation_sessions where id = s2;
  if v_int <> 2026 then raise exception 'T3: created_at fallback gave % (expected 2026)', v_int; end if;
  raise notice 'T3 passed';

  -- ---- T4. Pruning formula ----------------------------------------------
  v_res := public._refresh_pruning_yield_estimates(v1, 2027);

  -- Block A: 1000 vines × (2 × 6) buds × 1.5 bunches × 120 g ÷ 1e6 = 2.16 t
  select base_estimate_tonnes into v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bA and deleted_at is null;
  if abs(v_num - 2.16) > 1e-9 then raise exception 'T4: Block A = % (expected 2.16)', v_num; end if;

  -- Block B (cane): 500 × (4 × 10) × 1.5 × 120 ÷ 1e6 = 3.6 t
  select base_estimate_tonnes into v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bB and deleted_at is null;
  if abs(v_num - 3.6) > 1e-9 then raise exception 'T4: Block B = % (expected 3.6)', v_num; end if;

  -- Vine-count precedence: override wins even though vines_per_ha exists elsewhere.
  select source_inputs ->> 'vine_count_basis' into v_txt
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bA and deleted_at is null;
  if v_txt <> 'block_vine_count_override' then
    raise exception 'T4: Block A vine basis % ', v_txt;
  end if;

  -- Block E has no override: area × vines_per_ha.
  select coalesce(public._paddock_polygon_area_hectares(polygon_points), 0)
    into v_area from public.paddocks where id = bE;
  if v_area <= 0 then raise exception 'T4: Block E fixture area is not positive'; end if;

  select source_inputs ->> 'vine_count_basis', base_estimate_tonnes
    into v_txt, v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bE and deleted_at is null;
  if v_txt <> 'block_area_x_vines_per_ha' then
    raise exception 'T4: Block E vine basis %', v_txt;
  end if;
  if abs(v_num - (v_area * 2000 * 12 * 1.5 * 120 / 1000000.0)) > 1e-9 then
    raise exception 'T4: Block E tonnes % disagree with area × vines_per_ha', v_num;
  end if;
  raise notice 'T4 passed';

  -- ---- T5. Missing inputs are NEVER zero ---------------------------------
  select base_estimate_tonnes, is_estimate_available, setup_warnings
    into v_num, v_bool, v_json
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bC and deleted_at is null;
  if v_num is not null then
    raise exception 'T5: unconfigured block produced % tonnes (must be NULL)', v_num;
  end if;
  if v_bool then raise exception 'T5: unconfigured block marked available'; end if;
  if not (v_json ? 'missing_pruning_settings') then
    raise exception 'T5: missing_pruning_settings warning absent (got %)', v_json;
  end if;
  raise notice 'T5 passed';

  -- ---- T6. Mixed-variety split -------------------------------------------
  select count(*) into n
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD and deleted_at is null;
  if n <> 3 then raise exception 'T6: expected 3 planting groups on Block D, found %', n; end if;

  -- Two identical Shiraz/MV6/101-14 allocations merge into ONE group at 60%.
  select allocation_percent, base_estimate_tonnes,
         coalesce(array_length(variety_allocation_ids, 1), 0)
    into v_num, v_area, n
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD
     and planting_group_key = k_shiraz and deleted_at is null;
  if abs(v_num - 60) > 1e-9 then raise exception 'T6: Shiraz percent % (expected 60)', v_num; end if;
  if abs(v_area - 1.296) > 1e-9 then raise exception 'T6: Shiraz tonnes % (expected 1.296)', v_area; end if;
  if n <> 2 then raise exception 'T6: expected 2 member allocation ids, found %', n; end if;

  select base_estimate_tonnes into v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD
     and planting_group_key = k_cab and deleted_at is null;
  if abs(v_num - 0.648) > 1e-9 then raise exception 'T6: Cabernet tonnes % (expected 0.648)', v_num; end if;

  -- Residual 10% is preserved as "Unallocated variety".
  select base_estimate_tonnes, is_unallocated into v_num, v_bool
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD
     and planting_group_key = k_unalloc and deleted_at is null;
  if abs(v_num - 0.216) > 1e-9 then raise exception 'T6: unallocated tonnes % (expected 0.216)', v_num; end if;
  if not v_bool then raise exception 'T6: residual group not flagged is_unallocated'; end if;

  -- The three groups still sum to the block total.
  select sum(base_estimate_tonnes) into v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD and deleted_at is null;
  if abs(v_num - 2.16) > 1e-9 then raise exception 'T6: Block D groups sum to % (expected 2.16)', v_num; end if;
  raise notice 'T6 passed';

  -- ---- T7. Priority: manual is never downgraded --------------------------
  -- NOTE (B5): this fixture is written as the migration/test role (postgres),
  -- NOT as an authenticated client. Since SQL 221 the canonical table is
  -- client READ-ONLY, so a normal signed-in user CANNOT create a manual
  -- estimate directly — T15 proves exactly that. Manual and bunch_count
  -- sources will arrive through their own validated RPCs in a later phase;
  -- here we simply need a higher-priority row to exist so the pruning refresh
  -- can be shown to leave it alone.
  update public.season_yield_estimates
     set estimate_source = 'manual',
         base_estimate_tonnes = 9.99,
         is_estimate_available = true
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bA and deleted_at is null;

  v_res := public._refresh_pruning_yield_estimates(v1, 2027);

  select estimate_source, base_estimate_tonnes into v_txt, v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bA and deleted_at is null;
  if v_txt <> 'manual' or abs(v_num - 9.99) > 1e-9 then
    raise exception 'T7: pruning refresh overwrote a manual estimate (% / %)', v_txt, v_num;
  end if;
  if (v_res ->> 'rows_skipped_higher_priority')::integer < 1 then
    raise exception 'T7: skipped count not reported (%)', v_res;
  end if;

  if public.season_yield_estimate_source_rank('manual')
     <= public.season_yield_estimate_source_rank('bunch_count')
     or public.season_yield_estimate_source_rank('bunch_count')
     <= public.season_yield_estimate_source_rank('pruning_calculator') then
    raise exception 'T7: source priority order is wrong';
  end if;
  raise notice 'T7 passed';

  -- ---- T8. Idempotency ---------------------------------------------------
  select count(*) into n from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and deleted_at is null;
  v_res := public._refresh_pruning_yield_estimates(v1, 2027);
  if (v_res ->> 'rows_inserted')::integer <> 0 then
    raise exception 'T8: repeat refresh inserted % rows', v_res ->> 'rows_inserted';
  end if;
  select count(*) into v_int from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and deleted_at is null;
  if v_int <> n then raise exception 'T8: active row count drifted % → %', n, v_int; end if;
  raise notice 'T8 passed';

  -- ---- T9. Stale planting groups -----------------------------------------
  update public.paddocks
     set variety_allocations = jsonb_build_array(
           jsonb_build_object('varietyKey', 'shiraz', 'name', 'Shiraz',
                              'clone', 'MV6', 'rootstock', '101-14', 'percent', 100))
   where id = bD;

  v_res := public._refresh_pruning_yield_estimates(v1, 2027);

  select count(*) into n from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD
     and planting_group_key = k_cab and deleted_at is null;
  if n <> 0 then raise exception 'T9: removed Cabernet group still active'; end if;

  select count(*) into n from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD
     and planting_group_key = k_cab and deleted_at is not null;
  if n <> 1 then raise exception 'T9: removed group was hard-deleted, not soft-deleted'; end if;

  select base_estimate_tonnes into v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bD
     and planting_group_key = k_shiraz and deleted_at is null;
  if abs(v_num - 2.16) > 1e-9 then raise exception 'T9: Shiraz now % (expected whole block 2.16)', v_num; end if;
  raise notice 'T9 passed';

  -- ---- T10. Vintage isolation --------------------------------------------
  v_res := public._refresh_pruning_yield_estimates(v1, 2026);
  select count(*) into n from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2026 and deleted_at is null;
  if n = 0 then raise exception 'T10: 2026 refresh produced nothing'; end if;

  -- The manual 2027 row is untouched by a 2026 refresh.
  select estimate_source, base_estimate_tonnes into v_txt, v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bA and deleted_at is null;
  if v_txt <> 'manual' or abs(v_num - 9.99) > 1e-9 then
    raise exception 'T10: 2026 refresh disturbed the 2027 estimate';
  end if;
  raise notice 'T10 passed';

  -- ---- T11. get_season_yield_base_overview -------------------------------
  -- v3 is the fully-configured control vineyard: every row available.
  v_res := public._refresh_pruning_yield_estimates(v3, 2027);

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_res := public.get_season_yield_base_overview(v1, 2027);

  if (v_res ->> 'vintage')::integer <> 2027 then raise exception 'T11: wrong vintage echoed'; end if;
  if jsonb_typeof(v_res -> 'blocks') <> 'array' then raise exception 'T11: blocks not an array'; end if;
  if jsonb_typeof(v_res -> 'varieties') <> 'array' then raise exception 'T11: varieties not an array'; end if;
  if v_res -> 'source_inputs' is null then raise exception 'T11: source_inputs missing'; end if;
  if jsonb_typeof(v_res -> 'setup_warnings') <> 'array' then
    raise exception 'T11: setup_warnings not an array';
  end if;
  if v_res ->> 'estimate_source' is null then raise exception 'T11: estimate_source missing'; end if;
  if v_res ->> 'calculated_at' is null then raise exception 'T11: calculated_at missing'; end if;

  -- Manual outranks pruning at the top level.
  if v_res ->> 'estimate_source' <> 'manual' then
    raise exception 'T11: top-level source % (expected manual)', v_res ->> 'estimate_source';
  end if;

  -- Base-only contract: nothing damage-related is returned.
  if v_res::text ilike '%adjusted%' or v_res::text ilike '%damage_factor%' then
    raise exception 'T11: overview leaked a damage-adjusted figure';
  end if;
  if (v_res -> 'source_inputs' -> 'summary' ->> 'damage_applied')::boolean then
    raise exception 'T11: overview claims damage was applied';
  end if;

  -- (B2) v1 contains unconfigured Block C, so this vineyard is INCOMPLETE.
  -- The canonical total must be withheld while the known subtotal is still
  -- published for diagnostics.
  if (v_res ->> 'is_estimate_complete')::boolean then
    raise exception 'T11: vineyard with an unconfigured block claims completeness';
  end if;
  if v_res -> 'total_base_estimate_tonnes' <> 'null'::jsonb then
    raise exception 'T11: canonical total published while incomplete (%)',
      v_res ->> 'total_base_estimate_tonnes';
  end if;

  select coalesce(sum(base_estimate_tonnes), 0) into v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and deleted_at is null and is_estimate_available;
  if abs((v_res ->> 'known_base_estimate_tonnes')::double precision - v_num) > 1e-9 then
    raise exception 'T11: known subtotal % disagrees with row sum %',
      v_res ->> 'known_base_estimate_tonnes', v_num;
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_res -> 'setup_warnings') w
     where w ->> 'code' = 'estimate_incomplete'
  ) then
    raise exception 'T11: estimate_incomplete warning missing on a partial vineyard';
  end if;

  -- Block counts must add up and identify the unconfigured block.
  select count(distinct paddock_id) into n
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and deleted_at is null;
  if (v_res ->> 'blocks_total')::integer <> n then
    raise exception 'T11: blocks_total % <> % distinct blocks', v_res ->> 'blocks_total', n;
  end if;
  if (v_res ->> 'blocks_available')::integer + (v_res ->> 'blocks_unavailable')::integer
     <> (v_res ->> 'blocks_total')::integer then
    raise exception 'T11: block counts do not reconcile (%)', v_res;
  end if;
  if (v_res ->> 'blocks_unavailable')::integer < 1 then
    raise exception 'T11: unconfigured Block C not counted as unavailable';
  end if;

  -- The unconfigured block itself must withhold its canonical figure too,
  -- and must NOT report 0 t.
  if not exists (
    select 1 from jsonb_array_elements(v_res -> 'blocks') b
     where (b ->> 'paddock_id')::uuid = bC
       and b -> 'base_estimate_tonnes' = 'null'::jsonb
       and (b ->> 'is_estimate_complete')::boolean is false
  ) then
    raise exception 'T11: unconfigured block did not withhold its canonical estimate';
  end if;

  -- A variety that draws on an unavailable block withholds its total as well.
  if exists (
    select 1 from jsonb_array_elements(v_res -> 'varieties') vv
     where (vv ->> 'is_estimate_complete')::boolean is false
       and vv -> 'base_estimate_tonnes' <> 'null'::jsonb
  ) then
    raise exception 'T11: an incomplete variety published a canonical total';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_res -> 'varieties') vv
     where vv -> 'known_base_estimate_tonnes' is null
  ) then
    raise exception 'T11: variety known subtotal missing';
  end if;

  -- Identity is retained per block/group.
  if not exists (
    select 1
      from jsonb_array_elements(v_res -> 'blocks') b,
           jsonb_array_elements(b -> 'groups') g
     where g ->> 'planting_group_key' = k_shiraz
  ) then
    raise exception 'T11: planting_group_key identity lost in the overview';
  end if;

  -- The RPC signature must NOT accept apply_damage.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'get_season_yield_base_overview'
     and pg_get_function_identity_arguments(p.oid) = 'p_vineyard_id uuid, p_vintage integer';
  if n <> 1 then raise exception 'T11: unexpected overview signature'; end if;

  -- (B2) A vintage with NO rows must be unknown, not zero. This branch used to
  -- be unreachable: the aggregate always produced one row, so the coalesce
  -- fallback never fired and callers saw a confident 0 t.
  v_res := public.get_season_yield_base_overview(v1, 2099);
  if jsonb_array_length(v_res -> 'blocks') <> 0 then
    raise exception 'T11: empty vintage returned blocks (%)', v_res;
  end if;
  if v_res -> 'total_base_estimate_tonnes' <> 'null'::jsonb then
    raise exception 'T11: empty vintage returned a canonical total of % (expected null)',
      v_res ->> 'total_base_estimate_tonnes';
  end if;
  if (v_res ->> 'known_base_estimate_tonnes')::double precision <> 0 then
    raise exception 'T11: empty vintage known subtotal % (expected 0)',
      v_res ->> 'known_base_estimate_tonnes';
  end if;
  if (v_res ->> 'is_estimate_complete')::boolean then
    raise exception 'T11: empty vintage claims completeness';
  end if;
  if v_res ->> 'estimate_source' <> 'none' then
    raise exception 'T11: empty vintage source % (expected none)', v_res ->> 'estimate_source';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_res -> 'setup_warnings') w
     where w ->> 'code' = 'no_estimates_for_vintage'
  ) then
    raise exception 'T11: no_estimates_for_vintage warning missing (%)', v_res;
  end if;

  -- (B2) A COMPLETE vineyard publishes a usable canonical total that Grape
  -- Allocation may consume.
  v_res := public.get_season_yield_base_overview(v3, 2027);
  if not (v_res ->> 'is_estimate_complete')::boolean then
    raise exception 'T11: fully configured vineyard reported incomplete (%)', v_res;
  end if;
  if abs((v_res ->> 'total_base_estimate_tonnes')::double precision - 2.16) > 1e-9 then
    raise exception 'T11: complete canonical total % (expected 2.16)',
      v_res ->> 'total_base_estimate_tonnes';
  end if;
  if abs((v_res ->> 'known_base_estimate_tonnes')::double precision - 2.16) > 1e-9 then
    raise exception 'T11: complete known subtotal % (expected 2.16)',
      v_res ->> 'known_base_estimate_tonnes';
  end if;
  if (v_res ->> 'blocks_unavailable')::integer <> 0 then
    raise exception 'T11: complete vineyard reports unavailable blocks';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_res -> 'setup_warnings') w
     where w ->> 'code' in ('estimate_incomplete', 'no_estimates_for_vintage')
  ) then
    raise exception 'T11: complete vineyard still carries an incompleteness warning';
  end if;
  perform set_config('role', 'postgres', true);
  raise notice 'T11 passed';

  -- ---- T12. Permissions ---------------------------------------------------
  -- (B4) The public wrapper only accepts the vineyard's CURRENT vintage, so
  -- the operator must call it with the runtime-resolved value rather than the
  -- fixture's 2027.
  v_current := public.resolve_vineyard_vintage_year(
    v1, (now() at time zone 'Australia/Sydney')::date);

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_operator, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  v_res := public.refresh_pruning_yield_estimates(v1, v_current);
  if v_res is null then raise exception 'T12: operator refresh returned null'; end if;
  perform set_config('role', 'postgres', true);

  -- Stranger (member of another vineyard) is denied both RPCs and sees no rows.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_stranger, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_caught := false;
  begin
    perform public.get_season_yield_base_overview(v1, 2027);
  exception when others then v_caught := true;
  end;
  if not v_caught then raise exception 'T12: stranger read the overview'; end if;

  v_caught := false;
  begin
    perform public.refresh_pruning_yield_estimates(v1, v_current);
  exception when others then v_caught := true;
  end;
  if not v_caught then raise exception 'T12: stranger refreshed estimates'; end if;

  select count(*) into n from public.season_yield_estimates where vineyard_id = v1;
  if n <> 0 then raise exception 'T12: RLS leaked % rows to a stranger', n; end if;

  -- Hard delete is denied even for a member's own vineyard. Since B5 the
  -- table privilege refuses it outright; before that only the RLS policy did.
  -- Either outcome is acceptable, a deleted row is not.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  v_caught := false;
  n := -1;
  begin
    delete from public.season_yield_estimates where vineyard_id = v1;
    get diagnostics n = row_count;
  exception when others then
    v_caught := true;
  end;
  if not v_caught and n <> 0 then
    raise exception 'T12: client hard delete succeeded (% rows)', n;
  end if;
  perform set_config('role', 'postgres', true);

  -- Anonymous callers are refused.
  perform set_config('request.jwt.claims', '', true);
  v_caught := false;
  begin
    perform public.get_season_yield_base_overview(v1, 2027);
  exception when others then v_caught := true;
  end;
  if not v_caught then raise exception 'T12: anonymous read allowed'; end if;
  raise notice 'T12 passed';

  -- ---- T13. (B3) Allocation reconciliation --------------------------------
  perform set_config('request.jwt.claims', '', true);

  -- Block F: 51.8% + 50% = 101.8% (the shape found in the live audit).
  -- Groups must be normalised proportionally back to exactly 100%.
  select coalesce(sum(allocation_percent), 0), coalesce(sum(base_estimate_tonnes), 0)
    into v_num, v_area
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bF and deleted_at is null;
  if abs(v_num - 100) > 1e-6 then
    raise exception 'T13: Block F percentages sum to % (expected 100)', v_num;
  end if;
  if abs(v_area - 2.16) > 1e-9 then
    raise exception 'T13: Block F group tonnes sum to % (expected the block total 2.16)', v_area;
  end if;

  select allocation_percent, base_estimate_tonnes into v_num, v_area
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bF
     and planting_group_key = k_shiraz and deleted_at is null;
  if abs(v_num - (51.8 / 101.8 * 100)) > 1e-9 then
    raise exception 'T13: Block F Shiraz normalised to % (expected %)',
      v_num, 51.8 / 101.8 * 100;
  end if;
  if abs(v_area - (2.16 * 51.8 / 101.8)) > 1e-9 then
    raise exception 'T13: Block F Shiraz tonnes % disagree with its normalised share', v_area;
  end if;

  select setup_warnings, source_inputs into v_json, v_res
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bF
     and planting_group_key = k_shiraz and deleted_at is null;
  if not (v_json ? 'block_allocations_over_100_normalized') then
    raise exception 'T13: Block F missing block_allocations_over_100_normalized (%)', v_json;
  end if;
  -- The original total is preserved for explanation/audit.
  if abs((v_res ->> 'allocation_percent_total_original')::double precision - 101.8) > 1e-9 then
    raise exception 'T13: Block F original total not preserved (%)',
      v_res ->> 'allocation_percent_total_original';
  end if;
  if abs((v_res ->> 'allocation_percent_total_final')::double precision - 100) > 1e-6 then
    raise exception 'T13: Block F final total % (expected 100)',
      v_res ->> 'allocation_percent_total_final';
  end if;

  -- Block G: duplicates merge FIRST (60 + 60 = 120 as one group), then
  -- normalise to 100. Merging after capping would have produced two 60%
  -- groups and 120% of the block's tonnes.
  select count(*) into n
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bG and deleted_at is null;
  if n <> 1 then raise exception 'T13: Block G should hold ONE merged group, found %', n; end if;

  select allocation_percent, base_estimate_tonnes, source_inputs
    into v_num, v_area, v_res
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bG
     and planting_group_key = k_shiraz and deleted_at is null;
  if abs(v_num - 100) > 1e-6 then
    raise exception 'T13: Block G merged group at % (expected 100)', v_num;
  end if;
  if abs(v_area - 2.16) > 1e-9 then
    raise exception 'T13: Block G tonnes % (expected the whole block 2.16)', v_area;
  end if;
  if abs((v_res ->> 'allocation_percent_total_original')::double precision - 120) > 1e-9 then
    raise exception 'T13: Block G original total % (expected 120)',
      v_res ->> 'allocation_percent_total_original';
  end if;

  -- Block H: a numeric STRING parses; a non-numeric value and a negative value
  -- are excluded and named, never read as a legitimate zero.
  select allocation_percent, base_estimate_tonnes, setup_warnings
    into v_num, v_area, v_json
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bH
     and planting_group_key = k_shiraz and deleted_at is null;
  if abs(v_num - 45.5) > 1e-9 then
    raise exception 'T13: numeric-string percent parsed as % (expected 45.5)', v_num;
  end if;
  if abs(v_area - (2.16 * 0.455)) > 1e-9 then
    raise exception 'T13: Block H Shiraz tonnes % (expected 0.9828)', v_area;
  end if;
  if not (v_json ? 'allocation_percent_invalid') then
    raise exception 'T13: allocation_percent_invalid warning missing (%)', v_json;
  end if;
  if not (v_json ? 'block_allocations_under_100') then
    raise exception 'T13: Block H residual warning missing (%)', v_json;
  end if;

  -- The invalid and negative allocations must NOT have produced groups.
  select count(*) into n
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bH
     and planting_group_key in (k_merlot, k_grenache) and deleted_at is null;
  if n <> 0 then
    raise exception 'T13: invalid/negative allocations produced % group(s)', n;
  end if;

  -- The residual is preserved as Unallocated, and the block still reconciles.
  select coalesce(sum(allocation_percent), 0), coalesce(sum(base_estimate_tonnes), 0)
    into v_num, v_area
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and paddock_id = bH and deleted_at is null;
  if abs(v_num - 100) > 1e-6 then
    raise exception 'T13: Block H percentages sum to % (expected 100)', v_num;
  end if;
  if abs(v_area - 2.16) > 1e-9 then
    raise exception 'T13: Block H group tonnes sum to % (expected 2.16)', v_area;
  end if;

  -- Global invariant: no available block may allocate above 100%.
  if exists (
    select 1
      from public.season_yield_estimates
     where vineyard_id = v1 and vintage = 2027 and deleted_at is null
       and is_estimate_available
     group by paddock_id
    having abs(sum(allocation_percent) - 100) > 1e-6
  ) then
    raise exception 'T13: a block''s allocation percentages do not sum to 100';
  end if;
  raise notice 'T13 passed';

  -- ---- T14. (B4) Current vintage only -------------------------------------
  v_current := public.resolve_vineyard_vintage_year(
    v1, (now() at time zone 'Australia/Sydney')::date);

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- Accepts the vineyard's current vintage.
  v_res := public.refresh_pruning_yield_estimates(v1, v_current);
  if (v_res ->> 'vintage')::integer <> v_current then
    raise exception 'T14: refresh echoed vintage % (expected %)',
      v_res ->> 'vintage', v_current;
  end if;

  -- Rejects a historical vintage: today's pruning settings must never be
  -- written into a finished season.
  v_caught := false;
  v_txt := null;
  begin
    perform public.refresh_pruning_yield_estimates(v1, v_current - 1);
  exception when others then
    v_caught := true;
    v_txt := sqlerrm;
  end;
  if not v_caught then
    raise exception 'T14: historical vintage refresh was allowed';
  end if;
  if v_txt not like '%pruning_estimate_refresh_current_vintage_only%' then
    raise exception 'T14: historical refresh failed with the wrong error (%)', v_txt;
  end if;

  -- Rejects a future vintage.
  v_caught := false;
  v_txt := null;
  begin
    perform public.refresh_pruning_yield_estimates(v1, v_current + 1);
  exception when others then
    v_caught := true;
    v_txt := sqlerrm;
  end;
  if not v_caught then
    raise exception 'T14: future vintage refresh was allowed';
  end if;
  if v_txt not like '%pruning_estimate_refresh_current_vintage_only%' then
    raise exception 'T14: future refresh failed with the wrong error (%)', v_txt;
  end if;

  -- A vineyard on a different local clock resolves with ITS OWN timezone.
  v_int := public.resolve_vineyard_vintage_year(
    v4, (now() at time zone 'Pacific/Auckland')::date);
  v_res := public.refresh_pruning_yield_estimates(v4, v_int);
  if (v_res ->> 'vintage')::integer <> v_int then
    raise exception 'T14: vineyard-local current vintage rejected for v4';
  end if;
  perform set_config('role', 'postgres', true);

  -- The INTERNAL worker still builds isolated fixtures for any vintage, which
  -- is what makes vintage-isolation testing (T10) possible.
  v_res := public._refresh_pruning_yield_estimates(v3, 2024);
  select count(*) into n from public.season_yield_estimates
   where vineyard_id = v3 and vintage = 2024 and deleted_at is null;
  if n = 0 then
    raise exception 'T14: internal worker could not build an isolated fixture';
  end if;
  raise notice 'T14 passed';

  -- ---- T15. (B1/B5) Least privilege ---------------------------------------
  -- (B1) Internal helpers must not be reachable by any client role. They are
  -- SECURITY DEFINER and take a vineyard id, so a grant here would hand any
  -- signed-in user another vineyard's blocks, vine counts and settings.
  if has_function_privilege('authenticated',
       'public._pruning_block_estimate(uuid, uuid)', 'EXECUTE') then
    raise exception 'T15: _pruning_block_estimate is EXECUTE-able by authenticated';
  end if;
  if has_function_privilege('anon',
       'public._pruning_block_estimate(uuid, uuid)', 'EXECUTE') then
    raise exception 'T15: _pruning_block_estimate is EXECUTE-able by anon';
  end if;
  if has_function_privilege('authenticated',
       'public._refresh_pruning_yield_estimates(uuid, integer)', 'EXECUTE') then
    raise exception 'T15: _refresh_pruning_yield_estimates is EXECUTE-able by authenticated';
  end if;
  if has_function_privilege('authenticated',
       'public._season_alloc_text(jsonb, text[])', 'EXECUTE')
     or has_function_privilege('authenticated',
       'public._season_alloc_number(jsonb, text[])', 'EXECUTE') then
    raise exception 'T15: allocation readers are EXECUTE-able by authenticated';
  end if;

  -- The supported public entry points remain callable.
  if not has_function_privilege('authenticated',
       'public.refresh_pruning_yield_estimates(uuid, integer)', 'EXECUTE')
     or not has_function_privilege('authenticated',
       'public.get_season_yield_base_overview(uuid, integer)', 'EXECUTE') then
    raise exception 'T15: a public RPC lost its EXECUTE grant';
  end if;

  -- A stranger cannot reach the internal helper directly.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_stranger, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  v_caught := false;
  begin
    perform public._pruning_block_estimate(v1, bA);
  exception when others then v_caught := true;
  end;
  perform set_config('role', 'postgres', true);
  if not v_caught then
    raise exception 'T15: a stranger called _pruning_block_estimate directly';
  end if;

  -- (B5) Canonical table privileges: read-only for clients.
  if not has_table_privilege('authenticated', 'public.season_yield_estimates', 'SELECT') then
    raise exception 'T15: authenticated lost SELECT on season_yield_estimates';
  end if;
  if has_table_privilege('authenticated', 'public.season_yield_estimates', 'INSERT')
     or has_table_privilege('authenticated', 'public.season_yield_estimates', 'UPDATE')
     or has_table_privilege('authenticated', 'public.season_yield_estimates', 'DELETE') then
    raise exception 'T15: season_yield_estimates is still client-writable';
  end if;

  -- Every privileged role is refused a direct write: no client may invent a
  -- manual estimate, change the source, or set arbitrary tonnes.
  foreach v_user in array array[u_owner, u_manager, u_supervisor, u_operator]
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);

    v_caught := false;
    begin
      insert into public.season_yield_estimates
        (vineyard_id, vintage, paddock_id, planting_group_key, variety_name,
         estimate_source, base_estimate_tonnes, is_estimate_available)
      values (v1, 2027, bB, k_shiraz, 'Shiraz', 'manual', 999, true);
    exception when others then v_caught := true;
    end;
    if not v_caught then
      perform set_config('role', 'postgres', true);
      raise exception 'T15: a client role inserted directly into the canonical table';
    end if;

    v_caught := false;
    begin
      update public.season_yield_estimates
         set estimate_source = 'manual'
       where vineyard_id = v1 and vintage = 2027;
    exception when others then v_caught := true;
    end;
    if not v_caught then
      perform set_config('role', 'postgres', true);
      raise exception 'T15: a client role changed estimate_source directly';
    end if;

    v_caught := false;
    begin
      update public.season_yield_estimates
         set base_estimate_tonnes = 999
       where vineyard_id = v1 and vintage = 2027;
    exception when others then v_caught := true;
    end;
    if not v_caught then
      perform set_config('role', 'postgres', true);
      raise exception 'T15: a client role changed tonnes directly';
    end if;

    perform set_config('role', 'postgres', true);
  end loop;

  -- The deterministic RPC remains the one supported write path.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_operator, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  v_res := public.refresh_pruning_yield_estimates(v1, v_current);
  if v_res is null then raise exception 'T15: operator refresh RPC failed'; end if;
  perform set_config('role', 'postgres', true);

  -- Nothing above managed to plant a manual 999 t row.
  if exists (
    select 1 from public.season_yield_estimates
     where vineyard_id = v1 and base_estimate_tonnes = 999
  ) then
    raise exception 'T15: a direct client write reached the canonical table';
  end if;
  raise notice 'T15 passed';

  raise notice 'SQL 221 season yield estimate tests: ALL PASSED';
end
$t221$;

-- ---- T16. Discard everything ------------------------------------------
rollback;
