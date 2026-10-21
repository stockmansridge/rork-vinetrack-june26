-- Function rollback only. Restore the captured rollout flag snapshot in the SAME transaction.
-- Does not overwrite commercial records, customer grants, trials or derived cache rows.
-- Re-run the canonical state refresh after the rollback if required.

CREATE OR REPLACE FUNCTION public._user_level_access(p_user_id uuid)
 RETURNS TABLE(has_access boolean, reason_code text, subscription_id uuid, plan_code text, plan_tier text, plan_name text, billing_provider text, status text, purchase_platform text, environment text, trial_end timestamp with time zone, current_period_end timestamp with time zone, cancel_at_period_end boolean, grace_period_end timestamp with time zone, unlimited_licences boolean, manual_grant_reason text, manual_grant_expires_at timestamp with time zone, is_owner boolean, licence_id uuid, vineyard_id uuid, portal_access boolean, portal_access_level text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  tr record;
  v_reason text;
begin
  select
    s.id            as sub_id,
    p.code          as plan_code,
    p.tier          as plan_tier,
    p.name          as plan_name,
    p.portal_access_level,
    s.billing_provider,
    s.status,
    s.platform,
    s.environment,
    s.trial_end,
    s.current_period_end,
    coalesce(s.cancel_at_period_end, false) as cancel_at_period_end,
    s.grace_period_end,
    coalesce(s.unlimited_licences, false)   as unlimited,
    s.manual_grant_reason,
    s.manual_grant_expires_at,
    (s.owner_user_id = p_user_id)           as is_owner,
    (
      select ul.id from public.vinetrack_user_licences ul
      where ul.subscription_id = s.id
        and ul.user_id = p_user_id
        and ul.status = 'active'
      order by ul.id limit 1
    ) as licence_id,
    coalesce(
      (
        select ul2.vineyard_id from public.vinetrack_user_licences ul2
        where ul2.subscription_id = s.id
          and ul2.user_id = p_user_id
          and ul2.status = 'active'
        order by ul2.id limit 1
      ),
      s.primary_vineyard_id
    ) as vineyard_id
  into r
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where s.deleted_at is null
    and (s.environment is null or s.environment <> 'sandbox')
    -- A VINEYARD-SCOPED grant (sql/155) funds exactly one vineyard through
    -- _vineyard_entitlement_for. It is NOT an account entitlement for its
    -- billing anchor (nor for the anchor licence it asserts), otherwise the
    -- anchor's OTHER vineyards would silently inherit owner-backed access
    -- and scope would be inferred after all.
    and coalesce(s.grant_scope, 'user') <> 'vineyard'
    and (
      s.owner_user_id = p_user_id
      or exists (
        select 1 from public.vinetrack_user_licences l
        where l.subscription_id = s.id
          and l.user_id = p_user_id
          and l.status = 'active'
      )
    )
    and (
      s.status in ('trialing', 'active', 'manual')
      or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
      or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (s.started_at is null or s.started_at <= now())
    and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
    and (
      coalesce(s.unlimited_licences, false) = true
      or s.status not in ('active', 'past_due')
      or s.current_period_end is null
      or s.current_period_end > now()
      or (s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
    and (
      coalesce(s.unlimited_licences, false) = false
      or s.manual_grant_expires_at is null
      or s.manual_grant_expires_at > now()
    )
  order by
    case
      when p.code = 'internal_unlimited' then 6
      when p.tier = 'enterprise'         then 5
      when p.tier = 'team'               then 4
      when p.tier = 'legacy'             then 3
      when p.tier = 'solo'               then 2
      else 1
    end desc,
    (s.status = 'trialing') asc,
    (s.owner_user_id = p_user_id) desc,
    s.current_period_end desc nulls last,
    s.created_at desc,
    s.id
  limit 1;

  if r.sub_id is not null then
    v_reason := case
      when r.plan_code = 'internal_unlimited'                 then 'internal_unlimited'
      when r.plan_tier = 'enterprise'                         then 'enterprise_subscription'
      when r.status = 'trialing'
           and r.billing_provider not in ('apple', 'google')  then 'active_trial'
      when r.licence_id is not null
           and coalesce(r.is_owner, false) = false
           and r.billing_provider not in ('apple', 'google')  then 'assigned_licence'
      when r.billing_provider in ('apple', 'google')          then 'app_store_subscription'
      else 'portal_subscription'
    end;

    return query select
      true, v_reason, r.sub_id, r.plan_code, r.plan_tier, r.plan_name,
      r.billing_provider, r.status, r.platform, r.environment,
      r.trial_end, r.current_period_end, r.cancel_at_period_end,
      r.grace_period_end, r.unlimited, r.manual_grant_reason,
      r.manual_grant_expires_at, coalesce(r.is_owner, false),
      r.licence_id, r.vineyard_id,
      (coalesce(r.portal_access_level, 'none') <> 'none'),
      coalesce(r.portal_access_level, 'none');
    return;
  end if;

  select * into tr from public._account_trial_for(p_user_id);

  if coalesce(tr.is_active, false) then
    return query select
      true, 'active_trial'::text, null::uuid,
      'trial'::text, 'trial'::text, 'Account Trial'::text,
      'trial'::text, 'trialling'::text,
      null::text, null::text,
      tr.trial_ends_at, null::timestamptz, false,
      null::timestamptz, false, null::text,
      null::timestamptz, false,
      null::uuid, null::uuid,
      true, 'basic'::text;
    return;
  end if;

  select case
    when s2.manual_grant_revoked_at is not null
      or s2.status = 'canceled'
      or s2.deleted_at is not null                                  then 'revoked'
    when s2.status = 'expired'                                      then 'expired'
    when s2.status = 'trialing'
      and s2.trial_end is not null and s2.trial_end <= now()        then 'expired'
    when s2.status in ('active', 'past_due')
      and s2.current_period_end is not null
      and s2.current_period_end <= now()                            then 'expired'
    when coalesce(s2.unlimited_licences, false) = true
      and s2.manual_grant_expires_at is not null
      and s2.manual_grant_expires_at <= now()                       then 'expired'
    else null
  end
  into v_reason
  from public.vinetrack_subscriptions s2
  where coalesce(s2.grant_scope, 'user') <> 'vineyard'
    and (
      s2.owner_user_id = p_user_id
      or exists (
        select 1 from public.vinetrack_user_licences l2
        where l2.subscription_id = s2.id and l2.user_id = p_user_id
      )
    )
  order by s2.updated_at desc, s2.id
  limit 1;

  if v_reason is null and tr.status is not null then
    return query select
      false,
      case when tr.status = 'revoked' then 'revoked' else 'expired' end,
      null::uuid,
      'trial'::text, 'trial'::text, 'Account Trial'::text,
      'trial'::text,
      case when tr.status = 'revoked' then 'revoked' else 'expired' end,
      null::text, null::text,
      tr.trial_ends_at,
      null::timestamptz, false,
      null::timestamptz, false, null::text,
      null::timestamptz, false,
      null::uuid, null::uuid,
      false, 'none'::text;
    return;
  end if;

  return query select
    false, coalesce(v_reason, 'no_entitlement'),
    null::uuid, null::text, null::text, null::text,
    null::text, null::text, null::text, null::text,
    null::timestamptz, null::timestamptz, false,
    null::timestamptz, false, null::text,
    null::timestamptz, false,
    null::uuid, null::uuid,
    false, 'none'::text;
end;
$function$;

CREATE OR REPLACE FUNCTION public._vineyard_entitlement_for(p_vineyard_id uuid)
 RETURNS TABLE(has_entitlement boolean, access_source text, reason_code text, plan_code text, plan_tier text, plan_name text, subscription_status text, subscription_id uuid, billing_owner_user_id uuid, starts_at timestamp with time zone, expires_at timestamp with time zone, is_trial boolean, is_vineyard_wide boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  best  record;
  own   record;
  tro   record;
  v_src text;
  v_user_only_owner boolean := false;
begin
  if p_vineyard_id is null then
    return query select false, 'none'::text, 'no_vineyard_entitlement'::text,
      null::text, null::text, null::text, null::text, null::uuid, null::uuid,
      null::timestamptz, null::timestamptz, false, false;
    return;
  end if;

  -- 1+2. Entitlements anchored DIRECTLY to the vineyard. A vineyard-scoped
  --      grant outranks an anchored multi-seat subscription. A user-scoped
  --      grant, a Solo/legacy subscription or a store subscription with an
  --      informational primary vineyard NEVER funds the vineyard here.
  select
    s.id             as sub_id,
    s.owner_user_id  as b_owner,
    s.grant_scope    as b_scope,
    s.status         as b_status,
    s.started_at     as b_started,
    p.code           as b_plan_code,
    p.tier           as b_plan_tier,
    p.name           as b_plan_name,
    (s.status = 'trialing') as b_is_trial,
    (
      select min(cand) from unnest(array[
        s.manual_grant_expires_at,
        s.trial_end,
        case
          when s.current_period_end is not null and s.grace_period_end is not null
            then greatest(s.current_period_end, s.grace_period_end)
          else coalesce(s.current_period_end, s.grace_period_end)
        end
      ]) cand
      where cand is not null and cand > now()
    ) as b_expires
  into best
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where s.primary_vineyard_id = p_vineyard_id
    and s.deleted_at is null
    and (s.environment is null or s.environment <> 'sandbox')
    and (
      s.grant_scope = 'vineyard'
      or public._plan_funds_vineyard(p.code, p.tier, s.billing_provider)
    )
    and (
      s.status in ('trialing', 'active', 'manual')
      or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
      or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (s.started_at is null or s.started_at <= now())
    and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
    and (
      coalesce(s.unlimited_licences, false) = true
      or s.status not in ('active', 'past_due')
      or s.current_period_end is null
      or s.current_period_end > now()
      or (s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
    and (
      coalesce(s.unlimited_licences, false) = false
      or s.manual_grant_expires_at is null
      or s.manual_grant_expires_at > now()
    )
  order by
    (s.grant_scope = 'vineyard') desc,
    case
      when p.code = 'internal_unlimited' then 6
      when p.tier = 'enterprise'         then 5
      when p.tier = 'team'               then 4
      else 1
    end desc,
    (s.status = 'trialing') asc,
    s.current_period_end desc nulls last,
    s.created_at desc,
    s.id
  limit 1;

  if best.sub_id is not null then
    v_src := case when best.b_scope = 'vineyard'
                  then 'vineyard_grant' else 'vineyard_subscription' end;
    return query select
      true, v_src, v_src,
      best.b_plan_code, best.b_plan_tier, best.b_plan_name, best.b_status,
      best.sub_id, best.b_owner,
      best.b_started, best.b_expires, best.b_is_trial,
      (best.b_scope = 'vineyard');
    return;
  end if;

  -- 3. Owner-backed MULTI-SEAT subscription. The Owner must be the
  --    SUBSCRIPTION owner (an assigned licence entitles the assignee only)
  --    and the plan must be team/enterprise (Solo never funds members).
  select o.owner_uid, ua.*
  into own
  from public._vineyard_owner_ids(p_vineyard_id) o
  cross join lateral public._user_level_access(o.owner_uid) ua
  where ua.has_access
    and coalesce(ua.is_owner, false) = true
    and public._plan_funds_vineyard(ua.plan_code, ua.plan_tier, ua.billing_provider)
  order by
    coalesce(ua.manual_grant_expires_at, ua.current_period_end, ua.trial_end)
      desc nulls first,
    o.owner_uid
  limit 1;

  if own.owner_uid is not null then
    return query select
      true, 'owner_subscription'::text, 'owner_subscription'::text,
      own.plan_code, own.plan_tier, own.plan_name, own.status,
      own.subscription_id, own.owner_uid,
      null::timestamptz,
      (
        select min(cand) from unnest(array[
          own.trial_end,
          case
            when own.current_period_end is not null and own.grace_period_end is not null
              then greatest(own.current_period_end, own.grace_period_end)
            else coalesce(own.current_period_end, own.grace_period_end)
          end
        ]) cand
        where cand is not null and cand > now()
      ),
      (own.status in ('trialing', 'trialling')),
      false;
    return;
  end if;

  -- 4. Owner ACCOUNT TRIAL (sql/143). Resolved independently of the
  --    Owner's subscriptions so a Solo purchase during the trial cannot
  --    strip the invited staff's evaluation access. Funds every vineyard
  --    that Owner owns, for the original three-calendar-month window.
  select o.owner_uid, tr.trial_ends_at
  into tro
  from public._vineyard_owner_ids(p_vineyard_id) o
  cross join lateral public._account_trial_for(o.owner_uid) tr
  where coalesce(tr.is_active, false)
  order by tr.trial_ends_at desc, o.owner_uid
  limit 1;

  if tro.owner_uid is not null then
    return query select
      true, 'owner_trial'::text, 'owner_trial'::text,
      'trial'::text, 'trial'::text, 'Account Trial'::text, 'trialling'::text,
      null::uuid, tro.owner_uid,
      null::timestamptz, tro.trial_ends_at, true, false;
    return;
  end if;

  -- 5. Nothing funds the vineyard. Distinguish "the Owner is entitled, but
  --    only for their own account" (Solo / legacy / user-scoped grant /
  --    assigned licence) from "no entitlement anywhere".
  select exists (
    select 1
    from public._vineyard_owner_ids(p_vineyard_id) o
    cross join lateral public._user_level_access(o.owner_uid) ua
    where ua.has_access
  ) into v_user_only_owner;

  return query select
    false, 'none'::text,
    case when v_user_only_owner then 'owner_plan_not_vineyard_funding'
         else 'no_vineyard_entitlement' end,
    null::text, null::text, null::text, null::text, null::uuid, null::uuid,
    null::timestamptz, null::timestamptz, false, false;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_user_access_detail(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v jsonb;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'user_required' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'generated_at', now(),

    'identity', (
      select jsonb_build_object(
        'user_id', u.id,
        'email', coalesce(pr.email, u.email),
        'full_name', pr.full_name,
        'email_confirmed', (u.email_confirmed_at is not null),
        'email_confirmed_at', u.email_confirmed_at,
        'account_created_at', u.created_at,
        'last_sign_in_at', u.last_sign_in_at,
        'is_disabled', (u.banned_until is not null and u.banned_until > now()),
        'is_system_admin', exists (
          select 1 from public.system_admins sa
          where sa.user_id = u.id and sa.is_active = true
        )
      )
      from auth.users u
      left join public.profiles pr on pr.id = u.id
      where u.id = p_user_id
    ),

    'memberships', jsonb_build_object(
      'active', coalesce((
        select jsonb_agg(jsonb_build_object(
          'vineyard_id', vy.id,
          'vineyard_name', vy.name,
          'role', vm.role,
          'display_name', vm.display_name,
          'joined_at', vm.joined_at,
          'licence', (
            select jsonb_build_object(
              'licence_id', l.id, 'status', l.status, 'assigned_at', l.assigned_at
            )
            from public.vinetrack_user_licences l
            where l.user_id = p_user_id
              and l.vineyard_id = vy.id
              and l.status = 'active'
            order by l.assigned_at desc
            limit 1
          )
        ) order by vy.name)
        from public.vineyard_members vm
        join public.vineyards vy on vy.id = vm.vineyard_id
        where vm.user_id = p_user_id and vy.deleted_at is null
      ), '[]'::jsonb),
      'historical', coalesce((
        select jsonb_agg(jsonb_build_object(
          'vineyard_id', vy.id,
          'vineyard_name', vy.name,
          'role', vm.role,
          'joined_at', vm.joined_at,
          'vineyard_deleted_at', vy.deleted_at
        ) order by vy.deleted_at desc)
        from public.vineyard_members vm
        join public.vineyards vy on vy.id = vm.vineyard_id
        where vm.user_id = p_user_id and vy.deleted_at is not null
      ), '[]'::jsonb),
      'pending_invitations', coalesce((
        select jsonb_agg(jsonb_build_object(
          'invitation_id', i.id,
          'vineyard_id', i.vineyard_id,
          'vineyard_name', vy.name,
          'role', i.role,
          'status', i.status,
          'expires_at', i.expires_at,
          'created_at', i.created_at
        ) order by i.created_at desc)
        from public.invitations i
        join public.vineyards vy on vy.id = i.vineyard_id
        left join public.profiles pr2 on pr2.id = p_user_id
        where lower(i.email) = lower(coalesce(pr2.email,
                (select u2.email from auth.users u2 where u2.id = p_user_id)))
          and i.status = 'pending'
      ), '[]'::jsonb)
    ),

    'effective_access', (
      select jsonb_build_object(
        'has_access', ea.has_access,
        'reason_code', ea.reason_code,
        'access_source', coalesce(ea.plan_tier, 'none'),
        'plan_code', ea.plan_code,
        'plan_name', ea.plan_name,
        'billing_provider', ea.billing_provider,
        'subscription_status', ea.status,
        'purchase_platform', ea.purchase_platform,
        'unlimited_licences', ea.unlimited_licences,
        'trial_end', ea.trial_end,
        'current_period_end', ea.current_period_end,
        'cancel_at_period_end', ea.cancel_at_period_end,
        'grace_period_end', ea.grace_period_end,
        'manual_grant_reason', ea.manual_grant_reason,
        'manual_grant_expires_at', ea.manual_grant_expires_at,
        'subscription_id', ea.subscription_id,
        'licence_id', ea.licence_id,
        'vineyard_id', ea.vineyard_id,
        'portal_access', (ea.has_access and ea.portal_access),
        'portal_access_level', ea.portal_access_level,
        'can_use_ios_app', ea.has_access,
        'can_use_android_app', ea.has_access,
        'expires_at', case when ea.plan_tier = 'trial' then ea.trial_end
                           else coalesce(ea.manual_grant_expires_at,
                                         ea.trial_end,
                                         greatest(ea.current_period_end, ea.grace_period_end),
                                         ea.current_period_end,
                                         ea.grace_period_end) end,
        'last_verified_at', (
          select es.updated_at from public.vinetrack_entitlement_state es
          where es.user_id = p_user_id
        ),
        'cached_state', (
          select jsonb_build_object(
            'has_access', es.has_access, 'access_source', es.access_source,
            'reason_code', es.reason_code, 'plan_code', es.plan_code,
            'updated_at', es.updated_at
          )
          from public.vinetrack_entitlement_state es
          where es.user_id = p_user_id
        )
      )
      from public._admin_effective_access(p_user_id) ea
    ),

    -- SQL 144: server-authoritative account trial (sql/143). Appears as an
    -- ACCESS SOURCE — never as an Apple/Google/portal purchase.
    'account_trial', (
      select jsonb_build_object(
        'source_type', 'account_trial',
        'trial_started_at', t.trial_started_at,
        'trial_ends_at', t.trial_ends_at,
        'status', t.status,
        'is_currently_valid', t.is_active,
        'created_from', t.created_from,
        'is_persisted', t.is_persisted
      )
      from public._account_trial_for(p_user_id) t
    ),

    'billing_sources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'subscription_id', s.id,
        'plan_code', p.code,
        'plan_name', p.name,
        'plan_tier', p.tier,
        'billing_provider', s.billing_provider,
        'status', s.status,
        'environment', s.environment,
        'purchase_platform', s.platform,
        'is_owner', (s.owner_user_id = p_user_id),
        'started_at', s.started_at,
        'trial_end', s.trial_end,
        'current_period_start', s.current_period_start,
        'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end,
        'grace_period_end', s.grace_period_end,
        'canceled_at', s.canceled_at,
        'expired_at', s.expired_at,
        'deleted_at', s.deleted_at,
        'unlimited_licences', coalesce(s.unlimited_licences, false),
        'manual_grant_reason', s.manual_grant_reason,
        'manual_grant_expires_at', s.manual_grant_expires_at,
        'manual_grant_revoked_at', s.manual_grant_revoked_at,
        'external_subscription_ref', case
          when s.external_subscription_id is null then null
          when length(s.external_subscription_id) <= 8 then '…'
          else left(s.external_subscription_id, 4) || '…' || right(s.external_subscription_id, 4)
        end,
        'product_id', (
          select e.product_id from public.billing_provider_events e
          where e.resolved_user_id = s.owner_user_id
            and e.product_id is not null
            and (s.external_subscription_id is null
                 or e.external_subscription_id = s.external_subscription_id)
          order by e.received_at desc limit 1
        ),
        'last_provider_event', s.last_provider_event,
        'last_provider_event_at', s.last_provider_event_at,
        'last_verified_at', s.last_verified_at,
        'seats_included', s.seats_included,
        'seats_purchased', s.seats_purchased,
        'active_licences', (
          select count(*)::integer from public.vinetrack_user_licences cl
          where cl.subscription_id = s.id and cl.status = 'active'
        ),
        'is_effective', (s.id = (
          select ea2.subscription_id from public._admin_effective_access(p_user_id) ea2
        )),
        'is_currently_valid', (
          s.deleted_at is null
          and (s.environment is null or s.environment <> 'sandbox')
          and (
            s.status in ('trialing', 'active', 'manual')
            or (coalesce(s.unlimited_licences, false) and s.status = 'past_due')
            or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
          )
          and (s.started_at is null or s.started_at <= now())
          and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
          and (
            coalesce(s.unlimited_licences, false)
            or s.status not in ('active', 'past_due')
            or s.current_period_end is null
            or s.current_period_end > now()
            or (s.grace_period_end is not null and s.grace_period_end > now())
          )
          and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
          and (
            coalesce(s.unlimited_licences, false) = false
            or s.manual_grant_expires_at is null
            or s.manual_grant_expires_at > now()
          )
        )
      ) order by (s.deleted_at is null) desc, s.updated_at desc)
      from public.vinetrack_subscriptions s
      join public.vinetrack_plans p on p.id = s.plan_id
      where s.owner_user_id = p_user_id
         or exists (
           select 1 from public.vinetrack_user_licences l
           where l.subscription_id = s.id and l.user_id = p_user_id
         )
    ), '[]'::jsonb),

    'licences_held', coalesce((
      select jsonb_agg(jsonb_build_object(
        'licence_id', l.id,
        'subscription_id', l.subscription_id,
        'plan_code', p.code,
        'plan_name', p.name,
        'status', l.status,
        'vineyard_id', l.vineyard_id,
        'vineyard_name', vy.name,
        'assigned_at', l.assigned_at,
        'revoked_at', l.revoked_at
      ) order by l.assigned_at desc)
      from public.vinetrack_user_licences l
      join public.vinetrack_subscriptions s2 on s2.id = l.subscription_id
      join public.vinetrack_plans p on p.id = s2.plan_id
      left join public.vineyards vy on vy.id = l.vineyard_id
      where l.user_id = p_user_id
    ), '[]'::jsonb),

    'open_alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'alert_id', a.id,
        'alert_type', a.alert_type,
        'severity', a.severity,
        'product_id', a.product_id,
        'event_type', a.event_type,
        'detail', a.detail,
        'created_at', a.created_at
      ) order by a.created_at desc)
      from public.billing_admin_alerts a
      where a.resolved_user_id = p_user_id
        and a.acknowledged_at is null
    ), '[]'::jsonb)
  ) into v;

  return v;
