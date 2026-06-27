-- ---------------------------------------------------------------------------
-- 044 — Conservative backfill of pin attachment fields (HIGH confidence only).
--
-- Purpose
--   Backfills the new attachment columns on public.pins using the resolved
--   geometry preview in public.v_pin_attachment_preview.
--
--   Only rows where the preview reports confidence = 'high' are touched.
--   Medium and low confidence rows are intentionally left for manual review.
--
-- Safety guarantees
--   * Only updates pins where snapped_to_row IS false OR NULL.
--   * Only updates pins where pin_row_number IS NULL.
--   * Only sources rows from v_pin_attachment_preview where confidence = 'high'.
--   * Does NOT modify legacy row_number or side.
--   * Does NOT modify completion / status / audit fields.
--   * Does NOT modify trips, live trip data, row guidance, spray jobs,
--     or any other table — only public.pins.
--   * Wrapped in a single transaction so it can be rolled back if the
--     affected count looks wrong.
--
-- Recommended workflow
--   1. Run the SELECT preview count below first and confirm the number.
--   2. Then run the UPDATE block (also below) inside the same session if
--      desired, or copy it into a separate execution.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- STEP 1 — Preview count (READ ONLY).
--
-- Shows exactly how many pin rows the UPDATE will affect, using the same
-- filter the UPDATE uses. Run this first.
-- ---------------------------------------------------------------------------
select count(*) as rows_to_update
from public.pins p
join public.v_pin_attachment_preview v on v.pin_id = p.id
where v.confidence = 'high'
  and (p.snapped_to_row is null or p.snapped_to_row = false)
  and p.pin_row_number is null
  and p.deleted_at is null;

-- Optional breakdown by paddock for spot-checking before the UPDATE.
select
  p.paddock_id,
  count(*) as rows_to_update
from public.pins p
join public.v_pin_attachment_preview v on v.pin_id = p.id
where v.confidence = 'high'
  and (p.snapped_to_row is null or p.snapped_to_row = false)
  and p.pin_row_number is null
  and p.deleted_at is null
group by p.paddock_id
order by rows_to_update desc;


-- ---------------------------------------------------------------------------
-- STEP 2 — Conservative UPDATE (HIGH confidence only).
--
-- Run this only after the count above looks correct.
-- ---------------------------------------------------------------------------
begin;

with candidates as (
  select
    v.pin_id,
    v.proposed_driving_row_number,
    v.proposed_pin_row_number,
    v.proposed_pin_side,
    v.proposed_along_row_distance_m,
    v.proposed_snapped_latitude,
    v.proposed_snapped_longitude
  from public.v_pin_attachment_preview v
  where v.confidence = 'high'
)
update public.pins p
set
  driving_row_number    = c.proposed_driving_row_number,
  pin_row_number        = c.proposed_pin_row_number,
  pin_side              = c.proposed_pin_side,
  along_row_distance_m  = c.proposed_along_row_distance_m,
  snapped_latitude      = c.proposed_snapped_latitude,
  snapped_longitude     = c.proposed_snapped_longitude,
  snapped_to_row        = true
from candidates c
where p.id = c.pin_id
  and (p.snapped_to_row is null or p.snapped_to_row = false)
  and p.pin_row_number is null
  and p.deleted_at is null;

-- Verify the affected count before committing. Compare with STEP 1.
-- If the number does not match expectations, run: rollback;
-- Otherwise:
commit;


-- ---------------------------------------------------------------------------
-- STEP 3 — Post-update verification (READ ONLY).
--
-- Sanity checks after committing.
-- ---------------------------------------------------------------------------

-- How many pins are now snapped.
select
  count(*) filter (where snapped_to_row = true)            as snapped_pins,
  count(*) filter (where snapped_to_row is not true)       as unsnapped_pins,
  count(*) filter (where pin_row_number is not null)       as with_pin_row_number,
  count(*) filter (where driving_row_number is not null)   as with_driving_row_number
from public.pins
where deleted_at is null;

-- Any 'high' confidence rows still un-backfilled (should be 0 unless they
-- were excluded by the snapped_to_row / pin_row_number guards).
select count(*) as remaining_high_confidence_unbackfilled
from public.v_pin_attachment_preview v
join public.pins p on p.id = v.pin_id
where v.confidence = 'high'
  and (p.snapped_to_row is null or p.snapped_to_row = false)
  and p.pin_row_number is null
  and p.deleted_at is null;
