-- 225: Canonical Spray Report v1 read model and private shared route-image metadata.
-- Run manually after sql/224_trip_weather_observations.sql. This migration does not deploy itself.
begin;

create table if not exists public.trip_report_assets (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  asset_kind text not null default 'route_png',
  bucket text not null default 'trip-report-assets',
  object_path text not null,
  sha256 text not null,
  route_hash text not null,
  style_version text not null default 'spray-route-red-green-v1',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  constraint trip_report_assets_kind_check check (asset_kind = 'route_png'),
  constraint trip_report_assets_bucket_check check (bucket = 'trip-report-assets'),
  constraint trip_report_assets_sha_check check (sha256 ~ '^[a-f0-9]{64}$'),
  constraint trip_report_assets_style_check check (style_version = 'spray-route-red-green-v1'),
  constraint trip_report_assets_trip_style_unique unique (trip_id, asset_kind, route_hash, style_version)
);
create index if not exists trip_report_assets_trip_idx on public.trip_report_assets(trip_id, created_at desc);

alter table public.trip_report_assets enable row level security;
drop policy if exists trip_report_assets_select_members on public.trip_report_assets;
create policy trip_report_assets_select_members on public.trip_report_assets for select to authenticated
  using (public.is_vineyard_member(vineyard_id));
