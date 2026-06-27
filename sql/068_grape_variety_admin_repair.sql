-- 068_grape_variety_admin_repair.sql
--
-- Admin-safe variant of `repair_grape_variety_allocations` that can be
-- invoked from the Supabase SQL Editor / via the service role to repair
-- every vineyard regardless of `auth.uid()`.
--
-- The original `repair_grape_variety_allocations(uuid, boolean)` from
-- migration 067 scopes work to vineyards where the calling user has
-- owner/manager role. In the SQL Editor `auth.uid()` is null so that
-- function returns zero rows when called with `null::uuid`.
--
-- This migration adds:
--
--   public.repair_grape_variety_allocations_admin(
--       p_vineyard_id uuid default null,
--       p_dry_run     boolean default true
--   )
--
-- Behaviour:
--   * `p_vineyard_id is null` → every active (non-deleted) vineyard.
--   * `p_vineyard_id is given` → only that vineyard.
--   * Repair logic is identical to migration 067 (catalog match,
--     deterministic id remap, name backfill, duplicate collapse).
--   * Idempotent — a follow-up dry-run after apply returns zero repairs.
--
-- Auth gate:
--   * Allowed when the caller is the Supabase service role
--     (`auth.role() = 'service_role'` or running as the `service_role`
--     / `postgres` role inside the SQL Editor).
--   * Otherwise the caller must be `public.is_system_admin()`.
--   * Normal authenticated users are NOT granted broad access — they
--     should keep using `repair_grape_variety_allocations`.

set search_path = public;

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
    v_is_service_role  boolean := false;
    v_is_admin         boolean := false;
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
    -- ---------------------------------------------------------------
    -- Auth gate: service role OR system admin only.
    -- ---------------------------------------------------------------
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

    -- ---------------------------------------------------------------
    -- Resolve scope (no auth.uid() dependency).
    -- ---------------------------------------------------------------
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
                        c_backfilled  := c_backfilled + 1;
                        v_pad_changed := true;
                    end if;
                else
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

            -- Rebuild ordered output from collapse map.
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

-- Service role always bypasses grants, but make execution explicit for
-- platform admins (gate inside the function still enforces is_system_admin()).
grant execute on function public.repair_grape_variety_allocations_admin(uuid, boolean) to authenticated;
