-- 067_grape_variety_canonicalization_repair.sql
--
-- Server-side grape variety repair tooling. Mirrors the iOS
-- `GrapeVarietyCanonicalization` / `BuiltInGrapeVarietyCatalog` rules so
-- paddock `variety_allocations` rows can be canonicalised, deduplicated
-- and id-remapped from SQL.
--
-- New functions:
--   * public._variety_canonical(text)
--   * public._variety_deterministic_id(uuid, text)
--   * public._variety_catalog_match(text)
--   * public.repair_grape_variety_allocations(uuid, boolean)
--
-- The repair function is idempotent — running it again after an apply
-- pass returns zero repairs/backfills/collapses for the same data.
--
-- Allocation shape in `paddocks.variety_allocations` (JSONB array):
--   [{ "id": uuid, "varietyId": uuid, "percent": number, "name": text? }, ...]
--
-- The iOS catalog (built-in slugs + aliases) is duplicated here. If new
-- built-in varieties are added to `BuiltInGrapeVarietyCatalog.entries`,
-- mirror them in `_variety_catalog_match` below — slugs MUST stay stable.

set search_path = public;

-- =========================================================================
-- _variety_canonical(text)
-- =========================================================================
-- Same rule as Swift: lowercase + strip everything that is not [a-z0-9].
-- Diacritics are NOT folded server-side (the iOS rule also doesn't fold
-- them — both rely on the alias table for accented forms like "Sémillon").

create or replace function public._variety_canonical(p_name text)
returns text
language sql
immutable
as $$
    select regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '', 'g');
$$;

-- =========================================================================
-- _variety_deterministic_id(vineyard_id, key)
-- =========================================================================
-- Reproduces `GrapeVariety.deterministicID(vineyardId:key:)`:
--   md5(uuid_bytes(vineyardId) || utf8(key))
--   bytes[6] = (b & 0x0F) | 0x50   (version 5 nibble)
--   bytes[8] = (b & 0x3F) | 0x80   (RFC 4122 variant)
-- Returns null when inputs are missing.

create or replace function public._variety_deterministic_id(
    p_vineyard_id uuid,
    p_key text
)
returns uuid
language plpgsql
immutable
as $$
declare
    v_input bytea;
    v_hash  bytea;
    v_hex   text;
begin
    if p_vineyard_id is null or p_key is null or length(p_key) = 0 then
        return null;
    end if;

    v_input := uuid_send(p_vineyard_id) || convert_to(p_key, 'UTF8');
    v_hash  := decode(md5(v_input), 'hex');
    v_hash  := set_byte(v_hash, 6, (get_byte(v_hash, 6) & 15) | 80);   -- 0x50
    v_hash  := set_byte(v_hash, 8, (get_byte(v_hash, 8) & 63) | 128);  -- 0x80

    v_hex := encode(v_hash, 'hex');
    return (
        substr(v_hex, 1, 8)  || '-' ||
        substr(v_hex, 9, 4)  || '-' ||
        substr(v_hex, 13, 4) || '-' ||
        substr(v_hex, 17, 4) || '-' ||
        substr(v_hex, 21, 12)
    )::uuid;
end$$;

-- =========================================================================
-- _variety_catalog_match(name) -> (key, name, optimal_gdd)
-- =========================================================================
-- Free-form name → built-in catalog entry, via canonical-name + alias
-- table. Returns zero rows for unknown names. Kept in lockstep with
-- `BuiltInGrapeVarietyCatalog.entries` in Swift.

