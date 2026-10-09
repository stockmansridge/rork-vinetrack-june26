-- REVIEW / UNAPPLIED. Apply after 272, 273 and 274. No operational tables are mutated.
-- New-client Vintage Report protocol v1. All report writes use the RPC below.
begin;
create table public.vintage_reports (
 id uuid primary key default gen_random_uuid(),
 vineyard_id uuid not null references public.vineyards(id), vintage integer not null,
 current_revision_id uuid, unique(vineyard_id,vintage)
);
create table public.vintage_report_requests (
 operation_id uuid primary key, report_id uuid not null references public.vintage_reports(id),
 vineyard_id uuid not null references public.vineyards(id), authored_by uuid not null references auth.users(id),
 action text not null check(action in ('generate','regenerate','append','edit')),
 expected_revision_id uuid, report_through date not null,
 input jsonb not null, evidence jsonb not null,
 status text not null default 'queued' check(status in ('queued','running','succeeded','failed','unchanged')),
 error_code text, created_at timestamptz not null default clock_timestamp(), started_at timestamptz,
 result_revision_id uuid
);
create table public.vintage_report_revisions (
 id uuid primary key default gen_random_uuid(), report_id uuid not null references public.vintage_reports(id),
 vineyard_id uuid not null references public.vineyards(id), revision integer not null,
 operation_id uuid not null unique references public.vintage_report_requests(operation_id),
 action text not null, report_through date not null, collected_at timestamptz not null,
 evidence jsonb not null, content jsonb not null,
 created_at timestamptz not null default clock_timestamp(), created_by uuid not null references auth.users(id),
 unique(report_id,revision)
);
alter table public.vintage_reports add foreign key(current_revision_id) references public.vintage_report_revisions(id);
alter table public.vintage_report_requests add foreign key(result_revision_id) references public.vintage_report_revisions(id);
-- Provider/usage data is deliberately separate from provider-independent content.
create table public.vintage_report_diagnostics (
 operation_id uuid primary key references public.vintage_report_requests(operation_id),
 provider_response_id text, model text, usage jsonb, validated_content jsonb, updated_at timestamptz not null default clock_timestamp()
);
create index vintage_report_revision_history on public.vintage_report_revisions(report_id,revision desc);
create index vintage_report_request_recovery on public.vintage_report_requests(authored_by,vineyard_id,status);
alter table public.vintage_reports enable row level security;
alter table public.vintage_report_requests enable row level security;
alter table public.vintage_report_revisions enable row level security;
alter table public.vintage_report_diagnostics enable row level security;
create policy vr_read on public.vintage_reports for select to authenticated using(public.can_use_vineyard_insights(vineyard_id));
create policy vr_revision_read on public.vintage_report_revisions for select to authenticated using(public.can_use_vineyard_insights(vineyard_id));
create policy vr_request_read on public.vintage_report_requests for select to authenticated using(authored_by=auth.uid() and public.can_use_vineyard_insights(vineyard_id));
revoke all on public.vintage_reports,public.vintage_report_revisions,public.vintage_report_requests,public.vintage_report_diagnostics from public,anon,authenticated;
grant select on public.vintage_reports,public.vintage_report_revisions,public.vintage_report_requests to authenticated;
grant all on public.vintage_reports,public.vintage_report_revisions,public.vintage_report_requests,public.vintage_report_diagnostics to service_role;

-- Stable helpers use the caller's statement snapshot across every page. A limit is a
-- rejection boundary, never truncation. Raw paths, photos and costing payloads stay out.
create function public._vr_collect(p_vineyard uuid,p_vintage integer,p_through date)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare
 v public.vineyards%rowtype; start_day date; end_day date; local_today date;
 y integer; m integer; d integer; spec jsonb; row_data jsonb; page jsonb; compact jsonb;
 records jsonb := '[]'; coverage jsonb := '{}'; gaps jsonb := '[]'; rain jsonb;
 source_name text; date_key text; event_day date; stop_day date; event_raw text; offset_rows integer;
 n integer; draft_count integer; keys text[]; stop_record record; item_record record;
