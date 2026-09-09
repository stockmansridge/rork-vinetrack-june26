-- 233: additive corrections for deployed manual spray entry v1.
-- Fixes manual tank removal/renumbering, legacy mobile tank decoding, and retry-after-delete authority.
begin;
select pg_advisory_xact_lock(hashtext('vinetrack:manual-spray-entry-v1'));

-- Manual rows intentionally carry actual-use values in spray_tank_actuals. Keep the
-- frozen spray_records.tanks projection decodable by released clients without
-- inventing planned rates, areas, or row assignments.
create or replace function public.manual_spray_compatible_tanks_v1(p_tanks jsonb)
returns jsonb
language sql
immutable
set search_path=public
as $fn$
  select coalesce(jsonb_agg(
    (tank || jsonb_build_object(
      'waterVolume', coalesce((tank->>'waterVolume')::double precision, 0),
      'sprayRatePerHa', coalesce((tank->>'sprayRatePerHa')::double precision, 0),
      'concentrationFactor', coalesce((tank->>'concentrationFactor')::double precision, 0),
      'rowApplications', coalesce(tank->'rowApplications', '[]'::jsonb),
      'chemicals', coalesce((
        select jsonb_agg(chemical || jsonb_build_object(
          'volumePerTank', coalesce((chemical->>'volumePerTank')::double precision, 0),
          'ratePerHa', coalesce((chemical->>'ratePerHa')::double precision, 0),
          'ratePer100L', coalesce((chemical->>'ratePer100L')::double precision, 0),
          'costPerUnit', coalesce((chemical->>'costPerUnit')::double precision, 0)
        ))
        from jsonb_array_elements(coalesce(tank->'chemicals', '[]'::jsonb)) chemical
      ), '[]'::jsonb)
    )) order by coalesce((tank->>'tankNumber')::integer, 0)
  ), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_tanks, '[]'::jsonb)) tank
$fn$;

create or replace function public.manual_spray_compatibility_before_write_v1()
returns trigger
language plpgsql
security definer
set search_path=public
as $fn$
begin
  if new.entry_source = 'manual' then
    new.tanks := public.manual_spray_compatible_tanks_v1(new.tanks);
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_spray_records_manual_compatibility_v1 on public.spray_records;
create trigger trg_spray_records_manual_compatibility_v1
before insert or update of tanks on public.spray_records
for each row execute function public.manual_spray_compatibility_before_write_v1();

-- Existing manual rows created after 232 but before this correction must also be
-- readable by released clients. The coordinated-write guard is disabled only for
-- this deterministic compatibility backfill inside this migration transaction.
alter table public.spray_records disable trigger trg_spray_records_manual_guard_v1;
update public.spray_records
set tanks = public.manual_spray_compatible_tanks_v1(tanks)
where entry_source = 'manual'
  and deleted_at is null;
alter table public.spray_records enable trigger trg_spray_records_manual_guard_v1;

-- A removed actual is allowed to transition to deleted only inside the manual RPC.
-- Active inserts/updates still require an identity present in the frozen tank list.
create or replace function public.spray_tank_actuals_before_write()
returns trigger language plpgsql security definer set search_path=public as $fn$
declare v_trip public.trips; v_record public.spray_records;
begin
  select * into v_trip from public.trips where id=new.trip_id and deleted_at is null;
  select * into v_record from public.spray_records where id=new.spray_record_id and deleted_at is null and is_template=false;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  if v_record.id is null then raise exception 'Spray record not found'; end if;
  if new.vineyard_id<>v_trip.vineyard_id or new.vineyard_id<>v_record.vineyard_id or v_record.trip_id is distinct from new.trip_id then
    raise exception 'Vineyard, trip and spray record do not match';
  end if;
  if v_record.entry_source='manual' then
    if v_trip.entry_source<>'manual' or v_trip.manual_entry_id is distinct from v_record.manual_entry_id then
      raise exception 'Manual application provenance does not match' using errcode='23514';
    end if;
    if coalesce(current_setting('vinetrack.manual_spray_rpc',true),'')<>'on' or not public.has_vineyard_role(new.vineyard_id,array['owner','manager','supervisor']) then
      raise exception 'Manual spray coordinated access required' using errcode='42501';
    end if;
    if not (tg_op='UPDATE' and old.deleted_at is null and new.deleted_at is not null) and not exists (
      select 1 from jsonb_array_elements(coalesce(v_record.tanks,'[]'::jsonb)) tank
      where coalesce(tank->>'id',tank->>'tankSessionId')=new.tank_session_id
        and coalesce((tank->>'tankNumber')::integer,(tank->>'tank_number')::integer)=new.tank_number
    ) then raise exception 'Manual tank identity does not belong to spray'; end if;
  elsif not exists (
    select 1 from jsonb_array_elements(coalesce(v_trip.tank_sessions,'[]'::jsonb)) session
    where coalesce(session->>'id',session->>'tank_session_id')=new.tank_session_id
      and coalesce((session->>'tank_number')::integer,(session->>'tankNumber')::integer)=new.tank_number
  ) then raise exception 'Tank session does not belong to trip'; end if;
  new.updated_by:=auth.uid();
  if tg_op='INSERT' then
    new.created_by:=coalesce(new.created_by,auth.uid()); new.confirmed_by:=auth.uid();
  else
    new.id:=old.id; new.created_at:=old.created_at; new.created_by:=old.created_by;
    new.confirmed_by:=old.confirmed_by; new.sync_version:=old.sync_version+1;
  end if;
  return new;
