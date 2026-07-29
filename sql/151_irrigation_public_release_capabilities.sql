-- =============================================================================
-- 151_irrigation_public_release_capabilities.sql
-- Irrigation Records — PUBLIC RELEASE.
--
-- Replaces the temporary System Administrator gate (Phase 1/2A/2B) with the
-- shared role-based capability model. NO irrigation calculation, import or
-- reporting logic changes in this migration — access control only.
--
-- Capability matrix (single source of truth: public.irrigation_capability):
--
--   capability                  owner  manager  supervisor  operator
--   view_irrigation_records       ✓      ✓         ✓           ✓
--   record_irrigation             ✓      ✓         ✓           ✓
--   edit_irrigation               ✓      ✓         ✗           ✗
--   reverse_irrigation            ✓      ✓         ✓*          ✗
--   manage_irrigation_setup       ✓      ✓         ✗           ✗
--   view_irrigation_reports       ✓      ✓         ✓           ✗
--   import_irrigation             ✓      ✓         ✗           ✗
--   reverse_irrigation_import     ✓      ✓         ✗           ✗
--
--   * Supervisor session reversal follows the existing VineTrack work-record
--     convention: soft_delete_work_task and the labour-line RPCs allow
--     owner/manager/supervisor. Reversal is the irrigation equivalent of a
--     work-record soft delete, so supervisors keep it (per the release spec's
--     "unless existing work-record permissions already allow this").
--
--   System Administrators who are members of the vineyard retain FULL access
--   to every capability (unchanged from the Phase 1 gate, which was
--   is_system_admin() AND is_vineyard_member()).
--
-- Enforcement design (no RPC body is rewritten):
--   * public.has_irrigation_records_access() — the Phase 1 gate that SQL 125
--     was explicitly designed around ("releasing means changing ONLY this
--     function body") — is repointed to the view capability. This releases
--     every view-level RPC and all core-table RLS SELECT policies at once.
--   * public._irrigation_require_access() and
--     public._irrigation_import_require_admin() now read the per-function
--     GUC `app.irrigation_capability` (bound below with ALTER FUNCTION ...
--     SET), defaulting to `view_irrigation_records` / `import_irrigation`.
--     Postgres applies a function's SET clause for the whole call, including
--     the nested require helpers, so each RPC enforces its own capability
--     without any body change.
--   * Stricter RPCs (setup, edit, reverse, reports, import reversal) get the
--     GUC bound via a verified ALTER FUNCTION loop (all overloads).
--   * Import-table RLS SELECT policies move from the inline system-admin
--     check to the import capability.
--
-- NOTE for future migrations: CREATE OR REPLACE FUNCTION drops a function's
-- SET clauses. Any migration that re-declares one of the bound RPCs below
-- MUST re-apply its `set app.irrigation_capability` binding (see §5).
--
-- Error contract (unchanged prefixes, one addition):
--   irrigation_access_denied    — caller cannot even view Irrigation Records
--   irrigation_permission_denied — caller can view, but the role lacks this action
--   import_access_denied        — caller lacks the import capability
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Guard — require the phases this migration releases.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'has_irrigation_records_access') then
    raise exception 'SQL 125 not applied — Irrigation Records Phase 1 is required.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = '_irrigation_import_require_admin') then
    raise exception 'SQL 142 not applied — the import framework is required.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'get_irrigation_vintage_overview') then
    raise exception 'SQL 147/149 not applied — Phase 2B reporting is required.';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 1. Central capability check (single source of truth for all three clients).
