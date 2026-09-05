-- Phase 5: authoritative actual water and chemical use per started spray tank.
-- Planned quantities remain frozen in spray_records.tanks and are never updated here.

create table if not exists public.spray_tank_actuals (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  spray_record_id uuid not null references public.spray_records(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  tank_session_id text not null,
  tank_number integer not null,
  water_volume_l double precision not null,
  chemicals jsonb not null default '[]'::jsonb,
  confirmed_at timestamptz not null,
  confirmed_by uuid not null references auth.users(id),
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz not null,
  sync_version integer not null default 1,
  constraint spray_tank_actuals_trip_session_unique unique (trip_id, tank_session_id),
  constraint spray_tank_actuals_tank_number_check check (tank_number >= 1),
  constraint spray_tank_actuals_water_check check (water_volume_l >= 0 and water_volume_l not in ('Infinity'::double precision, '-Infinity'::double precision) and water_volume_l <> 'NaN'::double precision),
  constraint spray_tank_actuals_session_check check (btrim(tank_session_id) <> ''),
  constraint spray_tank_actuals_chemicals_array_check check (jsonb_typeof(chemicals) = 'array')
);

create index if not exists spray_tank_actuals_vineyard_idx on public.spray_tank_actuals(vineyard_id) where deleted_at is null;
create index if not exists spray_tank_actuals_spray_record_idx on public.spray_tank_actuals(spray_record_id) where deleted_at is null;
create index if not exists spray_tank_actuals_trip_idx on public.spray_tank_actuals(trip_id) where deleted_at is null;
create index if not exists spray_tank_actuals_updated_idx on public.spray_tank_actuals(updated_at);

comment on table public.spray_tank_actuals is
  'Confirmed actual tank contents. Separate from immutable planned spray_records.tanks. One active identity per trip + tank session.';
comment on column public.spray_tank_actuals.chemicals is
  'Array contract: {id, plannedChemicalId|null, savedChemicalId|null, name, actualAmountBase, unit}; base is mL for liquids and g for solids.';

create or replace function public.validate_spray_tank_actual_chemicals(p_chemicals jsonb)
returns boolean
language plpgsql
immutable
set search_path = public
as $fn$
declare
  v_line jsonb;
  v_amount double precision;
begin
  if jsonb_typeof(p_chemicals) <> 'array' then return false; end if;
  for v_line in select value from jsonb_array_elements(p_chemicals)
  loop
    if jsonb_typeof(v_line) <> 'object'
       or jsonb_typeof(v_line->'id') <> 'string'
       or nullif(btrim(v_line->>'id'), '') is null
       or (v_line ? 'plannedChemicalId') = false
       or (v_line ? 'savedChemicalId') = false
       or jsonb_typeof(v_line->'name') <> 'string'
       or nullif(btrim(v_line->>'name'), '') is null
       or jsonb_typeof(v_line->'actualAmountBase') <> 'number'
       or jsonb_typeof(v_line->'unit') <> 'string'
       or v_line->>'unit' not in ('Litres','mL','Kg','g')
    then return false;
    end if;
    begin
      perform (v_line->>'id')::uuid;
    exception when others then return false;
    end;
    begin
      v_amount := (v_line->>'actualAmountBase')::double precision;
    exception when others then return false;
    end;
    if v_amount < 0 or v_amount <> v_amount or v_amount in ('Infinity'::double precision, '-Infinity'::double precision) then
      return false;
    end if;
    if (v_line->'plannedChemicalId') <> 'null'::jsonb then
      begin perform (v_line->>'plannedChemicalId')::uuid; exception when others then return false; end;
    end if;
    if (v_line->'savedChemicalId') <> 'null'::jsonb then
      begin perform (v_line->>'savedChemicalId')::uuid; exception when others then return false; end;
    end if;
  end loop;
  return true;
end;
$fn$;

alter table public.spray_tank_actuals drop constraint if exists spray_tank_actuals_chemicals_contract_check;
alter table public.spray_tank_actuals add constraint spray_tank_actuals_chemicals_contract_check
  check (public.validate_spray_tank_actual_chemicals(chemicals));

create or replace function public.spray_tank_actuals_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_trip_vineyard uuid;
  v_record_vineyard uuid;
  v_record_trip uuid;
begin
  select vineyard_id into v_trip_vineyard from public.trips where id = new.trip_id and deleted_at is null;
  select vineyard_id, trip_id into v_record_vineyard, v_record_trip
    from public.spray_records where id = new.spray_record_id and deleted_at is null and is_template = false;
  if v_trip_vineyard is null then raise exception 'Trip not found'; end if;
  if v_record_vineyard is null then raise exception 'Spray record not found'; end if;
  if new.vineyard_id <> v_trip_vineyard or new.vineyard_id <> v_record_vineyard or v_record_trip is distinct from new.trip_id then
    raise exception 'Vineyard, trip and spray record do not match';
  end if;
  if not exists (
    select 1 from public.trips t, jsonb_array_elements(coalesce(t.tank_sessions, '[]'::jsonb)) s
    where t.id = new.trip_id
      and coalesce(s->>'id', s->>'tank_session_id') = new.tank_session_id
      and coalesce((s->>'tank_number')::integer, (s->>'tankNumber')::integer) = new.tank_number
  ) then raise exception 'Tank session does not belong to trip'; end if;
  new.updated_by := auth.uid();
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
    new.confirmed_by := auth.uid();
  else
    new.id := old.id;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.confirmed_by := old.confirmed_by;
    new.deleted_at := null;
    new.sync_version := old.sync_version + 1;
  end if;
  return new;
end;
$fn$;

create or replace trigger spray_tank_actuals_before_write
before insert or update on public.spray_tank_actuals
for each row execute function public.spray_tank_actuals_before_write();

create or replace trigger spray_tank_actuals_set_updated_at
before update on public.spray_tank_actuals
for each row execute function public.set_updated_at();

alter table public.spray_tank_actuals enable row level security;
drop policy if exists spray_tank_actuals_select_members on public.spray_tank_actuals;
create policy spray_tank_actuals_select_members on public.spray_tank_actuals for select to authenticated
  using (public.is_vineyard_member(vineyard_id));
drop policy if exists spray_tank_actuals_insert_operational on public.spray_tank_actuals;
create policy spray_tank_actuals_insert_operational on public.spray_tank_actuals for insert to authenticated
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));
drop policy if exists spray_tank_actuals_update_operational on public.spray_tank_actuals;
create policy spray_tank_actuals_update_operational on public.spray_tank_actuals for update to authenticated
  using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));
