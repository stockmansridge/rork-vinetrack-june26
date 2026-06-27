-- 036_pins_backfill_audit_dryrun.sql
--
-- READ-ONLY AUDIT. Does not modify any rows.
--
-- Goal: classify legacy pins for a possible conservative backfill of:
--   * pins.created_by             (uuid, references auth.users)
--   * pins.completed_by_user_id   (uuid, references auth.users; added in 035)
--
-- The audit is per-vineyard scoped. Resolution of a display-name string to
-- a single user uses the same priority chain as get_vineyard_team_members:
--   1. vineyard_members.display_name
--   2. profiles.full_name
--   3. profiles.email
--   4. auth.users.email
-- A match is only considered "safe" when it resolves to EXACTLY ONE user
-- inside that pin's vineyard. Any ambiguity -> manual review.
--
-- updated_by is NEVER used as a created_by source unless the pin has clearly
-- never been completed or edited by anyone else (single-toucher heuristic).
-- Even then it is reported in its own bucket so a human can confirm before
-- any UPDATE is run.
--
-- Run this in Supabase SQL editor. Each block ends with a SELECT that
-- returns counts. Nothing is written.

-- -----------------------------------------------------------------------
-- 0. Resolution helpers (CTE-only; not persisted)
-- -----------------------------------------------------------------------
-- Build a per-vineyard candidate name map: every member with every
-- non-empty resolvable display token (lower-cased, trimmed).
with member_names as (
  select
    vm.vineyard_id,
    vm.user_id,
    lower(btrim(name)) as name_norm
  from public.vineyard_members vm
  left join public.profiles p on p.id = vm.user_id
  left join auth.users au on au.id = vm.user_id
  cross join lateral (values
    (vm.display_name),
    (p.full_name),
    (p.email),
    (au.email)
  ) as v(name)
  where name is not null and btrim(name) <> ''
),
-- For each (vineyard, normalized name) decide whether it resolves to
-- exactly one user. Anything that maps to >1 user is ambiguous.
name_resolution as (
  select
    vineyard_id,
    name_norm,
    count(distinct user_id) as match_count,
    (array_agg(user_id order by user_id::text))[1] as resolved_user_id
  from member_names
  group by vineyard_id, name_norm
),
-- Per-pin "single-toucher" check. The pin's updated_by may be reused
-- as a tentative creator only when:
--   * created_by is null
--   * pin is NOT completed
--   * completed_by / completed_by_user_id / completed_at all null
--   * updated_by is not null
-- This is reported separately and is NOT auto-applied.
pin_audit as (
  select
    p.id,
    p.vineyard_id,
    p.created_by,
    p.updated_by,
    p.is_completed,
    p.completed_by,
    p.completed_by_user_id,
    p.completed_at,
    -- Resolve created_by from completed_by text? No — that's the completer.
    -- We do not currently store a creator display string, so the only
    -- safe automatic source is updated_by under the single-toucher rule.
    case
      when p.created_by is not null then 'has_value'
      when p.updated_by is not null
           and coalesce(p.is_completed, false) = false
           and p.completed_by is null
           and p.completed_by_user_id is null
           and p.completed_at is null
        then 'safe_updated_by_single_toucher'
      else 'manual_review'
    end as created_by_class,
    -- Completed_by_user_id resolution from completed_by text
    case
      when p.completed_by_user_id is not null then 'has_value'
      when coalesce(p.is_completed, false) = false
           and p.completed_at is null
           and p.completed_by is null
        then 'not_completed'
      when p.completed_by is null or btrim(p.completed_by) = ''
        then 'manual_review_no_text'
      else null  -- decided in join below
    end as completed_by_class_pre,
    lower(btrim(p.completed_by)) as completed_by_norm
  from public.pins p
  where p.deleted_at is null
),
pin_classified as (
  select
    pa.*,
    case
      when pa.completed_by_class_pre is not null then pa.completed_by_class_pre
      when nr.match_count = 1 then 'safe_text_unique_match'
      when nr.match_count is null then 'manual_review_no_match'
      else 'manual_review_ambiguous'
    end as completed_by_class,
    nr.resolved_user_id as completed_by_resolved_user_id
  from pin_audit pa
  left join name_resolution nr
    on nr.vineyard_id = pa.vineyard_id
   and nr.name_norm   = pa.completed_by_norm
)
-- -----------------------------------------------------------------------
-- 1. High-level counts (overall)
-- -----------------------------------------------------------------------
select
  'overall' as scope,
  count(*)                                                       as total_pins,
  count(*) filter (where created_by is null)                     as missing_created_by,
  count(*) filter (where is_completed and completed_by_user_id is null) as missing_completed_by_user_id,
  count(*) filter (where created_by_class = 'safe_updated_by_single_toucher') as safe_created_by_updated_by,
  count(*) filter (where completed_by_class = 'safe_text_unique_match')        as safe_completed_by_unique_text,
  count(*) filter (where created_by is null and created_by_class = 'manual_review') as unsafe_created_by,
  count(*) filter (where is_completed
                    and completed_by_user_id is null
                    and completed_by_class in ('manual_review_ambiguous','manual_review_no_match','manual_review_no_text')) as unsafe_completed_by
