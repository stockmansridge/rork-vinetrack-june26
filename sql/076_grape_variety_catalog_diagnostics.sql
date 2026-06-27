-- 076_grape_variety_catalog_diagnostics.sql
--
-- Verifies the expanded grape-variety catalogue from 074 and adds two
-- diagnostics RPCs used by System Admin -> Sync Diagnostics:
--
--   * public.verify_grape_variety_catalog()
--       Returns one row of global catalogue counts: active built-ins,
--       inactive built-ins, total entries, total aliases, last update,
--       plus a "pinot_gris_resolves_pinot_grigio" boolean sanity check.
--       Readable by any authenticated user.
--
--   * public.grape_variety_diagnostics(p_vineyard_id uuid)
--       Returns one row of vineyard-scoped counts: vineyard variety
--       rows (active + archived), active built-in count, active custom
--       count, archived count, and unresolved allocation count for that
--       vineyard. Members can read; the unresolved count falls back to
--       0 if the caller cannot read the admin report RPC.
--
-- Idempotent: re-running is safe.

set search_path = public;


-- =========================================================================
-- Verification block (074 sanity check) — RAISE NOTICEs into the SQL log so
-- a manual run via the SQL editor produces a quick readout. Safe to leave
-- in production; no rows are mutated.
-- =========================================================================
do $$
declare
    v_active     int;
    v_inactive   int;
    v_total      int;
    v_aliases    int;
    v_pg_active  boolean;
    v_match_key  text;
begin
    select
        count(*) filter (where is_active and is_builtin),
        count(*) filter (where not is_active and is_builtin),
        count(*),
        coalesce(sum(jsonb_array_length(coalesce(aliases, '[]'::jsonb))), 0)
      into v_active, v_inactive, v_total, v_aliases
      from public.grape_variety_catalog;

    select c.is_active into v_pg_active
      from public.grape_variety_catalog c
     where c.key = 'pinot_gris';

    select m.key into v_match_key
      from public._variety_catalog_match('Pinot Grigio') m
     limit 1;

    raise notice '076 verify: catalog active_builtin=% inactive_builtin=% total=% aliases=%',
        v_active, v_inactive, v_total, v_aliases;
    raise notice '076 verify: pinot_gris active=% / Pinot Grigio matches key=%',
        coalesce(v_pg_active, false), coalesce(v_match_key, '<none>');
end$$;


-- =========================================================================
-- verify_grape_variety_catalog()
-- =========================================================================
create or replace function public.verify_grape_variety_catalog()
returns table(
    active_builtin_count   int,
    inactive_builtin_count int,
    total_count            int,
    total_aliases          int,
    last_updated_at        timestamptz,
    pinot_gris_active                    boolean,
    pinot_grigio_resolves_to_pinot_gris  boolean
)
language sql
stable
security definer
set search_path = public
as $$
    with stats as (
        select
            count(*) filter (where c.is_active and c.is_builtin)::int        as active_builtin_count,
            count(*) filter (where not c.is_active and c.is_builtin)::int    as inactive_builtin_count,
            count(*)::int                                                    as total_count,
            coalesce(sum(jsonb_array_length(coalesce(c.aliases, '[]'::jsonb))), 0)::int
                                                                              as total_aliases,
            max(c.updated_at)                                                as last_updated_at
          from public.grape_variety_catalog c
    ),
    pg as (
        select c.is_active as pinot_gris_active
          from public.grape_variety_catalog c
         where c.key = 'pinot_gris'
    ),
    grigio as (
        select (m.key = 'pinot_gris') as pinot_grigio_resolves_to_pinot_gris
          from public._variety_catalog_match('Pinot Grigio') m
         limit 1
    )
    select s.active_builtin_count,
           s.inactive_builtin_count,
           s.total_count,
           s.total_aliases,
           s.last_updated_at,
           coalesce((select pinot_gris_active from pg), false),
           coalesce((select pinot_grigio_resolves_to_pinot_gris from grigio), false)
      from stats s;
$$;

grant execute on function public.verify_grape_variety_catalog() to authenticated;


-- =========================================================================
-- grape_variety_diagnostics(p_vineyard_id)
-- =========================================================================
create or replace function public.grape_variety_diagnostics(
    p_vineyard_id uuid
)
returns table(
    vineyard_variety_count   int,
    builtin_count            int,
    custom_count             int,
    archived_count           int,
    unresolved_allocations   int
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_total      int := 0;
    v_builtin    int := 0;
    v_custom     int := 0;
    v_archived   int := 0;
    v_unresolved int := 0;
begin
    if p_vineyard_id is null then
        raise exception 'p_vineyard_id is required' using errcode = '22023';
    end if;

    if not public.is_vineyard_member(p_vineyard_id) then
        raise exception 'not_authorized: caller is not a member of the vineyard'
            using errcode = '42501';
    end if;

    select
        count(*)::int,
        count(*) filter (where not is_custom and is_active)::int,
        count(*) filter (where is_custom and is_active)::int,
        count(*) filter (where not is_active)::int
      into v_total, v_builtin, v_custom, v_archived
      from public.vineyard_grape_varieties
     where vineyard_id = p_vineyard_id;

    -- Unresolved count — only meaningful for system admins. Anyone else
    -- gets 0 here (and the underlying report RPC would refuse anyway).
    begin
        select count(*)::int
          into v_unresolved
          from public.report_unresolved_grape_variety_allocations(p_vineyard_id);
    exception when others then
        v_unresolved := 0;
    end;

    vineyard_variety_count := v_total;
    builtin_count          := v_builtin;
    custom_count           := v_custom;
    archived_count         := v_archived;
    unresolved_allocations := v_unresolved;
    return next;
end$$;

grant execute on function public.grape_variety_diagnostics(uuid) to authenticated;
