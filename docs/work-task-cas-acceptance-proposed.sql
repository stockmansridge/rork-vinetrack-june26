-- WITHDRAWN 2026-10-09. DO NOT EXECUTE; requires a rejected new-schema contract.
-- REVIEW-ONLY acceptance script. NOT EXECUTED. Run only on a disposable full
-- schema clone AFTER expansion AND enforcement. Entire session is rolled back.
-- Requires a migration administrator able to SET ROLE authenticated.
-- Fixture INSERT shapes must be confirmed against the clone's live constraints.
BEGIN;
SET LOCAL statement_timeout='60s';

CREATE TEMP TABLE cas_fixture ON COMMIT DROP AS SELECT
  gen_random_uuid() AS actor,gen_random_uuid() AS other_actor,
  gen_random_uuid() AS outsider,gen_random_uuid() AS viewer,
  gen_random_uuid() AS vineyard,gen_random_uuid() AS other_vineyard,
  gen_random_uuid() AS resource,gen_random_uuid() AS inactive_resource,
  gen_random_uuid() AS foreign_resource,gen_random_uuid() AS task,
  gen_random_uuid() AS date_task,gen_random_uuid() AS create_op,
  NULL::jsonb AS create_ack,NULL::jsonb AS date_ack;
GRANT SELECT,UPDATE ON cas_fixture TO authenticated;

INSERT INTO auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
SELECT u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  u::text||'@work-task-cas.invalid','x',now(),now(),now()
FROM cas_fixture f CROSS JOIN LATERAL unnest(ARRAY[f.actor,f.other_actor,f.outsider,f.viewer]) u;
INSERT INTO public.profiles(id,email)
SELECT u,u::text||'@work-task-cas.invalid'
FROM cas_fixture f CROSS JOIN LATERAL unnest(ARRAY[f.actor,f.other_actor,f.outsider,f.viewer]) u
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.vineyards(id,name,timezone)
SELECT vineyard,'CAS disposable A','Australia/Sydney' FROM cas_fixture
UNION ALL SELECT other_vineyard,'CAS disposable B','UTC' FROM cas_fixture;
INSERT INTO public.vineyard_members(vineyard_id,user_id,role)
SELECT vineyard,actor,'owner' FROM cas_fixture
UNION ALL SELECT vineyard,other_actor,'operator' FROM cas_fixture
UNION ALL SELECT other_vineyard,outsider,'owner' FROM cas_fixture;
-- 'viewer' fixture is a memberless account; do not fabricate a role value that
-- the deployed membership CHECK may not support. Add an actual read-only role
-- fixture separately only if that role exists in the reviewed schema.
INSERT INTO public.vineyard_external_resources(id,vineyard_id,name,kind,is_active)
SELECT resource,vineyard,'Active crew','crew',true FROM cas_fixture
UNION ALL SELECT inactive_resource,vineyard,'Inactive contractor','contractor',false FROM cas_fixture
UNION ALL SELECT foreign_resource,other_vineyard,'Foreign crew','crew',true FROM cas_fixture;

