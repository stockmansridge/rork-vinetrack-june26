-- 038_trips_seeding_details.sql
-- Phase: Seeding trip function — optional structured Seeding Details on trips.
--
-- Approved approach:
--   * Add a single nullable JSONB column to public.trips: seeding_details
--   * No defaults, no backfill, no triggers
--   * No RLS changes (existing trip RLS already covers this column)
--   * Optional GIN index for future reporting / filtering by seeding fields
--   * No changes to other tables, RPCs, or sync logic
--
-- Storage model:
--   * Only normally populated when trips.trip_function = 'seeding'
--   * Older clients ignore this column safely (column is nullable, no default)
--   * Lovable can later read trips.seeding_details for trip detail / reports
--
-- Approved JSON shape (all fields optional):
--   {
--     "front_box": {
--       "mix_name": "",
--       "rate_per_ha": null,
--       "shutter_slide": "3/4",        -- '3/4' | 'Full'
--       "bottom_flap": "1",            -- '1'   | '3'
--       "metering_wheel": "N",         -- 'N'   | 'F'
--       "seed_volume_kg": null,
--       "gearbox_setting": null
--     },
--     "back_box": {
--       "mix_name": "",
--       "rate_per_ha": null,
--       "shutter_slide": "Full",
--       "bottom_flap": "3",
--       "metering_wheel": "F",
--       "seed_volume_kg": null,
--       "gearbox_setting": null
--     },
--     "sowing_depth_cm": null,
--     "mix_lines": [
--       {
--         "name": "",
--         "percent_of_mix": null,      -- 0-100 if entered
--         "seed_box": "Front",         -- 'Front' | 'Back'
--         "kg_per_ha": null,
--         "supplier_manufacturer": ""
--       }
--     ]
--   }

-- =====================================================================
-- Column
-- =====================================================================
alter table public.trips
  add column if not exists seeding_details jsonb null;

comment on column public.trips.seeding_details is
  'Optional structured Seeding Details for trips with trip_function = ''seeding''. '
  'Schema is documented in sql/038_trips_seeding_details.sql. All fields optional. '
  'Older clients ignore this column safely. Lovable can read this for reporting.';

-- =====================================================================
-- Index (optional, for future reporting / filtering)
-- GIN with jsonb_path_ops keeps index small and is well-suited to @> queries.
-- Only indexes rows that actually have seeding_details populated.
-- =====================================================================
create index if not exists idx_trips_seeding_details_gin
  on public.trips
  using gin (seeding_details jsonb_path_ops)
  where seeding_details is not null;

-- =====================================================================
-- Smoke-test queries (run manually after applying):
--
--   -- 1) Column exists and is nullable jsonb
--   select column_name, data_type, is_nullable
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name = 'trips'
--     and column_name = 'seeding_details';
--   -- expect: 1 row, data_type = jsonb, is_nullable = YES
--
--   -- 2) Index exists
--   select indexname
--   from pg_indexes
--   where schemaname = 'public'
--     and tablename = 'trips'
--     and indexname = 'idx_trips_seeding_details_gin';
--
--   -- 3) Existing trips are unaffected
--   select count(*) as total,
--          count(*) filter (where seeding_details is null) as null_count
--   from public.trips;
--   -- expect: total = null_count (no backfill)
--
--   -- 4) Round-trip a sample seeding_details on a test trip (as a vineyard member)
--   --    Replace <trip-id> with a real id you own.
--   -- update public.trips
--   --   set seeding_details = jsonb_build_object(
--   --     'front_box', jsonb_build_object(
--   --       'mix_name', 'Test mix',
--   --       'rate_per_ha', 25.5,
--   --       'shutter_slide', '3/4',
--   --       'bottom_flap', '1',
--   --       'metering_wheel', 'N',
--   --       'seed_volume_kg', 120,
--   --       'gearbox_setting', 14
--   --     ),
--   --     'sowing_depth_cm', 2.5,
--   --     'mix_lines', jsonb_build_array(
--   --       jsonb_build_object(
--   --         'name', 'Ryegrass',
--   --         'percent_of_mix', 60,
--   --         'seed_box', 'Front',
--   --         'kg_per_ha', 15,
--   --         'supplier_manufacturer', 'Acme'
--   --       )
--   --     )
--   --   )
--   --   where id = '<trip-id>';
--
--   -- 5) Read it back
--   -- select id, trip_function, seeding_details
--   -- from public.trips
--   -- where id = '<trip-id>';
--
--   -- 6) GIN containment query (future reporting style)
--   -- select id
--   -- from public.trips
--   -- where seeding_details @> '{"front_box": {"shutter_slide": "3/4"}}';
-- =====================================================================
