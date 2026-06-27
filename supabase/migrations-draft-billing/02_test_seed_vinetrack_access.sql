-- =====================================================================
-- 02_test_seed_vinetrack_access.sql   (DRAFT — TEST SEED, manual only)
-- =====================================================================
-- Purpose:
--   Seed test rows so you can exercise the new VineTrack access resolver
--   on iOS via the Backend Diagnostic view ("VineTrack Access Resolution"
--   section), BEFORE the new billing/access model is enforced anywhere.
--
-- ⚠️  DRAFT / MANUAL ONLY.
--   * This file lives in supabase/migrations-draft-billing/, NOT in sql/.
--     It is intentionally OUTSIDE the numbered migration stream, so it will
--     NOT run automatically and will NOT be applied to production.
--   * It depends on the draft tables/RPC created by
--     01_vinetrack_pricing_entitlements.sql. Run that first (in a test
--     project) if the vinetrack_* tables don't exist yet.
--   * You MUST replace the placeholder ids below before running anything.
--     The script raises an exception if the placeholders are left unset.
--   * Copy ONLY the block(s) you need into the Supabase SQL editor, or run
--     the whole file after editing the placeholders. Each block is wrapped
--     in its own DO $$ ... $$ so they're independent and idempotent.
--
-- What it seeds (one block per tier — all OPTIONAL):
--   1. Solo        — provider revenuecat, status trialing, basic portal.
--   2. Team        — provider stripe,     status active,   full portal.
--   3. Enterprise  — provider manual,     status active,   custom portal.
--
-- Schema notes (important — maps your request onto the real columns):
--   * vinetrack_subscriptions has NO `owner_type`/`owner_id` columns. A
--     subscription is always owned by a USER via `owner_user_id`, with an
--     optional `primary_vineyard_id` for the business/vineyard context.
--     So:  owner_type=user      -> owner_user_id = _test_user_id
--          owner_type=business/ -> owner_user_id = _test_user_id (the owner)
--          owner_type=vineyard     primary_vineyard_id = _test_vineyard_id
--   * There is NO `role` column on the billing tables. Role (owner/manager/
--     operator) lives in public.vineyard_members and is resolved by the app
--     separately — it is NOT part of get_my_vinetrack_access(). An optional,
--     commented helper at the bottom of each block shows how to ensure a
--     vineyard membership role exists for the test user if you need it.
--   * Portal access level is derived from the PLAN, not the subscription:
--       solo -> 'basic', team -> 'full', enterprise -> 'custom'.
--     get_my_vinetrack_access() reads plan.portal_access_level, so you do
--     NOT set portal access on the subscription/licence directly.
--   * Seats: `seats_included` mirrors the plan's included licences;
--     `seats_purchased` is extra paid seats. Each active licence row in
--     vinetrack_user_licences consumes one seat for one user.
--
-- How to verify after seeding:
--   * On device: open Backend Diagnostic -> "VineTrack Access Resolution"
--     -> Resolve. Or call the RPC directly in the SQL editor AS the test
--     user (the RPC uses auth.uid(), so direct SQL-editor calls run as the
--     service role / your editor session, not the test user — prefer device
--     testing for an end-to-end check). For a raw data sanity check:
--       select * from public.vinetrack_subscriptions where owner_user_id = '<_test_user_id>';
--       select * from public.vinetrack_user_licences   where user_id      = '<_test_user_id>';
--
-- Cleanup:
--   * A commented cleanup block is at the very bottom. Uncomment and set the
--     same _test_user_id to remove the seeded subscriptions/licences.
-- =====================================================================


-- =====================================================================
-- PLACEHOLDERS — EDIT THESE FIRST
-- =====================================================================
-- Replace the three values below with real ids from your TEST project.
--   _test_user_id     : the auth.users.id of the signed-in test account.
--   _test_vineyard_id : a public.vineyards.id the test user belongs to.
--   _test_email       : the test account email (used for invited_email and
--                       as a readable label in metadata).
--
-- Find them with, e.g.:
--   select id, email from auth.users where email = 'you@example.com';
--   select id, name  from public.vineyards order by created_at desc limit 20;
--
-- Each block re-declares these placeholders locally so blocks stay
-- copy-paste independent. Update them in EVERY block you intend to run.
-- =====================================================================


