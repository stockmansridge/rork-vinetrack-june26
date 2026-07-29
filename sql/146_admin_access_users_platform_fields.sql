-- =====================================================================
-- 146_admin_access_users_platform_fields.sql
-- =====================================================================
-- Phase 2C.2 — append the three Available Platform booleans to the
-- System Admin user directory so the portal can render the "Available
-- Platforms" column inline, without a per-row detail call.
--
-- EXISTING BEHAVIOUR BEING CORRECTED:
--   admin_access_users() (SQL 144) does not return portal_access /
--   can_use_ios_app / can_use_android_app, even though
--   admin_user_access_detail() already exposes them. The paginated
--   directory therefore cannot display Available Platforms.
--
-- WHAT THIS MIGRATION CHANGES (one function only):
--   DROPs and recreates public.admin_access_users(...) with:
--     * IDENTICAL parameters (names, types, defaults, order);
--     * IDENTICAL first 26 output columns (names, types, order,
--       meanings, pagination, filters, total_count window) — any
--       positional consumer keeps working;
--     * THREE new APPENDED columns, all guaranteed non-null:
--         portal_access       boolean
--         can_use_ios_app     boolean
--         can_use_android_app boolean
--
-- SOURCE OF TRUTH (no inference from platform/source/role/plan):
--   The values come from the SAME per-user effective-access calculation
--   the whole admin surface uses — _admin_effective_access(user_id),
--   the read-only mirror of get_my_vinetrack_access() — combined with
--   the EXACT expressions admin_user_access_detail() already returns:
--     portal_access       = ea.has_access AND ea.portal_access
--                           (resolver: v_has AND portal_level <> 'none')
--     can_use_ios_app     = ea.has_access   (resolver column 15)
--     can_use_android_app = ea.has_access   (resolver column 28)
--   Consequences (all inherited, not re-implemented):
--     * Internal Unlimited / active account trial / valid Apple / valid
--       Google / valid portal sub / assigned licence -> all three TRUE
--       (every granting path sets portal_access_level <> 'none');
--     * expired or revoked entitlement with no fallback -> all FALSE.
--
-- NOT CHANGED: get_my_vinetrack_access(), _admin_effective_access(),
--   admin_user_access_detail(), admin_user_access_history(), any
--   mutation RPC, the entitlement feature flag (stays 'internal').
--
-- ROLLBACK (non-destructive):
--   drop function if exists public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer);
--   -- then re-run sql/144 section C to restore the 26-column version.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public._admin_effective_access(uuid)') is null then
    raise exception 'SQL 146 precondition failed: apply sql/140 first';
  end if;
  if to_regprocedure('public._account_trial_for(uuid)') is null then
    raise exception 'SQL 146 precondition failed: apply sql/143 + sql/144 first';
  end if;
end$$;

-- Return signature grows by three appended columns -> DROP + recreate.
drop function if exists public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer);

