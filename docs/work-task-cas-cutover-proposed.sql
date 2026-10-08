-- REVIEW PROPOSAL ONLY. NOT APPLIED. SEPARATE enforcement from expansion.
-- Requires docs/work-task-cas-proposed.sql and compatibility sign-off.
-- Read docs/work-task-cas-proposal.md before deploying anything.
-- This blocks legacy protected Work Task writes, including server-generated
-- header creation. Do not apply until all required dependent writers are resolved.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
LOCK TABLE public.work_tasks IN SHARE ROW EXCLUSIVE MODE;

-- Review against the EXACT saved live function before replacement. This is the
-- work_tasks-only trigger, not the shared resolver or any pruning trigger/RPC.
CREATE OR REPLACE FUNCTION public.work_tasks_resolve_vintage()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog AS $fn$
BEGIN
  IF current_user='vinetrack_work_task_cas_owner' THEN
    -- The RPC validates new/changed schedules. Unrelated legacy edits keep their
    -- original vintage, including null; never derive it from E-L compatibility date.
    RETURN NEW;
  END IF;
  IF TG_OP='UPDATE' AND NEW.date IS NOT DISTINCT FROM OLD.date
    AND NEW.vineyard_id IS NOT DISTINCT FROM OLD.vineyard_id
    AND NEW.vintage_year IS NOT DISTINCT FROM OLD.vintage_year THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Scheduling requires save_work_task_cas' USING ERRCODE='42501';
END;
$fn$;

CREATE TRIGGER zzzz_work_task_cas_header_gate BEFORE INSERT OR UPDATE OR DELETE
  ON public.work_tasks FOR EACH ROW EXECUTE FUNCTION work_task_cas_private.header_gate();
ALTER TABLE public.work_tasks ENABLE ALWAYS TRIGGER zzzz_work_task_cas_header_gate;
ALTER TABLE public.work_tasks ENABLE ALWAYS TRIGGER zz_work_task_cas_revision;
ALTER TABLE public.work_task_write_receipts ENABLE ALWAYS TRIGGER work_task_receipt_immutable;

REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.work_tasks
  FROM PUBLIC,anon,authenticated,service_role;
-- Table-level revocation is insufficient if old column grants survive.
DO $revoke_columns$
DECLARE c record;
BEGIN
  FOR c IN SELECT attname FROM pg_attribute
    WHERE attrelid='public.work_tasks'::regclass AND attnum>0 AND NOT attisdropped LOOP
    EXECUTE format('REVOKE INSERT (%I), UPDATE (%I), REFERENCES (%I) ON public.work_tasks FROM PUBLIC,anon,authenticated,service_role',
      c.attname,c.attname,c.attname);
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.roleid
      WHERE r.rolname='vinetrack_work_task_cas_owner') THEN
    RAISE EXCEPTION 'RPC owner must not have grantees (including authenticator or service roles)';
  END IF;
END;
$revoke_columns$;
GRANT EXECUTE ON FUNCTION public.save_work_task_cas(uuid,uuid,uuid,uuid,bigint,text,jsonb)
  TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