CREATE FUNCTION pg_temp.cas_assert(p_ok boolean,p_message text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'CAS assertion: %',p_message; END IF; END;
$fn$;
CREATE FUNCTION pg_temp.cas_expect_error(p_sql text,p_state text)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE got text;
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS got=RETURNED_SQLSTATE; END;
  IF got IS DISTINCT FROM p_state THEN
    RAISE EXCEPTION 'Expected SQLSTATE %, got % for %',p_state,coalesce(got,'success'),p_sql;
  END IF;
END;
$fn$;

-- Run behavioral calls with the REAL client DB role, not just a spoofed UID
-- while still operating as postgres. Only these rollback fixtures use set_config.
SELECT set_config('request.jwt.claim.sub',actor::text,true) FROM cas_fixture;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true) FROM cas_fixture;
SET LOCAL ROLE authenticated;
DO $tests$
DECLARE f record; a jsonb; b jsonb; c jsonb; patch jsonb; rev bigint; before_row jsonb;
  op uuid; instant text;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  patch:=jsonb_build_object('task_type','Pruning plan','schedule_basis','el_stage',
    'target_el_stage',35,'vintage_year',2027,'assigned_to',f.other_actor,'notes','first');
  a:=public.save_work_task_cas(f.task,f.vineyard,f.create_op,f.actor,NULL,'create',patch);
  PERFORM pg_temp.cas_assert(a->>'applied'='true','create applied');
  PERFORM pg_temp.cas_assert((a->>'server_revision')::bigint=1,'initial revision');
  PERFORM pg_temp.cas_assert(a#>>'{canonical,vintage_year}'='2027','explicit E-L vintage survives trigger');
  PERFORM pg_temp.cas_assert(a#>>'{canonical,start_date}' IS NULL
    AND a#>>'{canonical,planned_end_date}' IS NULL,'E-L has no planned range');
  PERFORM pg_temp.cas_assert(a#>>'{canonical,assigned_to}'=f.other_actor::text,'internal assignment');
  UPDATE cas_fixture SET create_ack=a;
  b:=public.save_work_task_cas(f.task,f.vineyard,f.create_op,f.actor,NULL,'create',patch);
  PERFORM pg_temp.cas_assert(a=b,'lost-response exact duplicate acknowledgement');
  SELECT to_jsonb(w) INTO before_row FROM public.work_tasks w WHERE id=f.task;
  PERFORM pg_temp.cas_assert(before_row->>'server_revision'='1','duplicate did not write');

  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,NULL,''create'',%L::jsonb)',
    f.task,f.vineyard,f.create_op,f.actor,(patch||'{"notes":"different"}'::jsonb)::text),'22023');
  b:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,NULL,'create',patch);
  PERFORM pg_temp.cas_assert(b->>'reason'='already_exists','duplicate ID never becomes update');
  PERFORM pg_temp.cas_assert(NOT EXISTS(SELECT 1 FROM public.work_task_write_receipts
    WHERE operation_id=(b->>'operation_id')::uuid),'conflict has no receipt');

  -- Revision AND optional expected values; failed predicates never become a rebase.
  b:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,1,'edit',
    '{"notes":"wrong","expected":{"assigned_to":null}}');
  PERFORM pg_temp.cas_assert(b->>'reason'='expected_mismatch','expected null conflicts');
  b:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,1,'edit','{"notes":"second"}');
  rev:=(b->>'server_revision')::bigint;
  PERFORM pg_temp.cas_assert(rev=2,'revision advances');
  c:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,1,'edit','{"notes":"stale"}');
  PERFORM pg_temp.cas_assert(c->>'reason'='revision_mismatch'
    AND c#>>'{canonical,notes}'='second','stale edit preserves newer value');
  c:=public.save_work_task_cas(f.task,f.vineyard,f.create_op,f.actor,NULL,'create',patch);
  PERFORM pg_temp.cas_assert(c=a,'receipt returns old exact ack despite divergent current row');

  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,2,''edit'',%L::jsonb)',
    f.task,f.vineyard,gen_random_uuid(),f.actor,jsonb_build_object('assigned_to',f.outsider)::text),'22023');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,2,''edit'',%L::jsonb)',
    f.task,f.vineyard,gen_random_uuid(),f.actor,jsonb_build_object(
      'assigned_external_resource_id',f.resource)::text),'22023'); -- both IDs non-null
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,2,''edit'',%L::jsonb)',
    f.task,f.vineyard,gen_random_uuid(),f.actor,jsonb_build_object(
      'assigned_to',NULL,'assigned_external_resource_id',f.foreign_resource)::text),'22023');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,2,''edit'',%L::jsonb)',
    f.task,f.vineyard,gen_random_uuid(),f.actor,jsonb_build_object(
      'assigned_to',NULL,'assigned_external_resource_id',f.inactive_resource)::text),'22023');
  b:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,2,'edit',
    jsonb_build_object('assigned_to',NULL,'assigned_external_resource_id',f.resource));
  PERFORM pg_temp.cas_assert(b#>>'{canonical,assigned_to}' IS NULL
    AND b#>>'{canonical,assigned_external_resource_id}'=f.resource::text,'explicit switch and clear');
  rev:=(b->>'server_revision')::bigint;
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,%s,''edit'',''{"target_el_stage":5}'')',
    f.task,f.vineyard,gen_random_uuid(),f.actor,rev),'22023');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,%s,''edit'',''{"schedule_basis":"date"}'')',
    f.task,f.vineyard,gen_random_uuid(),f.actor,rev),'22023');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,%s,''edit'',''{"target_el_stage":"35"}'')',
    f.task,f.vineyard,gen_random_uuid(),f.actor,rev),'22023');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,%s,''edit'',''{"piece_rate_per_vine":99}'')',
    f.task,f.vineyard,gen_random_uuid(),f.actor,rev),'22023');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,%s,''edit'',''{"completed_by":null}'')',
    f.task,f.vineyard,gen_random_uuid(),f.actor,rev),'22023');

  -- Completion by actor (NOT assigned crew/member), UTC -> vineyard day, future
  -- E-L compatibility date never constrains actual completion/business day.
  -- Deterministic UTC-midnight boundary: Sydney is 2020-01-02. Past authored
  -- instants also exercise offline completion before server-side create replay.
  instant:='2020-01-01T13:30:00Z';
  op:=gen_random_uuid();
  patch:=jsonb_build_object('completed_at',instant);
  b:=public.save_work_task_cas(f.task,f.vineyard,op,f.actor,rev,'complete',patch);
  PERFORM pg_temp.cas_assert(b#>>'{canonical,completed_by}'=f.actor::text,'authenticated actual completer');
  PERFORM pg_temp.cas_assert(b#>>'{canonical,assigned_external_resource_id}'=f.resource::text,'assignment retained');
  PERFORM pg_temp.cas_assert(b#>>'{canonical,target_el_stage}'='35','stage retained');
  PERFORM pg_temp.cas_assert((b#>>'{canonical,completed_at}')::timestamptz=instant::timestamptz,'authored instant not replay time');
  PERFORM pg_temp.cas_assert((b#>>'{canonical,completion_business_date}')::date=
    (instant::timestamptz AT TIME ZONE 'Australia/Sydney')::date,'vineyard day');
  c:=public.save_work_task_cas(f.task,f.vineyard,op,f.actor,rev,'complete',patch);
  PERFORM pg_temp.cas_assert(c=b,'complete retry is exact');
  rev:=(b->>'server_revision')::bigint;
  c:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,rev,'completion_date',
    jsonb_build_object('completion_business_date',to_char(
      (instant::timestamptz AT TIME ZONE 'Australia/Sydney')::date-1,'YYYY-MM-DD')));
  PERFORM pg_temp.cas_assert(c#>>'{canonical,completed_by}'=b#>>'{canonical,completed_by}'
    AND c#>>'{canonical,completed_at}'=b#>>'{canonical,completed_at}','date correction preserves audit');
  rev:=(c->>'server_revision')::bigint;
  c:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,rev,'reopen','{}');
  PERFORM pg_temp.cas_assert(c#>>'{canonical,completed_by}' IS NULL
    AND c#>>'{canonical,completed_at}' IS NULL
    AND c#>>'{canonical,completion_business_date}' IS NULL
    AND c#>>'{canonical,finalized_by}' IS NULL AND c#>>'{canonical,status}'='planned','reopen clears lifecycle');
  PERFORM pg_temp.cas_assert(c#>>'{canonical,target_el_stage}'='35'
    AND c#>>'{canonical,assigned_external_resource_id}'=f.resource::text,'reopen retains plan/assignment');

  -- Date range is kept in a separate field while legacy end_date mirrors completion.
  b:=public.save_work_task_cas(f.date_task,f.vineyard,gen_random_uuid(),f.actor,NULL,'create',
    '{"task_type":"Dated plan","schedule_basis":"date","date":"2020-01-01T00:00:00Z","planned_end_date":"2020-01-10T00:00:00Z"}');
  b:=public.save_work_task_cas(f.date_task,f.vineyard,gen_random_uuid(),f.actor,
    (b->>'server_revision')::bigint,'complete',jsonb_build_object('completed_at',instant));
  PERFORM pg_temp.cas_assert((b#>>'{canonical,planned_end_date}')::timestamptz=
    timestamptz '2020-01-10T00:00:00Z','completion preserves planned range');
  b:=public.save_work_task_cas(f.date_task,f.vineyard,gen_random_uuid(),f.actor,
    (b->>'server_revision')::bigint,'reopen','{}');
  PERFORM pg_temp.cas_assert(b#>>'{canonical,end_date}'=b#>>'{canonical,planned_end_date}',
    'reopen restores planned range mirror');
  UPDATE cas_fixture SET date_ack=b;

  -- Direct client writes/upsert, mutable receipts and membership impersonation.
  PERFORM pg_temp.cas_expect_error(format('UPDATE public.work_tasks SET notes=''unsafe'' WHERE id=%L',f.task),'42501');
  PERFORM pg_temp.cas_expect_error(format('INSERT INTO public.work_tasks(id,vineyard_id) VALUES(%L,%L) ON CONFLICT(id) DO UPDATE SET notes=''unsafe''',f.task,f.vineyard),'42501');
  PERFORM pg_temp.cas_expect_error(format('DELETE FROM public.work_tasks WHERE id=%L',f.task),'42501');
  PERFORM pg_temp.cas_expect_error(format('UPDATE public.work_task_write_receipts SET acknowledgement=''{}'' WHERE task_id=%L',f.task),'42501');
  PERFORM pg_temp.cas_expect_error(format('SELECT public.save_work_task_cas(%L,%L,%L,%L,1,''edit'',''{"notes":"fake author"}'')',f.task,f.vineyard,gen_random_uuid(),f.other_actor),'42501');
END;
$tests$;
RESET ROLE;

-- Frozen costing sentinel data on the disposable date task. This is not a
-- calculator rewrite, and no real task data is involved.
UPDATE public.work_tasks SET costing_method='piece_rate',piece_rate_per_vine=1.75,
  piece_vine_count=123 WHERE id=(SELECT date_task FROM cas_fixture);
CREATE TEMP TABLE cas_frozen_costs ON COMMIT DROP AS
SELECT w.id, jsonb_build_object('costing_method',w.costing_method,
  'piece_rate_per_vine',w.piece_rate_per_vine,'piece_vine_count',w.piece_vine_count,
  'resources',w.resources,'pruning_activity_id',w.pruning_activity_id) AS snapshot
FROM public.work_tasks w WHERE w.id=(SELECT date_task FROM cas_fixture);
GRANT SELECT ON cas_frozen_costs TO authenticated;
SELECT set_config('request.jwt.claim.sub',actor::text,true) FROM cas_fixture;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true) FROM cas_fixture;
SET LOCAL ROLE authenticated;
DO $frozen$
DECLARE f record; b jsonb; r bigint; expected jsonb; actual jsonb;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  SELECT snapshot INTO expected FROM cas_frozen_costs WHERE id=f.date_task;
  SELECT server_revision INTO r FROM public.work_tasks WHERE id=f.date_task;
  b:=public.save_work_task_cas(f.date_task,f.vineyard,gen_random_uuid(),f.actor,r,'complete',
    '{"completed_at":"2020-01-01T13:30:00Z"}');
  b:=public.save_work_task_cas(f.date_task,f.vineyard,gen_random_uuid(),f.actor,
    (b->>'server_revision')::bigint,'reopen','{}');
  SELECT jsonb_build_object('costing_method',w.costing_method,
    'piece_rate_per_vine',w.piece_rate_per_vine,'piece_vine_count',w.piece_vine_count,
    'resources',w.resources,'pruning_activity_id',w.pruning_activity_id)
    INTO actual FROM public.work_tasks w WHERE id=f.date_task;
  PERFORM pg_temp.cas_assert(expected=actual,'frozen rates/counts/resources/provenance unchanged');
END;
$frozen$;
RESET ROLE;

-- Historical inactive AND soft-deleted assignments survive an unrelated edit.
UPDATE public.vineyard_external_resources SET is_active=false,deleted_at=clock_timestamp()
WHERE id=(SELECT resource FROM cas_fixture);
SELECT set_config('request.jwt.claim.sub',actor::text,true) FROM cas_fixture;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true) FROM cas_fixture;
SET LOCAL ROLE authenticated;
DO $history$
DECLARE f record; r bigint; b jsonb;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  SELECT server_revision INTO r FROM public.work_tasks WHERE id=f.task;
  b:=public.save_work_task_cas(f.task,f.vineyard,gen_random_uuid(),f.actor,r,'edit','{"notes":"history retained"}');
  PERFORM pg_temp.cas_assert(b->>'applied'='true'
    AND b#>>'{canonical,assigned_external_resource_id}'=f.resource::text,'unchanged deleted historical resource preserved');
END;
$history$;
RESET ROLE;

-- Another permitted actor cannot read prior author's receipts or reuse that op.
SELECT set_config('request.jwt.claim.sub',other_actor::text,true) FROM cas_fixture;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',other_actor,'role','authenticated')::text,true) FROM cas_fixture;
SET LOCAL ROLE authenticated;
DO $isolation$
DECLARE f record; b jsonb; r bigint;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  PERFORM pg_temp.cas_assert(NOT EXISTS(SELECT 1 FROM public.work_task_write_receipts
    WHERE operation_id=f.create_op),'receipt author RLS');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,NULL,''create'',''{"task_type":"reuse","schedule_basis":"el_stage","target_el_stage":35,"vintage_year":2027}'')',
    f.task,f.vineyard,f.create_op,f.other_actor),'22023');
  SELECT server_revision INTO r FROM public.work_tasks WHERE id=f.date_task;
  b:=public.save_work_task_cas(f.date_task,f.vineyard,gen_random_uuid(),f.other_actor,r,'edit','{"notes":"other operator edit"}');
  PERFORM pg_temp.cas_assert(b->>'applied'='true','other operational actor allowed');
END;
$isolation$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub',outsider::text,true) FROM cas_fixture;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true) FROM cas_fixture;
SET LOCAL ROLE authenticated;
DO $outsider$
DECLARE f record;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  PERFORM pg_temp.cas_assert(NOT EXISTS(SELECT 1 FROM public.work_tasks WHERE id=f.task),'cross-vineyard RLS');
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,1,''edit'',''{"notes":"wrong vineyard"}'')',
    f.task,f.vineyard,gen_random_uuid(),f.outsider),'42501');
END;
$outsider$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',viewer::text,true) FROM cas_fixture;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',viewer,'role','authenticated')::text,true) FROM cas_fixture;
SET LOCAL ROLE authenticated;
DO $viewer$
DECLARE f record;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,1,''edit'',''{"notes":"nonmember"}'')',
    f.task,f.vineyard,gen_random_uuid(),f.viewer),'42501');
