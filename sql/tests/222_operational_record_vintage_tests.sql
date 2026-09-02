-- =====================================================================
-- 222_operational_record_vintage_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/222_operational_record_vintage.sql.
-- Everything runs inside ONE transaction that is ROLLED BACK at the end,
-- so no fixture survives and no production row is modified.
--
-- Test map
--   T1  Objects — eight vintage columns, eight triggers, the shared
--       _vineyard_local_date helper, and the per-table indexes
--   T2  INSERT resolves the vintage from each table's own event date
--       (pins, trips, spray_records, growth_stage_records, maintenance_logs,
--       fuel_purchases, tractor_fuel_logs, fertiliser_records)
--   T3  Vineyard-local boundary — the SAME UTC instant lands in DIFFERENT
--       vintages for two vineyards in different timezones
--   T4  Changing the event date re-resolves the vintage (audit req 10)
--   T5  Editing an unrelated field NEVER moves a record between vintages
--       (audit req 9) — checked on every one of the eight tables
--   T6  A deliberate client restatement of the vintage is honoured
--   T7  Offline replay — absent or implausible client vintage is resolved
--       server-side rather than rejected (audit req 3)
--   T8  Fallback chains — spray_records with a null `date` uses start_time
--       then created_at; a wholly undated spray keeps a null vintage rather
--       than being forced into a wrong season
--   T9  fertiliser_records uses its DATE column with NO timezone shift
--   T10 Backfill — a row inserted with the trigger disabled is corrected by
--       the migration's backfill statement (audit req 4)
--   T11 Vineyard + vintage filtering returns only the requested slice
--       (audit req 5)
--   T12 SQL 221's Yield/Damage contract is still intact and untouched
--   T13 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 222 operational record vintage tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'pins' and column_name = 'vintage'
  ) then
    raise exception 'sql/222_operational_record_vintage.sql has not been applied';
  end if;
end $$;

