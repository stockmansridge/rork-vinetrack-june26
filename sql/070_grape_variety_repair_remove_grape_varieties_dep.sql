-- 070_grape_variety_repair_remove_grape_varieties_dep.sql
--
-- Patch migration that fixes a runtime error in the grape variety repair
-- functions introduced in 067/068/069:
--
--   ERROR: 42P01: relation "public.grape_varieties" does not exist
--   QUERY:  select gv.name from public.grape_varieties gv
--
-- Root cause:
--   Both `repair_grape_variety_allocations` and
--   `repair_grape_variety_allocations_admin` contained a fallback branch
--   that, when an allocation had no usable name snapshot but did have an
--   old `varietyId`, attempted to look up the variety name from
--   `public.grape_varieties`. That table does not exist in the shared
--   Supabase schema (grape varieties live in the client / built-in
--   catalogue), so the function aborts the moment that branch executes.
--
-- Fix:
--   Remove the `public.grape_varieties` lookup entirely. The repair must
--   only rely on:
--     * `paddocks.variety_allocations.name` / `varietyName`
--     * built-in catalogue/alias matching via `_variety_catalog_match`
--     * existing `varietyId` when no safe name match exists
--   If an allocation has no catalogue match AND no usable saved name,
--   leave it untouched and count it as unresolved. Never crash.
--
-- This migration re-creates both functions with the dependency removed.
-- Safe to run repeatedly; uses `create or replace function`. Idempotent.

set search_path = public;

-- =========================================================================
-- repair_grape_variety_allocations (member-scoped)
-- =========================================================================

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

                -- Try catalog match against name snapshot. Use explicit
                -- scalars so unmatched names simply leave the variables
                -- NULL instead of producing an unbound record.
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
                    -- No catalog match. Preserve existing varietyId and
                    -- name as-is. Do NOT query any grape_varieties table;
                    -- it does not exist in the shared schema. If the
                    -- allocation cannot be resolved, count it as
                    -- unresolved and leave the JSON untouched.
                    v_new_id   := v_old_variety_id;
                    v_new_name := v_name;

                    if v_new_id is null and v_new_name is null then
                        c_unresolved := c_unresolved + 1;
                    elsif v_new_id is null then
                        -- Has a saved name but no resolvable id; still
                        -- counts as unresolved for reporting purposes,
                        -- but we keep the name snapshot in the JSON.
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

grant execute on function public.repair_grape_variety_allocations(uuid, boolean) to authenticated;


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
    -- Auth gate: service role OR system admin only.
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

    -- Resolve scope.
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

                -- Catalog match via explicit scalars so unmatched names
                -- simply leave the variables NULL instead of producing an
                -- unbound record with no tuple structure.
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
                    -- No catalog match. Do NOT consult any
                    -- public.grape_varieties table; it does not exist in
                    -- the shared schema. Preserve existing varietyId and
                    -- name as-is. Count truly unresolved allocations.
                    v_new_id   := v_old_variety_id;
                    v_new_name := v_name;

                    if v_new_id is null and v_new_name is null then
                        c_unresolved := c_unresolved + 1;
                    elsif v_new_id is null then
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

grant execute on function public.repair_grape_variety_allocations_admin(uuid, boolean) to authenticated;
