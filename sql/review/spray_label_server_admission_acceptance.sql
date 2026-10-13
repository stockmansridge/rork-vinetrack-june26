-- UNEXECUTED server-boundary acceptance, separate from additive SQL v2 storage.
-- Run only AFTER full restore parity and a separately reviewed server gate are installed.
-- This is not a replacement fixture schema or a claim the gate currently exists.
-- Requires synthetic, editable NON-manual NON-template record_id, matching vineyard_id,
-- and owner_actor_id seeded in restored auth.users/vineyard_members.
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
begin;
select set_config('vinetrack.review_record_id', :'record_id', true),
       set_config('vinetrack.review_vineyard_id', :'vineyard_id', true),
       set_config('request.jwt.claim.sub', :'owner_actor_id', true),
       set_config('request.jwt.claims', jsonb_build_object('sub', :'owner_actor_id', 'role', 'authenticated')::text, true);
do $$ begin
 if current_database() !~ '^vinetrack_spray_v2_review_' then raise exception 'Refusing non-review database'; end if;
 if to_regclass('auth.users') is null then raise exception 'Native-auth restore absent'; end if;
 if not exists (select 1 from public.spray_records where id=current_setting('vinetrack.review_record_id')::uuid
   and vineyard_id=current_setting('vinetrack.review_vineyard_id')::uuid and not coalesce(is_template,false)
   and coalesce(entry_source,'')<>'manual' and deleted_at is null and end_time is null) then
   raise exception 'Editable, synthetic operational fixture missing';
 end if;
end $$;
create temp table label_admission_before as
 select to_jsonb(r) value from public.spray_records r where id=current_setting('vinetrack.review_record_id')::uuid;
grant select on label_admission_before to authenticated;
set local role authenticated;
do $test$
declare
 recipe jsonb; rejection text; unchanged jsonb; accepted integer;
 recipes jsonb[] := array[
  '[{"id":"71000000-0000-4000-8000-000000000001","tankNumber":1,"waterVolume":1500,"concentrationFactor":1.426,"chemicals":[{"id":"71000000-0000-4000-8000-000000000002","name":"Synthetic unverified dilute","rateBasis":"per_100_litres","ratePer100L":100,"ratePerHa":0,"volumePerTank":2139,"unit":"Millilitres"}]}]'::jsonb,
  -- Spoofing a numeric CF does not supply authoritative label/reference evidence.
  '[{"id":"71000000-0000-4000-8000-000000000001","tankNumber":1,"waterVolume":1500,"concentrationFactor":1,"chemicals":[{"id":"71000000-0000-4000-8000-000000000002","name":"Synthetic unverified dilute","rateBasis":"per_100_litres","ratePer100L":100,"ratePerHa":0,"volumePerTank":2139,"unit":"Millilitres"}]}]'::jsonb,
  -- Legacy ambiguous basis must not silently become area permission.
  '[{"id":"71000000-0000-4000-8000-000000000001","tankNumber":1,"waterVolume":1500,"concentrationFactor":1.426,"chemicals":[{"id":"71000000-0000-4000-8000-000000000002","name":"Synthetic ambiguous","ratePer100L":100,"ratePerHa":1,"volumePerTank":2139,"unit":"Millilitres"}]}]'::jsonb
 ];
begin
 if not public.has_vineyard_role(current_setting('vinetrack.review_vineyard_id')::uuid,array['owner']) then
   raise exception 'Owner fixture/RLS precondition missing; denial would not prove chemical admission';
 end if;
 -- First prove the exact role/row is editable. RLS denial is NOT chemical evidence.
 update public.spray_records set notes=notes where id=current_setting('vinetrack.review_record_id')::uuid;
 get diagnostics accepted = row_count;
 if accepted<>1 then raise exception 'Owner cannot edit the target row'; end if;
 foreach recipe in array recipes loop
   rejection := null;
   begin
     update public.spray_records set tanks=recipe where id=current_setting('vinetrack.review_record_id')::uuid;
     get diagnostics accepted = row_count;
     if accepted<>1 then raise exception 'Target row disappeared'; end if;
   exception when sqlstate '23514' then
     get stacked diagnostics rejection = message_text;
   end;
   -- Reviewed server admission must use this explicit code. Other CHECK/RLS
   -- failures are setup errors, never a chemical-safety pass.
   if rejection not like 'SPRAY_LABEL_AUTHORITY_UNVERIFIED%' then
     raise exception 'SERVER ADMISSION FAIL: unverified recipe accepted or rejected for unrelated reason (%)',rejection;
   end if;
   select to_jsonb(r) into unchanged from public.spray_records r where id=current_setting('vinetrack.review_record_id')::uuid;
   -- set_updated_at may change on the no-op edit above. All operational evidence remains identical.
   if unchanged - array['updated_at','client_updated_at','sync_version'] is distinct from
      (select value - array['updated_at','client_updated_at','sync_version'] from label_admission_before) then
     raise exception 'Rejected recipe changed the spray record';
   end if;
 end loop;
 raise notice 'DIRECT RECORD ADMISSION PASS for unverified concentrate, spoofed CF and ambiguous old-client recipe. Job activation/Trip/start RPC and zero-side-effect tests are still separate.';
end;
$test$;
rollback;
