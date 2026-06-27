-- 071_grape_variety_repair_unresolved_and_mapping.sql
--
-- Follow-up patch to the grape variety repair pipeline. Addresses the
-- diagnostic where iOS still shows `Unknown` for an allocation that the
-- server-side repair reports as resolved:
--
--   alloc.varietyId = ECCB0BD-262A-4DD5-A368-838FACBD725C
--   alloc.name      = nil
--   resolver path   = no-match
--
-- The previous repair counted any allocation with a non-null `varietyId`
-- as resolved, even when:
--   * no name snapshot existed (cannot drive a catalog match), AND
--   * the saved id was not a deterministic built-in id for the
--     vineyard.
--
-- That left genuinely-unrecoverable rows in place AND reported
-- `unresolved_allocations = 0`, hiding them from operators.
--
-- This migration:
--   1. Adds a helper `_variety_catalog_keys()` that enumerates every
--      built-in catalog key, kept in lockstep with
--      `_variety_catalog_match` and the iOS `BuiltInGrapeVarietyCatalog`.
--   2. Adds `_variety_is_known_deterministic_id(vineyard_id, variety_id)`
--      that returns true iff the id matches any deterministic built-in
--      id for that vineyard.
--   3. Recreates `repair_grape_variety_allocations` and
--      `repair_grape_variety_allocations_admin` so that an allocation
--      with no catalog name match AND a non-deterministic `varietyId`
--      is counted as unresolved.
--   4. Adds `report_unresolved_grape_variety_allocations(p_vineyard_id)`
--      returning one row per unresolved allocation across all
--      vineyards (or a given vineyard).
--   5. Adds `repair_grape_variety_allocation_by_mapping(p_vineyard_id,
--      p_old_variety_id, p_catalog_key, p_dry_run)` that remaps stale
--      `varietyId`s to the deterministic built-in id + backfills the
--      canonical name. Idempotent, vineyard-scoped, admin-callable.
--
-- All functions remain idempotent. `create or replace function` only.

set search_path = public;

-- =========================================================================
-- _variety_catalog_keys() -> setof text
-- =========================================================================
-- Mirrors `_variety_catalog_match` keys. Kept here as a separate function
-- so other repair RPCs can iterate the full catalog without scraping
-- catalog rows by matching names.

create or replace function public._variety_catalog_keys()
returns table(key text, display_name text)
language sql
immutable
as $$
    values
        ('chardonnay',          'Chardonnay'),
        ('pinot_gris',          'Pinot Gris / Grigio'),
        ('riesling',            'Riesling'),
        ('sauvignon_blanc',     'Sauvignon Blanc'),
        ('semillon',            'Semillon'),
        ('chenin_blanc',        'Chenin Blanc'),
        ('gewurztraminer',      'Gewurztraminer'),
        ('viognier',            'Viognier'),
        ('shiraz',              'Shiraz'),
        ('merlot',              'Merlot'),
        ('cabernet_franc',      'Cabernet Franc'),
        ('cabernet_sauvignon',  'Cabernet Sauvignon'),
        ('pinot_noir',          'Pinot Noir'),
        ('tempranillo',         'Tempranillo'),
        ('sangiovese',          'Sangiovese'),
        ('grenache',            'Grenache'),
        ('mataro_mourvedre',    'Mataro / Mourvedre'),
        ('barbera',             'Barbera'),
        ('malbec',              'Malbec'),
        ('colombard',           'Colombard'),
        ('muscat_gordo_blanco', 'Muscat Gordo Blanco'),
        ('fiano',               'Fiano'),
        ('prosecco',            'Prosecco'),
        ('vermentino',          'Vermentino'),
        ('gruner_veltliner',    'Gruner Veltliner'),
        ('primitivo',           'Primitivo');
$$;

grant execute on function public._variety_catalog_keys() to authenticated;


-- =========================================================================
-- _variety_is_known_deterministic_id(vineyard_id, variety_id)
-- =========================================================================
-- True iff `p_variety_id` equals the deterministic id for any built-in
-- catalog key under `p_vineyard_id`. Null inputs return false.

create or replace function public._variety_is_known_deterministic_id(
    p_vineyard_id uuid,
    p_variety_id  uuid
)
returns boolean
language plpgsql
immutable
as $$
declare
    r record;
