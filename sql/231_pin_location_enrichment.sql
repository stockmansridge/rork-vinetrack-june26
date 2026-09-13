-- 231_pin_location_enrichment.sql
-- Durable, independently uploaded capture evidence plus leased server resolution.
-- Additive only: no historical pin is automatically queued or rewritten.

create extension if not exists pgcrypto;

create table if not exists public.pin_capture_evidence (
  pin_id uuid not null,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  evidence_revision integer not null check (evidence_revision > 0),
  resolver_version text not null default 'server-geometry-v2',
  captured_at timestamptz not null,
  location_observed_at timestamptz not null,
  raw_latitude double precision not null check (raw_latitude between -90 and 90),
  raw_longitude double precision not null check (raw_longitude between -180 and 180),
  horizontal_accuracy_m double precision null check (horizontal_accuracy_m >= 0),
  heading_degrees double precision null check (heading_degrees >= 0 and heading_degrees <= 360),
  heading_source text null,
  heading_observed_at timestamptz null,
  pressed_side text null check (pressed_side in ('Left','Right')),
  trip_id uuid null,
  capture_user_id uuid null,
  capture_button_name text not null default '',
  capture_mode text not null default '',
  supported_paddock_id uuid null,
  supported_driving_row numeric null,
  supported_pin_row numeric null,
  supported_pin_side text null check (supported_pin_side in ('Left','Right')),
  supported_snapped_latitude double precision null,
  supported_snapped_longitude double precision null,
  supported_along_row_distance_m numeric null,
  aisle_lock jsonb null,
  observations jsonb not null default '[]'::jsonb,
  capture_provenance jsonb not null default '{}'::jsonb,
  geometry_revision text null,
  geometry_hash text null,
  created_by uuid not null default auth.uid(),
  received_at timestamptz not null default now(),
  payload_hash text null,
  primary key (pin_id, evidence_revision),
  constraint pin_capture_observations_bounded check (
    jsonb_typeof(observations) = 'array' and jsonb_array_length(observations) <= 16
  )
);

alter table public.pin_capture_evidence alter column horizontal_accuracy_m drop not null;
alter table public.pin_capture_evidence add column if not exists capture_user_id uuid null;
alter table public.pin_capture_evidence add column if not exists capture_button_name text not null default '';
alter table public.pin_capture_evidence add column if not exists capture_mode text not null default '';
alter table public.pin_capture_evidence add column if not exists payload_hash text null;
alter table public.pin_capture_evidence drop constraint if exists pin_capture_evidence_pin_id_fkey;
alter table public.pin_capture_evidence enable row level security;
drop policy if exists pin_capture_evidence_member_select on public.pin_capture_evidence;
create policy pin_capture_evidence_member_select on public.pin_capture_evidence
for select to authenticated using (public.is_vineyard_member(vineyard_id));
drop policy if exists pin_capture_evidence_member_insert on public.pin_capture_evidence;
create policy pin_capture_evidence_member_insert on public.pin_capture_evidence
for insert to authenticated with check (
  created_by = auth.uid() and public.is_vineyard_member(vineyard_id)
);
revoke update, delete, truncate on public.pin_capture_evidence from anon, authenticated;
grant select, insert on public.pin_capture_evidence to authenticated;

-- Insert-or-verify makes response-loss retries safe without granting UPDATE.
create or replace function public.insert_pin_capture_evidence(p_payload jsonb)
returns text language plpgsql security definer set search_path=public as $$
declare v_existing public.pin_capture_evidence%rowtype; v_hash text;
  v_pin uuid:=(p_payload->>'pin_id')::uuid; v_revision integer:=(p_payload->>'evidence_revision')::integer;
  v_vineyard uuid:=(p_payload->>'vineyard_id')::uuid; v_capture_user uuid:=nullif(p_payload->>'capture_user_id','')::uuid;
