-- Adds operator-selectable function and free-text title to trips so the
-- maintenance operation can be identified in trip history / reporting.
-- Backwards-compatible: both columns are nullable. No RLS or portal changes.

alter table public.trips
    add column if not exists trip_function text null,
    add column if not exists trip_title text null;

create index if not exists idx_trips_trip_function on public.trips (trip_function);
