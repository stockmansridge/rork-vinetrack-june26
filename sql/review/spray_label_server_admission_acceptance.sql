-- UNEXECUTED review-only server test, separate from SQL v2 persistence.
-- Requires full restored native-auth schema + separately installed reviewed gate.
-- Run on a QUIESCENT isolated clone with synthetic data only, as the trusted restore owner.
-- Seed record_id with server-validated V=1500L, A=3ha, D=713L/ha evidence.
-- unknown_chemical_id: applicable identity/use/reference, concentrate permission unknown.
-- prohibited_chemical_id: applicable identity/use/reference, explicitly reviewed prohibition.
-- Both Saved Chemicals belong to vineyard_id; caller labels/numeric CF are not authority.
-- This tests direct UPDATE only; direct INSERT/job/Trip/tank/RPC matrices remain separate.
\set ON_ERROR_STOP on
\if :{?record_id}
\else
  \echo 'BLOCKED: synthetic editable record_id required'
  \quit 3
\endif
\if :{?vineyard_id}
\else
  \echo 'BLOCKED: synthetic vineyard_id required'
  \quit 3
\endif
\if :{?owner_actor_id}
\else
  \echo 'BLOCKED: synthetic native-auth owner_actor_id required'
  \quit 3
\endif
\if :{?unknown_chemical_id}
\else
  \echo 'BLOCKED: synthetic unknown-permission chemical fixture required'
  \quit 3
\endif
\if :{?prohibited_chemical_id}
\else
  \echo 'BLOCKED: synthetic explicitly prohibited chemical fixture required'
  \quit 3
\endif
begin;
select set_config('vinetrack.review_record_id', :'record_id', true),
       set_config('vinetrack.review_vineyard_id', :'vineyard_id', true),
       set_config('vinetrack.review_unknown_chemical_id', :'unknown_chemical_id', true),
       set_config('vinetrack.review_prohibited_chemical_id', :'prohibited_chemical_id', true),
       set_config('request.jwt.claim.sub', :'owner_actor_id', true),
       set_config('request.jwt.claims', jsonb_build_object('sub', :'owner_actor_id', 'role', 'authenticated')::text, true);
do $$ begin
 if current_database() !~ '^vinetrack_spray_v2_review_' then raise exception 'Refusing non-review database'; end if;
 if to_regclass('auth.users') is null then raise exception 'Native-auth restore absent'; end if;
 if not exists (select 1 from public.spray_records where id=current_setting('vinetrack.review_record_id')::uuid
   and vineyard_id=current_setting('vinetrack.review_vineyard_id')::uuid and not coalesce(is_template,false)
   and coalesce(entry_source,'')<>'manual' and deleted_at is null and end_time is null) then
   raise exception 'Editable synthetic operational fixture missing';
 end if;
 if current_setting('vinetrack.review_unknown_chemical_id')=current_setting('vinetrack.review_prohibited_chemical_id') then
   raise exception 'Unknown and prohibited evidence require distinct product fixtures';
 end if;
 if (select count(*) from public.saved_chemicals where vineyard_id=current_setting('vinetrack.review_vineyard_id')::uuid
    and id in (current_setting('vinetrack.review_unknown_chemical_id')::uuid,
               current_setting('vinetrack.review_prohibited_chemical_id')::uuid) and deleted_at is null)<>2 then
   raise exception 'Synthetic chemical identities missing or cross-vineyard';
 end if;
end $$;
-- Trusted test-only snapshot crosses RLS so hidden side effects cannot look unchanged.
-- Exact full JSON rows, not only counts; includes audit/version fields and every public
-- ordinary/partitioned table (records, jobs, Trips, tanks, inventory, labour, events, etc.).
-- The snapshot owner must be able to inspect all rows; row_security=off fails rather
-- than silently returning actor-filtered rows. No business rows are returned to the client.
create function pg_temp.label_review_state() returns jsonb
language plpgsql security definer set search_path=pg_catalog,pg_temp set row_security=off as $$
declare relation record; rows jsonb; result jsonb := '{}'::jsonb;
begin
 for relation in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind in ('r','p') order by c.relname loop
   execute format('select coalesce(jsonb_agg(value order by value::text), ''[]''::jsonb) from (select to_jsonb(r) value from public.%I r) x', relation.relname) into rows;
   result := result || jsonb_build_object(relation.relname,rows);
 end loop;
 return result;
