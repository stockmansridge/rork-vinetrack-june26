-- V2 FULL-CLONE REVIEW HARNESS. Never run against production.
-- Restore the complete current schema, extensions and password-free custom roles first.
-- Seed synthetic historical and editable record/job fixtures using the restored contracts.
-- Required psql variables: clone_schema_sha256, clone_roles_sha256, record_id, job_id.
-- Database name MUST start vinetrack_spray_v2_review_. Artifact hashes are attestation,
-- not proof of catalog parity: compare the restore manifest separately before running.
-- This validates additive storage/constraints; it does NOT certify execution authority,
-- RLS actor scenarios, successful replay or old RPC consumers. Those remain separate gates.
\set ON_ERROR_STOP on
\if :{?clone_schema_sha256}
\else
  \echo 'BLOCKED: full schema artifact fingerprint is required'
  \quit 3
\endif
\if :{?clone_roles_sha256}
\else
  \echo 'BLOCKED: custom-role artifact fingerprint is required'
  \quit 3
\endif
\if :{?record_id}
\else
  \echo 'BLOCKED: synthetic editable record fixture is required'
  \quit 3
\endif
\if :{?job_id}
\else
  \echo 'BLOCKED: synthetic editable job fixture is required'
  \quit 3
\endif
select set_config('vinetrack.review_schema_hash', :'clone_schema_sha256', false),
       set_config('vinetrack.review_roles_hash', :'clone_roles_sha256', false),
       set_config('vinetrack.review_record_id', :'record_id', false),
       set_config('vinetrack.review_job_id', :'job_id', false);
do $$ begin
  if current_database() !~ '^vinetrack_spray_v2_review_' then
    raise exception 'Refusing non-review database';
  end if;
  if current_setting('vinetrack.review_schema_hash') !~ '^[a-f0-9]{64}$'
     or current_setting('vinetrack.review_roles_hash') !~ '^[a-f0-9]{64}$' then
    raise exception 'Missing valid artifact fingerprints';
  end if;
  if to_regclass('public.spray_records') is null or to_regclass('public.spray_jobs') is null
     or to_regclass('auth.users') is null then raise exception 'Full native-auth schema restore is required'; end if;
  if not exists (select 1 from pg_trigger where tgrelid='public.spray_records'::regclass and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid='public.spray_jobs'::regclass and not tgisinternal) then
    raise exception 'Required existing trigger inventory is absent';
  end if;
  if not exists (select 1 from public.spray_records where id=current_setting('vinetrack.review_record_id')::uuid)
     or not exists (select 1 from public.spray_jobs where id=current_setting('vinetrack.review_job_id')::uuid) then
    raise exception 'Synthetic fixture IDs not found';
  end if;
end $$;

create temp table review_rows_before as
 select 'spray_records'::text as table_name, id, to_jsonb(r) as row_value from public.spray_records r
 union all select 'spray_jobs', id, to_jsonb(j) from public.spray_jobs j;
create temp table review_policies_before as select * from pg_policies where schemaname='public' and tablename in ('spray_records','spray_jobs');
create temp table review_permissions_before as select oid, relacl, relrowsecurity, relforcerowsecurity from pg_class where oid in ('public.spray_records'::regclass,'public.spray_jobs'::regclass);
create temp table review_triggers_before as
 select oid, tgrelid, pg_get_triggerdef(oid) as definition from pg_trigger where tgrelid in ('public.spray_records'::regclass,'public.spray_jobs'::regclass);

\ir spray_configuration_full_tank_planning_draft.sql
\ir spray_configuration_full_tank_planning_draft.sql

begin;
do $validation$
declare
 t text; col text; val text; rejected boolean; invalid_writes integer := 0;
 fixture uuid; count_columns integer; old_row record; new_row jsonb;
 inputs text[] := array['sprayer_configuration','spray_planning_method','full_tank_specification','planning_input_provenance','planning_intended_tank_litres','planning_target_area_ha','planning_calibrated_litres_per_hectare'];
 outputs text[] := array['planned_application_area_ha','resolved_planning_carrier_litres','resolved_planning_litres_per_hectare','resolved_planning_physical_row_litres_per_100m','resolved_planning_concentration_factor','controller_litres_per_100m_travel','effective_working_width_metres'];
 keys text[]; numeric_keys text[];
 provenance jsonb := '{"schema_version":1,"tank_text":" 1500.00 ","area_text":"3.00","rate_text":"","volume_unit":"litres","area_unit":"hectares","rate_area_unit":"hectare","country_code":"AU"}'::jsonb;
 malformed jsonb;
