-- Correct explicit per-function grants introduced by database default privileges.
-- Run after migration 253 creates both functions; no global defaults or table policies change.
begin;

revoke execute on function public.capture_trip_labour_start_v1(
  uuid, uuid, uuid, text, numeric, timestamptz
) from public, anon;

revoke execute on function public.finalise_trip_labour_v1(uuid)
  from public, anon;

grant execute on function public.capture_trip_labour_start_v1(
  uuid, uuid, uuid, text, numeric, timestamptz
) to authenticated;

grant execute on function public.finalise_trip_labour_v1(uuid)
  to authenticated;

commit;