end $fn$;

-- Synchronise a retained stable tank identity to its new number immediately after
-- the frozen list changes. Removed identities are untouched here and are then
-- soft-deleted by save_manual_spray_v1.
create or replace function public.manual_spray_sync_actual_tank_numbers_v1()
returns trigger
language plpgsql
security definer
set search_path=public
as $fn$
begin
  if new.entry_source='manual' and new.tanks is distinct from old.tanks then
    update public.spray_tank_actuals actual
    set tank_number=(tank->>'tankNumber')::integer,
        updated_by=auth.uid(),
        client_updated_at=new.client_updated_at
    from jsonb_array_elements(coalesce(new.tanks,'[]'::jsonb)) tank
    where actual.spray_record_id=new.id
      and actual.trip_id=new.trip_id
      and actual.deleted_at is null
      and actual.tank_session_id=coalesce(tank->>'id',tank->>'tankSessionId')
      and actual.tank_number is distinct from (tank->>'tankNumber')::integer;
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_spray_records_manual_sync_actual_numbers_v1 on public.spray_records;
create trigger trg_spray_records_manual_sync_actual_numbers_v1
after update of tanks on public.spray_records
for each row execute function public.manual_spray_sync_actual_tank_numbers_v1();

-- Keep the public RPC signature unchanged while making a tombstone authoritative
-- over every save result, including an otherwise cacheable lost-response retry.
do $upgrade$
begin
  if to_regprocedure('public.save_manual_spray_v1_pre_edit_correction_v1(uuid,jsonb,integer)') is null then
    alter function public.save_manual_spray_v1(uuid,jsonb,integer)
      rename to save_manual_spray_v1_pre_edit_correction_v1;
  end if;
end
$upgrade$;

create or replace function public.save_manual_spray_v1(
  p_operation_id uuid,
  p_payload jsonb,
  p_expected_version integer default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $fn$
declare v_manual_entry_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_operation_id is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Invalid manual spray request' using errcode='22023'; end if;
  begin
    v_manual_entry_id := (p_payload->>'manualEntryId')::uuid;
  exception when others then
    raise exception 'Manual spray identities are invalid' using errcode='22023';
  end;
  perform pg_advisory_xact_lock(hashtextextended(v_manual_entry_id::text,0));
  if exists(select 1 from public.manual_spray_tombstones where manual_entry_id=v_manual_entry_id) then
    raise exception 'Manual spray was deleted and cannot be replayed' using errcode='55000';
  end if;
  return public.save_manual_spray_v1_pre_edit_correction_v1(p_operation_id,p_payload,p_expected_version);
end
$fn$;

revoke all on function public.manual_spray_compatible_tanks_v1(jsonb) from public,anon,authenticated;
revoke all on function public.manual_spray_compatibility_before_write_v1() from public,anon,authenticated;
revoke all on function public.manual_spray_sync_actual_tank_numbers_v1() from public,anon,authenticated;
revoke all on function public.save_manual_spray_v1_pre_edit_correction_v1(uuid,jsonb,integer) from public,anon,authenticated,service_role;
revoke all on function public.save_manual_spray_v1(uuid,jsonb,integer) from public,anon,service_role;
grant execute on function public.save_manual_spray_v1(uuid,jsonb,integer) to authenticated;
commit;
