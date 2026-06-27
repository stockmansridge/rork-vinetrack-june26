-- 064_soil_profiles_and_irrigation_soil.sql
--
-- Phase 1 of the soil-aware irrigation model.
--
-- Adds two tables and a small RPC surface so iOS and Lovable can share a
-- single per-paddock soil profile used by the Irrigation Advisor:
--
--   public.soil_class_defaults    - global reference values per irrigation
--                                   soil class (read-only on the client)
--   public.paddock_soil_profiles  - one row per paddock with the active
--                                   soil profile (manual or, in Phase 2,
--                                   NSW SEED auto-fill)
--
-- Source provider is intentionally a free-form text column so Phase 2 can
-- add nsw_seed and future providers (nz_smap, usda_ssurgo, vic_soil,
-- sa_soil) without a schema change. A model_version column lets us bump
-- AWC defaults / mapping logic / irrigation formulas safely later on.
--
-- All client access is funneled through SECURITY DEFINER RPCs that gate
-- on public.is_vineyard_member / public.has_vineyard_role.

-- =========================================================================
-- soil_class_defaults
-- =========================================================================

create table if not exists public.soil_class_defaults (
    irrigation_soil_class           text primary key,
    label                           text not null,
    description                     text,
    default_awc_min_mm_per_m        numeric(6,2),
    default_awc_max_mm_per_m        numeric(6,2),
    default_awc_mm_per_m            numeric(6,2) not null,
    default_allowed_depletion_percent numeric(5,2) not null default 45,
    default_root_depth_m            numeric(4,2) not null default 0.60,
    infiltration_risk               text,
    drainage_risk                   text,
    waterlogging_risk               text,
    sort_order                      int not null default 100,
    created_at                      timestamptz not null default now(),
    updated_at                      timestamptz not null default now()
);

alter table public.soil_class_defaults enable row level security;

drop policy if exists soil_class_defaults_select on public.soil_class_defaults;
create policy soil_class_defaults_select on public.soil_class_defaults
    for select to authenticated
    using (true);

-- Seed defaults. Use UPSERT so re-running the migration keeps values in
-- sync without duplicating rows.
insert into public.soil_class_defaults (
    irrigation_soil_class, label, description,
    default_awc_min_mm_per_m, default_awc_max_mm_per_m, default_awc_mm_per_m,
    default_allowed_depletion_percent, default_root_depth_m,
    infiltration_risk, drainage_risk, waterlogging_risk, sort_order
) values
    ('sand_loamy_sand',   'Sand / loamy sand',   'Coarse textured soils with low water holding capacity.', 50,  100, 75,  40, 0.50, 'high',    'high',     'low',      10),
    ('sandy_loam',        'Sandy loam',          'Light textured soils with moderate water holding.',     90,  130, 110, 45, 0.55, 'moderate','moderate', 'low',      20),
    ('loam',              'Loam',                'Balanced loam with good water holding and drainage.',   130, 170, 150, 50, 0.60, 'moderate','moderate', 'low',      30),
    ('silt_loam',         'Silt loam',           'Silt loam with high water holding capacity.',           170, 210, 190, 50, 0.60, 'moderate','moderate', 'moderate', 40),
    ('clay_loam',         'Clay loam',           'Heavier loam with good water holding, slower drainage.',150, 180, 165, 50, 0.60, 'moderate','moderate', 'moderate', 50),
    ('clay_heavy_clay',   'Clay / heavy clay',   'Heavy clay with high holding but poor drainage.',       130, 170, 150, 50, 0.55, 'low',     'low',      'high',     60),
    ('basalt_clay_loam',  'Basalt clay loam',    'Basalt-derived clay loam, well structured.',            150, 190, 170, 50, 0.60, 'moderate','moderate', 'moderate', 70),
    ('shallow_rocky',     'Shallow / rocky',     'Shallow rocky soils with limited root zone.',           60,  100, 80,  40, 0.35, 'high',    'high',     'low',      80),
    ('unknown',           'Unknown',             'Use as a fallback when texture is not yet known.',      100, 150, 120, 45, 0.55, 'moderate','moderate', 'moderate', 999)
