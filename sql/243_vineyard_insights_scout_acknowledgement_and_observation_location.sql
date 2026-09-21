-- Add revision acknowledgement for Scout graph uploads and measured locations for
-- individual observations. Additive only; existing rows remain location-unavailable.
begin;

alter table public.scout_observations
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists horizontal_accuracy double precision,
  add column if not exists location_captured_at timestamptz,
  add column if not exists location_status text not null default 'location_unavailable';

alter table public.scout_observations
  drop constraint if exists scout_observation_location_honesty;
alter table public.scout_observations
  add constraint scout_observation_location_honesty check (
    (location_status = 'gps_confirmed'
      and latitude is not null and longitude is not null
      and latitude between -90 and 90 and longitude between -180 and 180
      and not (latitude = 0 and longitude = 0)
      and horizontal_accuracy is not null and horizontal_accuracy >= 0
      and location_captured_at is not null)
    or
    (location_status = 'location_unavailable'
      and latitude is null and longitude is null
      and horizontal_accuracy is null and location_captured_at is null)
  );

create or replace function public._vineyard_insights_increment_sync_version()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op = 'INSERT' then
    new.sync_version := greatest(coalesce(new.sync_version, 0), 1);
  else
    if new.client_updated_at is not null and old.client_updated_at is not null then
      if new.client_updated_at < old.client_updated_at then
        raise exception 'A newer Scout revision is already stored' using errcode='40001';
      elsif new.client_updated_at = old.client_updated_at then
        new.sync_version := old.sync_version;
        return new;
      end if;
    end if;
    new.sync_version := coalesce(old.sync_version, 0) + 1;
  end if;
  return new;
end;
$$;

revoke all on function public._vineyard_insights_increment_sync_version() from public, anon;

drop trigger if exists scout_visits_increment_sync_version on public.scout_visits;
create trigger scout_visits_increment_sync_version
before insert or update on public.scout_visits
for each row execute function public._vineyard_insights_increment_sync_version();

drop trigger if exists scout_block_assessments_increment_sync_version on public.scout_block_assessments;
create trigger scout_block_assessments_increment_sync_version
before insert or update on public.scout_block_assessments
for each row execute function public._vineyard_insights_increment_sync_version();

drop trigger if exists scout_observations_increment_sync_version on public.scout_observations;
create trigger scout_observations_increment_sync_version
before insert or update on public.scout_observations
for each row execute function public._vineyard_insights_increment_sync_version();

drop trigger if exists scout_observation_photos_increment_sync_version on public.scout_observation_photos;
create trigger scout_observation_photos_increment_sync_version
before insert or update on public.scout_observation_photos
for each row execute function public._vineyard_insights_increment_sync_version();

commit;