begin
  if auth.uid() is null or not public.is_vineyard_member(v_vineyard) then raise exception 'FORBIDDEN'; end if;
  if v_capture_user is distinct from auth.uid() then raise exception 'CAPTURE_USER_MISMATCH'; end if;
  if jsonb_typeof(coalesce(p_payload->'observations','[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_payload->'observations','[]'::jsonb))>16 then raise exception 'OBSERVATIONS_INVALID'; end if;
  v_hash:=encode(digest((p_payload - 'isUploaded' - 'uploaded')::text,'sha256'),'hex');
  select * into v_existing from public.pin_capture_evidence where pin_id=v_pin and evidence_revision=v_revision;
  if found then return case when v_existing.payload_hash=v_hash then 'identical' else 'conflict' end; end if;
  insert into public.pin_capture_evidence(
    pin_id,vineyard_id,evidence_revision,resolver_version,captured_at,location_observed_at,raw_latitude,raw_longitude,horizontal_accuracy_m,
    heading_degrees,heading_source,heading_observed_at,pressed_side,trip_id,capture_user_id,capture_button_name,capture_mode,
    supported_paddock_id,supported_driving_row,supported_pin_row,supported_pin_side,supported_snapped_latitude,supported_snapped_longitude,
    supported_along_row_distance_m,aisle_lock,observations,capture_provenance,geometry_revision,geometry_hash,created_by,payload_hash)
  values(
    v_pin,v_vineyard,v_revision,coalesce(p_payload->>'resolver_version','server-geometry-v3'),(p_payload->>'captured_at')::timestamptz,
    (p_payload->>'location_observed_at')::timestamptz,(p_payload->>'raw_latitude')::double precision,(p_payload->>'raw_longitude')::double precision,
    nullif(p_payload->>'horizontal_accuracy_m','')::double precision,nullif(p_payload->>'heading_degrees','')::double precision,p_payload->>'heading_source',
    nullif(p_payload->>'heading_observed_at','')::timestamptz,p_payload->>'pressed_side',nullif(p_payload->>'trip_id','')::uuid,v_capture_user,
    p_payload->>'capture_button_name',p_payload->>'capture_mode',nullif(p_payload->>'supported_paddock_id','')::uuid,
    nullif(p_payload->>'supported_driving_row','')::numeric,nullif(p_payload->>'supported_pin_row','')::numeric,p_payload->>'supported_pin_side',
    nullif(p_payload->>'supported_snapped_latitude','')::double precision,nullif(p_payload->>'supported_snapped_longitude','')::double precision,
    nullif(p_payload->>'supported_along_row_distance_m','')::numeric,p_payload->'aisle_lock',coalesce(p_payload->'observations','[]'::jsonb),
    coalesce(p_payload->'capture_provenance','{}'::jsonb),p_payload->>'geometry_revision',p_payload->>'geometry_hash',auth.uid(),v_hash);
  return 'inserted';
exception when unique_violation then
  select * into v_existing from public.pin_capture_evidence where pin_id=v_pin and evidence_revision=v_revision;
  return case when v_existing.payload_hash=v_hash then 'identical' else 'conflict' end;
end $$;
revoke all on function public.insert_pin_capture_evidence(jsonb) from public,anon;
grant execute on function public.insert_pin_capture_evidence(jsonb) to authenticated;

alter table public.pins
  add column if not exists location_enrichment_status text null,
  add column if not exists location_enrichment_revision integer null,
  add column if not exists location_resolver_version text null,
  add column if not exists location_enriched_at timestamptz null,
  add column if not exists location_confirmation_revision integer null,
  add column if not exists location_confirmed_at timestamptz null,
  add column if not exists location_confirmed_by uuid null;

-- Forward geometry history. The initial snapshot begins at deployment time and
-- is never claimed as evidence for captures made before deployment.
create table if not exists public.pin_location_geometry_history (
  id uuid primary key default gen_random_uuid(),
  paddock_id uuid not null,
  vineyard_id uuid not null,
  valid_from timestamptz not null default now(),
  valid_to timestamptz null,
  geometry_hash text not null,
  polygon_points jsonb not null,
  rows jsonb not null,
  row_width double precision null,
  recorded_at timestamptz not null default now(),
  unique (paddock_id, valid_from)
);
alter table public.pin_location_geometry_history add column if not exists row_width double precision null;
revoke all on public.pin_location_geometry_history from anon, authenticated;

create or replace function public.pin_geometry_identity(points jsonb, rows jsonb)
returns text language sql immutable as $$
select 'pin-geometry-v1:' || encode(digest(
  'pin-geometry-v1|p=' || coalesce((
    select string_agg(to_char(coalesce((p->>'latitude')::numeric,(p->>'lat')::numeric),'FM999999990.00000000') || ',' ||
                      to_char(coalesce((p->>'longitude')::numeric,(p->>'lng')::numeric),'FM999999990.00000000'),';' order by ord)
    from jsonb_array_elements(coalesce(points,'[]'::jsonb)) with ordinality x(p,ord)
  ),'') || '|r=' || coalesce((
    select string_agg((r->>'number') || ':' ||
      to_char(coalesce((coalesce(r->'startPoint',r->'start_point')->>'latitude')::numeric,(coalesce(r->'startPoint',r->'start_point')->>'lat')::numeric),'FM999999990.00000000') || ',' ||
      to_char(coalesce((coalesce(r->'startPoint',r->'start_point')->>'longitude')::numeric,(coalesce(r->'startPoint',r->'start_point')->>'lng')::numeric),'FM999999990.00000000') || '>' ||
      to_char(coalesce((coalesce(r->'endPoint',r->'end_point')->>'latitude')::numeric,(coalesce(r->'endPoint',r->'end_point')->>'lat')::numeric),'FM999999990.00000000') || ',' ||
      to_char(coalesce((coalesce(r->'endPoint',r->'end_point')->>'longitude')::numeric,(coalesce(r->'endPoint',r->'end_point')->>'lng')::numeric),'FM999999990.00000000'),';' order by (r->>'number')::numeric)
    from jsonb_array_elements(coalesce(rows,'[]'::jsonb)) x(r)
  ),''), 'sha256'),'hex')
$$;

create or replace function public.snapshot_pin_location_geometry()
returns trigger language plpgsql security definer set search_path=public as $$
declare h text; changed_at timestamptz := now();
begin
  h := public.pin_geometry_identity(new.polygon_points,new.rows);
  if tg_op='UPDATE' and public.pin_geometry_identity(old.polygon_points,old.rows) = h then
    return new;
  end if;
  update public.pin_location_geometry_history set valid_to=changed_at
  where paddock_id=new.id and valid_to is null;
  insert into public.pin_location_geometry_history(paddock_id,vineyard_id,valid_from,geometry_hash,polygon_points,rows,row_width)
  values(new.id,new.vineyard_id,changed_at,h,coalesce(new.polygon_points,'[]'::jsonb),coalesce(new.rows,'[]'::jsonb),new.row_width);
  return new;
end $$;

drop trigger if exists snapshot_pin_location_geometry_change on public.paddocks;
create trigger snapshot_pin_location_geometry_change
after insert or update of polygon_points,rows,row_width on public.paddocks
for each row execute function public.snapshot_pin_location_geometry();

insert into public.pin_location_geometry_history(paddock_id,vineyard_id,valid_from,geometry_hash,polygon_points,rows,row_width)
select p.id,p.vineyard_id,now(),public.pin_geometry_identity(p.polygon_points,p.rows),coalesce(p.polygon_points,'[]'::jsonb),coalesce(p.rows,'[]'::jsonb),p.row_width
from public.paddocks p
where not exists(select 1 from public.pin_location_geometry_history h where h.paddock_id=p.id);

create table if not exists public.pin_location_enrichment_queue (
  pin_id uuid not null,
  evidence_revision integer not null,
  resolver_version text not null,
  available_at timestamptz not null default now(),
  lease_token uuid null,
  lease_expires_at timestamptz null,
  attempts integer not null default 0,
  last_error text null,
  terminal_at timestamptz null,
  primary key (pin_id, evidence_revision, resolver_version)
);
alter table public.pin_location_enrichment_queue add column if not exists terminal_at timestamptz null;
revoke all on public.pin_location_enrichment_queue from anon, authenticated;

create table if not exists public.pin_location_enrichment_audit (
  id uuid primary key default gen_random_uuid(),
  pin_id uuid not null,
  evidence_revision integer not null,
  resolver_version text not null,
  lease_token uuid null,
  outcome text not null,
  before_placement jsonb not null default '{}'::jsonb,
  after_placement jsonb not null default '{}'::jsonb,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.pin_location_enrichment_audit add column if not exists lease_token uuid null;
alter table public.pin_location_enrichment_audit add column if not exists detail jsonb not null default '{}'::jsonb;
revoke all on public.pin_location_enrichment_audit from anon, authenticated;

create or replace function public.enqueue_pin_location_enrichment()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.pins p where p.id=new.pin_id and p.vineyard_id=new.vineyard_id) then
    insert into public.pin_location_enrichment_queue(pin_id,evidence_revision,resolver_version)
    values(new.pin_id,new.evidence_revision,new.resolver_version) on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists enqueue_pin_location_enrichment_after_evidence on public.pin_capture_evidence;
create trigger enqueue_pin_location_enrichment_after_evidence after insert on public.pin_capture_evidence
for each row execute function public.enqueue_pin_location_enrichment();

create or replace function public.enqueue_existing_pin_capture_evidence()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.pin_location_enrichment_queue(pin_id,evidence_revision,resolver_version)
  select e.pin_id,e.evidence_revision,e.resolver_version from public.pin_capture_evidence e
  where e.pin_id=new.id and e.vineyard_id=new.vineyard_id on conflict do nothing;
  return new;
end $$;
drop trigger if exists enqueue_existing_pin_evidence_after_pin on public.pins;
create trigger enqueue_existing_pin_evidence_after_pin after insert on public.pins
for each row execute function public.enqueue_existing_pin_capture_evidence();

-- Ray-casting containment over the persisted capture-time polygon JSON.
create or replace function public.pin_point_in_polygon(lat double precision, lon double precision, points jsonb)
returns boolean language plpgsql immutable as $$
declare i integer; j integer; n integer; inside boolean:=false; xi double precision; yi double precision; xj double precision; yj double precision;
begin
  if jsonb_typeof(points)<>'array' or jsonb_array_length(points)<3 then return false; end if;
  n:=jsonb_array_length(points); j:=n-1;
  for i in 0..n-1 loop
    xi:=coalesce((points->i->>'longitude')::double precision,(points->i->>'lng')::double precision);
    yi:=coalesce((points->i->>'latitude')::double precision,(points->i->>'lat')::double precision);
    xj:=coalesce((points->j->>'longitude')::double precision,(points->j->>'lng')::double precision);
    yj:=coalesce((points->j->>'latitude')::double precision,(points->j->>'lat')::double precision);
    if ((yi>lat)<>(yj>lat)) and lon < (xj-xi)*(lat-yi)/nullif(yj-yi,0)+xi then inside:=not inside; end if;
    j:=i;
  end loop;
  return inside;
exception when others then return false;
end $$;

create or replace function public.resolve_pin_row_geometry(
  rows jsonb, polygon jsonb, paddock_id uuid, lat double precision, lon double precision,
  accuracy_m double precision, heading double precision, heading_observed_at timestamptz,
  captured_at timestamptz, pressed_side text, aisle_lock jsonb, observations jsonb, row_width double precision)
returns jsonb language plpgsql immutable as $$
declare aisle numeric; first_row jsonb; second_row jsonb; r jsonb; o jsonb; s jsonb; e jsonb;
  lat0 double precision:=radians(lat); heading_used double precision:=heading; movement_count integer:=0; support_count integer:=0;
  x1 double precision; y1 double precision; x2 double precision; y2 double precision; dx double precision; dy double precision; len2 double precision;
  t double precision; px double precision; py double precision; d1 double precision; d2 double precision; width double precision;
  first_projection jsonb; second_projection jsonb; selected jsonb; opposite jsonb; side_label text; cross_side double precision;
begin
  if pressed_side not in ('Left','Right') or jsonb_typeof(rows)<>'array' or jsonb_typeof(observations)<>'array' then return null; end if;
  if aisle_lock is null or (aisle_lock->>'paddockId')::uuid<>paddock_id or (aisle_lock->>'supportingObservations')::integer<3 then return null; end if;
  if captured_at-(aisle_lock->>'confirmedAt')::timestamptz not between interval '0 seconds' and interval '20 seconds' then return null; end if;
  aisle:=(aisle_lock->>'aisleNumber')::numeric;
  select a.r,b.r into first_row,second_row from
    (select value r,row_number() over(order by (value->>'number')::numeric) n from jsonb_array_elements(rows)) a
    join (select value r,row_number() over(order by (value->>'number')::numeric) n from jsonb_array_elements(rows)) b on b.n=a.n+1
    where abs((((a.r->>'number')::numeric+(b.r->>'number')::numeric)/2)-aisle)<0.01 limit 1;
  if first_row is null or second_row is null then return null; end if;

  -- Heading is fresh device evidence, or independently supported fresh moving
  -- course evidence from the bounded pre-tap history; never upload-time state.
  if heading_used is not null and (heading_observed_at is null or captured_at-heading_observed_at not between interval '0 seconds' and interval '5 seconds') then heading_used:=null; end if;
  if heading_used is null then
    select count(*),avg((x->>'courseDegrees')::double precision) into movement_count,heading_used
    from jsonb_array_elements(observations) x
    where (x->>'speedMps')::double precision>=0.5 and (x->>'observedAt')::timestamptz<=captured_at
      and captured_at-(x->>'observedAt')::timestamptz<=interval '5 seconds' and x ? 'courseDegrees';
    if movement_count<2 then heading_used:=null; end if;
  end if;
  if heading_used is null or accuracy_m is null or accuracy_m<0 then return null; end if;

  -- Every supporting observation must be in the block, within both row extents,
  -- and geometrically between this physically adjacent pair at plausible width.
  for o in select value from jsonb_array_elements(observations) order by value->>'observedAt' desc limit 16 loop
    if (o->>'observedAt')::timestamptz>captured_at or captured_at-(o->>'observedAt')::timestamptz>interval '20 seconds'
       or not public.pin_point_in_polygon((o->>'latitude')::double precision,(o->>'longitude')::double precision,polygon) then continue; end if;
    d1:=null; d2:=null;
    for r in select value from jsonb_array_elements(jsonb_build_array(first_row,second_row)) loop
      s:=coalesce(r->'startPoint',r->'start_point'); e:=coalesce(r->'endPoint',r->'end_point');
      x1:=(coalesce((s->>'longitude')::double precision,(s->>'lng')::double precision)-(o->>'longitude')::double precision)*111320*cos(radians((o->>'latitude')::double precision));
      y1:=(coalesce((s->>'latitude')::double precision,(s->>'lat')::double precision)-(o->>'latitude')::double precision)*111320;
      x2:=(coalesce((e->>'longitude')::double precision,(e->>'lng')::double precision)-(o->>'longitude')::double precision)*111320*cos(radians((o->>'latitude')::double precision));
      y2:=(coalesce((e->>'latitude')::double precision,(e->>'lat')::double precision)-(o->>'latitude')::double precision)*111320;
      dx:=x2-x1; dy:=y2-y1; len2:=dx*dx+dy*dy; if len2<0.01 then continue; end if;
      t:=-(x1*dx+y1*dy)/len2; if t<0 or t>1 then continue; end if;
      px:=x1+t*dx; py:=y1+t*dy;
      if d1 is null then d1:=sqrt(px*px+py*py); else d2:=sqrt(px*px+py*py); end if;
    end loop;
    if d1 is not null and d2 is not null then
      width:=d1+d2;
      if width between 1.5 and coalesce(nullif(row_width,0)*2.5,12) and coalesce((o->>'horizontalAccuracyM')::double precision,1e9)<width then support_count:=support_count+1; end if;
    end if;
  end loop;
  if support_count<3 then return null; end if;

  -- Resolve the frozen raw fix against exactly the validated adjacent pair.
  for r in select value from jsonb_array_elements(jsonb_build_array(first_row,second_row)) loop
    s:=coalesce(r->'startPoint',r->'start_point'); e:=coalesce(r->'endPoint',r->'end_point');
    x1:=(coalesce((s->>'longitude')::double precision,(s->>'lng')::double precision)-lon)*111320*cos(lat0);
    y1:=(coalesce((s->>'latitude')::double precision,(s->>'lat')::double precision)-lat)*111320;
    x2:=(coalesce((e->>'longitude')::double precision,(e->>'lng')::double precision)-lon)*111320*cos(lat0);
    y2:=(coalesce((e->>'latitude')::double precision,(e->>'lat')::double precision)-lat)*111320;
    dx:=x2-x1; dy:=y2-y1; len2:=dx*dx+dy*dy; t:=-(x1*dx+y1*dy)/len2; if t<0 or t>1 then return null; end if;
    px:=x1+t*dx; py:=y1+t*dy; cross_side:=sin(radians(heading_used))*py-cos(radians(heading_used))*px;
    side_label:=case when cross_side>=0 then 'Left' else 'Right' end;
    selected:=jsonb_build_object('row',(r->>'number')::numeric,'snapped_latitude',lat+py/111320,'snapped_longitude',lon+px/(111320*cos(lat0)),'along_m',t*sqrt(len2));
    if side_label=pressed_side then first_projection:=selected; else second_projection:=selected; end if;
  end loop;
  if first_projection is null or second_projection is null then return null; end if;
  return first_projection || jsonb_build_object('driving_row',aisle,'pin_side',pressed_side,'support_count',support_count,'heading_used',heading_used);
exception when others then return null;
end $$;

create or replace function public.pin_location_placement_json(p public.pins)
returns jsonb language sql immutable as $$
select jsonb_build_object(
  'paddock_id',p.paddock_id,'driving_row_number',p.driving_row_number,
  'pin_row_number',p.pin_row_number,'pin_side',p.pin_side,
  'snapped_latitude',p.snapped_latitude,'snapped_longitude',p.snapped_longitude,
  'along_row_distance_m',p.along_row_distance_m,'snapped_to_row',p.snapped_to_row,
  'location_enrichment_status',p.location_enrichment_status,
  'location_resolver_version',p.location_resolver_version,
  'sync_version',p.sync_version,
  'location_enrichment_revision',p.location_enrichment_revision,
  'location_confirmation_revision',p.location_confirmation_revision
) $$;

create or replace function public.claim_pin_location_enrichment(p_limit integer default 20,p_lease_seconds integer default 90)
returns setof public.pin_location_enrichment_queue language plpgsql security definer set search_path=public as $$
begin
  if auth.role()<>'service_role' then raise exception 'service role required'; end if;
  with terminal as (
    update public.pin_location_enrichment_queue q set terminal_at=now(),lease_token=null,lease_expires_at=null,last_error='final lease expired'
    where q.terminal_at is null and q.attempts>=8 and q.lease_expires_at<now() returning q.*
  ) insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,lease_token,outcome,detail)
    select pin_id,evidence_revision,resolver_version,lease_token,'technical_failure_terminal',jsonb_build_object('attempts',attempts,'reason','final_lease_expired') from terminal;
  return query with due as (
    select q.pin_id,q.evidence_revision,q.resolver_version
    from public.pin_location_enrichment_queue q
    where q.available_at<=now() and q.terminal_at is null
      and (q.lease_expires_at is null or q.lease_expires_at<now()) and q.attempts<8
    order by q.available_at,q.pin_id for update skip locked limit least(greatest(p_limit,1),50)
  ) update public.pin_location_enrichment_queue q set
    lease_token=gen_random_uuid(),lease_expires_at=now()+make_interval(secs=>least(greatest(p_lease_seconds,15),300)),attempts=q.attempts+1
  from due where (q.pin_id,q.evidence_revision,q.resolver_version)=(due.pin_id,due.evidence_revision,due.resolver_version)
  returning q.*;
end $$;
revoke all on function public.claim_pin_location_enrichment(integer,integer) from public,anon,authenticated;
grant execute on function public.claim_pin_location_enrichment(integer,integer) to service_role;

create or replace function public.fail_pin_location_enrichment(p_pin_id uuid,p_evidence_revision integer,p_resolver_version text,p_lease_token uuid,p_error text)
returns text language plpgsql security definer set search_path=public as $$
declare q public.pin_location_enrichment_queue%rowtype; outcome text;
begin
  if auth.role()<>'service_role' then raise exception 'service role required'; end if;
  select * into q from public.pin_location_enrichment_queue where pin_id=p_pin_id and evidence_revision=p_evidence_revision and resolver_version=p_resolver_version for update;
  if not found or q.lease_token is distinct from p_lease_token or q.lease_expires_at<=now() then return 'stale_lease'; end if;
  outcome:=case when q.attempts>=8 then 'technical_failure_terminal' else 'technical_failure_retry' end;
  update public.pin_location_enrichment_queue set lease_token=null,lease_expires_at=null,last_error=left(p_error,500),
    available_at=now()+make_interval(secs=>least(3600,30*power(2,least(attempts,7))::integer)),
    terminal_at=case when attempts>=8 then now() else null end
  where pin_id=p_pin_id and evidence_revision=p_evidence_revision and resolver_version=p_resolver_version;
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,lease_token,outcome,detail)
  values(p_pin_id,p_evidence_revision,p_resolver_version,p_lease_token,outcome,jsonb_build_object('error',left(p_error,500),'attempts',q.attempts));
  return outcome;