-- =====================================================================
-- BLOCK 1 — SOLO test subscription  (provider revenuecat, trialing)
-- =====================================================================
-- Tier: solo | Provider: revenuecat | Status: trialing (3-month trial)
-- Owner: the test user | Portal: resolves to 'basic' (from the solo plan)
-- Creates: 1 subscription + 1 active user licence for _test_user_id.
--
-- Expected resolver result on iOS:
--   has_supabase_access depends on how the app treats Solo. The RPC reports
--   access_source='solo' is NOT a Supabase-granted tier — Solo lives with
--   Apple/RevenueCat. NOTE: the draft RPC only grants Supabase access for
--   team/enterprise/legacy tiers; for a 'solo' plan it will set
--   solo_check_required=true (so the app falls back to RevenueCat). This
--   block is still useful to confirm the Solo subscription/licence rows
--   exist and that the resolver correctly defers to RevenueCat.
-- ---------------------------------------------------------------------
do $$
declare
  -- >>> EDIT THESE <<<
  _test_user_id     uuid := '00000000-0000-0000-0000-000000000000'::uuid; -- auth.users.id
  _test_vineyard_id uuid := '00000000-0000-0000-0000-000000000000'::uuid; -- public.vineyards.id (optional context)
  _test_email       text := 'REPLACE_ME@example.com';

  _plan_id   uuid;
  _sub_id    uuid;
  _plan_seats integer;
begin
  -- Guard: refuse to run with un-edited placeholders.
  if _test_user_id = '00000000-0000-0000-0000-000000000000'::uuid then
    raise exception 'BLOCK 1 (Solo): set _test_user_id before running.';
  end if;

  -- Resolve the seeded 'solo' plan from the catalogue.
  select id, coalesce(included_user_licences, 1)
    into _plan_id, _plan_seats
  from public.vinetrack_plans
  where code = 'solo';

  if _plan_id is null then
    raise exception 'BLOCK 1 (Solo): plan code "solo" not found. Run 01_vinetrack_pricing_entitlements.sql first.';
  end if;

  -- Upsert the subscription (idempotent on (owner_user_id, plan_id) for tests).
  -- We look for an existing non-deleted row for this owner+plan and refresh it,
  -- otherwise insert a new one.
  select id into _sub_id
  from public.vinetrack_subscriptions
  where owner_user_id = _test_user_id
    and plan_id = _plan_id
    and deleted_at is null
  limit 1;

  if _sub_id is null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
       trial_start, trial_end, current_period_start, current_period_end,
       seats_included, seats_purchased, revenuecat_app_user_id, started_at,
       notes, metadata, created_by, updated_by)
    values
      (_test_user_id, _test_vineyard_id, _plan_id, 'apple', 'trialing',
       now(), now() + interval '90 days', now(), now() + interval '90 days',
       _plan_seats, 0, _test_user_id::text, now(),
       'TEST SEED — Solo', jsonb_build_object('test_seed', true, 'email', _test_email),
       _test_user_id, _test_user_id)
    returning id into _sub_id;
  else
    update public.vinetrack_subscriptions
    set billing_provider = 'apple',
        status = 'trialing',
        trial_start = now(),
        trial_end = now() + interval '90 days',
        current_period_start = now(),
        current_period_end = now() + interval '90 days',
        seats_included = _plan_seats,
        primary_vineyard_id = _test_vineyard_id,
        notes = 'TEST SEED — Solo (refreshed)',
        metadata = jsonb_build_object('test_seed', true, 'email', _test_email),
        updated_by = _test_user_id,
        deleted_at = null
    where id = _sub_id;
  end if;

  -- Active user licence for the test user (one active per subscription+user).
  insert into public.vinetrack_user_licences
    (subscription_id, user_id, invited_email, vineyard_id, status, assigned_by, metadata)
  values
    (_sub_id, _test_user_id, _test_email, _test_vineyard_id, 'active', _test_user_id,
     jsonb_build_object('test_seed', true))
  on conflict (subscription_id, user_id) where (status = 'active' and user_id is not null)
  do update set
    invited_email = excluded.invited_email,
    vineyard_id = excluded.vineyard_id,
    status = 'active',
    revoked_at = null,
    metadata = excluded.metadata;

  raise notice 'BLOCK 1 (Solo): subscription % seeded with active licence for %.', _sub_id, _test_user_id;

  -- OPTIONAL — ensure a vineyard membership role of 'owner' for the test user.
  -- Role is NOT part of the billing tables; uncomment if your test needs it
  -- and your vineyard_members schema matches (adjust columns as needed):
  --
  -- insert into public.vineyard_members (vineyard_id, user_id, role)
  -- values (_test_vineyard_id, _test_user_id, 'owner')
  -- on conflict (vineyard_id, user_id) do update set role = 'owner';
