-- =====================================================================
-- 153_vineyard_owner_billing_tests.sql — Phase 2E security tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/152 AND sql/153.
-- Everything runs inside ONE transaction that is ROLLED BACK — no
-- production data is touched. Expected final output:
--   NOTICE: SQL 152/153 vineyard owner billing tests: ALL PASSED
--
-- NOTE: the SQL editor runs as postgres (RLS bypassed), so these tests
-- exercise the RPC-level checks — which are the customer security
-- boundary (direct table reads were removed in SQL 153; the Edge
-- Functions reuse the same helpers asserted here).
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 152 + 153 are applied.
do $$
begin
  if to_regprocedure('public.get_my_billing_vineyards()') is null
     or to_regprocedure('public.get_my_vineyard_billing_summary(uuid)') is null
     or to_regprocedure('public.get_my_vineyard_billing_history(uuid,integer,integer)') is null
     or to_regprocedure('public.get_my_vineyard_billing_licences(uuid)') is null then
    raise exception 'SQL 152/153 not applied — run both migrations first.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vinetrack_invoice_records'
      and column_name = 'external_customer_id'
  ) then
    raise exception 'SQL 153 not applied — invoice columns missing.';
  end if;
end$$;

do $$
declare
  -- vineyards
  v_yard_a uuid;  -- Stripe-billed (Team), two Owner-role members
  v_yard_b uuid;  -- owned by an unrelated user (foreign vineyard)
  v_yard_c uuid;  -- Apple store-managed subscription
  v_yard_d uuid;  -- account-trial only (no subscription)

  -- users
  u_o1   uuid;  -- Owner member of A + C, Stripe billing owner of A's sub
  u_o2   uuid;  -- Owner member of A, NOT the billing owner
  u_mgr  uuid;  -- manager of A
  u_sup  uuid;  -- supervisor of A
  u_op   uuid;  -- operator of A
  u_lic  uuid;  -- assigned licence user (operator member, licence holder)
  u_sys  uuid;  -- System Admin, NO memberships
  u_oth  uuid;  -- owner of foreign vineyard B
  u_o3   uuid;  -- owner of trial vineyard D

  v_plan uuid;
  v_sub_a uuid;
  v_sub_b uuid;
  v_sub_c uuid;

  v_sum   jsonb;
  v_n     integer;
  v_total bigint;
  ok      boolean;
