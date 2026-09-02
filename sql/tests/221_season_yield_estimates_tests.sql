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
--   T11 get_season_yield_base_overview — shape, totals, base-only contract
--   T12 Permissions — member reads, operator refreshes, stranger denied,
--       anonymous denied
--   T13 All fixtures discarded by the final ROLLBACK
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
  u_owner    uuid;
  u_operator uuid;
  u_stranger uuid;
  v1         uuid := gen_random_uuid();
  v2         uuid := gen_random_uuid();
  bA         uuid := gen_random_uuid();  -- spur, vine override 1000
  bB         uuid := gen_random_uuid();  -- cane, vine override 500
  bC         uuid := gen_random_uuid();  -- no pruning settings
  bD         uuid := gen_random_uuid();  -- mixed variety
  bE         uuid := gen_random_uuid();  -- area × vines_per_ha path
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
  k_shiraz   text;
  k_cab      text;
  k_unalloc  text;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-owner@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-operator@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't221-stranger@test.local', 'x', now(), now(), now());
  select id into u_owner    from auth.users where email = 't221-owner@test.local';
  select id into u_operator from auth.users where email = 't221-operator@test.local';
  select id into u_stranger from auth.users where email = 't221-stranger@test.local';

  insert into public.profiles (id, email)
  values (u_owner, 't221-owner@test.local'),
         (u_operator, 't221-operator@test.local'),
         (u_stranger, 't221-stranger@test.local')
  on conflict (id) do nothing;

  -- Season starts 1 September, so 2026-09-02 AND 2027-03-01 are both Vintage 2027.
  -- v1 carries Australia/Sydney (AEST = UTC+10 in late August) so the
  -- vineyard-local boundary tests have a real offset to cross.
  insert into public.vineyards (id, name, season_start_month, season_start_day, timezone)
  values (v1, 'T221 Vineyard', 9, 1, 'Australia/Sydney'),
         (v2, 'T221 Other Vineyard', 9, 1, 'Australia/Sydney');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v1, u_owner, 'owner'),
    (v1, u_operator, 'operator'),
    (v2, u_stranger, 'owner');

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

  insert into public.pruning_yield_settings
    (vineyard_id, paddock_id, prune_method, bunches_per_bud, buds_per_spur,
     spurs_per_vine, buds_per_cane, canes_per_vine, vines_per_ha, bunch_weight_grams)
  values
    (v1, bA, 'spur', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bB, 'cane', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bD, 'spur', 1.5, 2, 6, 10, 4, null, 120),
    (v1, bE, 'spur', 1.5, 2, 6, 10, 4, 2000, 120);

  k_shiraz  := public.planting_group_key('Shiraz', 'MV6', '101-14');
  k_cab     := public.planting_group_key('Cabernet Sauvignon', null, null);
  k_unalloc := public.planting_group_key('Unallocated variety', null, null);

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

  -- Totals only count available rows; unconfigured Block C contributes nothing.
  select coalesce(sum(base_estimate_tonnes), 0) into v_num
    from public.season_yield_estimates
   where vineyard_id = v1 and vintage = 2027 and deleted_at is null and is_estimate_available;
  if abs((v_res ->> 'total_base_estimate_tonnes')::double precision - v_num) > 1e-9 then
    raise exception 'T11: total % disagrees with row sum %',
      v_res ->> 'total_base_estimate_tonnes', v_num;
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

  -- A vintage with no rows returns an empty, safe shape (never another vintage).
  v_res := public.get_season_yield_base_overview(v1, 2099);
  if jsonb_array_length(v_res -> 'blocks') <> 0
     or (v_res ->> 'total_base_estimate_tonnes')::double precision <> 0
     or v_res ->> 'estimate_source' <> 'none' then
    raise exception 'T11: empty vintage did not return an empty overview (%)', v_res;
  end if;
  perform set_config('role', 'postgres', true);
  raise notice 'T11 passed';

  -- ---- T12. Permissions ---------------------------------------------------
  -- Operator may refresh.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_operator, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  v_res := public.refresh_pruning_yield_estimates(v1, 2027);
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
    perform public.refresh_pruning_yield_estimates(v1, 2027);
  exception when others then v_caught := true;
  end;
  if not v_caught then raise exception 'T12: stranger refreshed estimates'; end if;

  select count(*) into n from public.season_yield_estimates where vineyard_id = v1;
  if n <> 0 then raise exception 'T12: RLS leaked % rows to a stranger', n; end if;

  -- Hard delete is denied even for a member's own vineyard.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  delete from public.season_yield_estimates where vineyard_id = v1;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'T12: client hard delete succeeded (% rows)', n; end if;
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

  raise notice 'SQL 221 season yield estimate tests: ALL PASSED';
end
$t221$;

-- ---- T13. Discard everything ------------------------------------------
rollback;
