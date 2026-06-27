-- 085_hard_delete_draft_spray_job.sql
--
-- Shared server-side RPC for permanently deleting a DRAFT spray job.
--
-- Background:
--   * sql/032 created spray_jobs with RLS that blocks client-side DELETE
--     (`spray_jobs_no_client_hard_delete` USING (false)`). Soft-delete /
--     archive goes through `archive_spray_job`.
--   * Lovable's "delete draft" UI was falling back to a direct client
--     DELETE, which silently returns 0 rows because of that RLS policy.
--   * We want iOS and Lovable to share the same rule, so destructive
--     "permanent delete" lives in the database, not the clients.
--
-- Behaviour:
--   * Authenticated owner/manager only.
--   * Job must exist, be a non-template, status = 'draft',
--     deleted_at is null, and have NO linked spray_records (active or
--     soft-deleted — any linked record means real work happened against
--     this draft and we must preserve the audit trail).
--   * Deletes `spray_job_paddocks` for the job (draft-only junction
--     rows; the FK cascades anyway, but we delete explicitly so the
--     intent is obvious and so any future non-cascading junctions are
--     covered).
--   * Hard deletes the `spray_jobs` row.
--   * Anything other than a clean draft must be archived/cancelled via
--     `archive_spray_job` instead — this RPC refuses.
--
-- Idempotent: drops and recreates the function.

set search_path = public;

drop function if exists public.hard_delete_draft_spray_job(uuid);

create or replace function public.hard_delete_draft_spray_job(p_spray_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id    uuid;
  v_status         text;
  v_is_template    boolean;
  v_deleted_at     timestamptz;
  v_linked_records bigint := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_spray_job_id is null then
    raise exception 'spray_job_id_required' using errcode = '22023';
  end if;

  select vineyard_id, status, is_template, deleted_at
    into v_vineyard_id, v_status, v_is_template, v_deleted_at
    from public.spray_jobs
   where id = p_spray_job_id;

  if v_vineyard_id is null then
    raise exception 'Spray job not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to permanently delete spray job';
  end if;

  if v_is_template then
    raise exception 'Cannot permanently delete a template. Archive it instead.'
      using errcode = '22023';
  end if;

  if v_deleted_at is not null then
    raise exception 'Spray job is already archived. Use restore or leave archived.'
      using errcode = '22023';
  end if;

  if v_status is distinct from 'draft' then
    raise exception
      'Only draft spray jobs can be permanently deleted. Current status: %. Archive or cancel instead.',
      coalesce(v_status, '(null)')
      using errcode = '22023';
  end if;

  -- Any spray_records pointing at this job means real work was recorded
  -- against the draft; block hard delete to protect the audit trail.
  -- Counts include soft-deleted records on purpose.
  select count(*)
    into v_linked_records
    from public.spray_records sr
   where sr.spray_job_id = p_spray_job_id;

  if v_linked_records > 0 then
    raise exception
      'Cannot permanently delete: % linked spray record(s) exist. Archive the job instead.',
      v_linked_records
      using errcode = '23503';
  end if;

  -- Draft-only junction rows. FK is ON DELETE CASCADE, but be explicit.
  delete from public.spray_job_paddocks
   where spray_job_id = p_spray_job_id;

  delete from public.spray_jobs
   where id = p_spray_job_id;
end;
$function$;

revoke all on function public.hard_delete_draft_spray_job(uuid) from public;
grant execute on function public.hard_delete_draft_spray_job(uuid) to authenticated;

-- Refresh PostgREST schema cache so clients see the new RPC.
notify pgrst, 'reload schema';
