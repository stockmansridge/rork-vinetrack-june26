-- =====================================================================
-- 148_billing_review_resolution_actions.sql
-- =====================================================================
-- Billing Review Resolution Actions — gives System Admins a safe way to
-- clear resolved or irrelevant items from the active Billing Health
-- review queues WITHOUT deleting any raw provider events, subscriptions,
-- audit records or webhook payload history.
--
-- AUDIT (existing behaviour being corrected):
--   Category               Source                                        Clearable today?
--   events_needing_review  billing_provider_events status=needs_review   NO — no fields, no RPC
--   failed events          billing_provider_events status=failed         NO
--   unresolved_users       billing_provider_events error_code in
--                          (unresolved_app_user_id, user_not_found)      NO
--   ownership_conflicts    billing_provider_events error_code =
--                          ownership_conflict                            NO
--   stuck_deliveries       billing_provider_events status=received
--                          older than 15 minutes                         NO
--   open_alerts            billing_admin_alerts acknowledged_at is null  YES —
--                          admin_acknowledge_billing_alert (SQL 139);
--                          count already excludes acknowledged rows.
--
-- WHAT THIS MIGRATION ADDS (all ADDITIVE):
--   A. Review-state columns on billing_provider_events:
--        resolved_at/by + resolution_reason/action,
--        dismissed_at/by + dismissal_reason,
--        retry_count / last_retry_at / last_retry_by,
--        review_item_type (queue snapshot for historical filtering).
--      A row can be resolved OR dismissed, never both. Raw payload,
--      processing status history and provider fields are untouched.
--   B. Helpers: _billing_ms_to_ts, _billing_event_is_retryable.
--   C. _billing_reprocess_provider_event — server-side idempotent retry
--      that mirrors the revenuecat-webhook pipeline (user gate,
--      entitlement gate, catalogue mapping, sandbox guard, stale-event
--      guard, ownership guard, keyed subscription upsert, licence
--      upsert, lifecycle audit). Internal only; no client grant.
--   D. admin_update_billing_review_item — unified, strictly-validated
--      mutation RPC (acknowledge | resolve | dismiss | retry |
--      link_user) + thin wrappers admin_resolve_billing_review_item,
--      admin_dismiss_billing_review_item, admin_retry_billing_delivery.
--      Every action requires System Admin + a non-empty reason and
--      writes an append-only vinetrack_billing_events audit row.
--   E. admin_billing_review_items — sanitised, paginated detail list
--      per category and status (open | resolved | dismissed | all).
--   F. admin_store_billing_monitor v2 — active counts now exclude
--      resolved/dismissed rows; adds recent_review_actions.
--   G. admin_billing_alerts v2 — lazy sync-window checks skip
--      resolved/dismissed events.
--
-- NEVER DELETES: no DELETE statement exists in this migration and none
-- of the new RPCs can remove rows from billing_provider_events,
-- billing_admin_alerts, vinetrack_subscriptions, vinetrack_user_licences,
-- vinetrack_billing_events or vinetrack_entitlement_audit.
--
-- ROLLBACK:
--   drop function if exists public.admin_billing_review_items(text, text, integer, integer);
--   drop function if exists public.admin_retry_billing_delivery(uuid, text);
--   drop function if exists public.admin_dismiss_billing_review_item(text, uuid, text);
--   drop function if exists public.admin_resolve_billing_review_item(text, uuid, text);
--   drop function if exists public.admin_update_billing_review_item(text, uuid, text, text, uuid);
--   drop function if exists public._billing_reprocess_provider_event(uuid, uuid);
--   drop function if exists public._billing_event_is_retryable(public.billing_provider_events);
--   drop function if exists public._billing_ms_to_ts(text);
--   alter table public.billing_provider_events
--     drop column if exists resolved_at,       drop column if exists resolved_by,
--     drop column if exists resolution_reason, drop column if exists resolution_action,
--     drop column if exists dismissed_at,      drop column if exists dismissed_by,
--     drop column if exists dismissal_reason,  drop column if exists review_item_type,
--     drop column if exists retry_count,       drop column if exists last_retry_at,
--     drop column if exists last_retry_by;
--   -- then re-run sections D and E of sql/139 to restore the previous
--   -- admin_store_billing_monitor / admin_billing_alerts definitions.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.billing_provider_events') is null
     or to_regclass('public.billing_admin_alerts') is null
     or to_regclass('public.vinetrack_billing_events') is null then
    raise exception 'SQL 148 precondition failed: apply sql/133, sql/139 and sql/141 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. Additive review-state columns (raw evidence untouched).
-- ---------------------------------------------------------------------------
alter table public.billing_provider_events
  add column if not exists resolved_at       timestamptz null,
  add column if not exists resolved_by       uuid null references auth.users(id) on delete set null,
  add column if not exists resolution_reason text null,
  add column if not exists resolution_action text null,
  add column if not exists dismissed_at      timestamptz null,
  add column if not exists dismissed_by      uuid null references auth.users(id) on delete set null,
  add column if not exists dismissal_reason  text null,
  add column if not exists review_item_type  text null
    check (review_item_type is null or review_item_type in
           ('event', 'unresolved_user', 'ownership_conflict', 'stuck_delivery')),
  add column if not exists retry_count       integer not null default 0,
  add column if not exists last_retry_at     timestamptz null,
  add column if not exists last_retry_by     uuid null references auth.users(id) on delete set null;

-- Resolved and dismissed are mutually exclusive.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.billing_provider_events'::regclass
      and conname  = 'billing_provider_events_review_state_chk'
  ) then
    alter table public.billing_provider_events
      add constraint billing_provider_events_review_state_chk
      check (resolved_at is null or dismissed_at is null);
  end if;
end$$;

create index if not exists idx_billing_provider_events_received_open
  on public.billing_provider_events (received_at desc)
  where processing_status = 'received' and resolved_at is null and dismissed_at is null;

comment on column public.billing_provider_events.resolved_at is
  'SQL 148: set by admin_update_billing_review_item when the underlying issue was corrected (manually or via successful retry). Row remains in history; active review queues exclude it.';
comment on column public.billing_provider_events.dismissed_at is
  'SQL 148: set by admin_update_billing_review_item when the item is irrelevant/synthetic/not actionable. Mandatory dismissal_reason; row remains in history.';

