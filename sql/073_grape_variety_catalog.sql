-- 073_grape_variety_catalog.sql
--
-- Shared Supabase grape variety catalogue.
--
-- Architecture
-- ============
--   public.grape_variety_catalog        -- global built-in catalogue (source of truth)
--   public.vineyard_grape_varieties     -- vineyard-scoped selections + custom varieties
--
--   iOS + Lovable are CONSUMERS: they read via RPCs, cache locally, and
--   fall back to their hardcoded `BuiltInGrapeVarietyCatalog` only when
--   Supabase is unreachable.
--
-- Stable keys
-- ===========
--   * Built-in keys are global and immutable, e.g.:
--       `pinot_gris`, `sauvignon_blanc`, `shiraz`.
--   * Custom keys are vineyard-scoped and use the form:
--       `custom:<vineyard_id>:<slug>`
--     where `<slug>` is the lowercase ASCII slug of the user-supplied name.
--   * Paddock allocation JSON carries `varietyKey` (see migration 072) so
--     resolution is stable across devices, app reinstalls, and id drift.
--
-- This migration is idempotent. Re-running it is safe.

set search_path = public;


-- =========================================================================
-- Table: public.grape_variety_catalog
-- =========================================================================
create table if not exists public.grape_variety_catalog (
    key             text primary key,
    canonical_name  text not null,
    display_name    text not null,
    aliases         jsonb not null default '[]'::jsonb,
    optimal_gdd     numeric,
    is_builtin      boolean not null default true,
    is_active       boolean not null default true,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

create index if not exists grape_variety_catalog_active_idx
    on public.grape_variety_catalog (is_active);


-- =========================================================================
-- Table: public.vineyard_grape_varieties
-- =========================================================================
create table if not exists public.vineyard_grape_varieties (
    id                    uuid primary key default gen_random_uuid(),
    vineyard_id           uuid not null references public.vineyards(id) on delete cascade,
    variety_key           text not null,
    display_name          text not null,
    is_custom             boolean not null default false,
    is_active             boolean not null default true,
    optimal_gdd_override  numeric,
    created_at            timestamptz not null default now(),
    updated_at            timestamptz not null default now(),
    unique (vineyard_id, variety_key)
);

create index if not exists vineyard_grape_varieties_vineyard_idx
    on public.vineyard_grape_varieties (vineyard_id);

create index if not exists vineyard_grape_varieties_active_idx
    on public.vineyard_grape_varieties (vineyard_id, is_active);


-- =========================================================================
-- updated_at triggers
-- =========================================================================
create or replace function public._grape_variety_catalog_touch()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    return new;
end$$;

drop trigger if exists trg_grape_variety_catalog_touch on public.grape_variety_catalog;
create trigger trg_grape_variety_catalog_touch
    before update on public.grape_variety_catalog
    for each row execute function public._grape_variety_catalog_touch();

drop trigger if exists trg_vineyard_grape_varieties_touch on public.vineyard_grape_varieties;
create trigger trg_vineyard_grape_varieties_touch
    before update on public.vineyard_grape_varieties
    for each row execute function public._grape_variety_catalog_touch();


-- =========================================================================
-- Seed: 26 built-in varieties (mirrors iOS BuiltInGrapeVarietyCatalog and
-- the SQL _variety_catalog_keys()/_variety_catalog_match() helpers).
-- =========================================================================
insert into public.grape_variety_catalog
    (key, canonical_name, display_name, aliases, optimal_gdd, is_builtin, is_active)
values
    ('chardonnay',          'Chardonnay',           'Chardonnay',            '[]'::jsonb,                                                                          1145, true, true),
    ('pinot_gris',          'Pinot Gris',           'Pinot Gris / Grigio',   '["Pinot Gris","Pinot Grigio","Pinot Gris / Grigio"]'::jsonb,                         1100, true, true),
    ('riesling',            'Riesling',             'Riesling',              '[]'::jsonb,                                                                          1200, true, true),
    ('sauvignon_blanc',     'Sauvignon Blanc',      'Sauvignon Blanc',       '["Sauv Blanc","Sav Blanc","Savvy B"]'::jsonb,                                       1150, true, true),
    ('semillon',            'Semillon',             'Semillon',              '["Sémillon"]'::jsonb,                                                                1200, true, true),
    ('chenin_blanc',        'Chenin Blanc',         'Chenin Blanc',          '[]'::jsonb,                                                                          1250, true, true),
    ('gewurztraminer',      'Gewurztraminer',       'Gewurztraminer',        '["Gewürztraminer"]'::jsonb,                                                          1150, true, true),
    ('viognier',            'Viognier',             'Viognier',              '[]'::jsonb,                                                                          1260, true, true),
    ('shiraz',              'Shiraz',               'Shiraz',                '["Syrah"]'::jsonb,                                                                   1255, true, true),
    ('merlot',              'Merlot',               'Merlot',                '[]'::jsonb,                                                                          1250, true, true),
    ('cabernet_franc',      'Cabernet Franc',       'Cabernet Franc',        '["Cab Franc"]'::jsonb,                                                               1255, true, true),
    ('cabernet_sauvignon',  'Cabernet Sauvignon',   'Cabernet Sauvignon',    '["Cab Sav","Cab Sauv"]'::jsonb,                                                      1310, true, true),
    ('pinot_noir',          'Pinot Noir',           'Pinot Noir',            '[]'::jsonb,                                                                          1145, true, true),
    ('tempranillo',         'Tempranillo',          'Tempranillo',           '[]'::jsonb,                                                                          1230, true, true),
    ('sangiovese',          'Sangiovese',           'Sangiovese',            '[]'::jsonb,                                                                          1285, true, true),
    ('grenache',            'Grenache',             'Grenache',              '["Garnacha"]'::jsonb,                                                                1365, true, true),
    ('mataro_mourvedre',    'Mataro / Mourvedre',   'Mataro / Mourvedre',    '["Mataro","Mourvedre","Mourvèdre","Monastrell"]'::jsonb,                             1440, true, true),
    ('barbera',             'Barbera',              'Barbera',               '[]'::jsonb,                                                                          1285, true, true),
    ('malbec',              'Malbec',               'Malbec',                '[]'::jsonb,                                                                          1230, true, true),
    ('colombard',           'Colombard',            'Colombard',             '[]'::jsonb,                                                                          1300, true, true),
    ('muscat_gordo_blanco', 'Muscat Gordo Blanco',  'Muscat Gordo Blanco',   '["Muscat Gordo","Muscat of Alexandria"]'::jsonb,                                     1350, true, true),
    ('fiano',               'Fiano',                'Fiano',                 '[]'::jsonb,                                                                          1320, true, true),
    ('prosecco',            'Prosecco',             'Prosecco',              '["Glera"]'::jsonb,                                                                   1410, true, true),
    ('vermentino',          'Vermentino',           'Vermentino',            '[]'::jsonb,                                                                          1290, true, true),
    ('gruner_veltliner',    'Gruner Veltliner',     'Gruner Veltliner',      '["Grüner Veltliner","Gruner"]'::jsonb,                                               1200, true, true),
    ('primitivo',           'Primitivo',            'Primitivo',             '["Zinfandel"]'::jsonb,                                                               1200, true, true)
on conflict (key) do update
    set canonical_name = excluded.canonical_name,
        display_name   = excluded.display_name,
        aliases        = excluded.aliases,
        optimal_gdd    = excluded.optimal_gdd,
        is_builtin     = excluded.is_builtin,
        is_active      = true,
        updated_at     = now();


-- =========================================================================
-- Helper: slugify a free-form name into a stable ascii slug suitable for a
-- vineyard-scoped custom key suffix.
-- =========================================================================
create or replace function public._grape_variety_slugify(p_name text)
returns text
language plpgsql
immutable
as $$
declare
    v text;
begin
    if p_name is null then
        return null;
    end if;

    v := lower(trim(p_name));

    -- Replace common accented letters with their ASCII counterpart.
    v := translate(
        v,
        'àáâãäåāăąçćčďèéêëēĕėęěğìíîïīĭįıłñńņňòóôõöøōŏőŕřśşšťùúûüūŭůűųýÿžźżđ',
        'aaaaaaaaacccdeeeeeeeegiiiiiiiilnnnnoooooooooooorrsssstuuuuuuuuuyyzzzd'
    );

    -- Replace anything not a-z/0-9 with `_`.
    v := regexp_replace(v, '[^a-z0-9]+', '_', 'g');
    v := regexp_replace(v, '^_+|_+$', '', 'g');
    if v is null or length(v) = 0 then
        return null;
    end if;
    return v;
end$$;

grant execute on function public._grape_variety_slugify(text) to authenticated;


-- =========================================================================
-- Helper: build a vineyard-scoped custom variety key.
--   custom:<vineyard_id>:<slug>
-- =========================================================================
create or replace function public._grape_variety_custom_key(
    p_vineyard_id uuid,
    p_name        text
)
returns text
language plpgsql
immutable
as $$
declare
    v_slug text;
begin
    if p_vineyard_id is null then
        return null;
    end if;
    v_slug := public._grape_variety_slugify(p_name);
    if v_slug is null then
        return null;
    end if;
    return 'custom:' || p_vineyard_id::text || ':' || v_slug;
end$$;

grant execute on function public._grape_variety_custom_key(uuid, text) to authenticated;


-- =========================================================================
-- RLS
-- =========================================================================
alter table public.grape_variety_catalog    enable row level security;
alter table public.vineyard_grape_varieties enable row level security;

-- Catalog is readable by any authenticated user.
drop policy if exists grape_variety_catalog_read on public.grape_variety_catalog;
create policy grape_variety_catalog_read
    on public.grape_variety_catalog
    for select
    to authenticated
    using (true);

-- Catalog writes are restricted to system admins. (Direct writes are rare;
-- the seed in this migration handles built-ins.)
drop policy if exists grape_variety_catalog_admin_write on public.grape_variety_catalog;
create policy grape_variety_catalog_admin_write
    on public.grape_variety_catalog
    for all
    to authenticated
    using (public.is_system_admin())
    with check (public.is_system_admin());

-- Vineyard varieties: members can read; owners/managers can write.
drop policy if exists vineyard_grape_varieties_read on public.vineyard_grape_varieties;
create policy vineyard_grape_varieties_read
    on public.vineyard_grape_varieties
    for select
    to authenticated
    using (public.is_vineyard_member(vineyard_id));

drop policy if exists vineyard_grape_varieties_insert on public.vineyard_grape_varieties;
create policy vineyard_grape_varieties_insert
    on public.vineyard_grape_varieties
    for insert
    to authenticated
    with check (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists vineyard_grape_varieties_update on public.vineyard_grape_varieties;
create policy vineyard_grape_varieties_update
    on public.vineyard_grape_varieties
    for update
    to authenticated
    using (public.has_vineyard_role(vineyard_id, array['owner','manager']))
    with check (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists vineyard_grape_varieties_delete on public.vineyard_grape_varieties;
create policy vineyard_grape_varieties_delete
    on public.vineyard_grape_varieties
    for delete
    to authenticated
    using (public.has_vineyard_role(vineyard_id, array['owner','manager']));


-- =========================================================================
-- RPC: get_grape_variety_catalog()
-- =========================================================================
-- Returns the active built-in catalog. Any authenticated user can read.

drop function if exists public.get_grape_variety_catalog();

create or replace function public.get_grape_variety_catalog()
returns table(
    key             text,
    canonical_name  text,
    display_name    text,
    aliases         jsonb,
    optimal_gdd     numeric,
    is_builtin      boolean,
    is_active       boolean,
    updated_at      timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select c.key,
           c.canonical_name,
           c.display_name,
           c.aliases,
           c.optimal_gdd,
           c.is_builtin,
           c.is_active,
           c.updated_at
      from public.grape_variety_catalog c
     where c.is_active = true
     order by c.display_name;
$$;

grant execute on function public.get_grape_variety_catalog() to authenticated;


-- =========================================================================
-- RPC: list_vineyard_grape_varieties(p_vineyard_id)
-- =========================================================================
-- Returns vineyard-scoped variety selections. Caller must be a member.

drop function if exists public.list_vineyard_grape_varieties(uuid);

create or replace function public.list_vineyard_grape_varieties(p_vineyard_id uuid)
returns table(
    id                    uuid,
    vineyard_id           uuid,
    variety_key           text,
    display_name          text,
    is_custom             boolean,
    is_active             boolean,
    optimal_gdd_override  numeric,
    created_at            timestamptz,
    updated_at            timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if p_vineyard_id is null then
        raise exception 'missing_vineyard_id' using errcode = '22023';
    end if;
    if not public.is_vineyard_member(p_vineyard_id) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    return query
        select v.id, v.vineyard_id, v.variety_key, v.display_name,
               v.is_custom, v.is_active, v.optimal_gdd_override,
               v.created_at, v.updated_at
          from public.vineyard_grape_varieties v
         where v.vineyard_id = p_vineyard_id
         order by v.display_name;
end$$;

grant execute on function public.list_vineyard_grape_varieties(uuid) to authenticated;


-- =========================================================================
-- RPC: upsert_vineyard_grape_variety(...)
-- =========================================================================
-- Upserts a vineyard-scoped variety selection. Built-ins must pass an
-- existing catalog key in `p_variety_key`. Custom varieties pass
-- `p_variety_key = null` and a display name; the function derives a
-- stable `custom:<vineyard>:<slug>` key.

drop function if exists public.upsert_vineyard_grape_variety(uuid, text, text, numeric);
drop function if exists public.upsert_vineyard_grape_variety(uuid, text, text, numeric, boolean);

create or replace function public.upsert_vineyard_grape_variety(
    p_vineyard_id          uuid,
    p_variety_key          text,
    p_display_name         text,
    p_optimal_gdd_override numeric default null,
    p_is_active            boolean default true
)
returns public.vineyard_grape_varieties
language plpgsql
security definer
set search_path = public
as $$
declare
    v_key          text;
    v_is_custom    boolean;
    v_display_name text;
    v_row          public.vineyard_grape_varieties;
    v_catalog      record;
begin
    if p_vineyard_id is null then
        raise exception 'missing_vineyard_id' using errcode = '22023';
    end if;
    if not public.has_vineyard_role(p_vineyard_id, array['owner','manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    v_display_name := nullif(trim(coalesce(p_display_name, '')), '');
    v_key          := nullif(trim(coalesce(p_variety_key, '')), '');

    if v_key is not null and v_key not like 'custom:%' then
        -- Built-in selection: catalog key must exist + be active.
        select c.key, c.display_name
          into v_catalog
          from public.grape_variety_catalog c
         where c.key = v_key and c.is_active = true
         limit 1;
        if v_catalog.key is null then
            raise exception 'unknown_catalog_key: %', v_key using errcode = '22023';
        end if;
        v_is_custom    := false;
        v_display_name := coalesce(v_display_name, v_catalog.display_name);
    else
        -- Custom variety. Require a display name; derive a stable key.
        if v_display_name is null then
            raise exception 'missing_display_name' using errcode = '22023';
        end if;
        if v_key is null then
            v_key := public._grape_variety_custom_key(p_vineyard_id, v_display_name);
            if v_key is null then
                raise exception 'invalid_display_name' using errcode = '22023';
            end if;
        end if;
        v_is_custom := true;
    end if;

    insert into public.vineyard_grape_varieties as t
        (vineyard_id, variety_key, display_name, is_custom, is_active, optimal_gdd_override)
    values
        (p_vineyard_id, v_key, v_display_name, v_is_custom, coalesce(p_is_active, true), p_optimal_gdd_override)
    on conflict (vineyard_id, variety_key) do update
        set display_name         = excluded.display_name,
            is_active            = excluded.is_active,
            optimal_gdd_override = excluded.optimal_gdd_override,
            updated_at           = now()
    returning * into v_row;

    return v_row;
end$$;

grant execute on function public.upsert_vineyard_grape_variety(uuid, text, text, numeric, boolean)
    to authenticated;


-- =========================================================================
-- RPC: archive_vineyard_grape_variety(p_id)
-- =========================================================================
-- Soft-archives by setting is_active=false. Members keep historical references
-- (allocations still resolve by varietyKey) but the variety hides from pickers.

drop function if exists public.archive_vineyard_grape_variety(uuid);

create or replace function public.archive_vineyard_grape_variety(p_id uuid)
returns public.vineyard_grape_varieties
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row public.vineyard_grape_varieties;
begin
    if p_id is null then
        raise exception 'missing_id' using errcode = '22023';
    end if;

    select * into v_row
      from public.vineyard_grape_varieties
     where id = p_id
     limit 1;

    if v_row.id is null then
        raise exception 'not_found' using errcode = 'P0002';
    end if;

    if not public.has_vineyard_role(v_row.vineyard_id, array['owner','manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    update public.vineyard_grape_varieties
       set is_active  = false,
           updated_at = now()
     where id = p_id
    returning * into v_row;

    return v_row;
end$$;

grant execute on function public.archive_vineyard_grape_variety(uuid) to authenticated;


-- =========================================================================
-- Backfill: seed every active vineyard with the built-in catalog so that
-- listing the per-vineyard table immediately surfaces all 26 built-ins.
-- Idempotent via the unique (vineyard_id, variety_key) constraint.
-- =========================================================================
insert into public.vineyard_grape_varieties
    (vineyard_id, variety_key, display_name, is_custom, is_active, optimal_gdd_override)
select v.id, c.key, c.display_name, false, true, null
  from public.vineyards v
  cross join public.grape_variety_catalog c
 where v.deleted_at is null
   and c.is_builtin = true
   and c.is_active  = true
on conflict (vineyard_id, variety_key) do nothing;


-- =========================================================================
-- Notes for consumers (iOS + Lovable)
-- =========================================================================
-- Resolver order for paddock allocations (mirrors migration 072):
--   1. allocation.varietyKey   -> match vineyard_grape_varieties.variety_key,
--                                 then grape_variety_catalog.key
--   2. allocation.varietyId    -> match local master variety id
--   3. allocation.name         -> match grape_variety_catalog.canonical_name
--                                 OR grape_variety_catalog.aliases
--   4. _variety_catalog_match  -> alias/canonical fold
--   5. unresolved
--
-- Custom varieties:
--   * Always use `custom:<vineyard_id>:<slug>` for `variety_key`.
--   * Stored in vineyard_grape_varieties with is_custom = true.
--   * Never collide with built-in keys (no `custom:` prefix on built-ins).
--
-- New paddock allocations MUST write `varietyKey` and `name` snapshots.
