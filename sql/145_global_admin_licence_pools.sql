-- =====================================================================
-- 145_global_admin_licence_pools.sql
-- =====================================================================
-- Phase 2C.1 (3 of 3) — GLOBAL licence-pool administration for the
-- Access & Entitlements centre.
--
-- EXISTING BEHAVIOUR BEING CORRECTED:
--   The portal can only see licence pools OWNED BY THE SELECTED USER
--   (admin_user_access_detail -> billing_sources), so System Admins
--   cannot assign a seat from another owner's Team/Enterprise pool.
--
-- WHAT THIS MIGRATION ADDS / CHANGES (all ADDITIVE):
--   A. public.admin_available_licence_pools(...) — NEW read-only,
--      System-Admin-only, paginated + server-filtered list of EVERY
--      eligible seat pool:
--        INCLUDED: plan tier 'team' or 'enterprise' (covers portal Team,
--          Enterprise, and the manual grant types complimentary_team /
--          enterprise_contract, which are shaped as team/enterprise
--          manual rows by SQL 141).
--        EXCLUDED: solo & legacy plans, the account trial (not a
--          subscription at all), Apple/Google store subscriptions
--          (personal — never seat pools), Internal Unlimited /
--          Complimentary Solo / Beta Tester / Temporary Access /
--          Support Access (internal or solo plans → excluded by tier),
--          sandbox rows, deleted rows, revoked grants, and rows whose
--          status is 'canceled' or 'expired'.
--      Seat maths is computed ON THE SERVER:
--        licence_limit      = seats_included + seats_purchased (null when
--                             the pool is unlimited)
--        assigned_licences  = count of ACTIVE licence rows only —
--                             revoked/pending rows never consume a seat
--        available_licences = licence_limit - assigned (null when
--                             unlimited)
--      is_assignable + not_assignable_reason mark pools that are
--      future-starting ('not_started'), past their period/trial/grant end
--      ('expired'), suspended ('suspended') or full
--      ('no_seats_available').
--   B. CREATE OR REPLACEs public.admin_assign_licence() (same signature,
--      SQL 141) hardened for global pool selection:
--        * row-level lock (SELECT ... FOR UPDATE) on the subscription —
--          concurrent assignments serialise per pool, so capacity can
--          NEVER be over-allocated even under racing admins;
--        * seat availability is re-checked INSIDE the locked transaction
--          (client-supplied availability is never trusted);
--        * NEW validity gates: future-start ('pool_not_started'),
--          elapsed period/trial/grant ('pool_expired'), suspended pools
--          ('pool_suspended');
--        * everything else unchanged: reason REQUIRED, store
--          subscriptions rejected, duplicate active assignment prevented
--          (idempotent re-activation for the same user), billing event
--          written, recipient's entitlement refreshed.
--      The partial unique index uniq_vinetrack_user_licences_active_user
--      (subscription_id, user_id) WHERE status='active' remains the
--      structural duplicate guard beneath the RPC.
--   C. admin_remove_licence() is UNCHANGED (already reason-gated,
--      audited, and refreshes the recipient).
--
-- SECURITY:
--   * Both functions: SECURITY DEFINER, search_path pinned, System-Admin
--     gate (42501 otherwise). Vineyard owners/managers who are not
--     System Admins cannot call them.
--   * The pool list is read-only; external ids are NOT exposed.
--
-- ROLLBACK PROCEDURE (non-destructive):
--   drop function if exists public.admin_available_licence_pools(text, uuid, text, uuid, boolean, integer, integer);
--   -- restore the previous assignment RPC:
--   -- re-run section E of sql/141_billing_grants_and_admin_actions.sql
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.admin_assign_licence(uuid, uuid, text, uuid)') is null then
    raise exception 'SQL 145 precondition failed: apply sql/141 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. admin_available_licence_pools — every eligible global seat pool.
