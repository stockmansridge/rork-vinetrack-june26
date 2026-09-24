-- The live zz_trips_completed_invariant / trips_enforce_completed_invariant()
-- is the canonical terminal-state rule for every Trip. Remove only the
-- obsolete safeguard limited to three Estellar Trips.
drop trigger if exists trg_temp_estellar_hold_completed_trips_closed on public.trips;
drop function if exists public.temp_estellar_hold_completed_trips_closed();