create function public.admin_access_users(
  p_search         text    default null,   -- email / full name (ilike)
  p_has_access     boolean default null,   -- true = granted, false = denied
  p_plan_code      text    default null,   -- effective plan code
  p_vineyard_id    uuid    default null,   -- member of this vineyard
  p_role           text    default null,   -- owner|manager|supervisor|operator
  p_billing_source text    default null,   -- apple|google|stripe|manual|internal|trial|none
  p_status_filter  text    default null,   -- trial|expired|cancelled|needs_review|failed|mismatch|manual_override
  p_limit          integer default 50,
  p_offset         integer default 0
)
returns table (
  user_id              uuid,
  email                text,
  full_name            text,
  email_confirmed      boolean,
  is_disabled          boolean,
  is_system_admin      boolean,
  account_created_at   timestamptz,
  last_sign_in_at      timestamptz,
  vineyards            jsonb,
  has_access           boolean,
  reason_code          text,
  access_source        text,
  plan_code            text,
  plan_name            text,
  billing_provider     text,
  purchase_platform    text,
  product_id           text,
  subscription_status  text,
  current_period_end   timestamptz,
  cancel_at_period_end boolean,
  manual_override      boolean,
  unlimited_licences   boolean,
  licence_count        integer,
  review_status        text,
  last_verified_at     timestamptz,
  total_count          bigint,
  -- ---- NEW (SQL 146, appended — additive only; always non-null) ----
  portal_access        boolean,
  can_use_ios_app      boolean,
  can_use_android_app  boolean
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
  with users as (
    select
      u.id,
      coalesce(pr.email, u.email)::text as email,
      pr.full_name,
      (u.email_confirmed_at is not null) as email_confirmed,
      (u.banned_until is not null and u.banned_until > now()) as is_disabled,
      exists (
        select 1 from public.system_admins sa
        where sa.user_id = u.id and sa.is_active = true
      ) as is_sys_admin,
      u.created_at,
      u.last_sign_in_at
    from auth.users u
    left join public.profiles pr on pr.id = u.id
    where u.deleted_at is null
      and (
        p_search is null
        or coalesce(pr.email, u.email) ilike '%' || p_search || '%'
        or coalesce(pr.full_name, '') ilike '%' || p_search || '%'
      )
      and (
        p_vineyard_id is null
        or exists (
          select 1 from public.vineyard_members vm
          where vm.user_id = u.id and vm.vineyard_id = p_vineyard_id
        )
      )
      and (
        p_role is null
        or exists (
          select 1 from public.vineyard_members vm2
          join public.vineyards vy2 on vy2.id = vm2.vineyard_id
          where vm2.user_id = u.id
            and vm2.role = p_role
            and vy2.deleted_at is null
        )
      )
  ),
  enriched as (
    select
      us.*,
      ea.has_access           as e_has_access,
      ea.reason_code          as e_reason_code,
      coalesce(ea.plan_tier, 'none') as e_access_source,
      ea.plan_code            as e_plan_code,
      ea.plan_name            as e_plan_name,
      ea.billing_provider     as e_billing_provider,
      ea.purchase_platform    as e_purchase_platform,
      ea.status               as e_status,
      case when ea.plan_tier = 'trial' then ea.trial_end
           else ea.current_period_end end as e_period_end,
      ea.cancel_at_period_end as e_cancel_at_end,
      ea.unlimited_licences   as e_unlimited,
      -- SQL 146: identical expressions to admin_user_access_detail()
      -- 'effective_access' (which mirror resolver columns 13/15/28).
      (coalesce(ea.has_access, false)
       and coalesce(ea.portal_access, false)) as e_portal_access,
      (
        coalesce(ea.unlimited_licences, false)
        or ea.billing_provider = 'manual'
      ) as e_manual_override,
      coalesce((
        select prod.product_id
        from public.billing_provider_events prod
        where prod.resolved_user_id = us.id
          and prod.product_id is not null
        order by prod.received_at desc
        limit 1
      ), null) as e_product_id,
      coalesce((
        select count(*)::integer
        from public.vinetrack_user_licences lic
        where lic.user_id = us.id and lic.status = 'active'
      ), 0) as e_licence_count,
      case
        when exists (
          select 1 from public.vinetrack_entitlement_audit a
          where a.user_id = us.id
            and a.event_type = 'store_subscription_sync_mismatch'
            and a.created_at > now() - interval '30 days'
        ) then 'mismatch'
        when exists (
          select 1 from public.billing_provider_events e
          where e.resolved_user_id = us.id and e.processing_status = 'failed'
        ) then 'failed'
        when exists (
          select 1 from public.billing_provider_events e
          where e.resolved_user_id = us.id and e.processing_status = 'needs_review'
        ) then 'needs_review'
        else 'ok'
      end as e_review_status,
      (
        select es.updated_at from public.vinetrack_entitlement_state es
        where es.user_id = us.id
      ) as e_last_verified_at,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'vineyard_id', vy.id,
          'name', vy.name,
          'role', vm.role
        ) order by vy.name)
        from public.vineyard_members vm
        join public.vineyards vy on vy.id = vm.vineyard_id
        where vm.user_id = us.id and vy.deleted_at is null
      ), '[]'::jsonb) as e_vineyards
    from users us
    cross join lateral public._admin_effective_access(us.id) ea
  ),
  filtered as (
    select * from enriched en
    where (p_has_access is null or en.e_has_access = p_has_access)
      and (p_plan_code is null or en.e_plan_code = p_plan_code)
      and (
        p_billing_source is null
        or (p_billing_source = 'internal'
            and (en.e_plan_code = 'internal_unlimited' or coalesce(en.e_unlimited, false)))
        or (p_billing_source = 'trial'
            and (en.e_billing_provider = 'trial' or en.e_status in ('trialing', 'trialling')))
        or (p_billing_source = 'none' and en.e_has_access = false)
        or (p_billing_source in ('apple', 'google', 'stripe', 'manual')
            and en.e_billing_provider = p_billing_source)
      )
      and (
        p_status_filter is null
        or (p_status_filter = 'trial' and en.e_status in ('trialing', 'trialling'))
        or (p_status_filter = 'expired'
            and en.e_has_access = false and en.e_reason_code = 'expired')
        or (p_status_filter = 'cancelled'
            and ((en.e_has_access and coalesce(en.e_cancel_at_end, false))
                 or (en.e_has_access = false and en.e_reason_code = 'revoked')))
        or (p_status_filter = 'needs_review' and en.e_review_status = 'needs_review')
        or (p_status_filter = 'failed' and en.e_review_status = 'failed')
        or (p_status_filter = 'mismatch' and en.e_review_status = 'mismatch')
        or (p_status_filter = 'manual_override' and en.e_manual_override)
      )
  )
  select
    f.id,
    f.email,
    f.full_name,
    f.email_confirmed,
    f.is_disabled,
    f.is_sys_admin,
    f.created_at,
    f.last_sign_in_at,
    f.e_vineyards,
    f.e_has_access,
    f.e_reason_code,
    f.e_access_source,
    f.e_plan_code,
    f.e_plan_name,
    f.e_billing_provider,
    f.e_purchase_platform,
    f.e_product_id,
    f.e_status,
    f.e_period_end,
    coalesce(f.e_cancel_at_end, false),
    f.e_manual_override,
    coalesce(f.e_unlimited, false),
    f.e_licence_count,
    f.e_review_status,
    f.e_last_verified_at,
    count(*) over () as total_count,
    -- SQL 146 appended platform booleans (non-null by construction):
    coalesce(f.e_portal_access, false),      -- portal_access
    coalesce(f.e_has_access, false),         -- can_use_ios_app
    coalesce(f.e_has_access, false)          -- can_use_android_app
  from filtered f
  order by f.email asc
  limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;