-- ---------------------------------------------------------------------------
create or replace function public.irrigation_capability(
  p_vineyard_id uuid,
  p_capability text
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_vineyard_id is null then false
    -- System Administrators keep full access (must still be a member —
    -- identical to the Phase 1 gate semantics).
    when public.is_system_admin() and public.is_vineyard_member(p_vineyard_id) then true
    else public.has_vineyard_role(p_vineyard_id,
      case p_capability
        when 'view_irrigation_records'   then array['owner','manager','supervisor','operator']
        when 'record_irrigation'         then array['owner','manager','supervisor','operator']
        when 'edit_irrigation'           then array['owner','manager']
        when 'reverse_irrigation'        then array['owner','manager','supervisor']
        when 'manage_irrigation_setup'   then array['owner','manager']
        when 'view_irrigation_reports'   then array['owner','manager','supervisor']
        when 'import_irrigation'         then array['owner','manager']
        when 'reverse_irrigation_import' then array['owner','manager']
        else array[]::text[]  -- unknown capability => deny
      end)
  end;
$$;

revoke all on function public.irrigation_capability(uuid, text) from public, anon;
grant execute on function public.irrigation_capability(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Client contract — one RPC returning the full capability set, so Portal,
--    iOS and Android gate visibility from the SAME server answer instead of
--    duplicating role logic.
-- ---------------------------------------------------------------------------
create or replace function public.get_irrigation_capabilities(p_vineyard_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'vineyard_id',                    p_vineyard_id,
    'role',                           public.vineyard_role(p_vineyard_id),
    'is_system_admin',                public.is_system_admin(),
    'can_view_irrigation_records',    public.irrigation_capability(p_vineyard_id, 'view_irrigation_records'),
    'can_record_irrigation',          public.irrigation_capability(p_vineyard_id, 'record_irrigation'),
    'can_edit_irrigation',            public.irrigation_capability(p_vineyard_id, 'edit_irrigation'),
    'can_reverse_irrigation',         public.irrigation_capability(p_vineyard_id, 'reverse_irrigation'),
    'can_manage_irrigation_setup',    public.irrigation_capability(p_vineyard_id, 'manage_irrigation_setup'),
    'can_view_irrigation_reports',    public.irrigation_capability(p_vineyard_id, 'view_irrigation_reports'),
    'can_import_irrigation',          public.irrigation_capability(p_vineyard_id, 'import_irrigation'),
    'can_reverse_irrigation_import',  public.irrigation_capability(p_vineyard_id, 'reverse_irrigation_import'),
    'generated_at',                   now());
$$;

revoke all on function public.get_irrigation_capabilities(uuid) from public, anon;
grant execute on function public.get_irrigation_capabilities(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Release the Phase 1 gate. This is THE switch: every core-table RLS
--    SELECT policy and every view-level RPC uses this function.
-- ---------------------------------------------------------------------------
create or replace function public.has_irrigation_records_access(p_vineyard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.irrigation_capability(p_vineyard_id, 'view_irrigation_records');
$$;

revoke all on function public.has_irrigation_records_access(uuid) from public, anon;
grant execute on function public.has_irrigation_records_access(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Capability-aware require helpers. Each RPC's bound GUC (see §5) decides
--    which capability is demanded; unbound RPCs keep the view/import default.
-- ---------------------------------------------------------------------------
create or replace function public._irrigation_require_access(p_vineyard_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cap text := coalesce(nullif(current_setting('app.irrigation_capability', true), ''),
                         'view_irrigation_records');
begin
  if p_vineyard_id is null
     or not public.irrigation_capability(p_vineyard_id, 'view_irrigation_records') then
    raise exception 'irrigation_access_denied: Irrigation Records is not available for this account';
  end if;
  if v_cap <> 'view_irrigation_records'
     and not public.irrigation_capability(p_vineyard_id, v_cap) then
    raise exception 'irrigation_permission_denied: Your role does not allow this irrigation action (%)', v_cap;
  end if;
end;
$$;

revoke all on function public._irrigation_require_access(uuid) from public, anon, authenticated;

create or replace function public._irrigation_import_require_admin(p_vineyard_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cap text := coalesce(nullif(current_setting('app.irrigation_capability', true), ''),
                         'import_irrigation');
begin
  if p_vineyard_id is null then
    raise exception 'invalid_vineyard: vineyard is required';
  end if;
  if not public.irrigation_capability(p_vineyard_id, v_cap) then
    raise exception 'import_access_denied: Controller imports require Owner or Manager access to this vineyard';
  end if;
end;
$$;

revoke all on function public._irrigation_import_require_admin(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Bind each stricter RPC to its capability (ALL overloads; loud failure if
--    an expected RPC is missing so a partial apply cannot go unnoticed).
--    View-level RPCs (list/get/status/preview/session detail) stay unbound
--    and use the `view_irrigation_records` default. Import RPCs stay unbound
--    and use the `import_irrigation` default via the import helper.
-- ---------------------------------------------------------------------------
do $$
declare
  m record;
  f record;
  n integer;
begin
  for m in
    select * from (values
      -- Recording / editing / reversal (SQL 125 + 130 + 131)
      ('record_irrigation_session',                 'record_irrigation'),
      ('update_irrigation_session',                 'edit_irrigation'),
      ('reverse_irrigation_session',                'reverse_irrigation'),
      -- Setup (SQL 125 + 126 + 127)
      ('create_irrigation_system',                  'manage_irrigation_setup'),
      ('update_irrigation_system',                  'manage_irrigation_setup'),
      ('create_irrigation_valve',                   'manage_irrigation_setup'),
      ('update_irrigation_valve',                   'manage_irrigation_setup'),
      ('set_irrigation_valve_blocks',               'manage_irrigation_setup'),
      ('set_irrigation_valve_rows',                 'manage_irrigation_setup'),
      -- Phase 1 summaries (SQL 125)
      ('get_irrigation_vintage_summary',            'view_irrigation_reports'),
      ('get_irrigation_valve_summary',              'view_irrigation_reports'),
      ('get_irrigation_block_summary',              'view_irrigation_reports'),
      ('get_irrigation_variety_summary',            'view_irrigation_reports'),
      ('get_irrigation_daily_summary',              'view_irrigation_reports'),
      ('get_irrigation_monthly_summary',            'view_irrigation_reports'),
      -- Phase 2B reporting (SQL 147 + 149)
      ('get_irrigation_vintage_overview',           'view_irrigation_reports'),
      ('get_irrigation_daily_report',               'view_irrigation_reports'),
      ('get_irrigation_weekly_summary',             'view_irrigation_reports'),
      ('get_irrigation_monthly_report',             'view_irrigation_reports'),
      ('get_irrigation_valve_report',               'view_irrigation_reports'),
      ('get_irrigation_block_report',               'view_irrigation_reports'),
      ('get_irrigation_variety_report',             'view_irrigation_reports'),
      ('get_irrigation_water_source_summary',       'view_irrigation_reports'),
      ('get_irrigation_calculation_source_summary', 'view_irrigation_reports'),
      ('get_irrigation_record_source_summary',      'view_irrigation_reports'),
      ('get_irrigation_rainfall_summary',           'view_irrigation_reports'),
      ('get_irrigation_vintage_trends',             'view_irrigation_reports'),
      ('list_irrigation_report_sessions',           'view_irrigation_reports'),
      -- Import batch reversal (SQL 142) — separate capability so it can be
      -- made Owner-only later without touching the other import RPCs.
      ('reverse_irrigation_import_batch',           'reverse_irrigation_import')
    ) as t(fname, cap)
  loop
    n := 0;
    for f in
      select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname = m.fname
    loop
      execute format('alter function %s set app.irrigation_capability = %L', f.sig, m.cap);
      n := n + 1;
    end loop;
    if n = 0 then
      raise exception 'SQL 151: expected function public.%() not found — capability binding incomplete', m.fname;
    end if;
  end loop;
end$$;

-- ---------------------------------------------------------------------------
-- 6. Import-table RLS — SELECT moves from the inline system-admin check to
--    the import capability (writes remain definer-RPC-only, unchanged).
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['irrigation_import_provider_settings',
                           'irrigation_controller_valve_mappings',
                           'irrigation_import_batches',
                           'irrigation_import_rows']
  loop
    execute format('drop policy if exists "%s_select_admin" on public.%I', t, t);
    execute format('drop policy if exists "%s_select_import" on public.%I', t, t);
    execute format(
      'create policy "%s_select_import" on public.%I for select to authenticated
       using (public.irrigation_capability(vineyard_id, ''import_irrigation''))', t, t);
    -- No insert/update/delete policies: writes only via security-definer RPCs.
  end loop;
end$$;

-- ---------------------------------------------------------------------------
-- 7. Validation — fail loudly if any binding or policy is missing.
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  -- 7a. Every bound RPC carries the GUC in proconfig.
  select string_agg(distinct fname, ', ') into v_missing
  from (values
      ('record_irrigation_session'), ('update_irrigation_session'),
      ('reverse_irrigation_session'), ('create_irrigation_system'),
      ('update_irrigation_system'), ('create_irrigation_valve'),
      ('update_irrigation_valve'), ('set_irrigation_valve_blocks'),
      ('set_irrigation_valve_rows'), ('get_irrigation_vintage_summary'),
      ('get_irrigation_valve_summary'), ('get_irrigation_block_summary'),
      ('get_irrigation_variety_summary'), ('get_irrigation_daily_summary'),
      ('get_irrigation_monthly_summary'), ('get_irrigation_vintage_overview'),
      ('get_irrigation_daily_report'), ('get_irrigation_weekly_summary'),
      ('get_irrigation_monthly_report'), ('get_irrigation_valve_report'),
      ('get_irrigation_block_report'), ('get_irrigation_variety_report'),
      ('get_irrigation_water_source_summary'),
      ('get_irrigation_calculation_source_summary'),
      ('get_irrigation_record_source_summary'),
      ('get_irrigation_rainfall_summary'), ('get_irrigation_vintage_trends'),
      ('list_irrigation_report_sessions'), ('reverse_irrigation_import_batch')
  ) expected(fname)
  where exists (
    select 1 from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = expected.fname
      and (p.proconfig is null
           or not exists (select 1 from unnest(p.proconfig) c
                          where c like 'app.irrigation_capability=%')));
  if v_missing is not null then
    raise exception 'SQL 151 validation failed — unbound RPCs: %', v_missing;
  end if;

  -- 7b. Import-table policies repointed.
  if (select count(*) from pg_policies
      where schemaname = 'public'
        and tablename in ('irrigation_import_provider_settings',
                          'irrigation_controller_valve_mappings',
                          'irrigation_import_batches','irrigation_import_rows')
        and policyname like '%_select_import') <> 4 then
    raise exception 'SQL 151 validation failed — import RLS policies incomplete';
  end if;

  -- 7c. Unknown capability denies (never grants).
  if public.irrigation_capability(gen_random_uuid(), 'made_up_capability') then
    raise exception 'SQL 151 validation failed — unknown capability must deny';
  end if;

  raise notice 'SQL 151 applied: Irrigation Records released to vineyard roles (29 RPCs bound, 4 import policies repointed).';
end$$;