drop policy if exists trip_report_assets_no_direct_write on public.trip_report_assets;
create policy trip_report_assets_no_direct_write on public.trip_report_assets for all to authenticated using (false) with check (false);
revoke all on public.trip_report_assets from public, anon, authenticated;
grant select on public.trip_report_assets to authenticated, service_role;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('trip-report-assets', 'trip-report-assets', false, 10485760, array['image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Storage reads are restricted to members of the owning trip's vineyard. Uploads are
-- performed by the controlled backend path; clients cannot create arbitrary objects.
drop policy if exists trip_report_route_member_read on storage.objects;
create policy trip_report_route_member_read on storage.objects for select to authenticated using (
  bucket_id = 'trip-report-assets' and exists (
    select 1 from public.trip_report_assets a
    where a.bucket = bucket_id and a.object_path = name and public.is_vineyard_member(a.vineyard_id)
  )
);

create or replace function public.upsert_trip_report_route_asset_v1(
  p_trip_id uuid, p_object_path text, p_sha256 text, p_route_hash text
) returns public.trip_report_assets
language plpgsql security definer set search_path = public, storage
as $fn$
declare v_trip public.trips; v_result public.trip_report_assets;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into v_trip from public.trips where id = p_trip_id and deleted_at is null;
  if v_trip.id is null then raise exception 'Trip not found' using errcode = 'P0002'; end if;
  if not public.has_vineyard_role(v_trip.vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'Operational vineyard access required' using errcode = '42501';
  end if;
  if nullif(btrim(p_object_path),'') is null or p_object_path !~ ('^' || p_trip_id::text || '/')
     or p_sha256 !~ '^[a-f0-9]{64}$' or nullif(btrim(p_route_hash),'') is null then
    raise exception 'Invalid route asset metadata' using errcode = '22023';
  end if;
  insert into public.trip_report_assets(vineyard_id,trip_id,object_path,sha256,route_hash,created_by)
  values(v_trip.vineyard_id,p_trip_id,btrim(p_object_path),p_sha256,btrim(p_route_hash),auth.uid())
  on conflict (trip_id,asset_kind,route_hash,style_version) do update set
    object_path=excluded.object_path, sha256=excluded.sha256
  returning * into v_result;
  return v_result;
end;
$fn$;
revoke all on function public.upsert_trip_report_route_asset_v1(uuid,text,text,text) from public, anon;
grant execute on function public.upsert_trip_report_route_asset_v1(uuid,text,text,text) to authenticated;

create or replace function public.spray_report_active_seconds_v1(
  p_start timestamptz, p_end timestamptz, p_pauses jsonb, p_resumes jsonb
) returns bigint language plpgsql stable set search_path = public as $fn$
declare v_end timestamptz := coalesce(p_end, now()); v_cursor timestamptz := p_start;
  v_total double precision := 0; v_pause timestamptz; v_resume timestamptz; i integer;
begin
  if p_start is null then return null; end if;
  if coalesce(jsonb_array_length(p_pauses),0) > 0 then
    for i in 0..jsonb_array_length(p_pauses)-1 loop
      begin v_pause := (p_pauses->>i)::timestamptz; exception when others then continue; end;
      if v_pause < v_cursor or v_pause > v_end then continue; end if;
      v_total := v_total + extract(epoch from (v_pause-v_cursor));
      if i >= coalesce(jsonb_array_length(p_resumes),0) then return greatest(floor(v_total),0)::bigint; end if;
      begin v_resume := (p_resumes->>i)::timestamptz; exception when others then return greatest(floor(v_total),0)::bigint; end;
      if v_resume < v_pause or v_resume > v_end then return greatest(floor(v_total),0)::bigint; end if;
      v_cursor := v_resume;
    end loop;
  end if;
  v_total := v_total + extract(epoch from (v_end-v_cursor));
  return greatest(floor(v_total),0)::bigint;
end;
$fn$;

create or replace function public.spray_report_rows_v1(p_trip public.trips, p_blocks jsonb)
returns jsonb language plpgsql stable set search_path = public as $fn$
declare v_rows jsonb := '[]'; v_row jsonb; v_number numeric; v_status text; v_source text;
  v_tanks integer[]; v_block_name text;
begin
  if jsonb_typeof(p_blocks)='array' and jsonb_array_length(p_blocks)=1 then
    v_block_name := coalesce(p_blocks->0->>'name', p_blocks->0->>'blockName');
  end if;
  for v_row in select value from jsonb_array_elements(coalesce(p_trip.row_sequence,'[]'::jsonb)) loop
    begin v_number := (v_row#>>'{}')::numeric; exception when others then continue; end;
    if coalesce(p_trip.completed_paths,'[]'::jsonb) @> jsonb_build_array(v_number) then
      v_status := 'Complete'; v_source := 'completedPaths';
    elsif coalesce(p_trip.skipped_paths,'[]'::jsonb) @> jsonb_build_array(v_number) then
      v_status := 'Skipped/Not complete'; v_source := 'skippedPaths';
    else v_status := 'Partial'; v_source := 'incompletePlannedPath'; end if;
    select array_agg(distinct coalesce((s->>'tankNumber')::integer,(s->>'tank_number')::integer))
      into v_tanks from jsonb_array_elements(coalesce(p_trip.tank_sessions,'[]'::jsonb)) s
      where coalesce(s->'pathsCovered',s->'paths_covered','[]'::jsonb) @> jsonb_build_array(v_number);
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'rowNumber',v_number,'blockName',v_block_name,'status',v_status,'source',v_source,
      'tank',case when coalesce(cardinality(v_tanks),0)=0 then 'null'::jsonb
                  when cardinality(v_tanks)=1 then to_jsonb(v_tanks[1]) else to_jsonb('Multiple'::text) end
    ));
  end loop;
  return v_rows;
end;
$fn$;

create or replace function public.spray_report_tanks_v1(p_planned jsonb, p_trip_id uuid)
returns jsonb language plpgsql stable set search_path = public as $fn$
declare v_result jsonb := '[]'; t jsonb; c jsonb; a public.spray_tank_actuals; v_chems jsonb;
  ac jsonb; matches jsonb[]; v_actual numeric; v_match text; v_planned_id text; v_saved_id text;
begin
  for t in select value from jsonb_array_elements(coalesce(p_planned,'[]'::jsonb)) loop
    select * into a from public.spray_tank_actuals x
      where x.trip_id=p_trip_id and x.deleted_at is null
        and x.tank_number=coalesce((t->>'tankNumber')::int,(t->>'tank_number')::int)
      order by x.client_updated_at desc limit 1;
    v_chems := '[]';
    for c in select value from jsonb_array_elements(coalesce(t->'chemicals','[]'::jsonb)) loop
      v_planned_id := coalesce(c->>'id',c->>'chemicalId'); v_saved_id := coalesce(c->>'savedChemicalId',c->>'saved_chemical_id');
      v_actual := null; v_match := 'notRecorded'; matches := array[]::jsonb[];
      if a.id is not null then
        select array_agg(x) into matches from jsonb_array_elements(a.chemicals) x where x->>'plannedChemicalId'=v_planned_id;
        if cardinality(matches)=1 then ac:=matches[1]; v_match:='plannedChemicalId';
        elsif cardinality(matches)>1 then ac:=null; v_match:='ambiguous';
        elsif v_saved_id is not null then
          select array_agg(x) into matches from jsonb_array_elements(a.chemicals) x where x->>'savedChemicalId'=v_saved_id;
          if cardinality(matches)=1 then ac:=matches[1]; v_match:='savedChemicalId'; elsif cardinality(matches)>1 then ac:=null; v_match:='ambiguous'; end if;
        end if;
        if ac is null and v_match='notRecorded' then
          select array_agg(x) into matches from jsonb_array_elements(a.chemicals) x
            where lower(btrim(x->>'name'))=lower(btrim(coalesce(c->>'name','')))
              and lower(btrim(x->>'unit'))=lower(btrim(coalesce(c->>'unit','')));
          if cardinality(matches)=1 then ac:=matches[1]; v_match:='nameUnit'; elsif cardinality(matches)>1 then v_match:='ambiguous'; end if;
        end if;
        if ac is not null then v_actual := (ac->>'actualAmountBase')::numeric; end if;
      end if;
      v_chems := v_chems || jsonb_build_array(jsonb_build_object(
        'plannedChemicalId',v_planned_id,'savedChemicalId',v_saved_id,'name',coalesce(c->>'name','Unnamed chemical'),
        'unit',coalesce(c->>'unit','Litres'),'plannedAmountBase',coalesce((c->>'volumePerTank')::numeric,(c->>'volume_per_tank')::numeric,0),
        'actualAmountBase',v_actual,'matchSource',v_match));
      ac:=null;
    end loop;
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'tankNumber',coalesce((t->>'tankNumber')::int,(t->>'tank_number')::int),
      'plannedWaterLitres',coalesce((t->>'waterVolume')::numeric,(t->>'water_volume')::numeric,0),
      'actualWaterLitres',case when a.id is null then null else a.water_volume_l end,'chemicals',v_chems));
  end loop;
  return v_result;