end;
$$;


-- =====================================================================
-- BLOCK 2 — TEAM test subscription  (provider stripe, active)
-- =====================================================================
-- Tier: team | Provider: stripe | Status: active
-- Owner: the test user (the business/vineyard owner) with
--   primary_vineyard_id = _test_vineyard_id (the "business/vineyard" context).
-- Included licences: 3 (from the team plan) | Portal: resolves to 'full'.
-- Creates: 1 subscription + 1 active user licence for _test_user_id.
--
-- Expected resolver result on iOS:
--   has_supabase_access = true, access_source = 'team',
--   portal_access = true, portal_access_level = 'full',
--   can_use_ios_app = true, solo_check_required = false.
-- ---------------------------------------------------------------------
do $$
declare
  -- >>> EDIT THESE <<<
  _test_user_id     uuid := '00000000-0000-0000-0000-000000000000'::uuid; -- auth.users.id (the Team owner)
  _test_vineyard_id uuid := '00000000-0000-0000-0000-000000000000'::uuid; -- public.vineyards.id (business/vineyard context)
  _test_email       text := 'REPLACE_ME@example.com';

  _plan_id   uuid;
  _sub_id    uuid;
  _plan_seats integer;
begin
  if _test_user_id = '00000000-0000-0000-0000-000000000000'::uuid then
    raise exception 'BLOCK 2 (Team): set _test_user_id before running.';
  end if;
  if _test_vineyard_id = '00000000-0000-0000-0000-000000000000'::uuid then
    raise exception 'BLOCK 2 (Team): set _test_vineyard_id (the business/vineyard context) before running.';
  end if;

  select id, coalesce(included_user_licences, 3)
    into _plan_id, _plan_seats
  from public.vinetrack_plans
  where code = 'team';

  if _plan_id is null then
    raise exception 'BLOCK 2 (Team): plan code "team" not found. Run 01_vinetrack_pricing_entitlements.sql first.';
  end if;

  select id into _sub_id
  from public.vinetrack_subscriptions
  where owner_user_id = _test_user_id
    and plan_id = _plan_id
    and deleted_at is null
  limit 1;

  if _sub_id is null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
       current_period_start, current_period_end,
       seats_included, seats_purchased,
       stripe_customer_id, stripe_subscription_id, started_at,
       notes, metadata, created_by, updated_by)
    values
      (_test_user_id, _test_vineyard_id, _plan_id, 'stripe', 'active',
       now(), now() + interval '1 year',
       _plan_seats, 0,
       'cus_TEST_SEED', 'sub_TEST_SEED', now(),
       'TEST SEED — Team', jsonb_build_object('test_seed', true, 'email', _test_email),
       _test_user_id, _test_user_id)
    returning id into _sub_id;
  else
    update public.vinetrack_subscriptions
    set billing_provider = 'stripe',
        status = 'active',
        current_period_start = now(),
        current_period_end = now() + interval '1 year',
        seats_included = _plan_seats,
        primary_vineyard_id = _test_vineyard_id,
        stripe_customer_id = coalesce(stripe_customer_id, 'cus_TEST_SEED'),
        stripe_subscription_id = coalesce(stripe_subscription_id, 'sub_TEST_SEED'),
        notes = 'TEST SEED — Team (refreshed)',
        metadata = jsonb_build_object('test_seed', true, 'email', _test_email),
        updated_by = _test_user_id,
        deleted_at = null
    where id = _sub_id;
  end if;

  -- Active licence for the test user (owner consumes one of the 3 seats).
  insert into public.vinetrack_user_licences
    (subscription_id, user_id, invited_email, vineyard_id, status, assigned_by, metadata)
  values
    (_sub_id, _test_user_id, _test_email, _test_vineyard_id, 'active', _test_user_id,
     jsonb_build_object('test_seed', true))
  on conflict (subscription_id, user_id) where (status = 'active' and user_id is not null)
  do update set
    invited_email = excluded.invited_email,
    vineyard_id = excluded.vineyard_id,
    status = 'active',
    revoked_at = null,
    metadata = excluded.metadata;

  raise notice 'BLOCK 2 (Team): subscription % seeded (3 seats) with active licence for %.', _sub_id, _test_user_id;

  -- OPTIONAL — ensure vineyard membership role 'owner' (or 'manager') for full
  -- portal/role behaviour in the app. Adjust to your vineyard_members schema:
  --
  -- insert into public.vineyard_members (vineyard_id, user_id, role)
  -- values (_test_vineyard_id, _test_user_id, 'owner')
  -- on conflict (vineyard_id, user_id) do update set role = 'owner';