end $$;
revoke all on function public.fail_pin_location_enrichment(uuid,integer,text,uuid,text) from public,anon,authenticated;
grant execute on function public.fail_pin_location_enrichment(uuid,integer,text,uuid,text) to service_role;

create or replace function public.commit_pin_location_enrichment(p_pin_id uuid,p_evidence_revision integer,p_resolver_version text,p_lease_token uuid)
returns text language plpgsql security definer set search_path=public as $$
declare e public.pin_capture_evidence%rowtype; p public.pins%rowtype; q public.pin_location_enrichment_queue%rowtype;
  before_row jsonb:='{}'; after_row jsonb:='{}'; outcome text; candidate_count integer; g public.pin_location_geometry_history%rowtype;
  resolved_paddock uuid; resolved_row numeric; can_use_mobile_row boolean:=false; rr jsonb; candidate_placement jsonb; existing_placement jsonb;
begin
  if auth.role()<>'service_role' then raise exception 'service role required'; end if;
  select * into q from public.pin_location_enrichment_queue where pin_id=p_pin_id and evidence_revision=p_evidence_revision and resolver_version=p_resolver_version for update;
  if not found or q.lease_token is distinct from p_lease_token or q.lease_expires_at<=now() then return 'stale_lease'; end if;
  select * into e from public.pin_capture_evidence where pin_id=p_pin_id and evidence_revision=p_evidence_revision;
  select * into p from public.pins where id=p_pin_id for update;
  before_row:=coalesce(public.pin_location_placement_json(p),'{}'::jsonb);

  if e.pin_id is null then outcome:='evidence_missing';
  elsif p.id is null or p.deleted_at is not null then outcome:='deleted_or_missing';
  elsif p.vineyard_id<>e.vineyard_id then outcome:='ownership_conflict';
  elsif p.created_at is distinct from e.captured_at or abs(p.latitude-e.raw_latitude)>0.0000001 or abs(p.longitude-e.raw_longitude)>0.0000001
     or p.trip_id is distinct from e.trip_id or p.created_by is distinct from e.capture_user_id
     or coalesce(p.button_name,p.title,'')<>e.capture_button_name or coalesce(p.mode,'')<>e.capture_mode then outcome:='evidence_pin_mismatch';
  elsif p.location_confirmation_revision is not null then outcome:='user_confirmed';
  elsif p.location_enrichment_revision>p_evidence_revision
     or (p.location_enrichment_revision=p_evidence_revision and p.location_resolver_version=p_resolver_version) then outcome:='already_applied';
  else
    select count(*) into candidate_count
    from public.pin_location_geometry_history h
    where h.vineyard_id=e.vineyard_id and h.valid_from<=e.captured_at and (h.valid_to is null or h.valid_to>e.captured_at)
      and public.pin_point_in_polygon(e.raw_latitude,e.raw_longitude,h.polygon_points);
    if candidate_count=0 then outcome:='unresolved_no_capture_geometry';
    elsif candidate_count>1 then outcome:='conflict_overlapping_blocks'; resolved_paddock:=null;
    else
      select h.paddock_id into resolved_paddock from public.pin_location_geometry_history h
      where h.vineyard_id=e.vineyard_id and h.valid_from<=e.captured_at and (h.valid_to is null or h.valid_to>e.captured_at)
        and public.pin_point_in_polygon(e.raw_latitude,e.raw_longitude,h.polygon_points) limit 1;
      select * into g from public.pin_location_geometry_history h where h.paddock_id=resolved_paddock and h.valid_from<=e.captured_at and (h.valid_to is null or h.valid_to>e.captured_at) order by h.valid_from desc limit 1;
      rr:=public.resolve_pin_row_geometry(g.rows,g.polygon_points,g.paddock_id,e.raw_latitude,e.raw_longitude,e.horizontal_accuracy_m,e.heading_degrees,e.heading_observed_at,e.captured_at,e.pressed_side,e.aisle_lock,e.observations,g.row_width);
      can_use_mobile_row:=rr is not null;
      resolved_row:=case when rr is not null then (rr->>'row')::numeric else null end;
      if e.geometry_hash is not null and e.geometry_hash<>g.geometry_hash then
        outcome:='conflict_geometry_revision'; can_use_mobile_row:=false; resolved_row:=null;
      elsif rr is not null and e.supported_pin_row is not null and e.supported_pin_row<>resolved_row then
        outcome:='conflict_mobile_server_row'; can_use_mobile_row:=false; resolved_row:=null;
      else outcome:=case when can_use_mobile_row then 'resolved' else 'partial_block_only' end;
      end if;
      candidate_placement:=jsonb_build_object(
        'paddock_id',resolved_paddock,'driving_row_number',case when can_use_mobile_row then (rr->>'driving_row')::numeric else null end,
        'pin_row_number',resolved_row,'pin_side',case when can_use_mobile_row then rr->>'pin_side' else null end,
        'snapped_latitude',case when can_use_mobile_row then (rr->>'snapped_latitude')::double precision else null end,
        'snapped_longitude',case when can_use_mobile_row then (rr->>'snapped_longitude')::double precision else null end,
        'along_row_distance_m',case when can_use_mobile_row then (rr->>'along_m')::numeric else null end,'snapped_to_row',can_use_mobile_row);
      existing_placement:=jsonb_build_object('paddock_id',p.paddock_id,'driving_row_number',p.driving_row_number,'pin_row_number',p.pin_row_number,
        'pin_side',p.pin_side,'snapped_latitude',p.snapped_latitude,'snapped_longitude',p.snapped_longitude,'along_row_distance_m',p.along_row_distance_m,'snapped_to_row',p.snapped_to_row);
      if (p.driving_row_number is not null or p.pin_row_number is not null or p.pin_side is not null or p.snapped_latitude is not null or p.snapped_longitude is not null or p.along_row_distance_m is not null or p.snapped_to_row)
         and existing_placement is distinct from candidate_placement then
        outcome:='conflict_current_placement';
      elsif p.paddock_id is not null and p.paddock_id<>resolved_paddock then
        outcome:='conflict_current_placement';
      elsif outcome in ('resolved','partial_block_only') then
        update public.pins set
          paddock_id=resolved_paddock,driving_row_number=(candidate_placement->>'driving_row_number')::numeric,
          pin_row_number=(candidate_placement->>'pin_row_number')::numeric,pin_side=candidate_placement->>'pin_side',
          snapped_latitude=(candidate_placement->>'snapped_latitude')::double precision,snapped_longitude=(candidate_placement->>'snapped_longitude')::double precision,
          along_row_distance_m=(candidate_placement->>'along_row_distance_m')::numeric,snapped_to_row=(candidate_placement->>'snapped_to_row')::boolean,
          location_enrichment_status=outcome,location_enrichment_revision=p_evidence_revision,
          location_resolver_version=p_resolver_version,location_enriched_at=now(),sync_version=sync_version+1
        where id=p_pin_id and deleted_at is null and location_confirmation_revision is null;
      end if;
    end if;
  end if;
  select * into p from public.pins where id=p_pin_id;
  after_row:=coalesce(public.pin_location_placement_json(p),before_row);
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,lease_token,outcome,before_placement,after_placement,detail)
  values(p_pin_id,p_evidence_revision,p_resolver_version,p_lease_token,outcome,before_row,coalesce(after_row,before_row),jsonb_build_object('candidate_count',coalesce(candidate_count,0),'geometry_hash',g.geometry_hash));
  delete from public.pin_location_enrichment_queue where pin_id=p_pin_id and evidence_revision=p_evidence_revision and resolver_version=p_resolver_version and lease_token=p_lease_token;
  return outcome;
