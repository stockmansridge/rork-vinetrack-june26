-- 042_pins_attachment_preview.sql
--
-- READ-ONLY PREVIEW. Does not modify any rows.
--
-- Goal: classify legacy pins for a possible conservative backfill of:
--   * pins.driving_row_number   (numeric)  e.g. 14.5
--   * pins.pin_row_number       (numeric)  e.g. 14 or 15
--   * pins.pin_side             (text)     'Left' | 'Right'
--   * pins.snapped_latitude     (double)
--   * pins.snapped_longitude    (double)
--   * pins.along_row_distance_m (numeric)
--   * pins.snapped_to_row       (boolean)
--
-- The legacy `pins.row_number` integer is the driving path floor (X for
-- path X.5). The actual attached vine row depends on the operator's
-- direction of travel + side, which require row geometry that lives in
-- the iOS client (paddocks.rows). This SQL preview cannot resolve the
-- attached vine row by itself; it scopes the rows that need geometry-
-- aware processing and labels each candidate's confidence bucket.
--
-- Use this query to see overall counts. Use scripts/preview_pin_attachment.ts
-- (Bun + service role) for the per-pin proposed values once geometry is
-- loaded.

-- =====================================================================
-- 1. High-level counts (overall)
-- =====================================================================
select
  'overall' as scope,
  count(*) as total_pins,
  count(*) filter (where deleted_at is null)                                as live_pins,
  count(*) filter (where deleted_at is null and row_number is not null)    as has_legacy_row,
  count(*) filter (where deleted_at is null and side is not null)          as has_legacy_side,
  count(*) filter (where deleted_at is null and pin_row_number is null
                    and row_number is not null and paddock_id is not null) as backfill_candidates,
  count(*) filter (where deleted_at is null and pin_row_number is null
                    and (row_number is null or paddock_id is null))        as manual_review_required
from public.pins;

-- =====================================================================
-- 2. Per-vineyard breakdown
-- =====================================================================
select
  v.id   as vineyard_id,
  v.name as vineyard_name,
  count(*)                                                                          as total_pins,
  count(*) filter (where p.deleted_at is null and p.pin_row_number is null
                    and p.row_number is not null and p.paddock_id is not null)      as backfill_candidates,
  count(*) filter (where p.deleted_at is null and p.pin_row_number is null
                    and (p.row_number is null or p.paddock_id is null))             as manual_review_required,
  count(*) filter (where p.deleted_at is null and p.snapped_to_row = true)          as already_snapped
from public.vineyards v
join public.pins p on p.vineyard_id = v.id
group by v.id, v.name
order by v.name;

-- =====================================================================
-- 3. Sample candidate rows (for manual sanity-check before running the
-- TypeScript preview script). Nothing destructive.
-- =====================================================================
select
  p.id,
  p.vineyard_id,
  p.paddock_id,
  p.button_name,
  p.mode,
  p.is_completed,
  p.row_number                       as legacy_row_number,        -- driving path floor
  (p.row_number::numeric + 0.5)      as proposed_driving_row_number,
  p.side                             as legacy_side,
  p.heading,
  p.latitude,
  p.longitude,
  case
    when p.row_number is null            then 'manual_review_no_row'
    when p.paddock_id is null            then 'manual_review_no_paddock'
    when p.heading is null               then 'medium_no_heading'
    when p.side is null                  then 'medium_no_side'
    else 'high_geometry_required'
  end as confidence_bucket,
  case
    when p.heading is null then
      'No heading recorded \u2014 cannot infer left/right vs lower/higher row.'
    when p.side is null then
      'No side recorded \u2014 cannot infer attached vine row.'
    else
      'High confidence pending paddock-row geometry resolution.'
  end as reason
from public.pins p
where p.deleted_at is null
  and p.pin_row_number is null
order by p.updated_at desc
limit 100;
