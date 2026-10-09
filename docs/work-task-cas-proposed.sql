-- WITHDRAWN 2026-10-09 by user instruction. DO NOT APPLY ANY SECTION.
-- Superseded by existing-schema functional parity and sync_version review.
-- REVIEW PROPOSAL ONLY. NOT APPLIED. Not in a migration discovery directory.
-- Contract v1; read docs/work-task-cas-proposal.md BEFORE running anything.
-- PostgreSQL / native Supabase Auth. Run only on a disposable schema clone first.
-- Sections A-C are expansion; D is read-only discovery. Enforcement is ONLY in
-- docs/work-task-cas-cutover-proposed.sql, a separately reviewed proposal.
-- This file does NOT change pruning functions, child costing tables or calculators.

-- A. Expansion. Intentionally one-shot: existing names cause failure, not silent reuse.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $preflight$
BEGIN
  IF to_regclass('public.work_tasks') IS NULL
     OR to_regclass('public.vineyard_members') IS NULL
     OR to_regclass('public.vineyard_external_resources') IS NULL
     OR to_regprocedure('public.has_vineyard_role(uuid,text[])') IS NULL
     OR to_regprocedure('public.resolve_vineyard_vintage_year(uuid,date)') IS NULL THEN
    RAISE EXCEPTION 'Required live schema/functions missing';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vinetrack_work_task_cas_owner') THEN
    RAISE EXCEPTION 'Role already exists: inspect ownership/membership before retry';
  END IF;
END;
$preflight$;

CREATE ROLE vinetrack_work_task_cas_owner
  NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE SCHEMA work_task_cas_private;
REVOKE ALL ON SCHEMA work_task_cas_private FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public, auth, work_task_cas_private TO vinetrack_work_task_cas_owner;
GRANT EXECUTE ON FUNCTION auth.uid() TO vinetrack_work_task_cas_owner;
GRANT EXECUTE ON FUNCTION public.has_vineyard_role(uuid,text[]) TO vinetrack_work_task_cas_owner;

ALTER TABLE public.work_tasks
  ADD COLUMN server_revision bigint NOT NULL DEFAULT 1,
  ADD COLUMN planned_end_date timestamptz,
  ADD COLUMN completion_business_date date,
  ADD COLUMN scheduling_contract_version smallint NOT NULL DEFAULT 0,
  ADD COLUMN completion_contract_version smallint NOT NULL DEFAULT 0;

-- No history rewrite. Version 0 preserves legacy data; new/touched schedule or
-- lifecycle fields adopt version 1 only after explicit validation in the RPC.
ALTER TABLE public.work_tasks
  ADD CONSTRAINT work_task_cas_positive_revision CHECK (server_revision > 0),
  ADD CONSTRAINT work_task_cas_versions CHECK (
    scheduling_contract_version IN (0,1) AND completion_contract_version IN (0,1)),
  ADD CONSTRAINT work_task_cas_assignment_exclusive CHECK (
    assigned_to IS NULL OR assigned_external_resource_id IS NULL) NOT VALID,
  ADD CONSTRAINT work_task_cas_schedule CHECK (
    scheduling_contract_version = 0 OR (
      vintage_year IS NOT NULL AND vintage_year BETWEEN 1900 AND 9998 AND
      ((schedule_basis = 'el_stage' AND target_el_stage IS NOT NULL
        AND target_el_stage IN (1,2,3,4,7,9,11,12,13,14,15,16,17,18,19,20,21,23,25,26,27,29,31,32,33,34,35,36,37,38,39,41,43)
        AND start_date IS NULL AND planned_end_date IS NULL)
       OR (schedule_basis = 'date' AND target_el_stage IS NULL
        AND (planned_end_date IS NULL OR planned_end_date >= coalesce(start_date,date))))
    )) NOT VALID,
  ADD CONSTRAINT work_task_cas_completion CHECK (
    completion_contract_version = 0 OR (
      (is_finalized AND status IS NOT DISTINCT FROM 'completed'
       AND completed_by IS NOT NULL AND completed_at IS NOT NULL
       AND completion_business_date IS NOT NULL AND finalized_at IS NOT NULL
       AND finalized_by IS NOT DISTINCT FROM completed_by::text)
      OR (NOT is_finalized AND status IS DISTINCT FROM 'completed'
       AND completed_by IS NULL AND completed_at IS NULL
       AND completion_business_date IS NULL AND finalized_at IS NULL AND finalized_by IS NULL)
    )) NOT VALID;

-- Existing PK supports ID/revision CAS. Do not add a redundant (id,revision) index.
CREATE INDEX work_task_cas_stage_idx ON public.work_tasks
  (vineyard_id, vintage_year, target_el_stage DESC, id)
  WHERE deleted_at IS NULL AND schedule_basis = 'el_stage';
CREATE INDEX work_task_cas_internal_assignment_idx ON public.work_tasks
  (vineyard_id, assigned_to) WHERE deleted_at IS NULL AND assigned_to IS NOT NULL;
CREATE INDEX work_task_cas_external_assignment_idx ON public.work_tasks
  (vineyard_id, assigned_external_resource_id)
  WHERE deleted_at IS NULL AND assigned_external_resource_id IS NOT NULL;

