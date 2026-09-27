-- Extend the existing sql/203 audited review apply whitelist. No direct Master write grant.
-- The preview remains service-stored, admin-bound, expiring, CAS-checked and single-use.
begin;
create or replace function public.master_review_apply(
  p_preview_id uuid, p_master_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_preview public.master_review_previews%rowtype;
  v_master public.master_chemicals%rowtype;
  v_patch jsonb;
  v_key text;
  v_type text;
  v_action_id uuid := gen_random_uuid();
  v_result_revision integer;
begin
  if not public.is_system_admin() then
    raise exception 'not_authorised' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  select * into v_preview from public.master_review_previews where id = p_preview_id for update;
  if not found then raise exception 'preview_not_found' using errcode = 'P0002'; end if;
  if v_preview.requested_by is distinct from auth.uid() then
    raise exception 'preview_not_yours' using errcode = '42501';
  end if;
  if v_preview.master_chemical_id is distinct from p_master_id then
    raise exception 'preview_mismatch' using errcode = '22023';
  end if;
  if v_preview.consumed_at is not null then
    select a.result_revision into v_result_revision from public.master_chemical_review_actions a
      where a.id = v_preview.consumed_action_id;
    return jsonb_build_object('status','already_applied','master_chemical_id',p_master_id,
      'base_revision',v_preview.base_revision,'result_revision',v_result_revision,
      'action_id',v_preview.consumed_action_id);
  end if;
  if v_preview.expires_at <= now() then
    raise exception 'preview_expired' using errcode = '55000',
      hint = 'Re-run master_review_preview; the register may have drifted.';
  end if;
  select * into v_master from public.master_chemicals where id = p_master_id for update;
  if not found then raise exception 'master_not_found' using errcode = 'P0002'; end if;
  if v_master.catalogue_version <> v_preview.base_revision then
    raise exception 'revision_mismatch' using errcode = '55000',
      detail = format('current_revision=%s base_revision=%s',v_master.catalogue_version,v_preview.base_revision);
  end if;
  v_patch := v_preview.proposed_patch;
  if v_patch is null or jsonb_typeof(v_patch) <> 'object' or v_patch = '{}'::jsonb then
    raise exception 'patch_contract_violation' using errcode = '22023', detail = 'proposed_patch must be a non-empty object';
  end if;
  for v_key, v_type in select e.key, jsonb_typeof(e.value) from jsonb_each(v_patch) e loop
    if v_key in ('registered_product_name','verification_status','source_kind',
                  'resistance_classification_state') then
      if v_type <> 'string' then
        raise exception 'patch_contract_violation' using errcode = '22023',detail = format('key %s must be a string',v_key);
      end if;
      if v_key = 'resistance_classification_state' and v_patch->>v_key not in ('classified','not_applicable','unresolved') then
        raise exception 'patch_contract_violation' using errcode = '22023',detail = 'invalid resistance state';
      end if;
    elsif v_key in ('registrant','product_category','form_type','label_version',
                    'label_reference','source_reference','retrieved_at','activity_group_scheme') then
      if v_type not in ('string','null') then
        raise exception 'patch_contract_violation' using errcode = '22023',detail = format('key %s must be a string or null',v_key);
      end if;
      if v_key = 'activity_group_scheme' and v_type = 'string' and v_patch->>v_key not in ('frac','hrac','irac','not_applicable') then
        raise exception 'patch_contract_violation' using errcode = '22023',detail = 'invalid group scheme';
      end if;
    elsif v_key in ('registered_uses','label_rate_bases','active_ingredients','activity_groups') then
      if v_type <> 'array' then
        raise exception 'patch_contract_violation' using errcode = '22023',detail = format('key %s must be an array',v_key);
      end if;
      if v_key = 'active_ingredients' and exists (
        select 1 from jsonb_array_elements(v_patch->v_key) a
        where jsonb_typeof(a) <> 'object' or jsonb_typeof(a->'name') <> 'string'
      ) then raise exception 'patch_contract_violation' using errcode = '22023',detail = 'invalid active_ingredients'; end if;
      if v_key in ('activity_groups','label_rate_bases') and exists (
        select 1 from jsonb_array_elements(v_patch->v_key) a where jsonb_typeof(a) <> 'string'
      ) then raise exception 'patch_contract_violation' using errcode = '22023',detail = format('invalid %s',v_key); end if;
    elsif v_key = 'viticulture_rates' then
      if v_type <> 'object' or jsonb_typeof(v_patch->v_key->'per_hectare') <> 'array'
        or jsonb_typeof(v_patch->v_key->'per_100_litres') <> 'array' then
        raise exception 'patch_contract_violation' using errcode = '22023',detail = 'invalid viticulture_rates';
      end if;
    elsif v_key in ('verification_sources','verification_conflicts','verification_unresolved_fields') then
      if v_type not in ('array','null') then
        raise exception 'patch_contract_violation' using errcode = '22023',detail = format('key %s must be an array or null',v_key);
      end if;
    else
      raise exception 'patch_contract_violation' using errcode = '22023',detail = format('forbidden_key=%s',v_key);
    end if;
  end loop;
  -- The structured state must not claim complete classification when an active
  -- is still unresolved; explicit group-free is never inferred from [] groups.
  if v_patch ? 'resistance_classification_state' then
    if v_patch->>'resistance_classification_state' = 'classified' and
      (jsonb_array_length(coalesce(v_patch->'active_ingredients',v_master.active_ingredients)) = 0 or exists (
        select 1 from jsonb_array_elements(coalesce(v_patch->'active_ingredients',v_master.active_ingredients)) a
        where coalesce(a->'activity_group'->>'code','') = '' or coalesce(a->'activity_group'->>'scheme','') not in ('frac','hrac','irac')
      )) then raise exception 'patch_contract_violation' using errcode = '22023',detail = 'classified requires every active group'; end if;
    if v_patch->>'resistance_classification_state' = 'not_applicable' and
      (coalesce(v_patch->>'activity_group_scheme',v_master.activity_group_scheme) <> 'not_applicable'
       or jsonb_array_length(coalesce(v_patch->'active_ingredients',v_master.active_ingredients)) = 0
       or exists (select 1 from jsonb_array_elements(coalesce(v_patch->'active_ingredients',v_master.active_ingredients)) a
                  where a->'activity_group'->>'scheme' is distinct from 'not_applicable')) then
      raise exception 'patch_contract_violation' using errcode = '22023',detail = 'not_applicable requires explicit per-active assertion';
    end if;
  end if;
  perform set_config('vinetrack.master_change_reason',p_reason,true);
  update public.master_chemicals m set
    registered_product_name = case when v_patch ? 'registered_product_name' then v_patch->>'registered_product_name' else m.registered_product_name end,
    registrant = case when v_patch ? 'registrant' then v_patch->>'registrant' else m.registrant end,
    product_category = case when v_patch ? 'product_category' then v_patch->>'product_category' else m.product_category end,
    form_type = case when v_patch ? 'form_type' then v_patch->>'form_type' else m.form_type end,
    label_version = case when v_patch ? 'label_version' then v_patch->>'label_version' else m.label_version end,
    label_reference = case when v_patch ? 'label_reference' then v_patch->>'label_reference' else m.label_reference end,
    registered_uses = case when v_patch ? 'registered_uses' then v_patch->'registered_uses' else m.registered_uses end,
    active_ingredients = case when v_patch ? 'active_ingredients' then v_patch->'active_ingredients' else m.active_ingredients end,
    activity_groups = case when v_patch ? 'activity_groups' then array(select jsonb_array_elements_text(v_patch->'activity_groups')) else m.activity_groups end,
    activity_group_scheme = case when v_patch ? 'activity_group_scheme' then v_patch->>'activity_group_scheme' else m.activity_group_scheme end,
    resistance_classification_state = case when v_patch ? 'resistance_classification_state' then v_patch->>'resistance_classification_state' else m.resistance_classification_state end,
    viticulture_rates = case when v_patch ? 'viticulture_rates' then v_patch->'viticulture_rates' else m.viticulture_rates end,
    label_rate_bases = case when v_patch ? 'label_rate_bases' then
      (select coalesce(array_agg(t.v),'{}'::text[]) from jsonb_array_elements_text(v_patch->'label_rate_bases') t(v)) else m.label_rate_bases end,
    verification_status = case when v_patch ? 'verification_status' then v_patch->>'verification_status' else m.verification_status end,
    verification_sources = case when v_patch ? 'verification_sources' then nullif(v_patch->'verification_sources','null'::jsonb) else m.verification_sources end,
    verification_conflicts = case when v_patch ? 'verification_conflicts' then nullif(v_patch->'verification_conflicts','null'::jsonb) else m.verification_conflicts end,
    verification_unresolved_fields = case when v_patch ? 'verification_unresolved_fields' then
      case when jsonb_typeof(v_patch->'verification_unresolved_fields') = 'null' then null
      else (select coalesce(array_agg(t.v),'{}'::text[]) from jsonb_array_elements_text(v_patch->'verification_unresolved_fields') t(v)) end
      else m.verification_unresolved_fields end,
    retrieved_at = case when v_patch ? 'retrieved_at' then nullif(v_patch->>'retrieved_at','')::timestamptz else m.retrieved_at end,
    source_kind = case when v_patch ? 'source_kind' then v_patch->>'source_kind' else m.source_kind end,
    source_reference = case when v_patch ? 'source_reference' then v_patch->>'source_reference' else m.source_reference end
  where m.id = p_master_id;
  select catalogue_version into v_result_revision from public.master_chemicals where id = p_master_id;
  insert into public.master_chemical_review_actions
    (id,master_chemical_id,action,preview_id,base_revision,result_revision,patch,reason,performed_by)
  values (v_action_id,p_master_id,'refresh_apply',p_preview_id,v_preview.base_revision,v_result_revision,v_patch,p_reason,auth.uid());
  update public.master_review_previews set consumed_at = now(),consumed_action_id = v_action_id where id = p_preview_id;
  return jsonb_build_object('status','applied','master_chemical_id',p_master_id,
    'base_revision',v_preview.base_revision,'result_revision',v_result_revision,'action_id',v_action_id);
end$$;
revoke all on function public.master_review_apply(uuid,uuid,text) from public;
grant execute on function public.master_review_apply(uuid,uuid,text) to authenticated;
comment on function public.master_review_apply(uuid,uuid,text) is
  'Audited admin-only application of a server-stored, expiring CAS preview; structured enrichment fields are validated on store and apply. Identity and review status never change.';
-- SQL 238's revision comparator predates SQL 210's resistance state. Include it
-- so even a state-only enrichment produces a normal version/history entry.
create or replace function public.master_chemicals_before_write()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.catalogue_version := 1;
    new.created_at := now();
    new.updated_at := now();
    return new;
  end if;
  new.id := old.id;
  new.created_at := old.created_at;
  new.updated_at := now();
  if (new.registration_country, new.registration_scheme,
      new.registration_number, new.registrant,
      new.registered_product_name, new.product_category,
      new.form_type, new.active_ingredients,
      new.activity_groups, new.activity_group_scheme,
      new.resistance_classification_state,
      new.registered_uses, new.viticulture_rates, new.label_rate_bases,
      new.label_reference, new.label_version,
      new.verification_status, new.verification_sources,
      new.verification_conflicts, new.verification_unresolved_fields,
      new.verified_at, new.activity_group_table_version,
      new.intelligence_schema_version)
     is distinct from
     (old.registration_country, old.registration_scheme,
      old.registration_number, old.registrant,
      old.registered_product_name, old.product_category,
      old.form_type, old.active_ingredients,
      old.activity_groups, old.activity_group_scheme,
      old.resistance_classification_state,
      old.registered_uses, old.viticulture_rates, old.label_rate_bases,
      old.label_reference, old.label_version,
      old.verification_status, old.verification_sources,
      old.verification_conflicts, old.verification_unresolved_fields,
      old.verified_at, old.activity_group_table_version,
      old.intelligence_schema_version) then
    new.catalogue_version := old.catalogue_version + 1;
  else
    new.catalogue_version := old.catalogue_version;
  end if;
  return new;
end$$;

-- Read-only live baseline; uses the same predicates as search, not a guessed client copy.
create or replace function public.master_backfill_catalogue_stats_v2() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not public.is_system_admin() then raise exception 'not_authorised' using errcode = '42501'; end if;
  select jsonb_build_object(
    'total', count(*),
    'au', count(*) filter (where m.registration_country='AU'),
    'approved', count(*) filter (where m.review_status='approved'),
    'candidate', count(*) filter (where m.review_status='candidate'),
    'v2_eligible', count(*) filter (where public.master_chemical_is_v2_eligible(m)),
    'v2_searchable', count(*) filter (where public.master_chemical_is_v2_eligible(m) and public.master_chemical_has_viticulture_evidence(m)),
    'searchable_rates_resolved', count(*) filter (where public.master_chemical_is_v2_eligible(m) and public.master_chemical_has_viticulture_evidence(m)
      and (jsonb_array_length(coalesce(m.viticulture_rates->'per_hectare','[]'::jsonb)) > 0 or jsonb_array_length(coalesce(m.viticulture_rates->'per_100_litres','[]'::jsonb)) > 0)
      and m.resistance_classification_state in ('classified','not_applicable')),
    'classified', count(*) filter (where m.resistance_classification_state = 'classified'),
    'not_applicable', count(*) filter (where m.resistance_classification_state = 'not_applicable'),
    'unresolved', count(*) filter (where m.resistance_classification_state = 'unresolved'),
    'crop_protection_missing_group', count(*) filter (where m.product_category ~* '(fungicide|herbicide|insecticide|miticide)' and cardinality(m.activity_groups) = 0),
    'vineyard_use_records', count(*) filter (where exists (select 1 from jsonb_array_elements(coalesce(m.registered_uses,'[]'::jsonb)) u where lower(coalesce(u->>'crop','')) ~ '(grape|vineyard|vine)')),
    'viticulture_rates_records', count(*) filter (where jsonb_array_length(coalesce(m.viticulture_rates->'per_hectare','[]'::jsonb)) > 0 or jsonb_array_length(coalesce(m.viticulture_rates->'per_100_litres','[]'::jsonb)) > 0)
  ) into v_result from public.master_chemicals m;
  return v_result;
end$$;
revoke all on function public.master_backfill_catalogue_stats_v2() from public, anon;
grant execute on function public.master_backfill_catalogue_stats_v2() to authenticated;
commit;