end;
$fn$;

create or replace function public.get_spray_report_v1(p_trip_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare t public.trips; r public.spray_records; v public.vineyards; v_blocks jsonb; v_rows jsonb;
  v_route public.trip_report_assets; v_machine text; v_unit text; v_warnings jsonb := '[]'; v_weather jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not public.is_vineyard_member(t.vineyard_id) then raise exception 'Vineyard membership required' using errcode='42501'; end if;
  select * into r from public.spray_records where trip_id=t.id and not is_template and deleted_at is null order by updated_at desc limit 1;
  if coalesce(t.trip_function,'')<>'spraying' and r.id is null then raise exception 'Trip is not a spray trip' using errcode='22023'; end if;
  if r.id is null then raise exception 'Spray record not available yet—sync and retry' using errcode='P0002'; end if;
  select * into v from public.vineyards where id=t.vineyard_id;
  if r.application_blocks is not null then
    select jsonb_agg(jsonb_build_object(
      'blockId',b->>'blockId','name',coalesce(b->>'blockName','Unnamed block'),
      'grossAreaHa',case when b ? 'grossAreaHa' then (b->>'grossAreaHa')::numeric end,
      'treatedAreaHa',null) order by ordinality)
      into v_blocks from jsonb_array_elements(r.application_blocks) with ordinality as source(b, ordinality);
  end if;
  if v_blocks is null then v_warnings:=v_warnings||to_jsonb('Blocks treated were not recorded.'::text); end if;
  select name into v_machine from public.vineyard_machines where id=coalesce(r.machine_id,t.machine_id) and deleted_at is null;
  v_machine:=coalesce(v_machine,r.tractor,(select name from public.tractors where id=coalesce(r.tractor_id,t.tractor_id)));
  select name into v_unit from public.spray_equipment where id=r.spray_equipment_id and deleted_at is null;
  v_unit:=coalesce(v_unit,r.equipment_type);
  select * into v_route from public.trip_report_assets where trip_id=t.id and route_hash is not null order by created_at desc limit 1;
  if v_route.id is null then v_warnings:=v_warnings||to_jsonb('Shared route image is not available yet.'::text); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'sampleSlot',w.sample_slot,'observedAt',w.observed_at,'source',w.source,'sourceKind',w.source_kind,'isStale',w.is_stale,
    'temperatureC',w.temperature_c,'humidityPct',w.humidity_pct,'windSpeedKmh',w.wind_speed_kmh,'windGustKmh',w.wind_gust_kmh,
    'windDirectionDeg',w.wind_direction_deg,'rainMm',w.rain_mm) order by w.sample_slot),'[]'::jsonb)
    into v_weather from public.trip_weather_observations w where w.trip_id=t.id;
  if jsonb_array_length(v_weather)=0 then v_warnings:=v_warnings||to_jsonb('No hourly weather observations were recorded.'::text); end if;
  v_rows:=public.spray_report_rows_v1(t,v_blocks);
  if exists(select 1 from jsonb_array_elements(v_rows) x where x->>'tank'='Multiple') then
    v_warnings:=v_warnings||to_jsonb('One or more rows overlap multiple tank sessions.'::text);
  end if;
  return jsonb_build_object(
    'schemaVersion','1.0',
    'identity',jsonb_build_object('tripId',t.id,'sprayRecordId',r.id,'vineyardId',v.id,'vineyardName',v.name,
      'reference',coalesce(r.spray_reference,''),'vineyardTimeZone',coalesce(nullif(v.timezone,''),'UTC')),
    'trip',jsonb_build_object('startUtc',t.start_time,'endUtc',t.end_time,
      'activeDurationSeconds',public.spray_report_active_seconds_v1(t.start_time,t.end_time,t.pause_timestamps,t.resume_timestamps),
      'distanceMetres',t.total_distance,'operatorName',coalesce(nullif(t.person_name,''),(select full_name from public.profiles where id=t.operator_user_id)),
      'pinCount',coalesce(jsonb_array_length(t.pin_ids),0)),
    'blocks',v_blocks,
    'equipment',jsonb_build_object('tractorName',nullif(v_machine,''),'startEngineHours',t.start_engine_hours,
      'endEngineHours',t.end_engine_hours,'engineHoursUsed',case when t.end_engine_hours>t.start_engine_hours then t.end_engine_hours-t.start_engine_hours end,
      'sprayUnitName',nullif(v_unit,'')),
    'rows',v_rows,'tanks',public.spray_report_tanks_v1(r.tanks,t.id),'weather',v_weather,
    'route',case when v_route.id is null then null else jsonb_build_object('bucket',v_route.bucket,'objectPath',v_route.object_path,
      'sha256',v_route.sha256,'routeHash',v_route.route_hash,'styleVersion',v_route.style_version) end,
    'cost',null,'warnings',v_warnings);
end;
$fn$;

revoke all on function public.get_spray_report_v1(uuid) from public, anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;
revoke all on function public.spray_report_active_seconds_v1(timestamptz,timestamptz,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.spray_report_rows_v1(public.trips,jsonb) from public, anon, authenticated;
revoke all on function public.spray_report_tanks_v1(jsonb,uuid) from public, anon, authenticated;

commit;