end;
$$;


-- =====================================================================
-- BLOCK 3 — ENTERPRISE test subscription  (provider manual, active)
-- =====================================================================
-- Tier: enterprise | Provider: manual | Status: active
-- Owner: the test user | Portal: resolves to 'custom'.
-- Custom seat allowance: the enterprise plan has no fixed included seats
--   (null / custom), so we set a custom seats_included here for testing.
-- Creates: 1 subscription + 1 active user licence for _test_user_id.
--
-- Expected resolver result on iOS:
--   has_supabase_access = true, access_source = 'enterprise',
--   portal_access = true, portal_access_level = 'custom',
--   can_use_ios_app = true, solo_check_required = false.
-- ---------------------------------------------------------------------
do $$
declare
  -- >>> EDIT THESE <<<
  _test_user_id     uuid := '00000000-0000-0000-0000-000000000000'::uuid; -- auth.users.id
  _test_vineyard_id uuid := '00000000-0000-0000-0000-000000000000'::uuid; -- public.vineyards.id (optional context)
  _test_email       text := 'REPLACE_ME@example.com';

  -- Custom seat allowance for this Enterprise test subscription.
  _custom_seats integer := 25;

  _plan_id uuid;
  _sub_id  uuid;
begin
  if _test_user_id = '00000000-0000-0000-0000-000000000000'::uuid then
    raise exception 'BLOCK 3 (Enterprise): set _test_user_id before running.';
  end if;

  select id into _plan_id
  from public.vinetrack_plans
  where code = 'enterprise';

  if _plan_id is null then
    raise exception 'BLOCK 3 (Enterprise): plan code "enterprise" not found. Run 01_vinetrack_pricing_entitlements.sql first.';
  end if;

  select id into _sub_id
  from public.vinetrack_subscriptions
  where owner_user_id = _test_user_id
    and plan_id = _plan_id
    and deleted_at is null
  limit 1;

  if _sub_id is null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
       current_period_start, current_period_end,
       seats_included, seats_purchased, started_at,
       notes, metadata, created_by, updated_by)
    values
      (_test_user_id, _test_vineyard_id, _plan_id, 'manual', 'active',
       now(), now() + interval '1 year',
       _custom_seats, 0, now(),
       'TEST SEED — Enterprise',
       jsonb_build_object('test_seed', true, 'email', _test_email, 'custom_seats', _custom_seats),
       _test_user_id, _test_user_id)
    returning id into _sub_id;
  else
    update public.vinetrack_subscriptions
    set billing_provider = 'manual',
        status = 'active',
        current_period_start = now(),
        current_period_end = now() + interval '1 year',
        seats_included = _custom_seats,
        primary_vineyard_id = _test_vineyard_id,
        notes = 'TEST SEED — Enterprise (refreshed)',
        metadata = jsonb_build_object('test_seed', true, 'email', _test_email, 'custom_seats', _custom_seats),
        updated_by = _test_user_id,
        deleted_at = null
    where id = _sub_id;
  end if;

  insert into public.vinetrack_user_licences
    (subscription_id, user_id, invited_email, vineyard_id, status, assigned_by, metadata)
  values
    (_sub_id, _test_user_id, _test_email, _test_vineyard_id, 'active', _test_user_id,
     jsonb_build_object('test_seed', true))
  on conflict (subscription_id, user_id) where (status = 'active' and user_id is not null)
  do update set
    invited_email = excluded.invited_email,
    vineyard_id = excluded.vineyard_id,
    status = 'active',
    revoked_at = null,
    metadata = excluded.metadata;

  raise notice 'BLOCK 3 (Enterprise): subscription % seeded (% seats) with active licence for %.', _sub_id, _custom_seats, _test_user_id;

  -- OPTIONAL — ensure vineyard membership role 'owner'/'admin' for the test user:
  --
  -- insert into public.vineyard_members (vineyard_id, user_id, role)
  -- values (_test_vineyard_id, _test_user_id, 'owner')
  -- on conflict (vineyard_id, user_id) do update set role = 'owner';
