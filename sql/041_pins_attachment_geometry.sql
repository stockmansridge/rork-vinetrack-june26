-- 041_pins_attachment_geometry.sql
-- Phase: pin row-attachment geometry (additive, non-breaking).
--
-- Background:
--   * Existing public.pins.row_number stores the integer X for the driving
--     path/mid-row, and is currently displayed as "Row X.5" in the iOS UI.
--     The actual vine row beside the tractor (the row the issue is on) is
--     not stored explicitly today.
--   * To enable accurate attached-row display, along-row duplicate checks
--     and a clean Lovable display, we add explicit attachment fields.
--
-- Approach:
--   * Additive only. New columns are nullable and have no defaults (apart
--     from snapped_to_row which defaults to false to mirror existing rows).
--   * Existing pins.row_number / pins.side remain in place for backward
--     compatibility. Older clients keep working unchanged.
--   * No RLS changes (existing pins policies already cover these columns).
--   * No backfill in this migration. A separate preview SELECT is provided
--     in sql/042_pins_attachment_preview.sql; the conservative UPDATE for
--     high-confidence rows is held until the preview has been reviewed.

-- =====================================================================
-- Columns
-- =====================================================================
alter table public.pins
  add column if not exists driving_row_number numeric null;

alter table public.pins
  add column if not exists pin_row_number numeric null;

alter table public.pins
  add column if not exists pin_side text null;

alter table public.pins
  add column if not exists along_row_distance_m numeric null;

alter table public.pins
  add column if not exists snapped_latitude double precision null;

alter table public.pins
  add column if not exists snapped_longitude double precision null;

alter table public.pins
  add column if not exists snapped_to_row boolean not null default false;

-- =====================================================================
-- Comments
-- =====================================================================
comment on column public.pins.driving_row_number is
  'Driving path / mid-row the tractor was on when the pin was dropped, '
  'e.g. 14.5 for the path between vine rows 14 and 15. Independent from '
  'pin_row_number which is the actual attached vine row.';

comment on column public.pins.pin_row_number is
  'Actual vine row the pin/issue is attached to, e.g. 14 or 15. '
  'Resolved from driving path + heading + side. Numeric to allow fractional '
  'values on irregular blocks if ever needed.';

comment on column public.pins.pin_side is
  'Side of the operator the pin was attached to, from the operator''s '
  'direction of travel. Values: ''Left'' / ''Right''. Used together with '
  'pin_row_number for customer-facing display and duplicate detection.';

comment on column public.pins.along_row_distance_m is
  'Distance along pin_row_number (metres) from the row''s start point to '
  'the snapped pin location. Used for along-row duplicate detection so '
  'two pins on the same row line are matched even if their raw GPS '
  'samples differ by 1-2 m.';

comment on column public.pins.snapped_latitude is
  'Latitude of the pin after snapping to the driving path / row line. '
  'Falls back to latitude when snapped_to_row is false.';

comment on column public.pins.snapped_longitude is
  'Longitude of the pin after snapping to the driving path / row line. '
  'Falls back to longitude when snapped_to_row is false.';

comment on column public.pins.snapped_to_row is
  'True when the iOS client had a confident row lock and successfully '
  'snapped the pin to the row geometry. Only confident snaps populate '
  'pin_row_number, pin_side and along_row_distance_m for duplicate use.';

-- =====================================================================
-- Index
-- =====================================================================
-- Supports along-row duplicate lookups: same vineyard + paddock + actual
-- vine row. Partial index keeps the index small (most legacy pins have
-- no pin_row_number until backfill runs).
create index if not exists idx_pins_attached_row
  on public.pins (vineyard_id, paddock_id, pin_row_number, pin_side)
  where pin_row_number is not null;

-- =====================================================================
-- Smoke-test queries (run manually after applying):
--
--   -- 1) All seven columns exist and are nullable as expected
--   select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name = 'pins'
--     and column_name in (
--       'driving_row_number','pin_row_number','pin_side',
--       'along_row_distance_m','snapped_latitude','snapped_longitude',
--       'snapped_to_row'
--     )
--   order by column_name;
--
--   -- 2) Existing rows are untouched (no backfill yet)
--   select count(*) as total,
--          count(*) filter (where pin_row_number is null) as pin_row_null,
--          count(*) filter (where snapped_to_row = false)  as not_snapped
--   from public.pins
--   where deleted_at is null;
--   -- expect: total = pin_row_null = not_snapped
-- =====================================================================