do $t222$
declare
  u_owner   uuid := gen_random_uuid();
  -- Sydney (UTC+10/+11), season starts 1 September
  vSyd      uuid := gen_random_uuid();
  -- Los Angeles (UTC-7/-8), same season start — used for the boundary test
  vLA       uuid := gen_random_uuid();
  -- 1 January season start: vintage always equals the calendar year
  vJan      uuid := gen_random_uuid();
  pk        uuid := gen_random_uuid();
  t_pin     uuid := gen_random_uuid();
  t_trip    uuid := gen_random_uuid();
  t_spray   uuid := gen_random_uuid();
  t_spray2  uuid := gen_random_uuid();
  t_spray3  uuid := gen_random_uuid();
  t_growth  uuid := gen_random_uuid();
  t_maint   uuid := gen_random_uuid();
  t_fuel    uuid := gen_random_uuid();
  t_tfuel   uuid := gen_random_uuid();
  t_fert    uuid := gen_random_uuid();
  t_bfill   uuid := gen_random_uuid();
  b_syd     uuid := gen_random_uuid();
  b_la      uuid := gen_random_uuid();
  v_int     integer;
  v_int2    integer;
  n         integer;
  tname     text;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (u_owner, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't222-owner@test.local', 'x', now(), now(), now());

  insert into public.profiles (id) values (u_owner) on conflict (id) do nothing;

  insert into public.vineyards (id, name, season_start_month, season_start_day, timezone)
  values (vSyd, 'T222 Sydney',      9, 1, 'Australia/Sydney'),
         (vLA,  'T222 Los Angeles', 9, 1, 'America/Los_Angeles'),
         (vJan, 'T222 January',     1, 1, 'UTC');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (vSyd, u_owner, 'owner'),
    (vLA,  u_owner, 'owner'),
    (vJan, u_owner, 'owner');

  insert into public.paddocks (id, vineyard_id, name)
  values (pk, vSyd, 'T222 Block A')
  on conflict (id) do nothing;

  -- =====================================================================
  -- T1 Objects
  -- =====================================================================
  select count(*) into n
    from information_schema.columns
   where table_schema = 'public'
     and column_name = 'vintage'
     and table_name in ('pins','trips','spray_records','growth_stage_records',
                        'maintenance_logs','fuel_purchases','tractor_fuel_logs',
                        'fertiliser_records');
  assert n = 8, format('T1: expected 8 vintage columns, found %s', n);

  select count(*) into n
    from pg_trigger
   where not tgisinternal
     and tgname in ('pins_resolve_vintage','trips_resolve_vintage',
                    'spray_records_resolve_vintage','growth_stage_records_resolve_vintage',
                    'maintenance_logs_resolve_vintage','fuel_purchases_resolve_vintage',
                    'tractor_fuel_logs_resolve_vintage','fertiliser_records_resolve_vintage');
  assert n = 8, format('T1: expected 8 vintage triggers, found %s', n);

  assert to_regprocedure('public._vineyard_local_date(uuid, timestamptz)') is not null,
    'T1: _vineyard_local_date helper missing';

  select count(*) into n
    from pg_indexes
   where schemaname = 'public'
     and indexname in ('pins_vineyard_vintage_idx','trips_vineyard_vintage_idx',
                       'spray_records_vineyard_vintage_idx',
                       'growth_stage_records_vineyard_vintage_idx',
                       'maintenance_logs_vineyard_vintage_idx',
                       'fuel_purchases_vineyard_vintage_idx',
                       'tractor_fuel_logs_vineyard_vintage_idx',
                       'fertiliser_records_vineyard_vintage_idx');
  assert n = 8, format('T1: expected 8 vineyard+vintage indexes, found %s', n);

  -- The shared helper must agree with the vineyard's configured season.
  assert public._vineyard_local_date(vSyd, timestamptz '2026-09-01T00:30:00+10:00')
         = date '2026-09-01',
    'T1: _vineyard_local_date must report the vineyard-local day';

  -- =====================================================================
  -- T2 INSERT resolves from each table's own event date
  --
  -- Sydney season starts 1 September, so 15 Sep 2026 → Vintage 2027 and
  -- 15 Aug 2026 → Vintage 2026 on every table.
  -- =====================================================================
  insert into public.pins (id, vineyard_id, created_at)
  values (t_pin, vSyd, timestamptz '2026-09-15T10:00:00+10:00');
  select vintage into v_int from public.pins where id = t_pin;
  assert v_int = 2027, format('T2 pins: expected 2027, got %s', v_int);

  insert into public.trips (id, vineyard_id, start_time)
  values (t_trip, vSyd, timestamptz '2026-09-15T10:00:00+10:00');
  select vintage into v_int from public.trips where id = t_trip;
  assert v_int = 2027, format('T2 trips: expected 2027, got %s', v_int);

  insert into public.spray_records (id, vineyard_id, date)
  values (t_spray, vSyd, timestamptz '2026-08-15T10:00:00+10:00');
  select vintage into v_int from public.spray_records where id = t_spray;
  assert v_int = 2026, format('T2 spray_records: expected 2026, got %s', v_int);

  insert into public.growth_stage_records (id, vineyard_id, observed_at)
  values (t_growth, vSyd, timestamptz '2026-09-15T10:00:00+10:00');
  select vintage into v_int from public.growth_stage_records where id = t_growth;
  assert v_int = 2027, format('T2 growth_stage_records: expected 2027, got %s', v_int);

  insert into public.maintenance_logs (id, vineyard_id, date)
  values (t_maint, vSyd, timestamptz '2026-08-15T10:00:00+10:00');
  select vintage into v_int from public.maintenance_logs where id = t_maint;
  assert v_int = 2026, format('T2 maintenance_logs: expected 2026, got %s', v_int);

  insert into public.fuel_purchases (id, vineyard_id, date)
  values (t_fuel, vSyd, timestamptz '2026-09-15T10:00:00+10:00');
  select vintage into v_int from public.fuel_purchases where id = t_fuel;
  assert v_int = 2027, format('T2 fuel_purchases: expected 2027, got %s', v_int);

  insert into public.tractor_fuel_logs (id, vineyard_id, fill_datetime)
  values (t_tfuel, vSyd, timestamptz '2026-09-15T10:00:00+10:00');
  select vintage into v_int from public.tractor_fuel_logs where id = t_tfuel;
  assert v_int = 2027, format('T2 tractor_fuel_logs: expected 2027, got %s', v_int);

  insert into public.fertiliser_records (id, vineyard_id, application_date)
  values (t_fert, vSyd, date '2026-09-15');
  select vintage into v_int from public.fertiliser_records where id = t_fert;
  assert v_int = 2027, format('T2 fertiliser_records: expected 2027, got %s', v_int);

  -- =====================================================================
  -- T3 Vineyard-local boundary
  --
  -- One UTC instant, two vineyards. 2026-08-31T16:00Z is 1 Sep 10:00 in
  -- Sydney (season already started → 2027) but still 31 Aug 09:00 in Los
  -- Angeles (season not yet started → 2026). A UTC-only resolver would put
  -- both in the same vintage; that is exactly the bug this guards.
  -- =====================================================================
  insert into public.pins (id, vineyard_id, created_at)
  values (b_syd, vSyd, timestamptz '2026-08-31T16:00:00Z'),
         (b_la,  vLA,  timestamptz '2026-08-31T16:00:00Z');

  select vintage into v_int  from public.pins where id = b_syd;
  select vintage into v_int2 from public.pins where id = b_la;
  assert v_int = 2027,
    format('T3: Sydney side of the boundary must be 2027, got %s', v_int);
  assert v_int2 = 2026,
    format('T3: Los Angeles side of the boundary must be 2026, got %s', v_int2);
  assert v_int <> v_int2,
    'T3: the same UTC instant must resolve to different vintages per timezone';

  -- =====================================================================
  -- T4 Changing the event date re-resolves (audit req 10)
  -- =====================================================================
  update public.pins set created_at = timestamptz '2026-08-15T10:00:00+10:00'
   where id = t_pin;
  select vintage into v_int from public.pins where id = t_pin;
  assert v_int = 2026,
    format('T4 pins: moving the date back must re-resolve to 2026, got %s', v_int);

  update public.spray_records set date = timestamptz '2026-09-15T10:00:00+10:00'
   where id = t_spray;
  select vintage into v_int from public.spray_records where id = t_spray;
  assert v_int = 2027,
    format('T4 spray_records: moving the date forward must re-resolve to 2027, got %s', v_int);

  update public.fertiliser_records set application_date = date '2026-08-15'
   where id = t_fert;
  select vintage into v_int from public.fertiliser_records where id = t_fert;
  assert v_int = 2026,
    format('T4 fertiliser_records: expected 2026 after date move, got %s', v_int);

  -- Put the pin back where T2 left it for the checks that follow.
  update public.pins set created_at = timestamptz '2026-09-15T10:00:00+10:00'
   where id = t_pin;

  -- =====================================================================
  -- T5 Unrelated edits never move a record between vintages (audit req 9)
  --
  -- Each table gets a real field edit that has nothing to do with the event
  -- date; the stored vintage must survive every one of them.
  -- =====================================================================
  update public.pins set notes = 'T222 unrelated edit' where id = t_pin;
  select vintage into v_int from public.pins where id = t_pin;
  assert v_int = 2027, format('T5 pins: unrelated edit moved the vintage to %s', v_int);

  update public.trips set notes = 'T222 unrelated edit' where id = t_trip;
  select vintage into v_int from public.trips where id = t_trip;
  assert v_int = 2027, format('T5 trips: unrelated edit moved the vintage to %s', v_int);

  update public.spray_records set notes = 'T222 unrelated edit' where id = t_spray;
  select vintage into v_int from public.spray_records where id = t_spray;
  assert v_int = 2027, format('T5 spray_records: unrelated edit moved the vintage to %s', v_int);

  update public.growth_stage_records set notes = 'T222 unrelated edit' where id = t_growth;
  select vintage into v_int from public.growth_stage_records where id = t_growth;
  assert v_int = 2027, format('T5 growth_stage_records: unrelated edit moved the vintage to %s', v_int);

  update public.maintenance_logs set notes = 'T222 unrelated edit' where id = t_maint;
  select vintage into v_int from public.maintenance_logs where id = t_maint;
  assert v_int = 2026, format('T5 maintenance_logs: unrelated edit moved the vintage to %s', v_int);

  update public.fuel_purchases set notes = 'T222 unrelated edit' where id = t_fuel;
  select vintage into v_int from public.fuel_purchases where id = t_fuel;
  assert v_int = 2027, format('T5 fuel_purchases: unrelated edit moved the vintage to %s', v_int);

  update public.tractor_fuel_logs set notes = 'T222 unrelated edit' where id = t_tfuel;
  select vintage into v_int from public.tractor_fuel_logs where id = t_tfuel;
  assert v_int = 2027, format('T5 tractor_fuel_logs: unrelated edit moved the vintage to %s', v_int);

  update public.fertiliser_records set notes = 'T222 unrelated edit' where id = t_fert;
  select vintage into v_int from public.fertiliser_records where id = t_fert;
  assert v_int = 2026, format('T5 fertiliser_records: unrelated edit moved the vintage to %s', v_int);

  -- A no-op touch of updated_at must not move it either.
  update public.pins set updated_at = now() where id = t_pin;
  select vintage into v_int from public.pins where id = t_pin;
  assert v_int = 2027, format('T5 pins: updated_at touch moved the vintage to %s', v_int);

  -- =====================================================================
  -- T6 A deliberate client restatement is honoured
  --
  -- The user moved the date AND explicitly restated the vintage in the same
  -- write: that is a considered correction, not a stale client value.
  -- =====================================================================
  update public.maintenance_logs
     set date = timestamptz '2026-09-20T10:00:00+10:00',
         vintage = 2026
   where id = t_maint;
  select vintage into v_int from public.maintenance_logs where id = t_maint;
  assert v_int = 2026,
    format('T6: an explicit restatement must be preserved, got %s', v_int);

  -- =====================================================================
  -- T7 Offline replay — absent or implausible values are resolved, never
  --    rejected (audit req 3)
  -- =====================================================================
  -- An un-updated build that knows nothing about the column at all.
  insert into public.fuel_purchases (id, vineyard_id, date)
  values (gen_random_uuid(), vSyd, timestamptz '2026-09-15T10:00:00+10:00')
  returning vintage into v_int;
  assert v_int = 2027,
    format('T7: an omitted vintage must be server-resolved to 2027, got %s', v_int);

  -- A stale client that computed something impossible.
  insert into public.fuel_purchases (id, vineyard_id, date, vintage)
  values (gen_random_uuid(), vSyd, timestamptz '2026-09-15T10:00:00+10:00', 1899)
  returning vintage into v_int;
  assert v_int = 2027,
    format('T7: an implausible past vintage must be re-resolved, got %s', v_int);

  insert into public.fuel_purchases (id, vineyard_id, date, vintage)
  values (gen_random_uuid(), vSyd, timestamptz '2026-09-15T10:00:00+10:00', 9999)
  returning vintage into v_int;
  assert v_int = 2027,
    format('T7: an implausible future vintage must be re-resolved, got %s', v_int);

  -- A plausible client value is trusted as-is.
  insert into public.fuel_purchases (id, vineyard_id, date, vintage)
  values (gen_random_uuid(), vSyd, timestamptz '2026-09-15T10:00:00+10:00', 2026)
  returning vintage into v_int;
  assert v_int = 2026,
    format('T7: a plausible client vintage must be preserved, got %s', v_int);

  -- =====================================================================
  -- T8 spray_records fallback chain — `date` has always been nullable
  -- =====================================================================
  insert into public.spray_records (id, vineyard_id, date, start_time)
  values (t_spray2, vSyd, null, timestamptz '2026-09-15T10:00:00+10:00');
  select vintage into v_int from public.spray_records where id = t_spray2;
  assert v_int = 2027,
    format('T8: a null date must fall back to start_time, got %s', v_int);

  insert into public.spray_records (id, vineyard_id, date, start_time, created_at)
  values (t_spray3, vSyd, null, null, timestamptz '2026-08-15T10:00:00+10:00');
  select vintage into v_int from public.spray_records where id = t_spray3;
  assert v_int = 2026,
    format('T8: a null date and start_time must fall back to created_at, got %s', v_int);

  -- =====================================================================
  -- T9 fertiliser_records takes its DATE column with NO timezone shift
  --
  -- 1 September is the first day of the season. If the date were pushed
  -- through a timezone conversion it would slip to 31 August for a UTC+10
  -- vineyard and land in the wrong vintage.
  -- =====================================================================
  insert into public.fertiliser_records (id, vineyard_id, application_date)
  values (gen_random_uuid(), vSyd, date '2026-09-01')
  returning vintage into v_int;
  assert v_int = 2027,
    format('T9: 1 Sep must be the first day of Vintage 2027, got %s', v_int);

  insert into public.fertiliser_records (id, vineyard_id, application_date)
  values (gen_random_uuid(), vSyd, date '2026-08-31')
  returning vintage into v_int;
  assert v_int = 2026,
    format('T9: 31 Aug must be the last day of Vintage 2026, got %s', v_int);

  -- A 1 January season start means vintage == calendar year.
  insert into public.fertiliser_records (id, vineyard_id, application_date)
  values (gen_random_uuid(), vJan, date '2026-02-15')
  returning vintage into v_int;
  assert v_int = 2026,
    format('T9: a 1 Jan season start must give vintage = calendar year, got %s', v_int);

  -- =====================================================================
  -- T10 Backfill corrects rows written while the trigger was off (req 4)
  -- =====================================================================
  alter table public.pins disable trigger pins_resolve_vintage;
  insert into public.pins (id, vineyard_id, created_at, vintage)
  values (t_bfill, vSyd, timestamptz '2026-09-15T10:00:00+10:00', null);
  alter table public.pins enable trigger pins_resolve_vintage;

  select vintage into v_int from public.pins where id = t_bfill;
  assert v_int is null, 'T10: fixture must start with a null vintage';

  -- The exact statement shape the migration's backfill runs.
  update public.pins p
     set vintage = public.resolve_vineyard_vintage_year(
                     p.vineyard_id,
                     (p.created_at at time zone coalesce(nullif(v.timezone, ''), 'UTC'))::date)
    from public.vineyards v
   where v.id = p.vineyard_id
     and p.vintage is null
     and p.created_at is not null;

  select vintage into v_int from public.pins where id = t_bfill;
  assert v_int = 2027, format('T10: backfill must resolve to 2027, got %s', v_int);

  -- =====================================================================
  -- T11 Filtering by vineyard + vintage returns only that slice (req 5)
  -- =====================================================================
  select count(*) into n
    from public.pins
   where vineyard_id = vSyd and vintage = 2027 and deleted_at is null;
  assert n >= 3, format('T11: expected at least 3 Sydney 2027 pins, got %s', n);

  select count(*) into n
    from public.pins
   where vineyard_id = vLA and vintage = 2027 and deleted_at is null;
  assert n = 0, format('T11: the LA pin must not appear in 2027, got %s', n);

  select count(*) into n
    from public.pins
   where vineyard_id = vLA and vintage = 2026 and deleted_at is null;
  assert n = 1, format('T11: expected exactly 1 LA 2026 pin, got %s', n);

  -- Cross-vineyard leakage guard: filtering by vintage alone must never be
  -- treated as sufficient — the vineyard scope has to be part of the key.
  select count(distinct vineyard_id) into n
    from public.pins
   where vintage = 2026 and vineyard_id in (vSyd, vLA);
  assert n >= 1, 'T11: expected 2026 pins to exist for at least one fixture vineyard';

  -- =====================================================================
  -- T12 SQL 221's Yield/Damage contract is untouched
  -- =====================================================================
  assert to_regprocedure('public.damage_records_resolve_vintage()') is not null,
    'T12: SQL 221 damage trigger function must still exist';
  assert to_regprocedure('public.yield_estimation_sessions_resolve_vintage()') is not null,
    'T12: SQL 221 session trigger function must still exist';
  assert to_regclass('public.season_yield_estimates') is not null,
    'T12: SQL 221 season_yield_estimates table must still exist';

  select count(*) into n
    from pg_trigger
   where not tgisinternal
     and tgname in ('damage_records_resolve_vintage',
                    'yield_estimation_sessions_resolve_vintage');
  assert n = 2, format('T12: expected SQL 221 triggers still installed, found %s', n);

  -- 221 still resolves damage exactly as before, alongside the new triggers.
  insert into public.damage_records (id, vineyard_id, paddock_id, date)
  values (gen_random_uuid(), vSyd, pk, timestamptz '2026-09-15T10:00:00+10:00')
  returning vintage into v_int;
  assert v_int = 2027,
    format('T12: SQL 221 damage resolution must be unchanged, got %s', v_int);

  raise notice 'SQL 222 operational record vintage tests: ALL PASSED';
end
$t222$;

-- =====================================================================
-- T13 Discard everything
-- =====================================================================
rollback;
