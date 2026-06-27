-- 033_spray_records_link_jobs.sql
-- Adds an optional link from an actual spray record back to the planned
-- spray job that it fulfilled. Phase 1: nullable, no backfill, no UI yet.
--
-- Run order: must run AFTER sql/032_spray_jobs.sql (the FK target table
-- public.spray_jobs is created there).
--
-- Safety:
--   * Column is NULLABLE; existing spray_records rows are unaffected.
--   * ON DELETE SET NULL: hard-deleting a spray_jobs row (not currently
--     possible from the client; archive is the only path) leaves the
--     spray_record intact with the link cleared.
--   * Cross-vineyard integrity is enforced by a trigger so an iOS client
--     cannot link a record to a job in a different vineyard, even if RLS
--     would otherwise allow the update.
--   * RLS on spray_records is unchanged. iOS sync behaviour is unchanged
--     because the column defaults to NULL and is not required.
--
-- Reminder: spray_records.is_template is DEPRECATED for the new
-- planned/template model. Use spray_jobs.is_template instead.

alter table public.spray_records
  add column if not exists spray_job_id uuid null
  references public.spray_jobs(id) on delete set null;

create index if not exists idx_spray_records_spray_job_id
  on public.spray_records (spray_job_id);

comment on column public.spray_records.spray_job_id is
  'Optional link to the planned spray_jobs row this record fulfilled. '
  'Nullable. Must reference a spray_job in the same vineyard (enforced '
  'by trigger). spray_records remains the actual completed field/'
  'compliance record; spray_jobs is the planning layer.';

comment on column public.spray_records.is_template is
  'DEPRECATED for the planned/template model. Use spray_jobs.is_template '
  'instead. Left in place to avoid breaking existing iOS sync.';

-- =====================================================================
-- Cross-vineyard integrity trigger for spray_records.spray_job_id
-- =====================================================================
create or replace function public.spray_records_validate_job_link()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_job_vineyard uuid;
begin
  if new.spray_job_id is null then
    return new;
  end if;

  select vineyard_id into v_job_vineyard
  from public.spray_jobs
  where id = new.spray_job_id;

  if v_job_vineyard is null then
    raise exception 'spray_records.spray_job_id % not found', new.spray_job_id;
  end if;

  if v_job_vineyard <> new.vineyard_id then
    raise exception
      'spray_records.spray_job_id % belongs to a different vineyard than spray_record %',
      new.spray_job_id, new.id;
  end if;

  return new;
end;
$function$;

drop trigger if exists spray_records_validate_job_link_trg on public.spray_records;
create trigger spray_records_validate_job_link_trg
before insert or update of spray_job_id, vineyard_id on public.spray_records
for each row execute function public.spray_records_validate_job_link();