-- ---------------------------------------------------------------------------
-- B. Helpers.
-- ---------------------------------------------------------------------------
create or replace function public._billing_ms_to_ts(p text)
returns timestamptz
language sql
immutable
as $$
  select case
    when p is null or p !~ '^\d{1,17}$' then null
    else to_timestamp(p::numeric / 1000.0)
  end;
$$;

revoke all on function public._billing_ms_to_ts(text) from public;

-- Retryable = RevenueCat event, not closed, not a high-risk event type,
-- in a retryable processing state, and (for user-resolution failures)
-- already linked to a Supabase user via link_user.
create or replace function public._billing_event_is_retryable(e public.billing_provider_events)
returns boolean
language sql
stable
as $$
  select e.provider = 'revenuecat'
     and e.resolved_at is null
     and e.dismissed_at is null
     and e.event_type not in ('TEST', 'TRANSFER', 'SUBSCRIBER_ALIAS')
     and e.processing_status in ('received', 'failed', 'needs_review')
     and (coalesce(e.processing_error_code, '') not in ('unresolved_app_user_id', 'user_not_found')
          or e.resolved_user_id is not null);
$$;

revoke all on function public._billing_event_is_retryable(public.billing_provider_events) from public;

comment on function public._billing_event_is_retryable(public.billing_provider_events) is
  'SQL 148: whether a provider event may be reprocessed. TEST/TRANSFER/SUBSCRIBER_ALIAS are never retryable (transfer semantics stay webhook-only); user-resolution failures become retryable after link_user.';

