-- Run manually after sql/226_register_spray_report_route_asset_v1.sql. This migration does not deploy itself.
-- Adds version-checked, audited corrections to the existing spray_tank_actuals authority.
begin;

alter table public.spray_tank_actuals alter column water_volume_l drop not null;
alter table public.spray_tank_actuals add column if not exists correction_version bigint not null default 0;
alter table public.spray_tank_actuals add column if not exists last_corrected_at timestamptz;
alter table public.spray_tank_actuals drop constraint if exists spray_tank_actuals_water_check;
alter table public.spray_tank_actuals add constraint spray_tank_actuals_water_check check (
  water_volume_l is null or (water_volume_l >= 0 and water_volume_l not in ('Infinity'::double precision, '-Infinity'::double precision) and water_volume_l <> 'NaN'::double precision)
);

create table if not exists public.spray_tank_actual_amendments (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  spray_record_id uuid not null references public.spray_records(id) on delete cascade,
  spray_tank_actual_id uuid not null references public.spray_tank_actuals(id) on delete cascade,
  tank_number integer not null,
  chemical_actual_id uuid,
  planned_chemical_id uuid,
  saved_chemical_id uuid,
  field_name text not null,
  change_kind text not null,
  previous_value jsonb,
  new_value jsonb,
  previous_unit text,
  new_unit text,
  revision bigint not null,
  edited_by uuid not null references auth.users(id),
  editor_name text not null,
  edited_at timestamptz not null default now(),
  constraint spray_actual_amendments_field_check check (field_name in ('actualWaterLitres','actualChemical')),
  constraint spray_actual_amendments_kind_check check (change_kind in ('initialEntry','correction','cleared','addition','substitution','removed','explicitZero')),
  constraint spray_actual_amendments_tank_check check (tank_number >= 1),
  constraint spray_actual_amendments_operation_field_unique unique(operation_id, field_name, chemical_actual_id)
);
create index if not exists spray_actual_amendments_trip_idx on public.spray_tank_actual_amendments(trip_id, edited_at, id);
create index if not exists spray_actual_amendments_actual_idx on public.spray_tank_actual_amendments(spray_tank_actual_id, revision);
comment on table public.spray_tank_actual_amendments is 'Append-only server-authored audit history for actual tank-use corrections. Planned spray_records.tanks are never changed.';

alter table public.spray_tank_actual_amendments enable row level security;
drop policy if exists spray_actual_amendments_select_members on public.spray_tank_actual_amendments;
create policy spray_actual_amendments_select_members on public.spray_tank_actual_amendments for select to authenticated
  using (public.is_vineyard_member(vineyard_id));
drop policy if exists spray_actual_amendments_no_direct_write on public.spray_tank_actual_amendments;
create policy spray_actual_amendments_no_direct_write on public.spray_tank_actual_amendments for all to authenticated using (false) with check (false);
revoke all on public.spray_tank_actual_amendments from public, anon, authenticated;
grant select on public.spray_tank_actual_amendments to authenticated, service_role;