end $$;
revoke all on function public.commit_pin_location_enrichment(uuid,integer,text,uuid) from public,anon,authenticated;
grant execute on function public.commit_pin_location_enrichment(uuid,integer,text,uuid) to service_role;

-- Optional post-save confirmation. It is narrow, keeps the pin/evidence identity,
-- and creates a revision that older worker results cannot outrank.
create or replace function public.confirm_saved_pin_location(p_pin_id uuid,p_evidence_revision integer,p_paddock_id uuid,p_driving_row numeric,p_pin_row numeric,p_pin_side text,p_snapped_latitude double precision,p_snapped_longitude double precision,p_along_row_distance_m numeric)
returns public.pins language plpgsql security definer set search_path=public as $$
declare p public.pins%rowtype; before_row jsonb; after_row jsonb;
begin
  select * into p from public.pins where id=p_pin_id for update;
  if not found or p.deleted_at is not null then raise exception 'PIN_NOT_FOUND'; end if;
  if not public.is_vineyard_member(p.vineyard_id) then raise exception 'FORBIDDEN'; end if;
  if not exists(select 1 from public.pin_capture_evidence e where e.pin_id=p.id and e.evidence_revision=p_evidence_revision and e.vineyard_id=p.vineyard_id) then raise exception 'EVIDENCE_NOT_FOUND'; end if;
  if not exists(select 1 from public.paddocks b where b.id=p_paddock_id and b.vineyard_id=p.vineyard_id) then raise exception 'OWNERSHIP_CONFLICT'; end if;
  before_row:=public.pin_location_placement_json(p);
  update public.pins set paddock_id=p_paddock_id,driving_row_number=p_driving_row,pin_row_number=p_pin_row,pin_side=p_pin_side,
    snapped_latitude=p_snapped_latitude,snapped_longitude=p_snapped_longitude,along_row_distance_m=p_along_row_distance_m,
    snapped_to_row=p_snapped_latitude is not null and p_snapped_longitude is not null,
    location_confirmation_revision=greatest(coalesce(location_confirmation_revision,0),p_evidence_revision),location_confirmed_at=now(),location_confirmed_by=auth.uid(),
    location_enrichment_status='user_confirmed',location_resolver_version='user-confirmation-v1',sync_version=sync_version+1
  where id=p_pin_id returning * into p;
  after_row:=public.pin_location_placement_json(p);
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,outcome,before_placement,after_placement)
  values(p_pin_id,p_evidence_revision,'user-confirmation-v1','user_confirmed',before_row,after_row);
  return p;
