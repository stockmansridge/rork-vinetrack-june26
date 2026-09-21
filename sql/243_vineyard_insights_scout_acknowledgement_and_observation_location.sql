-- Add revision acknowledgement for Scout graph uploads and measured locations for
-- individual observations. Additive only; existing rows remain location-unavailable.
begin;

alter table public.scout_observations
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists horizontal_accuracy double precision,
  add column if not exists location_captured_at timestamptz,
  add column if not exists location_status text not null default 'location_unavailable';

-- A timestamp orders revisions; it does not identify them. The durable client
-- outbox UUID identifies one exact graph attempt across restart and retry.
alter table public.scout_visits
  add column if not exists client_revision_id uuid;
alter table public.scout_block_assessments
  add column if not exists client_revision_id uuid;
alter table public.scout_observations
  add column if not exists client_revision_id uuid;
alter table public.scout_observation_photos
  add column if not exists client_revision_id uuid;

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
    if new.client_updated_at is not null and old.client_updated_at is not null
       and new.client_updated_at < old.client_updated_at then
      raise exception 'A newer Scout revision is already stored; local work was not accepted'
        using errcode='40001';
    end if;

    if new.client_revision_id is not null
       and new.client_revision_id = old.client_revision_id
       and new.client_updated_at is not distinct from old.client_updated_at then
      if (to_jsonb(new) - array['sync_version', 'updated_at']::text[])
         is distinct from
         (to_jsonb(old) - array['sync_version', 'updated_at']::text[]) then
        raise exception 'Scout revision identity was reused with different content; local work was not accepted'
          using errcode='40001';
      end if;
      new.sync_version := old.sync_version;
      new.updated_at := old.updated_at;
      return new;
    end if;

    new.sync_version := coalesce(old.sync_version, 0) + 1;
  end if;
  return new;
end;
$$;

revoke all on function public._vineyard_insights_increment_sync_version() from public, anon;

drop trigger if exists scout_visits_increment_sync_version on public.scout_visits;
drop trigger if exists zz_scout_visits_increment_sync_version on public.scout_visits;
create trigger zz_scout_visits_increment_sync_version
before insert or update on public.scout_visits
for each row execute function public._vineyard_insights_increment_sync_version();

drop trigger if exists scout_block_assessments_increment_sync_version on public.scout_block_assessments;
drop trigger if exists zz_scout_block_assessments_increment_sync_version on public.scout_block_assessments;
create trigger zz_scout_block_assessments_increment_sync_version
before insert or update on public.scout_block_assessments
for each row execute function public._vineyard_insights_increment_sync_version();

drop trigger if exists scout_observations_increment_sync_version on public.scout_observations;
drop trigger if exists zz_scout_observations_increment_sync_version on public.scout_observations;
create trigger zz_scout_observations_increment_sync_version
before insert or update on public.scout_observations
for each row execute function public._vineyard_insights_increment_sync_version();

drop trigger if exists scout_observation_photos_increment_sync_version on public.scout_observation_photos;
drop trigger if exists zz_scout_observation_photos_increment_sync_version on public.scout_observation_photos;
create trigger zz_scout_observation_photos_increment_sync_version
before insert or update on public.scout_observation_photos
for each row execute function public._vineyard_insights_increment_sync_version();

commit;
