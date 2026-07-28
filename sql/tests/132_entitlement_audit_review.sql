-- ============================================================================
-- Phase 2A §12 — Entitlement audit-event review
-- ============================================================================
-- READ-ONLY. Run in the Supabase SQL editor after the mobile acceptance tests.
-- Returns ONE JSON object summarising vinetrack_entitlement_state and
-- vinetrack_entitlement_audit:
--   * total rows and per-event-type counts for the last 7 days
--   * the most recent 20 audit events (user, event, source, plan, reason,
--     platform, app version, timestamps) — no receipts/tokens are stored in
--     these tables by design, so nothing sensitive can appear
--   * duplicate-volume check: users with more than 10 events in 24 h
--     (repeated unchanged resolver calls should NOT create rows)
-- ============================================================================

with recent as (
  select *
  from public.vinetrack_entitlement_audit
  where created_at > now() - interval '7 days'
),
event_counts as (
  select event_type, count(*) as n
  from recent
  group by event_type
),
latest_events as (
  -- access_source / plan_code / reason_code are NOT columns on the audit
  -- table — they live inside the new_state / previous_state JSONB blobs
  -- (see sql/132 section C). Extract them for readability.
  select
    a.created_at,
    a.user_id,
    a.event_type,
    a.new_state ->> 'access_source' as access_source,
    a.new_state ->> 'plan_code'     as plan_code,
    a.new_state ->> 'reason_code'   as reason_code,
    a.platform,
    a.app_version,
    a.previous_state,
    a.new_state
  from recent a
  order by a.created_at desc
  limit 20
),
noisy_users as (
  select user_id, count(*) as events_24h
  from public.vinetrack_entitlement_audit
  where created_at > now() - interval '24 hours'
  group by user_id
  having count(*) > 10
),
state_rows as (
  select count(*) as n from public.vinetrack_entitlement_state
)
select jsonb_pretty(jsonb_build_object(
  'state_row_count',        (select n from state_rows),
  'audit_events_last_7d',   (select count(*) from recent),
  'events_by_type',         coalesce((
                              select jsonb_object_agg(event_type, n)
                              from event_counts
                            ), '{}'::jsonb),
  'latest_20_events',       coalesce((
                              select jsonb_agg(to_jsonb(e) order by e.created_at desc)
                              from latest_events e
                            ), '[]'::jsonb),
  'excessive_volume_users', coalesce((
                              select jsonb_agg(to_jsonb(u))
                              from noisy_users u
                            ), '[]'::jsonb),
  'note', 'Expected event types: entitlement_granted, entitlement_denied, '
          || 'entitlement_source_changed, entitlement_expired, entitlement_revoked, '
          || 'entitlement_mismatch_detected. excessive_volume_users should be empty — '
          || 'unchanged resolver calls must not append audit rows.'
)) as entitlement_audit_review;