begin
  -- ======================================================================
  -- Fixtures (all rolled back)
  -- ======================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t153-o1@test.local','t153-o2@test.local','t153-mgr@test.local',
                    't153-sup@test.local','t153-op@test.local','t153-lic@test.local',
                    't153-sys@test.local','t153-oth@test.local','t153-o3@test.local']) as e;

  select id into u_o1  from auth.users where email = 't153-o1@test.local';
  select id into u_o2  from auth.users where email = 't153-o2@test.local';
  select id into u_mgr from auth.users where email = 't153-mgr@test.local';
  select id into u_sup from auth.users where email = 't153-sup@test.local';
  select id into u_op  from auth.users where email = 't153-op@test.local';
  select id into u_lic from auth.users where email = 't153-lic@test.local';
  select id into u_sys from auth.users where email = 't153-sys@test.local';
  select id into u_oth from auth.users where email = 't153-oth@test.local';
  select id into u_o3  from auth.users where email = 't153-o3@test.local';

  insert into public.profiles (id, email, full_name)
  select u.id, u.email, 'Test ' || u.email
  from auth.users u
  where u.email like 't153-%@test.local'
  on conflict (id) do nothing;

  insert into public.vineyards (name, owner_id) values ('T153 Yard A', u_o1) returning id into v_yard_a;
  insert into public.vineyards (name, owner_id) values ('T153 Yard B', u_oth) returning id into v_yard_b;
  insert into public.vineyards (name, owner_id) values ('T153 Yard C', u_o1) returning id into v_yard_c;
  insert into public.vineyards (name, owner_id) values ('T153 Yard D', u_o3) returning id into v_yard_d;

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_yard_a, u_o1, 'owner'),
    (v_yard_a, u_o2, 'owner'),
    (v_yard_a, u_mgr, 'manager'),
    (v_yard_a, u_sup, 'supervisor'),
    (v_yard_a, u_op,  'operator'),
    (v_yard_a, u_lic, 'operator'),
    (v_yard_b, u_oth, 'owner'),
    (v_yard_c, u_o1,  'owner'),
    (v_yard_d, u_o3,  'owner');

  insert into public.system_admins (user_id, email, is_active)
  values (u_sys, 't153-sys@test.local', true)
  on conflict (user_id) do update set is_active = true;

  insert into public.vinetrack_plans (code, name, tier, billing_provider, billing_cycle, portal_access_level, base_price_cents)
  values ('t153_team', 'T153 Team', 'team', 'stripe', 'yearly', 'full', 99900)
  returning id into v_plan;

  -- Yard A: Stripe subscription billed by u_o1 (5 seats).
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     current_period_start, current_period_end, seats_included, seats_purchased,
     stripe_customer_id, stripe_subscription_id)
  values
    (u_o1, v_yard_a, v_plan, 'stripe', 'active',
     now() - interval '30 days', now() + interval '335 days', 3, 2,
     'cus_t153_a', 'sub_t153_a')
  returning id into v_sub_a;

  -- Yard B: foreign Stripe subscription (different owner + customer).
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     current_period_end, seats_included, stripe_customer_id, stripe_subscription_id)
  values
    (u_oth, v_yard_b, v_plan, 'stripe', 'active',
     now() + interval '300 days', 3, 'cus_t153_b', 'sub_t153_b')
  returning id into v_sub_b;

  -- Yard C: Apple store-managed subscription owned by u_o1.
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     current_period_end, seats_included, platform, external_subscription_id)
  values
    (u_o1, v_yard_c, v_plan, 'apple', 'active',
     now() + interval '200 days', 1, 'ios', 'txn_t153_c')
  returning id into v_sub_c;

  -- Yard D: no subscription; u_o3 has an active account trial.
  insert into public.vinetrack_account_trials (user_id, trial_started_at, trial_ends_at, status)
  values (u_o3, now() - interval '3 days', now() + interval '11 days', 'active');

  -- Licence: u_lic consumes a seat on sub A.
  insert into public.vinetrack_user_licences (subscription_id, user_id, vineyard_id, status)
  values (v_sub_a, u_lic, v_yard_a, 'active');

  -- Invoices: three on sub A, one foreign on sub B.
  insert into public.vinetrack_invoice_records
    (subscription_id, owner_user_id, vineyard_id, provider, external_invoice_id,
     external_customer_id, external_subscription_id, invoice_number, status,
     currency, subtotal_cents, tax_cents, total_cents, amount_paid_cents,
     amount_due_cents, period_start, period_end, issued_at, paid_at, description)
  values
    (v_sub_a, u_o1, v_yard_a, 'stripe', 'in_t153_a1', 'cus_t153_a', 'sub_t153_a',
     'VT-0001', 'paid', 'AUD', 90818, 9082, 99900, 99900, 0,
     now() - interval '395 days', now() - interval '30 days',
     now() - interval '395 days', now() - interval '394 days', 'Team yearly'),
    (v_sub_a, u_o1, v_yard_a, 'stripe', 'in_t153_a2', 'cus_t153_a', 'sub_t153_a',
     'VT-0002', 'paid', 'AUD', 90818, 9082, 99900, 99900, 0,
     now() - interval '30 days', now() + interval '335 days',
     now() - interval '30 days', now() - interval '29 days', 'Team yearly renewal'),
    (v_sub_a, u_o1, v_yard_a, 'stripe', 'in_t153_a3', 'cus_t153_a', 'sub_t153_a',
     'VT-0003', 'open', 'AUD', 4545, 455, 5000, 0, 5000,
     now() - interval '10 days', now() + interval '335 days',
     now() - interval '10 days', null, 'Additional licence'),
    (v_sub_b, u_oth, v_yard_b, 'stripe', 'in_t153_foreign', 'cus_t153_b', 'sub_t153_b',
     'VT-9999', 'paid', 'AUD', 90818, 9082, 99900, 99900, 0,
     now() - interval '10 days', now() + interval '355 days',
     now() - interval '10 days', now() - interval '9 days', 'Foreign invoice');

  -- ======================================================================
  -- T1  Owner lists owned billing vineyards with correct authority flags.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_o1, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.get_my_billing_vineyards();
  assert v_n = 2, format('T1 owner should list 2 vineyards (A + C), got %s', v_n);

  select count(*) into v_n from public.get_my_billing_vineyards() g
  where g.vineyard_id = v_yard_a and g.can_manage_billing and g.has_stripe_customer
    and g.plan_code = 't153_team' and g.subscription_status = 'active';
  assert v_n = 1, 'T1 yard A flags wrong for billing owner';

  select count(*) into v_n from public.get_my_billing_vineyards() g
  where g.vineyard_id = v_yard_c and g.can_manage_billing = false;
  assert v_n = 1, 'T1 store-managed yard C must not offer Stripe management';

  -- ======================================================================
  -- T2  Manager / Supervisor / Operator receive ZERO billing vineyards.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.get_my_billing_vineyards();
  assert v_n = 0, 'T2 manager must get zero billing vineyards';

  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.get_my_billing_vineyards();
  assert v_n = 0, 'T2 supervisor must get zero billing vineyards';

  perform set_config('request.jwt.claims', json_build_object('sub', u_op, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.get_my_billing_vineyards();
  assert v_n = 0, 'T2 operator must get zero billing vineyards';

  -- ======================================================================
  -- T3  Assigned licence user without Owner role: no billing access.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_lic, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.get_my_billing_vineyards();
  assert v_n = 0, 'T3 licence holder must get zero billing vineyards';

  ok := false;
  begin
    v_sum := public.get_my_vineyard_billing_summary(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T3 licence holder summary must raise owner_required';

  -- ======================================================================
  -- T4  Billing owner summary: authority, seats, money unit.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_o1, 'role', 'authenticated')::text, true);
  v_sum := public.get_my_vineyard_billing_summary(v_yard_a);

  assert (v_sum->>'can_manage_billing')::boolean,             'T4 billing owner must manage billing';
  assert (v_sum->>'can_view_invoices')::boolean,              'T4 billing owner must view invoices';
  assert v_sum->>'plan_code' = 't153_team',                   'T4 plan_code wrong';
  assert v_sum->>'provider' = 'stripe',                       'T4 provider wrong';
  assert (v_sum->>'licence_limit')::integer = 5,              'T4 licence_limit must be 5';
  assert (v_sum->>'assigned_licences')::integer = 1,          'T4 assigned_licences must be 1';
  assert (v_sum->>'available_licences')::integer = 4,         'T4 available_licences must be 4';
  assert (v_sum->>'is_unlimited')::boolean = false,           'T4 is_unlimited must be false';
  assert v_sum->>'money_unit' = 'minor_units',                'T4 money unit must be declared';
  assert (v_sum->>'has_stripe_customer')::boolean,            'T4 has_stripe_customer must be true';
  assert (v_sum->>'has_invoice_history')::boolean,            'T4 has_invoice_history must be true';
  assert v_sum ? 'billing_owner_user_id',                     'T4 billing owner id field missing';
  assert v_sum->>'billing_authority_code' is null,            'T4 authorised owner must have no authority code';

  -- ======================================================================
  -- T5  Owner WITHOUT billing authority: safe summary, no money access.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_o2, 'role', 'authenticated')::text, true);
  v_sum := public.get_my_vineyard_billing_summary(v_yard_a);

  assert (v_sum->>'can_manage_billing')::boolean = false, 'T5 non-billing owner must not manage billing';
  assert (v_sum->>'can_view_invoices')::boolean = false,  'T5 non-billing owner must not view invoices';
  assert v_sum->>'billing_authority_code' = 'billing_managed_by_another_owner',
    'T5 authority code must be billing_managed_by_another_owner';

  ok := false;
  begin
    perform * from public.get_my_vineyard_billing_history(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'billing_managed_by_another_owner');
  end;
  assert ok, 'T5 non-billing owner history must raise billing_managed_by_another_owner';

  ok := false;
  begin
    perform * from public.get_my_vineyard_billing_licences(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'billing_managed_by_another_owner');
  end;
  assert ok, 'T5 non-billing owner licences must raise billing_managed_by_another_owner';

  -- ======================================================================
  -- T6  Owner cannot request a vineyard they do not own.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_o1, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    v_sum := public.get_my_vineyard_billing_summary(v_yard_b);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T6 foreign vineyard summary must raise owner_required';

  ok := false;
  begin
    perform * from public.get_my_vineyard_billing_history(v_yard_b);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T6 foreign vineyard history must raise owner_required';

  -- ======================================================================
  -- T7  Manager direct RPC calls are rejected.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    v_sum := public.get_my_vineyard_billing_summary(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T7 manager summary must raise owner_required';

  ok := false;
  begin
    perform * from public.get_my_vineyard_billing_history(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T7 manager history must raise owner_required';

  ok := false;
  begin
    perform * from public.get_my_vineyard_billing_licences(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T7 manager licences must raise owner_required';

  -- ======================================================================
  -- T8  Billing owner invoice history: rows, cents, pagination, ordering.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_o1, 'role', 'authenticated')::text, true);

  select count(*), max(h.total_count) into v_n, v_total
  from public.get_my_vineyard_billing_history(v_yard_a) h;
  assert v_n = 3 and v_total = 3, format('T8 expected 3 invoices/total 3, got %s/%s', v_n, v_total);

  select count(*) into v_n
  from public.get_my_vineyard_billing_history(v_yard_a) h
  where h.invoice_id = 'in_t153_a2' and h.total = 99900 and h.tax = 9082
    and h.amount_paid = 99900 and h.currency = 'AUD'
    and h.can_view_invoice and h.can_download_invoice
    and h.redacted_reference = 'in_t…3_a2';
  assert v_n = 1, 'T8 invoice a2 fields wrong (cents / flags / redaction)';

  select count(*), max(h.total_count) into v_n, v_total
  from public.get_my_vineyard_billing_history(v_yard_a, 2, 0) h;
  assert v_n = 2 and v_total = 3, 'T8 pagination limit 2 must return 2 rows with total_count 3';

  -- ======================================================================
  -- T9  Foreign invoice never appears in the owner's history.
  -- ======================================================================
  select count(*) into v_n
  from public.get_my_vineyard_billing_history(v_yard_a) h
  where h.invoice_id = 'in_t153_foreign';
  assert v_n = 0, 'T9 foreign invoice leaked into yard A history';

  -- ======================================================================
  -- T10 Store-managed (Apple) subscription: no Stripe actions.
  -- ======================================================================
  v_sum := public.get_my_vineyard_billing_summary(v_yard_c);
  assert v_sum->>'provider' = 'apple',                        'T10 provider must be apple';
  assert v_sum->>'receipt_managed_by' = 'apple',              'T10 receipts managed by apple';
  assert v_sum->>'purchase_platform' = 'ios',                 'T10 purchase_platform must be ios';
  assert (v_sum->>'has_stripe_customer')::boolean = false,    'T10 no stripe customer';
  assert (v_sum->>'can_manage_billing')::boolean = false,     'T10 no Stripe management for store sub';
  assert (v_sum->>'can_view_invoices')::boolean = false,      'T10 no Stripe invoices for store sub';

  -- ======================================================================
  -- T11 Trial vineyard: honest trial state, no invoice actions.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_o3, 'role', 'authenticated')::text, true);
  v_sum := public.get_my_vineyard_billing_summary(v_yard_d);
  assert v_sum->>'access_source' = 'trial',                   'T11 access_source must be trial';
  assert (v_sum->>'has_stripe_customer')::boolean = false,    'T11 trial has no stripe customer';
  assert (v_sum->>'can_view_invoices')::boolean = false,      'T11 trial exposes no invoices';
  assert v_sum->>'billing_authority_code' = 'no_billing_relationship',
    'T11 trial must report no_billing_relationship';
  assert (v_sum->>'expires_at') is not null,                  'T11 trial expiry missing';

  -- ======================================================================
  -- T12 Cancelled subscription retains historical invoices.
  -- ======================================================================
  update public.vinetrack_subscriptions
     set status = 'canceled', canceled_at = now()
   where id = v_sub_a;

  perform set_config('request.jwt.claims', json_build_object('sub', u_o1, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.get_my_vineyard_billing_history(v_yard_a) h;
  assert v_n = 3, 'T12 cancelled subscription must retain all 3 invoices';

  select count(*) into v_n from public.get_my_vineyard_billing_history(v_yard_a) h
  where h.subscription_status = 'canceled';
  assert v_n = 3, 'T12 history must report the cancelled status';

  -- ======================================================================
  -- T13 Revoked Owner membership loses billing access immediately.
  -- ======================================================================
  delete from public.vineyard_members where vineyard_id = v_yard_a and user_id = u_o2;

  perform set_config('request.jwt.claims', json_build_object('sub', u_o2, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.get_my_billing_vineyards();
  assert v_n = 0, 'T13 revoked owner must list zero billing vineyards';

  ok := false;
  begin
    v_sum := public.get_my_vineyard_billing_summary(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T13 revoked owner summary must raise owner_required';

  -- ======================================================================
  -- T14 System Admin WITHOUT Owner membership: no customer billing access.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_sys, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.get_my_billing_vineyards();
  assert v_n = 0, 'T14 system admin must list zero billing vineyards';

  ok := false;
  begin
    v_sum := public.get_my_vineyard_billing_summary(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'owner_required');
  end;
  assert ok, 'T14 system admin summary must raise owner_required';

  -- ======================================================================
  -- T15 Unauthenticated requests are rejected.
  -- ======================================================================
  perform set_config('request.jwt.claims', '', true);
  ok := false;
  begin
    select count(*) into v_n from public.get_my_billing_vineyards();
  exception when others then
    ok := (sqlerrm = 'authentication_required');
  end;
  assert ok, 'T15 unauthenticated list must raise authentication_required';

  ok := false;
  begin
    v_sum := public.get_my_vineyard_billing_summary(v_yard_a);
  exception when others then
    ok := (sqlerrm = 'authentication_required');
  end;
  assert ok, 'T15 unauthenticated summary must raise authentication_required';

  -- ======================================================================
  -- T16 Unknown vineyard id → vineyard_not_found.
  -- ======================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_o1, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    v_sum := public.get_my_vineyard_billing_summary(gen_random_uuid());
  exception when others then
    ok := (sqlerrm = 'vineyard_not_found');
  end;
  assert ok, 'T16 unknown vineyard must raise vineyard_not_found';

  -- ======================================================================
  -- T17 Licences RPC: billing owner sees seat assignments.
  -- ======================================================================
  select count(*) into v_n from public.get_my_vineyard_billing_licences(v_yard_a) l
  where l.status = 'active' and l.user_email = 't153-lic@test.local';
  assert v_n = 1, 'T17 billing owner must see the assigned licence';

  -- ======================================================================
  -- T18 Direct table reads are locked down (RLS policy shape).
  -- ======================================================================
  assert not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'vinetrack_invoice_records'
      and policyname = 'vinetrack_invoice_records_select_owner'
  ), 'T18 customer direct-read policy must be dropped';

  assert exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'vinetrack_invoice_records'
      and policyname = 'vinetrack_invoice_records_select_admin'
  ), 'T18 admin-only read policy must exist';

  -- ======================================================================
  -- T19 Billing evidence preserved: nothing was deleted by any RPC.
  -- ======================================================================
  select count(*) into v_n from public.vinetrack_invoice_records
  where external_invoice_id like 'in_t153_%';
  assert v_n = 4, 'T19 all 4 fixture invoices must still exist';

  raise notice 'SQL 152/153 vineyard owner billing tests: ALL PASSED';
end$$;

rollback;