create or replace function public.validate_spray_tank_actual_chemicals_v1(p_chemicals jsonb, p_planned_tank jsonb, p_vineyard_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $fn$
declare c jsonb; v_saved uuid; v_planned text; v_replaces text; v_kind text; v_amount double precision; v_plan_unit text;
begin
  if jsonb_typeof(p_chemicals) <> 'array' then return false; end if;
  if exists(select 1 from jsonb_array_elements(p_chemicals) x group by x->>'id' having count(*) > 1) then return false; end if;
  if exists(select 1 from jsonb_array_elements(p_chemicals) x where x->>'plannedChemicalId' is not null group by x->>'plannedChemicalId' having count(*) > 1) then return false; end if;
  for c in select value from jsonb_array_elements(p_chemicals) loop
    if not public.validate_spray_tank_actual_chemicals(jsonb_build_array(c)) then return false; end if;
    v_kind := coalesce(nullif(c->>'usageKind',''), case when c->>'plannedChemicalId' is not null then 'planned' else 'additional' end);
    if v_kind not in ('planned','substitution','additional') then return false; end if;
    v_planned := c->>'plannedChemicalId'; v_replaces := c->>'replacesPlannedChemicalId';
    if v_kind='planned' and v_planned is null then return false; end if;
    if v_kind<>'planned' and v_planned is not null then return false; end if;
    if v_kind='substitution' and v_replaces is null then return false; end if;
    if v_kind<>'substitution' and v_replaces is not null then return false; end if;
    if coalesce(v_planned,v_replaces) is not null then
      select coalesce(pc->>'unit','Litres') into v_plan_unit
      from jsonb_array_elements(coalesce(p_planned_tank->'chemicals','[]'::jsonb)) pc
      where coalesce(pc->>'id',pc->>'chemicalId')=coalesce(v_planned,v_replaces) limit 1;
      if v_plan_unit is null then return false; end if;
      if (v_plan_unit in ('Litres','mL')) <> (c->>'unit' in ('Litres','mL')) then return false; end if;
    end if;
    if c->>'savedChemicalId' is not null then
      begin v_saved := (c->>'savedChemicalId')::uuid; exception when others then return false; end;
      if not exists(select 1 from public.saved_chemicals sc where sc.id=v_saved and sc.vineyard_id=p_vineyard_id and sc.deleted_at is null) then return false; end if;
    end if;
    begin v_amount := (c->>'actualAmountBase')::double precision; exception when others then return false; end;
    if v_amount < 0 or v_amount <> v_amount or v_amount in ('Infinity'::double precision,'-Infinity'::double precision) then return false; end if;
  end loop;
  return true;
end $fn$;

create or replace function public.spray_actual_amendments_v1(p_trip_id uuid)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',a.id,'operationId',a.operation_id,'tankNumber',a.tank_number,'chemicalActualId',a.chemical_actual_id,
    'plannedChemicalId',a.planned_chemical_id,'savedChemicalId',a.saved_chemical_id,'field',a.field_name,
    'changeKind',a.change_kind,'previousValue',a.previous_value,'newValue',a.new_value,
    'previousUnit',a.previous_unit,'newUnit',a.new_unit,'revision',a.revision,
    'editedBy',a.edited_by,'editorName',a.editor_name,'editedAt',a.edited_at
  ) order by a.edited_at,a.id),'[]'::jsonb)
  from public.spray_tank_actual_amendments a where a.trip_id=p_trip_id
    and public.is_vineyard_member(a.vineyard_id)
$fn$;

