-- ============================================================================
-- App Review demo account: expired-trial configuration (self-contained)
-- ============================================================================
-- Purpose: create + configure a demo account whose free trial has ALREADY
-- EXPIRED so Apple App Review lands on the subscription paywall immediately
-- after login (Guideline 2.1(b) information request, Aug 11).
--
-- HOW TO RUN:
--   1. Edit v_password below (this is the password you will give Apple).
--   2. Run the whole script in the Supabase SQL editor. It is idempotent:
--      re-running updates the password and re-verifies the expired state.
--
-- What it does:
--   1. Creates the auth user (email/password, pre-confirmed) if missing;
--      if it already exists, resets the password to v_password.
--   2. Backdates auth.users.created_at by 4 months. This simultaneously:
--        - expires the CLIENT-side legacy free window (created_at + 3 months,
--          SubscriptionService.isInInitialFreeAccessPeriod), and
--        - makes the SERVER-authoritative account trial (sql/143/144) derive
--          as trial_ends_at in the past.
--   3. Rebuilds the vinetrack_account_trials row via _ensure_account_trial()
--      so its status is 'expired'.
--   4. Ensures a profiles row and provisions "App Review Demo Vineyard" with
--      an owner membership, so login routes past vineyard onboarding straight
--      to the entitlement gate -> paywall.
--   5. Verifies the final state and raises clear notices.
--
-- Result in-app: sign in -> accept disclaimer -> full-screen subscription
-- paywall (Monthly / Annual via Apple IAP, Restore Purchases, Sign Out only).
--
-- To reset later: delete the user in Dashboard -> Authentication (cascades
-- profiles/membership) and re-run this script.
-- ============================================================================

do $$
declare
  v_email       text := 'appreview@vinetrack.com.au';
  v_password    text := 'CHANGE-ME-BEFORE-RUNNING';   -- <<< EDIT: password for Apple
  v_uid         uuid;
  v_created     timestamptz;
  v_trial       record;
  v_vineyard_id uuid;
  v_count       bigint := 0;
begin
  if v_password = 'CHANGE-ME-BEFORE-RUNNING' then
    raise exception 'Edit v_password at the top of this script first (this is the password you will give Apple).';
  end if;

  -- ---- 0. Create or update the auth user --------------------------------------
  select u.id into v_uid
  from auth.users u
  where lower(u.email) = lower(v_email) and u.deleted_at is null;

  if v_uid is null then
    v_uid := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email,
      encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, recovery_token,
      email_change_token_new, email_change,
      is_super_admin
    ) values (
      '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', lower(v_email),
      extensions.crypt(v_password, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
      now(), now(),
      '', '',
      '', '',
      false
    );

    insert into auth.identities (
      provider_id, user_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) values (
      v_uid::text, v_uid,
      jsonb_build_object('sub', v_uid::text, 'email', lower(v_email), 'email_verified', true),
      'email',
      now(), now(), now()
    );

    raise notice 'Created auth user % (%)', v_email, v_uid;
  else
    update auth.users
    set encrypted_password = extensions.crypt(v_password, extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        updated_at = now()
    where id = v_uid;
    raise notice 'Auth user % already existed (%) — password reset to the value above', v_email, v_uid;
  end if;

  -- ---- 1. Backdate account creation (kills the client 3-month window) ---------
  update auth.users
  set created_at = now() - interval '4 months'
  where id = v_uid;

  select u.created_at into v_created from auth.users u where u.id = v_uid;
  raise notice 'auth.users.created_at backdated to % (client legacy free window now expired)', v_created;

  -- ---- 2. Profiles row (vineyard_members references profiles) -----------------
  insert into public.profiles (id, email, full_name)
  values (v_uid, lower(v_email), 'App Review')
  on conflict (id) do nothing;

  -- ---- 3. Server-authoritative trial: rebuild as EXPIRED -----------------------
  -- Delete any trial derived from a pre-backdate created_at, then let the
  -- canonical maintainer re-derive it from the (now backdated) created_at.
  delete from public.vinetrack_account_trials where user_id = v_uid;
  perform public._ensure_account_trial(v_uid);

  select t.status, t.trial_started_at, t.trial_ends_at
  into v_trial
  from public.vinetrack_account_trials t
  where t.user_id = v_uid;

  if v_trial is null then
    raise exception 'Trial row was not created — is sql/143 applied to this environment?';
  end if;
  if v_trial.status <> 'expired' then
    raise exception 'Trial status is % (expected expired). trial_ends_at=%', v_trial.status, v_trial.trial_ends_at;
  end if;
  raise notice 'Account trial: status=% started=% ends=% (EXPIRED as required)',
    v_trial.status, v_trial.trial_started_at, v_trial.trial_ends_at;

  -- ---- 4. Demo vineyard + owner membership -------------------------------------
  select m.vineyard_id into v_vineyard_id
  from public.vineyard_members m
  where m.user_id = v_uid
  limit 1;

  if v_vineyard_id is null then
    insert into public.vineyards (name, owner_id, country)
    values ('App Review Demo Vineyard', v_uid, 'Australia')
    returning id into v_vineyard_id;

    insert into public.vineyard_members (vineyard_id, user_id, role, display_name)
    values (v_vineyard_id, v_uid, 'owner', 'App Review');
    raise notice 'Provisioned "App Review Demo Vineyard" (%) with owner membership', v_vineyard_id;
  else
    raise notice 'User already has a vineyard membership (vineyard %)', v_vineyard_id;
  end if;

  -- ---- 5. Guard: nothing else may grant access ---------------------------------
  -- The resolver grants access from subscriptions/licences/manual grants before
  -- it ever looks at the trial. The demo account must have none of these.
  if to_regclass('public.vinetrack_subscriptions') is not null then
    execute 'select count(*) from public.vinetrack_subscriptions where owner_user_id = $1'
      into v_count using v_uid;
    if v_count > 0 then
      raise exception 'Demo user unexpectedly owns % subscription row(s) — remove them or use a different account', v_count;
    end if;
  end if;
  if to_regclass('public.vinetrack_licences') is not null then
    execute 'select count(*) from public.vinetrack_licences where assigned_user_id = $1'
      into v_count using v_uid;
    if v_count > 0 then
      raise exception 'Demo user unexpectedly holds % assigned licence(s) — remove them or use a different account', v_count;
    end if;
  end if;

  raise notice '=== DONE: % will resolve to DENIED (paywall) on next sign-in ===', v_email;
  raise notice 'Reviewer path: Sign In -> accept disclaimer -> subscription paywall (Apple IAP only).';
end$$;
