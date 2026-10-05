-- tests/265_fertigation_system_admin_preview_tests.sql
-- Disposable structural/security checks for SQL 265.
begin;

do $$
declare
  v text;
begin
  if not exists (
    select 1 from information_schema.tables
    where table_schema='public' and table_name='fertigation_applications'
  ) then
    raise exception 'missing fertigation_applications';
  end if;

  if not exists (
    select 1 from information_schema.tables
    where table_schema='public' and table_name='fertigation_application_products'
  ) then
    raise exception 'missing fertigation_application_products';
  end if;

  select permissive into v
  from pg_policies
  where schemaname='public'
    and tablename='spray_jobs'
    and policyname='spray_jobs_fertigation_dev_select_guard';

  if v is distinct from 'RESTRICTIVE' then
    raise exception 'fertigation SELECT guard is not restrictive';
  end if;

  if has_table_privilege('authenticated', 'public.fertigation_applications', 'SELECT')
     or has_table_privilege('authenticated', 'public.fertigation_applications', 'INSERT')
     or has_table_privilege('authenticated', 'public.fertigation_applications', 'UPDATE')
     or has_table_privilege('authenticated', 'public.fertigation_applications', 'DELETE') then
    raise exception 'authenticated has direct fertigation_applications table privileges';
  end if;

  if has_table_privilege('authenticated', 'public.fertigation_application_products', 'SELECT')
     or has_table_privilege('authenticated', 'public.fertigation_application_products', 'INSERT')
     or has_table_privilege('authenticated', 'public.fertigation_application_products', 'UPDATE')
     or has_table_privilege('authenticated', 'public.fertigation_application_products', 'DELETE') then
    raise exception 'authenticated has direct fertigation product table privileges';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.get_fertigation_capabilities(uuid)',
    'EXECUTE'
  ) then
    raise exception 'authenticated cannot execute get_fertigation_capabilities';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.upsert_irrigation_fertigation(uuid,uuid,uuid,uuid,text,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'authenticated cannot execute upsert_irrigation_fertigation';
  end if;

  if has_function_privilege(
    'authenticated',
    'public._fertigation_require_dev_access(uuid)',
    'EXECUTE'
  ) then
    raise exception 'authenticated can execute private fertigation guard';
  end if;

  raise notice 'SQL 265 fertigation development foundation: structural checks passed';
end $$;

rollback;
