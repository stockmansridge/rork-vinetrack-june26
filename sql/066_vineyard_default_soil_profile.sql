-- 066_vineyard_default_soil_profile.sql
--
-- Allow an optional vineyard-level soil profile alongside per-paddock
-- profiles. The Irrigation Advisor's "Whole Vineyard" mode reads this
-- row when present so the user can have a single editable fallback
-- profile that covers the whole site without picking a specific block.
--
-- Schema change:
--   * paddock_id becomes nullable
--   * a partial unique index ensures only one vineyard-level row per
--     vineyard (the existing unique(paddock_id) keeps one row per
--     paddock)
--
-- New RPCs:
--   * get_vineyard_default_soil_profile(p_vineyard_id)
--   * upsert_vineyard_default_soil_profile(...)
--   * delete_vineyard_default_soil_profile(p_vineyard_id)

-- =========================================================================
-- Allow null paddock_id
-- =========================================================================

alter table public.paddock_soil_profiles
    alter column paddock_id drop not null;

-- One vineyard-level row per vineyard (paddock_id is null).
create unique index if not exists paddock_soil_profiles_vineyard_default_uniq
    on public.paddock_soil_profiles (vineyard_id)
    where paddock_id is null;

-- =========================================================================
-- get_vineyard_default_soil_profile(p_vineyard_id)
-- =========================================================================

create or replace function public.get_vineyard_default_soil_profile(p_vineyard_id uuid)
returns setof public.paddock_soil_profiles
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if p_vineyard_id is null then
        raise exception 'vineyard_id_required' using errcode = '22023';
    end if;

    if not public.is_vineyard_member(p_vineyard_id) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    return query
        select * from public.paddock_soil_profiles
         where vineyard_id = p_vineyard_id
           and paddock_id is null
         limit 1;
end$$;

grant execute on function public.get_vineyard_default_soil_profile(uuid) to authenticated;

-- =========================================================================
-- upsert_vineyard_default_soil_profile(...)
-- =========================================================================

drop function if exists public.upsert_vineyard_default_soil_profile(
    uuid, text, numeric, numeric, numeric,
    text, text, text, text, text, text, text, boolean, text,
    text, text, text, text, text, text, text,
    double precision, double precision, jsonb, text,
    text, text, text, integer, text
);

