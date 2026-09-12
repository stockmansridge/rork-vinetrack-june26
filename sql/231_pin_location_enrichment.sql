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
  horizontal_accuracy_m double precision not null check (horizontal_accuracy_m >= 0),
  heading_degrees double precision null check (heading_degrees >= 0 and heading_degrees <= 360),
  heading_source text null,
  heading_observed_at timestamptz null,
  pressed_side text null check (pressed_side in ('Left','Right')),
  trip_id uuid null,
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
  primary key (pin_id, evidence_revision),
  constraint pin_capture_observations_bounded check (
    jsonb_typeof(observations) = 'array' and jsonb_array_length(observations) <= 16
  )
);

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
  recorded_at timestamptz not null default now(),
  unique (paddock_id, valid_from)
);
revoke all on public.pin_location_geometry_history from anon, authenticated;

create or replace function public.snapshot_pin_location_geometry()
returns trigger language plpgsql security definer set search_path=public as $$
declare h text; changed_at timestamptz := now();
begin
  h := encode(digest(coalesce(new.polygon_points,'[]'::jsonb)::text || '|' || coalesce(new.rows,'[]'::jsonb)::text, 'sha256'),'hex');
  if tg_op='UPDATE' and encode(digest(coalesce(old.polygon_points,'[]'::jsonb)::text || '|' || coalesce(old.rows,'[]'::jsonb)::text,'sha256'),'hex') = h then
    return new;
  end if;
  update public.pin_location_geometry_history set valid_to=changed_at
  where paddock_id=new.id and valid_to is null;
  insert into public.pin_location_geometry_history(paddock_id,vineyard_id,valid_from,geometry_hash,polygon_points,rows)
  values(new.id,new.vineyard_id,changed_at,h,coalesce(new.polygon_points,'[]'::jsonb),coalesce(new.rows,'[]'::jsonb));
  return new;
end $$;

drop trigger if exists snapshot_pin_location_geometry_change on public.paddocks;
create trigger snapshot_pin_location_geometry_change
after insert or update of polygon_points,rows on public.paddocks
for each row execute function public.snapshot_pin_location_geometry();

insert into public.pin_location_geometry_history(paddock_id,vineyard_id,valid_from,geometry_hash,polygon_points,rows)
select p.id,p.vineyard_id,now(),encode(digest(coalesce(p.polygon_points,'[]'::jsonb)::text || '|' || coalesce(p.rows,'[]'::jsonb)::text,'sha256'),'hex'),coalesce(p.polygon_points,'[]'::jsonb),coalesce(p.rows,'[]'::jsonb)
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

create or replace function public.resolve_pin_row_geometry(rows jsonb,lat double precision,lon double precision,accuracy_m double precision,heading double precision,pressed_side text)
returns jsonb language plpgsql immutable as $$
declare r jsonb; s jsonb; e jsonb; lat0 double precision:=radians(lat); sx double precision; sy double precision; ex double precision; ey double precision;
  dx double precision; dy double precision; len2 double precision; t double precision; px double precision; py double precision; dist double precision;
  forward_x double precision:=sin(radians(heading)); forward_y double precision:=cos(radians(heading)); cross_side double precision;
  best_dist double precision:=1e30; opposite_dist double precision:=1e30; best jsonb; opposite jsonb; row_no numeric; side_label text;
begin
  if heading is null or pressed_side not in ('Left','Right') or jsonb_typeof(rows)<>'array' then return null; end if;
  for r in select value from jsonb_array_elements(rows) loop
    s:=coalesce(r->'startPoint',r->'start_point'); e:=coalesce(r->'endPoint',r->'end_point');
    if s is null or e is null then continue; end if;
    sx:=(coalesce((s->>'longitude')::double precision,(s->>'lng')::double precision)-lon)*111320*cos(lat0);
    sy:=(coalesce((s->>'latitude')::double precision,(s->>'lat')::double precision)-lat)*111320;
    ex:=(coalesce((e->>'longitude')::double precision,(e->>'lng')::double precision)-lon)*111320*cos(lat0);
    ey:=(coalesce((e->>'latitude')::double precision,(e->>'lat')::double precision)-lat)*111320;
    dx:=ex-sx; dy:=ey-sy; len2:=dx*dx+dy*dy; if len2<0.01 then continue; end if;
    t:=-(sx*dx+sy*dy)/len2; if t<0 or t>1 then continue; end if;
    px:=sx+t*dx; py:=sy+t*dy; dist:=sqrt(px*px+py*py); cross_side:=forward_x*py-forward_y*px;
    side_label:=case when cross_side>=0 then 'Left' else 'Right' end; row_no:=(r->>'number')::numeric;
    if side_label=pressed_side and dist<best_dist then
      best_dist:=dist; best:=jsonb_build_object('row',row_no,'snapped_latitude',lat+py/111320,'snapped_longitude',lon+px/(111320*cos(lat0)),'along_m',t*sqrt(len2));
    elsif side_label<>pressed_side and dist<opposite_dist then
      opposite_dist:=dist; opposite:=jsonb_build_object('row',row_no);
    end if;
  end loop;
  if best is null or opposite is null or accuracy_m<0 or accuracy_m>=best_dist+opposite_dist then return null; end if;
  return best || jsonb_build_object('driving_row',((best->>'row')::numeric+(opposite->>'row')::numeric)/2,'pin_side',pressed_side);