on conflict (irrigation_soil_class) do update
    set label                              = excluded.label,
        description                        = excluded.description,
        default_awc_min_mm_per_m           = excluded.default_awc_min_mm_per_m,
        default_awc_max_mm_per_m           = excluded.default_awc_max_mm_per_m,
        default_awc_mm_per_m               = excluded.default_awc_mm_per_m,
        default_allowed_depletion_percent  = excluded.default_allowed_depletion_percent,
        default_root_depth_m               = excluded.default_root_depth_m,
        infiltration_risk                  = excluded.infiltration_risk,
        drainage_risk                      = excluded.drainage_risk,
        waterlogging_risk                  = excluded.waterlogging_risk,
        sort_order                         = excluded.sort_order,
        updated_at                         = now();

-- =========================================================================
-- paddock_soil_profiles
-- =========================================================================

create table if not exists public.paddock_soil_profiles (
    id                                 uuid primary key default gen_random_uuid(),
    vineyard_id                        uuid not null references public.vineyards(id) on delete cascade,
    paddock_id                         uuid not null references public.paddocks(id) on delete cascade,

    -- Provenance / versioning
    source                             text not null default 'manual',
        -- "manual" | "nsw_seed" | "imported" | "default" | ...
    source_provider                    text,
        -- free-form e.g. nsw_seed, nz_smap, usda_ssurgo, vic_soil, sa_soil
    source_dataset                     text,
    source_feature_id                  text,
    source_name                        text,
    model_version                      text not null default 'soil_aware_irrigation_v1',

    -- Geo context
    country_code                       text,
    region_code                        text,
    lookup_latitude                    double precision,
    lookup_longitude                   double precision,

    -- Soil description (free text / classification)
    soil_landscape                     text,
    soil_description                   text,
    soil_texture_class                 text,
    irrigation_soil_class              text
        references public.soil_class_defaults(irrigation_soil_class)
        on update cascade,

    -- Irrigation-relevant numbers (canonical metric storage)
    available_water_capacity_mm_per_m  numeric(6,2),
    effective_root_depth_m             numeric(4,2),
    management_allowed_depletion_percent numeric(5,2),

    -- Risk descriptors
    infiltration_risk                  text,
    drainage_risk                      text,
    waterlogging_risk                  text,

    -- Confidence + overrides
    confidence                         text,        -- "high" | "moderate" | "low" | null
    is_manual_override                 boolean not null default false,
    manual_notes                       text,

    -- Diagnostics
    raw_source_json                    jsonb,

    -- Audit
    created_at                         timestamptz not null default now(),
    updated_at                         timestamptz not null default now(),
    updated_by                         uuid references auth.users(id) on delete set null,

    unique (paddock_id)
);

create index if not exists paddock_soil_profiles_vineyard_idx
    on public.paddock_soil_profiles(vineyard_id);
create index if not exists paddock_soil_profiles_paddock_idx
    on public.paddock_soil_profiles(paddock_id);

drop trigger if exists trg_paddock_soil_profiles_updated_at on public.paddock_soil_profiles;
create trigger trg_paddock_soil_profiles_updated_at
    before update on public.paddock_soil_profiles
    for each row execute function public.set_updated_at();

alter table public.paddock_soil_profiles enable row level security;
-- No client SELECT / INSERT / UPDATE / DELETE policies. All access is funneled
-- through SECURITY DEFINER functions below.

-- =========================================================================
-- get_soil_class_defaults()
--   Returns the seed defaults for the irrigation soil class picker.
-- =========================================================================

create or replace function public.get_soil_class_defaults()
returns table (
    irrigation_soil_class             text,
    label                             text,
    description                       text,
    default_awc_min_mm_per_m          numeric,
    default_awc_max_mm_per_m          numeric,
    default_awc_mm_per_m              numeric,
    default_allowed_depletion_percent numeric,
    default_root_depth_m              numeric,
    infiltration_risk                 text,
    drainage_risk                     text,
    waterlogging_risk                 text,
    sort_order                        int
)
language sql
stable
security definer
set search_path = public
as $$
    select scd.irrigation_soil_class,
           scd.label,
           scd.description,
           scd.default_awc_min_mm_per_m,
           scd.default_awc_max_mm_per_m,
           scd.default_awc_mm_per_m,
           scd.default_allowed_depletion_percent,
           scd.default_root_depth_m,
           scd.infiltration_risk,
           scd.drainage_risk,
           scd.waterlogging_risk,
           scd.sort_order
      from public.soil_class_defaults scd
     order by scd.sort_order, scd.label;
$$;

grant execute on function public.get_soil_class_defaults() to authenticated;