create or replace function public._variety_catalog_match(p_name text)
returns table(key text, display_name text, optimal_gdd numeric)
language sql
immutable
as $$
    with catalog(key, display_name, optimal_gdd, aliases) as (
        values
            ('chardonnay',          'Chardonnay',           1145::numeric, array[]::text[]),
            ('pinot_gris',          'Pinot Gris / Grigio',  1100::numeric, array['Pinot Gris','Pinot Grigio']),
            ('riesling',            'Riesling',             1200::numeric, array[]::text[]),
            ('sauvignon_blanc',     'Sauvignon Blanc',      1150::numeric, array['Sav Blanc','Savvy B']),
            ('semillon',            'Semillon',             1200::numeric, array['Sémillon']),
            ('chenin_blanc',        'Chenin Blanc',         1250::numeric, array[]::text[]),
            ('gewurztraminer',      'Gewurztraminer',       1150::numeric, array['Gewürztraminer']),
            ('viognier',            'Viognier',             1260::numeric, array[]::text[]),
            ('shiraz',              'Shiraz',               1255::numeric, array['Syrah']),
            ('merlot',              'Merlot',               1250::numeric, array[]::text[]),
            ('cabernet_franc',      'Cabernet Franc',       1255::numeric, array['Cab Franc']),
            ('cabernet_sauvignon',  'Cabernet Sauvignon',   1310::numeric, array['Cab Sav','Cab Sauv']),
            ('pinot_noir',          'Pinot Noir',           1145::numeric, array[]::text[]),
            ('tempranillo',         'Tempranillo',          1230::numeric, array[]::text[]),
            ('sangiovese',          'Sangiovese',           1285::numeric, array[]::text[]),
            ('grenache',            'Grenache',             1365::numeric, array['Garnacha']),
            ('mataro_mourvedre',    'Mataro / Mourvedre',   1440::numeric, array['Mataro','Mourvedre','Mourvèdre','Monastrell']),
            ('barbera',             'Barbera',              1285::numeric, array[]::text[]),
            ('malbec',              'Malbec',               1230::numeric, array[]::text[]),
            ('colombard',           'Colombard',            1300::numeric, array[]::text[]),
            ('muscat_gordo_blanco', 'Muscat Gordo Blanco',  1350::numeric, array['Muscat Gordo','Muscat of Alexandria']),
            ('fiano',               'Fiano',                1320::numeric, array[]::text[]),
            ('prosecco',            'Prosecco',             1410::numeric, array['Glera']),
            ('vermentino',          'Vermentino',           1290::numeric, array[]::text[]),
            ('gruner_veltliner',    'Gruner Veltliner',     1200::numeric, array['Grüner Veltliner','Gruner']),
            ('primitivo',           'Primitivo',            1200::numeric, array['Zinfandel'])
    ),
    expanded as (
        select c.key, c.display_name, c.optimal_gdd,
               public._variety_canonical(c.display_name) as cname
          from catalog c
        union all
        select c.key, c.display_name, c.optimal_gdd,
               public._variety_canonical(alias) as cname
          from catalog c
          cross join lateral unnest(c.aliases) as alias
    )
    select key, display_name, optimal_gdd
      from expanded
     where cname <> ''
       and cname = public._variety_canonical(p_name)
     limit 1;
$$;

-- =========================================================================
-- repair_grape_variety_allocations(vineyard_id, dry_run)
-- =========================================================================
-- Walks every paddock in scope, rewrites `variety_allocations` to:
--
--   1. Use the catalog name snapshot to find a built-in entry.
--   2. Replace the saved `varietyId` with the deterministic id for that
--      (vineyard_id, key) pair so allocations stay stable across
--      device/app resets.
--   3. Backfill missing `name` snapshots with the catalog display name.
--   4. Collapse duplicate allocations within a paddock (same final
--      `varietyId`) by summing their percentages and keeping the first
--      `id`/`name`.
--   5. Leave allocations alone when no safe catalog/alias match exists.
--
-- Returns one row per processed vineyard (or one aggregate row if
-- p_vineyard_id is null and no paddocks match).
--
-- Auth: callable by authenticated users. When p_vineyard_id is given the
-- caller must be a vineyard member with owner/manager role. When
-- p_vineyard_id is null the function processes every vineyard the
-- caller has owner/manager role in.

