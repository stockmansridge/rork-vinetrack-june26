-- 107_worker_types_drop_compat.sql
--
-- ⚠️  DO NOT RUN IMMEDIATELY. This is the deferred cleanup for the
--     worker_types rename (sql/106_worker_types_rename.sql, applied 2026-07-12).
--
--     Run this 1–2 months later (target: on/after 2026-09-01), ONLY after
--     confirming:
--       1. The web portal (Lovable) release that queries public.worker_types
--          directly has been live for several weeks with no rollback.
--       2. No external SQL, exports, or integrations still reference
--          public.operator_categories or the *_operator_category functions.
--
-- What it removes (all created as a compatibility layer by migration 106):
--   - view      public.operator_categories
--   - function  public.soft_delete_operator_category(uuid)
--   - function  public.upsert_operator_category(uuid, text, double precision)
--   - function  public.merge_operator_categories(uuid, uuid)
--   - function  public.update_member_operator_category(uuid, uuid, uuid)
--   - function  public.operator_category_normalised_name(text)
--   - legacy operator_category_id / operator_category_name columns from
--     get_vineyard_team_members (recreated with worker_type_* only)
--
-- What it deliberately KEEPS:
--   - public.create_invitation with its p_operator_category_id parameter name.
--     Both apps and the portal call it positionally/by that name; renaming the
--     parameter would break callers for zero benefit. It already validates
--     against worker_types internally.
--
-- Re-runnable: every step is guarded with IF EXISTS.

begin;

-- ---------------------------------------------------------------------------
-- 0. Preflight guard: abort if the legacy view has already been replaced by a
--    real table (would indicate an unexpected state), or if migration 106 was
--    never applied (worker_types missing).
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.worker_types') is null then
    raise exception 'Preflight failed: public.worker_types does not exist. Run sql/106_worker_types_rename.sql first.';
  end if;

  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public'
      and table_name = 'operator_categories'
      and table_type = 'BASE TABLE'
  ) then
    raise exception 'Preflight failed: public.operator_categories is a BASE TABLE, not the compatibility view. Investigate before dropping.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Drop the compatibility view
-- ---------------------------------------------------------------------------
drop view if exists public.operator_categories;

-- ---------------------------------------------------------------------------
-- 2. Drop the function aliases
-- ---------------------------------------------------------------------------
drop function if exists public.soft_delete_operator_category(uuid);
drop function if exists public.upsert_operator_category(uuid, text, double precision);
drop function if exists public.merge_operator_categories(uuid, uuid);
drop function if exists public.update_member_operator_category(uuid, uuid, uuid);
drop function if exists public.operator_category_normalised_name(text);

-- ---------------------------------------------------------------------------
-- 3. get_vineyard_team_members — recreate WITHOUT the legacy
--    operator_category_id / operator_category_name columns.
--    (Return type changes, so drop + create is required.)
-- ---------------------------------------------------------------------------
drop function if exists public.get_vineyard_team_members(uuid);

create function public.get_vineyard_team_members(p_vineyard_id uuid)
returns table (
  membership_id uuid,
  vineyard_id uuid,
  user_id uuid,
  role text,
  joined_at timestamptz,
  display_name text,
  full_name text,
  email text,
  avatar_url text,
  worker_type_id uuid,
  worker_type_name text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_vineyard_id is null then
    raise exception 'p_vineyard_id is required';
  end if;

  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'not a member of this vineyard'
      using errcode = '42501';
  end if;

  return query
  select
    vm.id            as membership_id,
    vm.vineyard_id   as vineyard_id,
    vm.user_id       as user_id,
    vm.role          as role,
    vm.joined_at     as joined_at,
    coalesce(
      nullif(btrim(vm.display_name), ''),
      nullif(btrim(p.full_name), ''),
      nullif(btrim(p.email), ''),
      nullif(btrim(au.email), ''),
      'User ' || substr(vm.user_id::text, 1, 8)
    )                as display_name,
    p.full_name      as full_name,
    coalesce(nullif(btrim(p.email), ''), au.email) as email,
    p.avatar_url     as avatar_url,
    vm.worker_type_id as worker_type_id,
    wt.name          as worker_type_name
  from public.vineyard_members vm
  left join public.profiles p on p.id = vm.user_id
  left join auth.users au on au.id = vm.user_id
  left join public.worker_types wt
    on wt.id = vm.worker_type_id
   and wt.deleted_at is null
  where vm.vineyard_id = p_vineyard_id
  order by vm.joined_at asc, vm.id asc;
end;
$$;

revoke all on function public.get_vineyard_team_members(uuid) from public;
grant execute on function public.get_vineyard_team_members(uuid) to authenticated;

comment on function public.get_vineyard_team_members(uuid) is
  $c$Returns display-safe team member info for a vineyard the caller is a member of. Canonical worker_type_id/worker_type_name columns only (legacy operator_category aliases removed by migration 107).$c$;

-- ---------------------------------------------------------------------------
-- 4. Update the table comment now that the legacy view is gone
-- ---------------------------------------------------------------------------
comment on table public.worker_types is
  'Per-vineyard worker types (role name + hourly cost). Formerly operator_categories; compatibility layer removed by migration 107.';

commit;

-- ---------------------------------------------------------------------------
-- Verification queries (run manually after this migration)
-- ---------------------------------------------------------------------------
-- Should return NULL (view gone):
--   select to_regclass('public.operator_categories');
-- Should return 0 rows (aliases gone):
--   select proname from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and proname in (
--     'soft_delete_operator_category', 'upsert_operator_category',
--     'merge_operator_categories', 'update_member_operator_category',
--     'operator_category_normalised_name');
-- Should still work and return worker_type_* columns only:
--   select worker_type_id, worker_type_name
--   from public.get_vineyard_team_members('<vineyard_id>') limit 5;
-- create_invitation is intentionally unchanged:
--   select pg_get_function_arguments('public.create_invitation'::regproc);
