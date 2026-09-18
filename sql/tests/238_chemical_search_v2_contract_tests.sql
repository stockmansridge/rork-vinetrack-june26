-- Focused post-install contract checks for sql/238_chemical_search_v2.sql.
-- Run only in an isolated validation database or inside a transaction that is rolled back.

do $$
declare
  v_id uuid := gen_random_uuid();
  v_version integer;
  v_history integer;
  v_policy_count integer;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'master_chemicals'
      and column_name = 'viticulture_rates'
  ) then
    raise exception 'T238.1: viticulture_rates missing';
  end if;

  if exists (
    select 1 from pg_get_functiondef(p.oid) body
    where p.oid = 'public.search_master_chemicals_v2(text,integer)'::regprocedure
      and (body like '%r.manufacturer_label_url%' or body like '%r.manufacturer_product_url%')
  ) then
    raise exception 'T238.2: RPC still reads nonexistent Master URL columns';
  end if;

  if not exists (
    select 1 from pg_get_functiondef(p.oid) body
    where p.oid = 'public.master_chemicals_before_write()'::regprocedure
      and body like '%new.viticulture_rates%'
      and body like '%old.viticulture_rates%'
  ) then
    raise exception 'T238.3: canonical revision trigger omits viticulture_rates';
  end if;

  if exists (
    select 1 from pg_trigger
    where tgrelid = 'public.master_chemicals'::regclass
      and not tgisinternal and tgname = 'zz_master_chemicals_v2_rate_revision'
  ) then
    raise exception 'T238.4: competing rate-only revision trigger remains';
  end if;

  insert into public.master_chemicals (
    id, registration_country, registration_scheme, registration_number,
    registration_identity_key, registered_product_name, review_status,
    source_kind, verification_status, verification_sources
  ) values (
    v_id, 'AU', 'apvma', '99999998', 'AU:apvma:99999998',
    'T238 RATE VERSION FIXTURE', 'candidate', 'official_register',
    'partially_verified',
    '[{"kind":"official_register"},{"kind":"viticulture_reference","reference":"https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf"}]'::jsonb
  );

  select catalogue_version into v_version from public.master_chemicals where id = v_id;
  if v_version <> 1 then raise exception 'T238.5: fixture did not start at version 1'; end if;

  update public.master_chemicals
  set viticulture_rates = '{"per_hectare":[{"label":"","basis":"per_hectare","value":1,"unit":"L","raw_text":"1 L/ha"}],"per_100_litres":[]}'::jsonb
  where id = v_id;

  select catalogue_version into v_version from public.master_chemicals where id = v_id;
  select count(*) into v_history from public.master_chemical_versions
  where master_chemical_id = v_id and catalogue_version = 2
    and snapshot->'viticulture_rates'->'per_hectare'->0->>'raw_text' = '1 L/ha';
  if v_version <> 2 or v_history <> 1 then
    raise exception 'T238.6: rate update was not versioned and snapshotted (% / %)', v_version, v_history;
  end if;

  select count(*) into v_policy_count
  from pg_policies
  where schemaname = 'public' and tablename = 'saved_chemical_attachments'
    and policyname in (
      'saved_chemical_attachments_member_insert',
      'saved_chemical_attachments_member_update',
      'saved_chemical_attachments_manager_delete'
    )
    and (coalesce(with_check, qual, '') like '%has_vineyard_role%owner%manager%');
  if v_policy_count <> 3 then
    raise exception 'T238.7: attachment mutation policies are not Owner/Manager-only';
  end if;

  select count(*) into v_policy_count
  from pg_policies
  where schemaname = 'storage' and tablename = 'objects'
    and policyname in (
      'chemical_label_photos_member_insert',
      'chemical_label_photos_member_update',
      'chemical_label_photos_member_delete'
    )
    and (coalesce(with_check, qual, '') like '%has_vineyard_role%owner%manager%');
  if v_policy_count <> 3 then
    raise exception 'T238.8: storage mutation policies are not Owner/Manager-only';
  end if;

  if (select public from storage.buckets where id = 'chemical-label-photos') is distinct from false then
    raise exception 'T238.9: label-photo bucket must remain private';
  end if;

  raise notice 'SQL 238 focused contract tests: ALL PASSED';
end $$;
