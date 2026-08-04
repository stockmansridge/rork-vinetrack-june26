-- =====================================================================
-- 166_pruning_activities_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/166_pruning_activities.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production pruning row is created, changed or deleted.
--
-- Test map
--   T1  Objects, signatures, security definer, fixed search_path, grants
--   T2  derive_pruning_allocation_id is deterministic and MD5 v3 shaped
--   T3  One activity with ONE block
--   T4  One activity with SEVERAL blocks (one parent, three allocations)
--   T5  Labour is stored ONCE on the parent, never apportioned
--   T6  Totals are correct across allocations
--   T7  July / August 2026 -> season 2026 for EVERY allocation, vintage 2027
--   T8  An invalid block rolls back the ENTIRE activity
--   T9  Duplicate rows/quarters are canonicalised, never double-counted
--   T10 Retry with the same client activity UUID is idempotent
--   T11 Update ADDS a block
--   T12 Update REMOVES one block — the parent and other blocks survive
--   T13 Date change across a year boundary reassigns EVERY allocation
--   T14 Labour can change without touching allocations
--   T15 Allocations can change without duplicating labour
--   T16 Reversal reverses the FULL activity and releases every quarter
--   T17 A reversed activity cannot be edited; a stale edit is ignored
--   T18 Legacy record_pruning_entry still works -> one-allocation activity
--   T19 Legacy update_pruning_entry still works and mirrors up to the parent
--   T20 Legacy delete_pruning_entry reverses the parent activity
--   T21 A pre-existing (historic) entry is readable as a one-allocation activity
--   T22 Export breakdown counts shared labour exactly once
--   T23 Non-members and anonymous callers are rejected
--   T24 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 166 pruning activity tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 166 is applied.
do $$
begin
  if to_regclass('public.pruning_activities') is null
     or to_regprocedure('public.record_pruning_activity(uuid, uuid, jsonb, jsonb, timestamptz)') is null then
    raise exception 'SQL 166 not applied — run sql/166_pruning_activities.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr   uuid;
  u_out   uuid;
  v_vy    uuid := gen_random_uuid();
  v_vy2   uuid := gen_random_uuid();
  b_cab   uuid := gen_random_uuid();
  b_sauv  uuid := gen_random_uuid();
  b_pinot uuid := gen_random_uuid();
  b_alien uuid := gen_random_uuid();   -- block of ANOTHER vineyard
  a1      uuid := gen_random_uuid();   -- single block
  a2      uuid := gen_random_uuid();   -- three blocks
  a3      uuid := gen_random_uuid();   -- date-boundary edit
  a4      uuid := gen_random_uuid();   -- reversal
  a5      uuid := gen_random_uuid();   -- duplicate canonicalisation
  e_leg   uuid := gen_random_uuid();   -- legacy record_pruning_entry
  e_hist  uuid := gen_random_uuid();   -- historic direct insert
  r       jsonb;
  c       jsonb;
  n       integer;
  n2      integer;
  y       integer;
  num     numeric;
  ok      boolean;
  aid     uuid;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t166-mgr@test.local','t166-out@test.local']) e;
  select id into u_mgr from auth.users where email = 't166-mgr@test.local';
  select id into u_out from auth.users where email = 't166-out@test.local';

  insert into public.profiles (id, email)
  select u, 't166-' || u::text || '@test.local' from unnest(array[u_mgr, u_out]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T166 Activity Vineyard'),
    (v_vy2, 'T166 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy2, u_out, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_cab,   v_vy,  'T166 Cab Franc'),
    (b_sauv,  v_vy,  'T166 Sauvignon Blanc'),
    (b_pinot, v_vy,  'T166 Pinot Noir'),
    (b_alien, v_vy2, 'T166 Foreign Block');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);

  -- ---- T1. Objects, signatures, security, grants -------------------------
  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('record_pruning_activity','update_pruning_activity',
                      'get_pruning_activity','list_pruning_activities',
                      'reverse_pruning_activity','pruning_activity_json',
                      'apply_pruning_activity_allocation',
                      'sync_pruning_activity_rollup','derive_pruning_allocation_id');
  assert n >= 9, 'T1 all activity functions must exist, found ' || n;

  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prosecdef
    and p.proname in ('record_pruning_activity','update_pruning_activity',
                      'reverse_pruning_activity','apply_pruning_activity_allocation',
                      'sync_pruning_activity_rollup');
  assert n >= 5, 'T1 the write path must be security definer, found ' || n;

  select coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=public%' into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'record_pruning_activity'
    and p.pronargs = 5;
  assert ok, 'T1 record_pruning_activity must pin search_path';

  assert not has_function_privilege('anon',
    'public.record_pruning_activity(uuid, uuid, jsonb, jsonb, timestamptz)', 'execute'),
    'T1 anon must NOT execute record_pruning_activity';
  assert has_function_privilege('authenticated',
    'public.record_pruning_activity(uuid, uuid, jsonb, jsonb, timestamptz)', 'execute'),
    'T1 authenticated must execute record_pruning_activity';
  assert not has_function_privilege('anon',
    'public.apply_pruning_activity_allocation(uuid, uuid, date, text, text, text, integer, timestamptz, jsonb, integer)', 'execute'),
    'T1 the internal allocation helper must not be callable by anon';

  -- Clients may READ activities but never write them directly.
  select count(*) into n from pg_policies
  where schemaname = 'public' and tablename = 'pruning_activities';
  assert n >= 4, 'T1 pruning_activities needs its RLS policies, found ' || n;
  raise notice 'T1 passed: objects, signatures, security definer, search_path, grants';

  -- ---- T2. Deterministic allocation id ------------------------------------
  assert public.derive_pruning_allocation_id(a2, b_cab) = public.derive_pruning_allocation_id(a2, b_cab),
    'T2 derivation must be deterministic';
  assert public.derive_pruning_allocation_id(a2, b_cab) <> public.derive_pruning_allocation_id(a2, b_sauv),
    'T2 a different block must derive a different allocation id';
  assert substr(public.derive_pruning_allocation_id(a2, b_cab)::text, 15, 1) = '3',
    'T2 must be a UUID v3';
  assert position(substr(public.derive_pruning_allocation_id(a2, b_cab)::text, 20, 1) in '89ab') > 0,
    'T2 must use the IETF variant';
  raise notice 'T2 passed: deterministic MD5 v3 allocation id';

  -- ---- T3. One activity, ONE block ----------------------------------------
  r := public.record_pruning_activity(
    p_activity_id => a1,
    p_vineyard_id => v_vy,
    p_activity => jsonb_build_object(
      'entry_date', '2026-07-15', 'worker_or_crew', 'Jon', 'method', 'spur',
      'labour_hours', 6, 'hourly_rate', 35, 'notes', 'Single block day'),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 400,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2),
          jsonb_build_object('row', 41, 'segment', 1),
          jsonb_build_object('row', 41, 'segment', 2)))),
    p_client_updated_at => now());

  assert (r->>'created')::boolean, 'T3 the activity must be created';
  c := r->'canonical';
  assert (c#>>'{totals,allocation_count}')::integer = 1, 'T3 exactly one allocation';
  assert jsonb_array_length(c->'allocations') = 1, 'T3 one allocation in the payload';
  assert (c#>>'{totals,quarters}')::integer = 4, 'T3 four quarters attributed';
  assert (c#>>'{activity,labour_hours}')::numeric = 6, 'T3 activity labour hours';
  assert (c#>>'{activity,hourly_rate}')::numeric = 35, 'T3 activity hourly rate';
  assert (c#>>'{totals,labour_cost}')::numeric = 210, 'T3 labour cost = 6 x 35';
  assert c#>>'{totals,block_summary}' = 'T166 Cab Franc', 'T3 block summary';
  assert (c#>>'{allocations,0,quarters}')::integer = 4, 'T3 allocation quarter count';
  assert (c#>>'{allocations,0,row_equivalents}')::numeric = 1.0, 'T3 4 quarters = 1 row equivalent';
  raise notice 'T3 passed: one activity with one block';

  -- ---- T4. One activity, THREE blocks -------------------------------------
  r := public.record_pruning_activity(
    p_activity_id => a2,
    p_vineyard_id => v_vy,
    p_activity => jsonb_build_object(
      'entry_date', '2026-08-04', 'worker_or_crew', 'Jon', 'method', 'spur',
      'start_time', '2026-08-04T08:00:00+00:00',
      'finish_time', '2026-08-04T15:30:00+00:00',
      'labour_hours', 7.5, 'hourly_rate', 35,
      'notes', 'Finished Cabernet Franc and moved into Sauvignon Blanc'),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'quarters', 12, 'estimated_vines', 900,
        'rows', jsonb_build_array(42, 43, 44)),
      jsonb_build_object('paddock_id', b_sauv, 'quarters', 6, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2),
          jsonb_build_object('row', 66, 'segment', 3),
          jsonb_build_object('row', 67, 'segment', 1),
          jsonb_build_object('row', 67, 'segment', 2),
          jsonb_build_object('row', 67, 'segment', 3))),
      jsonb_build_object('paddock_id', b_pinot, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 5, 'segment', 1)))),
    p_client_updated_at => now());

  c := r->'canonical';
  assert (c#>>'{totals,allocation_count}')::integer = 3, 'T4 three allocations under ONE parent';
  select count(*) into n from public.pruning_activities where id = a2;
  assert n = 1, 'T4 exactly one parent activity row';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null;
  assert n = 3, 'T4 three allocation rows, got ' || n;
  assert c#>>'{totals,block_summary}' like 'T166 Cab Franc + %', 'T4 block summary joins the blocks';
  assert (c#>>'{activity,duration_hours}')::numeric = 7.5, 'T4 duration from start/finish';
  raise notice 'T4 passed: one activity across three blocks';

  -- ---- T5. Labour is stored ONCE ------------------------------------------
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null and labour_hours is not null;
  assert n = 1, 'T5 exactly ONE allocation may mirror labour hours, got ' || n;

  select coalesce(sum(labour_hours), 0) into num from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null;
  assert num = 7.5, 'T5 a legacy sum over allocations must still total 7.5, got ' || num;

  select labour_hours into num from public.pruning_activities where id = a2;
  assert num = 7.5, 'T5 canonical labour lives on the parent';

  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null
    and (start_time is not null or finish_time is not null);
  assert n = 1, 'T5 timing is mirrored on the primary allocation only, got ' || n;

  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null and allocation_index = 0
    and labour_hours is not null;
  assert n = 1, 'T5 the mirror must sit on the PRIMARY allocation';
  raise notice 'T5 passed: labour stored once on the parent, mirrored once for legacy readers';

  -- ---- T6. Totals across allocations --------------------------------------
  -- 12 quarters (3 whole rows) + 6 + 1 = 19
  assert (c#>>'{totals,quarters}')::integer = 19, 'T6 total quarters, got ' || (c#>>'{totals,quarters}');
  assert (c#>>'{totals,row_equivalents}')::numeric = 4.75, 'T6 19/4 row equivalents';
  select sum(estimated_vines_completed) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null;
  assert (c#>>'{totals,estimated_vines}')::integer = n, 'T6 vines roll up from the allocations';
  select total_quarters into n from public.pruning_activities where id = a2;
  assert n = 19, 'T6 the parent roll-up is persisted, got ' || n;
  assert (c#>>'{allocations,0,quarters}')::integer = 12, 'T6 whole-row form expands to 4 quarters per row';
  raise notice 'T6 passed: totals reconcile across allocations';

  -- ---- T7. Season 2026 for every allocation, vintage 2027 ------------------
  select count(distinct s.season_year) into n
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.pruning_activity_id = a2 and e.deleted_at is null;
  assert n = 1, 'T7 every allocation of one activity shares the season YEAR, got ' || n;

  select distinct s.season_year into y
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.pruning_activity_id = a2 and e.deleted_at is null;
  assert y = 2026, 'T7 August 2026 work is season 2026, got ' || y;

  select count(*) into n
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.pruning_activity_id = a2 and e.deleted_at is null
    and s.paddock_id <> e.paddock_id;
  assert n = 0, 'T7 each allocation must own its own block season row';

  select count(distinct e.pruning_season_id) into n from public.pruning_entries e
  where e.pruning_activity_id = a2 and e.deleted_at is null;
  assert n = 3, 'T7 three blocks resolve three distinct 2026 season rows, got ' || n;

  select vintage_year into y from public.pruning_activities where id = a2;
  assert y = 2027, 'T7 vintage stays 2027 for August 2026 work, got ' || y;
  assert y = public.resolve_vineyard_vintage_year(v_vy, date '2026-08-04'),
    'T7 vintage must come from the SQL 119 resolver';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null and vintage_year = 2027;
  assert n = 3, 'T7 every allocation carries vintage 2027, got ' || n;

  -- ...and the same rule for the July activity.
  select season_year, vintage_year into y, n from public.pruning_activities where id = a1;
  assert y = 2026 and n = 2027, 'T7 July 2026 -> season 2026 / vintage 2027';
  raise notice 'T7 passed: season = year(activity date) per allocation, vintage resolved separately';

  -- ---- T8. An invalid block rolls the WHOLE activity back ------------------
  aid := gen_random_uuid();
  ok := false;
  begin
    perform public.record_pruning_activity(
      p_activity_id => aid,
      p_vineyard_id => v_vy,
      p_activity => jsonb_build_object('entry_date', '2026-08-05', 'worker_or_crew', 'Jon',
        'labour_hours', 4),
      p_allocations => jsonb_build_array(
        jsonb_build_object('paddock_id', b_cab,
          'segments', jsonb_build_array(jsonb_build_object('row', 90, 'segment', 1))),
        -- second allocation points at another vineyard's block
        jsonb_build_object('paddock_id', b_alien,
          'segments', jsonb_build_array(jsonb_build_object('row', 1, 'segment', 1)))),
      p_client_updated_at => now());
  exception when others then ok := true;
  end;
  assert ok, 'T8 an invalid block must raise';
  select count(*) into n from public.pruning_activities where id = aid;
  assert n = 0, 'T8 no parent activity may survive a failed allocation, found ' || n;
  select count(*) into n from public.pruning_entries where pruning_activity_id = aid;
  assert n = 0, 'T8 no allocation may survive, found ' || n;
  select count(*) into n from public.pruning_row_segments
  where paddock_id = b_cab and row_number = 90;
  assert n = 0, 'T8 the FIRST allocation''s quarters must roll back too, found ' || n;

  -- An activity with no allocation at all is refused.
  ok := false;
  begin
    perform public.record_pruning_activity(
      p_activity_id => gen_random_uuid(), p_vineyard_id => v_vy,
      p_activity => jsonb_build_object('entry_date', '2026-08-05'),
      p_allocations => '[]'::jsonb, p_client_updated_at => now());
  exception when others then ok := true;
  end;
  assert ok, 'T8 an activity with zero allocations must be refused';
  raise notice 'T8 passed: a failed allocation rolls back the entire activity';

  -- ---- T9. Duplicate rows/quarters are canonicalised ----------------------
  r := public.record_pruning_activity(
    p_activity_id => a5,
    p_vineyard_id => v_vy,
    p_activity => jsonb_build_object('entry_date', '2026-08-06', 'worker_or_crew', 'Jon',
      'labour_hours', 3),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_pinot, 'estimated_vines', 80,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 11, 'segment', 1),
          jsonb_build_object('row', 11, 'segment', 1),   -- exact duplicate
          jsonb_build_object('row', 11, 'segment', 1),   -- and again
          jsonb_build_object('row', 11, 'segment', 2),
          jsonb_build_object('row', 11, 'segment', 9)))),  -- out of range
    p_client_updated_at => now());

  assert (r#>>'{allocation_results,0,requested}')::integer = 2,
    'T9 five raw segments canonicalise to two quarters, got ' || (r#>>'{allocation_results,0,requested}');
  assert (r#>>'{allocation_results,0,duplicates_removed}')::integer = 3,
    'T9 duplicates + the out-of-range quarter are reported';
  assert (r#>>'{allocation_results,0,attributed}')::integer = 2,
    'T9 exactly two quarters attributed';
  select count(*) into n from public.pruning_row_segments s
  join public.pruning_entries e on e.id = s.pruning_entry_id
  where e.pruning_activity_id = a5;
  assert n = 2, 'T9 a quarter can never be stored twice, got ' || n;
  raise notice 'T9 passed: duplicate and invalid quarters canonicalised, never double-counted';

  -- ---- T10. Replay with the same client UUID is idempotent -----------------
  r := public.record_pruning_activity(
    p_activity_id => a2,
    p_vineyard_id => v_vy,
    p_activity => jsonb_build_object(
      'entry_date', '2026-08-04', 'worker_or_crew', 'Jon', 'method', 'spur',
      'labour_hours', 7.5, 'hourly_rate', 35,
      'notes', 'Finished Cabernet Franc and moved into Sauvignon Blanc'),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 900,
        'rows', jsonb_build_array(42, 43, 44)),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2),
          jsonb_build_object('row', 66, 'segment', 3),
          jsonb_build_object('row', 67, 'segment', 1),
          jsonb_build_object('row', 67, 'segment', 2),
          jsonb_build_object('row', 67, 'segment', 3))),
      jsonb_build_object('paddock_id', b_pinot, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 5, 'segment', 1)))),
    p_client_updated_at => now());

  assert (r->>'created')::boolean = false, 'T10 a replay must not report a new activity';
  select count(*) into n from public.pruning_activities where id = a2;
  assert n = 1, 'T10 no duplicate parent, found ' || n;
  select count(*) into n from public.pruning_entries where pruning_activity_id = a2;
  assert n = 3, 'T10 no duplicate allocations, found ' || n;
  select total_quarters into n from public.pruning_activities where id = a2;
  assert n = 19, 'T10 quarters must not be double-counted on replay, got ' || n;
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null and labour_hours is not null;
  assert n = 1, 'T10 a replay must not spread labour across allocations';
  raise notice 'T10 passed: replaying the same client activity UUID is idempotent';

  -- ---- T11. Update ADDS a block -------------------------------------------
  r := public.update_pruning_activity(
    p_activity_id => a1,
    p_activity => jsonb_build_object(
      'entry_date', '2026-07-15', 'worker_or_crew', 'Jon', 'method', 'spur',
      'labour_hours', 6, 'hourly_rate', 35, 'notes', 'Single block day'),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 400,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2),
          jsonb_build_object('row', 41, 'segment', 1),
          jsonb_build_object('row', 41, 'segment', 2))),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 58, 'segment', 1),
          jsonb_build_object('row', 58, 'segment', 2)))),
    p_client_updated_at => now());

  c := r->'canonical';
  assert (c#>>'{totals,allocation_count}')::integer = 2, 'T11 the added block appears';
  assert (c#>>'{totals,quarters}')::integer = 6, 'T11 quarters now 4 + 2';
  assert (c#>>'{activity,labour_hours}')::numeric = 6,
    'T11 adding a block must NOT change the activity labour';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a1 and deleted_at is null and labour_hours is not null;
  assert n = 1, 'T11 labour still stored once, got ' || n;
  select season_year into y from public.pruning_seasons s
  join public.pruning_entries e on e.pruning_season_id = s.id
  where e.pruning_activity_id = a1 and e.paddock_id = b_sauv and e.deleted_at is null;
  assert y = 2026, 'T11 the new allocation resolves the canonical 2026 season';
  raise notice 'T11 passed: update adds a block without touching shared labour';

  -- ---- T12. Update REMOVES one block --------------------------------------
  r := public.update_pruning_activity(
    p_activity_id => a1,
    p_activity => jsonb_build_object(
      'entry_date', '2026-07-15', 'worker_or_crew', 'Jon', 'method', 'spur',
      'labour_hours', 6, 'hourly_rate', 35, 'notes', 'Single block day'),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 58, 'segment', 1),
          jsonb_build_object('row', 58, 'segment', 2)))),
    p_client_updated_at => now());

  c := r->'canonical';
  assert jsonb_array_length(r->'removed_allocations') = 1, 'T12 one allocation removed';
  assert (c#>>'{totals,allocation_count}')::integer = 1, 'T12 one allocation remains';
  select count(*) into n from public.pruning_activities
  where id = a1 and deleted_at is null;
  assert n = 1, 'T12 the PARENT must survive while another allocation remains';
  assert (c#>>'{activity,labour_hours}')::numeric = 6, 'T12 activity labour untouched';

  -- The removed block's quarters are released, not deleted from history.
  select count(*) into n from public.pruning_row_segments
  where paddock_id = b_cab and row_number in (40, 41) and completed = true;
  assert n = 0, 'T12 the removed block''s quarters must be released, found ' || n;

  -- The labour mirror was promoted to the surviving allocation.
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a1 and deleted_at is null and labour_hours = 6;
  assert n = 1, 'T12 the labour mirror must move to the surviving allocation';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a1 and deleted_at is not null;
  assert n = 1, 'T12 the removed allocation is retained as reversed history';
  raise notice 'T12 passed: removing an allocation keeps the parent and promotes the labour mirror';

  -- ---- T13. Date change across a year boundary ----------------------------
  r := public.record_pruning_activity(
    p_activity_id => a3,
    p_vineyard_id => v_vy,
    p_activity => jsonb_build_object('entry_date', '2026-12-31', 'worker_or_crew', 'Jon',
      'labour_hours', 5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 70, 'segment', 1))),
      jsonb_build_object('paddock_id', b_pinot, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 21, 'segment', 1)))),
    p_client_updated_at => now());
  select count(*) into n
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.pruning_activity_id = a3 and e.deleted_at is null and s.season_year = 2026;
  assert n = 2, 'T13 both allocations start in season 2026, got ' || n;

  r := public.update_pruning_activity(
    p_activity_id => a3,
    p_activity => jsonb_build_object('entry_date', '2027-01-04', 'worker_or_crew', 'Jon',
      'labour_hours', 5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 70, 'segment', 1))),
      jsonb_build_object('paddock_id', b_pinot, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 21, 'segment', 1)))),
    p_client_updated_at => now());

  select count(*) into n
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.pruning_activity_id = a3 and e.deleted_at is null and s.season_year = 2027;
  assert n = 2, 'T13 EVERY allocation must move to season 2027, got ' || n;
  select count(*) into n from public.pruning_entries e
  where e.pruning_activity_id = a3 and e.deleted_at is null and e.entry_date = date '2027-01-04';
  assert n = 2, 'T13 every allocation carries the new activity date';
  -- Quarters travelled with their allocation.
  select count(*) into n
  from public.pruning_row_segments g
  join public.pruning_entries e on e.id = g.pruning_entry_id
  where e.pruning_activity_id = a3 and g.pruning_season_id = e.pruning_season_id;
  assert n = 2, 'T13 the quarters must travel with their allocation, got ' || n;
  select season_year into y from public.pruning_activities where id = a3;
  assert y = 2027, 'T13 the parent season year follows the date';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a3 and deleted_at is null and labour_hours is not null;
  assert n = 1, 'T13 a date edit must not spread labour';
  raise notice 'T13 passed: a year-crossing date edit reassigns every allocation';

  -- ---- T14. Labour changes without touching allocations -------------------
  select total_quarters into n from public.pruning_activities where id = a2;
  r := public.update_pruning_activity(
    p_activity_id => a2,
    p_activity => jsonb_build_object(
      'entry_date', '2026-08-04', 'worker_or_crew', 'Jon and Sam', 'method', 'spur',
      'labour_hours', 9.25, 'hourly_rate', 38, 'notes', 'Two on the row'),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 900,
        'rows', jsonb_build_array(42, 43, 44)),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2),
          jsonb_build_object('row', 66, 'segment', 3),
          jsonb_build_object('row', 67, 'segment', 1),
          jsonb_build_object('row', 67, 'segment', 2),
          jsonb_build_object('row', 67, 'segment', 3))),
      jsonb_build_object('paddock_id', b_pinot, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 5, 'segment', 1)))),
    p_client_updated_at => now());
  c := r->'canonical';
  select total_quarters into n2 from public.pruning_activities where id = a2;
  assert n = n2, 'T14 changing labour must not move a single quarter';
  assert (c#>>'{activity,labour_hours}')::numeric = 9.25, 'T14 new labour hours';
  assert (c#>>'{totals,labour_cost}')::numeric = round(9.25 * 38, 2), 'T14 recomputed labour cost';
  select coalesce(sum(labour_hours), 0) into num from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null;
  assert num = 9.25, 'T14 the legacy sum still equals the activity hours, got ' || num;
  raise notice 'T14 passed: labour can change without touching allocations';

  -- ---- T15. Allocations change without duplicating labour -----------------
  r := public.update_pruning_activity(
    p_activity_id => a2,
    p_activity => jsonb_build_object(
      'entry_date', '2026-08-04', 'worker_or_crew', 'Jon and Sam', 'method', 'spur',
      'labour_hours', 9.25, 'hourly_rate', 38, 'notes', 'Two on the row'),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 600,
        'rows', jsonb_build_array(42, 43)),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2))),
      jsonb_build_object('paddock_id', b_pinot, 'estimated_vines', 100,
        'segments', jsonb_build_array(jsonb_build_object('row', 5, 'segment', 1)))),
    p_client_updated_at => now());
  c := r->'canonical';
  assert (c#>>'{totals,quarters}')::integer = 11, 'T15 8 + 2 + 1 quarters, got ' || (c#>>'{totals,quarters}');
  assert (c#>>'{activity,labour_hours}')::numeric = 9.25, 'T15 labour unchanged and not duplicated';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a2 and deleted_at is null and labour_hours is not null;
  assert n = 1, 'T15 still exactly one labour mirror, got ' || n;
  select count(*) into n from public.pruning_row_segments
  where paddock_id = b_cab and row_number = 44 and completed = true;
  assert n = 0, 'T15 quarters dropped from an allocation are released, found ' || n;
  raise notice 'T15 passed: allocations change without duplicating labour';

  -- ---- T16. Reversal affects the FULL activity ----------------------------
  r := public.record_pruning_activity(
    p_activity_id => a4,
    p_vineyard_id => v_vy,
    p_activity => jsonb_build_object('entry_date', '2026-08-10', 'worker_or_crew', 'Jon',
      'labour_hours', 8, 'hourly_rate', 35),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 80, 'segment', 1),
          jsonb_build_object('row', 80, 'segment', 2))),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 200,
        'segments', jsonb_build_array(jsonb_build_object('row', 90, 'segment', 1)))),
    p_client_updated_at => now());

  r := public.reverse_pruning_activity(a4, 'test reversal');
  assert (r->>'allocations_reversed')::integer = 2, 'T16 both allocations reversed';
  assert (r->>'quarters_released')::integer = 3, 'T16 all three quarters released';
  select count(*) into n from public.pruning_activities where id = a4 and deleted_at is not null;
  assert n = 1, 'T16 the parent must be reversed';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = a4 and deleted_at is null;
  assert n = 0, 'T16 every allocation inherits the reversal, live left ' || n;
  select count(*) into n from public.pruning_row_segments
  where paddock_id in (b_cab, b_sauv) and row_number in (80, 90) and completed = true;
  assert n = 0, 'T16 no quarter of a reversed activity may stay completed, found ' || n;
  assert (r#>>'{canonical,activity,is_reversed}')::boolean, 'T16 the canonical payload reports the reversal';
  -- Reversing twice is a harmless no-op.
  r := public.reverse_pruning_activity(a4);
  assert (r->>'already_reversed')::boolean, 'T16 a second reversal is idempotent';
  raise notice 'T16 passed: reversal is one operation over the whole activity';

  -- ---- T17. Reversed activities are uneditable; stale edits ignored --------
  r := public.update_pruning_activity(
    p_activity_id => a4,
    p_activity => jsonb_build_object('entry_date', '2026-08-11', 'labour_hours', 1),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab,
        'segments', jsonb_build_array(jsonb_build_object('row', 80, 'segment', 1)))),
    p_client_updated_at => now());
  assert r->>'error' = 'activity_reversed', 'T17 a reversed activity must not be editable';

  r := public.update_pruning_activity(
    p_activity_id => a3,
    p_activity => jsonb_build_object('entry_date', '2027-01-05', 'labour_hours', 99),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab,
        'segments', jsonb_build_array(jsonb_build_object('row', 70, 'segment', 1)))),
    p_client_updated_at => now() - interval '2 days');
  assert (r->>'stale')::boolean, 'T17 an edit older than the stored stamp must be skipped';
  select labour_hours into num from public.pruning_activities where id = a3;
  assert num = 5, 'T17 a stale edit must not change stored labour, got ' || num;

  r := public.update_pruning_activity(
    p_activity_id => gen_random_uuid(),
    p_activity => jsonb_build_object('entry_date', '2026-08-01'),
    p_allocations => jsonb_build_array(jsonb_build_object('paddock_id', b_cab)),
    p_client_updated_at => now());
  assert r->>'error' = 'activity_not_found', 'T17 a missing activity reports a structured error';
  raise notice 'T17 passed: reversed / stale / missing edits handled without exceptions';

  -- ---- T18. Legacy record_pruning_entry still works -----------------------
  r := public.record_pruning_entry(
    p_id => e_leg, p_vineyard_id => v_vy,
    p_season_id => public.derive_pruning_season_id(v_vy, b_pinot, 2027),
    p_paddock_id => b_pinot, p_season_year => 2027, p_entry_date => date '2026-08-02',
    p_worker => 'Legacy build', p_labour_hours => 8,
    p_segments => '[{"row":31,"segment":1},{"row":31,"segment":2}]'::jsonb);
  assert (r->>'season_year')::integer = 2026, 'T18 SQL 161 season rule still applies';

  select pruning_activity_id, allocation_index into aid, n
  from public.pruning_entries where id = e_leg;
  assert aid = e_leg, 'T18 a legacy entry owns an activity keyed by its own id';
  assert n = 0, 'T18 a legacy entry is the primary allocation';

  c := public.get_pruning_activity(e_leg);
  assert (c#>>'{totals,allocation_count}')::integer = 1,
    'T18 a legacy one-block submission reads as a one-allocation activity';
  assert (c#>>'{activity,labour_hours}')::numeric = 8, 'T18 legacy labour is on the parent';
  assert (c#>>'{totals,quarters}')::integer = 2, 'T18 legacy quarters roll up';
  assert c#>>'{allocations,0,paddock_id}' = b_pinot::text, 'T18 the allocation keeps its block';
  select season_year into y from public.pruning_activities where id = e_leg;
  assert y = 2026, 'T18 the parent adopts the canonical season year';
  raise notice 'T18 passed: record_pruning_entry unchanged, now yields a one-allocation activity';

  -- ---- T19. Legacy update_pruning_entry still works -----------------------
  r := public.update_pruning_entry(
    p_entry_id => e_leg, p_entry_date => date '2026-08-03', p_worker => 'Legacy build',
    p_labour_hours => 8.5,
    p_segments => '[{"row":31,"segment":1},{"row":31,"segment":2},{"row":32,"segment":1}]'::jsonb,
    p_client_updated_at => now());
  assert (r->>'attributed')::integer = 3, 'T19 the legacy edit attributed three quarters';
  select labour_hours into num from public.pruning_activities where id = e_leg;
  assert num = 8.5, 'T19 the parent mirrors the edited labour, got ' || num;
  select total_quarters into n from public.pruning_activities where id = e_leg;
  assert n = 3, 'T19 the parent roll-up follows the legacy edit, got ' || n;
  select count(*) into n from public.pruning_activities
  where id = e_leg and entry_date = date '2026-08-03';
  assert n = 1, 'T19 the parent mirrors the edited date';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and deleted_at is null;
  assert n = 1, 'T19 a legacy edit must never split the entry into more allocations';
  raise notice 'T19 passed: update_pruning_entry unchanged, parent stays in step';

  -- ---- T20. Legacy delete_pruning_entry reverses the parent ---------------
  perform public.delete_pruning_entry(e_leg);
  select count(*) into n from public.pruning_activities where id = e_leg and deleted_at is not null;
  assert n = 1, 'T20 reversing the only allocation reverses the parent';
  select labour_hours into num from public.pruning_activities where id = e_leg;
  assert num = 8.5, 'T20 a reversal must not wipe the recorded labour, got ' || coalesce(num::text, 'null');
  select allocation_count into n from public.pruning_activities where id = e_leg;
  assert n = 0, 'T20 no live allocation remains';
  raise notice 'T20 passed: legacy reversal reverses the parent activity';

  -- ---- T21. A historic entry is readable as a one-allocation activity ------
  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    labour_hours, pruning_method, notes, row_equivalents_completed,
    estimated_vines_completed, vintage_year, created_by, created_at, updated_at
  ) values (
    e_hist, v_vy,
    public.resolve_pruning_season(v_vy, b_sauv, date '2025-07-20', null, now()),
    b_sauv, date '2025-07-20', 'Historic crew', 4, 'cane', 'imported', 0.5, 120,
    2026, u_mgr, now() - interval '400 days', now() - interval '400 days'
  );

  c := public.get_pruning_activity(e_hist);
  assert c is not null, 'T21 a historic entry must expose a parent activity';
  assert (c#>>'{totals,allocation_count}')::integer = 1, 'T21 exactly one allocation';
  assert (c#>>'{activity,entry_date}') = '2025-07-20', 'T21 the date is preserved';
  assert (c#>>'{activity,labour_hours}')::numeric = 4, 'T21 labour preserved';
  assert (c#>>'{activity,method}') = 'cane', 'T21 method preserved';
  assert (c#>>'{activity,vintage_year}')::integer = 2026, 'T21 vintage preserved, not recomputed';
  assert (c#>>'{activity,season_year}')::integer = 2025, 'T21 season year of the work';
  assert (c#>>'{allocations,0,estimated_vines}')::integer = 120, 'T21 vines preserved';
  assert (c#>>'{allocations,0,row_equivalents}')::numeric = 0.5, 'T21 row equivalents preserved';
  -- The historic entry itself is untouched.
  select count(*) into n from public.pruning_entries
  where id = e_hist and entry_date = date '2025-07-20' and labour_hours = 4
    and paddock_id = b_sauv and vintage_year = 2026 and created_by = u_mgr;
  assert n = 1, 'T21 the historic entry row must be byte-identical';
  raise notice 'T21 passed: historic single-block entries read as one-allocation activities';

  -- ---- T22. Export breakdown counts shared labour once --------------------
  select count(*) into n from public.pruning_activity_allocation_export
  where activity_id = a2;
  assert n = 3, 'T22 one export row per allocation, got ' || n;
  select count(*) into n from public.pruning_activity_allocation_export
  where activity_id = a2 and activity_labour_hours is not null;
  assert n = 1, 'T22 activity labour appears on exactly ONE export row, got ' || n;
  select coalesce(sum(activity_labour_hours), 0) into num
  from public.pruning_activity_allocation_export where activity_id = a2;
  assert num = 9.25, 'T22 summing the export must total the activity hours once, got ' || num;
  select coalesce(sum(allocation_share_of_row_equivalents), 0) into num
  from public.pruning_activity_allocation_export
  where activity_id = a2 and status = 'active';
  assert abs(num - 1) < 0.0001, 'T22 the informational shares must sum to 1, got ' || num;
  select count(*) into n from public.pruning_activity_allocation_export
  where activity_id = a4 and status = 'reversed';
  assert n = 2, 'T22 reversed activities stay visible for audit, got ' || n;
  raise notice 'T22 passed: allocation export never double-counts shared labour';

  -- ---- T23. Non-members and anonymous callers rejected --------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    perform public.record_pruning_activity(
      p_activity_id => gen_random_uuid(), p_vineyard_id => v_vy,
      p_activity => jsonb_build_object('entry_date', '2026-08-04'),
      p_allocations => jsonb_build_array(jsonb_build_object('paddock_id', b_cab)),
      p_client_updated_at => now());
  exception when others then ok := true;
  end;
  assert ok, 'T23 a non-member must not record an activity';

  ok := false;
  begin
    perform public.reverse_pruning_activity(a2);
  exception when others then ok := true;
  end;
  assert ok, 'T23 a non-member must not reverse an activity';

  ok := false;
  begin
    perform public.list_pruning_activities(v_vy);
  exception when others then ok := true;
  end;
  assert ok, 'T23 a non-member must not list another vineyard''s activities';

  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    perform public.get_pruning_activity(a2);
  exception when others then ok := true;
  end;
  assert ok, 'T23 an anonymous caller must be rejected';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  raise notice 'T23 passed: non-member and anonymous callers rejected';

  -- ---- Cross-cutting invariants ------------------------------------------
  select count(*) into n from public.pruning_entries
  where vineyard_id = v_vy and pruning_activity_id is null;
  assert n = 0, 'INV every entry must have a parent activity, offenders ' || n;

  select count(*) into n from (
    select pruning_activity_id from public.pruning_entries
    where deleted_at is null and labour_hours is not null
    group by pruning_activity_id having count(*) > 1
  ) t;
  assert n = 0, 'INV labour may never be mirrored on two live allocations, offenders ' || n;

  select count(*) into n
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.vineyard_id = v_vy
    and extract(year from e.entry_date)::integer <> s.season_year;
  assert n = 0, 'INV season_year must equal year(entry_date) everywhere, offenders ' || n;

  select count(*) into n
  from public.pruning_activities a
  join public.pruning_entries e on e.pruning_activity_id = a.id
  where a.vineyard_id = v_vy and e.deleted_at is null
    and e.entry_date is distinct from a.entry_date;
  assert n = 0, 'INV every live allocation shares the activity date, offenders ' || n;

  select count(*) into n from public.list_pruning_activities(v_vy) t;
  assert n = 1, 'INV list_pruning_activities returns one jsonb array';
  assert jsonb_array_length(public.list_pruning_activities(v_vy)) >= 6,
    'INV the vineyard feed lists every activity';

  raise notice 'SQL 166 pruning activity tests: ALL PASSED';
end$$;

rollback;

-- T24. Post-rollback proof: nothing survived.
select
  (select count(*) from auth.users where email like 't166-%@test.local')       as leftover_users,
  (select count(*) from public.vineyards where name like 'T166 %')             as leftover_vineyards,
  (select count(*) from public.paddocks where name like 'T166 %')              as leftover_paddocks,
  (select count(*) from public.pruning_activities
    where worker_or_crew in ('Jon','Jon and Sam','Legacy build','Historic crew')) as leftover_activities;