-- ---------------------------------------------------------------------------
create or replace function public.admin_available_licence_pools(
  p_search              text    default null,  -- owner name/email, vineyard name, subscription uuid
  p_vineyard_id         uuid    default null,
  p_plan_code           text    default null,
  p_billing_owner_user_id uuid  default null,
  p_has_available_seats boolean default null,  -- true = only pools with room (or unlimited)
  p_limit               integer default 50,
  p_offset              integer default 0
)
returns table (
  subscription_id       uuid,
  billing_owner_user_id uuid,
  billing_owner_name    text,
  billing_owner_email   text,
  vineyard_id           uuid,
  vineyard_name         text,
  plan_code             text,
  subscription_status   text,
  billing_source        text,        -- manual_grant_type | 'portal_subscription'
  provider              text,        -- billing_provider ('stripe' | 'manual')
  licence_limit         integer,     -- null when unlimited
  assigned_licences     integer,     -- ACTIVE assignments only
  available_licences    integer,     -- null when unlimited
  is_unlimited          boolean,
  starts_at             timestamptz,
  current_period_end    timestamptz,
  expires_at            timestamptz, -- earliest applicable end (period/grant)
  is_assignable         boolean,
  not_assignable_reason text,        -- null | not_started | expired | suspended | no_seats_available
  total_count           bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  return query
  with pools as (
    select
      s.id                                   as sub_id,
      s.owner_user_id                        as owner_id,
      pr.full_name                           as owner_name,
      coalesce(pr.email, u.email)::text      as owner_email,
      s.primary_vineyard_id                  as vy_id,
      vy.name                                as vy_name,
      p.code                                 as p_code,
      s.status                               as s_status,
      coalesce(
        s.manual_grant_type,
        case when s.billing_provider = 'stripe' then 'portal_subscription'
             else 'manual' end
      )                                      as b_source,
      s.billing_provider                     as b_provider,
      coalesce(s.unlimited_licences, false)  as unlimited,
      (coalesce(s.seats_included, 0) + coalesce(s.seats_purchased, 0)) as seat_limit,
      (
        -- ACTIVE assignments only: revoked/pending rows never consume a seat.
        select count(*)::integer
        from public.vinetrack_user_licences l
        where l.subscription_id = s.id and l.status = 'active'
      )                                      as assigned,
      s.started_at                           as s_starts,
      s.current_period_end                   as s_period_end,
      s.grace_period_end                     as s_grace_end,
      s.manual_grant_expires_at              as s_grant_end,
      s.trial_end                            as s_trial_end
    from public.vinetrack_subscriptions s
    join public.vinetrack_plans p on p.id = s.plan_id
    left join auth.users u on u.id = s.owner_user_id
    left join public.profiles pr on pr.id = s.owner_user_id
    left join public.vineyards vy on vy.id = s.primary_vineyard_id
    where s.deleted_at is null
      -- Only intentional seat pools: Team / Enterprise (portal or manual —
      -- covers complimentary_team & enterprise_contract). Solo, legacy,
      -- internal (Internal Unlimited / beta / temporary / support), and the
      -- account trial are structurally excluded here.
      and p.tier in ('team', 'enterprise')
      -- Store subscriptions are personal — never assignable pools.
      and s.billing_provider not in ('apple', 'google')
      -- Sandbox rows never appear.
      and (s.environment is null or s.environment <> 'sandbox')
      -- Revoked grants and terminally dead rows are excluded entirely.
      and s.manual_grant_revoked_at is null
      and s.status not in ('canceled', 'expired')
  ),
  classified as (
    select
      po.*,
      case
        when po.s_status not in ('trialing', 'active', 'manual', 'past_due')
          then 'suspended'
        when po.s_starts is not null and po.s_starts > now()
          then 'not_started'
        when po.s_status = 'trialing'
             and po.s_trial_end is not null and po.s_trial_end <= now()
          then 'expired'
        when po.s_status in ('active', 'past_due')
             and po.s_period_end is not null and po.s_period_end <= now()
             and (po.s_grace_end is null or po.s_grace_end <= now())
          then 'expired'
        when po.s_grant_end is not null and po.s_grant_end <= now()
          then 'expired'
        when not po.unlimited
             and po.assigned >= greatest(po.seat_limit, 1)
          then 'no_seats_available'
        else null
      end as reason
    from pools po
  ),
  filtered as (
    select * from classified c
    where (p_vineyard_id is null or c.vy_id = p_vineyard_id)
      and (p_plan_code is null or c.p_code = p_plan_code)
      and (p_billing_owner_user_id is null or c.owner_id = p_billing_owner_user_id)
      and (
        p_search is null
        or coalesce(c.owner_name, '')  ilike '%' || p_search || '%'
        or coalesce(c.owner_email, '') ilike '%' || p_search || '%'
        or coalesce(c.vy_name, '')     ilike '%' || p_search || '%'
        or c.sub_id::text = lower(btrim(p_search))
      )
      and (
        p_has_available_seats is null
        or p_has_available_seats = false
        or c.unlimited
        or (c.reason is null and c.assigned < greatest(c.seat_limit, 1))
      )
  )
  select
    f.sub_id,
    f.owner_id,
    f.owner_name,
    f.owner_email,
    f.vy_id,
    f.vy_name,
    f.p_code,
    f.s_status,
    f.b_source,
    f.b_provider,
    case when f.unlimited then null else f.seat_limit end,
    f.assigned,
    case when f.unlimited then null
         else greatest(f.seat_limit - f.assigned, 0) end,
    f.unlimited,
    f.s_starts,
    f.s_period_end,
    coalesce(
      f.s_grant_end,
      case
        when f.s_period_end is not null and f.s_grace_end is not null
          then greatest(f.s_period_end, f.s_grace_end)
        else coalesce(f.s_period_end, f.s_grace_end)
      end,
      f.s_trial_end
    ),
    (f.reason is null),
    f.reason,
    count(*) over () as total_count
  from filtered f
  order by (f.reason is null) desc, f.owner_email asc, f.sub_id
  limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;

revoke all on function public.admin_available_licence_pools(text, uuid, text, uuid, boolean, integer, integer) from public;
grant execute on function public.admin_available_licence_pools(text, uuid, text, uuid, boolean, integer, integer) to authenticated;

comment on function public.admin_available_licence_pools(text, uuid, text, uuid, boolean, integer, integer) is
  'SQL 145: System-Admin-only global seat-pool directory (team/enterprise plans incl. complimentary_team & enterprise_contract manual grants). Server-side seat maths (active assignments only), validity classification (not_started/expired/suspended/no_seats_available), search + filters, page clamped to 200. Store subscriptions, solo plans, Internal Unlimited, trials and sandbox rows are structurally excluded. Read-only; no external ids.';

-- ---------------------------------------------------------------------------
-- B. admin_assign_licence — hardened (same signature as SQL 141).
--    Row lock + in-transaction seat recheck + pool-validity gates.
-- ---------------------------------------------------------------------------
create or replace function public.admin_assign_licence(
  p_subscription_id uuid,
  p_user_id         uuid,
  p_reason          text,
  p_vineyard_id     uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin      uuid := auth.uid();
  v_sub        record;
  v_active     integer;
  v_licence_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  -- LOCK the pool row: concurrent assignments to the same subscription
  -- serialise here, so the seat recheck below can never over-allocate.
  select s.id, s.owner_user_id, s.billing_provider, s.deleted_at,
         s.status, s.started_at, s.trial_end, s.current_period_end,
         s.grace_period_end, s.manual_grant_expires_at,
         s.manual_grant_revoked_at, s.environment,
         coalesce(s.unlimited_licences, false) as unlimited,
         coalesce(s.seats_included, 0) + coalesce(s.seats_purchased, 0) as seats
  into v_sub
  from public.vinetrack_subscriptions s
  where s.id = p_subscription_id
  for update;

  if v_sub.id is null then
    raise exception 'subscription_not_found' using errcode = 'P0002';
  end if;
  if v_sub.deleted_at is not null or v_sub.manual_grant_revoked_at is not null then
    raise exception 'subscription_revoked' using errcode = '22023';
  end if;
  if v_sub.billing_provider in ('apple', 'google') then
    -- Store subscriptions are personal; seats are never admin-assigned.
    raise exception 'store_subscription_not_licence_assignable' using errcode = '22023';
  end if;
  if v_sub.environment = 'sandbox' then
    raise exception 'sandbox_subscription_not_assignable' using errcode = '22023';
  end if;

  -- SQL 145 pool-validity gates (server time only).
  if v_sub.status not in ('trialing', 'active', 'manual', 'past_due') then
    raise exception 'pool_suspended' using errcode = '22023';
  end if;
  if v_sub.started_at is not null and v_sub.started_at > now() then
    raise exception 'pool_not_started' using errcode = '22023';
  end if;
  if (v_sub.status = 'trialing'
      and v_sub.trial_end is not null and v_sub.trial_end <= now())
     or (v_sub.status in ('active', 'past_due')
         and v_sub.current_period_end is not null
         and v_sub.current_period_end <= now()
         and (v_sub.grace_period_end is null or v_sub.grace_period_end <= now()))
     or (v_sub.manual_grant_expires_at is not null
         and v_sub.manual_grant_expires_at <= now()) then
    raise exception 'pool_expired' using errcode = '22023';
  end if;

  -- Seat recheck INSIDE the locked transaction. Revoked/pending rows never
  -- consume a seat; a user's own existing active row is idempotent.
  if not v_sub.unlimited then
    select count(*)::integer into v_active
    from public.vinetrack_user_licences
    where subscription_id = p_subscription_id and status = 'active';

    if v_active >= greatest(v_sub.seats, 1)
       and not exists (
         select 1 from public.vinetrack_user_licences
         where subscription_id = p_subscription_id
           and user_id = p_user_id and status = 'active'
       ) then
      raise exception 'no_seats_available' using errcode = '22023';
    end if;
  end if;

  if exists (
    select 1 from public.vinetrack_user_licences
    where subscription_id = p_subscription_id and user_id = p_user_id
  ) then
    update public.vinetrack_user_licences
    set status      = 'active',
        revoked_at  = null,
        vineyard_id = coalesce(p_vineyard_id, vineyard_id),
        assigned_by = v_admin,
        updated_at  = now()
    where subscription_id = p_subscription_id and user_id = p_user_id
    returning id into v_licence_id;
  else
    insert into public.vinetrack_user_licences
      (subscription_id, user_id, vineyard_id, status, assigned_by)
    values
      (p_subscription_id, p_user_id, p_vineyard_id, 'active', v_admin)
    returning id into v_licence_id;
  end if;

  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (p_subscription_id, v_sub.owner_user_id, 'manual', 'licence_assigned',
     jsonb_build_object(
       'assigned_by', v_admin,
       'licence_id', v_licence_id,
       'assigned_user_id', p_user_id,
       'vineyard_id', p_vineyard_id,
       'reason', btrim(p_reason)
     ));

  -- Recipient's effective access updates immediately.
  perform public._admin_refresh_entitlement_state(p_user_id);

  return v_licence_id;
end;
$$;

revoke all on function public.admin_assign_licence(uuid, uuid, text, uuid) from public;
grant execute on function public.admin_assign_licence(uuid, uuid, text, uuid) to authenticated;

comment on function public.admin_assign_licence(uuid, uuid, text, uuid) is
  'SQL 145 (hardens SQL 141, same signature): System-Admin-only seat assignment from ANY eligible global pool. Locks the subscription row (FOR UPDATE) and re-checks seat availability inside the transaction — concurrent assignments cannot over-allocate. Rejects store subscriptions, sandbox rows, revoked/suspended/expired/future-starting pools and full pools. Reason required; audited; recipient entitlement refreshed.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit, as a System Admin):
--   select * from public.admin_available_licence_pools(p_limit => 20);
--   select * from public.admin_available_licence_pools(p_has_available_seats => true);
--   select * from public.admin_available_licence_pools(p_search => 'stockman');
--
--   -- Assign from a listed pool:
--   select public.admin_assign_licence('<pool-sub-uuid>', '<user-uuid>',
--                                      'Seat for new team member');
--
-- Expected failures:
--   * non-admin caller                          -> 42501
--   * solo / apple / google / internal pools    -> never listed
--   * assign on an apple/google sub             -> store_subscription_not_licence_assignable
--   * assign on a full pool                     -> no_seats_available
--   * assign on a future-starting pool          -> pool_not_started
--   * assign on an elapsed pool                 -> pool_expired
--   * two concurrent assigns on a 1-seat pool   -> exactly one succeeds
--     (row lock serialises; loser gets no_seats_available)
-- =====================================================================