begin
 foreach t in array array['spray_records','spray_jobs'] loop
   keys := inputs || case when t='spray_records' then outputs else array[]::text[] end;
   select count(*) into count_columns from information_schema.columns where table_schema='public' and table_name=t and column_name=any(keys);
   if count_columns <> cardinality(keys) then raise exception 'Wrong v2 column inventory: %', t; end if;
   if exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name=any(keys) and (is_nullable<>'YES' or column_default is not null)) then raise exception 'Nullable/no-default contract failed'; end if;
   if t='spray_jobs' and exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name=any(outputs)) then raise exception 'Job has record-only v1/output columns; not a clean pre-v2 clone'; end if;
   for old_row in select * from review_rows_before where table_name=t loop
     execute format('select to_jsonb(r) - $1 from public.%I r where id=$2', t) into new_row using keys, old_row.id;
     if new_row is distinct from old_row.row_value - keys then raise exception 'Historical fields changed: % %', t,old_row.id; end if;
   end loop;
   fixture := current_setting(case when t='spray_records' then 'vinetrack.review_record_id' else 'vinetrack.review_job_id' end)::uuid;
   numeric_keys := array['planning_intended_tank_litres','planning_target_area_ha','planning_calibrated_litres_per_hectare'] || case when t='spray_records' then outputs else array[]::text[] end;
   foreach col in array numeric_keys loop
     foreach val in array array['0','-1','NaN','Infinity','-Infinity'] loop
       rejected := false;
       begin execute format('update public.%I set %I=$1::numeric where id=$2',t,col) using val,fixture;
       exception when check_violation then rejected := true; end;
       if not rejected then raise exception 'Invalid numeric accepted: % % %',t,col,val; end if;
       invalid_writes := invalid_writes + 1;
     end loop;
   end loop;
   foreach malformed in array array[
      '{}'::jsonb, '[]'::jsonb, 'null'::jsonb,
      provenance - 'schema_version', provenance || '{"schema_version":2}',
      provenance || '{"tank_text":1500}', provenance || '{"volume_unit":"gallons"}',
      provenance || '{"area_unit":"unknown"}', provenance || '{"rate_area_unit":"unknown"}',
      provenance || '{"country_code":" "}', provenance || '{"unexplained":true}'
   ] loop
     rejected := false;
     begin execute format('update public.%I set planning_input_provenance=$1 where id=$2',t) using malformed,fixture;
     exception when check_violation then rejected := true; end;
     if not rejected then raise exception 'Malformed provenance accepted on %: %',t,malformed; end if;
   end loop;
   foreach val in array array['litres','us_gallons','imperial_gallons'] loop
     execute format('update public.%I set sprayer_configuration=''standard_pass'',spray_planning_method=''full_tank'',full_tank_specification=''target_area'',planning_intended_tank_litres=1500,planning_target_area_ha=3,planning_input_provenance=$1 where id=$2',t)
       using provenance || jsonb_build_object('volume_unit',val),fixture;
   end loop;
   foreach val in array array['100m_travel','100ft_travel'] loop
     execute format('update public.%I set planning_input_provenance=$1 where id=$2',t)
       using provenance || jsonb_build_object('rate_area_unit',val,'rate_text','16.8'),fixture;
   end loop;
   -- Clear obsolete inputs and every output atomically. Omission is not SQL NULL.
   execute format('update public.%I set spray_planning_method=''by_area'',full_tank_specification=null,planning_intended_tank_litres=null,planning_target_area_ha=null,planning_calibrated_litres_per_hectare=null,planning_input_provenance=null where id=$1',t) using fixture;
   if t='spray_records' then
     execute 'update public.spray_records set planned_application_area_ha=null,resolved_planning_carrier_litres=null,resolved_planning_litres_per_hectare=null,resolved_planning_physical_row_litres_per_100m=null,resolved_planning_concentration_factor=null,controller_litres_per_100m_travel=null,effective_working_width_metres=null where id=$1' using fixture;
   end if;
   execute format('select to_jsonb(r) from public.%I r where id=$1',t) into new_row using fixture;
   foreach col in array array['full_tank_specification','planning_intended_tank_litres','planning_target_area_ha','planning_calibrated_litres_per_hectare','planning_input_provenance'] || case when t='spray_records' then outputs else array[]::text[] end loop
     if new_row -> col is distinct from 'null'::jsonb then raise exception 'Explicit clearing did not persist: % %',t,col; end if;
   end loop;
   -- Storage CHECKs intentionally permit incomplete drafts. This is NOT admission success.
 end loop;
 if exists ((select * from review_policies_before except select * from pg_policies where schemaname='public' and tablename in ('spray_records','spray_jobs')) union all (select * from pg_policies where schemaname='public' and tablename in ('spray_records','spray_jobs') except select * from review_policies_before)) then raise exception 'Existing RLS changed'; end if;
 if exists (select 1 from review_permissions_before b join pg_class c on c.oid=b.oid where c.relacl is distinct from b.relacl or c.relrowsecurity<>b.relrowsecurity or c.relforcerowsecurity<>b.relforcerowsecurity) then raise exception 'Privileges/RLS flags changed'; end if;
 if exists (select 1 from review_triggers_before b left join pg_trigger t on t.oid=b.oid where t.oid is null or pg_get_triggerdef(t.oid)<>b.definition) then raise exception 'Existing triggers changed'; end if;
 raise notice 'V2 STORAGE CHECKS PASS: 21 nullable columns, repeated draft, historical preservation, % invalid numeric assignments, malformed provenance, gallon variants and explicit clearing. NOT actor/RPC/compliance/replay acceptance.',invalid_writes;
end;
$validation$;
rollback;