CREATE TABLE public.work_task_write_receipts (
  operation_id uuid PRIMARY KEY,
  task_id uuid NOT NULL REFERENCES public.work_tasks(id) ON DELETE RESTRICT,
  vineyard_id uuid NOT NULL REFERENCES public.vineyards(id) ON DELETE RESTRICT,
  authored_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  action text NOT NULL CHECK (action IN ('create','edit','complete','reopen','completion_date')),
  base_revision bigint,
  request jsonb NOT NULL CHECK (jsonb_typeof(request) = 'object'),
  applied_revision bigint NOT NULL CHECK (applied_revision > 0),
  acknowledgement jsonb NOT NULL CHECK (jsonb_typeof(acknowledgement) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT work_task_receipt_base CHECK (
    (action = 'create' AND base_revision IS NULL)
    OR (action <> 'create' AND base_revision > 0 AND base_revision IS NOT NULL))
);
CREATE INDEX work_task_receipt_task_revision_idx
  ON public.work_task_write_receipts(task_id,applied_revision);
CREATE INDEX work_task_receipt_author_scope_idx
  ON public.work_task_write_receipts(authored_by,vineyard_id,created_at DESC);
ALTER TABLE public.work_task_write_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.work_task_write_receipts FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.work_task_write_receipts TO authenticated;
GRANT SELECT, INSERT ON public.work_task_write_receipts TO vinetrack_work_task_cas_owner;

CREATE POLICY work_task_receipt_author_read ON public.work_task_write_receipts
  FOR SELECT TO authenticated USING (
    authored_by = auth.uid() AND public.has_vineyard_role(
      vineyard_id,ARRAY['owner','manager','supervisor','operator']));
-- Only the non-login function owner can inspect global operation-ID collisions.
-- Incoming auth/membership is checked first; request equality is checked before
-- returning ANY receipt. Client SELECT remains author-and-vineyard scoped.
CREATE POLICY work_task_receipt_rpc_read ON public.work_task_write_receipts
  FOR SELECT TO vinetrack_work_task_cas_owner USING (auth.uid() IS NOT NULL);
CREATE POLICY work_task_receipt_rpc_insert ON public.work_task_write_receipts
  FOR INSERT TO vinetrack_work_task_cas_owner WITH CHECK (
    authored_by = auth.uid() AND public.has_vineyard_role(
      vineyard_id,ARRAY['owner','manager','supervisor','operator']));

-- The RPC role is not the table owner and has NO BYPASSRLS.
ALTER TABLE public.work_tasks ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.work_tasks TO vinetrack_work_task_cas_owner;
CREATE POLICY work_task_cas_role_read ON public.work_tasks
  FOR SELECT TO vinetrack_work_task_cas_owner USING (
    public.has_vineyard_role(vineyard_id,ARRAY['owner','manager','supervisor','operator']));
CREATE POLICY work_task_cas_role_insert ON public.work_tasks
  FOR INSERT TO vinetrack_work_task_cas_owner WITH CHECK (
    public.has_vineyard_role(vineyard_id,ARRAY['owner','manager','supervisor','operator']));
CREATE POLICY work_task_cas_role_update ON public.work_tasks
  FOR UPDATE TO vinetrack_work_task_cas_owner USING (
    public.has_vineyard_role(vineyard_id,ARRAY['owner','manager','supervisor','operator']))
  WITH CHECK (public.has_vineyard_role(vineyard_id,ARRAY['owner','manager','supervisor','operator']));

-- Narrow trusted-schema adapters: no direct grants on membership/profile/resource
-- tables to the RPC owner. These helpers are owned by the migration administrator,
-- NOT by a client role. All identifiers are qualified; no dynamic user SQL.
CREATE FUNCTION work_task_cas_private.actor_timezone(p_vineyard uuid,p_actor uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $fn$
DECLARE v_tz text;
BEGIN
  IF auth.uid() IS NULL OR p_actor IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Authenticated author required' USING ERRCODE = '42501';
  END IF;
  -- Hold actual membership against concurrent revocation/role downgrade.
  PERFORM 1 FROM public.vineyard_members
    WHERE vineyard_id=p_vineyard AND user_id=p_actor
      AND role::text IN ('owner','manager','supervisor','operator') FOR SHARE;
  IF NOT FOUND OR NOT public.has_vineyard_role(
      p_vineyard,ARRAY['owner','manager','supervisor','operator']) THEN
    RAISE EXCEPTION 'Operational vineyard membership required' USING ERRCODE='42501';
  END IF;
  SELECT timezone INTO v_tz FROM public.vineyards WHERE id=p_vineyard FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Vineyard unavailable' USING ERRCODE='42501'; END IF;
  v_tz := coalesce(nullif(v_tz,''),'UTC');
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name=v_tz) THEN
    RAISE EXCEPTION 'Invalid vineyard timezone' USING ERRCODE='22023';
  END IF;
  RETURN v_tz;
END;
$fn$;

CREATE FUNCTION work_task_cas_private.validate_links(
  p_vineyard uuid,p_internal uuid,p_external uuid,p_paddock uuid,
  p_validate_internal boolean,p_validate_external boolean,p_validate_paddock boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $fn$
BEGIN
  IF p_internal IS NOT NULL AND p_external IS NOT NULL THEN
    RAISE EXCEPTION 'Choose internal OR external assignment' USING ERRCODE='22023';
  END IF;
  IF p_validate_internal AND p_internal IS NOT NULL THEN
    PERFORM 1 FROM public.vineyard_members WHERE vineyard_id=p_vineyard
      AND user_id=p_internal FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Assignee must belong to vineyard' USING ERRCODE='22023';
    END IF;
    PERFORM 1 FROM public.profiles WHERE id=p_internal;
    IF NOT FOUND THEN RAISE EXCEPTION 'Assignee profile unavailable' USING ERRCODE='22023'; END IF;
  END IF;
  IF p_validate_external AND p_external IS NOT NULL THEN
    PERFORM 1 FROM public.vineyard_external_resources
      WHERE id=p_external AND vineyard_id=p_vineyard
        AND is_active AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Active same-vineyard external resource required' USING ERRCODE='22023';
    END IF;
  END IF;
  IF p_validate_paddock AND p_paddock IS NOT NULL THEN
    PERFORM 1 FROM public.paddocks WHERE id=p_paddock
      AND vineyard_id=p_vineyard AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Same-vineyard block required' USING ERRCODE='22023'; END IF;
  END IF;
END;
$fn$;

CREATE FUNCTION work_task_cas_private.resolved_vintage(p_vineyard uuid,p_day date)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $fn$
  SELECT public.resolve_vineyard_vintage_year(p_vineyard,p_day)
$fn$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA work_task_cas_private FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION work_task_cas_private.actor_timezone(uuid,uuid),
  work_task_cas_private.validate_links(uuid,uuid,uuid,uuid,boolean,boolean,boolean),
  work_task_cas_private.resolved_vintage(uuid,date) TO vinetrack_work_task_cas_owner;

-- B. Trigger functions. Revision is installed at expansion, before any new writer.
CREATE FUNCTION work_task_cas_private.advance_revision()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $fn$
BEGIN
  IF TG_OP='INSERT' THEN NEW.server_revision:=1;
  ELSE
    IF OLD.server_revision=9223372036854775807 THEN
      RAISE EXCEPTION 'Revision exhausted' USING ERRCODE='54000';
    END IF;
    NEW.server_revision:=OLD.server_revision+1;
  END IF;
  RETURN NEW;
END;
$fn$;
CREATE TRIGGER zz_work_task_cas_revision BEFORE INSERT OR UPDATE ON public.work_tasks
  FOR EACH ROW EXECUTE FUNCTION work_task_cas_private.advance_revision();

CREATE FUNCTION work_task_cas_private.receipt_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $fn$
BEGIN
  IF TG_OP <> 'INSERT' OR current_user <> 'vinetrack_work_task_cas_owner' THEN
    RAISE EXCEPTION 'Receipts are RPC-owned and immutable' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END;
$fn$;
CREATE TRIGGER work_task_receipt_immutable BEFORE INSERT OR UPDATE OR DELETE
  ON public.work_task_write_receipts FOR EACH ROW
  EXECUTE FUNCTION work_task_cas_private.receipt_immutable();

-- These functions are deliberately SECURITY INVOKER: current_user identifies the
-- NOLOGIN RPC function owner, not a forged request GUC or JWT claim.
CREATE FUNCTION work_task_cas_private.header_gate()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $fn$
DECLARE
  v_keys text[] := ARRAY['id','vineyard_id','paddock_id','paddock_name','task_type',
    'description','notes','duration_hours','date','start_date','end_date','planned_end_date',
    'assigned_to','assigned_external_resource_id','schedule_basis','target_el_stage','vintage_year',
    'completed_by','completed_at','completion_business_date','is_finalized','finalized_at',
    'finalized_by','status','is_archived','archived_at','archived_by','deleted_at','created_by',
    'created_at','scheduling_contract_version','completion_contract_version'];
  k text;
BEGIN
  IF current_user='vinetrack_work_task_cas_owner' THEN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Hard delete not supported' USING ERRCODE='42501'; END IF;
    IF TG_OP='UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id
      OR NEW.vineyard_id IS DISTINCT FROM OLD.vineyard_id) THEN
      RAISE EXCEPTION 'Task identity is immutable' USING ERRCODE='42501';
    END IF;
    PERFORM work_task_cas_private.validate_links(NEW.vineyard_id,NEW.assigned_to,
      NEW.assigned_external_resource_id,NEW.paddock_id,
      TG_OP='INSERT' OR NEW.assigned_to IS DISTINCT FROM OLD.assigned_to,
      TG_OP='INSERT' OR NEW.assigned_external_resource_id IS DISTINCT FROM OLD.assigned_external_resource_id,
      TG_OP='INSERT' OR NEW.paddock_id IS DISTINCT FROM OLD.paddock_id);
    RETURN NEW;
  END IF;
  IF TG_OP <> 'UPDATE' THEN
    RAISE EXCEPTION 'Work Task header writes require save_work_task_cas' USING ERRCODE='42501';
  END IF;
  FOREACH k IN ARRAY v_keys LOOP
    IF (to_jsonb(NEW)->k) IS DISTINCT FROM (to_jsonb(OLD)->k) THEN
      RAISE EXCEPTION 'Work Task header writes require save_work_task_cas' USING ERRCODE='42501';
    END IF;
  END LOOP;
  -- Existing trusted cost-only updates are permitted ONLY when protected fields
  -- remain unchanged. Their revision still advances; they cannot win a stale CAS.
  RETURN NEW;
END;
$fn$;
-- Header gate is NOT installed until the separately reviewed cutover file.

-- C. RPC. No defaults: callers supply all seven arguments, including null base.
CREATE FUNCTION public.save_work_task_cas(
  p_task_id uuid,p_vineyard_id uuid,p_operation_id uuid,p_authored_by uuid,
  p_base_revision bigint,p_action text,p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog SET timezone='UTC' SET datestyle='ISO, YMD'
AS $rpc$
DECLARE
  v_old public.work_tasks%ROWTYPE;
  v_new public.work_tasks%ROWTYPE;
  v_saved public.work_tasks%ROWTYPE;
  v_receipt public.work_task_write_receipts%ROWTYPE;
  v_tz text;
  v_request jsonb;
  v_ack jsonb;
  v_data jsonb;
  v_expected jsonb;
  v_allowed text[];
  v_schedule_keys text[] := ARRAY['schedule_basis','target_el_stage','date','start_date','planned_end_date','vintage_year'];
  v_owned text[] := ARRAY['task_type','description','notes','paddock_id','paddock_name','duration_hours',
    'assigned_to','assigned_external_resource_id','schedule_basis','target_el_stage',
    'date','start_date','planned_end_date','vintage_year'];
  v_schedule boolean;
  v_done boolean;
  v_mode_change boolean;
  v_day date;
  v_instant timestamptz;
  k text;
  typ text;
  v_conflict_keys text[] := ARRAY[]::text[];
  v_set text;
  v_rows bigint;
  v_update_keys text[] := ARRAY['paddock_id','paddock_name','date','task_type','duration_hours',
    'notes','description','start_date','end_date','planned_end_date','assigned_to',
    'assigned_external_resource_id','schedule_basis','target_el_stage','vintage_year',
    'completed_by','completed_at','completion_business_date','is_finalized','finalized_at',
    'finalized_by','status','scheduling_contract_version','completion_contract_version'];
BEGIN
  IF p_task_id IS NULL OR p_vineyard_id IS NULL OR p_operation_id IS NULL
     OR p_authored_by IS NULL OR p_action IS NULL THEN
    RAISE EXCEPTION 'Non-null identifiers/action required' USING ERRCODE='22023';
  END IF;
  v_tz := work_task_cas_private.actor_timezone(p_vineyard_id,p_authored_by);
  IF p_action NOT IN ('create','edit','complete','reopen','completion_date')
     OR p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'Invalid action or patch' USING ERRCODE='22023';
  END IF;
  IF pg_column_size(p_patch)>65536 THEN
    RAISE EXCEPTION 'Patch exceeds 64KiB' USING ERRCODE='22023';
  END IF;
  IF (p_action='create' AND p_base_revision IS NOT NULL)
     OR (p_action<>'create' AND (p_base_revision IS NULL OR p_base_revision<1)) THEN
    RAISE EXCEPTION 'Create needs null base; other actions need positive revision' USING ERRCODE='22023';
  END IF;
  v_request:=jsonb_build_object('task_id',p_task_id,'vineyard_id',p_vineyard_id,
    'authored_by',p_authored_by,'action',p_action,'base_revision',p_base_revision,'patch',p_patch);
  -- Hash collisions only serialize unrelated work; never affect equality checks.
  PERFORM pg_advisory_xact_lock(hashtextextended('work-task-operation:'||p_operation_id::text,0));
  SELECT * INTO v_receipt FROM public.work_task_write_receipts WHERE operation_id=p_operation_id;
  IF FOUND THEN
    IF v_receipt.request IS DISTINCT FROM v_request THEN
      RAISE EXCEPTION 'Operation ID reused for a different request' USING ERRCODE='22023';
    END IF;
    RETURN v_receipt.acknowledgement; -- exact saved response, not today's row
  END IF;
  -- Serializes absent-row creation across ALL vineyards as well as existing writes.
  PERFORM pg_advisory_xact_lock(hashtextextended('work-task-row:'||p_task_id::text,0));
  SELECT * INTO v_old FROM public.work_tasks
    WHERE id=p_task_id AND vineyard_id=p_vineyard_id FOR UPDATE;
  IF p_action='create' AND FOUND THEN
    RETURN jsonb_build_object('applied',false,'conflict',true,'reason','already_exists',
      'operation_id',p_operation_id,'task_id',p_task_id,'vineyard_id',p_vineyard_id,
      'server_revision',v_old.server_revision,'canonical',to_jsonb(v_old));
  ELSIF p_action<>'create' AND NOT FOUND THEN
    RETURN jsonb_build_object('applied',false,'conflict',true,'reason','not_available',
      'operation_id',p_operation_id,'task_id',p_task_id,'vineyard_id',p_vineyard_id,
      'server_revision',NULL,'canonical',NULL);
  END IF;
  IF p_action<>'create' THEN
    IF v_old.deleted_at IS NOT NULL OR v_old.server_revision<>p_base_revision THEN
      RETURN jsonb_build_object('applied',false,'conflict',true,
        'reason',CASE WHEN v_old.deleted_at IS NOT NULL THEN 'deleted' ELSE 'revision_mismatch' END,
        'operation_id',p_operation_id,'task_id',p_task_id,'vineyard_id',p_vineyard_id,
        'server_revision',v_old.server_revision,'canonical',to_jsonb(v_old));
    END IF;
  END IF;

  v_allowed:=CASE WHEN p_action IN ('create','edit') THEN v_owned
    WHEN p_action='complete' THEN ARRAY['completed_at','completion_business_date']
    WHEN p_action='completion_date' THEN ARRAY['completion_business_date']
    ELSE ARRAY[]::text[] END;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_patch) AS t(key)
      WHERE key <> 'expected' AND NOT (key=ANY(v_allowed))) THEN
    RAISE EXCEPTION 'Unknown or non-owned patch key' USING ERRCODE='22023';
  END IF;
  IF p_patch ? 'expected' THEN
    IF p_action='create' OR jsonb_typeof(p_patch->'expected')<>'object' THEN
      RAISE EXCEPTION 'Expected values require an existing row/object' USING ERRCODE='22023';
    END IF;
    v_expected:=p_patch->'expected';
    FOR k IN SELECT jsonb_object_keys(v_expected) LOOP
      IF NOT (k=ANY(v_owned||ARRAY['server_revision','status','is_finalized',
        'completed_by','completed_at','completion_business_date','finalized_at','finalized_by'])) THEN
        RAISE EXCEPTION 'Unknown expected key' USING ERRCODE='22023';
      END IF;
      IF (to_jsonb(v_old)->k) IS DISTINCT FROM (v_expected->k) THEN
        v_conflict_keys:=array_append(v_conflict_keys,k);
      END IF;
    END LOOP;
    IF cardinality(v_conflict_keys)>0 THEN
      RETURN jsonb_build_object('applied',false,'conflict',true,'reason','expected_mismatch',
        'mismatched_keys',to_jsonb(v_conflict_keys),'operation_id',p_operation_id,
        'task_id',p_task_id,'vineyard_id',p_vineyard_id,'server_revision',v_old.server_revision,
        'canonical',to_jsonb(v_old));
    END IF;
  END IF;
  v_data:=p_patch-'expected';
  IF p_action='edit' AND v_data='{}'::jsonb THEN
    RAISE EXCEPTION 'Empty edit is not a mutation' USING ERRCODE='22023';
  END IF;

  -- Reject coercion of JSON string/numeric/boolean types; JSON null is intentional.
  FOR k IN SELECT jsonb_object_keys(v_data) LOOP
    typ:=jsonb_typeof(v_data->k);
    IF typ='null' THEN
      IF k=ANY(ARRAY['task_type','notes','paddock_name','duration_hours','schedule_basis',
        'date','vintage_year','completed_at','completion_business_date']) THEN
        RAISE EXCEPTION 'Required field cannot be null: %',k USING ERRCODE='22023';
      END IF;
    ELSIF k=ANY(ARRAY['duration_hours','target_el_stage','vintage_year']) THEN
      IF typ<>'number' THEN RAISE EXCEPTION 'Numeric field required: %',k USING ERRCODE='22023'; END IF;
      IF k<>'duration_hours' AND (v_data->>k)!~'^[0-9]+$' THEN
        RAISE EXCEPTION 'Integer field required: %',k USING ERRCODE='22023';
      END IF;
    ELSE
      IF typ<>'string' THEN RAISE EXCEPTION 'String field required: %',k USING ERRCODE='22023'; END IF;
    END IF;
    IF typ<>'null' AND k=ANY(ARRAY['date','start_date','planned_end_date','completed_at'])
       AND (v_data->>k)!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' THEN
      RAISE EXCEPTION 'ISO timestamp with explicit offset required: %',k USING ERRCODE='22023';
    END IF;
    IF k='completion_business_date' AND (v_data->>k)!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
      RAISE EXCEPTION 'ISO business date required' USING ERRCODE='22023';
    END IF;
  END LOOP;

  IF p_action='create' THEN
    IF NOT (v_data ? 'task_type') OR NOT (v_data ? 'schedule_basis') THEN
      RAISE EXCEPTION 'Create requires task_type and schedule_basis' USING ERRCODE='22023';
    END IF;
    -- Only known planning fields are populated. Existing column defaults supply
    -- all costing fields at INSERT; financial/provenance payloads are never accepted.
    SELECT * INTO v_new FROM jsonb_populate_record(NULL::public.work_tasks,
      jsonb_build_object('id',p_task_id,'vineyard_id',p_vineyard_id,'paddock_name','',
        'notes','','duration_hours',0,'is_archived',false,'is_finalized',false,
        'status','planned','created_by',p_authored_by,'updated_by',p_authored_by,
        'scheduling_contract_version',1,'completion_contract_version',1)||v_data);
  ELSE
    IF v_old.is_archived THEN RAISE EXCEPTION 'Archived task is read-only' USING ERRCODE='22023'; END IF;
    v_new:=v_old;
    IF p_action='edit' THEN
      SELECT * INTO v_new FROM jsonb_populate_record(v_new,v_data);
    END IF;
  END IF;
  v_done:=coalesce(v_old.is_finalized,false) OR coalesce(v_old.status='completed',false);
  v_schedule:=p_action='create' OR (p_action='edit' AND v_data ?| v_schedule_keys);
  v_mode_change:=p_action<>'create' AND v_new.schedule_basis IS DISTINCT FROM v_old.schedule_basis;
  IF p_action='edit' AND v_done AND v_schedule THEN
    RAISE EXCEPTION 'Reopen before changing the schedule' USING ERRCODE='22023';
  END IF;
  IF p_action IN ('create','edit') THEN
    IF (v_data ? 'task_type') AND btrim(v_new.task_type)='' THEN
      RAISE EXCEPTION 'Task type cannot be empty' USING ERRCODE='22023';
    END IF;
    IF (v_data ? 'duration_hours') AND
      (v_new.duration_hours<0 OR v_new.duration_hours='Infinity'::float8
       OR v_new.duration_hours='NaN'::float8) THEN
      RAISE EXCEPTION 'Hours must be finite and nonnegative' USING ERRCODE='22023';
    END IF;
  END IF;
  IF v_schedule THEN
    IF v_new.schedule_basis='el_stage' THEN
      IF v_new.target_el_stage IS NULL OR v_new.target_el_stage NOT IN
        (1,2,3,4,7,9,11,12,13,14,15,16,17,18,19,20,21,23,25,26,27,29,31,32,33,34,35,36,37,38,39,41,43) THEN
        RAISE EXCEPTION 'Supported E-L target required' USING ERRCODE='22023';
      END IF;
      IF v_data ? 'date' OR (v_data ? 'start_date' AND v_data->'start_date'<>'null'::jsonb)
         OR (v_data ? 'planned_end_date' AND v_data->'planned_end_date'<>'null'::jsonb) THEN
        RAISE EXCEPTION 'E-L schedule has no planned date/range' USING ERRCODE='22023';
      END IF;
      IF p_action='create' AND NOT (v_data ? 'vintage_year') THEN
        RAISE EXCEPTION 'E-L create requires explicit vintage_year' USING ERRCODE='22023';
      END IF;
      v_new.start_date:=NULL;
      v_new.planned_end_date:=NULL;
      -- Preserve a legacy compatibility date unless creating or switching mode.
      IF p_action='create' OR v_mode_change THEN
        IF v_new.vintage_year IS NULL THEN
          RAISE EXCEPTION 'Explicit vintage required for E-L scheduling' USING ERRCODE='22023';
        END IF;
        v_new.date:=(make_date(v_new.vintage_year,1,1)::timestamp+interval '12 hours') AT TIME ZONE v_tz;
      END IF;
      v_new.end_date:=NULL;
    ELSIF v_new.schedule_basis='date' THEN
      IF (p_action='create' OR v_mode_change) AND NOT (v_data ? 'date') THEN
        RAISE EXCEPTION 'Explicit planned date required; never reuse E-L compatibility date' USING ERRCODE='22023';
      END IF;
      IF (v_data ? 'target_el_stage') AND v_data->'target_el_stage'<>'null'::jsonb THEN
        RAISE EXCEPTION 'Date schedule cannot have a target stage' USING ERRCODE='22023';
      END IF;
      v_new.target_el_stage:=NULL;
      -- First schedule edit of a legacy incomplete date task imports its old range.
      IF p_action<>'create' AND v_old.scheduling_contract_version=0 AND NOT v_done
        AND NOT v_mode_change AND NOT (v_data ? 'planned_end_date') THEN
        v_new.planned_end_date:=v_old.end_date;
      END IF;
      IF v_new.date IS NULL OR NOT isfinite(v_new.date)
        OR (v_new.start_date IS NOT NULL AND NOT isfinite(v_new.start_date))
        OR (v_new.planned_end_date IS NOT NULL AND (NOT isfinite(v_new.planned_end_date)
          OR v_new.planned_end_date<coalesce(v_new.start_date,v_new.date))) THEN
        RAISE EXCEPTION 'Invalid date/range' USING ERRCODE='22023';
      END IF;
      IF p_action='create' OR (v_data ? 'date' AND NOT v_mode_change) THEN
        v_new.vintage_year:=work_task_cas_private.resolved_vintage(
          p_vineyard_id,(v_new.date AT TIME ZONE v_tz)::date);
        IF v_data ? 'vintage_year' AND (v_data->>'vintage_year')::integer<>v_new.vintage_year THEN
          RAISE EXCEPTION 'Date-task vintage must match vineyard resolver' USING ERRCODE='22023';
        END IF;
      ELSIF v_data ? 'vintage_year' THEN
        IF v_new.vintage_year<>work_task_cas_private.resolved_vintage(
          p_vineyard_id,(v_new.date AT TIME ZONE v_tz)::date) THEN
          RAISE EXCEPTION 'Explicit date-task vintage must match resolver' USING ERRCODE='22023';
        END IF;
      END IF;
      -- Mode switch alone preserves previously frozen vintage unless an explicit
      -- validated vintage is supplied. A later explicit date change re-resolves it.
      v_new.end_date:=v_new.planned_end_date;
    ELSE RAISE EXCEPTION 'Unknown scheduling basis' USING ERRCODE='22023';
    END IF;
    IF v_new.vintage_year IS NULL OR v_new.vintage_year NOT BETWEEN 1900 AND 9998 THEN
      RAISE EXCEPTION 'Vintage year outside supported review range' USING ERRCODE='22023';
    END IF;
    v_new.scheduling_contract_version:=1;
  END IF;

  IF p_action IN ('complete','completion_date') THEN
    IF p_action='complete' THEN
      IF v_done THEN RAISE EXCEPTION 'Already completed; use original receipt or conflict resolution' USING ERRCODE='22023'; END IF;
      IF NOT (v_data ? 'completed_at') THEN
        RAISE EXCEPTION 'Authored completion instant required' USING ERRCODE='22023';
      END IF;
      v_instant:=(v_data->>'completed_at')::timestamptz;
      IF NOT isfinite(v_instant) OR v_instant>clock_timestamp()+interval '5 minutes'
        OR v_instant<timestamptz '1900-01-01T00:00:00Z' THEN
        RAISE EXCEPTION 'Completion instant outside supported range/clock tolerance' USING ERRCODE='22023';
      END IF;
      v_day:=coalesce((v_data->>'completion_business_date')::date,(v_instant AT TIME ZONE v_tz)::date);
    ELSE
      IF NOT v_done OR NOT (v_data ? 'completion_business_date') THEN
        RAISE EXCEPTION 'Completed task and explicit business date required' USING ERRCODE='22023';
      END IF;
      v_day:=(v_data->>'completion_business_date')::date;
      v_instant:=coalesce(v_old.completed_at,v_old.finalized_at);
      IF v_instant IS NULL THEN
        RAISE EXCEPTION 'Historical completion has no verified instant; requires reviewed correction' USING ERRCODE='22023';
      END IF;
    END IF;
    IF NOT isfinite(v_day) OR v_day<date '1900-01-01' OR v_day>(v_instant AT TIME ZONE v_tz)::date
      OR (v_new.schedule_basis='date' AND v_day<(coalesce(v_new.start_date,v_new.date) AT TIME ZONE v_tz)::date) THEN
      RAISE EXCEPTION 'Business date outside allowed work interval' USING ERRCODE='22023';
    END IF;
    -- An actual recording instant and an earlier selected work business day are
    -- independent. E-L compatibility date is NEVER a lower bound.
    v_new.completion_business_date:=v_day;
    v_new.end_date:=v_day::timestamp AT TIME ZONE v_tz; -- legacy read mirror
    IF p_action='complete' THEN
      IF v_old.scheduling_contract_version=0 AND v_old.schedule_basis='date' THEN
        v_new.planned_end_date:=v_old.end_date; -- save old range before legacy mirror
      END IF;
      v_new.completed_by:=p_authored_by;
      v_new.completed_at:=v_instant;
      v_new.is_finalized:=true;
      v_new.status:='completed';
      v_new.finalized_by:=p_authored_by::text;
      v_new.finalized_at:=v_instant;
      v_new.completion_contract_version:=1;
    END IF;
    -- Date-only correction NEVER fills historical unknown attribution/audit fields.
  ELSIF p_action='reopen' THEN
    IF NOT v_done THEN RAISE EXCEPTION 'Task is not completed' USING ERRCODE='22023'; END IF;
    v_new.is_finalized:=false;
    v_new.status:='planned';
    v_new.completed_by:=NULL;
    v_new.completed_at:=NULL;
    v_new.completion_business_date:=NULL;
    v_new.finalized_by:=NULL;
    v_new.finalized_at:=NULL;
    v_new.end_date:=CASE WHEN v_new.schedule_basis='date' THEN v_new.planned_end_date ELSE NULL END;
    v_new.completion_contract_version:=1;
  END IF;
  v_new.updated_by:=p_authored_by;
  PERFORM work_task_cas_private.validate_links(p_vineyard_id,v_new.assigned_to,
    v_new.assigned_external_resource_id,v_new.paddock_id,
    p_action='create' OR v_new.assigned_to IS DISTINCT FROM v_old.assigned_to,
    p_action='create' OR v_new.assigned_external_resource_id IS DISTINCT FROM v_old.assigned_external_resource_id,
    p_action='create' OR v_new.paddock_id IS DISTINCT FROM v_old.paddock_id);

  IF p_action='create' THEN
    INSERT INTO public.work_tasks(id,vineyard_id,paddock_id,paddock_name,date,task_type,
      duration_hours,notes,description,start_date,end_date,planned_end_date,
      assigned_to,assigned_external_resource_id,schedule_basis,target_el_stage,vintage_year,
      is_archived,is_finalized,status,created_by,updated_by,
      scheduling_contract_version,completion_contract_version)
    VALUES(p_task_id,p_vineyard_id,v_new.paddock_id,v_new.paddock_name,v_new.date,v_new.task_type,
      v_new.duration_hours,v_new.notes,v_new.description,v_new.start_date,v_new.end_date,v_new.planned_end_date,
      v_new.assigned_to,v_new.assigned_external_resource_id,v_new.schedule_basis,v_new.target_el_stage,v_new.vintage_year,
      false,false,'planned',p_authored_by,p_authored_by,1,1)
    ON CONFLICT (id) DO NOTHING RETURNING * INTO v_saved;
    IF NOT FOUND THEN
      -- A task in another vineyard is hidden by RLS; never disclose its row.
      RETURN jsonb_build_object('applied',false,'conflict',true,'reason','identity_unavailable',
        'operation_id',p_operation_id,'task_id',p_task_id,'vineyard_id',p_vineyard_id,
        'server_revision',NULL,'canonical',NULL);
    END IF;
  ELSE
    -- Only changed columns enter the SET list. This is necessary for legacy
    -- UPDATE OF resource validation triggers: do not revalidate an unchanged
    -- historical deleted/inactive resource merely because a notes edit arrived.
    -- Identifiers come solely from our fixed allowlist; values are bound parameters.
    v_set:='updated_by=$2';
    FOREACH k IN ARRAY v_update_keys LOOP
      IF (to_jsonb(v_new)->k) IS DISTINCT FROM (to_jsonb(v_old)->k) THEN
        v_set:=v_set||format(', %I=(jsonb_populate_record(NULL::public.work_tasks,$1)).%I',k,k);
      END IF;
    END LOOP;
    EXECUTE 'UPDATE public.work_tasks SET '||v_set||
      ' WHERE id=$3 AND vineyard_id=$4 AND server_revision=$5 AND deleted_at IS NULL RETURNING *'
      INTO v_saved USING to_jsonb(v_new),p_authored_by,p_task_id,p_vineyard_id,p_base_revision;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    IF v_rows<>1 THEN RAISE EXCEPTION 'Locked row changed unexpectedly' USING ERRCODE='40001'; END IF;
  END IF;
  -- Read AFTER synchronous trigger effects; never acknowledge a suppressed or
  -- transformed owned value as the requested write. A failure rolls back all effects.
  SELECT * INTO STRICT v_saved FROM public.work_tasks
    WHERE id=p_task_id AND vineyard_id=p_vineyard_id;
  IF v_saved.updated_by IS DISTINCT FROM p_authored_by THEN
    RAISE EXCEPTION 'Server trigger changed editor audit identity' USING ERRCODE='40001';
  END IF;
  FOREACH k IN ARRAY v_update_keys LOOP
    IF (to_jsonb(v_saved)->k) IS DISTINCT FROM (to_jsonb(v_new)->k) THEN
      RAISE EXCEPTION 'Server trigger changed owned field: %',k USING ERRCODE='40001';
    END IF;
  END LOOP;
  v_ack:=jsonb_build_object('applied',true,'conflict',false,'contract_version',1,
    'operation_id',p_operation_id,'authored_by',p_authored_by,'task_id',p_task_id,
    'vineyard_id',p_vineyard_id,'server_revision',v_saved.server_revision,'canonical',to_jsonb(v_saved));
  INSERT INTO public.work_task_write_receipts(operation_id,task_id,vineyard_id,authored_by,
    action,base_revision,request,applied_revision,acknowledgement)
  VALUES(p_operation_id,p_task_id,p_vineyard_id,p_authored_by,p_action,p_base_revision,
    v_request,v_saved.server_revision,v_ack);
  RETURN v_ack;
