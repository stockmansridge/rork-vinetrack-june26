-- TEST HARNESS ONLY: a fresh disposable localhost cluster, never an existing DB.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role fixture_client login noinherit nosuperuser nocreaterole;
grant authenticated to fixture_client;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table public.vineyards(id uuid primary key);
create table public.vineyard_members(vineyard_id uuid,user_id uuid,role text,primary key(vineyard_id,user_id));
create table public.work_tasks(id uuid primary key,vineyard_id uuid,deleted_at timestamptz);
create table public.worker_types(id uuid primary key,vineyard_id uuid,deleted_at timestamptz);
create table public.tractors(id uuid primary key,vineyard_id uuid,deleted_at timestamptz);
create table public.vineyard_machines(id uuid primary key,vineyard_id uuid,deleted_at timestamptz);
create table public.paddocks(id uuid primary key,vineyard_id uuid references public.vineyards(id),name text,deleted_at timestamptz,rows jsonb);
alter table public.paddocks enable row level security;
create function public.has_vineyard_role(v uuid,r text[]) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from vineyard_members where vineyard_id=v and user_id=auth.uid() and role=any(r))$$;
create function public.is_vineyard_member(v uuid) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from vineyard_members where vineyard_id=v and user_id=auth.uid())$$;
create function public.set_updated_at() returns trigger language plpgsql as $$begin new.updated_at=now(); return new; end$$;
\ir ../006_trips_sync.sql
alter table public.trips add column trip_function text,add column tractor_id uuid,add column operator_user_id uuid,
 add column machine_id uuid,add column start_engine_hours numeric,add column end_engine_hours numeric,add column completion_notes text,
 add column work_task_id uuid references public.work_tasks(id),add column worker_type_id uuid references public.worker_types(id),
 add column seeding_details jsonb,add column trip_title text,add column manual_correction_events jsonb;
grant usage on schema public,auth to authenticated,anon,service_role;
grant select,insert,update on public.trips to authenticated;
grant select,insert,update on public.trips to service_role;
grant select on public.paddocks to authenticated;
create policy paddock_members on public.paddocks for select to authenticated using(public.is_vineyard_member(vineyard_id));
insert into auth.users values('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002');
insert into public.vineyards values('20000000-0000-4000-8000-000000000001'),('20000000-0000-4000-8000-000000000002');
insert into public.vineyard_members values
 ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','operator'),
 ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','operator');
insert into public.paddocks(id,vineyard_id,name,deleted_at) values
 ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Block X',null),
 ('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','Block Y',null),
 ('30000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000002','Other vineyard',null);
update public.paddocks set rows='[
 {"id":"31000000-0000-4000-8000-000000000001","number":38,"startPoint":{"latitude":-33.4,"longitude":149.1},"endPoint":{"latitude":-33.399,"longitude":149.1}},
 {"id":"31000000-0000-4000-8000-000000000002","number":39,"startPoint":{"latitude":-33.4,"longitude":149.10003},"endPoint":{"latitude":-33.399,"longitude":149.10003}}
]';
-- Snapshot legacy rows before the additive migration to prove there is no rewrite.
insert into public.trips(id,vineyard_id,row_sequence,completed_paths,skipped_paths) values
 ('40000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','[38.5]','[38.5]','[]'),
 ('40000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','[38.5,38.5]','[38.5]','[]');
create table public.fixture_legacy_before as select to_jsonb(t) payload from public.trips t;
create table public.spray_row_assignment_evidence(id uuid default gen_random_uuid(),trip_id uuid,row_number numeric,status text);
-- Adapter tests deliberately stub NON-coverage facts; this is not full canonical report-chain validation.
create function public.get_spray_report_v1(p_trip_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.trips; rows jsonb;
begin
 select * into t from public.trips where id=p_trip_id;
 if t.id is null or not public.is_vineyard_member(t.vineyard_id) then raise exception 'REPORT_FORBIDDEN' using errcode='42501'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('rowNumber',n,'blockName',null,'status',
   case when t.completed_paths @> jsonb_build_array(n) then 'Complete' else 'Not recorded' end,'tank',null)),'[]')
   into rows from jsonb_array_elements(t.row_sequence) n;
 return jsonb_build_object('schemaVersion','1.0','rows',rows,'warnings','[]'::jsonb,
   'tankSessions','[]'::jsonb,'weather',jsonb_build_array('fixture weather unchanged'),
   'cost',jsonb_build_object('visibility','restricted'),'application',jsonb_build_object('marker','unchanged'));
end $$;
revoke all on function public.get_spray_report_v1(uuid) from public,anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;
create table public.fixture_legacy_reports as select id,public.get_spray_report_v1(id) payload from public.trips where false;
-- Build baselines as a synthetic member without changing production history.
set request.jwt.claim.sub='10000000-0000-4000-8000-000000000001';
insert into public.fixture_legacy_reports select id,public.get_spray_report_v1(id) from public.trips;
reset request.jwt.claim.sub;
