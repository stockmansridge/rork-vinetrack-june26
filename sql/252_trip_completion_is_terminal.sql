-- A completed trip cannot be reopened by an older device snapshot or upsert.
-- Inactive saved drafts have no end_time and remain startable as before.
create or replace function public.prevent_completed_trip_reopen()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if old.end_time is not null
     and (new.end_time is null or new.is_active is distinct from false) then
    raise exception 'trip_completed: ended trip cannot be reopened';
  end if;
  return new;
end;
$function$;

drop trigger if exists trips_prevent_completed_reopen on public.trips;
create trigger trips_prevent_completed_reopen
before update on public.trips
for each row execute function public.prevent_completed_trip_reopen();