end;
$function$;

CREATE OR REPLACE FUNCTION public._admin_refresh_entitlement_state(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ea record;
  v_source      text;
  v_prev_has    boolean;
  v_prev_source text;
  v_prev_reason text;
  v_event       text;
  v_changed     boolean := false;
begin
  select * into ea from public._admin_effective_access(p_user_id);
  v_source := coalesce(ea.plan_tier, 'none');

  select es.has_access, es.access_source, es.reason_code
    into v_prev_has, v_prev_source, v_prev_reason
  from public.vinetrack_entitlement_state es
  where es.user_id = p_user_id;

  if not found then
    insert into public.vinetrack_entitlement_state
      (user_id, has_access, access_source, reason_code, plan_code, updated_at)
    values (p_user_id, ea.has_access, v_source, ea.reason_code, ea.plan_code, now());

    insert into public.vinetrack_entitlement_audit
      (user_id, event_type, previous_state, new_state, platform)
    values (
      p_user_id,
      case when ea.has_access then 'entitlement_granted' else 'entitlement_denied' end,
      null,
      jsonb_build_object(
        'has_access', ea.has_access, 'access_source', v_source,
        'reason_code', ea.reason_code, 'plan_code', ea.plan_code
      ),
      'server'
    );
    v_changed := true;
  elsif v_prev_has is distinct from ea.has_access
     or v_prev_source is distinct from v_source
     or v_prev_reason is distinct from ea.reason_code then

    v_event := case
      when ea.has_access and not coalesce(v_prev_has, false) then 'entitlement_granted'
      when not ea.has_access and coalesce(v_prev_has, false) then
        case ea.reason_code
          when 'expired' then 'entitlement_expired'
          when 'revoked' then 'entitlement_revoked'
          else 'entitlement_denied'
        end
      else 'entitlement_source_changed'
    end;

    update public.vinetrack_entitlement_state es
    set has_access    = ea.has_access,
        access_source = v_source,
        reason_code   = ea.reason_code,
        plan_code     = ea.plan_code,
        updated_at    = now()
    where es.user_id = p_user_id;

    insert into public.vinetrack_entitlement_audit
      (user_id, event_type, previous_state, new_state, platform)
    values (
      p_user_id,
      v_event,
      jsonb_build_object(
        'has_access', v_prev_has, 'access_source', v_prev_source,
        'reason_code', v_prev_reason
      ),
      jsonb_build_object(
        'has_access', ea.has_access, 'access_source', v_source,
        'reason_code', ea.reason_code, 'plan_code', ea.plan_code
      ),
      'server'
    );
    v_changed := true;
  end if;

  return jsonb_build_object(
    'user_id', p_user_id,
    'has_access', ea.has_access,
    'access_source', v_source,
    'reason_code', ea.reason_code,
    'plan_code', ea.plan_code,
    'changed', v_changed,
    'refreshed_at', now()
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_vinetrack_access()
 RETURNS TABLE(user_id uuid, has_supabase_access boolean, access_source text, is_owner boolean, subscription_id uuid, plan_code text, plan_tier text, plan_name text, billing_provider text, status text, trial_end timestamp with time zone, current_period_end timestamp with time zone, portal_access boolean, portal_access_level text, can_use_ios_app boolean, can_use_portal boolean, seats_included integer, seats_purchased integer, active_licences integer, vineyard_id uuid, licence_id uuid, unlimited_licences boolean, manual_grant_reason text, manual_grant_expires_at timestamp with time zone, solo_check_required boolean, reason_code text, is_unlimited boolean, can_use_android_app boolean, last_verified_at timestamp with time zone, enforcement_enabled boolean, purchase_platform text, cancel_at_period_end boolean, grace_period_end timestamp with time zone, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();

  v_sub_id          uuid;
  v_is_owner        boolean;
  v_status          text;
  v_provider        text;
  v_trial_end       timestamptz;
  v_period_end      timestamptz;
  v_seats_included  integer;
  v_seats_purchased integer;
  v_unlimited       boolean;
  v_grant_reason    text;
  v_grant_expires   timestamptz;
  v_plan_code       text;
  v_plan_tier       text;
  v_plan_name       text;
  v_portal_level    text;
  v_active_licences integer;
  v_licence_id      uuid;
  v_vineyard_id     uuid;
  v_platform        text;
  v_cancel_at_end   boolean;
  v_grace_end       timestamptz;
  v_expires_at      timestamptz;

  tr record;
  vb record;   -- SQL 156: best vineyard-backed entitlement

  v_has     boolean := false;
  v_source  text := 'none';
  v_reason  text := 'no_entitlement';
  v_enforce boolean := false;

  v_prev_has    boolean;
  v_prev_source text;
  v_prev_reason text;
  v_event       text;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- ---- 1. Best VALID own subscription entitlement (unchanged from SQL 144).
  select
    b.id, b.b_is_owner, b.b_status, b.b_provider, b.b_trial_end, b.b_period_end,
    b.b_seats_included, b.b_seats_purchased, b.b_unlimited, b.b_grant_reason,
    b.b_grant_expires, b.b_plan_code, b.b_plan_tier, b.b_plan_name,
    b.b_portal_level, b.b_active_licences, b.b_licence_id, b.b_vineyard_id,
    b.b_platform, b.b_cancel_at_end, b.b_grace_end
  into
    v_sub_id, v_is_owner, v_status, v_provider, v_trial_end, v_period_end,
    v_seats_included, v_seats_purchased, v_unlimited, v_grant_reason,
    v_grant_expires, v_plan_code, v_plan_tier, v_plan_name,
    v_portal_level, v_active_licences, v_licence_id, v_vineyard_id,
    v_platform, v_cancel_at_end, v_grace_end
  from (select 1) one
  left join (
    select
      s.id,
      (s.owner_user_id = v_uid)             as b_is_owner,
      s.status                               as b_status,
      s.billing_provider                     as b_provider,
      s.trial_end                            as b_trial_end,
      s.current_period_end                   as b_period_end,
      s.seats_included                       as b_seats_included,
      s.seats_purchased                      as b_seats_purchased,
      coalesce(s.unlimited_licences, false)  as b_unlimited,
      s.manual_grant_reason                  as b_grant_reason,
      s.manual_grant_expires_at              as b_grant_expires,
      p.code                                 as b_plan_code,
      p.tier                                 as b_plan_tier,
      p.name                                 as b_plan_name,
      p.portal_access_level                  as b_portal_level,
      s.platform                             as b_platform,
      coalesce(s.cancel_at_period_end, false) as b_cancel_at_end,
      s.grace_period_end                     as b_grace_end,
      (
        select count(*)::integer
        from public.vinetrack_user_licences cl
        where cl.subscription_id = s.id
          and cl.status = 'active'
      ) as b_active_licences,
      (
        select ul.id
        from public.vinetrack_user_licences ul
        where ul.subscription_id = s.id
          and ul.user_id = v_uid
          and ul.status = 'active'
        order by ul.id
        limit 1
      ) as b_licence_id,
      coalesce(
        (
          select ul2.vineyard_id
          from public.vinetrack_user_licences ul2
          where ul2.subscription_id = s.id
            and ul2.user_id = v_uid
            and ul2.status = 'active'
          order by ul2.id
          limit 1
        ),
        s.primary_vineyard_id
      ) as b_vineyard_id,
      case
        when p.code = 'internal_unlimited' then 6
        when p.tier = 'enterprise'         then 5
        when p.tier = 'team'               then 4
        when p.tier = 'legacy'             then 3
        when p.tier = 'solo'               then 2
        else 1
      end as tier_rank
    from public.vinetrack_subscriptions s
    join public.vinetrack_plans p on p.id = s.plan_id
    where s.deleted_at is null
      and (s.environment is null or s.environment <> 'sandbox')
      and (
        s.owner_user_id = v_uid
        or exists (
          select 1 from public.vinetrack_user_licences l
          where l.subscription_id = s.id
            and l.user_id = v_uid
            and l.status = 'active'
        )
      )
      and (
        s.status in ('trialing', 'active', 'manual')
        or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
        or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
      )
      and (s.started_at is null or s.started_at <= now())
      and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
      and (
        coalesce(s.unlimited_licences, false) = true
        or s.status not in ('active', 'past_due')
        or s.current_period_end is null
        or s.current_period_end > now()
        or (s.grace_period_end is not null and s.grace_period_end > now())
      )
      and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
      and (
        coalesce(s.unlimited_licences, false) = false
        or s.manual_grant_expires_at is null
        or s.manual_grant_expires_at > now()
      )
    order by
      tier_rank desc,
      (s.status = 'trialing') asc,
      (s.owner_user_id = v_uid) desc,
      s.current_period_end desc nulls last,
      s.created_at desc,
      s.id
    limit 1
  ) b on true;

  -- ---- 2. Account trial (sql/143).
  select * into tr from public._account_trial_for(v_uid);

  -- ---- 3. Reason code + precedence (subscription > trial > VINEYARD > denial).
  if v_sub_id is not null then
    v_has := true;
    v_source := coalesce(v_plan_tier, 'none');
    v_reason := case
      when v_plan_code = 'internal_unlimited'            then 'internal_unlimited'
      when v_plan_tier = 'enterprise'                    then 'enterprise_subscription'
      when v_status = 'trialing'
           and v_provider not in ('apple', 'google')     then 'active_trial'
      when v_licence_id is not null
           and coalesce(v_is_owner, false) = false
           and v_provider not in ('apple', 'google')     then 'assigned_licence'
      when v_provider in ('apple', 'google')             then 'app_store_subscription'
      else 'portal_subscription'
    end;
    select min(cand) into v_expires_at
    from unnest(array[
      v_grant_expires,
      v_trial_end,
      case
        when v_period_end is not null and v_grace_end is not null
          then greatest(v_period_end, v_grace_end)
        else coalesce(v_period_end, v_grace_end)
      end
    ]) cand
    where cand is not null and cand > now();

  elsif coalesce(tr.is_active, false) then
    v_has          := true;
    v_source       := 'trial';
    v_reason       := 'active_trial';
    v_plan_code    := 'trial';
    v_plan_tier    := 'trial';
    v_plan_name    := 'Account Trial';
    v_provider     := 'trial';
    v_status       := 'trialling';
    v_trial_end    := tr.trial_ends_at;
    v_portal_level := 'basic';
    v_seats_included := 1;
    v_expires_at   := tr.trial_ends_at;

  else
    -- ---- SQL 156: vineyard-backed access. When the user has no own
    --      entitlement, any of their vineyards funded by a vineyard-wide
    --      grant, an anchored subscription, or an active Owner's own
    --      entitlement still grants access. The funding subscription id
    --      is NOT exposed to plain members.
    select mv.m_vineyard_id, ve.*
    into vb
    from (
      select vy.id as m_vineyard_id
      from public.vineyards vy
      left join public.vineyard_members vm
        on vm.vineyard_id = vy.id and vm.user_id = v_uid
      where vy.deleted_at is null
        and (vm.user_id = v_uid or vy.owner_id = v_uid)
    ) mv
    cross join lateral public._vineyard_entitlement_for(mv.m_vineyard_id) ve
    where ve.has_entitlement
    order by ve.is_trial asc, ve.expires_at desc nulls first, mv.m_vineyard_id
    limit 1;

    if vb.m_vineyard_id is not null then
      v_has          := true;
      v_source       := 'vineyard';
      v_reason       := 'vineyard_entitlement';
      v_plan_code    := vb.plan_code;
      v_plan_tier    := 'vineyard';
      v_plan_name    := vb.plan_name;
      v_provider     := 'vineyard';
      v_status       := vb.subscription_status;
      v_vineyard_id  := vb.m_vineyard_id;
      v_portal_level := 'basic';
      v_seats_included := 1;
      v_expires_at   := vb.expires_at;
      if vb.is_trial then
        v_trial_end := vb.expires_at;
      end if;
      -- subscription_id / licence stay NULL for members.

    else
      -- ---- Denial classification (unchanged from SQL 144).
      select case
        when s2.manual_grant_revoked_at is not null
          or s2.status = 'canceled'
          or s2.deleted_at is not null                                  then 'revoked'
        when s2.status = 'expired'                                      then 'expired'
        when s2.status = 'trialing'
          and s2.trial_end is not null and s2.trial_end <= now()        then 'expired'
        when s2.status in ('active', 'past_due')
          and s2.current_period_end is not null
          and s2.current_period_end <= now()                            then 'expired'
        when coalesce(s2.unlimited_licences, false) = true
          and s2.manual_grant_expires_at is not null
          and s2.manual_grant_expires_at <= now()                       then 'expired'
        else null
      end
      into v_reason
      from public.vinetrack_subscriptions s2
      where s2.owner_user_id = v_uid
         or exists (
           select 1 from public.vinetrack_user_licences l2
           where l2.subscription_id = s2.id and l2.user_id = v_uid
         )
      order by s2.updated_at desc, s2.id
      limit 1;

      if v_reason is null and tr.status is not null then
        v_reason     := case when tr.status = 'revoked' then 'revoked' else 'expired' end;
        v_source     := 'trial';
        v_plan_code  := 'trial';
        v_plan_tier  := 'trial';
        v_plan_name  := 'Account Trial';
        v_provider   := 'trial';
        v_status     := case when tr.status = 'revoked' then 'revoked' else 'expired' end;
        v_trial_end  := tr.trial_ends_at;
        v_expires_at := tr.trial_ends_at;
      end if;

      v_reason := coalesce(v_reason, 'no_entitlement');
    end if;
  end if;

  -- ---- 4. Per-caller rollout flag (unchanged).
  v_enforce := public._entitlement_enforcement_enabled(
    v_uid,
    v_has and v_reason = 'internal_unlimited'
  );

  -- ---- 5. Guarded maintenance + change-detected audit (unchanged).
  begin
    perform public._ensure_account_trial(v_uid);

    select es.has_access, es.access_source, es.reason_code
      into v_prev_has, v_prev_source, v_prev_reason
    from public.vinetrack_entitlement_state es
    where es.user_id = v_uid;

    if not found then
      insert into public.vinetrack_entitlement_state
        (user_id, has_access, access_source, reason_code, plan_code, updated_at)
      values (v_uid, v_has, v_source, v_reason, v_plan_code, now());

      insert into public.vinetrack_entitlement_audit
        (user_id, event_type, previous_state, new_state, platform)
      values (
        v_uid,
        case when v_has then 'entitlement_granted' else 'entitlement_denied' end,
        null,
        jsonb_build_object(
          'has_access', v_has, 'access_source', v_source,
          'reason_code', v_reason, 'plan_code', v_plan_code
        ),
        'server'
      );
    elsif v_prev_has is distinct from v_has
       or v_prev_source is distinct from v_source
       or v_prev_reason is distinct from v_reason then

      v_event := case
        when v_has and not coalesce(v_prev_has, false) then 'entitlement_granted'
        when not v_has and coalesce(v_prev_has, false) then
          case v_reason
            when 'expired' then 'entitlement_expired'
            when 'revoked' then 'entitlement_revoked'
            else 'entitlement_denied'
          end
        else 'entitlement_source_changed'
      end;

      update public.vinetrack_entitlement_state es
      set has_access    = v_has,
          access_source = v_source,
          reason_code   = v_reason,
          plan_code     = v_plan_code,
          updated_at    = now()
      where es.user_id = v_uid;

      insert into public.vinetrack_entitlement_audit
        (user_id, event_type, previous_state, new_state, platform)
      values (
        v_uid,
        v_event,
        jsonb_build_object(
          'has_access', v_prev_has, 'access_source', v_prev_source,
          'reason_code', v_prev_reason
        ),
        jsonb_build_object(
          'has_access', v_has, 'access_source', v_source,
          'reason_code', v_reason, 'plan_code', v_plan_code
        ),
        'server'
      );
    end if;
  exception when others then
    null;
  end;

  -- ---- 6. Response (same 34 columns as SQL 144).
  return query select
    v_uid,
    v_has,
    v_source,
    coalesce(v_is_owner, false),
    v_sub_id,
    v_plan_code,
    v_plan_tier,
    v_plan_name,
    v_provider,
    v_status,
    v_trial_end,
    v_period_end,
    (v_has and coalesce(v_portal_level, 'none') <> 'none'),
    coalesce(v_portal_level, 'none'),
    v_has,
    (v_has and coalesce(v_portal_level, 'none') <> 'none'),
    v_seats_included,
    v_seats_purchased,
    coalesce(v_active_licences, 0),
    v_vineyard_id,
    v_licence_id,
    coalesce(v_unlimited, false),
    v_grant_reason,
    v_grant_expires,
    (not v_has),
    v_reason,
    coalesce(v_unlimited, false),
    v_has,
    now(),
    v_enforce,
    v_platform,
    coalesce(v_cancel_at_end, false),
    v_grace_end,
    v_expires_at;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_system_feature_flag(p_key text, p_is_enabled boolean, p_value jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    if not public.is_system_admin() then
        raise exception 'System admin required' using errcode = '42501';
    end if;

    insert into public.system_feature_flags as f (key, value, is_enabled, updated_at, updated_by)
    values (
        p_key,
        coalesce(p_value, to_jsonb(p_is_enabled)),
        p_is_enabled,
        now(),
        auth.uid()
    )
    on conflict (key) do update
        set is_enabled = excluded.is_enabled,
            value      = coalesce(p_value, to_jsonb(excluded.is_enabled)),
            updated_at = now(),
            updated_by = auth.uid();
end$function$;

DROP FUNCTION public._vinetrack_subscription_is_current(public.vinetrack_subscriptions, timestamptz);

