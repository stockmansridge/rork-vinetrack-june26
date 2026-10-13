-- OBSOLETE v1 HARNESS: intentionally disabled after the unapplied v2 draft amendment.
-- Do not cite prior v1 runs as v2 validation. Review/update this harness before use.
\quit
-- LOCAL NON-PRODUCTION CONTRACT HARNESS ONLY. Never run on an existing database.
-- Invoke psql on a fresh disposable database with ON_ERROR_STOP=1.
-- These representative tables test the draft's additive contract, not a staging clone.
\set ON_ERROR_STOP on
begin;
do $$ begin
  if to_regclass('public.spray_records') is not null or to_regclass('public.spray_jobs') is not null then
    raise exception 'Validation requires an empty disposable database';
  end if;
end $$;
create table public.spray_records (
  id uuid primary key, vineyard_id uuid not null, tanks jsonb,
  row_spacing_metres numeric, applied_litres_per_100m numeric,
  date timestamptz, updated_at timestamptz, sync_version integer
);
create table public.spray_jobs (
  id uuid primary key, vineyard_id uuid not null, chemical_lines jsonb,
  water_volume numeric, spray_rate_per_ha numeric, is_template boolean,
  updated_at timestamptz
);
alter table public.spray_records enable row level security;
alter table public.spray_jobs enable row level security;
create policy fixture_record_scope on public.spray_records using (vineyard_id = '00000000-0000-0000-0000-000000000001'::uuid);
create policy fixture_job_scope on public.spray_jobs using (vineyard_id = '00000000-0000-0000-0000-000000000001'::uuid);
insert into public.spray_records values ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '[{"frozen":true}]', 2.8, 20, '2020-01-01', '2020-01-02', 4);
insert into public.spray_jobs values ('00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', '[{"frozen":true}]', 1000, 500, true, '2020-01-02');
create table review_before as
 select 'spray_records' as table_name, to_jsonb(r) as row_value from public.spray_records r
 union all select 'spray_jobs', to_jsonb(j) from public.spray_jobs j;
create table review_policies_before as select * from pg_policies where tablename in ('spray_records','spray_jobs');
create table review_permissions_before as select oid, relacl, relrowsecurity, relforcerowsecurity from pg_class where oid in ('public.spray_records'::regclass, 'public.spray_jobs'::regclass);
commit;
\ir spray_configuration_full_tank_planning_draft.sql
\ir spray_configuration_full_tank_planning_draft.sql

do $validation$
declare
 t text; col text; val text; rejected boolean; checks integer := 0;
 keys text[] := array['sprayer_configuration','spray_planning_method','full_tank_specification','planned_application_area_ha','planning_tank_capacity_litres','planning_calibrated_litres_per_hectare','controller_litres_per_100m_travel','effective_working_width_metres'];
 old_row jsonb; new_row jsonb;
begin
 foreach t in array array['spray_records','spray_jobs'] loop
   select row_value into old_row from review_before where table_name=t;
   execute format('select to_jsonb(r) - $1 from public.%I r', t) into new_row using keys;
   if new_row <> old_row then raise exception 'Historical row changed: %', t; end if;
   execute format('select count(*) from public.%I where sprayer_configuration is not null or spray_planning_method is not null or full_tank_specification is not null or planned_application_area_ha is not null or planning_tank_capacity_litres is not null or planning_calibrated_litres_per_hectare is not null',t) into checks;
   if checks <> 0 then raise exception 'Historical unknown intent defaulted'; end if;
   if exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name=any(keys) and (is_nullable <> 'YES' or column_default is not null)) then raise exception 'Nullable/no-default contract failed'; end if;
   foreach col in array array['planned_application_area_ha','planning_tank_capacity_litres','planning_calibrated_litres_per_hectare'] loop
     foreach val in array array['0','-1','NaN','Infinity','-Infinity'] loop
       rejected := false;
       begin execute format('update public.%I set %I = %L::numeric', t,col,val);
       exception when check_violation then rejected := true; end;
       if not rejected then raise exception 'Invalid % accepted: % %',t,col,val; end if;
     end loop;
   end loop;
   rejected := false;
   begin execute format('update public.%I set sprayer_configuration = ''unknown''',t);
   exception when check_violation then rejected := true; end;
   if not rejected then raise exception 'Invalid configuration accepted'; end if;
   rejected := false;
   begin execute format('update public.%I set spray_planning_method = ''unknown''',t);
   exception when check_violation then rejected := true; end;
   if not rejected then raise exception 'Invalid method accepted'; end if;
   rejected := false;
   begin execute format('update public.%I set full_tank_specification = ''target_area''',t);
   exception when check_violation then rejected := true; end;
   if not rejected then raise exception 'Full-tank spec with NULL method accepted'; end if;
   execute format('update public.%I set sprayer_configuration = ''over_row_two_rows'', spray_planning_method = ''full_tank'', full_tank_specification = ''target_area'', planned_application_area_ha=2, planning_tank_capacity_litres=1000',t);
   rejected := false;
   begin execute format('update public.%I set spray_planning_method = ''by_area''',t);
   exception when check_violation then rejected := true; end;
   if not rejected then raise exception 'Full-tank spec with by-area accepted'; end if;
   execute format('update public.%I set full_tank_specification=''calibrated_rate'', planning_calibrated_litres_per_hectare=500',t);
 end loop;
 foreach col in array array['controller_litres_per_100m_travel','effective_working_width_metres'] loop
   foreach val in array array['0','-1','NaN','Infinity','-Infinity'] loop
     rejected := false;
     begin execute format('update public.spray_records set %I = %L::numeric',col,val);
     exception when check_violation then rejected := true; end;
     if not rejected then raise exception 'Invalid % accepted: %',col,val; end if;
   end loop;
 end loop;
 if exists ((select * from review_policies_before except select * from pg_policies where tablename in ('spray_records','spray_jobs')) union all (select * from pg_policies where tablename in ('spray_records','spray_jobs') except select * from review_policies_before)) then raise exception 'RLS policies changed'; end if;
 if exists (select 1 from review_permissions_before b join pg_class c on c.oid=b.oid where c.relacl is distinct from b.relacl or c.relrowsecurity<>b.relrowsecurity or c.relforcerowsecurity<>b.relforcerowsecurity) then raise exception 'Permissions/RLS flags changed'; end if;
 select count(*) into checks from pg_constraint where conrelid in ('public.spray_records'::regclass,'public.spray_jobs'::regclass) and (conname like '%sprayer_configuration_check' or conname like '%spray_planning_method_check' or conname like '%full_tank_specification_check' or conname like '%planned_application_area_ha_check' or conname like '%planning_tank_capacity_litres_check' or conname like '%planning_calibrated_litres_per_hectare_check' or conname like '%controller_litres_per_100m_travel_check' or conname like '%effective_working_width_metres_check');
 if checks <> 14 then raise exception 'Expected 14 constraints, found %',checks; end if;
 raise notice 'PASS: repeatability, 14 nullable/no-default columns, frozen historical rows, 40 invalid numeric writes, enums/specification dependencies, unchanged RLS policies and table privileges';
end;
$validation$;