exception when others then return null;
end $$;

create or replace function public.pin_location_placement_json(p public.pins)
returns jsonb language sql immutable as $$
select jsonb_build_object(
  'paddock_id',p.paddock_id,'driving_row_number',p.driving_row_number,
  'pin_row_number',p.pin_row_number,'pin_side',p.pin_side,
  'snapped_latitude',p.snapped_latitude,'snapped_longitude',p.snapped_longitude,
  'along_row_distance_m',p.along_row_distance_m,
  'location_enrichment_revision',p.location_enrichment_revision,
  'location_confirmation_revision',p.location_confirmation_revision
) $$;

create or replace function public.claim_pin_location_enrichment(p_limit integer default 20,p_lease_seconds integer default 90)
returns setof public.pin_location_enrichment_queue language plpgsql security definer set search_path=public as $$
begin
  if auth.role()<>'service_role' then raise exception 'service role required'; end if;
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
  resolved_paddock uuid; resolved_row numeric; can_use_mobile_row boolean:=false; rr jsonb;
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
  elsif p.location_confirmation_revision is not null then outcome:='user_confirmed';
  elsif p.location_enrichment_revision is not null and p.location_enrichment_revision>=p_evidence_revision then outcome:='already_applied';
  else
    select count(*),min(h.paddock_id) into candidate_count,resolved_paddock
    from public.pin_location_geometry_history h
    where h.vineyard_id=e.vineyard_id and h.valid_from<=e.captured_at and (h.valid_to is null or h.valid_to>e.captured_at)
      and public.pin_point_in_polygon(e.raw_latitude,e.raw_longitude,h.polygon_points);
    if candidate_count=0 then outcome:='unresolved_no_capture_geometry';
    elsif candidate_count>1 then outcome:='conflict_overlapping_blocks'; resolved_paddock:=null;
    else
      select * into g from public.pin_location_geometry_history h where h.paddock_id=resolved_paddock and h.valid_from<=e.captured_at and (h.valid_to is null or h.valid_to>e.captured_at) order by h.valid_from desc limit 1;
      rr:=public.resolve_pin_row_geometry(g.rows,e.raw_latitude,e.raw_longitude,e.horizontal_accuracy_m,e.heading_degrees,e.pressed_side);
      can_use_mobile_row:=rr is not null;
      resolved_row:=case when rr is not null then (rr->>'row')::numeric else null end;
      if e.geometry_hash is not null and e.geometry_hash<>g.geometry_hash then
        outcome:='conflict_geometry_revision'; can_use_mobile_row:=false; resolved_row:=null;
      elsif rr is not null and e.supported_pin_row is not null and e.supported_pin_row<>resolved_row then
        outcome:='conflict_mobile_server_row'; can_use_mobile_row:=false; resolved_row:=null;
      else outcome:=case when can_use_mobile_row then 'resolved' else 'partial_block_only' end;
      end if;
      update public.pins set
        paddock_id=coalesce(paddock_id,resolved_paddock),
        driving_row_number=case when can_use_mobile_row then coalesce(driving_row_number,(rr->>'driving_row')::numeric) else driving_row_number end,
        pin_row_number=coalesce(pin_row_number,resolved_row),
        pin_side=case when can_use_mobile_row then coalesce(pin_side,rr->>'pin_side') else pin_side end,
        snapped_latitude=case when can_use_mobile_row then coalesce(snapped_latitude,(rr->>'snapped_latitude')::double precision) else snapped_latitude end,
        snapped_longitude=case when can_use_mobile_row then coalesce(snapped_longitude,(rr->>'snapped_longitude')::double precision) else snapped_longitude end,
        along_row_distance_m=case when can_use_mobile_row then coalesce(along_row_distance_m,(rr->>'along_m')::numeric) else along_row_distance_m end,
        snapped_to_row=snapped_to_row or can_use_mobile_row,
        location_enrichment_status=outcome,location_enrichment_revision=p_evidence_revision,
        location_resolver_version=p_resolver_version,location_enriched_at=now()
      where id=p_pin_id and deleted_at is null and location_confirmation_revision is null;
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
    location_enrichment_status='user_confirmed',location_resolver_version='user-confirmation-v1'
  where id=p_pin_id returning * into p;
  after_row:=public.pin_location_placement_json(p);
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,outcome,before_placement,after_placement)
  values(p_pin_id,p_evidence_revision,'user-confirmation-v1','user_confirmed',before_row,after_row);
  return p;
end $$;
revoke all on function public.confirm_saved_pin_location(uuid,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) from public,anon;
grant execute on function public.confirm_saved_pin_location(uuid,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) to authenticated;

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
    along_row_distance_m=(a.before_placement->>'along_row_distance_m')::numeric,location_enrichment_status='reversed',location_enrichment_revision=null,location_enriched_at=now()
  where id=a.pin_id;
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,outcome,before_placement,after_placement,detail)
  values(a.pin_id,a.evidence_revision,a.resolver_version,'reversed',a.after_placement,a.before_placement,jsonb_build_object('reversed_audit_id',a.id));
  return 'reversed';
end $$;
revoke all on function public.reverse_pin_location_enrichment(uuid) from public,anon,authenticated;
grant execute on function public.reverse_pin_location_enrichment(uuid) to service_role;

-- Scheduling intentionally remains disabled. Deploy and verify controlled fixtures first.