begin
 if not public.can_use_vineyard_insights(p_vineyard) then raise exception 'not_authorised' using errcode='42501'; end if;
 select * into strict v from public.vineyards where id=p_vineyard;
 m:=least(greatest(coalesce(v.season_start_month,7),1),12); d:=greatest(coalesce(v.season_start_day,1),1);
 y:=case when m=1 and d=1 then p_vintage else p_vintage-1 end;
 start_day:=make_date(y,m,least(d,extract(day from(make_date(y,m,1)+interval '1 month - 1 day'))::integer));
 end_day:=make_date(y+1,m,least(d,extract(day from(make_date(y+1,m,1)+interval '1 month - 1 day'))::integer))-1;
 if public.resolve_vineyard_vintage_year(p_vineyard,start_day)<>p_vintage or public.resolve_vineyard_vintage_year(p_vineyard,end_day)<>p_vintage then
  raise exception 'season_authority_mismatch';
 end if;
 local_today:=(statement_timestamp() at time zone coalesce(nullif(v.timezone,''),'UTC'))::date;
 if p_through is null or p_through<start_day or p_through>least(end_day,local_today) then raise exception 'invalid_report_through'; end if;
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='scout_block_assessments' and column_name='stop_context') then raise exception 'migration_274_required'; end if;
 keys:=array['id','paddock_id','paddock_ids','paddock_name','targets','operation_type','application_blocks','trip_id','spray_job_id','work_task_id','pruning_activity_id','growth_stage_record_id','pin_id',
 'sync_version','client_revision_id','updated_at','scout_date','visit_summary','scout_name_snapshot','note_date','note_type_id','note_type_label','observer_name_snapshot','title','body','notes','text',
 'stage_code','stage_label','variety','variety_name','observed_at','date','start_time','end_time','trip_function','is_active','is_finalized','completed_at','end_date','schedule_basis','target_el_stage','task_type','description',
 'entry_date','finish_time','vintage_year','vintage','status','session_date','started_at','finished_at','total_volume_litres','effective_volume_litres','calculation_method','source_type','volume_is_estimated','actual_volume_l','allocated_volume_l','water_volume_l','duration_minutes','fertiliser_name','nutrients',
 'calculated_at','estimate_source','base_estimate_tonnes','is_estimate_available','source_session_id','estimated_tonnes','estimated_yield_tonnes','yield_tonnes','total_tonnes','weight_kg','picked_at','sugar_value','sugar_unit','ph','ta_g_l','date_observed','damage_type','damage_percent','loss_percent','severity','product_name','record_status','calculation_mode','application_date','block_names','application_rate','application_rate_unit','total_product_required','product_unit'];
 for spec in select value from jsonb_array_elements('[
  {"table":"scout_visits","date":"scout_date"},{"table":"vintage_notes","date":"note_date"},
  {"table":"growth_stage_records","date":"observed_at"},{"table":"spray_records","date":"date"},
  {"table":"work_tasks","date":"date"},{"table":"pruning_activities","date":"entry_date"},
  {"table":"trips","date":"start_time"},{"table":"irrigation_sessions","date":"session_date"},
  {"table":"season_yield_estimates","date":"calculated_at"},{"table":"damage_records","date":"date_observed"},
  {"table":"picking_records","date":"picked_at"},{"table":"fertiliser_records","date":"application_date"}]'::jsonb)
 loop
  source_name:=spec->>'table'; date_key:=spec->>'date'; offset_rows:=0; n:=0; draft_count:=0;
  if to_regclass('public.'||source_name) is null then
   gaps:=gaps||jsonb_build_array(source_name||': source unavailable'); continue;
  end if;
  loop
   execute format('select coalesce(jsonb_agg(j order by j->>''id''),''[]''::jsonb) from (select to_jsonb(t) j from public.%I t where vineyard_id=$1 order by id limit 500 offset $2) q',source_name)
    into page using p_vineyard,offset_rows;
   exit when jsonb_array_length(page)=0;
   for row_data in select value from jsonb_array_elements(page) loop
    if row_data->>'deleted_at' is not null then continue; end if;
    event_raw:=case when source_name='work_tasks' and coalesce((row_data->>'is_finalized')::boolean,false) then coalesce(left(row_data->>'end_date',10),row_data->>'completed_at',row_data->>date_key) else row_data->>date_key end;
    event_raw:=coalesce(event_raw,case when source_name='spray_records' then row_data->>'start_time' when source_name='damage_records' then row_data->>'date' end);
    if event_raw is null then gaps:=gaps||jsonb_build_array(source_name||':'||(row_data->>'id')||': event date unavailable'); continue; end if;
    event_day:=case when length(event_raw)=10 then event_raw::date else (event_raw::timestamptz at time zone coalesce(nullif(v.timezone,''),'UTC'))::date end;
    -- Stored canonical vintage wins where supplied, dates still bound the reporting period.
    if coalesce(row_data->>'vintage_year',row_data->>'vintage',public.resolve_vineyard_vintage_year(p_vineyard,event_day)::text)::integer<>p_vintage or (event_day not between start_day and p_through and not (source_name='work_tasks' and coalesce(row_data->>'schedule_basis','date')='el_stage' and not coalesce((row_data->>'is_finalized')::boolean,false))) then continue; end if;
    if source_name='scout_visits' and row_data->>'status'<>'completed' then draft_count:=draft_count+1; continue; end if;
    if source_name='irrigation_sessions' and row_data->>'status' not in ('completed','corrected','imported','estimated') then
     gaps:=gaps||jsonb_build_array('irrigation_sessions:'||(row_data->>'id')||': non-recorded/reversed/planned session excluded'); continue;
    end if;
    if source_name='fertiliser_records' and row_data->>'record_status'<>'completed' then continue; end if;
    if source_name='spray_records' and coalesce((row_data->>'is_template')::boolean,false) then continue; end if;
    -- Linked task/trip records are relationship evidence, not a second operation.
    if source_name='work_tasks' and (
      exists(select 1 from public.pruning_activities a where a.id=(row_data->>'pruning_activity_id')::uuid and a.vineyard_id=p_vineyard and a.deleted_at is null and a.vintage_year=p_vintage and a.entry_date between start_day and p_through)
      or exists(select 1 from public.trips t where to_jsonb(t)->>'work_task_id'=row_data->>'id' and t.vineyard_id=p_vineyard and t.deleted_at is null and not t.is_active and t.end_time is not null and (t.start_time at time zone coalesce(nullif(v.timezone,''),'UTC'))::date between start_day and p_through)
    ) then continue; end if;
    if source_name='trips' and exists(select 1 from public.spray_records s where s.trip_id=(row_data->>'id')::uuid and s.vineyard_id=p_vineyard and s.deleted_at is null and not s.is_template and (coalesce(s.date,s.start_time) at time zone coalesce(nullif(v.timezone,''),'UTC'))::date between start_day and p_through) then continue; end if;
    select coalesce(jsonb_object_agg(key,value),'{}') into compact from jsonb_each(row_data) where key=any(keys);
    if source_name='work_tasks' then
     compact:=(compact-'date')||jsonb_build_object('record_kind',case when coalesce((row_data->>'is_finalized')::boolean,false) then 'finalised_record' else 'planned_work' end,'planned_date',case when coalesce(row_data->>'schedule_basis','date')='date' then left(row_data->>'date',10) else null end);
     if not coalesce((row_data->>'is_finalized')::boolean,false) or (row_data->>'end_date' is null and row_data->>'completed_at' is null) then event_day:=null; end if;
    end if;
    if source_name='spray_records' then
     -- Recorded product identities/rates only; no entire tank/route/cost payload.
     compact:=compact||jsonb_build_object('recorded_tanks',coalesce((select jsonb_agg(jsonb_build_object('tank_number',x->'tankNumber','products',coalesce((select jsonb_agg((select jsonb_object_agg(key,value) from jsonb_each(product) where key=any(array['id','name','savedChemicalId','unit','volumePerTank','ratePerHa','ratePer100L','rateBasis']))) from jsonb_array_elements(case when jsonb_typeof(x->'chemicals')='array' then x->'chemicals' else '[]' end) product),'[]'::jsonb),'targets',x->'targets')) from jsonb_array_elements(case when jsonb_typeof(row_data->'tanks')='array' then row_data->'tanks' else '[]' end) x),'[]'));
    end if;
    records:=records||jsonb_build_array(jsonb_build_object('id',source_name||':'||(row_data->>'id'),'event_date',event_day,'hash',md5((compact-'sync_version'-'updated_at'-'client_revision_id')::text),'data',compact)); n:=n+1;
    if source_name='scout_visits' then
     for stop_record in select a.* from public.scout_block_assessments a where a.scout_visit_id=(row_data->>'id')::uuid and a.vineyard_id=p_vineyard and a.deleted_at is null and a.status='complete' and coalesce((a.stop_context->>'is_draft')::boolean,false)=false order by a.id loop
      stop_day:=case when stop_record.stop_context->>'captured_at' is not null then ((stop_record.stop_context->>'captured_at')::timestamptz at time zone coalesce(nullif(v.timezone,''),'UTC'))::date else event_day end;
      if stop_day not between start_day and p_through then continue; end if;
      compact:=jsonb_build_object('event_date_basis',case when stop_record.stop_context is null then 'associated_trip_date_not_stop_capture' else 'stop_capture_date' end,'id',stop_record.id,'paddock_id',stop_record.paddock_id,'stop_context',stop_record.stop_context,'client_revision_id',stop_record.client_revision_id);
      records:=records||jsonb_build_array(jsonb_build_object('id','scout_stop:'||stop_record.id,'event_date',stop_day,'hash',md5((compact-'sync_version'-'updated_at'-'client_revision_id')::text),'data',compact));
      for item_record in select o.* from public.scout_observations o where o.assessment_id=stop_record.id and o.vineyard_id=p_vineyard and o.deleted_at is null and (o.value_code is not null or o.value_label is not null or nullif(trim(o.notes),'') is not null or o.linked_growth_record_id is not null) order by o.id loop
       row_data:=to_jsonb(item_record);
       -- Canonical E-L evidence is read once through growth_stage_records.
       if row_data->>'linked_growth_record_id' is not null then continue; end if;
       select coalesce(jsonb_object_agg(key,value),'{}') into compact from jsonb_each(row_data) where key=any(array['id','assessment_id','item_kind','value_code','value_label','notes','client_revision_id']);
       records:=records||jsonb_build_array(jsonb_build_object('id','scout_item:'||item_record.id,'event_date',stop_day,'hash',md5((compact-'sync_version'-'updated_at'-'client_revision_id')::text),'data',compact));
      end loop;
     end loop;
    end if;
   end loop;
   offset_rows:=offset_rows+500;
   if offset_rows>100000 then raise exception 'source_too_large_no_truncation'; end if;
  end loop;
  coverage:=coverage||jsonb_build_object(source_name,n);
  if source_name='scout_visits' then coverage:=coverage||jsonb_build_object('excluded_draft_trips',draft_count); end if;
 end loop;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.date),'[]') into rain from public.get_daily_rainfall(p_vineyard,start_day,p_through) r;
 for row_data in select value from jsonb_array_elements(rain) loop
  if row_data->>'rainfall_mm' is null then continue; end if;
  records:=records||jsonb_build_array(jsonb_build_object('id','rainfall:'||(row_data->>'date'),'event_date',row_data->>'date','hash',md5((row_data-'updated_at')::text),'data',row_data));
 end loop;
 compact:=jsonb_build_object('season_start',start_day,'season_end',end_day,'report_through',p_through,'season_to_date',p_through<end_day,'vineyard_name',v.name,'timezone',coalesce(nullif(v.timezone,''),'UTC'));
 records:=records||jsonb_build_array(jsonb_build_object('id','report_scope:'||p_vineyard||':'||p_vintage,'event_date',p_through,'hash',md5(compact::text),'data',compact));
 coverage:=coverage||jsonb_build_object('saved_stops',(select count(*) from jsonb_array_elements(records) x where x->>'id' like 'scout_stop:%'),'saved_scout_items',(select count(*) from jsonb_array_elements(records) x where x->>'id' like 'scout_item:%'),'rainfall_recorded_days',(select count(*) from jsonb_array_elements(rain) x where x->>'rainfall_mm' is not null),'rainfall_missing_days',(select count(*) from jsonb_array_elements(rain) x where x->>'rainfall_mm' is null));
 gaps:=gaps||jsonb_build_array('Photographs are not analysed. Scout snapshot weather is observation-time only.','Historical temperature/wind series and comparable baseline are not integrated. No heat, frost, wind extremes or average comparisons are inferred.','Scout weather snapshots describe observation-time conditions only.','Operational records establish recorded dates, not necessarily actual activity start or completion.','Work logs, detailed fertigation allocations and historical actual-yield archives are not integrated in v1.');
 compact:=jsonb_build_object('schema_version',1,'vineyard_id',p_vineyard,'vineyard_name',v.name,'vintage',p_vintage,'timezone',coalesce(nullif(v.timezone,''),'UTC'),'season_start',start_day,'season_end',end_day,'report_through',p_through,'season_to_date',p_through<end_day,'collected_at',statement_timestamp(),'coverage',coverage,'gaps',gaps,'rainfall',rain,'sources',records);
 if octet_length(compact::text)>500000 then raise exception 'evidence_too_large_no_truncation'; end if;
 return compact;
