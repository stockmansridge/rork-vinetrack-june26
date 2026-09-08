-- 226: Controlled, immutable registration for canonical Spray Report route assets.
-- Run manually after sql/225_get_spray_report_v1.sql. This migration does not deploy itself.
begin;

-- A Spray Trip has one immutable canonical route image. Refuse to guess which
-- record is canonical if uncontrolled writes have already created duplicates.
do $migration$
begin
  if exists (
    select 1
    from public.trip_report_assets
    where asset_kind = 'route_png'
      and style_version = 'spray-route-red-green-v1'
    group by trip_id
    having count(*) > 1
  ) then
    raise exception 'Duplicate canonical Spray Report route assets exist; resolve them before applying SQL 226'
      using errcode = '23505';
  end if;
end;
$migration$;

create unique index if not exists trip_report_assets_one_canonical_route_per_trip
  on public.trip_report_assets (trip_id)
  where asset_kind = 'route_png'
    and style_version = 'spray-route-red-green-v1';

-- The SQL 225 upsert could replace metadata for an existing route hash. Remove
-- that write path so every client uses the immutable registration contract.
revoke all on function public.upsert_trip_report_route_asset_v1(uuid, text, text, text)
  from public, anon, authenticated;
drop function if exists public.upsert_trip_report_route_asset_v1(uuid, text, text, text);

create or replace function public.register_spray_report_route_asset_v1(
  p_trip_id uuid,
  p_bucket text,
  p_object_path text,
  p_sha256 text,
  p_route_hash text,
  p_style_version text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, storage
as $function$
declare
  v_uid uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_existing public.trip_report_assets%rowtype;
  v_path text := btrim(coalesce(p_object_path, ''));
  v_sha256 text := btrim(coalesce(p_sha256, ''));
  v_route_hash text := btrim(coalesce(p_route_hash, ''));
  v_bucket constant text := 'trip-report-assets';
  v_style constant text := 'spray-route-red-green-v1';
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_trip_id is null then
    raise exception 'A trip is required' using errcode = '22004';
  end if;

  if p_bucket is distinct from v_bucket
     or p_style_version is distinct from v_style then
    raise exception 'Only the approved canonical Spray Report route bucket and style are accepted'
      using errcode = '22023';
  end if;

  if length(v_path) > 512
     or v_path !~ ('^' || p_trip_id::text || '/[A-Za-z0-9][A-Za-z0-9._/-]*[.]png$')
     or v_path ~ '(^|/)[.][.]?(/|$)'
     or v_path like '%//%'
     or v_path like E'%\\%' then
    raise exception 'The route object path must be a safe PNG path beneath the trip id'
      using errcode = '22023';
  end if;

  if v_sha256 !~ '^[a-f0-9]{64}$'
     or v_route_hash = ''
     or length(v_route_hash) > 256
     or v_route_hash ~ '[[:cntrl:][:space:]]' then
    raise exception 'Route sha256 or route hash is invalid'
      using errcode = '22023';
  end if;

  -- The trip row is the per-trip serialization lock. A simultaneous caller
  -- waits here, then observes and receives the winner's immutable asset.
  select * into v_trip
  from public.trips
  where id = p_trip_id
    and deleted_at is null
  for update;

  if v_trip.id is null then
    raise exception 'Trip not found' using errcode = 'P0002';
  end if;

  if not public.is_vineyard_member(v_trip.vineyard_id) then
    raise exception 'Vineyard membership required' using errcode = '42501';
  end if;

  select * into v_existing
  from public.trip_report_assets
  where trip_id = p_trip_id
    and asset_kind = 'route_png'
    and style_version = v_style
  order by created_at, id
  limit 1;

  if v_existing.id is null then
    if not exists (
      select 1
      from storage.buckets b
      where b.id = v_bucket
        and b.public = false
    ) then
      raise exception 'Approved private route bucket is not configured'
        using errcode = '55000';
    end if;

    if not exists (
      select 1
      from storage.objects o
      where o.bucket_id = v_bucket
        and o.name = v_path
    ) then
      raise exception 'Route object must be uploaded before registration'
        using errcode = 'P0002';
    end if;

    begin
      insert into public.trip_report_assets (
        vineyard_id,
        trip_id,
        asset_kind,
        bucket,
        object_path,
        sha256,
        route_hash,
        style_version,
        created_by
      ) values (
        v_trip.vineyard_id,
        p_trip_id,
        'route_png',
        v_bucket,
        v_path,
        v_sha256,
        v_route_hash,
        v_style,
        v_uid
      )
      returning * into v_existing;
    exception when unique_violation then
      -- The partial unique index is the final safety net if a competing
      -- transaction registered between checks through any privileged path.
      select * into v_existing
      from public.trip_report_assets
      where trip_id = p_trip_id
        and asset_kind = 'route_png'
        and style_version = v_style
      order by created_at, id
      limit 1;
    end;
  end if;

  if v_existing.id is null then
    raise exception 'Canonical route asset could not be resolved'
      using errcode = '55000';
  end if;

  return jsonb_build_object(
    'bucket', v_existing.bucket,
    'objectPath', v_existing.object_path,
    'sha256', v_existing.sha256,
    'routeHash', v_existing.route_hash,
    'styleVersion', v_existing.style_version
  );
end;
$function$;

revoke all on function public.register_spray_report_route_asset_v1(uuid, text, text, text, text, text)
  from public, anon;
grant execute on function public.register_spray_report_route_asset_v1(uuid, text, text, text, text, text)
  to authenticated;

-- Keep direct metadata writes closed. Reads remain member-scoped through the
-- policy installed by SQL 225.
alter table public.trip_report_assets enable row level security;
revoke insert, update, delete, truncate on public.trip_report_assets from anon, authenticated;
grant select on public.trip_report_assets to authenticated;

commit;