begin
    if p_vineyard_id is null or p_variety_id is null then
        return false;
    end if;

    for r in select key from public._variety_catalog_keys() loop
        if public._variety_deterministic_id(p_vineyard_id, r.key) = p_variety_id then
            return true;
        end if;
    end loop;
    return false;
end$$;

grant execute on function public._variety_is_known_deterministic_id(uuid, uuid)
    to authenticated;


-- =========================================================================
-- repair_grape_variety_allocations (member-scoped)
-- =========================================================================
-- Updated unresolved-detection logic. An allocation is unresolved when:
--   * no catalog match was found from name/varietyName, AND
--   * the existing varietyId is null OR not a known deterministic
--     built-in id for the vineyard.
-- Allocation JSON is left untouched in that case; it is only counted.

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
    v_scope_ids          uuid[];
    v_vy_id              uuid;
    r_pad                record;
    v_allocs             jsonb;
    v_alloc              jsonb;
    v_idx                int;
    v_name               text;
    v_old_variety_id     uuid;
    v_old_variety_text   text;
    v_percent            numeric;
    v_alloc_id           text;
    v_match_key          text;
    v_match_display_name text;
    v_new_id             uuid;
    v_new_name           text;
    v_new_allocs         jsonb;
    v_collapsed          jsonb;
    v_collapse_map       jsonb;
    v_key                text;
    v_existing           jsonb;
    v_pad_changed        boolean;
    c_paddocks           int;
    c_allocs             int;
    c_repaired           int;
    c_backfilled         int;
    c_collapsed          int;
    c_unresolved         int;
begin
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

                v_match_key          := null;
                v_match_display_name := null;
                if v_name is not null then
                    select m.key, m.display_name
                      into v_match_key, v_match_display_name
                      from public._variety_catalog_match(v_name) m
                     limit 1;
                end if;

                if v_match_key is not null then
                    v_new_id   := public._variety_deterministic_id(v_vy_id, v_match_key);
                    v_new_name := v_match_display_name;

                    if v_old_variety_id is distinct from v_new_id then
                        c_repaired    := c_repaired + 1;
                        v_pad_changed := true;
                    end if;
                    if v_name is distinct from v_new_name then
                        c_backfilled  := c_backfilled + 1;
                        v_pad_changed := true;
                    end if;
                else
                    -- No catalog match. Preserve existing JSON. Count as
                    -- unresolved when the id is missing OR is not a
                    -- known deterministic built-in id for this vineyard.
                    v_new_id   := v_old_variety_id;
                    v_new_name := v_name;

                    if v_new_id is null
                       or not public._variety_is_known_deterministic_id(v_vy_id, v_new_id) then
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

            -- Collapse duplicates by final varietyId.
            v_collapse_map := '{}'::jsonb;
            v_collapsed    := '[]'::jsonb;
            for v_idx in 0 .. jsonb_array_length(v_new_allocs) - 1 loop
                v_alloc := v_new_allocs -> v_idx;
                v_key   := coalesce(v_alloc ->> 'varietyId',
                                    'unresolved:' || (v_alloc ->> 'id'));
                if v_collapse_map ? v_key then
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

            v_new_allocs := '[]'::jsonb;
            for v_idx in 0 .. jsonb_array_length(v_collapsed) - 1 loop
                v_alloc := v_collapsed -> v_idx;
                v_key   := coalesce(v_alloc ->> 'varietyId',
                                    'unresolved:' || (v_alloc ->> 'id'));
                v_new_allocs := v_new_allocs || (v_collapse_map -> v_key);
            end loop;

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

grant execute on function public.repair_grape_variety_allocations(uuid, boolean)
    to authenticated;


-- =========================================================================
-- repair_grape_variety_allocations_admin (service role / system admin)
-- =========================================================================

