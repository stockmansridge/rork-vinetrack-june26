-- ============================================================================
-- App Review demo account: expired-trial configuration
-- ============================================================================
-- Purpose: configure a demo account whose free trial has ALREADY EXPIRED so
-- Apple App Review lands on the subscription paywall immediately after login
-- (Guideline 2.1(b) information request, Aug 11).
--
-- PREREQUISITE (one manual step, ~30 seconds):
--   Supabase Dashboard -> Authentication -> Users -> "Add user"
--     Email:    appreview@vinetrack.com.au      (or edit v_email below)
--     Password: choose the password you will give Apple
--     Tick "Auto Confirm User"
--
-- Then run this whole script in the SQL editor. It is idempotent.
--
-- What it does:
--   1. Backdates auth.users.created_at by 4 months. This simultaneously:
--        - expires the CLIENT-side legacy free window (created_at + 3 months,
--          SubscriptionService.isInInitialFreeAccessPeriod), and
--        - makes the SERVER-authoritative account trial (sql/143/144) derive
--          as trial_ends_at in the past.
--   2. Rebuilds the vinetrack_account_trials row via _ensure_account_trial()
--      so its status is 'expired' (deletes any previously-derived row first —
--      needed if the account ever signed in before being backdated).
--   3. Ensures a profiles row and provisions "App Review Demo Vineyard" with
--      an owner membership, so login routes past vineyard onboarding and the
--      disclaimer straight to the entitlement gate -> paywall.
--   4. Verifies the final state and raises clear notices.
--
-- Result in-app: sign in -> accept disclaimer -> full-screen subscription
-- paywall (Monthly / Annual via Apple IAP, Restore Purchases, Sign Out only).
--
-- To reset the account later: delete the user in the Auth dashboard (cascades
-- profiles/membership) and re-run the prerequisite + this script.
-- ============================================================================

do $$
declare
  v_email       text := 'appreview@vinetrack.com.au';  -- EDIT if you chose a different address
  v_uid         uuid;
  v_created     timestamptz;
  v_trial       record;
  v_vineyard_id uuid;
  v_subs        bigint := 0;
begin
  -- ---- 0. Locate the auth user ------------------------------------------------
  select u.id into v_uid
  from auth.users u
  where lower(u.email) = lower(v_email) and u.deleted_at is null;

  if v_uid is null then
    raise exception 'No auth user found for %. Create it first in Dashboard -> Authentication -> Users -> Add user (tick Auto Confirm), then re-run.', v_email;
  end if;

  -- ---- 1. Backdate account creation (kills the client 3-month window) ---------
  update auth.users
  set created_at = now() - interval '4 months'
  where id = v_uid;

  select u.created_at into v_created from auth.users u where u.id = v_uid;
  raise notice 'auth.users.created_at backdated to % (client legacy free window now expired)', v_created;

  -- ---- 2. Profiles row (vineyard_members references profiles) -----------------
  insert into public.profiles (id, email, full_name)
  values (v_uid, v_email, 'App Review')
  on conflict (id) do nothing;

  -- ---- 3. Server-authoritative trial: rebuild as EXPIRED -----------------------
  -- Delete any trial derived from the pre-backdate created_at, then let the
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
  -- it ever looks at the trial. A fresh demo account must have none of these.
  if to_regclass('public.vinetrack_subscriptions') is not null then
    execute 'select count(*) from public.vinetrack_subscriptions where owner_user_id = $1'
      into v_subs using v_uid;
    if v_subs > 0 then
      raise exception 'Demo user unexpectedly owns % subscription row(s) — remove them or use a different account', v_subs;
    end if;
  end if;
  if to_regclass('public.vinetrack_licences') is not null then
    execute 'select count(*) from public.vinetrack_licences where assigned_user_id = $1'
      into v_subs using v_uid;
    if v_subs > 0 then
      raise exception 'Demo user unexpectedly holds % assigned licence(s) — remove them or use a different account', v_subs;
    end if;
  end if;

  raise notice '=== DONE: % will resolve to DENIED (paywall) on next sign-in ===', v_email;
  raise notice 'Reviewer path: Sign In -> accept disclaimer -> subscription paywall (Apple IAP only).';
end$$;