create or replace function public.upsert_vineyard_default_soil_profile(
    p_vineyard_id                                 uuid,
    p_irrigation_soil_class                       text,
    p_available_water_capacity_mm_per_m           numeric,
    p_effective_root_depth_m                      numeric,
    p_management_allowed_depletion_percent        numeric,
    p_soil_landscape                              text default null,
    p_soil_description                            text default null,
    p_soil_texture_class                          text default null,
    p_infiltration_risk                           text default null,
    p_drainage_risk                               text default null,
    p_waterlogging_risk                           text default null,
    p_confidence                                  text default null,
    p_is_manual_override                          boolean default true,
    p_manual_notes                                text default null,
    p_source                                      text default 'manual',
    p_source_provider                             text default null,
    p_source_dataset                              text default null,
    p_source_feature_id                           text default null,
    p_source_name                                 text default null,
    p_country_code                                text default null,
    p_region_code                                 text default null,
    p_lookup_latitude                             double precision default null,
    p_lookup_longitude                            double precision default null,
    p_raw_source_json                             jsonb default null,
    p_model_version                               text default 'soil_aware_irrigation_v2',
    p_australian_soil_classification              text default null,
    p_australian_soil_classification_code         text default null,
    p_land_soil_capability                        text default null,
    p_land_soil_capability_class                  integer default null,
    p_soil_landscape_code                         text default null
)
returns setof public.paddock_soil_profiles
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_vineyard_id is null then
        raise exception 'vineyard_id_required' using errcode = '22023';
    end if;

    if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    if p_irrigation_soil_class is not null then
        perform 1 from public.soil_class_defaults
                 where irrigation_soil_class = p_irrigation_soil_class;
        if not found then
            raise exception 'invalid_irrigation_soil_class' using errcode = '22023';
        end if;
    end if;

    if p_available_water_capacity_mm_per_m is not null
       and (p_available_water_capacity_mm_per_m < 0 or p_available_water_capacity_mm_per_m > 400) then
        raise exception 'invalid_awc' using errcode = '22023';
    end if;
    if p_effective_root_depth_m is not null
       and (p_effective_root_depth_m < 0 or p_effective_root_depth_m > 5) then
        raise exception 'invalid_root_depth' using errcode = '22023';
    end if;
    if p_management_allowed_depletion_percent is not null
       and (p_management_allowed_depletion_percent < 0
            or p_management_allowed_depletion_percent > 100) then
        raise exception 'invalid_allowed_depletion' using errcode = '22023';
    end if;

    -- Manual upsert keyed on (vineyard_id, paddock_id is null)
    if exists (
        select 1 from public.paddock_soil_profiles
         where vineyard_id = p_vineyard_id and paddock_id is null
    ) then
        update public.paddock_soil_profiles set
            source                                = coalesce(p_source, 'manual'),
            source_provider                       = p_source_provider,
            source_dataset                        = p_source_dataset,
            source_feature_id                     = p_source_feature_id,
            source_name                           = p_source_name,
            model_version                         = coalesce(p_model_version, 'soil_aware_irrigation_v2'),
            country_code                          = p_country_code,
            region_code                           = p_region_code,
            lookup_latitude                       = p_lookup_latitude,
            lookup_longitude                      = p_lookup_longitude,
            soil_landscape                        = p_soil_landscape,
            soil_landscape_code                   = p_soil_landscape_code,
            soil_description                      = p_soil_description,
            soil_texture_class                    = p_soil_texture_class,
            irrigation_soil_class                 = p_irrigation_soil_class,
            available_water_capacity_mm_per_m     = p_available_water_capacity_mm_per_m,
            effective_root_depth_m                = p_effective_root_depth_m,
            management_allowed_depletion_percent  = p_management_allowed_depletion_percent,
            infiltration_risk                     = p_infiltration_risk,
            drainage_risk                         = p_drainage_risk,
            waterlogging_risk                     = p_waterlogging_risk,
            confidence                            = p_confidence,
            is_manual_override                    = coalesce(p_is_manual_override, true),
            manual_notes                          = p_manual_notes,
            australian_soil_classification        = p_australian_soil_classification,
            australian_soil_classification_code   = p_australian_soil_classification_code,
            land_soil_capability                  = p_land_soil_capability,
            land_soil_capability_class            = p_land_soil_capability_class,
            raw_source_json                       = p_raw_source_json,
            updated_by                            = auth.uid()
        where vineyard_id = p_vineyard_id and paddock_id is null;
    else
        insert into public.paddock_soil_profiles (
            vineyard_id, paddock_id,
            source, source_provider, source_dataset, source_feature_id, source_name,
            model_version,
            country_code, region_code, lookup_latitude, lookup_longitude,
            soil_landscape, soil_landscape_code,
            soil_description, soil_texture_class, irrigation_soil_class,
            available_water_capacity_mm_per_m, effective_root_depth_m,
            management_allowed_depletion_percent,
            infiltration_risk, drainage_risk, waterlogging_risk,
            confidence, is_manual_override, manual_notes,
            australian_soil_classification, australian_soil_classification_code,
            land_soil_capability, land_soil_capability_class,
            raw_source_json, updated_by
        ) values (
            p_vineyard_id, null,
            coalesce(p_source, 'manual'), p_source_provider, p_source_dataset,
            p_source_feature_id, p_source_name,
            coalesce(p_model_version, 'soil_aware_irrigation_v2'),
            p_country_code, p_region_code, p_lookup_latitude, p_lookup_longitude,
            p_soil_landscape, p_soil_landscape_code,
            p_soil_description, p_soil_texture_class, p_irrigation_soil_class,
            p_available_water_capacity_mm_per_m, p_effective_root_depth_m,
            p_management_allowed_depletion_percent,
            p_infiltration_risk, p_drainage_risk, p_waterlogging_risk,
            p_confidence, coalesce(p_is_manual_override, true), p_manual_notes,
            p_australian_soil_classification, p_australian_soil_classification_code,
            p_land_soil_capability, p_land_soil_capability_class,
            p_raw_source_json, auth.uid()
        );
    end if;

    return query
        select * from public.paddock_soil_profiles
         where vineyard_id = p_vineyard_id and paddock_id is null;
end$$;

grant execute on function public.upsert_vineyard_default_soil_profile(
    uuid, text, numeric, numeric, numeric,
    text, text, text, text, text, text, text, boolean, text,
    text, text, text, text, text, text, text,
    double precision, double precision, jsonb, text,
    text, text, text, integer, text
) to authenticated;

-- =========================================================================
-- delete_vineyard_default_soil_profile(p_vineyard_id)
-- =========================================================================

create or replace function public.delete_vineyard_default_soil_profile(p_vineyard_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_vineyard_id is null then
        raise exception 'vineyard_id_required' using errcode = '22023';
    end if;

    if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    delete from public.paddock_soil_profiles
     where vineyard_id = p_vineyard_id and paddock_id is null;
end$$;

grant execute on function public.delete_vineyard_default_soil_profile(uuid) to authenticated;