revoke all on function public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer) from public;
grant execute on function public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer) to authenticated;

comment on function public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer) is
  'SQL 146: System-Admin-only paginated user directory. Identical to SQL 144 plus three appended non-null booleans from _admin_effective_access (same calculation as get_my_vinetrack_access / admin_user_access_detail): portal_access = has_access AND portal level <> none; can_use_ios_app / can_use_android_app = has_access. Internal Unlimited, active account trial, valid Apple/Google/portal/licence sources -> all three true; expired/revoked with no fallback -> all three false.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit, as a System Admin):
--   select user_id, email, has_access, reason_code,
--          portal_access, can_use_ios_app, can_use_android_app
--   from public.admin_access_users(p_limit => 50);
--   -- Expect: no NULLs in the three platform columns; rows with
--   -- has_access=false show false/false/false; active-trial and
--   -- Internal Unlimited rows show true/true/true.
--
--   -- Directory must agree with the detail RPC for any user:
--   select (d -> 'effective_access' ->> 'portal_access')::boolean,
--          (d -> 'effective_access' ->> 'can_use_ios_app')::boolean,
--          (d -> 'effective_access' ->> 'can_use_android_app')::boolean
--   from public.admin_user_access_detail('<user-uuid>') d;
--
-- Non-admin callers still get 42501.
--
-- ROLLBACK:
--   drop function if exists public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer);
--   -- then re-run sql/144 section C (restores the 26-column version).
-- =====================================================================