end;
$$;


-- =====================================================================
-- CLEANUP — remove all TEST SEED data for a given test user (COMMENTED)
-- =====================================================================
-- Uncomment and set _test_user_id to the SAME id you seeded with. This
-- removes the seeded licences and subscriptions (only the test-seed rows
-- created by this script, identified by metadata.test_seed = true).
--
-- ⚠️  Review before running. It deletes rows; there is no undo.
-- ---------------------------------------------------------------------
-- do $$
-- declare
--   _test_user_id uuid := '00000000-0000-0000-0000-000000000000'::uuid; -- SAME id you seeded
-- begin
--   if _test_user_id = '00000000-0000-0000-0000-000000000000'::uuid then
--     raise exception 'CLEANUP: set _test_user_id before running.';
--   end if;
--
--   -- Delete licences belonging to this user's test-seed subscriptions.
--   delete from public.vinetrack_user_licences l
--   using public.vinetrack_subscriptions s
--   where l.subscription_id = s.id
--     and s.owner_user_id = _test_user_id
--     and coalesce((s.metadata->>'test_seed')::boolean, false) = true;
--
--   -- Also delete any licences directly assigned to this user with test_seed metadata.
--   delete from public.vinetrack_user_licences
--   where user_id = _test_user_id
--     and coalesce((metadata->>'test_seed')::boolean, false) = true;
--
--   -- Delete the test-seed subscriptions for this owner.
--   delete from public.vinetrack_subscriptions
--   where owner_user_id = _test_user_id
--     and coalesce((metadata->>'test_seed')::boolean, false) = true;
--
--   raise notice 'CLEANUP: removed TEST SEED subscriptions/licences for %.', _test_user_id;
--
--   -- OPTIONAL — also remove the test vineyard membership if you added one:
--   -- delete from public.vineyard_members
--   -- where user_id = _test_user_id and vineyard_id = '00000000-0000-0000-0000-000000000000'::uuid;
-- end;
-- $$;
