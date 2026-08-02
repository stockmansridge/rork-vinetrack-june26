-- =====================================================================
-- 161_pruning_season_canonical_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/161_pruning_season_canonical_assignment.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production pruning row is created, changed or deleted.
--
-- Test map
--   T1  Functions exist with the expected signatures, security + grants
--   T2  derive_pruning_season_id is deterministic and MD5 v3 shaped
--   T3  Aug-2026 entry -> season_year 2026 (never the vintage 2027)
--   T4  ...and vintage_year 2027 on the same entry (1 July season start)
--   T5  A client season id belonging to ANOTHER year is ignored
--   T6  Two blocks recorded on the SAME DAY share one season year
--   T7  A wrong client p_season_year is ignored, not stored
--   T8  December-2026 entry -> season 2026
--   T9  Backdated entry (Dec 2026 recorded in 2027) -> season 2026
--   T10 Offline replay is idempotent and does not move the stored season
--   T11 Edit within the same year keeps the season
--   T12 Edit across a year boundary re-points season AND quarters
--   T13 Reversed entry cannot be edited (contract unchanged)
--   T14 The canonical season row is created once, never duplicated
--   T15 Soft-deleted canonical season is resurrected, not duplicated
--   T16 Non-members and anonymous callers are rejected
--   T17 No entry in the fixture ends up with season_year <> year(date)
--   T18 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 161 pruning season canonical tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 161 is applied.
do $$
begin
  if to_regprocedure('public.derive_pruning_season_id(uuid, uuid, integer)') is null
     or to_regprocedure('public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)') is null then
    raise exception 'SQL 161 not applied — run sql/161_pruning_season_canonical_assignment.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr    uuid;
  u_out    uuid;   -- member of another vineyard only
  v_vy     uuid := gen_random_uuid();
  v_vy2    uuid := gen_random_uuid();
  b_sauv   uuid := gen_random_uuid();
  b_pinot  uuid := gen_random_uuid();
  s_2026   uuid;
  s_2027   uuid;
  e1       uuid := gen_random_uuid();
  e2       uuid := gen_random_uuid();
  e3       uuid := gen_random_uuid();
  e4       uuid := gen_random_uuid();
  e5       uuid := gen_random_uuid();
  r        jsonb;
  n        integer;
  y        integer;
  sid      uuid;
  sid2     uuid;
  ok       boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t161-mgr@test.local','t161-out@test.local']) e;
  select id into u_mgr from auth.users where email = 't161-mgr@test.local';
  select id into u_out from auth.users where email = 't161-out@test.local';

  insert into public.profiles (id, email)
  select u, 't161-' || u::text || '@test.local' from unnest(array[u_mgr, u_out]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T161 Season Rule Vineyard'),
    (v_vy2, 'T161 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy2, u_out, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_sauv,  v_vy, 'T161 Sauvignon Blanc'),
    (b_pinot, v_vy, 'T161 Pinot Noir');

  -- Act as the manager for everything below.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);

  -- ---- T1. Signatures, security definer, fixed search_path, grants -------
  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('derive_pruning_season_id','resolve_pruning_season',
                      'record_pruning_entry','update_pruning_entry');
  assert n >= 4, 'T1 all four functions must exist, found ' || n;

  select p.prosecdef into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'resolve_pruning_season';
  assert ok, 'T1 resolve_pruning_season must be security definer';

  select coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=public%' into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'resolve_pruning_season';
  assert ok, 'T1 resolve_pruning_season must pin search_path';

  assert not has_function_privilege('anon',
    'public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)', 'execute'),
    'T1 anon must NOT execute resolve_pruning_season';
  assert has_function_privilege('authenticated',
    'public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)', 'execute'),
    'T1 authenticated must execute resolve_pruning_season';
  raise notice 'T1 passed: signatures, security definer, fixed search_path, grants';

  -- ---- T2. Deterministic id ----------------------------------------------
  sid  := public.derive_pruning_season_id(v_vy, b_sauv, 2026);
  sid2 := public.derive_pruning_season_id(v_vy, b_sauv, 2026);
  assert sid = sid2, 'T2 derivation must be deterministic';
  assert sid <> public.derive_pruning_season_id(v_vy, b_sauv, 2027),
    'T2 a different year must derive a different id';
  assert substr(sid::text, 15, 1) = '3', 'T2 must be a UUID v3';
  assert position(substr(sid::text, 20, 1) in '89ab') > 0, 'T2 must use the IETF variant';
  raise notice 'T2 passed: deterministic MD5 v3 season id';

  -- ---- T3/T4. August 2026 -> season 2026, vintage 2027 --------------------
  r := public.record_pruning_entry(
    p_id => e1, p_vineyard_id => v_vy, p_season_id => public.derive_pruning_season_id(v_vy, b_sauv, 2027),
    p_paddock_id => b_sauv, p_season_year => 2027, p_entry_date => date '2026-08-02',
    p_worker => 'T161 crew', p_labour_hours => 8, p_segments =>
      '[{"row":1,"segment":1},{"row":1,"segment":2}]'::jsonb);
  assert (r->>'season_year')::integer = 2026,
    'T3 August 2026 work must be season 2026, got ' || coalesce(r->>'season_year','null');
  select s.season_year into y
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.id = e1;
  assert y = 2026, 'T3 stored season row must be 2026, got ' || y;
  raise notice 'T3 passed: 2 Aug 2026 -> season 2026 even when the client says 2027';

  select vintage_year into y from public.pruning_entries where id = e1;
  assert y = public.resolve_vineyard_vintage_year(v_vy, date '2026-08-02'),
    'T4 vintage must come from the SQL 119 resolver';
  raise notice 'T4 passed: vintage resolved independently of the season year (got %)', y;

  -- ---- T5. A client id from another year is ignored -----------------------
  s_2026 := public.derive_pruning_season_id(v_vy, b_sauv, 2026);
  assert (r->>'season_id')::uuid = s_2026, 'T5 canonical 2026 id must be used';
  assert (r->>'season_corrected')::boolean, 'T5 the correction must be reported to the client';
  select count(*) into n from public.pruning_seasons
  where vineyard_id = v_vy and paddock_id = b_sauv and season_year = 2027 and deleted_at is null;
  assert n = 0, 'T5 no 2027 season row may be created for August 2026 work';
  raise notice 'T5 passed: a wrong-year season id is ignored, never followed';

  -- ---- T6. Same-day entries on two blocks share the season year -----------
  r := public.record_pruning_entry(
    p_id => e2, p_vineyard_id => v_vy, p_season_id => gen_random_uuid(),
    p_paddock_id => b_pinot, p_season_year => null, p_entry_date => date '2026-08-02',
    p_worker => 'T161 crew', p_segments => '[{"row":1,"segment":1}]'::jsonb);
  assert (r->>'season_year')::integer = 2026, 'T6 second block must also be season 2026';
  select count(distinct s.season_year) into n
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.vineyard_id = v_vy and e.entry_date = date '2026-08-02';
  assert n = 1, 'T6 same-date entries must never split across season years, got ' || n;
  raise notice 'T6 passed: both blocks recorded on 2 Aug 2026 sit in season 2026';

  -- ---- T7. A wrong p_season_year is ignored, not stored --------------------
  assert (r->>'season_year_requested') is null, 'T7 the requested value is echoed for diagnostics';
  select count(*) into n from public.pruning_seasons
  where vineyard_id = v_vy and season_year <> 2026 and deleted_at is null;
  assert n = 0, 'T7 no season row with a non-2026 year may exist yet, found ' || n;
  raise notice 'T7 passed: client season-year hints never reach the stored row';

  -- ---- T8. December 2026 -> season 2026 ------------------------------------
  r := public.record_pruning_entry(
    p_id => e3, p_vineyard_id => v_vy, p_season_id => s_2026,
    p_paddock_id => b_sauv, p_season_year => 2026, p_entry_date => date '2026-12-20',
    p_worker => 'T161 crew', p_segments => '[{"row":2,"segment":1}]'::jsonb);
  assert (r->>'season_year')::integer = 2026, 'T8 December 2026 is still season 2026';
  raise notice 'T8 passed: December 2026 -> season 2026';

  -- ---- T9. Backdated entry recorded in the following year ------------------
  -- The device says "current year 2027" (the old iOS rule); the work happened
  -- in December 2026 and must land in season 2026.
  r := public.record_pruning_entry(
    p_id => e4, p_vineyard_id => v_vy, p_season_id => public.derive_pruning_season_id(v_vy, b_pinot, 2027),
    p_paddock_id => b_pinot, p_season_year => 2027, p_entry_date => date '2026-12-31',
    p_worker => 'T161 crew', p_segments => '[{"row":3,"segment":1}]'::jsonb);
  assert (r->>'season_year')::integer = 2026, 'T9 backdated work must use the work year';
  raise notice 'T9 passed: a sync-time device year cannot override the entry date';

  -- ---- T10. Replay is idempotent and never moves the stored season --------
  select pruning_season_id into sid from public.pruning_entries where id = e1;
  r := public.record_pruning_entry(
    p_id => e1, p_vineyard_id => v_vy, p_season_id => s_2026,
    p_paddock_id => b_sauv, p_season_year => 2026, p_entry_date => date '2026-08-02',
    p_worker => 'T161 crew', p_labour_hours => 8, p_segments =>
      '[{"row":1,"segment":1},{"row":1,"segment":2}]'::jsonb);
  select pruning_season_id into sid2 from public.pruning_entries where id = e1;
  assert sid = sid2, 'T10 a replay must not move a stored entry';
  select count(*) into n from public.pruning_row_segments where pruning_entry_id = e1;
  assert n = 2, 'T10 replay must not duplicate quarters, got ' || n;
  select count(*) into n from public.pruning_entries where id = e1;
  assert n = 1, 'T10 replay must not duplicate the entry';
  raise notice 'T10 passed: replay idempotent, stored season untouched';

  -- ---- T11. Edit inside the same year keeps the season ---------------------
  r := public.update_pruning_entry(
    p_entry_id => e1, p_entry_date => date '2026-08-05', p_worker => 'T161 crew',
    p_labour_hours => 9, p_segments => '[{"row":1,"segment":1},{"row":1,"segment":2}]'::jsonb,
    p_client_updated_at => now());
  assert (r->>'season_changed')::boolean = false, 'T11 same-year edit must not move the season';
  assert (r->>'season_year')::integer = 2026, 'T11 season year stays 2026';
  raise notice 'T11 passed: same-year date edit keeps the season';

  -- ---- T12. Edit across the year boundary re-points season and quarters ----
  r := public.update_pruning_entry(
    p_entry_id => e4, p_entry_date => date '2027-01-04', p_worker => 'T161 crew',
    p_segments => '[{"row":3,"segment":1}]'::jsonb, p_client_updated_at => now());
  assert (r->>'season_changed')::boolean, 'T12 a year-crossing edit must re-point the season';
  assert (r->>'season_year')::integer = 2027, 'T12 the entry now belongs to season 2027';
  select s.season_year into y
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.id = e4;
  assert y = 2027, 'T12 stored season row must be 2027';
  select count(*) into n
  from public.pruning_row_segments g
  join public.pruning_entries e on e.id = g.pruning_entry_id
  where g.pruning_entry_id = e4 and g.pruning_season_id = e.pruning_season_id;
  assert n = 1, 'T12 the entry quarters must travel with it, got ' || n;
  assert (r->>'attributed')::integer = 1, 'T12 attribution preserved across the move';
  raise notice 'T12 passed: year-crossing edit moves the entry and its quarters';

  -- ---- T13. Reversed entries stay uneditable -------------------------------
  perform public.delete_pruning_entry(e3);
  r := public.update_pruning_entry(
    p_entry_id => e3, p_entry_date => date '2026-12-21', p_worker => 'T161 crew',
    p_segments => '[]'::jsonb, p_client_updated_at => now());
  assert r->>'error' = 'entry_reversed', 'T13 a reversed entry must not be editable';
  raise notice 'T13 passed: reversed entries remain read-only';

  -- ---- T14. One canonical season row per block and year --------------------
  select count(*) into n from public.pruning_seasons
  where vineyard_id = v_vy and paddock_id = b_sauv and season_year = 2026 and deleted_at is null;
  assert n = 1, 'T14 exactly one live 2026 season for the block, found ' || n;
  select count(*) into n from public.pruning_seasons
  where vineyard_id = v_vy and paddock_id = b_pinot and deleted_at is null;
  assert n = 2, 'T14 Pinot has exactly a 2026 and a 2027 season row, found ' || n;
  raise notice 'T14 passed: no duplicate season rows';

  -- ---- T15. A soft-deleted canonical row is resurrected --------------------
  update public.pruning_seasons set deleted_at = now()
  where vineyard_id = v_vy and paddock_id = b_sauv and season_year = 2026;
  sid := public.resolve_pruning_season(v_vy, b_sauv, date '2026-08-11', null, now());
  assert sid = s_2026, 'T15 the deterministic row must be resurrected, not replaced';
  select count(*) into n from public.pruning_seasons
  where vineyard_id = v_vy and paddock_id = b_sauv and season_year = 2026 and deleted_at is null;
  assert n = 1, 'T15 still exactly one live 2026 row, found ' || n;
  raise notice 'T15 passed: soft-deleted season resurrected in place';

  -- ---- T16. Non-members and anonymous callers rejected ---------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    perform public.resolve_pruning_season(v_vy, b_sauv, date '2026-08-02', null, now());
  exception when others then ok := true;
  end;
  assert ok, 'T16 a non-member must not resolve or create a season';

  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    perform public.resolve_pruning_season(v_vy, b_sauv, date '2026-08-02', null, now());
  exception when others then ok := true;
  end;
  assert ok, 'T16 an anonymous caller must be rejected';
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  raise notice 'T16 passed: non-member and anonymous callers rejected';

  -- ---- T17. Invariant across every fixture entry ---------------------------
  select count(*) into n
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.vineyard_id = v_vy
    and extract(year from e.entry_date)::integer <> s.season_year;
  assert n = 0, 'T17 every entry must sit in the season of its own work year, offenders ' || n;
  raise notice 'T17 passed: season_year = year(entry_date) for every fixture entry';

  raise notice 'SQL 161 pruning season canonical tests: ALL PASSED';
end$$;

rollback;

-- T18. Post-rollback proof: nothing survived.
select
  (select count(*) from auth.users where email like 't161-%@test.local')      as leftover_users,
  (select count(*) from public.vineyards where name like 'T161 %')            as leftover_vineyards,
  (select count(*) from public.paddocks where name like 'T161 %')             as leftover_paddocks;
