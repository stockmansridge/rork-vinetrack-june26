-- =====================================================================
-- 176_integration_api_stage3d_environment_tests.sql
-- =====================================================================
-- Read-only verification for sql/176 (Stage 3D environment support).
-- Run in the Supabase SQL editor AFTER applying sql/176. Produces one
-- row per check with PASS/FAIL. Makes NO data changes.
-- =====================================================================

with checks as (

  -- 1. Cache table exists
  select 1 as ord, 'integration_environment_cache table exists' as check_name,
    exists (
      select 1 from information_schema.tables
      where table_schema = 'public' and table_name = 'integration_environment_cache'
    ) as pass

  union all
  -- 2. Cache table has RLS enabled
  select 2, 'integration_environment_cache has RLS enabled',
    coalesce((
      select c.relrowsecurity
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = 'integration_environment_cache'
    ), false)

  union all
  -- 3. Cache table has NO policies (service-role only access)
  select 3, 'integration_environment_cache has no RLS policies',
    not exists (
      select 1 from pg_policies
      where schemaname = 'public' and tablename = 'integration_environment_cache'
    )

  union all
  -- 4. No direct grants to anon / authenticated on the cache table
  select 4, 'integration_environment_cache not granted to anon/authenticated',
    not exists (
      select 1 from information_schema.role_table_grants
      where table_schema = 'public'
        and table_name = 'integration_environment_cache'
        and grantee in ('anon', 'authenticated')
    )

  union all
  -- 5. Unique constraint on (vineyard_id, kind)
  select 5, 'integration_environment_cache unique (vineyard_id, kind)',
    exists (
      select 1
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = 'integration_environment_cache'
        and con.contype = 'u'
        and (
          select array_agg(a.attname order by a.attname)
          from unnest(con.conkey) k
          join pg_attribute a on a.attrelid = c.oid and a.attnum = k
        ) = array['kind', 'vineyard_id']::name[]
    )

  union all
  -- 6. kind CHECK constraint limits values to forecast / disease_risk
  select 6, 'integration_environment_cache kind CHECK present',
    exists (
      select 1
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = 'integration_environment_cache'
        and con.contype = 'c'
        and pg_get_constraintdef(con.oid) ilike '%forecast%'
        and pg_get_constraintdef(con.oid) ilike '%disease_risk%'
    )

  union all
  -- 7. integration_get_rainfall function exists with the right signature
  select 7, 'integration_get_rainfall(uuid,date,date,date,integer) exists',
    exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = 'integration_get_rainfall'
        and pg_get_function_identity_arguments(p.oid)
          = 'p_vineyard_id uuid, p_from date, p_to date, p_before date, p_limit integer'
    )

  union all
  -- 8. Function is SECURITY DEFINER
  select 8, 'integration_get_rainfall is SECURITY DEFINER',
    coalesce((
      select p.prosecdef from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'integration_get_rainfall'
      limit 1
    ), false)

  union all
  -- 9. Function is NOT executable by anon / authenticated
  select 9, 'integration_get_rainfall revoked from anon/authenticated',
    not exists (
      select 1 from information_schema.routine_privileges
      where routine_schema = 'public'
        and routine_name = 'integration_get_rainfall'
        and grantee in ('anon', 'authenticated', 'PUBLIC')
    )

  union all
  -- 10. Function IS executable by service_role
  select 10, 'integration_get_rainfall granted to service_role',
    exists (
      select 1 from information_schema.routine_privileges
      where routine_schema = 'public'
        and routine_name = 'integration_get_rainfall'
        and grantee = 'service_role'
    )

  union all
  -- 11. Smoke test: unknown vineyard returns zero rows (no error, no leak)
  select 11, 'integration_get_rainfall smoke test (unknown vineyard -> 0 rows)',
    (select count(*) = 0 from public.integration_get_rainfall(
      '00000000-0000-0000-0000-000000000000'::uuid, null, null, null, 10))

  union all
  -- 12. Priority CASE mirrors get_daily_rainfall (source families intact)
  select 12, 'integration_get_rainfall body carries the canonical source priority',
    exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = 'integration_get_rainfall'
        and p.prosrc ilike '%manual%'
        and p.prosrc ilike '%davis_weatherlink%'
        and p.prosrc ilike '%wunderground_pws%'
        and p.prosrc ilike '%open_meteo%'
        and p.prosrc ilike '%deleted_at is null%'
    )
)
select ord, check_name, case when pass then 'PASS' else 'FAIL' end as result
from checks
order by ord;