create or replace function public.correct_spray_tank_actual_v1(
  p_operation_id uuid, p_actual_id uuid, p_trip_id uuid, p_spray_record_id uuid,
  p_tank_session_id text, p_tank_number integer, p_expected_version bigint,
  p_water_volume_l double precision, p_chemicals jsonb
) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare t public.trips; r public.spray_records; a public.spray_tank_actuals; v_tank jsonb;
  old_water double precision; old_chems jsonb; new_version bigint; actor_name text; now_at timestamptz := clock_timestamp();
  old_c jsonb; new_c jsonb; chem_id uuid; kind text;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_operation_id is null or p_actual_id is null or p_expected_version is null or p_expected_version < 0 then raise exception 'Invalid correction request' using errcode='22023'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null for update;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then raise exception 'Correction access required' using errcode='42501'; end if;
  select * into r from public.spray_records where id=p_spray_record_id and trip_id=t.id and vineyard_id=t.vineyard_id and not is_template and deleted_at is null;
  if r.id is null then raise exception 'Spray record does not match trip' using errcode='22023'; end if;
  select value into v_tank from jsonb_array_elements(coalesce(r.tanks,'[]'::jsonb))
    where coalesce((value->>'tankNumber')::integer,(value->>'tank_number')::integer)=p_tank_number limit 1;
  if v_tank is null then raise exception 'Tank is not in frozen spray plan' using errcode='22023'; end if;
  if not exists(select 1 from jsonb_array_elements(coalesce(t.tank_sessions,'[]'::jsonb)) s
    where coalesce(s->>'id',s->>'tank_session_id')=btrim(p_tank_session_id)
      and coalesce((s->>'tankNumber')::integer,(s->>'tank_number')::integer)=p_tank_number)
  then raise exception 'Tank session does not match trip tank' using errcode='22023'; end if;
  if p_water_volume_l is not null and (p_water_volume_l < 0 or p_water_volume_l<>p_water_volume_l or p_water_volume_l in ('Infinity'::double precision,'-Infinity'::double precision)) then raise exception 'Invalid actual water' using errcode='22023'; end if;
  if not public.validate_spray_tank_actual_chemicals_v1(p_chemicals,v_tank,t.vineyard_id) then raise exception 'Invalid actual chemicals' using errcode='22023'; end if;
  select coalesce(nullif(btrim(p.full_name),''),nullif(btrim(p.email),''),'VineTrack user') into actor_name from public.profiles p where p.id=auth.uid();
  actor_name := coalesce(actor_name,'VineTrack user');

  select * into a from public.spray_tank_actuals where trip_id=t.id and tank_session_id=btrim(p_tank_session_id) for update;
  if exists(select 1 from public.spray_tank_actual_amendments where operation_id=p_operation_id and trip_id=t.id and spray_tank_actual_id=p_actual_id) then
    return jsonb_build_object('actual',to_jsonb(a),'amendments',public.spray_actual_amendments_v1(t.id));
  elsif exists(select 1 from public.spray_tank_actual_amendments where operation_id=p_operation_id) then
    raise exception 'Operation ID already belongs to another correction' using errcode='22023';
  end if;
  if a.id is null then
    if p_expected_version<>0 then raise exception 'Actual usage version conflict' using errcode='40001'; end if;
    old_water:=null; old_chems:='[]'::jsonb; new_version:=1;
    insert into public.spray_tank_actuals(id,vineyard_id,spray_record_id,trip_id,tank_session_id,tank_number,water_volume_l,chemicals,confirmed_at,confirmed_by,created_by,updated_by,client_updated_at,correction_version,last_corrected_at)
    values(p_actual_id,t.vineyard_id,r.id,t.id,btrim(p_tank_session_id),p_tank_number,p_water_volume_l,p_chemicals,now_at,auth.uid(),auth.uid(),auth.uid(),now_at,new_version,now_at) returning * into a;
  else
    if a.id<>p_actual_id or a.spray_record_id<>r.id or a.tank_number<>p_tank_number then raise exception 'Actual usage identity mismatch' using errcode='22023'; end if;
    if a.correction_version<>p_expected_version then raise exception 'Actual usage version conflict' using errcode='40001'; end if;
    old_water:=a.water_volume_l; old_chems:=a.chemicals;
    if old_water is not distinct from p_water_volume_l and old_chems=p_chemicals then
      return jsonb_build_object('actual',to_jsonb(a),'amendments',public.spray_actual_amendments_v1(t.id));
    end if;
    new_version:=a.correction_version+1;
    update public.spray_tank_actuals set water_volume_l=p_water_volume_l,chemicals=p_chemicals,
      updated_by=auth.uid(),client_updated_at=now_at,correction_version=new_version,last_corrected_at=now_at
      where id=a.id returning * into a;
  end if;

  if old_water is distinct from p_water_volume_l then
    insert into public.spray_tank_actual_amendments(operation_id,vineyard_id,trip_id,spray_record_id,spray_tank_actual_id,tank_number,field_name,change_kind,previous_value,new_value,previous_unit,new_unit,revision,edited_by,editor_name,edited_at)
    values(p_operation_id,t.vineyard_id,t.id,r.id,a.id,p_tank_number,'actualWaterLitres',
      case when old_water is null and p_water_volume_l is not null then 'initialEntry' when p_water_volume_l is null then 'cleared' when p_water_volume_l=0 then 'explicitZero' else 'correction' end,
      case when old_water is null then null else to_jsonb(old_water) end,case when p_water_volume_l is null then null else to_jsonb(p_water_volume_l) end,'L','L',new_version,auth.uid(),actor_name,now_at);
  end if;
  for chem_id in select distinct id from (
    select (x->>'id')::uuid id from jsonb_array_elements(old_chems) x union
    select (x->>'id')::uuid id from jsonb_array_elements(p_chemicals) x
  ) q loop
    select value into old_c from jsonb_array_elements(old_chems) where (value->>'id')::uuid=chem_id;
    select value into new_c from jsonb_array_elements(p_chemicals) where (value->>'id')::uuid=chem_id;
    if old_c is distinct from new_c then
      kind:=case when new_c is null then 'removed' when old_c is null and coalesce(new_c->>'usageKind','additional')='substitution' then 'substitution'
        when old_c is null then 'addition' when (new_c->>'actualAmountBase')::double precision=0 then 'explicitZero' else 'correction' end;
      insert into public.spray_tank_actual_amendments(operation_id,vineyard_id,trip_id,spray_record_id,spray_tank_actual_id,tank_number,chemical_actual_id,planned_chemical_id,saved_chemical_id,field_name,change_kind,previous_value,new_value,previous_unit,new_unit,revision,edited_by,editor_name,edited_at)
      values(p_operation_id,t.vineyard_id,t.id,r.id,a.id,p_tank_number,chem_id,
        coalesce(nullif(new_c->>'plannedChemicalId',''),nullif(old_c->>'plannedChemicalId',''))::uuid,
        coalesce(nullif(new_c->>'savedChemicalId',''),nullif(old_c->>'savedChemicalId',''))::uuid,
        'actualChemical',kind,old_c,new_c,old_c->>'unit',new_c->>'unit',new_version,auth.uid(),actor_name,now_at);
    end if;
    old_c:=null; new_c:=null;
  end loop;
  return jsonb_build_object('actual',to_jsonb(a),'amendments',public.spray_actual_amendments_v1(t.id));
