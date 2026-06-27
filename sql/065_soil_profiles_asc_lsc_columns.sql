-- 065_soil_profiles_asc_lsc_columns.sql
--
-- Phase 2 follow-up — surface Soils Near Me classification fields on the
-- shared paddock soil profile so iOS, Lovable and any future client can
-- query / display them directly without parsing raw_source_json.
--
-- Adds:
--   * australian_soil_classification        text   (e.g. "Ferrosols")
--   * australian_soil_classification_code   text   (ASRIS/ASC code if any)
--   * land_soil_capability                  text   (e.g. "High capability land")
--   * land_soil_capability_class            int    (NSW LSC most-limiting 1–8)
--   * soil_landscape_code                   text   (SALIS / landscape code)
--
-- The existing `soil_landscape` column keeps the NAME field; SALIS code
-- gets its own column so portal queries can filter by code reliably.
--
-- The upsert RPC is replaced (drop + create) so iOS and Lovable can
-- write/read these new fields. SECURITY DEFINER + has_vineyard_role
-- gating is preserved exactly as in migration 064.

-- =========================================================================
-- New columns
-- =========================================================================

alter table public.paddock_soil_profiles
    add column if not exists australian_soil_classification       text,
    add column if not exists australian_soil_classification_code  text,
    add column if not exists land_soil_capability                 text,
    add column if not exists land_soil_capability_class           integer,
    add column if not exists soil_landscape_code                  text;

create index if not exists paddock_soil_profiles_asc_idx
    on public.paddock_soil_profiles (australian_soil_classification);
create index if not exists paddock_soil_profiles_landscape_code_idx
    on public.paddock_soil_profiles (soil_landscape_code);

-- =========================================================================
-- upsert_paddock_soil_profile (v2)
--
-- New params (all default null so existing callers keep working):
--   p_australian_soil_classification
--   p_australian_soil_classification_code
--   p_land_soil_capability
--   p_land_soil_capability_class
--   p_soil_landscape_code
-- =========================================================================

drop function if exists public.upsert_paddock_soil_profile(
    uuid, text, numeric, numeric, numeric,
    text, text, text, text, text, text, text, boolean, text,
    text, text, text, text, text, text, text,
    double precision, double precision, jsonb, text
);

create or replace function public.upsert_paddock_soil_profile(
    p_paddock_id                                  uuid,
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
declare
    v_vineyard_id uuid;
begin
    if p_paddock_id is null then
        raise exception 'paddock_id_required' using errcode = '22023';
    end if;

    select p.vineyard_id into v_vineyard_id
      from public.paddocks p
     where p.id = p_paddock_id;

    if v_vineyard_id is null then
        raise exception 'paddock_not_found' using errcode = 'P0002';
    end if;

    if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
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

    insert into public.paddock_soil_profiles as psp (
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
        v_vineyard_id, p_paddock_id,
        coalesce(p_source, 'manual'), p_source_provider, p_source_dataset,
        p_source_feature_id, p_source_name,
        coalesce(p_model_version, 'soil_aware_irrigation_v2'),
        p_country_code, p_region_code, p_lookup_latitude, p_lookup_longitude,
        p_soil_landscape, p_soil_landscape_code,
        p_soil_description, p_soil_texture_class,
        p_irrigation_soil_class,
        p_available_water_capacity_mm_per_m, p_effective_root_depth_m,
        p_management_allowed_depletion_percent,
        p_infiltration_risk, p_drainage_risk, p_waterlogging_risk,
        p_confidence, coalesce(p_is_manual_override, true), p_manual_notes,
        p_australian_soil_classification, p_australian_soil_classification_code,
        p_land_soil_capability, p_land_soil_capability_class,
        p_raw_source_json, auth.uid()
    )
    on conflict (paddock_id) do update
        set source                                = excluded.source,
            source_provider                       = excluded.source_provider,
            source_dataset                        = excluded.source_dataset,
            source_feature_id                     = excluded.source_feature_id,
            source_name                           = excluded.source_name,
            model_version                         = excluded.model_version,
            country_code                          = excluded.country_code,
            region_code                           = excluded.region_code,
            lookup_latitude                       = excluded.lookup_latitude,
            lookup_longitude                      = excluded.lookup_longitude,
            soil_landscape                        = excluded.soil_landscape,
            soil_landscape_code                   = excluded.soil_landscape_code,
            soil_description                      = excluded.soil_description,
            soil_texture_class                    = excluded.soil_texture_class,
            irrigation_soil_class                 = excluded.irrigation_soil_class,
            available_water_capacity_mm_per_m     = excluded.available_water_capacity_mm_per_m,
            effective_root_depth_m                = excluded.effective_root_depth_m,
            management_allowed_depletion_percent  = excluded.management_allowed_depletion_percent,
            infiltration_risk                     = excluded.infiltration_risk,
            drainage_risk                         = excluded.drainage_risk,
            waterlogging_risk                     = excluded.waterlogging_risk,
            confidence                            = excluded.confidence,
            is_manual_override                    = excluded.is_manual_override,
            manual_notes                          = excluded.manual_notes,
            australian_soil_classification        = excluded.australian_soil_classification,
            australian_soil_classification_code   = excluded.australian_soil_classification_code,
            land_soil_capability                  = excluded.land_soil_capability,
            land_soil_capability_class            = excluded.land_soil_capability_class,
            raw_source_json                       = excluded.raw_source_json,
            updated_by                            = auth.uid();

    return query
        select * from public.paddock_soil_profiles
         where paddock_id = p_paddock_id;
end$$;

grant execute on function public.upsert_paddock_soil_profile(
    uuid, text, numeric, numeric, numeric,
    text, text, text, text, text, text, text, boolean, text,
    text, text, text, text, text, text, text,
    double precision, double precision, jsonb, text,
    text, text, text, integer, text
) to authenticated;
