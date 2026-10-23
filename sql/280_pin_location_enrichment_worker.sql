-- 280_pin_location_enrichment_worker.sql
-- Keep pin drops instant while making capture evidence and server row enrichment
-- deterministic after the local save.
--
-- 1) Allow the existing leased worker RPCs to run from pg_cron (postgres) as
--    well as the service_role Edge worker. Their EXECUTE ACL remains restricted.
-- 2) Process up to 50 queued pin enrichments per minute inside Postgres with no
--    network hop. The existing lease/skip-locked rules keep this safe if the
--    Edge worker is also enabled later.

begin;

create or replace function public.claim_pin_location_enrichment(p_limit integer default 20,p_lease_seconds integer default 90)
returns setof public.pin_location_enrichment_queue language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service role required'; end if;
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

create or replace function public.commit_pin_location_enrichment(p_pin_id uuid,p_evidence_revision integer,p_resolver_version text,p_lease_token uuid)
returns text language plpgsql security definer set search_path=public as $$
declare e public.pin_capture_evidence%rowtype; p public.pins%rowtype; q public.pin_location_enrichment_queue%rowtype;
  before_row jsonb:='{}'; after_row jsonb:='{}'; outcome text; candidate_count integer; g public.pin_location_geometry_history%rowtype;
  resolved_paddock uuid; resolved_row numeric; can_use_mobile_row boolean:=false; rr jsonb; candidate_placement jsonb; existing_placement jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service role required'; end if;
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

create or replace function public.fail_pin_location_enrichment(p_pin_id uuid,p_evidence_revision integer,p_resolver_version text,p_lease_token uuid,p_error text)
returns text language plpgsql security definer set search_path=public as $$
declare q public.pin_location_enrichment_queue%rowtype; outcome text;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service role required'; end if;
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

revoke all on function public.claim_pin_location_enrichment(integer,integer)
  from public, anon, authenticated;
grant execute on function public.claim_pin_location_enrichment(integer,integer)
  to service_role;

revoke all on function public.commit_pin_location_enrichment(uuid,integer,text,uuid)
  from public, anon, authenticated;
grant execute on function public.commit_pin_location_enrichment(uuid,integer,text,uuid)
  to service_role;

revoke all on function public.fail_pin_location_enrichment(uuid,integer,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.fail_pin_location_enrichment(uuid,integer,text,uuid,text)
  to service_role;

create or replace function vinetrack_private.process_pin_location_enrichment_batch(
  p_limit integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public, vinetrack_private
as $$
declare
  q public.pin_location_enrichment_queue%rowtype;
  v_outcome text;
  v_claimed integer := 0;
  v_committed integer := 0;
  v_failed integer := 0;
begin
  for q in
    select * from public.claim_pin_location_enrichment(
      least(greatest(p_limit,1),50),
      90
    )
  loop
    v_claimed := v_claimed + 1;
    begin
      v_outcome := public.commit_pin_location_enrichment(
        q.pin_id,
        q.evidence_revision,
        q.resolver_version,
        q.lease_token
      );
      v_committed := v_committed + 1;
    exception when others then
      perform public.fail_pin_location_enrichment(
        q.pin_id,
        q.evidence_revision,
        q.resolver_version,
        q.lease_token,
        sqlerrm
      );
      v_failed := v_failed + 1;
    end;
  end loop;

  return jsonb_build_object(
    'claimed',v_claimed,
    'committed',v_committed,
    'failed',v_failed
  );
end
$$;

revoke all on function vinetrack_private.process_pin_location_enrichment_batch(integer)
  from public, anon, authenticated;
grant execute on function vinetrack_private.process_pin_location_enrichment_batch(integer)
  to service_role;

do $schedule$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='vinetrack-pin-location-enrichment-every-minute'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;

  perform cron.schedule(
    'vinetrack-pin-location-enrichment-every-minute',
    '* * * * *',
    $cron$
      set statement_timeout = '50s';
      select vinetrack_private.process_pin_location_enrichment_batch(50);
    $cron$
  );
end
$schedule$;

commit;
