-- =====================================================================
-- 185_sync_stale_write_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/185_sync_stale_write_protection.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map (conflict order = the audit scenario: Device A edits offline,
-- Device B saves newer, Device A reconnects later — B must win)
--   T1  Objects: guard function + three triggers exist
--   T2  pruning_seasons — stale replay is skipped, newer value survives
--   T3  pruning_seasons — a genuinely newer write still applies
--   T4  pruning_yield_settings — stale replay is skipped, newer survives
--   T5  pruning_yield_settings — equal timestamp (idempotent re-send) applies
--   T6  Writes that don't carry client_updated_at are unaffected
--       (server-side status/archive updates keep working)
--   T7  picking_records — created_by preserved on edit, updated_by mirrors
--       the editor; INSERT defaults created_by to auth.uid()
--   T8  All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 185 sync stale-write tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 185 is applied.
do $$
begin
  if to_regprocedure('public.reject_stale_client_write()') is null
     or to_regprocedure('public.picking_records_attribution_guard()') is null then
    raise exception 'SQL 185 not applied — run sql/185_sync_stale_write_protection.sql first.';
  end if;
end$$;

do $$
declare
  u_a   uuid;                              -- Device A user (original author)
  u_b   uuid;                              -- Device B user (later editor)
  v_vy  uuid := gen_random_uuid();
  b_a   uuid := gen_random_uuid();
  s_id  uuid := gen_random_uuid();         -- pruning season row
  y_id  uuid := gen_random_uuid();         -- yield settings row
  p_id  uuid := gen_random_uuid();         -- picking record row
  t1    timestamptz := now() - interval '3 hours';  -- A's offline edit time
  t2    timestamptz := now() - interval '1 hour';   -- B's newer edit time
  r     record;
  n     integer;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t185-a@test.local','t185-b@test.local']) e;
  select id into u_a from auth.users where email = 't185-a@test.local';
  select id into u_b from auth.users where email = 't185-b@test.local';

  insert into public.profiles (id, email)
  select u, 't185-' || u::text || '@test.local' from unnest(array[u_a, u_b]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v_vy, 'T185 Stale-Write Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy, u_a, 'manager'),
    (v_vy, u_b, 'manager');

  -- ---- T1. Objects --------------------------------------------------------
  select count(*) into n from pg_trigger
  where tgname in ('pruning_seasons_stale_write_guard',
                   'pruning_yield_settings_stale_write_guard',
                   'picking_records_attribution_guard');
  if n <> 3 then raise exception 'T1: expected 3 guard triggers, found %', n; end if;
  raise notice 'T1 passed';

  -- ---- T2. pruning_seasons: stale replay skipped --------------------------
  -- Baseline row (Device A's original save).
  insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year, assigned_crew, created_by, client_updated_at)
  values (s_id, v_vy, b_a, 2026, 'Crew A original', u_a, t1);

  -- Step 2: Device B saves a NEWER change (T2 > T1).
  update public.pruning_seasons
     set assigned_crew = 'Crew B newer', client_updated_at = t2
   where id = s_id;
  select assigned_crew into r from public.pruning_seasons where id = s_id;
  if r.assigned_crew <> 'Crew B newer' then raise exception 'T2: newer write did not apply'; end if;

  -- Step 3: Device A reconnects and replays its OLDER edit (T1 < T2).
  update public.pruning_seasons
     set assigned_crew = 'Crew A stale replay', client_updated_at = t1
   where id = s_id;

  -- Step 4: Device B's newer value must remain authoritative.
  select assigned_crew, client_updated_at into r from public.pruning_seasons where id = s_id;
  if r.assigned_crew <> 'Crew B newer' then
    raise exception 'T2: stale replay overwrote the newer edit (got %)', r.assigned_crew;
  end if;
  if r.client_updated_at <> t2 then
    raise exception 'T2: client_updated_at regressed to the stale time';
  end if;
  raise notice 'T2 passed';

  -- ---- T3. pruning_seasons: genuinely newer write still applies -----------
  update public.pruning_seasons
     set assigned_crew = 'Crew B even newer', client_updated_at = t2 + interval '5 minutes'
   where id = s_id;
  select assigned_crew into r from public.pruning_seasons where id = s_id;
  if r.assigned_crew <> 'Crew B even newer' then raise exception 'T3: newer write was wrongly skipped'; end if;
  raise notice 'T3 passed';

  -- ---- T4. pruning_yield_settings: stale replay skipped -------------------
  insert into public.pruning_yield_settings (id, vineyard_id, paddock_id, prune_method, bunches_per_bud, created_by, client_updated_at)
  values (y_id, v_vy, b_a, 'spur', 1.5, u_a, t1);

  update public.pruning_yield_settings
     set bunches_per_bud = 2.0, client_updated_at = t2
   where id = y_id;

  -- Device A's stale replay (T1 < T2) must be skipped.
  update public.pruning_yield_settings
     set bunches_per_bud = 9.9, client_updated_at = t1
   where id = y_id;
  select bunches_per_bud into r from public.pruning_yield_settings where id = y_id;
  if r.bunches_per_bud <> 2.0 then
    raise exception 'T4: stale replay overwrote the newer settings (got %)', r.bunches_per_bud;
  end if;
  raise notice 'T4 passed';

  -- ---- T5. Equal timestamp (idempotent re-send) applies -------------------
  update public.pruning_yield_settings
     set bunches_per_bud = 2.5, client_updated_at = t2
   where id = y_id;
  select bunches_per_bud into r from public.pruning_yield_settings where id = y_id;
  if r.bunches_per_bud <> 2.5 then raise exception 'T5: equal-timestamp re-send was wrongly skipped'; end if;
  raise notice 'T5 passed';

  -- ---- T6. Writes without client_updated_at are unaffected ----------------
  -- Server-side/portal status changes never carry client_updated_at
  -- (new = old → never stale). Archive must still work.
  update public.pruning_seasons set status = 'archived' where id = s_id;
  select status into r from public.pruning_seasons where id = s_id;
  if r.status <> 'archived' then raise exception 'T6: status-only update was blocked'; end if;
  raise notice 'T6 passed';

  -- ---- T7. picking_records attribution guard ------------------------------
  -- INSERT as Device A: created_by defaults from auth.uid() when omitted.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  insert into public.picking_records (id, vineyard_id, picked_at, paddock_id, paddock_name, variety_name, weight_kg)
  values (p_id, v_vy, '2027-02-10', b_a, 'T185 Block', 'Pinot Noir', 1000);
  select created_by, updated_by into r from public.picking_records where id = p_id;
  if r.created_by <> u_a then raise exception 'T7: INSERT did not default created_by to auth.uid()'; end if;

  -- EDIT as Device B, maliciously/accidentally sending created_by = u_b
  -- (exactly what the old iOS upsert did): original attribution must survive,
  -- updated_by must reflect the editor.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_b::text, 'role', 'authenticated')::text, true);
  update public.picking_records
     set weight_kg = 1200, created_by = u_b, client_updated_at = now()
   where id = p_id;
  select created_by, updated_by, weight_kg into r from public.picking_records where id = p_id;
  if r.created_by <> u_a then
    raise exception 'T7: edit overwrote created_by (got %, expected original author %)', r.created_by, u_a;
  end if;
  if r.updated_by <> u_b then
    raise exception 'T7: updated_by does not reflect the editor';
  end if;
  if r.weight_kg <> 1200 then raise exception 'T7: legitimate edit did not apply'; end if;
  perform set_config('request.jwt.claims', null, true);
  raise notice 'T7 passed';

  raise notice 'SQL 185 sync stale-write tests: ALL PASSED';
end$$;

-- ---- T8. Discard every fixture -------------------------------------------
rollback;
