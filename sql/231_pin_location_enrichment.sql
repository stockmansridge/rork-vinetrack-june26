-- Save-first pin evidence and deferred location enrichment.
-- Additive only. Does not enqueue historical pins and never changes completion.

create table if not exists public.pin_capture_evidence (
  pin_id uuid not null references public.pins(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  evidence_revision integer not null check (evidence_revision > 0),
  resolver_version text not null default 'mobile-capture-v1',
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

alter table public.pin_capture_evidence enable row level security;
drop policy if exists pin_capture_evidence_member_select on public.pin_capture_evidence;
create policy pin_capture_evidence_member_select on public.pin_capture_evidence
for select to authenticated using (public.is_vineyard_member(vineyard_id));
drop policy if exists pin_capture_evidence_member_insert on public.pin_capture_evidence;
create policy pin_capture_evidence_member_insert on public.pin_capture_evidence
for insert to authenticated with check (
  created_by = auth.uid() and public.is_vineyard_member(vineyard_id)
  and exists (select 1 from public.pins p where p.id = pin_id and p.vineyard_id = vineyard_id)
);

alter table public.pins
  add column if not exists location_enrichment_status text null,
  add column if not exists location_enrichment_revision integer null,
  add column if not exists location_resolver_version text null,
  add column if not exists location_enriched_at timestamptz null;

create table if not exists public.pin_location_enrichment_queue (
  pin_id uuid not null,
  evidence_revision integer not null,
  resolver_version text not null,
  available_at timestamptz not null default now(),
  lease_token uuid null,
  lease_expires_at timestamptz null,
  attempts integer not null default 0,
  last_error text null,
  primary key (pin_id, evidence_revision, resolver_version)
);
revoke all on public.pin_location_enrichment_queue from anon, authenticated;

create table if not exists public.pin_location_enrichment_audit (
  id uuid primary key default gen_random_uuid(),
  pin_id uuid not null,
  evidence_revision integer not null,
  resolver_version text not null,
  outcome text not null,
  before_placement jsonb not null,
  after_placement jsonb not null,
  created_at timestamptz not null default now()
);
revoke all on public.pin_location_enrichment_audit from anon, authenticated;

create or replace function public.enqueue_pin_location_enrichment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.pin_location_enrichment_queue(pin_id,evidence_revision,resolver_version)
  values(new.pin_id,new.evidence_revision,new.resolver_version)
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists enqueue_pin_location_enrichment_after_evidence on public.pin_capture_evidence;
create trigger enqueue_pin_location_enrichment_after_evidence
after insert on public.pin_capture_evidence for each row execute function public.enqueue_pin_location_enrichment();

create or replace function public.claim_pin_location_enrichment(p_limit integer default 20, p_lease_seconds integer default 90)
returns setof public.pin_location_enrichment_queue
language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select q.pin_id,q.evidence_revision,q.resolver_version
    from public.pin_location_enrichment_queue q
    where q.available_at <= now() and (q.lease_expires_at is null or q.lease_expires_at < now())
      and q.attempts < 8
    order by q.available_at
    for update skip locked limit least(greatest(p_limit,1),50)
  )
  update public.pin_location_enrichment_queue q
  set lease_token=gen_random_uuid(), lease_expires_at=now()+make_interval(secs=>least(greatest(p_lease_seconds,15),300)), attempts=q.attempts+1
  from due where q.pin_id=due.pin_id and q.evidence_revision=due.evidence_revision and q.resolver_version=due.resolver_version
  returning q.*;
end $$;
revoke all on function public.claim_pin_location_enrichment(integer,integer) from public;

create or replace function public.commit_pin_location_enrichment(
  p_pin_id uuid, p_evidence_revision integer, p_resolver_version text, p_lease_token uuid
) returns text language plpgsql security definer set search_path=public as $$
declare e public.pin_capture_evidence%rowtype; p public.pins%rowtype; before_row jsonb; after_row jsonb; outcome text;
begin
  select * into e from public.pin_capture_evidence where pin_id=p_pin_id and evidence_revision=p_evidence_revision;
  select * into p from public.pins where id=p_pin_id for update;
  if not found or p.deleted_at is not null then outcome := 'deleted_or_missing';
  elsif p.location_enrichment_revision is not null and p.location_enrichment_revision >= p_evidence_revision then outcome := 'already_applied';
  elsif e.geometry_hash is null then outcome := 'insufficient_geometry_revision';
  else
    before_row := jsonb_build_object('paddock_id',p.paddock_id,'driving_row_number',p.driving_row_number,'pin_row_number',p.pin_row_number,'pin_side',p.pin_side,'snapped_latitude',p.snapped_latitude,'snapped_longitude',p.snapped_longitude);
    -- Narrow merge: automation only fills absent placement fields and never
    -- touches raw coordinates, status/completion, notes, photos, type or creator.
    update public.pins set
      paddock_id=coalesce(paddock_id,e.supported_paddock_id),
      driving_row_number=coalesce(driving_row_number,e.supported_driving_row),
      pin_row_number=coalesce(pin_row_number,e.supported_pin_row),
      pin_side=coalesce(pin_side,e.supported_pin_side),
      snapped_latitude=coalesce(snapped_latitude,e.supported_snapped_latitude),
      snapped_longitude=coalesce(snapped_longitude,e.supported_snapped_longitude),
      along_row_distance_m=coalesce(along_row_distance_m,e.supported_along_row_distance_m),
      snapped_to_row=snapped_to_row or (e.supported_snapped_latitude is not null and e.supported_snapped_longitude is not null),
      location_enrichment_status='enriched', location_enrichment_revision=p_evidence_revision,
      location_resolver_version=p_resolver_version, location_enriched_at=now()
    where id=p_pin_id and deleted_at is null;
    select to_jsonb(x) into after_row from (select paddock_id,driving_row_number,pin_row_number,pin_side,snapped_latitude,snapped_longitude from public.pins where id=p_pin_id) x;
    outcome := 'applied';
    insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,outcome,before_placement,after_placement)
    values(p_pin_id,p_evidence_revision,p_resolver_version,outcome,before_row,after_row);
  end if;
  delete from public.pin_location_enrichment_queue where pin_id=p_pin_id and evidence_revision=p_evidence_revision and resolver_version=p_resolver_version and lease_token=p_lease_token;
  return outcome;
exception when others then
  update public.pin_location_enrichment_queue set lease_token=null,lease_expires_at=null,last_error=left(sqlerrm,500),available_at=now()+make_interval(secs=>least(3600,30*power(2,least(attempts,7))::integer))
  where pin_id=p_pin_id and evidence_revision=p_evidence_revision and resolver_version=p_resolver_version and lease_token=p_lease_token;
  raise;
end $$;
revoke all on function public.commit_pin_location_enrichment(uuid,integer,text,uuid) from public;

-- Scheduling is intentionally NOT enabled here. See the contract deployment section.
-- Historical eligibility summary (SELECT only; never enqueue automatically):
-- select count(*) filter (where paddock_id is null) unresolved_block,
--        count(*) filter (where pin_row_number is null) unresolved_row
-- from public.pins where deleted_at is null;