END;
$viewer$;
RESET ROLE;

-- Even legacy SECURITY DEFINER writers owned by postgres cannot mutate protected
-- fields through the gate. Cost/provenance-only server mutations still advance
-- revision, without changing calculator data here.
DO $gate$
DECLARE f record; r bigint; n bigint;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  PERFORM pg_temp.cas_expect_error(format('UPDATE public.work_tasks SET assigned_to=%L WHERE id=%L',f.actor,f.task),'42501');
  SELECT server_revision INTO r FROM public.work_tasks WHERE id=f.task;
  UPDATE public.work_tasks SET sync_version=sync_version WHERE id=f.task;
  SELECT server_revision INTO n FROM public.work_tasks WHERE id=f.task;
  PERFORM pg_temp.cas_assert(n=r+1,'all header updates including no-op cost-only writes advance revision');
END;
$gate$;

-- Inject a receipt-insert failure on the clone. Verify mutation AND its receipt
-- roll back together; do NOT run this against production.
CREATE FUNCTION pg_temp.cas_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN RAISE EXCEPTION 'Injected receipt failure' USING ERRCODE='P0001'; END;
$fn$;
CREATE TRIGGER zzzz_cas_receipt_failure BEFORE INSERT ON public.work_task_write_receipts
FOR EACH ROW EXECUTE FUNCTION pg_temp.cas_receipt_failure();
SELECT set_config('request.jwt.claim.sub',actor::text,true) FROM cas_fixture;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true) FROM cas_fixture;
SET LOCAL ROLE authenticated;
DO $atomicity$
DECLARE f record; before_row jsonb; after_row jsonb; op uuid:=gen_random_uuid(); r bigint;
BEGIN
  SELECT * INTO f FROM cas_fixture;
  SELECT to_jsonb(w),server_revision INTO before_row,r FROM public.work_tasks w WHERE id=f.task;
  PERFORM pg_temp.cas_expect_error(format(
    'SELECT public.save_work_task_cas(%L,%L,%L,%L,%s,''edit'',''{"notes":"must rollback"}'')',
    f.task,f.vineyard,op,f.actor,r),'P0001');
  SELECT to_jsonb(w) INTO after_row FROM public.work_tasks w WHERE id=f.task;
  PERFORM pg_temp.cas_assert(before_row=after_row,'task rollback after receipt failure');
  PERFORM pg_temp.cas_assert(NOT EXISTS(SELECT 1 FROM public.work_task_write_receipts
    WHERE operation_id=op),'no receipt after rollback');
END;
$atomicity$;
RESET ROLE;
ROLLBACK;
-- Assertions succeeded only if the entire script completed without error.
-- No results are claimed by supplying this script. Multi-session contention,
-- PostgREST HTTP behavior, historic fixture variants and unchanged costing/pruning
-- acceptance remain separate mandatory checks in the accompanying proposal.