drop policy if exists spray_tank_actuals_no_hard_delete on public.spray_tank_actuals;
create policy spray_tank_actuals_no_hard_delete on public.spray_tank_actuals for delete to authenticated using (false);

grant select on public.spray_tank_actuals to authenticated;
revoke insert, update, delete on public.spray_tank_actuals from authenticated, anon;

create or replace function public.upsert_spray_tank_actual(
  p_id uuid, p_vineyard_id uuid, p_spray_record_id uuid, p_trip_id uuid,
  p_tank_session_id text, p_tank_number integer, p_water_volume_l double precision,
  p_chemicals jsonb, p_confirmed_at timestamptz, p_client_updated_at timestamptz
) returns public.spray_tank_actuals
language plpgsql
security definer
set search_path = public
as $fn$
declare v_result public.spray_tank_actuals;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'Insufficient operational access';
  end if;
  if p_id is null or p_trip_id is null or p_spray_record_id is null or p_tank_session_id is null
     or p_tank_number < 1 or p_water_volume_l < 0 or p_water_volume_l <> p_water_volume_l
     or p_water_volume_l in ('Infinity'::double precision, '-Infinity'::double precision)
     or not public.validate_spray_tank_actual_chemicals(p_chemicals)
  then raise exception 'Invalid actual tank use'; end if;

  insert into public.spray_tank_actuals(
    id, vineyard_id, spray_record_id, trip_id, tank_session_id, tank_number,
    water_volume_l, chemicals, confirmed_at, confirmed_by, created_by, updated_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, p_spray_record_id, p_trip_id, btrim(p_tank_session_id), p_tank_number,
    p_water_volume_l, p_chemicals, p_confirmed_at, auth.uid(), auth.uid(), auth.uid(), p_client_updated_at
  )
  on conflict (trip_id, tank_session_id) do update set
    water_volume_l = excluded.water_volume_l,
    chemicals = excluded.chemicals,
    confirmed_at = excluded.confirmed_at,
    client_updated_at = excluded.client_updated_at,
    updated_by = auth.uid(),
    deleted_at = null
  where excluded.client_updated_at >= spray_tank_actuals.client_updated_at
  returning * into v_result;

  if v_result.id is null then
    select * into v_result from public.spray_tank_actuals
      where trip_id = p_trip_id and tank_session_id = btrim(p_tank_session_id);
  end if;
  return v_result;
end;
$fn$;

revoke all on function public.upsert_spray_tank_actual(uuid,uuid,uuid,uuid,text,integer,double precision,jsonb,timestamptz,timestamptz) from public, anon;
grant execute on function public.upsert_spray_tank_actual(uuid,uuid,uuid,uuid,text,integer,double precision,jsonb,timestamptz,timestamptz) to authenticated;
revoke all on function public.validate_spray_tank_actual_chemicals(jsonb) from public, anon, authenticated;
