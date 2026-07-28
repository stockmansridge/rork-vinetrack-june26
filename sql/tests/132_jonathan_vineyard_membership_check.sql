-- ============================================================================
-- Phase 2A §1 — Vineyard membership verification for Jonathan
-- ============================================================================
-- READ-ONLY. Run in the Supabase SQL editor. Returns ONE JSON object (the
-- editor shows only the last statement's result, so everything is folded in).
--
-- Answers, for jonathan@stockmansridge.com.au:
--   * every vineyard membership he holds (name, role, joined date)
--   * whether a "Stockman's Ridge"-named vineyard exists in the database
--     and whether he is a member of it
--   * his profile's stored default (selected) vineyard and whether that
--     vineyard is one he can actually access
--   * which single vineyard_id the resolver reports (the resolver returns
--     the licensed/primary vineyard, not the full membership list — the
--     apps load the full list separately via vineyard_members RLS)
--
-- No data is modified. No tokens or Auth metadata are exposed.
-- ============================================================================

with target_user as (
  select u.id as user_id
  from auth.users u
  where lower(u.email) = lower('jonathan@stockmansridge.com.au')
  limit 1
),
memberships as (
  select
    vm.vineyard_id,
    v.name        as vineyard_name,
    vm.role,
    vm.joined_at,
    v.deleted_at  is not null as vineyard_deleted,
    v.owner_id = tu.user_id   as is_vineyard_owner_column
  from target_user tu
  join public.vineyard_members vm on vm.user_id = tu.user_id
  join public.vineyards v on v.id = vm.vineyard_id
),
stockmans as (
  select
    v.id,
    v.name,
    v.deleted_at is not null as deleted,
    exists (
      select 1 from target_user tu
      join public.vineyard_members vm
        on vm.vineyard_id = v.id and vm.user_id = tu.user_id
    ) as jonathan_is_member
  from public.vineyards v
  where v.name ilike '%stockman%'
),
profile_default as (
  select
    p.default_vineyard_id,
    dv.name as default_vineyard_name,
    (p.default_vineyard_id is null) as no_default_set,
    exists (
      select 1 from memberships m
      where m.vineyard_id = p.default_vineyard_id
    ) as default_is_accessible
  from target_user tu
  join public.profiles p on p.id = tu.user_id
  left join public.vineyards dv on dv.id = p.default_vineyard_id
),
resolver_vineyard as (
  -- The vineyard the licence/grant is attached to (what the resolver
  -- reports as its single vineyard_id). Mirrors sql/132: ownership is via
  -- owner_user_id OR an active licence; vineyard_id = the caller's active
  -- licence vineyard, falling back to the subscription's primary vineyard.
  select
    s.id     as subscription_id,
    s.status as subscription_status,
    coalesce(
      (
        select ul.vineyard_id
        from public.vinetrack_user_licences ul
        where ul.subscription_id = s.id
          and ul.user_id = tu.user_id
          and ul.status = 'active'
        order by ul.id
        limit 1
      ),
      s.primary_vineyard_id
    ) as resolver_vineyard_id
  from target_user tu
  join public.vinetrack_subscriptions s
    on (
         s.owner_user_id = tu.user_id
         or exists (
           select 1 from public.vinetrack_user_licences l
           where l.subscription_id = s.id
             and l.user_id = tu.user_id
             and l.status = 'active'
         )
       )
   and s.deleted_at is null
   and s.status in ('trialing', 'active', 'manual', 'past_due')
  order by s.updated_at desc, s.id
  limit 1
),
resolver_vineyard_named as (
  select
    rv.subscription_id,
    rv.subscription_status,
    rv.resolver_vineyard_id,
    v.name as resolver_vineyard_name
  from resolver_vineyard rv
  left join public.vineyards v on v.id = rv.resolver_vineyard_id
)
select jsonb_pretty(jsonb_build_object(
  'auth_user_found',        exists (select 1 from target_user),
  'membership_count',       (select count(*) from memberships),
  'memberships',            coalesce((
                              select jsonb_agg(jsonb_build_object(
                                'vineyard_id',   m.vineyard_id,
                                'vineyard_name', m.vineyard_name,
                                'role',          m.role,
                                'joined_at',     m.joined_at,
                                'vineyard_deleted', m.vineyard_deleted
                              ) order by m.joined_at)
                              from memberships m
                            ), '[]'::jsonb),
  'stockmans_ridge_vineyards', coalesce((
                              select jsonb_agg(jsonb_build_object(
                                'vineyard_id', s.id,
                                'name',        s.name,
                                'deleted',     s.deleted,
                                'jonathan_is_member', s.jonathan_is_member
                              ))
                              from stockmans s
                            ), '[]'::jsonb),
  'stockmans_ridge_exists', exists (select 1 from stockmans where not deleted),
  'jonathan_member_of_stockmans_ridge',
                            exists (select 1 from stockmans where jonathan_is_member and not deleted),
  'profile_default_vineyard', (select to_jsonb(pd) from profile_default pd),
  'resolver_primary_vineyard', (select to_jsonb(rv) from resolver_vineyard_named rv),
  'note', 'The resolver returns ONE vineyard_id (the licence''s primary vineyard). '
          || 'The apps list ALL memberships separately via vineyard_members; '
          || 'entitlement access and vineyard membership remain independent.'
)) as jonathan_vineyard_membership_report;