create or replace function public.repair_grape_variety_allocations(
    p_vineyard_id uuid default null,
    p_dry_run     boolean default true
)
returns table(
    vineyard_id             uuid,
    paddocks_checked        integer,
    allocations_checked     integer,
    allocations_repaired    integer,
    names_backfilled        integer,
    duplicates_collapsed    integer,
    unresolved_allocations  integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_scope_ids        uuid[];
    v_vy_id            uuid;
    r_pad              record;
    v_allocs           jsonb;
    v_alloc            jsonb;
    v_idx              int;
    v_name             text;
    v_old_variety_id   uuid;
    v_old_variety_text text;
    v_percent          numeric;
    v_alloc_id         text;
    v_match            record;
    v_new_id           uuid;
    v_new_name         text;
    v_new_allocs       jsonb;
    v_collapsed        jsonb;
    v_collapse_map     jsonb;
    v_key              text;
    v_existing         jsonb;
    v_pad_changed      boolean;
    -- counters per vineyard
    c_paddocks         int;
    c_allocs           int;
    c_repaired         int;
    c_backfilled       int;
    c_collapsed        int;
    c_unresolved       int;
begin
    -- Resolve scope.
    if p_vineyard_id is not null then
        if not public.has_vineyard_role(p_vineyard_id, array['owner','manager']) then
            raise exception 'not_authorized' using errcode = '42501';
        end if;
        v_scope_ids := array[p_vineyard_id];
    else
        select coalesce(array_agg(distinct vm.vineyard_id), array[]::uuid[])
          into v_scope_ids
          from public.vineyard_members vm
         where vm.user_id = auth.uid()
           and vm.role in ('owner','manager');
    end if;

    if v_scope_ids is null or array_length(v_scope_ids, 1) is null then
        vineyard_id            := p_vineyard_id;
        paddocks_checked       := 0;
        allocations_checked    := 0;
        allocations_repaired   := 0;
        names_backfilled       := 0;
        duplicates_collapsed   := 0;
        unresolved_allocations := 0;
        return next;
        return;
    end if;

    foreach v_vy_id in array v_scope_ids loop
        c_paddocks    := 0;
        c_allocs      := 0;
        c_repaired    := 0;
        c_backfilled  := 0;
        c_collapsed   := 0;
        c_unresolved  := 0;

        for r_pad in
            select p.id, p.variety_allocations
              from public.paddocks p
             where p.vineyard_id = v_vy_id
               and p.deleted_at is null
               and p.variety_allocations is not null
               and jsonb_typeof(p.variety_allocations) = 'array'
               and jsonb_array_length(p.variety_allocations) > 0
        loop
            c_paddocks    := c_paddocks + 1;
            v_allocs      := r_pad.variety_allocations;
            v_new_allocs  := '[]'::jsonb;
            v_pad_changed := false;

            -- Step 1: rewrite each allocation in place.
            for v_idx in 0 .. jsonb_array_length(v_allocs) - 1 loop
                v_alloc  := v_allocs -> v_idx;
                c_allocs := c_allocs + 1;

                v_name   := nullif(trim(coalesce(
                                v_alloc ->> 'name',
                                v_alloc ->> 'varietyName',
                                ''
                           )), '');
                v_alloc_id := coalesce(v_alloc ->> 'id', gen_random_uuid()::text);
                v_percent  := coalesce((v_alloc ->> 'percent')::numeric, 0);

                v_old_variety_text := coalesce(
                    v_alloc ->> 'varietyId',
                    v_alloc ->> 'variety_id',
                    v_alloc ->> 'variety'
                );
                begin
                    v_old_variety_id := nullif(v_old_variety_text, '')::uuid;
                exception when others then
                    v_old_variety_id := null;
                end;

                -- Try catalog match against name snapshot.
                v_match := null;
                if v_name is not null then
                    select * into v_match
                      from public._variety_catalog_match(v_name);
                end if;

                if v_match.key is not null then
                    v_new_id   := public._variety_deterministic_id(v_vy_id, v_match.key);
                    v_new_name := v_match.display_name;

                    if v_old_variety_id is distinct from v_new_id then
                        c_repaired    := c_repaired + 1;
                        v_pad_changed := true;
                    end if;
                    if v_name is distinct from v_new_name then
                        -- Treat catalog-cased name as a backfill/normalisation.
                        c_backfilled  := c_backfilled + 1;
                        v_pad_changed := true;
                    end if;
                else
                    -- No catalog match. Keep the old id but try to backfill
                    -- the name snapshot from the live `grape_varieties`
                    -- table when the id is known.
                    v_new_id := v_old_variety_id;
                    if v_name is null and v_old_variety_id is not null then
                        select gv.name into v_new_name
                          from public.grape_varieties gv
                         where gv.id = v_old_variety_id
                           and gv.vineyard_id = v_vy_id
                         limit 1;
                        if v_new_name is not null then
                            c_backfilled  := c_backfilled + 1;
                            v_pad_changed := true;
                        end if;
                    else
                        v_new_name := v_name;
                    end if;
                    if v_new_id is null then
                        c_unresolved := c_unresolved + 1;
                    end if;
                end if;

                v_new_allocs := v_new_allocs || jsonb_build_object(
                    'id',        v_alloc_id,
                    'varietyId', v_new_id,
                    'percent',   v_percent,
                    'name',      v_new_name
                );
            end loop;

            -- Step 2: collapse duplicates by final varietyId.
            v_collapse_map := '{}'::jsonb;
            v_collapsed    := '[]'::jsonb;
            for v_idx in 0 .. jsonb_array_length(v_new_allocs) - 1 loop
                v_alloc := v_new_allocs -> v_idx;
                v_key   := coalesce(v_alloc ->> 'varietyId',
                                    'unresolved:' || (v_alloc ->> 'id'));
                if v_collapse_map ? v_key then
                    -- Merge: sum percents into the existing entry.
                    v_existing := v_collapse_map -> v_key;
                    v_existing := jsonb_set(
                        v_existing,
                        '{percent}',
                        to_jsonb(
                            coalesce((v_existing ->> 'percent')::numeric, 0)
                          + coalesce((v_alloc    ->> 'percent')::numeric, 0)
                        )
                    );
                    if (v_existing ->> 'name') is null
                       and (v_alloc ->> 'name') is not null then
                        v_existing := jsonb_set(
                            v_existing,
                            '{name}',
                            to_jsonb(v_alloc ->> 'name')
                        );
                    end if;
                    v_collapse_map := jsonb_set(
                        v_collapse_map, array[v_key], v_existing
                    );
                    c_collapsed   := c_collapsed + 1;
                    v_pad_changed := true;
                else
                    v_collapse_map := jsonb_set(
                        v_collapse_map, array[v_key], v_alloc, true
                    );
                    v_collapsed := v_collapsed || v_alloc;
                end if;
            end loop;

            -- Rebuild ordered output from collapse map, preserving the
            -- first-seen order captured in `v_collapsed`.
            v_new_allocs := '[]'::jsonb;
            for v_idx in 0 .. jsonb_array_length(v_collapsed) - 1 loop
                v_alloc := v_collapsed -> v_idx;
                v_key   := coalesce(v_alloc ->> 'varietyId',
                                    'unresolved:' || (v_alloc ->> 'id'));
                v_new_allocs := v_new_allocs || (v_collapse_map -> v_key);
            end loop;

            -- Persist when changed and not in dry-run mode.
            if v_pad_changed and not p_dry_run then
                update public.paddocks
                   set variety_allocations = v_new_allocs,
                       updated_at          = now(),
                       client_updated_at   = now(),
                       sync_version        = coalesce(sync_version, 0) + 1,
                       updated_by          = coalesce(auth.uid(), updated_by)
                 where id = r_pad.id;
            end if;
        end loop;

        vineyard_id            := v_vy_id;
        paddocks_checked       := c_paddocks;
        allocations_checked    := c_allocs;
        allocations_repaired   := c_repaired;
        names_backfilled       := c_backfilled;
        duplicates_collapsed   := c_collapsed;
        unresolved_allocations := c_unresolved;
        return next;
    end loop;

    return;
end$$;

grant execute on function public._variety_canonical(text)              to authenticated;
grant execute on function public._variety_deterministic_id(uuid, text) to authenticated;
grant execute on function public._variety_catalog_match(text)          to authenticated;
grant execute on function public.repair_grape_variety_allocations(uuid, boolean) to authenticated;
