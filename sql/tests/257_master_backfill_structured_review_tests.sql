-- Run ONLY on an isolated database after the timestamped Master backfill migration.
-- ROLLBACK-ONLY: never execute fixture inserts on production.
begin;
do $$
declare
  v_fn regprocedure := 'public.master_review_apply(uuid,uuid,text)'::regprocedure;
  v_stats regprocedure := 'public.master_backfill_catalogue_stats_v2()'::regprocedure;
  v_body text;
  v_id uuid := gen_random_uuid();
  v_before integer;
  v_after integer;
begin
  select pg_get_functiondef(v_fn) into v_body;
  if v_body not like '%security definer%' and v_body not like '%SECURITY DEFINER%' then
    raise exception 'review apply lost SECURITY DEFINER';
  end if;
  if v_body not like '%v_preview.requested_by is distinct from auth.uid()%' or
     v_body not like '%v_master.catalogue_version <> v_preview.base_revision%' or
     v_body not like '%forbidden_key=%' or
     v_body not like '%resistance_classification_state%' or
     v_body not like '%viticulture_rates%' or
     v_body not like '%master_chemical_review_actions%' then
    raise exception 'review boundary/structured field contract incomplete';
  end if;
  if has_function_privilege('anon',v_fn,'EXECUTE') or
     not has_function_privilege('authenticated',v_fn,'EXECUTE') or
     has_function_privilege('anon',v_stats,'EXECUTE') then
    raise exception 'review/stats RPC grants changed';
  end if;
  -- A state-only Master change must trigger the normal catalogue revision and
  -- append-only history, not merely change a field outside the comparator.
  perform set_config('request.jwt.claims','{}',true);
  insert into public.master_chemicals
    (id,registration_country,registration_scheme,registration_number,registered_product_name,
     review_status,source_kind,resistance_classification_state)
  values (v_id,'AU','apvma',v_id::text,'T257 History Fixture','candidate','official_register','unresolved');
  select catalogue_version into v_before from public.master_chemicals where id=v_id;
  update public.master_chemicals set resistance_classification_state='classified' where id=v_id;
  select catalogue_version into v_after from public.master_chemicals where id=v_id;
  if v_after <> v_before+1 or not exists (
    select 1 from public.master_chemical_versions where master_chemical_id=v_id and catalogue_version=v_after
  ) then raise exception 'state-only change lost version/history'; end if;
  raise notice 'T257: structured review contract and state-only history passed';
end$$;
rollback;
