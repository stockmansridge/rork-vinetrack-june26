-- =====================================================================
-- 191_spray_application_geometry_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/191_spray_application_geometry.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects: every new column exists on spray_records / spray_jobs /
--       vineyards, and both spray-profile RPCs exist
--   T2  BACKWARDS COMPATIBILITY: a legacy-shaped insert that names none of
--       the new columns still succeeds, and every new column is NULL
--   T3  NO BACKFILL: the legacy row's treated_area_ha stays NULL — it does
--       NOT acquire a guessed treated area equal to its gross area
--   T4  The full new contract round-trips (10 ha gross, 2.5 ha treated,
--       31,250 m canonical rows, 0.8 m band)
--   T5  Domain CHECKs reject junk but accept NULL, on BOTH tables
--   T6  A band width of 0 is rejected — absence must be NULL so it can
--       never dose a tank
--   T7  A negative treated area and a zero row length are rejected
--   T8  Templates (spray_jobs.is_template = true) carry the band width and
--       carrier basis, so a banded template survives reuse
--   T9  vineyards: the new profile columns default to NULL for existing
--       vineyards (country default is resolved client-side, never stored)
--   T10 get_vineyard_spray_profile: a member reads; a non-member is denied
--   T11 set_vineyard_spray_profile: owner/manager writes, supervisor denied
--   T12 set_vineyard_spray_profile: '' is coerced to NULL (= "fall back to
--       the country default"), and an unsupported value raises
--   T13 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 191 spray application geometry tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 191 is applied.
do $$
begin
  if to_regprocedure('public.get_vineyard_spray_profile(uuid)') is null
     or to_regprocedure('public.set_vineyard_spray_profile(uuid, text, text)') is null then
    raise exception 'SQL 191 not applied — run sql/191_spray_application_geometry.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr    uuid;
  u_sup    uuid;
  u_out    uuid;
  v_vy     uuid := gen_random_uuid();
  r_legacy uuid := gen_random_uuid();
  r_new    uuid := gen_random_uuid();
  j_tpl    uuid := gen_random_uuid();
  v_txt    text;
  v_num    numeric;
  v_cnt    int;
  v_failed boolean;
begin
  -- ---------------- T1 objects ----------------
  -- Asserted BY NAME, never by count. A count can only say "one is missing";
  -- it can never say WHICH one, which makes it useless as a diagnostic. These
  -- lists are the authoritative statement of the stored contract.
  --
  -- spray_records takes 17 columns, spray_jobs 13. That asymmetry is deliberate,
  -- not an omission: `row_spacing_metres` and `concentration_factor` already
  -- exist on spray_jobs (sql/034) and must not be redeclared there.
  select string_agg(t.col, ', ' order by t.col) into v_txt
    from unnest(array[
      'gross_area_ha', 'treated_area_ha', 'application_mode', 'treated_area_method',
      'band_width_total_metres', 'band_width_left_metres', 'band_width_right_metres',
      'canonical_row_length_metres', 'row_spacing_metres', 'geometry_source',
      'geometry_quality', 'carrier_volume_basis', 'total_carrier_litres',
      'carrier_litres_per_hectare', 'dilute_litres_per_100m',
      'applied_litres_per_100m', 'concentration_factor']) as t(col)
   where not exists (
     select 1
       from information_schema.columns ic
      where ic.table_schema = 'public'
        and ic.table_name   = 'spray_records'
        and ic.column_name  = t.col);
  if v_txt is not null then
    raise exception 'T1 failed: spray_records is missing column(s): %', v_txt;
  end if;

  select string_agg(t.col, ', ' order by t.col) into v_txt
    from unnest(array[
      'gross_area_ha', 'treated_area_ha', 'application_mode', 'treated_area_method',
      'band_width_total_metres', 'band_width_left_metres', 'band_width_right_metres',
      'canonical_row_length_metres', 'geometry_source', 'geometry_quality',
      'carrier_volume_basis', 'dilute_litres_per_100m',
      'applied_litres_per_100m']) as t(col)
   where not exists (
     select 1
       from information_schema.columns ic
      where ic.table_schema = 'public'
        and ic.table_name   = 'spray_jobs'
        and ic.column_name  = t.col);
  if v_txt is not null then
    raise exception 'T1 failed: spray_jobs is missing column(s): %', v_txt;
  end if;

  select string_agg(t.col, ', ' order by t.col) into v_txt
    from unnest(array[
      'spray_compliance_profile', 'spray_carrier_volume_basis']) as t(col)
   where not exists (
     select 1
       from information_schema.columns ic
      where ic.table_schema = 'public'
        and ic.table_name   = 'vineyards'
        and ic.column_name  = t.col);
  if v_txt is not null then
    raise exception 'T1 failed: vineyards is missing column(s): %', v_txt;
  end if;

  -- Every new column must be nullable: a nullable column can never invalidate
  -- an existing row.
  select string_agg(table_name || '.' || column_name, ', '
                    order by table_name || '.' || column_name) into v_txt
    from information_schema.columns
   where table_schema = 'public'
     and table_name   in ('spray_records', 'spray_jobs')
     and column_name  in (
       'gross_area_ha', 'treated_area_ha', 'application_mode', 'treated_area_method',
       'band_width_total_metres', 'canonical_row_length_metres', 'geometry_source',
       'geometry_quality', 'carrier_volume_basis')
     and is_nullable = 'NO';
  if v_txt is not null then
    raise exception 'T1 failed: new column(s) are NOT NULL: %', v_txt;
  end if;

  -- Fixtures.
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't191-mgr@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't191-sup@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 't191-out@test.local', 'x', now(), now(), now());
  select id into u_mgr from auth.users where email = 't191-mgr@test.local';
  select id into u_sup from auth.users where email = 't191-sup@test.local';
  select id into u_out from auth.users where email = 't191-out@test.local';
  insert into public.profiles (id, email) values
    (u_mgr, 't191-mgr@test.local'),
    (u_sup, 't191-sup@test.local'),
    (u_out, 't191-out@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name, country_code)
  values (v_vy, 'T191 Spray Geometry Vineyard', 'NZ');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy, u_mgr, 'manager'),
    (v_vy, u_sup, 'supervisor');

  -- ---------------- T2 legacy-shaped insert ----------------
  -- Exactly the columns a pre-191 client writes. If this fails, the migration
  -- broke every deployed client.
  insert into public.spray_records (id, vineyard_id, date, spray_reference, operation_type, tanks)
  values (r_legacy, v_vy, now(), 'T191 legacy foliar', 'Foliar Spray',
          '[{"tankNumber":1,"waterVolume":3000,"sprayRatePerHa":300,"concentrationFactor":1,"chemicals":[]}]'::jsonb);

  select count(*) into v_cnt
    from public.spray_records
   where id = r_legacy
     and gross_area_ha is null and treated_area_ha is null
     and application_mode is null and treated_area_method is null
     and band_width_total_metres is null and canonical_row_length_metres is null
     and geometry_source is null and geometry_quality is null
     and carrier_volume_basis is null and total_carrier_litres is null
     and concentration_factor is null;
  if v_cnt <> 1 then
    raise exception 'T2 failed: legacy insert did not leave every new column NULL';
  end if;

  -- ---------------- T3 no backfill ----------------
  select treated_area_ha into v_num from public.spray_records where id = r_legacy;
  if v_num is not null then
    raise exception 'T3 failed: legacy record acquired a treated area of %', v_num;
  end if;

  -- ---------------- T4 the new contract round-trips ----------------
  -- 10 ha block, 31,250 m of row, 3.2 m spacing, 0.8 m total band:
  --   31,250 x 0.8 / 10,000 = 2.50 ha treated (gross stays 10).
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type,
    gross_area_ha, treated_area_ha, application_mode, treated_area_method,
    band_width_total_metres, band_width_left_metres, band_width_right_metres,
    canonical_row_length_metres, row_spacing_metres, geometry_source, geometry_quality,
    carrier_volume_basis, total_carrier_litres, carrier_litres_per_hectare,
    dilute_litres_per_100m, applied_litres_per_100m, concentration_factor, tanks
  ) values (
    r_new, v_vy, now(), 'T191 banded herbicide', 'Banded Spray',
    10, 2.5, 'banded', 'canonical_row_length',
    0.8, 0.4, 0.4,
    31250, 3.2, 'mapped_rows', 'authoritative',
    'l_per_100m', 6250, 625,
    40, 20, 2.0,
    '[{"tankNumber":1,"waterVolume":6250,"sprayRatePerHa":625,"concentrationFactor":2,"chemicals":[{"name":"Herbicide","rateBasis":"treated_area","ratePerHa":2,"volumePerTank":5,"unit":"Litres"}]}]'::jsonb
  );

  select count(*) into v_cnt
    from public.spray_records
   where id = r_new
     and gross_area_ha = 10 and treated_area_ha = 2.5
     and canonical_row_length_metres = 31250
     and carrier_volume_basis = 'l_per_100m'
     and total_carrier_litres = 6250
     and concentration_factor = 2.0;
  if v_cnt <> 1 then
    raise exception 'T4 failed: new contract did not round-trip';
  end if;

  -- Gross must survive alongside treated — treated never replaces gross.
  select gross_area_ha into v_num from public.spray_records where id = r_new;
  if v_num <> 10 then
    raise exception 'T4 failed: gross_area_ha was overwritten (%)', v_num;
  end if;

  -- ---------------- T5 domain CHECKs ----------------
  v_failed := false;
  begin
    update public.spray_records set application_mode = 'sideways' where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T5 failed: application_mode accepted junk';
  end if;

  v_failed := false;
  begin
    update public.spray_records set carrier_volume_basis = 'gallons_per_acre' where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T5 failed: carrier_volume_basis accepted junk';
  end if;

  v_failed := false;
  begin
    update public.spray_records set geometry_source = 'vibes' where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T5 failed: geometry_source accepted junk';
  end if;

  v_failed := false;
  begin
    update public.spray_records set geometry_quality = 'probably_fine' where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T5 failed: geometry_quality accepted junk';
  end if;

  v_failed := false;
  begin
    update public.spray_records set treated_area_method = 'divide_by_three' where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T5 failed: treated_area_method accepted junk';
  end if;

  -- NULL must remain acceptable for every one of them.
  update public.spray_records
     set application_mode = null, carrier_volume_basis = null,
         geometry_source = null, geometry_quality = null, treated_area_method = null
   where id = r_new;

  -- ---------------- T6 band width of zero is rejected ----------------
  v_failed := false;
  begin
    update public.spray_records set band_width_total_metres = 0 where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T6 failed: a 0 m band width was accepted — absence must be NULL';
  end if;

  -- ---------------- T7 physical sanity ----------------
  v_failed := false;
  begin
    update public.spray_records set treated_area_ha = -1 where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T7 failed: a negative treated area was accepted';
  end if;

  v_failed := false;
  begin
    update public.spray_records set canonical_row_length_metres = 0 where id = r_new;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T7 failed: a 0 m canonical row length was accepted';
  end if;

  -- ---------------- T8 templates carry the contract ----------------
  insert into public.spray_jobs (
    id, vineyard_id, name, is_template, operation_type,
    application_mode, band_width_total_metres, carrier_volume_basis,
    applied_litres_per_100m, dilute_litres_per_100m, chemical_lines
  ) values (
    j_tpl, v_vy, 'T191 banded template', true, 'Banded Spray',
    'banded', 0.8, 'l_per_100m', 20, 40,
    '[{"name":"Herbicide","rate":2,"unit":"L/ha","rate_basis":"treated_area"}]'::jsonb
  );

  select count(*) into v_cnt
    from public.spray_jobs
   where id = j_tpl and is_template = true
     and application_mode = 'banded' and band_width_total_metres = 0.8
     and carrier_volume_basis = 'l_per_100m'
     and chemical_lines -> 0 ->> 'rate_basis' = 'treated_area';
  if v_cnt <> 1 then
    raise exception 'T8 failed: banded template did not retain its contract';
  end if;

  -- ---------------- T9 vineyards default to NULL ----------------
  select count(*) into v_cnt
    from public.vineyards
   where id = v_vy
     and spray_compliance_profile is null
     and spray_carrier_volume_basis is null;
  if v_cnt <> 1 then
    raise exception 'T9 failed: a new vineyard was given a stored spray profile';
  end if;

  -- ---------------- T10 read permission ----------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select spray_compliance_profile into v_txt
    from public.get_vineyard_spray_profile(v_vy);
  if v_txt is not null then
    raise exception 'T10 failed: expected NULL stored profile, got %', v_txt;
  end if;

  -- country_code comes back so the client can resolve its default in one trip.
  select country_code into v_txt from public.get_vineyard_spray_profile(v_vy);
  if v_txt <> 'NZ' then
    raise exception 'T10 failed: expected country_code NZ, got %', coalesce(v_txt, '<null>');
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform * from public.get_vineyard_spray_profile(v_vy);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T10 failed: a non-member read the spray profile';
  end if;

  -- ---------------- T11 write permission ----------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sup::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform * from public.set_vineyard_spray_profile(v_vy, 'nz_swnz', 'l_per_100m');
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T11 failed: a supervisor changed the vineyard spray profile';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  select spray_carrier_volume_basis into v_txt
    from public.set_vineyard_spray_profile(v_vy, 'nz_swnz', 'l_per_100m');
  if v_txt <> 'l_per_100m' then
    raise exception 'T11 failed: manager write returned %', coalesce(v_txt, '<null>');
  end if;

  -- ---------------- T12 blank coercion + validation ----------------
  select spray_compliance_profile into v_txt
    from public.set_vineyard_spray_profile(v_vy, '', '');
  if v_txt is not null then
    raise exception 'T12 failed: empty string was stored instead of NULL (%)', v_txt;
  end if;

  v_failed := false;
  begin
    perform * from public.set_vineyard_spray_profile(v_vy, 'france', 'either');
  exception when others then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T12 failed: an unsupported compliance profile was accepted';
  end if;

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 191 spray application geometry tests: ALL PASSED';
end$$;

-- ---------------- T13 discard everything ----------------
rollback;