end $fn$;

-- Old offline confirmations may create new rows, but can never overwrite a server-corrected row.
create or replace function public.upsert_spray_tank_actual(
  p_id uuid,p_vineyard_id uuid,p_spray_record_id uuid,p_trip_id uuid,p_tank_session_id text,p_tank_number integer,
  p_water_volume_l double precision,p_chemicals jsonb,p_confirmed_at timestamptz,p_client_updated_at timestamptz
) returns public.spray_tank_actuals language plpgsql security definer set search_path=public as $fn$
declare v_result public.spray_tank_actuals;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.has_vineyard_role(p_vineyard_id,array['owner','manager','supervisor','operator']) then raise exception 'Insufficient operational access'; end if;
  if p_id is null or p_trip_id is null or p_spray_record_id is null or p_tank_session_id is null or p_tank_number<1
    or p_water_volume_l<0 or p_water_volume_l<>p_water_volume_l or p_water_volume_l in ('Infinity'::double precision,'-Infinity'::double precision)
    or not public.validate_spray_tank_actual_chemicals(p_chemicals) then raise exception 'Invalid actual tank use'; end if;
  insert into public.spray_tank_actuals(id,vineyard_id,spray_record_id,trip_id,tank_session_id,tank_number,water_volume_l,chemicals,confirmed_at,confirmed_by,created_by,updated_by,client_updated_at)
  values(p_id,p_vineyard_id,p_spray_record_id,p_trip_id,btrim(p_tank_session_id),p_tank_number,p_water_volume_l,p_chemicals,p_confirmed_at,auth.uid(),auth.uid(),auth.uid(),p_client_updated_at)
  on conflict(trip_id,tank_session_id) do update set water_volume_l=excluded.water_volume_l,chemicals=excluded.chemicals,confirmed_at=excluded.confirmed_at,client_updated_at=excluded.client_updated_at,updated_by=auth.uid(),deleted_at=null
  where spray_tank_actuals.correction_version=0 and excluded.client_updated_at>=spray_tank_actuals.client_updated_at returning * into v_result;
  if v_result.id is null then select * into v_result from public.spray_tank_actuals where trip_id=p_trip_id and tank_session_id=btrim(p_tank_session_id); end if;
  return v_result;
end $fn$;

-- Canonical tanks now retain frozen planned lines and append genuinely actual-only/substituted products.
create or replace function public.spray_report_tanks_v1(p_planned jsonb,p_trip_id uuid)
returns jsonb language plpgsql stable set search_path=public as $fn$
declare result jsonb:='[]'; t jsonb; c jsonb; a public.spray_tank_actuals; chems jsonb; ac jsonb; candidate jsonb;
  matches jsonb[]; planned_id text; saved_id text; source text; actual_id text;