create or replace function public.repair_grape_variety_allocations_admin(
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
    v_is_service_role    boolean := false;
    v_is_admin           boolean := false;
    v_scope_ids          uuid[];
    v_vy_id              uuid;
    r_pad                record;
    v_allocs             jsonb;
    v_alloc              jsonb;
    v_idx                int;
    v_name               text;
    v_old_variety_id     uuid;
    v_old_variety_text   text;
    v_percent            numeric;
    v_alloc_id           text;
    v_match_key          text;
    v_match_display_name text;
    v_new_id             uuid;
    v_new_name           text;
    v_new_allocs         jsonb;
    v_collapsed          jsonb;
    v_collapse_map       jsonb;
    v_key                text;
    v_existing           jsonb;
    v_pad_changed        boolean;
    c_paddocks           int;
    c_allocs             int;
    c_repaired           int;
    c_backfilled         int;
    c_collapsed          int;
    c_unresolved         int;
begin
    begin
        v_is_service_role :=
            coalesce(
                nullif(current_setting('request.jwt.claim.role', true), ''),
                ''
            ) = 'service_role'
            or current_user in ('service_role', 'postgres', 'supabase_admin');
    exception when others then
        v_is_service_role := current_user in ('service_role', 'postgres', 'supabase_admin');
    end;

    if not v_is_service_role then
        begin
            v_is_admin := public.is_system_admin();
        exception when others then
            v_is_admin := false;
        end;
    end if;

    if not (v_is_service_role or v_is_admin) then
        raise exception 'not_authorized: admin repair requires service role or system admin'
            using errcode = '42501';
    end if;

    if p_vineyard_id is not null then
        v_scope_ids := array[p_vineyard_id];
    else
        select coalesce(array_agg(distinct v.id), array[]::uuid[])
          into v_scope_ids
          from public.vineyards v
         where v.deleted_at is null;
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

                v_match_key          := null;
                v_match_display_name := null;
                if v_name is not null then
                    select m.key, m.display_name
                      into v_match_key, v_match_display_name
                      from public._variety_catalog_match(v_name) m
                     limit 1;
                end if;

                if v_match_key is not null then
                    v_new_id   := public._variety_deterministic_id(v_vy_id, v_match_key);
                    v_new_name := v_match_display_name;

                    if v_old_variety_id is distinct from v_new_id then
                        c_repaired    := c_repaired + 1;
                        v_pad_changed := true;
                    end if;
                    if v_name is distinct from v_new_name then
                        c_backfilled  := c_backfilled + 1;
                        v_pad_changed := true;
                    end if;
                else
                    v_new_id   := v_old_variety_id;
                    v_new_name := v_name;

                    if v_new_id is null
                       or not public._variety_is_known_deterministic_id(v_vy_id, v_new_id) then
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

            v_collapse_map := '{}'::jsonb;
            v_collapsed    := '[]'::jsonb;
            for v_idx in 0 .. jsonb_array_length(v_new_allocs) - 1 loop
                v_alloc := v_new_allocs -> v_idx;
                v_key   := coalesce(v_alloc ->> 'varietyId',
                                    'unresolved:' || (v_alloc ->> 'id'));
                if v_collapse_map ? v_key then
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

            v_new_allocs := '[]'::jsonb;
            for v_idx in 0 .. jsonb_array_length(v_collapsed) - 1 loop
                v_alloc := v_collapsed -> v_idx;
                v_key   := coalesce(v_alloc ->> 'varietyId',
                                    'unresolved:' || (v_alloc ->> 'id'));
                v_new_allocs := v_new_allocs || (v_collapse_map -> v_key);
            end loop;

            if v_pad_changed and not p_dry_run then
                update public.paddocks
                   set variety_allocations = v_new_allocs,
                       updated_at          = now(),
                       client_updated_at   = now(),
                       sync_version        = coalesce(sync_version, 0) + 1
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

grant execute on function public.repair_grape_variety_allocations_admin(uuid, boolean)
    to authenticated;


-- =========================================================================
-- report_unresolved_grape_variety_allocations(p_vineyard_id)
-- =========================================================================
-- Lists every allocation that the repair logic considers unresolved:
--   * has no catalog match against `name`/`varietyName`, AND
--   * has a null OR non-deterministic `varietyId` for the vineyard.
-- Admin-only (service role or system admin). Read-only; never mutates.

create or replace function public.report_unresolved_grape_variety_allocations(
    p_vineyard_id uuid default null
)
returns table(
    vineyard_id     uuid,
    vineyard_name   text,
    paddock_id      uuid,
    paddock_name    text,
    allocation_id   text,
    variety_id      uuid,
    allocation_name text,
    percent         numeric,
    reason          text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_is_service_role boolean := false;
    v_is_admin        boolean := false;
    r_pad             record;
    v_allocs          jsonb;
    v_alloc           jsonb;
    v_idx             int;
    v_name            text;
    v_old_text        text;
    v_old_id          uuid;
    v_match_key       text;
    v_alloc_uuid      uuid;
begin
    begin
        v_is_service_role :=
            coalesce(
                nullif(current_setting('request.jwt.claim.role', true), ''),
                ''
            ) = 'service_role'
            or current_user in ('service_role', 'postgres', 'supabase_admin');
    exception when others then
        v_is_service_role := current_user in ('service_role', 'postgres', 'supabase_admin');
    end;

    if not v_is_service_role then
        begin
            v_is_admin := public.is_system_admin();
        exception when others then
            v_is_admin := false;
        end;
    end if;

    if not (v_is_service_role or v_is_admin) then
        raise exception 'not_authorized: unresolved report requires service role or system admin'
            using errcode = '42501';
    end if;

    for r_pad in
        select p.id        as paddock_id,
               p.name      as paddock_name,
               p.vineyard_id,
               v.name      as vineyard_name,
               p.variety_allocations
          from public.paddocks p
          join public.vineyards v on v.id = p.vineyard_id
         where p.deleted_at is null
           and v.deleted_at is null
           and (p_vineyard_id is null or p.vineyard_id = p_vineyard_id)
           and p.variety_allocations is not null
           and jsonb_typeof(p.variety_allocations) = 'array'
           and jsonb_array_length(p.variety_allocations) > 0
    loop
        v_allocs := r_pad.variety_allocations;
        for v_idx in 0 .. jsonb_array_length(v_allocs) - 1 loop
            v_alloc := v_allocs -> v_idx;

            v_name := nullif(trim(coalesce(
                            v_alloc ->> 'name',
                            v_alloc ->> 'varietyName',
                            ''
                       )), '');

            v_old_text := coalesce(
                v_alloc ->> 'varietyId',
                v_alloc ->> 'variety_id',
                v_alloc ->> 'variety'
            );
            begin
                v_old_id := nullif(v_old_text, '')::uuid;
            exception when others then
                v_old_id := null;
            end;

            v_match_key := null;
            if v_name is not null then
                select m.key into v_match_key
                  from public._variety_catalog_match(v_name) m
                 limit 1;
            end if;

            if v_match_key is not null then
                continue;
            end if;

            if v_old_id is not null
               and public._variety_is_known_deterministic_id(r_pad.vineyard_id, v_old_id) then
                continue;
            end if;

            vineyard_id     := r_pad.vineyard_id;
            vineyard_name   := r_pad.vineyard_name;
            paddock_id      := r_pad.paddock_id;
            paddock_name    := r_pad.paddock_name;
            allocation_id   := v_alloc ->> 'id';
            variety_id      := v_old_id;
            allocation_name := v_name;
            percent         := coalesce((v_alloc ->> 'percent')::numeric, 0);

            if v_old_id is null and v_name is null then
                reason := 'missing_name_and_missing_variety_id';
            elsif v_old_id is null then
                reason := 'name_with_no_variety_id';
            elsif v_name is null then
                reason := 'missing_name_and_unknown_variety_id';
            else
                reason := 'unknown_custom_variety';
            end if;

            return next;
        end loop;
    end loop;

    return;
end$$;

grant execute on function public.report_unresolved_grape_variety_allocations(uuid)
    to authenticated;


-- =========================================================================
-- repair_grape_variety_allocation_by_mapping
-- =========================================================================
-- Manually remap every allocation in a vineyard whose `varietyId` matches
-- `p_old_variety_id` to the deterministic id + canonical name for
-- `p_catalog_key`. Used when an allocation has no recoverable name
-- snapshot and the catalog match cannot infer it automatically.
--
-- Admin-only (service role or system admin). Idempotent: rerunning with
-- the same arguments after apply changes nothing.

create or replace function public.repair_grape_variety_allocation_by_mapping(
    p_vineyard_id    uuid,
    p_old_variety_id uuid,
    p_catalog_key    text,
    p_dry_run        boolean default true
)
returns table(
    vineyard_id          uuid,
    paddocks_changed     integer,
    allocations_changed  integer,
    new_variety_id       uuid,
    new_variety_name     text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_is_service_role    boolean := false;
    v_is_admin           boolean := false;
    r_pad                record;
    v_allocs             jsonb;
    v_alloc              jsonb;
    v_idx                int;
    v_old_text           text;
    v_old_id             uuid;
    v_new_id             uuid;
    v_new_name           text;
    v_new_allocs         jsonb;
    v_pad_changed        boolean;
    c_paddocks           int := 0;
    c_allocs             int := 0;
begin
    if p_vineyard_id is null or p_old_variety_id is null
       or p_catalog_key is null or length(p_catalog_key) = 0 then
        raise exception 'missing_arguments' using errcode = '22023';
    end if;

    begin
        v_is_service_role :=
            coalesce(
                nullif(current_setting('request.jwt.claim.role', true), ''),
                ''
            ) = 'service_role'
            or current_user in ('service_role', 'postgres', 'supabase_admin');
    exception when others then
        v_is_service_role := current_user in ('service_role', 'postgres', 'supabase_admin');
    end;

    if not v_is_service_role then
        begin
            v_is_admin := public.is_system_admin();
        exception when others then
            v_is_admin := false;
        end;
    end if;

    if not (v_is_service_role or v_is_admin) then
        raise exception 'not_authorized: mapping repair requires service role or system admin'
            using errcode = '42501';
    end if;

    -- Resolve target via the catalog key.
    v_new_name := null;
    select k.display_name
      into v_new_name
      from public._variety_catalog_keys() k
     where k.key = p_catalog_key
     limit 1;

    if v_new_name is null then
        raise exception 'unknown_catalog_key: %', p_catalog_key
            using errcode = '22023';
    end if;

    v_new_id := public._variety_deterministic_id(p_vineyard_id, p_catalog_key);

    for r_pad in
        select p.id, p.variety_allocations
          from public.paddocks p
         where p.vineyard_id = p_vineyard_id
           and p.deleted_at is null
           and p.variety_allocations is not null
           and jsonb_typeof(p.variety_allocations) = 'array'
           and jsonb_array_length(p.variety_allocations) > 0
    loop
        v_allocs      := r_pad.variety_allocations;
        v_new_allocs  := '[]'::jsonb;
        v_pad_changed := false;

        for v_idx in 0 .. jsonb_array_length(v_allocs) - 1 loop
            v_alloc := v_allocs -> v_idx;

            v_old_text := coalesce(
                v_alloc ->> 'varietyId',
                v_alloc ->> 'variety_id',
                v_alloc ->> 'variety'
            );
            begin
                v_old_id := nullif(v_old_text, '')::uuid;
            exception when others then
                v_old_id := null;
            end;

            if v_old_id is not null and v_old_id = p_old_variety_id then
                v_alloc       := jsonb_set(v_alloc, '{varietyId}', to_jsonb(v_new_id::text), true);
                v_alloc       := jsonb_set(v_alloc, '{name}',      to_jsonb(v_new_name),     true);
                v_pad_changed := true;
                c_allocs      := c_allocs + 1;
            end if;

            v_new_allocs := v_new_allocs || v_alloc;
        end loop;

        if v_pad_changed then
            c_paddocks := c_paddocks + 1;
            if not p_dry_run then
                update public.paddocks
                   set variety_allocations = v_new_allocs,
                       updated_at          = now(),
                       client_updated_at   = now(),
                       sync_version        = coalesce(sync_version, 0) + 1
                 where id = r_pad.id;
            end if;
        end if;
    end loop;

    vineyard_id         := p_vineyard_id;
    paddocks_changed    := c_paddocks;
    allocations_changed := c_allocs;
    new_variety_id      := v_new_id;
    new_variety_name    := v_new_name;
    return next;
    return;
end$$;

grant execute on function public.repair_grape_variety_allocation_by_mapping(
    uuid, uuid, text, boolean
) to authenticated;