from pin_classified;

-- -----------------------------------------------------------------------
-- 2. Same counts grouped per vineyard (so you can decide vineyard-by-vineyard)
-- -----------------------------------------------------------------------
-- Re-run the same CTEs grouped:
with member_names as (
  select vm.vineyard_id, vm.user_id, lower(btrim(name)) as name_norm
  from public.vineyard_members vm
  left join public.profiles p on p.id = vm.user_id
  left join auth.users au on au.id = vm.user_id
  cross join lateral (values (vm.display_name),(p.full_name),(p.email),(au.email)) as v(name)
  where name is not null and btrim(name) <> ''
),
name_resolution as (
  select vineyard_id, name_norm,
         count(distinct user_id) as match_count,
         (array_agg(user_id order by user_id::text))[1] as resolved_user_id
  from member_names
  group by vineyard_id, name_norm
),
pin_classified as (
  select
    p.id, p.vineyard_id, p.created_by, p.updated_by,
    p.is_completed, p.completed_by, p.completed_by_user_id, p.completed_at,
    case
      when p.created_by is not null then 'has_value'
      when p.updated_by is not null
           and coalesce(p.is_completed, false) = false
           and p.completed_by is null
           and p.completed_by_user_id is null
           and p.completed_at is null
        then 'safe_updated_by_single_toucher'
      else 'manual_review'
    end as created_by_class,
    case
      when p.completed_by_user_id is not null then 'has_value'
      when coalesce(p.is_completed, false) = false
           and p.completed_at is null
           and p.completed_by is null
        then 'not_completed'
      when p.completed_by is null or btrim(p.completed_by) = ''
        then 'manual_review_no_text'
      when nr.match_count = 1 then 'safe_text_unique_match'
      when nr.match_count is null then 'manual_review_no_match'
      else 'manual_review_ambiguous'
    end as completed_by_class
  from public.pins p
  left join name_resolution nr
    on nr.vineyard_id = p.vineyard_id
   and nr.name_norm   = lower(btrim(p.completed_by))
  where p.deleted_at is null
)
select
  v.id   as vineyard_id,
  v.name as vineyard_name,
  count(*)                                                       as total_pins,
  count(*) filter (where pc.created_by is null)                  as missing_created_by,
  count(*) filter (where pc.is_completed and pc.completed_by_user_id is null) as missing_completed_by_user_id,
  count(*) filter (where pc.created_by_class = 'safe_updated_by_single_toucher') as safe_created_by_updated_by,
  count(*) filter (where pc.completed_by_class = 'safe_text_unique_match')        as safe_completed_by_unique_text,
  count(*) filter (where pc.created_by is null and pc.created_by_class = 'manual_review') as unsafe_created_by,
  count(*) filter (where pc.is_completed
                    and pc.completed_by_user_id is null
                    and pc.completed_by_class in ('manual_review_ambiguous','manual_review_no_match','manual_review_no_text')) as unsafe_completed_by
from public.vineyards v
join pin_classified pc on pc.vineyard_id = v.id
group by v.id, v.name
order by v.name;

-- -----------------------------------------------------------------------
-- 3. Sample rows for the unsafe / ambiguous buckets
-- (limit so it's reviewable; nothing destructive)
-- -----------------------------------------------------------------------
with member_names as (
  select vm.vineyard_id, vm.user_id, lower(btrim(name)) as name_norm
  from public.vineyard_members vm
  left join public.profiles p on p.id = vm.user_id
  left join auth.users au on au.id = vm.user_id
  cross join lateral (values (vm.display_name),(p.full_name),(p.email),(au.email)) as v(name)
  where name is not null and btrim(name) <> ''
),
name_resolution as (
  select vineyard_id, name_norm,
         count(distinct user_id) as match_count,
         (array_agg(user_id order by user_id::text))[1] as resolved_user_id
  from member_names
  group by vineyard_id, name_norm
)
select
  p.id,
  p.vineyard_id,
  p.title,
  p.is_completed,
  p.completed_by                       as completed_by_text,
  p.completed_by_user_id,
  p.created_by,
  p.updated_by,
  nr.match_count                       as completed_by_match_count,
  nr.resolved_user_id                  as completed_by_resolved_user_id,
  case
    when p.completed_by is null or btrim(p.completed_by) = '' then 'no_text'
    when nr.match_count = 1 then 'unique_match'
    when nr.match_count is null then 'no_match'
    else 'ambiguous'
  end as completed_by_class
from public.pins p
left join name_resolution nr
  on nr.vineyard_id = p.vineyard_id
 and nr.name_norm   = lower(btrim(p.completed_by))
where p.deleted_at is null
  and p.is_completed = true
  and p.completed_by_user_id is null
order by p.updated_at desc
limit 100;