end $$;
revoke all on function public.confirm_saved_pin_location(uuid,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) from public,anon;
-- Legacy confirmation is retained for migration compatibility but no longer client executable.
revoke execute on function public.confirm_saved_pin_location(uuid,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) from authenticated;

create table if not exists public.pin_location_confirmation_operations(
  operation_id uuid primary key,pin_id uuid not null,evidence_revision integer not null,payload_hash text not null,outcome text not null,created_at timestamptz not null default now()
);
revoke all on public.pin_location_confirmation_operations from anon,authenticated;

create or replace function public.confirm_saved_pin_location_v2(
  p_operation_id uuid,p_pin_id uuid,p_evidence_revision integer,p_expected_sync_version integer,p_paddock_id uuid,
  p_driving_row numeric,p_pin_row numeric,p_pin_side text,p_snapped_latitude double precision,p_snapped_longitude double precision,p_along_row_distance_m numeric)
returns text language plpgsql security definer set search_path=public as $$
declare p public.pins%rowtype; e public.pin_capture_evidence%rowtype; before_row jsonb; after_row jsonb; v_hash text; existing_hash text;
begin
  v_hash:=encode(digest(concat_ws('|',p_pin_id,p_evidence_revision,p_paddock_id,p_driving_row,p_pin_row,p_pin_side,p_snapped_latitude,p_snapped_longitude,p_along_row_distance_m),'sha256'),'hex');
  select payload_hash into existing_hash from public.pin_location_confirmation_operations where operation_id=p_operation_id;
  if found then
    if existing_hash<>v_hash then raise exception 'OPERATION_CONFLICT'; end if;
    return 'confirmed';
  end if;
  select * into p from public.pins where id=p_pin_id for update;
  if not found or p.deleted_at is not null then raise exception 'PIN_NOT_FOUND'; end if;
  if not public.is_vineyard_member(p.vineyard_id) then raise exception 'FORBIDDEN'; end if;
  if p_expected_sync_version is not null and p.sync_version<>p_expected_sync_version then raise exception 'STALE_PIN'; end if;
  select * into e from public.pin_capture_evidence where pin_id=p.id and evidence_revision=p_evidence_revision and vineyard_id=p.vineyard_id;
  if not found then raise exception 'EVIDENCE_NOT_FOUND'; end if;
  if e.supported_paddock_id is distinct from p_paddock_id or e.supported_driving_row is distinct from p_driving_row
     or e.supported_pin_row is distinct from p_pin_row or e.supported_pin_side is distinct from p_pin_side
     or e.supported_snapped_latitude is distinct from p_snapped_latitude or e.supported_snapped_longitude is distinct from p_snapped_longitude
     or e.supported_along_row_distance_m is distinct from p_along_row_distance_m then raise exception 'EVIDENCE_PLACEMENT_MISMATCH'; end if;
  if p.location_confirmation_revision is not null and p.location_confirmation_revision>p_evidence_revision then raise exception 'NEWER_CONFIRMATION'; end if;
  if (p.driving_row_number is not null or p.pin_row_number is not null or p.pin_side is not null or p.snapped_to_row)
     and (p.paddock_id,p.driving_row_number,p.pin_row_number,p.pin_side,p.snapped_latitude,p.snapped_longitude,p.along_row_distance_m,p.snapped_to_row)
       is distinct from (p_paddock_id,p_driving_row,p_pin_row,p_pin_side,p_snapped_latitude,p_snapped_longitude,p_along_row_distance_m,true) then raise exception 'CURRENT_PLACEMENT_CONFLICT'; end if;
  before_row:=public.pin_location_placement_json(p);
  update public.pins set paddock_id=p_paddock_id,driving_row_number=p_driving_row,pin_row_number=p_pin_row,pin_side=p_pin_side,
    snapped_latitude=p_snapped_latitude,snapped_longitude=p_snapped_longitude,along_row_distance_m=p_along_row_distance_m,snapped_to_row=true,
    location_confirmation_revision=p_evidence_revision,location_confirmed_at=now(),location_confirmed_by=auth.uid(),
    location_enrichment_status='user_confirmed',location_resolver_version='user-confirmation-v2',sync_version=sync_version+1 where id=p_pin_id returning * into p;
  after_row:=public.pin_location_placement_json(p);
  insert into public.pin_location_confirmation_operations values(p_operation_id,p_pin_id,p_evidence_revision,v_hash,'confirmed',now());
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,outcome,before_placement,after_placement,detail)
    values(p_pin_id,p_evidence_revision,'user-confirmation-v2','user_confirmed',before_row,after_row,jsonb_build_object('operation_id',p_operation_id));
  return 'confirmed';