begin
  for t in select value from jsonb_array_elements(coalesce(p_planned,'[]'::jsonb)) loop
    select * into a from public.spray_tank_actuals x where x.trip_id=p_trip_id and x.deleted_at is null
      and x.tank_number=coalesce((t->>'tankNumber')::int,(t->>'tank_number')::int)
      order by x.correction_version desc,x.client_updated_at desc limit 1;
    chems:='[]';
    for c in select value from jsonb_array_elements(coalesce(t->'chemicals','[]'::jsonb)) loop
      planned_id:=coalesce(c->>'id',c->>'chemicalId'); saved_id:=coalesce(c->>'savedChemicalId',c->>'saved_chemical_id');
      ac:=null; source:='notRecorded'; matches:=array[]::jsonb[];
      if a.id is not null then
        select array_agg(x) into matches from jsonb_array_elements(a.chemicals) x where x->>'plannedChemicalId'=planned_id;
        if cardinality(matches)=1 then ac:=matches[1];source:='plannedChemicalId';
        elsif cardinality(matches)>1 then source:='ambiguous';
        elsif saved_id is not null then
          select array_agg(x) into matches from jsonb_array_elements(a.chemicals) x where x->>'savedChemicalId'=saved_id and coalesce(x->>'usageKind','planned')='planned';
          if cardinality(matches)=1 then ac:=matches[1];source:='savedChemicalId';elsif cardinality(matches)>1 then source:='ambiguous';end if;
        end if;
        if ac is null and source='notRecorded' then
          select array_agg(x) into matches from jsonb_array_elements(a.chemicals) x
            where lower(btrim(x->>'name'))=lower(btrim(coalesce(c->>'name',''))) and lower(btrim(x->>'unit'))=lower(btrim(coalesce(c->>'unit','')))
              and coalesce(x->>'usageKind','planned')='planned';
          if cardinality(matches)=1 then ac:=matches[1];source:='nameUnit';elsif cardinality(matches)>1 then source:='ambiguous';end if;
        end if;
      end if;
      chems:=chems||jsonb_build_array(jsonb_build_object(
        'actualChemicalId',ac->>'id','plannedChemicalId',planned_id,'savedChemicalId',saved_id,
        'replacesPlannedChemicalId',null,'usageKind','planned','name',coalesce(c->>'name','Unnamed chemical'),
        'unit',coalesce(c->>'unit','Litres'),'plannedAmountBase',coalesce((c->>'volumePerTank')::numeric,(c->>'volume_per_tank')::numeric,0),
        'actualAmountBase',case when ac is null then null else (ac->>'actualAmountBase')::numeric end,'matchSource',source));
    end loop;
    if a.id is not null then
      for candidate in select value from jsonb_array_elements(a.chemicals) loop
        actual_id:=candidate->>'id';
        if not exists(select 1 from jsonb_array_elements(chems) x where x->>'actualChemicalId'=actual_id) then
          chems:=chems||jsonb_build_array(jsonb_build_object(
            'actualChemicalId',actual_id,'plannedChemicalId',null,'savedChemicalId',candidate->>'savedChemicalId',
            'replacesPlannedChemicalId',candidate->>'replacesPlannedChemicalId',
            'usageKind',coalesce(nullif(candidate->>'usageKind',''),'additional'),'name',candidate->>'name','unit',candidate->>'unit',
            'plannedAmountBase',null,'actualAmountBase',(candidate->>'actualAmountBase')::numeric,'matchSource','actualOnly'));
        end if;
      end loop;
    end if;
    result:=result||jsonb_build_array(jsonb_build_object(
      'tankNumber',coalesce((t->>'tankNumber')::int,(t->>'tank_number')::int),
      'actualId',a.id,'actualVersion',coalesce(a.correction_version,0),
      'plannedWaterLitres',coalesce((t->>'waterVolume')::numeric,(t->>'water_volume')::numeric,0),
      'actualWaterLitres',a.water_volume_l,'chemicals',chems));
  end loop;
  return result;
end $fn$;

-- Preserve SQL 225's validated body and add amendment history without competing report logic.
alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_actual_amendments_v1;
create or replace function public.get_spray_report_v1(p_trip_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare payload jsonb;
begin
  payload:=public.get_spray_report_v1_pre_actual_amendments_v1(p_trip_id);
  payload:=jsonb_set(payload,'{schemaVersion}',to_jsonb('1.1'::text),true);
  payload:=jsonb_set(payload,'{amendments}',public.spray_actual_amendments_v1(p_trip_id),true);
  payload:=jsonb_set(payload,'{actualChemicalTotals}',coalesce((
    select jsonb_agg(jsonb_build_object('identityKey',identity_key,'name',name,'unit',unit,'actualAmountBase',total) order by lower(name),unit)
    from (
      select coalesce(c->>'savedChemicalId',lower(btrim(c->>'name'))||'|'||lower(c->>'unit')) identity_key,
        min(c->>'name') name,c->>'unit' unit,sum((c->>'actualAmountBase')::numeric) total
      from jsonb_array_elements(payload->'tanks') t cross join lateral jsonb_array_elements(t->'chemicals') c
      where c->'actualAmountBase' <> 'null'::jsonb
      group by coalesce(c->>'savedChemicalId',lower(btrim(c->>'name'))||'|'||lower(c->>'unit')),c->>'unit'
    ) totals
  ),'[]'::jsonb),true);
  return payload;
end $fn$;

revoke all on function public.get_spray_report_v1_pre_actual_amendments_v1(uuid) from public,anon,authenticated;
revoke all on function public.get_spray_report_v1(uuid) from public,anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;
revoke all on function public.spray_report_tanks_v1(jsonb,uuid) from public,anon,authenticated;

revoke all on function public.correct_spray_tank_actual_v1(uuid,uuid,uuid,uuid,text,integer,bigint,double precision,jsonb) from public,anon,service_role;
grant execute on function public.correct_spray_tank_actual_v1(uuid,uuid,uuid,uuid,text,integer,bigint,double precision,jsonb) to authenticated;
revoke all on function public.spray_actual_amendments_v1(uuid) from public,anon,authenticated;
revoke all on function public.validate_spray_tank_actual_chemicals_v1(jsonb,jsonb,uuid) from public,anon,authenticated;

commit;
