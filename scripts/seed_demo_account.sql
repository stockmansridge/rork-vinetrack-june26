-- =====================================================================
-- seed_demo_account.sql   (MANUAL ONLY — run in the Supabase SQL editor)
-- =====================================================================
-- Purpose:
--   Attach a demo/testing account to a vineyard so it can sign in on
--   Android (or iOS) and see data immediately. Used for:
--     * internal testers on Google Play,
--     * Google Play review credentials (App content -> App access),
--     * sales/demo walkthroughs.
--
-- ⚠️  This file lives in scripts/, NOT sql/ — it is outside the numbered
--     migration stream and must never run automatically.
--
-- STEP 1 (manual, Supabase Dashboard):
--   Authentication -> Users -> "Add user" -> "Create new user"
--     * Email:    demo@yourdomain.com   (any address you control)
--     * Password: a strong password you can share with testers
--     * Tick "Auto Confirm User" so no verification email is needed.
--   (Alternatively: sign up inside the app with that email/password.)
--
-- STEP 2 (this script):
--   Edit the three placeholders below, then run the DO block.
--   It is idempotent — safe to re-run.
--
-- Role guidance:
--   'operator'   — safest for demos: day-to-day features, no team/admin.
--   'supervisor' — adds supervision features.
--   'manager'    — team management, settings.
--   'owner'      — full control; avoid for shared demo credentials.
-- =====================================================================

do $$
declare
  -- >>> EDIT THESE <<<
  _demo_email  text := 'REPLACE_ME@example.com';                          -- auth user created in STEP 1
  _vineyard_id uuid := '00000000-0000-0000-0000-000000000000'::uuid;      -- public.vineyards.id to attach to
  _role        text := 'operator';                                        -- owner | manager | supervisor | operator

  _user_id       uuid;
  _vineyard_name text;
begin
  -- Guards: refuse to run with un-edited placeholders.
  if _demo_email = 'REPLACE_ME@example.com' then
    raise exception 'Set _demo_email before running.';
  end if;
  if _vineyard_id = '00000000-0000-0000-0000-000000000000'::uuid then
    raise exception 'Set _vineyard_id before running. Find one with: select id, name from public.vineyards where deleted_at is null order by created_at desc;';
  end if;
  if _role not in ('owner', 'manager', 'supervisor', 'operator') then
    raise exception 'Role must be owner, manager, supervisor or operator.';
  end if;

  -- Resolve the auth user created in STEP 1.
  select id into _user_id
  from auth.users
  where lower(email) = lower(_demo_email)
  limit 1;

  if _user_id is null then
    raise exception 'No auth user found for %. Create it first (Dashboard -> Authentication -> Add user, with Auto Confirm).', _demo_email;
  end if;

  -- Confirm the target vineyard exists and is active.
  select name into _vineyard_name
  from public.vineyards
  where id = _vineyard_id and deleted_at is null;

  if _vineyard_name is null then
    raise exception 'Vineyard % not found (or soft-deleted).', _vineyard_id;
  end if;

  -- Ensure a profile row exists (normally created by the signup trigger;
  -- this covers dashboard-created users if the trigger is absent).
  insert into public.profiles (id, email, full_name)
  values (_user_id, _demo_email, 'Demo Account')
  on conflict (id) do nothing;

  -- Attach (or update) the vineyard membership.
  insert into public.vineyard_members (vineyard_id, user_id, role, display_name)
  values (_vineyard_id, _user_id, _role, 'Demo Account')
  on conflict (vineyard_id, user_id)
  do update set role = excluded.role;

  raise notice 'Demo account % (%) attached to vineyard "%" as %.',
    _demo_email, _user_id, _vineyard_name, _role;
end $$;

-- =====================================================================
-- Verify
-- =====================================================================
-- select vm.role, vm.display_name, v.name as vineyard, u.email
-- from public.vineyard_members vm
-- join public.vineyards v on v.id = vm.vineyard_id
-- join auth.users u on u.id = vm.user_id
-- where lower(u.email) = lower('REPLACE_ME@example.com');

-- =====================================================================
-- Cleanup (when the demo account is retired)
-- =====================================================================
-- 1) Remove the membership:
--   delete from public.vineyard_members vm
--   using auth.users u
--   where vm.user_id = u.id and lower(u.email) = lower('REPLACE_ME@example.com');
-- 2) Delete the user in Dashboard -> Authentication -> Users (cascades to profiles).