-- ---------------------------------------------------------------------------
-- C. Idempotent server-side reprocessing (mirrors revenuecat-webhook).
--    Internal only — called by admin_update_billing_review_item.
-- ---------------------------------------------------------------------------
create or replace function public._billing_reprocess_provider_event(
  p_event_id uuid,
  p_admin    uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  e             public.billing_provider_events%rowtype;
  v_ev          jsonb;
  v_user        uuid;
  v_platform    text;
  v_provider    text;
  v_env_key     text;
  v_is_sandbox  boolean;
  v_is_trial    boolean;
  v_event_ts    timestamptz;
  v_purchased   timestamptz;
  v_expiration  timestamptz;
  v_grace       timestamptz;
  v_original    timestamptz;
  v_status      text;          -- outcome processing_status
  v_code        text;
  v_msg         text;
  v_sub_status  text;
  v_cancel      boolean;
  v_set_cancel  boolean := false;
  v_revoke      boolean := false;
  v_audit_event text;
  v_cat_plan    text;
  v_cat_ent     text;
  v_plan_id     uuid;
  v_plan_code   text;
  v_sub_id      uuid;
  v_ex_owner    uuid;
  v_ex_last     timestamptz;
  v_prev_status text;
  v_lic_id      uuid;
  v_lic_status  text;
begin
  select * into e
  from public.billing_provider_events
  where id = p_event_id
  for update;
  if not found then
    raise exception 'item_not_found' using errcode = 'P0002';
  end if;
  if not public._billing_event_is_retryable(e) then
    raise exception 'not_retryable' using errcode = '22023';
  end if;

  v_ev         := coalesce(e.raw_payload->'event', '{}'::jsonb);
  v_is_trial   := coalesce(v_ev->>'period_type', '') in ('TRIAL', 'INTRO');
  v_event_ts   := coalesce(e.provider_created_at,
                           public._billing_ms_to_ts(v_ev->>'event_timestamp_ms'),
                           e.received_at);
  v_purchased  := public._billing_ms_to_ts(v_ev->>'purchased_at_ms');
  v_expiration := public._billing_ms_to_ts(v_ev->>'expiration_at_ms');
  v_grace      := public._billing_ms_to_ts(v_ev->>'grace_period_expiration_at_ms');
  v_original   := coalesce(public._billing_ms_to_ts(v_ev->>'original_purchase_at_ms'),
                           public._billing_ms_to_ts(v_ev->>'original_purchased_at_ms'));
  v_is_sandbox := upper(coalesce(e.environment, '')) = 'SANDBOX';
  v_env_key    := case when v_is_sandbox then 'sandbox' else 'production' end;
  v_user       := e.resolved_user_id;

  -- Store mapping (same table as the webhook's storeMapping()).
  if upper(coalesce(e.store, '')) in ('APP_STORE', 'MAC_APP_STORE') then
    v_platform := 'ios';     v_provider := 'apple';
  elsif upper(coalesce(e.store, '')) = 'PLAY_STORE' then
    v_platform := 'android'; v_provider := 'google';
  end if;

  -- Decision chain — mirrors supabase/functions/revenuecat-webhook/index.ts.
  if v_user is null then
    v_status := 'needs_review'; v_code := 'unresolved_app_user_id';
    v_msg := 'No Supabase user linked to this event — use link_user first';
  elsif not exists (select 1 from auth.users where id = v_user) then
    v_status := 'needs_review'; v_code := 'user_not_found';
    v_msg := 'Linked user no longer exists in auth.users';
  elsif e.entitlement_ids is not null
        and coalesce(array_length(e.entitlement_ids, 1), 0) > 0
        and not ('pro' = any(e.entitlement_ids)) then
    if 'premium' = any(e.entitlement_ids) then
      v_status := 'needs_review'; v_code := 'entitlement_mismatch';
      v_msg := 'Event carries entitlement premium but not pro — configuration mismatch, no access granted';
    else
      v_status := 'needs_review'; v_code := 'unexpected_entitlement';
      v_msg := format('Entitlements [%s] do not include pro', array_to_string(e.entitlement_ids, ','));
    end if;
  elsif v_provider is null then
    v_status := 'needs_review'; v_code := 'unsupported_store';
    v_msg := format('Store %s is not an Apple/Google store', coalesce(e.store, 'unknown'));
  elsif e.product_id is null then
    v_status := 'needs_review'; v_code := 'missing_product_id';
    v_msg := 'Event has no product id';
  else
    select c.plan_code, c.entitlement_id
      into v_cat_plan, v_cat_ent
    from public.billing_product_catalog c
    where c.provider = 'revenuecat'
      and c.external_product_id = e.product_id
      and c.platform in (v_platform, 'any')
      and c.is_active
      and c.environment in (v_env_key, 'any')
    limit 1;

    if v_cat_plan is null then
      v_status := 'needs_review';
      v_code := case when exists (
          select 1 from public.billing_product_catalog c
          where c.provider = 'revenuecat' and c.external_product_id = e.product_id)
        then 'inactive_product' else 'unknown_product' end;
      v_msg := format('Product %s has no active %s mapping in billing_product_catalog — no access granted',
                      e.product_id, v_env_key);
    elsif v_cat_ent <> 'pro' then
      v_status := 'needs_review'; v_code := 'catalog_entitlement_mismatch';
      v_msg := format('Catalogue maps product to entitlement %s, expected pro', v_cat_ent);
    elsif v_is_sandbox then
      v_status := 'ignored'; v_code := 'sandbox_not_processed';
      v_msg := 'Sandbox events are recorded but never grant production access';
    else
      -- Lifecycle mapping (resolveStatus in the webhook).
      case e.event_type
        when 'INITIAL_PURCHASE' then
          v_sub_status := case when v_is_trial then 'trialing' else 'active' end;
          v_cancel := false; v_set_cancel := true;
          v_audit_event := 'store_subscription_created';
        when 'RENEWAL' then
          v_sub_status := case when v_is_trial then 'trialing' else 'active' end;
          v_cancel := false; v_set_cancel := true;
          v_audit_event := 'store_subscription_renewed';
        when 'PRODUCT_CHANGE' then
          v_sub_status := case when v_is_trial then 'trialing' else 'active' end;
          v_cancel := false; v_set_cancel := true;
          v_audit_event := 'store_subscription_product_changed';
        when 'UNCANCELLATION' then
          v_sub_status := case when v_is_trial then 'trialing' else 'active' end;
          v_cancel := false; v_set_cancel := true;
          v_audit_event := 'store_subscription_uncancelled';
        when 'SUBSCRIPTION_EXTENDED' then
          v_sub_status := 'active';
          v_audit_event := 'store_subscription_renewed';
        when 'NON_RENEWING_PURCHASE' then
          v_sub_status := 'active'; v_cancel := true; v_set_cancel := true;
          v_audit_event := 'store_subscription_created';
        when 'CANCELLATION' then
          v_sub_status := case when v_is_trial then 'trialing' else 'active' end;
          v_cancel := true; v_set_cancel := true;
          v_audit_event := 'store_subscription_cancelled';
        when 'BILLING_ISSUE' then
          v_sub_status := 'past_due';
          v_audit_event := 'store_subscription_billing_issue';
        when 'SUBSCRIPTION_PAUSED' then
          v_sub_status := 'paused'; v_revoke := true;
          v_audit_event := 'store_subscription_expired';
        when 'EXPIRATION' then
          v_sub_status := 'expired'; v_cancel := true; v_set_cancel := true;
          v_revoke := true;
          v_audit_event := 'store_subscription_expired';
        else
          v_sub_status := null;
      end case;

      if v_sub_status is null then
        v_status := 'ignored'; v_code := 'informational_event';
      else
        select p.id, p.code into v_plan_id, v_plan_code
        from public.vinetrack_plans p
        where p.code = v_cat_plan
        limit 1;

        if v_plan_id is null then
          v_status := 'failed'; v_code := 'plan_lookup_failed';
          v_msg := format('plan %s not found', v_cat_plan);
        else
          -- Existing subscription: keyed on (provider, external id) first —
          -- this is the structural duplicate guard; retries UPDATE, never
          -- create a second subscription for the same store transaction.
          if e.external_subscription_id is not null then
            select s.id, s.owner_user_id, s.last_provider_event_at, s.status
              into v_sub_id, v_ex_owner, v_ex_last, v_prev_status
            from public.vinetrack_subscriptions s
            where s.billing_provider = v_provider
              and s.external_subscription_id = e.external_subscription_id
              and s.deleted_at is null
            limit 1;
          end if;
          if v_sub_id is null then
            select s.id, s.owner_user_id, s.last_provider_event_at, s.status
              into v_sub_id, v_ex_owner, v_ex_last, v_prev_status
            from public.vinetrack_subscriptions s
            where s.owner_user_id = v_user
              and s.billing_provider = v_provider
              and s.deleted_at is null
            order by s.created_at desc
            limit 1;
          end if;

          if v_ex_last is not null and v_event_ts < v_ex_last then
            v_status := 'ignored'; v_code := 'stale_event';
            v_msg := 'Event older than the last processed provider event for this subscription';
          elsif v_sub_id is not null
                and v_ex_owner <> v_user
                and e.external_subscription_id is not null then
            v_status := 'needs_review'; v_code := 'ownership_conflict';
            v_msg := 'Provider subscription already belongs to a different Supabase user (transfer must arrive via a TRANSFER event)';
            insert into public.vinetrack_entitlement_audit
              (user_id, event_type, previous_state, new_state, platform)
            values (v_user, 'store_subscription_sync_mismatch',
                    jsonb_build_object('owner_user_id', v_ex_owner),
                    jsonb_build_object('code', 'ownership_conflict',
                                       'attempted_user', v_user,
                                       'provider_event_id', e.provider_event_id,
                                       'reprocessed_by', p_admin),
                    'server');
          else
            if v_sub_id is not null then
              update public.vinetrack_subscriptions s
              set owner_user_id           = v_user,
                  plan_id                 = v_plan_id,
                  platform                = v_platform,
                  environment             = 'production',
                  status                  = v_sub_status,
                  trial_start             = case when v_is_trial then v_purchased else s.trial_start end,
                  trial_end               = case when v_is_trial then v_expiration else s.trial_end end,
                  current_period_start    = coalesce(v_purchased, s.current_period_start),
                  current_period_end      = coalesce(v_expiration, s.current_period_end),
                  grace_period_end        = case
                                              when e.event_type = 'BILLING_ISSUE' then v_grace
                                              when v_sub_status in ('active', 'trialing') then null
                                              else s.grace_period_end
                                            end,
                  started_at              = coalesce(v_original, v_purchased, s.started_at),
                  canceled_at             = case
                                              when e.event_type = 'CANCELLATION' then now()
                                              when e.event_type = 'UNCANCELLATION' then null
                                              else s.canceled_at
                                            end,
                  expired_at              = case when v_sub_status = 'expired'
                                                 then coalesce(v_expiration, now())
                                                 else null end,
                  seats_included          = 1,
                  revenuecat_app_user_id  = coalesce(e.app_user_id, v_user::text),
                  revenuecat_entitlement  = 'pro',
                  external_subscription_id = coalesce(e.external_subscription_id, s.external_subscription_id),
                  external_transaction_id  = coalesce(e.external_transaction_id, s.external_transaction_id),
                  cancel_at_period_end    = case when v_set_cancel then v_cancel else s.cancel_at_period_end end,
                  last_provider_event     = e.event_type,
                  last_provider_event_at  = v_event_ts,
                  last_verified_at        = now(),
                  updated_at              = now()
              where s.id = v_sub_id;
            else
              insert into public.vinetrack_subscriptions
                (owner_user_id, plan_id, billing_provider, platform, environment, status,
                 trial_start, trial_end, current_period_start, current_period_end,
                 grace_period_end, started_at, canceled_at, expired_at,
                 cancel_at_period_end, seats_included,
                 revenuecat_app_user_id, revenuecat_entitlement,
                 external_subscription_id, external_transaction_id,
                 last_provider_event, last_provider_event_at, last_verified_at)
              values
                (v_user, v_plan_id, v_provider, v_platform, 'production', v_sub_status,
                 case when v_is_trial then v_purchased end,
                 case when v_is_trial then v_expiration end,
                 v_purchased, v_expiration,
                 case when e.event_type = 'BILLING_ISSUE' then v_grace end,
                 coalesce(v_original, v_purchased, now()),
                 case when e.event_type = 'CANCELLATION' then now() end,
                 case when v_sub_status = 'expired' then coalesce(v_expiration, now()) end,
                 coalesce(v_cancel, false), 1,
                 coalesce(e.app_user_id, v_user::text), 'pro',
                 e.external_subscription_id, e.external_transaction_id,
                 e.event_type, v_event_ts, now())
              returning id into v_sub_id;
              v_prev_status := null;
            end if;

            -- Licence upsert (never a second active licence for the pair).
            select l.id, l.status into v_lic_id, v_lic_status
            from public.vinetrack_user_licences l
            where l.subscription_id = v_sub_id and l.user_id = v_user
            order by l.created_at desc
            limit 1;

            if v_revoke then
              if v_lic_id is not null and v_lic_status = 'active' then
                update public.vinetrack_user_licences
                set status = 'revoked', revoked_at = now(), updated_at = now()
                where id = v_lic_id;
              end if;
            else
              if v_lic_id is not null then
                if v_lic_status <> 'active' then
                  update public.vinetrack_user_licences
                  set status = 'active', revoked_at = null, assigned_at = now(), updated_at = now()
                  where id = v_lic_id;
                end if;
              else
                insert into public.vinetrack_user_licences (subscription_id, user_id, status)
                values (v_sub_id, v_user, 'active');
              end if;
            end if;

            -- Lifecycle audit on state change only (same rule as the webhook).
            if v_audit_event is not null and v_prev_status is distinct from v_sub_status then
              insert into public.vinetrack_entitlement_audit
                (user_id, event_type, previous_state, new_state, platform)
              values (v_user, v_audit_event,
                      case when v_prev_status is null then null
                           else jsonb_build_object('status', v_prev_status) end,
                      jsonb_build_object('status', v_sub_status, 'plan_code', v_plan_code,
                                         'provider', v_provider, 'platform', v_platform,
                                         'event_type', e.event_type,
                                         'provider_event_id', e.provider_event_id,
                                         'reprocessed_by', p_admin),
                      'server');
            end if;

            v_status := 'processed'; v_code := null; v_msg := null;
          end if;
        end if;
      end if;
    end if;
  end if;

  -- Finalise the SAME event row (UPDATE, never insert -> retrying twice can
  -- never create a second event or a second subscription).
  update public.billing_provider_events
  set processing_status        = v_status,
      processed_at             = now(),
      processing_error_code    = v_code,
      processing_error_message = v_msg,
      resolved_user_id         = coalesce(v_user, resolved_user_id),
      retry_count              = retry_count + 1,
      last_retry_at            = now(),
      last_retry_by            = p_admin
  where id = p_event_id;

  -- A successful reprocess clears the event's open alerts (kept historically).
  if v_status in ('processed', 'ignored') then
    update public.billing_admin_alerts
    set acknowledged_at = now(), acknowledged_by = p_admin
    where provider_event_id = e.provider_event_id
      and acknowledged_at is null;
  end if;

  return jsonb_build_object(
    'event_id', p_event_id,
    'provider_event_id', e.provider_event_id,
    'event_type', e.event_type,
    'outcome', v_status,
    'code', v_code,
    'message', v_msg,
    'subscription_id', v_sub_id,
    'resolved_user_id', v_user,
    'retried_at', now());
end;
$$;

revoke all on function public._billing_reprocess_provider_event(uuid, uuid) from public;
-- No client grant — called only by admin_update_billing_review_item.

comment on function public._billing_reprocess_provider_event(uuid, uuid) is
  'SQL 148: idempotent server-side reprocess of a stored RevenueCat event. Mirrors the revenuecat-webhook pipeline; keyed subscription upsert + row lock make concurrent/repeated retries safe. TEST/TRANSFER/SUBSCRIBER_ALIAS are rejected.';

-- ---------------------------------------------------------------------------
-- D. Unified review mutation RPC + wrappers.
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_billing_review_item(
  p_item_type      text,
  p_item_id        uuid,
  p_action         text,
  p_reason         text default null,
  p_target_user_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin     uuid := auth.uid();
  v_reason    text := btrim(coalesce(p_reason, ''));
  a           public.billing_admin_alerts%rowtype;
  e           public.billing_provider_events%rowtype;
  v_prev_user uuid;
  v_retry     jsonb;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_item_id is null then
    raise exception 'item_id_required' using errcode = '22023';
  end if;
  if p_item_type is null or p_item_type not in
     ('event', 'unresolved_user', 'ownership_conflict', 'stuck_delivery', 'alert') then
    raise exception 'invalid_item_type' using errcode = '22023';
  end if;
  if p_action is null or p_action not in
     ('acknowledge', 'resolve', 'dismiss', 'retry', 'link_user') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if length(v_reason) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  -- ---- alerts: acknowledge only -------------------------------------------
  if p_item_type = 'alert' then
    if p_action <> 'acknowledge' then
      raise exception 'invalid_action_for_item_type' using errcode = '22023';
    end if;
    select * into a from public.billing_admin_alerts where id = p_item_id for update;
    if not found then
      raise exception 'item_not_found' using errcode = 'P0002';
    end if;
    if a.acknowledged_at is null then
      update public.billing_admin_alerts
      set acknowledged_at = now(), acknowledged_by = v_admin
      where id = p_item_id;
    end if;
    insert into public.vinetrack_billing_events (owner_user_id, provider, event_type, payload)
    values (a.resolved_user_id, 'system', 'billing_review_alert_acknowledged',
            jsonb_build_object('item_type', 'alert', 'item_id', p_item_id,
                               'alert_type', a.alert_type,
                               'provider_event_id', a.provider_event_id,
                               'reason', v_reason, 'actor', v_admin, 'at', now()));
    return jsonb_build_object('item_type', 'alert', 'item_id', p_item_id,
                              'action', 'acknowledge', 'status', 'ok');
  end if;

  if p_action = 'acknowledge' then
    raise exception 'invalid_action_for_item_type' using errcode = '22023';
  end if;

  -- ---- provider-event categories --------------------------------------------
  select * into e from public.billing_provider_events where id = p_item_id for update;
  if not found then
    raise exception 'item_not_found' using errcode = 'P0002';
  end if;

  -- The item must belong to the claimed queue.
  if p_item_type = 'unresolved_user'
     and coalesce(e.processing_error_code, '') not in ('unresolved_app_user_id', 'user_not_found') then
    raise exception 'item_type_mismatch' using errcode = '22023';
  end if;
  if p_item_type = 'ownership_conflict'
     and coalesce(e.processing_error_code, '') <> 'ownership_conflict' then
    raise exception 'item_type_mismatch' using errcode = '22023';
  end if;
  if p_item_type = 'stuck_delivery' and e.processing_status <> 'received' then
    raise exception 'item_type_mismatch' using errcode = '22023';
  end if;
  if p_item_type = 'event' and e.processing_status not in ('needs_review', 'failed') then
    raise exception 'item_type_mismatch' using errcode = '22023';
  end if;

  if p_action = 'link_user' then
    if p_item_type not in ('unresolved_user', 'ownership_conflict') then
      raise exception 'invalid_action_for_item_type' using errcode = '22023';
    end if;
    if p_target_user_id is null then
      -- NEVER resolve users by email alone — an explicit confirmed
      -- auth.users.id selection is required.
      raise exception 'target_user_required' using errcode = '22023';
    end if;
    if not exists (select 1 from auth.users where id = p_target_user_id) then
      raise exception 'user_not_found' using errcode = 'P0002';
    end if;
    if e.resolved_at is not null or e.dismissed_at is not null then
      raise exception 'already_closed' using errcode = '22023';
    end if;
    v_prev_user := e.resolved_user_id;
    update public.billing_provider_events
    set resolved_user_id = p_target_user_id,
        review_item_type = coalesce(review_item_type, p_item_type)
    where id = p_item_id;
    insert into public.vinetrack_billing_events (owner_user_id, provider, event_type, payload)
    values (p_target_user_id, 'system', 'billing_review_user_linked',
            jsonb_build_object('item_type', p_item_type, 'item_id', p_item_id,
                               'provider_event_id', e.provider_event_id,
                               'previous_user_id', v_prev_user,
                               'linked_user_id', p_target_user_id,
                               'reason', v_reason, 'actor', v_admin, 'at', now()));
    return jsonb_build_object('item_type', p_item_type, 'item_id', p_item_id,
                              'action', 'link_user', 'status', 'ok',
                              'linked_user_id', p_target_user_id);
  end if;

  if p_action = 'retry' then
    if not public._billing_event_is_retryable(e) then
      raise exception 'not_retryable' using errcode = '22023';
    end if;
    v_retry := public._billing_reprocess_provider_event(p_item_id, v_admin);
    if (v_retry->>'outcome') in ('processed', 'ignored') then
      -- Mark resolved after successful retry; row leaves the active queue
      -- but remains fully queryable in history.
      update public.billing_provider_events
      set resolved_at       = now(),
          resolved_by       = v_admin,
          resolution_reason = v_reason,
          resolution_action = 'retry',
          review_item_type  = coalesce(review_item_type, p_item_type)
      where id = p_item_id and dismissed_at is null;
    else
      update public.billing_provider_events
      set review_item_type = coalesce(review_item_type, p_item_type)
      where id = p_item_id;
    end if;
    insert into public.vinetrack_billing_events (owner_user_id, provider, event_type, payload)
    values (coalesce((v_retry->>'resolved_user_id')::uuid, e.resolved_user_id),
            'system', 'billing_review_retried',
            jsonb_build_object('item_type', p_item_type, 'item_id', p_item_id,
                               'provider_event_id', e.provider_event_id,
                               'outcome', v_retry->>'outcome',
                               'code', v_retry->>'code',
                               'subscription_id', v_retry->>'subscription_id',
                               'reason', v_reason, 'actor', v_admin, 'at', now()));
    return jsonb_build_object('item_type', p_item_type, 'item_id', p_item_id,
                              'action', 'retry', 'status', 'ok', 'result', v_retry);
  end if;

  -- resolve / dismiss.
  if e.resolved_at is not null or e.dismissed_at is not null then
    raise exception 'already_closed' using errcode = '22023';
  end if;

  if p_action = 'resolve' then
    update public.billing_provider_events
    set resolved_at       = now(),
        resolved_by       = v_admin,
        resolution_reason = v_reason,
        resolution_action = 'resolve',
        review_item_type  = coalesce(review_item_type, p_item_type)
    where id = p_item_id;
  else
    update public.billing_provider_events
    set dismissed_at     = now(),
        dismissed_by     = v_admin,
        dismissal_reason = v_reason,
        review_item_type = coalesce(review_item_type, p_item_type)
    where id = p_item_id;
  end if;

  -- Clear the event's open alerts (kept historically as acknowledged).
  update public.billing_admin_alerts
  set acknowledged_at = now(), acknowledged_by = v_admin
  where provider_event_id = e.provider_event_id
    and acknowledged_at is null;

  insert into public.vinetrack_billing_events (owner_user_id, provider, event_type, payload)
  values (e.resolved_user_id, 'system',
          case when p_action = 'resolve' then 'billing_review_resolved'
               else 'billing_review_dismissed' end,
          jsonb_build_object('item_type', p_item_type, 'item_id', p_item_id,
                             'provider_event_id', e.provider_event_id,
                             'processing_status', e.processing_status,
                             'processing_error_code', e.processing_error_code,
                             'reason', v_reason, 'actor', v_admin, 'at', now()));

  return jsonb_build_object('item_type', p_item_type, 'item_id', p_item_id,
                            'action', p_action, 'status', 'ok');
end;
$$;

revoke all on function public.admin_update_billing_review_item(text, uuid, text, text, uuid) from public;
grant execute on function public.admin_update_billing_review_item(text, uuid, text, text, uuid) to authenticated;

comment on function public.admin_update_billing_review_item(text, uuid, text, text, uuid) is
  'SQL 148: unified System-Admin review mutation. Actions: acknowledge (alerts only), resolve/dismiss (mandatory reason), retry (retryable events/stuck deliveries; idempotent), link_user (unresolved-user/ownership-conflict records; explicit auth.users.id required). Every call writes an append-only vinetrack_billing_events audit row; nothing is ever deleted.';

-- Thin wrappers using the naming suggested by the review contract.
create or replace function public.admin_resolve_billing_review_item(
  p_item_type text, p_item_id uuid, p_reason text
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.admin_update_billing_review_item(p_item_type, p_item_id, 'resolve', p_reason, null);
$$;

create or replace function public.admin_dismiss_billing_review_item(
  p_item_type text, p_item_id uuid, p_reason text
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.admin_update_billing_review_item(p_item_type, p_item_id, 'dismiss', p_reason, null);
$$;

create or replace function public.admin_retry_billing_delivery(
  p_item_id uuid,
  p_reason  text default 'Retry requested'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  select bpe.processing_status into v_status
  from public.billing_provider_events bpe
  where bpe.id = p_item_id;
  if v_status is null then
    raise exception 'item_not_found' using errcode = 'P0002';
  end if;
  return public.admin_update_billing_review_item(
    case when v_status = 'received' then 'stuck_delivery' else 'event' end,
    p_item_id, 'retry', p_reason, null);
end;
$$;

revoke all on function public.admin_resolve_billing_review_item(text, uuid, text) from public;
revoke all on function public.admin_dismiss_billing_review_item(text, uuid, text) from public;
revoke all on function public.admin_retry_billing_delivery(uuid, text) from public;
grant execute on function public.admin_resolve_billing_review_item(text, uuid, text) to authenticated;
grant execute on function public.admin_dismiss_billing_review_item(text, uuid, text) to authenticated;
grant execute on function public.admin_retry_billing_delivery(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- E. Sanitised review-item detail list (paginated).
-- ---------------------------------------------------------------------------
create or replace function public.admin_billing_review_items(
  p_item_type text,
  p_status    text default 'open',
  p_limit     integer default 100,
  p_offset    integer default 0
)
returns table (
  item_id         uuid,
  item_type       text,
  severity        text,
  status          text,
  user_id         uuid,
  user_email      text,
  provider        text,
  platform        text,
  product         text,
  reason          text,
  created_at      timestamptz,
  last_attempt_at timestamptz,
  retry_count     integer,
  is_retryable    boolean,
  resolved_at     timestamptz,
  resolved_by     uuid,
  dismissed_at    timestamptz,
  dismissed_by    uuid,
  total_count     bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit  integer := greatest(1, least(coalesce(p_limit, 100), 500));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_item_type is null or p_item_type not in
     ('event', 'unresolved_user', 'ownership_conflict', 'stuck_delivery', 'alert') then
    raise exception 'invalid_item_type' using errcode = '22023';
  end if;
  if coalesce(p_status, 'open') not in ('open', 'resolved', 'dismissed', 'all') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  if p_item_type = 'alert' then
    return query
    select al.id,
           'alert'::text,
           al.severity,
           case when al.acknowledged_at is null then 'open' else 'resolved' end,
           al.resolved_user_id,
           u.email::text,
           al.provider,
           null::text,
           al.product_id,
           (al.alert_type || coalesce(': ' || al.detail, ''))::text,
           al.created_at,
           null::timestamptz,
           0,
           false,
           al.acknowledged_at,
           al.acknowledged_by,
           null::timestamptz,
           null::uuid,
           count(*) over ()
    from public.billing_admin_alerts al
    left join auth.users u on u.id = al.resolved_user_id
    where (coalesce(p_status, 'open') = 'all')
       or (coalesce(p_status, 'open') = 'open'     and al.acknowledged_at is null)
       or (coalesce(p_status, 'open') = 'resolved' and al.acknowledged_at is not null)
    order by al.created_at desc
    limit v_limit offset v_offset;
    return;
  end if;

  return query
  select ev.id,
         p_item_type,
         case when ev.processing_status = 'failed'
                or ev.processing_error_code = 'ownership_conflict' then 'critical'
              else 'warning' end,
         case when ev.dismissed_at is not null then 'dismissed'
              when ev.resolved_at  is not null then 'resolved'
              else 'open' end,
         ev.resolved_user_id,
         u.email::text,
         ev.provider,
         ev.platform,
         ev.product_id,
         (coalesce(ev.processing_error_code, ev.processing_status)
            || coalesce(': ' || left(ev.processing_error_message, 200), ''))::text,
         ev.received_at,
         coalesce(ev.last_retry_at, ev.processed_at),
         ev.retry_count,
         public._billing_event_is_retryable(ev),
         ev.resolved_at,
         ev.resolved_by,
         ev.dismissed_at,
         ev.dismissed_by,
         count(*) over ()
  from public.billing_provider_events ev
  left join auth.users u on u.id = ev.resolved_user_id
  where
    -- Open items match the LIVE queue definition; closed items match the
    -- queue snapshot stamped at action time (codes/statuses change on retry).
    case coalesce(p_status, 'open')
      when 'open' then
        ev.resolved_at is null and ev.dismissed_at is null
        and case p_item_type
              when 'unresolved_user'    then coalesce(ev.processing_error_code, '') in ('unresolved_app_user_id', 'user_not_found')
              when 'ownership_conflict' then coalesce(ev.processing_error_code, '') = 'ownership_conflict'
              when 'stuck_delivery'     then ev.processing_status = 'received'
              else ev.processing_status in ('needs_review', 'failed')
            end
      when 'resolved' then
        ev.resolved_at is not null and coalesce(ev.review_item_type, 'event') = p_item_type
      when 'dismissed' then
        ev.dismissed_at is not null and coalesce(ev.review_item_type, 'event') = p_item_type
      else
        (ev.resolved_at is not null or ev.dismissed_at is not null
         or ev.processing_status in ('needs_review', 'failed', 'received'))
        and (coalesce(ev.review_item_type,
              case
                when coalesce(ev.processing_error_code, '') in ('unresolved_app_user_id', 'user_not_found') then 'unresolved_user'
                when coalesce(ev.processing_error_code, '') = 'ownership_conflict' then 'ownership_conflict'
                when ev.processing_status = 'received' then 'stuck_delivery'
                else 'event'
              end) = p_item_type)
    end
  order by ev.received_at desc
  limit v_limit offset v_offset;
end;
$$;

revoke all on function public.admin_billing_review_items(text, text, integer, integer) from public;
grant execute on function public.admin_billing_review_items(text, text, integer, integer) to authenticated;

comment on function public.admin_billing_review_items(text, text, integer, integer) is
  'SQL 148: System-Admin paginated review-item list per category (event | unresolved_user | ownership_conflict | stuck_delivery | alert) and status (open | resolved | dismissed | all). Sanitised fields only — never raw receipts, purchase tokens, webhook signatures or full provider payloads.';

-- ---------------------------------------------------------------------------
-- F. Monitor v2 — active counts exclude resolved/dismissed items.
-- ---------------------------------------------------------------------------
create or replace function public.admin_store_billing_monitor()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'generated_at', now(),

    'events_needing_review', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_status = 'needs_review'
                  and resolved_at is null and dismissed_at is null),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', r.id,
          'event_type', r.event_type, 'code', r.processing_error_code,
          'product_id', r.product_id, 'platform', r.platform,
          'environment', r.environment, 'received_at', r.received_at,
          'resolved_user_id', r.resolved_user_id,
          'retry_count', r.retry_count,
          'app_user_ref', case when r.app_user_id is null then null
                               else left(r.app_user_id, 8) || '…' end
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_status = 'needs_review'
                and resolved_at is null and dismissed_at is null
              order by received_at desc limit 20) r), '[]'::jsonb)
    ),

    'failed_events', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_status = 'failed'
                  and resolved_at is null and dismissed_at is null),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', r.id,
          'event_type', r.event_type, 'code', r.processing_error_code,
          'message', left(coalesce(r.processing_error_message, ''), 200),
          'received_at', r.received_at, 'resolved_user_id', r.resolved_user_id,
          'retry_count', r.retry_count
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_status = 'failed'
                and resolved_at is null and dismissed_at is null
              order by received_at desc limit 20) r), '[]'::jsonb)
    ),

    'unknown_products', coalesce((
      select jsonb_agg(distinct e.product_id)
      from public.billing_provider_events e
      where e.processing_error_code in ('unknown_product', 'inactive_product')
        and e.resolved_at is null and e.dismissed_at is null
        and e.product_id is not null), '[]'::jsonb),

    'unresolved_users', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_error_code in ('unresolved_app_user_id', 'user_not_found')
                  and resolved_at is null and dismissed_at is null),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', r.id,
          'event_type', r.event_type, 'code', r.processing_error_code,
          'app_user_ref', case when r.app_user_id is null then null
                               else left(r.app_user_id, 8) || '…' end,
          'received_at', r.received_at
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_error_code in ('unresolved_app_user_id', 'user_not_found')
                and resolved_at is null and dismissed_at is null
              order by received_at desc limit 10) r), '[]'::jsonb)
    ),

    'ownership_conflicts', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_error_code = 'ownership_conflict'
                  and resolved_at is null and dismissed_at is null),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', r.id,
          'event_type', r.event_type, 'resolved_user_id', r.resolved_user_id,
          'product_id', r.product_id, 'received_at', r.received_at
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_error_code = 'ownership_conflict'
                and resolved_at is null and dismissed_at is null
              order by received_at desc limit 10) r), '[]'::jsonb)
    ),

    -- RevenueCat granted access (processed grant event) but the user has no
    -- live Supabase subscription 15+ minutes later. Cleared by acknowledging
    -- the matching sync_window_exceeded alert (or resolving the event).
    'rc_active_supabase_missing', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', m.event_type, 'resolved_user_id', m.resolved_user_id,
        'product_id', m.product_id, 'processed_at', m.processed_at
      ) order by m.processed_at desc)
      from (
        select e.event_type, e.resolved_user_id, e.product_id, e.processed_at
        from public.billing_provider_events e
        where e.provider = 'revenuecat'
          and e.processing_status = 'processed'
          and e.event_type in ('INITIAL_PURCHASE','RENEWAL','UNCANCELLATION',
                               'PRODUCT_CHANGE','SUBSCRIPTION_EXTENDED')
          and upper(coalesce(e.environment, '')) = 'PRODUCTION'
          and e.received_at > now() - interval '7 days'
          and e.processed_at < now() - interval '15 minutes'
          and e.resolved_user_id is not null
          and e.resolved_at is null and e.dismissed_at is null
          and not exists (
            select 1 from public.vinetrack_subscriptions s
            where s.owner_user_id = e.resolved_user_id
              and s.billing_provider in ('apple', 'google')
              and s.deleted_at is null
              and s.status in ('trialing', 'active', 'past_due')
          )
          and not exists (
            select 1 from public.billing_admin_alerts al
            where al.provider_event_id = e.provider_event_id
              and al.alert_type = 'sync_window_exceeded'
              and al.acknowledged_at is not null
          )
        order by e.processed_at desc limit 20
      ) m), '[]'::jsonb),

    -- Deliveries stuck before finalisation (webhook crashed mid-flight).
    'stuck_deliveries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'event_type', r.event_type, 'received_at', r.received_at,
        'retry_count', r.retry_count
      ) order by r.received_at desc)
      from (select * from public.billing_provider_events
            where processing_status = 'received'
              and received_at < now() - interval '15 minutes'
              and resolved_at is null and dismissed_at is null
            order by received_at desc limit 20) r), '[]'::jsonb),

    'expiring_within_7_days', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', s.owner_user_id, 'plan_code', p.code,
        'provider', s.billing_provider, 'status', s.status,
        'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end
      ) order by s.current_period_end)
      from public.vinetrack_subscriptions s
      join public.vinetrack_plans p on p.id = s.plan_id
      where s.deleted_at is null
        and s.billing_provider in ('apple', 'google')
        and s.status in ('active', 'past_due', 'trialing')
        and s.current_period_end between now() and now() + interval '7 days'),
      '[]'::jsonb),

    'recent_status_changes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', r.user_id, 'event_type', r.event_type,
        'new_status', r.new_state->>'status', 'plan_code', r.new_state->>'plan_code',
        'created_at', r.created_at
      ) order by r.created_at desc)
      from (select * from public.vinetrack_entitlement_audit
            where event_type like 'store\_%' escape '\'
            order by created_at desc limit 20) r), '[]'::jsonb),

    'recent_review_actions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', r.event_type,
        'item_type', r.payload->>'item_type',
        'item_id', r.payload->>'item_id',
        'reason', r.payload->>'reason',
        'outcome', r.payload->>'outcome',
        'actor', r.payload->>'actor',
        'created_at', r.created_at
      ) order by r.created_at desc)
      from (select * from public.vinetrack_billing_events
            where event_type like 'billing\_review\_%' escape '\'
            order by created_at desc limit 10) r), '[]'::jsonb),

    'open_alerts', (select count(*) from public.billing_admin_alerts
                    where acknowledged_at is null)
  ) into v;

  return v;