END;
$rpc$;

-- Secure ownership is a required part of the implementation, not an optional grant.
GRANT CREATE ON SCHEMA public TO vinetrack_work_task_cas_owner;
ALTER FUNCTION public.save_work_task_cas(uuid,uuid,uuid,uuid,bigint,text,jsonb)
  OWNER TO vinetrack_work_task_cas_owner;
REVOKE CREATE ON SCHEMA public FROM vinetrack_work_task_cas_owner;
REVOKE ALL ON FUNCTION public.save_work_task_cas(uuid,uuid,uuid,uuid,bigint,text,jsonb)
  FROM PUBLIC,anon,authenticated,service_role;
-- No execute grant until enforcement. Do not advertise expansion as replay-safe.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA work_task_cas_private FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION work_task_cas_private.actor_timezone(uuid,uuid),
  work_task_cas_private.validate_links(uuid,uuid,uuid,uuid,boolean,boolean,boolean),
  work_task_cas_private.resolved_vintage(uuid,date) TO vinetrack_work_task_cas_owner;
COMMIT;

-- D. Review-only pre-cutover discovery. These SELECTs do not change data.
SELECT p.oid::regprocedure,p.prosecdef,pg_get_userbyid(p.proowner) AS owner,
  pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE p.prokind='f' AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND pg_get_functiondef(p.oid) ILIKE '%work_tasks%';
SELECT * FROM information_schema.table_privileges
  WHERE table_schema='public' AND table_name='work_tasks';
SELECT * FROM information_schema.column_privileges
  WHERE table_schema='public' AND table_name='work_tasks';
SELECT pg_get_triggerdef(oid),pg_get_functiondef(tgfoid)
  FROM pg_trigger WHERE tgrelid='public.work_tasks'::regclass AND NOT tgisinternal;
SELECT * FROM pg_policies WHERE schemaname='public'
  AND tablename IN ('work_tasks','work_task_write_receipts');
SELECT r.rolname,m.* FROM pg_auth_members m
  JOIN pg_roles r ON r.oid=m.roleid WHERE r.rolname='vinetrack_work_task_cas_owner';

-- STOP after expansion/discovery. Client RPC execute remains REVOKED.
-- Bypass closure/vintage-trigger replacement are proposed separately in
-- docs/work-task-cas-cutover-proposed.sql. Do not enable replay at this stage.
