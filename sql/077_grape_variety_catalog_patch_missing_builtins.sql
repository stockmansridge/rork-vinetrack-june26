-- 077_grape_variety_catalog_patch_missing_builtins.sql
--
-- Reconciles the shared `public.grape_variety_catalog` against the
-- intended 67-built-in target. SQL 074 landed 60 active built-ins; this
-- patch adds the 7 commonly-requested entries that were missing:
--
--   * Muscadet / Melon de Bourgogne
--   * Rkatsiteli
--   * Pinotage
--   * Carignan
--   * Counoise
--   * Müller-Thurgau
--   * Torrontés
--
-- Also adds `grape_variety_diagnostics_admin(p_vineyard_id)` — a
-- system-admin / service-role-safe diagnostics helper so the catalogue
-- can be inspected from the Supabase SQL Editor without needing an
-- `auth.uid()` vineyard-member context.
--
-- Idempotent: re-running is safe.

set search_path = public;


-- =========================================================================
-- Patch: missing built-in varieties.
--
-- Slugs are stable and MUST NOT change. Aliases are generous so the
-- canonical resolver picks up common synonyms (e.g. Zinfandel →
-- primitivo, Melon de Bourgogne → muscadet).
-- =========================================================================
insert into public.grape_variety_catalog
    (key, canonical_name, display_name, aliases, optimal_gdd, is_builtin, is_active)
values
    ('muscadet',         'Muscadet',         'Muscadet / Melon de Bourgogne',
        '["Melon de Bourgogne","Melon B","Melon"]'::jsonb,                       1100, true, true),
    ('rkatsiteli',       'Rkatsiteli',       'Rkatsiteli',
        '["Rkaciteli","Rkatziteli"]'::jsonb,                                     1250, true, true),
    ('pinotage',         'Pinotage',         'Pinotage',
        '[]'::jsonb,                                                             1300, true, true),
    ('carignan',         'Carignan',         'Carignan',
        '["Carignane","Carinena","Cariñena","Mazuelo","Samso"]'::jsonb,          1400, true, true),
    ('counoise',         'Counoise',         'Counoise',
        '[]'::jsonb,                                                             1350, true, true),
    ('muller_thurgau',   'Muller-Thurgau',   'Müller-Thurgau',
        '["Muller Thurgau","Müller Thurgau","Müller-Thurgau","Rivaner"]'::jsonb, 1050, true, true),
    ('torrontes',        'Torrontes',        'Torrontés',
        '["Torrontes","Torrontés Riojano"]'::jsonb,                              1280, true, true)
on conflict (key) do update
    set canonical_name = excluded.canonical_name,
        display_name   = excluded.display_name,
        aliases        = excluded.aliases,
        optimal_gdd    = coalesce(public.grape_variety_catalog.optimal_gdd, excluded.optimal_gdd),
        is_builtin     = true,
        is_active      = true,
        updated_at     = now();


-- =========================================================================
-- Backfill: every active vineyard receives the new built-ins in
-- `vineyard_grape_varieties`. Existing rows (including vineyard
-- customs) are untouched thanks to the unique (vineyard_id, variety_key)
-- constraint.
-- =========================================================================
insert into public.vineyard_grape_varieties
    (vineyard_id, variety_key, display_name, is_custom, is_active, optimal_gdd_override)
select v.id, c.key, c.display_name, false, true, null
  from public.vineyards v
  cross join public.grape_variety_catalog c
 where v.deleted_at is null
   and c.is_builtin = true
   and c.is_active  = true
   and c.key in (
        'muscadet','rkatsiteli','pinotage','carignan',
        'counoise','muller_thurgau','torrontes'
   )
on conflict (vineyard_id, variety_key) do nothing;


-- =========================================================================
-- grape_variety_diagnostics_admin(p_vineyard_id)
--
-- System-admin / service-role-safe diagnostics. Lets a true system admin
-- (or the Supabase SQL Editor running as service_role / postgres) run
-- vineyard diagnostics without being a vineyard member.
--
-- Normal users / unauthenticated callers are rejected; use the regular
-- `grape_variety_diagnostics(p_vineyard_id)` from iOS/Lovable instead.
-- =========================================================================
create or replace function public.grape_variety_diagnostics_admin(
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
    v_role       text := current_user;
    v_jwt_role   text := coalesce(auth.role(), '');
begin
    if p_vineyard_id is null then
        raise exception 'p_vineyard_id is required' using errcode = '22023';
    end if;

    -- Allow if: (a) JWT role is service_role, (b) running as a Postgres
    -- superuser/admin in the SQL Editor, or (c) caller is a system admin.
    if v_jwt_role <> 'service_role'
       and v_role not in ('postgres','supabase_admin','service_role')
       and not public.is_system_admin()
    then
        raise exception 'not_authorized: system admin or service role required'
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

grant execute on function public.grape_variety_diagnostics_admin(uuid) to authenticated, service_role;