end $$;
revoke all on function pg_temp.label_review_state() from public;
grant usage on schema pg_temp to authenticated;
grant execute on function pg_temp.label_review_state() to authenticated;
set local role authenticated;
do $test$
declare
 recipe jsonb; rejection text; rejection_detail text; rejection_hint text; accepted integer;
 before_state jsonb; scenario integer; product_id uuid;
 expected text[] := array['SPRAY_LABEL_AUTHORITY_UNVERIFIED','SPRAY_LABEL_RECIPE_INCONSISTENT',
                          'SPRAY_LABEL_RECIPE_INCONSISTENT','SPRAY_LABEL_CONCENTRATE_PROHIBITED'];
 scenario_names text[] := array['unknown concentrate permission','spoofed CF1 with contradictory quantity/reference',
                                'ambiguous old-client dual basis','explicit concentrate prohibition'];
begin
 if not public.has_vineyard_role(current_setting('vinetrack.review_vineyard_id')::uuid,array['owner']) then
   raise exception 'Owner fixture/RLS precondition missing; RLS denial is not chemical admission';
 end if;
 before_state := pg_temp.label_review_state();
 -- Prove legitimate edit admission then roll back its audit/trigger effects too.
 begin
   update public.spray_records set notes=notes where id=current_setting('vinetrack.review_record_id')::uuid;
   get diagnostics accepted = row_count;
   if accepted<>1 then raise exception 'Owner cannot edit target row'; end if;
   raise exception using errcode='ZT001',message='Review edit probe rollback';
 exception when sqlstate 'ZT001' then null;
 end;
 if pg_temp.label_review_state() is distinct from before_state then raise exception 'Edit probe rollback changed public state'; end if;
 for scenario in 1..4 loop
   product_id := current_setting(case when scenario=4 then 'vinetrack.review_prohibited_chemical_id'
      else 'vinetrack.review_unknown_chemical_id' end)::uuid;
   recipe := jsonb_build_array(jsonb_build_object('id','71000000-0000-4000-8000-000000000001',
     'tankNumber',1,'waterVolume',1500,'concentrationFactor',case when scenario=2 then 1 else 1.426 end,
     'chemicals',jsonb_build_array(jsonb_build_object('id','71000000-0000-4000-8000-000000000002',
       'savedChemicalId',product_id,'name','Synthetic review product','ratePer100L',100,
       'ratePerHa',case when scenario=3 then 1 else 0 end,'volumePerTank',2139,'unit','Millilitres'))));
   if scenario<>3 then
     recipe := jsonb_set(recipe,'{0,chemicals,0,rateBasis}','"per_100_litres"'::jsonb);
   end if;
   rejection := null; rejection_detail := null; rejection_hint := null;
   begin
     update public.spray_records set tanks=recipe where id=current_setting('vinetrack.review_record_id')::uuid;
     get diagnostics accepted = row_count;
     if accepted<>1 then raise exception 'Target row disappeared'; end if;
   exception when sqlstate '23514' then
     get stacked diagnostics rejection=message_text,rejection_detail=pg_exception_detail,rejection_hint=pg_exception_hint;
   end;
   -- Require the exact classified token, not an unrelated CHECK/RLS exception.
   -- Recipe consistency precedes unknown permission once trusted reference is established.
   if split_part(coalesce(rejection,''),':',1)<>expected[scenario] then
     raise exception 'SERVER ADMISSION FAIL [%]: expected %, received %',scenario_names[scenario],expected[scenario],rejection;
   end if;
   if position(product_id::text in coalesce(rejection_detail,''))=0 or nullif(btrim(coalesce(rejection_hint,'')),'') is null then
     raise exception 'SERVER ERROR FAIL [%]: affected product ID/actionable hint missing',scenario_names[scenario];
   end if;
   if pg_temp.label_review_state() is distinct from before_state then
     raise exception 'Rejected scenario [%] changed public operational/evidence state (including audit fields)',scenario_names[scenario];
   end if;
 end loop;
 raise notice 'DIRECT UPDATE admission passed four classified rejections with exact unchanged public state. Other operational boundaries remain untested.';
end;
$test$;
rollback;
