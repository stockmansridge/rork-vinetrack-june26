-- Rollback-only isolated verification for SQL 237.
-- Run only in a disposable database after loading the normal schema, SQL 236,
-- and then SQL 237 directly. Never run against a linked/live project.
\set ON_ERROR_STOP on
begin;

do $test$
declare
  admin_member uuid := gen_random_uuid();
  admin_outsider uuid := gen_random_uuid();
  owner_member uuid := gen_random_uuid();
  vineyard_a uuid := gen_random_uuid();
  vineyard_b uuid := gen_random_uuid();
  block_a uuid := gen_random_uuid();
  visit_id uuid := gen_random_uuid();
  assessment_id uuid := gen_random_uuid();
  observation_id uuid := gen_random_uuid();
  photo_id uuid := gen_random_uuid();
  pin_id uuid := gen_random_uuid();
  growth_id uuid := gen_random_uuid();
  note_id uuid := gen_random_uuid();
  new_note_id uuid := gen_random_uuid();
  failed boolean;
  queue_row public.scout_photo_cleanup_queue%rowtype;
  marker_count integer;
  path text;
  function_name text;
begin
  if not exists(select 1 from pg_class where oid='public.vineyard_insights_deletions'::regclass and relrowsecurity)
     or not exists(select 1 from pg_class where oid='public.scout_photo_cleanup_queue'::regclass and relrowsecurity) then
    raise exception 'S1 FAIL: RLS is not enabled on both SQL 237 tables';
  end if;
  if has_table_privilege('anon','public.vineyard_insights_deletions','select')
     or has_table_privilege('authenticated','public.scout_photo_cleanup_queue','select')
     or not has_table_privilege('authenticated','public.vineyard_insights_deletions','select') then
    raise exception 'S2 FAIL: Data API grants are inconsistent with RLS';
  end if;
  foreach function_name in array array[
    'hard_delete_scout_visit(uuid,uuid,uuid,timestamptz)',
    'hard_delete_vintage_note(uuid,uuid,uuid,timestamptz)',
    'claim_scout_photo_cleanup(uuid,integer)',
    'complete_scout_photo_cleanup(uuid,uuid)',
    'fail_scout_photo_cleanup(uuid,uuid,text)'
  ] loop
    if exists(
         select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) acl
         where p.oid=('public.'||function_name)::regprocedure
           and acl.grantee=0 and acl.privilege_type='EXECUTE'
       ) or has_function_privilege('anon','public.'||function_name,'execute')
       or not has_function_privilege('authenticated','public.'||function_name,'execute') then
      raise exception 'S3 FAIL: function grants incorrect for %', function_name;
    end if;
    if position('pg_catalog, public' in pg_get_functiondef(('public.'||function_name)::regprocedure)) = 0 then
      raise exception 'S4 FAIL: fixed safe search_path missing for %', function_name;
    end if;
  end loop;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at) values
    (admin_member,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t237-admin-member@test.local','x',now(),now(),now()),
    (admin_outsider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t237-admin-outsider@test.local','x',now(),now(),now()),
    (owner_member,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t237-owner@test.local','x',now(),now(),now());
  insert into public.profiles(id,email) values
    (admin_member,'t237-admin-member@test.local'),(admin_outsider,'t237-admin-outsider@test.local'),(owner_member,'t237-owner@test.local') on conflict do nothing;
  insert into public.vineyards(id,name) values(vineyard_a,'T237 A'),(vineyard_b,'T237 B');
  insert into public.vineyard_members(vineyard_id,user_id,role) values
    (vineyard_a,admin_member,'manager'),(vineyard_a,owner_member,'owner');
  insert into public.system_admins(user_id,email,is_active) values
    (admin_member,'t237-admin-member@test.local',true),(admin_outsider,'t237-admin-outsider@test.local',true);
  insert into public.paddocks(id,vineyard_id,name) values(block_a,vineyard_a,'Block A');
  insert into public.pins(id,vineyard_id,mode,growth_stage_code) values(pin_id,vineyard_a,'Growth','EL23');
  insert into public.growth_stage_records(id,vineyard_id,pin_id,stage_code,observed_at) values(growth_id,vineyard_a,pin_id,'EL23',now());
  insert into public.scout_visits(id,vineyard_id,vintage_year,scout_date) values(visit_id,vineyard_a,2026,current_date);
  insert into public.scout_block_assessments(id,scout_visit_id,vineyard_id,paddock_id) values(assessment_id,visit_id,vineyard_a,block_a);
  insert into public.scout_observations(id,assessment_id,vineyard_id,item_kind,linked_pin_id,linked_growth_record_id) values(observation_id,assessment_id,vineyard_a,'growth_stage',pin_id,growth_id);
  path := vineyard_a||'/'||observation_id||'/'||photo_id||'.jpg';
  insert into public.scout_observation_photos(id,observation_id,vineyard_id,storage_path,captured_at) values(photo_id,observation_id,vineyard_a,path,now());
  insert into public.vintage_notes(id,vineyard_id,note_date,vintage_year,notes) values(note_id,vineyard_a,current_date,2026,'exact note');
  insert into public.vineyard_insights_deletions(vineyard_id,entity_type,entity_id,deleted_by,operation_id)
    values(vineyard_b,'vintage_note',gen_random_uuid(),admin_member,gen_random_uuid());

  perform set_config('request.jwt.claims',json_build_object('sub',admin_member::text,'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
  perform public.hard_delete_scout_visit(vineyard_a,visit_id,gen_random_uuid(),now()-interval '1 year');
  perform public.hard_delete_scout_visit(vineyard_a,visit_id,gen_random_uuid(),now());
  if exists(select 1 from public.scout_visits where id=visit_id)
     or exists(select 1 from public.scout_block_assessments where id=assessment_id)
     or exists(select 1 from public.scout_observations where id=observation_id)
     or exists(select 1 from public.scout_observation_photos where id=photo_id) then
    raise exception 'B1 FAIL: Scout rows/children were not physically removed';
  end if;
  if not exists(select 1 from public.pins where id=pin_id) or not exists(select 1 from public.growth_stage_records where id=growth_id) then
    raise exception 'B2 FAIL: canonical Growth Stage data was removed';
  end if;
  if not exists(select 1 from public.scout_photo_cleanup_queue where photo_id=photo_id and storage_path=path) then
    raise exception 'B3 FAIL: photo cleanup path was not captured before cascade';
  end if;
  select count(*) into marker_count from public.vineyard_insights_deletions where entity_id=visit_id;
  if marker_count<>1 then raise exception 'B4 FAIL: Scout delete is not idempotent'; end if;

  perform public.hard_delete_vintage_note(vineyard_a,note_id,gen_random_uuid(),now());
  perform public.hard_delete_vintage_note(vineyard_a,note_id,gen_random_uuid(),now());
  if exists(select 1 from public.vintage_notes where id=note_id) then raise exception 'B5 FAIL: note remains'; end if;
  select count(*) into marker_count from public.vineyard_insights_deletions where entity_id=note_id;
  if marker_count<>1 then raise exception 'B6 FAIL: note delete is not idempotent'; end if;

  failed:=false;
  begin insert into public.vintage_notes(id,vineyard_id,note_date,vintage_year,notes) values(note_id,vineyard_a,current_date,2026,'stale');
  exception when unique_violation then failed:=true; end;
  if not failed then raise exception 'B7 FAIL: stale deleted ID was recreated'; end if;
  insert into public.vintage_notes(id,vineyard_id,note_date,vintage_year,notes) values(new_note_id,vineyard_a,current_date,2026,'new id');

  select * into queue_row from public.claim_scout_photo_cleanup(vineyard_a,1);
  if queue_row.id is null then raise exception 'Q1 FAIL: cleanup work was not claimable'; end if;
  perform public.fail_scout_photo_cleanup(queue_row.id,queue_row.lease_token,'transient');
  if not exists(select 1 from public.scout_photo_cleanup_queue where id=queue_row.id and status='failed') then raise exception 'Q2 FAIL: transient failure was not retained'; end if;
  update public.scout_photo_cleanup_queue set next_attempt_at=now()-interval '1 second' where id=queue_row.id;
  select * into queue_row from public.claim_scout_photo_cleanup(vineyard_a,1);
  perform public.complete_scout_photo_cleanup(queue_row.id,queue_row.lease_token);
  if not exists(select 1 from public.scout_photo_cleanup_queue where id=queue_row.id and status='completed') then raise exception 'Q3 FAIL: successful cleanup was not acknowledged'; end if;

  if exists(select 1 from public.vineyard_insights_deletions where vineyard_id=vineyard_b) then
    raise exception 'A1 FAIL: cross-vineyard ledger read was allowed';
  end if;
  failed:=false;
  begin perform public.hard_delete_vintage_note(vineyard_b,new_note_id,gen_random_uuid(),now());
  exception when insufficient_privilege then failed:=true; end;
  if not failed then raise exception 'A2 FAIL: cross-vineyard deletion was allowed'; end if;

  perform set_config('role','postgres',true);
  perform set_config('request.jwt.claims',json_build_object('sub',admin_outsider::text,'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
  failed:=false; begin perform public.hard_delete_vintage_note(vineyard_a,new_note_id,gen_random_uuid(),now()); exception when insufficient_privilege then failed:=true; end;
  if not failed then raise exception 'A3 FAIL: System Admin without membership was allowed'; end if;

  perform set_config('role','postgres',true);
  perform set_config('request.jwt.claims',json_build_object('sub',owner_member::text,'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
  failed:=false; begin perform public.hard_delete_vintage_note(vineyard_a,new_note_id,gen_random_uuid(),now()); exception when insufficient_privilege then failed:=true; end;
  if not failed then raise exception 'A4 FAIL: non-System-Admin owner was allowed'; end if;

  perform set_config('role','anon',true);
  failed:=false; begin perform public.hard_delete_vintage_note(vineyard_a,new_note_id,gen_random_uuid(),now()); exception when others then failed:=true; end;
  if not failed then raise exception 'A5 FAIL: anonymous deletion was allowed'; end if;

  raise notice 'SQL 237 assertions ALL PASSED: S1-S4, B1-B7, Q1-Q3, A1-A5';
end $test$;
rollback;