-- =========================================================================
-- get_paddock_soil_profile(p_paddock_id)
--   Returns the current soil profile for a paddock, if any. Caller must be
--   a member of the paddock's vineyard.
-- =========================================================================

create or replace function public.get_paddock_soil_profile(p_paddock_id uuid)
returns setof public.paddock_soil_profiles
language plpgsql
stable
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

    if not public.is_vineyard_member(v_vineyard_id) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    return query
        select * from public.paddock_soil_profiles
         where paddock_id = p_paddock_id;
end$$;

grant execute on function public.get_paddock_soil_profile(uuid) to authenticated;

-- =========================================================================
-- list_vineyard_soil_profiles(p_vineyard_id)
--   Returns every paddock soil profile for a vineyard. Caller must be a
--   member of the vineyard.
-- =========================================================================

create or replace function public.list_vineyard_soil_profiles(p_vineyard_id uuid)
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
         where vineyard_id = p_vineyard_id;
end$$;

grant execute on function public.list_vineyard_soil_profiles(uuid) to authenticated;

-- =========================================================================
-- upsert_paddock_soil_profile
--   Manual editor save path. Owner / manager only. Stamps source = 'manual'
--   when called without an explicit source.
-- =========================================================================

create or replace function public.upsert_paddock_soil_profile(
    p_paddock_id                          uuid,
    p_irrigation_soil_class               text,
    p_available_water_capacity_mm_per_m   numeric,
    p_effective_root_depth_m              numeric,
    p_management_allowed_depletion_percent numeric,
    p_soil_landscape                      text default null,
    p_soil_description                    text default null,
    p_soil_texture_class                  text default null,
    p_infiltration_risk                   text default null,
    p_drainage_risk                       text default null,
    p_waterlogging_risk                   text default null,
    p_confidence                          text default null,
    p_is_manual_override                  boolean default true,
    p_manual_notes                        text default null,
    p_source                              text default 'manual',
    p_source_provider                     text default null,
    p_source_dataset                      text default null,
    p_source_feature_id                   text default null,
    p_source_name                         text default null,
    p_country_code                        text default null,
    p_region_code                         text default null,
    p_lookup_latitude                     double precision default null,
    p_lookup_longitude                    double precision default null,
    p_raw_source_json                     jsonb default null,
    p_model_version                       text default 'soil_aware_irrigation_v1'
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

    -- Validate soil class exists if provided.
    if p_irrigation_soil_class is not null then
        perform 1 from public.soil_class_defaults
                 where irrigation_soil_class = p_irrigation_soil_class;
        if not found then
            raise exception 'invalid_irrigation_soil_class' using errcode = '22023';
        end if;
    end if;

    -- Clamp ranges defensively.
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
        soil_landscape, soil_description, soil_texture_class, irrigation_soil_class,
        available_water_capacity_mm_per_m, effective_root_depth_m,
        management_allowed_depletion_percent,
        infiltration_risk, drainage_risk, waterlogging_risk,
        confidence, is_manual_override, manual_notes,
        raw_source_json, updated_by
    ) values (
        v_vineyard_id, p_paddock_id,
        coalesce(p_source, 'manual'), p_source_provider, p_source_dataset,
        p_source_feature_id, p_source_name,
        coalesce(p_model_version, 'soil_aware_irrigation_v1'),
        p_country_code, p_region_code, p_lookup_latitude, p_lookup_longitude,
        p_soil_landscape, p_soil_description, p_soil_texture_class,
        p_irrigation_soil_class,
        p_available_water_capacity_mm_per_m, p_effective_root_depth_m,
        p_management_allowed_depletion_percent,
        p_infiltration_risk, p_drainage_risk, p_waterlogging_risk,
        p_confidence, coalesce(p_is_manual_override, true), p_manual_notes,
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
    double precision, double precision, jsonb, text
) to authenticated;

-- =========================================================================
-- delete_paddock_soil_profile(p_paddock_id)
--   Owner / manager only. Hard delete is fine: the paddock soil profile is
--   a single mutable row, not a historical log.
-- =========================================================================

create or replace function public.delete_paddock_soil_profile(p_paddock_id uuid)
returns void
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

    delete from public.paddock_soil_profiles
     where paddock_id = p_paddock_id;
end$$;

grant execute on function public.delete_paddock_soil_profile(uuid) to authenticated;