end $$;
revoke all on function public.confirm_saved_pin_location_v2(uuid,uuid,integer,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) from public,anon;
grant execute on function public.confirm_saved_pin_location_v2(uuid,uuid,integer,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) to authenticated;

-- Guarded reversal: only the exact after-image may be reversed; later edits win.
create or replace function public.reverse_pin_location_enrichment(p_audit_id uuid)
returns text language plpgsql security definer set search_path=public as $$
declare a public.pin_location_enrichment_audit%rowtype; p public.pins%rowtype; current_row jsonb;
begin
  if auth.role()<>'service_role' then raise exception 'service role required'; end if;
  select * into a from public.pin_location_enrichment_audit where id=p_audit_id;
  if not found or a.outcome not in ('resolved','partial_block_only') then return 'not_reversible'; end if;
  select * into p from public.pins where id=a.pin_id for update;
  current_row:=public.pin_location_placement_json(p);
  if current_row is distinct from a.after_placement then return 'conflict_later_edit'; end if;
  update public.pins set paddock_id=(a.before_placement->>'paddock_id')::uuid,driving_row_number=(a.before_placement->>'driving_row_number')::numeric,
    pin_row_number=(a.before_placement->>'pin_row_number')::numeric,pin_side=a.before_placement->>'pin_side',
    snapped_latitude=(a.before_placement->>'snapped_latitude')::double precision,snapped_longitude=(a.before_placement->>'snapped_longitude')::double precision,
    along_row_distance_m=(a.before_placement->>'along_row_distance_m')::numeric,snapped_to_row=coalesce((a.before_placement->>'snapped_to_row')::boolean,false),
    location_enrichment_status='reversed',location_enrichment_revision=null,location_resolver_version=null,location_enriched_at=now(),sync_version=sync_version+1
  where id=a.pin_id;
  select * into p from public.pins where id=a.pin_id;
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,outcome,before_placement,after_placement,detail)
  values(a.pin_id,a.evidence_revision,a.resolver_version,'reversed',a.after_placement,public.pin_location_placement_json(p),jsonb_build_object('reversed_audit_id',a.id));
  return 'reversed';
end $$;
revoke all on function public.reverse_pin_location_enrichment(uuid) from public,anon,authenticated;
grant execute on function public.reverse_pin_location_enrichment(uuid) to service_role;

-- Scheduling intentionally remains disabled. Deploy and verify controlled fixtures first.