end $$;
revoke all on function public._vr_collect(uuid,integer,date) from public,anon,authenticated;

-- Client request/read/edit/activation protocol. Expected pointer never auto-rebases.
create function public.vintage_report_command(p_command text,p_vineyard_id uuid,p_vintage integer,p_operation_id uuid default null,p_expected_revision_id uuid default null,p_report_through date default null,p_content jsonb default null,p_offset integer default 0,p_author_id uuid default null,p_before_revision integer default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.vintage_reports%rowtype; q public.vintage_report_requests%rowtype; rev public.vintage_report_revisions%rowtype;
 e jsonb; original_input jsonb; start_date date; end_date date; today date; content_value jsonb;
begin
 if p_author_id is distinct from auth.uid() or not public.can_use_vineyard_insights(p_vineyard_id) then raise exception 'not_authorised' using errcode='42501'; end if;
 if p_vintage not between 1900 and 2200 then raise exception 'invalid_vintage'; end if;
 if p_command='read' then
  select * into r from public.vintage_reports where vineyard_id=p_vineyard_id and vintage=p_vintage;
  return jsonb_build_object('report',to_jsonb(r),'revisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.revision desc) from(select * from public.vintage_report_revisions where report_id=r.id and (p_before_revision is null or revision<p_before_revision) order by revision desc limit 20) x),'[]'),
   'requests',coalesce((select jsonb_agg(to_jsonb(x)-'evidence') from (select * from public.vintage_report_requests where report_id=r.id and authored_by=auth.uid() and status in ('queued','running') order by created_at desc limit 20) x),'[]'));
 end if;
 if p_command='coverage' then
  -- Resolve boundaries by querying all candidate dates with the existing resolver.
  select min(day),max(day) into start_date,end_date from (select gs::date day from generate_series(make_date(p_vintage-1,1,1),make_date(p_vintage+1,1,1),interval '1 day') gs) x where public.resolve_vineyard_vintage_year(p_vineyard_id,day)=p_vintage;
  select (statement_timestamp() at time zone coalesce(nullif(timezone,''),'UTC'))::date into today from public.vineyards where id=p_vineyard_id;
  if least(today,end_date)<start_date then return jsonb_build_object('season_start',start_date,'season_end',end_date,'not_started',true); end if;
  e:=public._vr_collect(p_vineyard_id,p_vintage,coalesce(p_report_through,least(today,end_date)));
  return e-'sources'-'rainfall';
 end if;
 insert into public.vintage_reports(vineyard_id,vintage) values(p_vineyard_id,p_vintage) on conflict(vineyard_id,vintage) do nothing;
 select * into strict r from public.vintage_reports where vineyard_id=p_vineyard_id and vintage=p_vintage for update;
 if p_command='activate' then
  select * into strict rev from public.vintage_report_revisions where operation_id=p_operation_id and report_id=r.id;
  if r.current_revision_id=rev.id then return to_jsonb(rev); end if;
  select * into strict q from public.vintage_report_requests where operation_id=p_operation_id;
  if r.current_revision_id is distinct from p_expected_revision_id or r.current_revision_id is distinct from q.expected_revision_id then raise exception 'revision_conflict'; end if;
  update public.vintage_reports set current_revision_id=rev.id where id=r.id;
  return to_jsonb(rev);
 end if;
 if p_command not in ('generate','regenerate','append','edit') or p_operation_id is null then raise exception 'invalid_command'; end if;
 original_input:=jsonb_build_object('action',p_command,'through',p_report_through,'expected',p_expected_revision_id,'content',p_content);
 select * into q from public.vintage_report_requests where operation_id=p_operation_id;
 if found then
  if q.authored_by<>auth.uid() or q.report_id<>r.id or q.input<>original_input then raise exception 'operation_id_reused'; end if;
  return to_jsonb(q)-'evidence'-'input';
 end if;
 if r.current_revision_id is distinct from p_expected_revision_id then raise exception 'revision_conflict'; end if;
 if (p_command='generate' and r.current_revision_id is not null) or (p_command<>'generate' and r.current_revision_id is null) then raise exception 'invalid_report_state'; end if;
 if p_command='edit' then
  select * into strict rev from public.vintage_report_revisions where id=r.current_revision_id;
  if p_content is null or jsonb_typeof(p_content) is distinct from 'object' or jsonb_typeof(p_content->'narrative') is distinct from 'string' or length(p_content->>'narrative') not between 1 and 100000 then raise exception 'invalid_narrative'; end if;
  e:=rev.evidence; content_value:=rev.content||jsonb_build_object('narrative',p_content->>'narrative','manually_edited',true);
 else
  if exists(select 1 from public.vintage_report_requests where report_id=r.id and status in ('queued','running')) then raise exception 'generation_in_progress'; end if;
  e:=public._vr_collect(p_vineyard_id,p_vintage,p_report_through);
 end if;
 insert into public.vintage_report_requests(operation_id,report_id,vineyard_id,authored_by,action,expected_revision_id,report_through,input,evidence)
 values(p_operation_id,r.id,p_vineyard_id,auth.uid(),p_command,p_expected_revision_id,case when p_command='edit' then rev.report_through else p_report_through end,original_input,e) returning * into q;
 if p_command='edit' then
  insert into public.vintage_report_revisions(report_id,vineyard_id,revision,operation_id,action,report_through,collected_at,evidence,content,created_by)
  values(r.id,r.vineyard_id,(select coalesce(max(revision),0)+1 from public.vintage_report_revisions where report_id=r.id),q.operation_id,'edit',q.report_through,rev.collected_at,e,content_value,auth.uid()) returning * into rev;
  update public.vintage_reports set current_revision_id=rev.id where id=r.id;
  update public.vintage_report_requests set status='succeeded',result_revision_id=rev.id where operation_id=q.operation_id returning * into q;
 end if;
 return to_jsonb(q)-'evidence'-'input';
end $$;
revoke all on function public.vintage_report_command(text,uuid,integer,uuid,uuid,date,jsonb,integer,uuid,integer) from public,anon;
grant execute on function public.vintage_report_command(text,uuid,integer,uuid,uuid,date,jsonb,integer,uuid,integer) to authenticated;

-- Service-only exact-operation claim and atomic revision commit. No paid-call replay.
create function public.vintage_report_worker(p_operation_id uuid,p_author uuid,p_command text,p_content jsonb default null,p_error text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare q public.vintage_report_requests%rowtype; r public.vintage_reports%rowtype; rev public.vintage_report_revisions%rowtype;
begin
 select report_id into q.report_id from public.vintage_report_requests where operation_id=p_operation_id;
 select * into strict r from public.vintage_reports where id=q.report_id for update;
 select * into strict q from public.vintage_report_requests where operation_id=p_operation_id for update;
 if q.authored_by<>p_author then raise exception 'not_authorised'; end if;
 -- Service-only entry; authenticate the actual persisted author again inside the transaction.
 perform set_config('request.jwt.claim.sub',p_author::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_author,'role','authenticated')::text,true);
 if not public.can_use_vineyard_insights(q.vineyard_id) then raise exception 'not_authorised' using errcode='42501'; end if;
 if p_command='claim' then
  if q.status='queued' then
   if r.current_revision_id is distinct from q.expected_revision_id then
    update public.vintage_report_requests set status='failed',error_code='revision_conflict' where operation_id=q.operation_id returning * into q;
    return to_jsonb(q)||jsonb_build_object('claimed',false);
   end if;
   update public.vintage_report_requests set status='running',started_at=clock_timestamp() where operation_id=q.operation_id returning * into q;
   return to_jsonb(q)||jsonb_build_object('claimed',true,'existing',(select content from public.vintage_report_revisions where id=q.expected_revision_id),'previous_evidence',(select evidence from public.vintage_report_revisions where id=q.expected_revision_id));
  end if;
  return to_jsonb(q)||jsonb_build_object('claimed',false);
 end if;
 if p_command='recover' and q.status in ('running','failed') then
  select validated_content into p_content from public.vintage_report_diagnostics where operation_id=q.operation_id;
  if p_content is null then return to_jsonb(q)-'evidence'-'input'; end if;
  update public.vintage_report_requests set status='running',error_code=null where operation_id=q.operation_id returning * into q;
  p_command:='commit';
 end if;
 if q.status<>'running' then return to_jsonb(q)-'evidence'-'input'; end if;
 if p_command in ('fail','unchanged') then
  update public.vintage_report_requests set status=case when p_command='fail' then 'failed' else 'unchanged' end,error_code=p_error where operation_id=q.operation_id returning * into q;
 elsif p_command='commit' then
  if r.current_revision_id is distinct from q.expected_revision_id then
   update public.vintage_report_requests set status='failed',error_code='revision_conflict' where operation_id=q.operation_id returning * into q;
  else
   if p_content is null or jsonb_typeof(p_content) is distinct from 'object' or jsonb_typeof(p_content->'narrative') is distinct from 'string' then raise exception 'invalid_content'; end if;
   insert into public.vintage_report_revisions(report_id,vineyard_id,revision,operation_id,action,report_through,collected_at,evidence,content,created_by)
   values(r.id,r.vineyard_id,(select coalesce(max(revision),0)+1 from public.vintage_report_revisions where report_id=r.id),q.operation_id,q.action,q.report_through,(q.evidence->>'collected_at')::timestamptz,q.evidence,p_content,q.authored_by) returning * into rev;
   -- Regeneration stays a saved candidate until explicit confirmation.
   if q.action<>'regenerate' then update public.vintage_reports set current_revision_id=rev.id where id=r.id; end if;
   update public.vintage_report_requests set status='succeeded',result_revision_id=rev.id where operation_id=q.operation_id returning * into q;
  end if;
 else raise exception 'invalid_worker_command'; end if;
 return to_jsonb(q)-'evidence'-'input';
end $$;
revoke all on function public.vintage_report_worker(uuid,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.vintage_report_worker(uuid,uuid,text,jsonb,text) to service_role;
-- Safe cancellation fence: an absent/queued operation becomes a durable failed receipt.
-- A delayed original request then returns this receipt instead of making a paid call.
-- Running operations are never discarded/cancelled by guessing their provider outcome.
create function public.vintage_report_abandon(p_vineyard_id uuid,p_vintage integer,p_operation_id uuid,p_input jsonb,p_author_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.vintage_reports%rowtype; q public.vintage_report_requests%rowtype; original_action text;
begin
 if p_author_id is distinct from auth.uid() or not public.can_use_vineyard_insights(p_vineyard_id) then raise exception 'not_authorised' using errcode='42501'; end if;
 original_action:=p_input->>'action';
 if p_vintage not between 1900 and 2200 or p_operation_id is null or original_action is null or original_action not in ('generate','regenerate','append','edit') or jsonb_typeof(p_input) is distinct from 'object' then raise exception 'invalid_operation'; end if;
 insert into public.vintage_reports(vineyard_id,vintage) values(p_vineyard_id,p_vintage) on conflict(vineyard_id,vintage) do nothing;
 select * into strict r from public.vintage_reports where vineyard_id=p_vineyard_id and vintage=p_vintage for update;
 select * into q from public.vintage_report_requests where operation_id=p_operation_id for update;
 if found then
  if q.authored_by<>auth.uid() or q.report_id<>r.id or q.input<>p_input then raise exception 'operation_id_reused'; end if;
  if q.status='queued' then update public.vintage_report_requests set status='failed',error_code='cancelled_before_provider' where operation_id=q.operation_id returning * into q; end if;
 else
  insert into public.vintage_report_requests(operation_id,report_id,vineyard_id,authored_by,action,expected_revision_id,report_through,input,evidence,status,error_code)
  values(p_operation_id,r.id,p_vineyard_id,auth.uid(),original_action,(p_input->>'expected')::uuid,current_date,p_input,'{}','failed','cancelled_before_acceptance') returning * into q;
 end if;
 return to_jsonb(q)-'evidence'-'input';
end $$;
revoke all on function public.vintage_report_abandon(uuid,integer,uuid,jsonb,uuid) from public,anon;
grant execute on function public.vintage_report_abandon(uuid,integer,uuid,jsonb,uuid) to authenticated;
commit;