end;
$$;

revoke all on function public.admin_store_billing_monitor() from public;
grant execute on function public.admin_store_billing_monitor() to authenticated;

comment on function public.admin_store_billing_monitor() is
  'SQL 148 v2: System-Admin-only one-call store-billing health report (JSON). Active counts exclude resolved/dismissed review items; resolved/dismissed rows remain queryable via admin_billing_review_items. Adds recent_review_actions. App user ids truncated; no receipts, tokens or payloads.';

-- ---------------------------------------------------------------------------
-- G. Alert listing v2 — lazy checks skip resolved/dismissed events.
-- ---------------------------------------------------------------------------
create or replace function public.admin_billing_alerts(
  p_include_acknowledged boolean default false,
  p_limit integer default 100
)
returns setof public.billing_admin_alerts
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  -- Lazy check 1: RevenueCat granted, Supabase not synchronised in window.
  insert into public.billing_admin_alerts
    (alert_type, severity, provider, provider_event_id, event_type, product_id, resolved_user_id, detail)
  select 'sync_window_exceeded', 'critical', e.provider, e.provider_event_id,
         e.event_type, e.product_id, e.resolved_user_id,
         'Provider granted access but no active Supabase subscription 15+ minutes after processing'
  from public.billing_provider_events e
  where e.provider = 'revenuecat'
    and e.processing_status = 'processed'
    and e.event_type in ('INITIAL_PURCHASE','RENEWAL','UNCANCELLATION',
                         'PRODUCT_CHANGE','SUBSCRIPTION_EXTENDED')
    and upper(coalesce(e.environment, '')) = 'PRODUCTION'
    and e.received_at > now() - interval '7 days'
    and e.processed_at < now() - interval '15 minutes'
    and e.resolved_user_id is not null
    and e.resolved_at is null and e.dismissed_at is null
    and not exists (
      select 1 from public.vinetrack_subscriptions s
      where s.owner_user_id = e.resolved_user_id
        and s.billing_provider in ('apple', 'google')
        and s.deleted_at is null
        and s.status in ('trialing', 'active', 'past_due')
    )
  on conflict (alert_type, provider_event_id) where provider_event_id is not null
  do nothing;

  -- Lazy check 2: deliveries stuck before finalisation.
  insert into public.billing_admin_alerts
    (alert_type, severity, provider, provider_event_id, event_type, product_id, resolved_user_id, detail)
  select 'sync_window_exceeded', 'warning', e.provider, e.provider_event_id,
         e.event_type, e.product_id, e.resolved_user_id,
         'Delivery stuck in status received for 15+ minutes (webhook did not finalise)'
  from public.billing_provider_events e
  where e.processing_status = 'received'
    and e.received_at < now() - interval '15 minutes'
    and e.resolved_at is null and e.dismissed_at is null
  on conflict (alert_type, provider_event_id) where provider_event_id is not null
  do nothing;

  return query
  select *
  from public.billing_admin_alerts a
  where p_include_acknowledged or a.acknowledged_at is null
  order by a.created_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

revoke all on function public.admin_billing_alerts(boolean, integer) from public;
grant execute on function public.admin_billing_alerts(boolean, integer) to authenticated;

commit;

-- =====================================================================
-- VERIFICATION (run after commit):
--   select public.admin_store_billing_monitor();                -- counts now review-aware
--   select * from public.admin_billing_review_items('event');   -- open needs-review/failed
--   select * from public.admin_billing_review_items('stuck_delivery');
--   select * from public.admin_billing_review_items('alert', 'all');
--   -- Mutations (System Admin, non-empty reason required):
--   -- select public.admin_resolve_billing_review_item('event', '<id>', 'Fixed catalogue mapping');
--   -- select public.admin_dismiss_billing_review_item('event', '<id>', 'Synthetic sandbox test event');
--   -- select public.admin_retry_billing_delivery('<id>', 'Catalogue corrected — reprocess');
--   -- select public.admin_update_billing_review_item('unresolved_user', '<id>', 'link_user', 'Confirmed account', '<auth user uuid>');
-- Then run sql/tests/148_billing_review_resolution_tests.sql (rolls back).
-- =====================================================================
