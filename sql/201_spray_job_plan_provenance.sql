-- =============================================================================
-- 201: Spray Job plan provenance — Resistance Plan Position -> Spray Job(s).
--
-- Stage 5B of the plan-vs-actual contract. Rork/VineTrack mobile is the SOURCE
-- OF TRUTH for this contract; Lovable (the web portal) CONSUMES it and must not
-- invent a competing representation. The consumer contract is documented in
-- docs/vinetrack-plan-proposed-actual-contract.md.
--
-- ---------------------------------------------------------------------------
-- THE RELATIONSHIP
-- ---------------------------------------------------------------------------
--   resistance_plans.positions[].id  (sql/196, stable text id inside the plan
--                                     JSONB document)
--        │ 0..N
--        ▼
--   spray_jobs                       (sql/032, proposed/planned work)
--        │ 0..N (sql/033 spray_records.spray_job_id)
--        ▼
--   spray_records                    (actual completed applications)
--
--   * A plan position may generate MANY spray jobs (multi-block / staged
--     execution), so there is deliberately NO uniqueness constraint on
--     (resistance_plan_id, resistance_position_id).
--   * A spray job belongs to AT MOST ONE plan position (single columns).
--   * Old spray jobs remain valid with NULL provenance — strictly additive.
--
-- ---------------------------------------------------------------------------
-- WHY resistance_plan_id HAS NO FOREIGN KEY
-- ---------------------------------------------------------------------------
-- Two load-bearing reasons, both already contractual elsewhere:
--
--   1. sql/196 (and its test T22) PINS that no table holds an FK into
--      resistance_plans. Planning data must never grow a cascade path into
--      operational data or vice versa.
--   2. OFFLINE ORDERING. A plan can be authored offline, a job created from
--      one of its positions offline, and the JOB may reach the server BEFORE
--      the plan. An FK would refuse the job outright and the linkage would be
--      lost. Instead the link is stored plainly and validated by trigger WHEN
--      the plan row is visible (section 4); until then the link is "pending".
--
-- ---------------------------------------------------------------------------
-- THE SNAPSHOT FREEZES ORIGINAL INTENT, NEVER VERDICTS
-- ---------------------------------------------------------------------------
-- resistance_position_snapshot is a verbatim copy of the sql/196 position
-- object (id, products[] with group_codes/source/saved_chemical_id/
-- product_name/chemical_availability/registered_for_planned_disease,
-- target_date_epoch_ms, growth_stage, note) AS IT WAS when the job was
-- created. A manager later editing the plan position (FRAC 3 -> FRAC 11) must
-- not rewrite what an existing job was originally asked to do — historical
-- job intent is NEVER derived from the current plan position.
--
-- Deliberately NOT snapshotted: resistance verdicts ("Good fit", warnings,
-- counters). Same rule as sql/196 — a verdict is a function of plan + actual
-- history + ruleset, two of which keep changing. The Live Resistance Check is
-- always recomputed against current history; plan compliance at planning time
-- guarantees nothing later.
--
-- PLAN DEVIATION ≠ RESISTANCE COMPLIANCE. The snapshot enables deviation
-- display (proposed/actual chemistry differs from originally planned intent);
-- compliance stays with the Resistance Engine. A job may deviate from the
-- plan while remaining perfectly resistance-compliant.
--
-- ---------------------------------------------------------------------------
-- PROGRESS IS DERIVED, NEVER WRITTEN BACK
-- ---------------------------------------------------------------------------
-- Creating or completing spray jobs MUST NOT modify the resistance plan nor
-- bump its sql/198 server_revision (a manager edits the plan while operators
-- execute jobs, without manufactured revision conflicts). Nothing in this
-- migration writes to resistance_plans. Position progress is derived on read:
--   * proposed coverage  from spray_job_paddocks
--   * completed coverage from spray_records.block_ids (derived by sql/195
--     from application_blocks) of records linked via spray_records.spray_job_id
-- See resistance_position_coverage() below.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
-- ---------------------------------------------------------------------------
-- STRICTLY ADDITIVE:
--   1. Four nullable columns on spray_jobs.
--   2. A shape CHECK so a link is always complete and self-consistent.
--   3. A partial index for position -> jobs lookups.
--   4. A cross-vineyard guard trigger (plan visible => vineyards must match).
--   5. A freeze trigger: provenance becomes immutable once a live
--      spray_record references the job.
--   6. Read-only resolution/progress functions for clients and the portal.
--
-- NOTHING existing is altered: no change to resistance_plans, spray_records,
-- spray_job_paddocks, RLS policies or existing triggers.
--
-- Verification: sql/tests/201_spray_job_plan_provenance_tests.sql
-- (rollback-only).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columns (additive, nullable — legacy jobs stay valid with NULL provenance)
-- ---------------------------------------------------------------------------
alter table public.spray_jobs
  add column if not exists resistance_plan_id uuid null,
  add column if not exists resistance_position_id text null,
  add column if not exists resistance_position_snapshot jsonb null,
  add column if not exists resistance_plan_source_revision bigint null;

comment on column public.spray_jobs.resistance_plan_id is
  'resistance_plans.id this job was created from. Plain uuid, DELIBERATELY no '
  'FK (sql/196 T22 + offline ordering: the job may sync before its plan). '
  'Vineyard equality is enforced by trigger when the plan row exists and by '
  'the resolution functions always.';
comment on column public.spray_jobs.resistance_position_id is
  'resistance_plans.positions[].id (stable text id inside the plan JSONB '
  'document) this job executes. At most one position per job; a position may '
  'have many jobs.';
comment on column public.spray_jobs.resistance_position_snapshot is
  'Verbatim sql/196 position object FROZEN at job creation — the original '
  'planned intent (products/group_codes, timing, note). Never verdicts. Never '
  're-derived from the current plan. Required whenever the link is set.';
comment on column public.spray_jobs.resistance_plan_source_revision is
  'resistance_plans.server_revision (sql/198) the creating client had synced '
  'when it froze the snapshot. NULL when the plan had never synced (offline '
  'draft) — a legitimate state, never faked.';

-- ---------------------------------------------------------------------------
-- 2. Shape constraint: a link is all-or-nothing and self-consistent.
--    * unlinked  => all four columns NULL
--    * linked    => plan id + non-empty position id + snapshot object whose
--                   own id equals resistance_position_id (the freeze must be
--                   OF that position, not of some other one)
--    * source revision only meaningful on a linked job
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'spray_jobs_resistance_link_shape'
  ) then
    alter table public.spray_jobs
      add constraint spray_jobs_resistance_link_shape check (
        (
          resistance_plan_id is null
          and resistance_position_id is null
          and resistance_position_snapshot is null
          and resistance_plan_source_revision is null
        )
        or
        (
          resistance_plan_id is not null
          and resistance_position_id is not null
          and length(btrim(resistance_position_id)) > 0
          and resistance_position_snapshot is not null
          and jsonb_typeof(resistance_position_snapshot) = 'object'
          and btrim(coalesce(resistance_position_snapshot ->> 'id', ''))
              = btrim(resistance_position_id)
        )
      );
  end if;
end $$;

-- Position -> jobs lookup (planner progress, portal). Partial: the vast
-- majority of spray_jobs rows are unlinked templates/ad-hoc jobs.
create index if not exists idx_spray_jobs_resistance_plan
  on public.spray_jobs (resistance_plan_id, resistance_position_id)
  where resistance_plan_id is not null;

-- ---------------------------------------------------------------------------
-- 3. Cross-vineyard guard.
--
-- A spray job in vineyard A must never link to a resistance plan in vineyard
-- B. SECURITY DEFINER is required: RLS hides the foreign plan row from the
-- writer, and an invisible row must still be able to veto the link.
--
-- When the plan row does NOT exist yet the write is ACCEPTED ("pending plan")
-- — that is the offline-ordering contract, not a hole: the link can never
-- RESOLVE cross-vineyard because every resolution function below joins on
-- vineyard equality, so a pending link whose plan later lands in another
-- vineyard stays permanently inert (and is reported as invalid by
-- spray_job_resistance_link_state).
-- ---------------------------------------------------------------------------
create or replace function public.spray_jobs_validate_plan_provenance()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_plan_vineyard uuid;
begin
  if new.resistance_plan_id is null then
    return new;
  end if;

  select vineyard_id into v_plan_vineyard
  from public.resistance_plans
  where id = new.resistance_plan_id;

  if found and v_plan_vineyard <> new.vineyard_id then
    raise exception
      'spray_jobs: resistance_plan_id % belongs to a different vineyard than spray_job %',
      new.resistance_plan_id, new.id;
  end if;

  return new;
end;
$function$;

drop trigger if exists spray_jobs_validate_plan_provenance_trg on public.spray_jobs;
create trigger spray_jobs_validate_plan_provenance_trg
before insert or update of resistance_plan_id, vineyard_id on public.spray_jobs
for each row execute function public.spray_jobs_validate_plan_provenance();

-- ---------------------------------------------------------------------------
-- 4. Completed provenance is immutable.
--
-- Before completion a proposed job may be re-linked or unlinked. Once ANY
-- live spray_record references the job (spray_records.spray_job_id, sql/033),
-- the four provenance columns are FROZEN — normal edits must never rewrite
-- historical plan provenance, and that includes clearing it. SECURITY DEFINER
-- so the referencing record vetoes the edit even when RLS hides it from the
-- writer.
-- ---------------------------------------------------------------------------
create or replace function public.spray_jobs_freeze_completed_provenance()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if (
       new.resistance_plan_id is distinct from old.resistance_plan_id
    or new.resistance_position_id is distinct from old.resistance_position_id
    or new.resistance_position_snapshot is distinct from old.resistance_position_snapshot
    or new.resistance_plan_source_revision is distinct from old.resistance_plan_source_revision
  ) and exists (
    select 1 from public.spray_records sr
    where sr.spray_job_id = old.id
      and sr.deleted_at is null
  ) then
    raise exception
      'spray_jobs: plan provenance is frozen — spray job % has a completed spray record',
      old.id;
  end if;

  return new;
end;
$function$;

drop trigger if exists spray_jobs_freeze_completed_provenance_trg on public.spray_jobs;
create trigger spray_jobs_freeze_completed_provenance_trg
before update on public.spray_jobs
for each row execute function public.spray_jobs_freeze_completed_provenance();

-- ---------------------------------------------------------------------------
-- 5. Link resolution state (diagnostics / portal display).
--
-- 'none'                   — job carries no plan provenance
-- 'pending_plan'           — link stored, plan row not on the server yet
--                            (offline ordering; resolves when the plan lands)
-- 'linked'                 — plan exists in the SAME vineyard
-- 'cross_vineyard_invalid' — plan exists in a DIFFERENT vineyard; the link is
--                            permanently inert (never resolvable, never
--                            counted by the progress functions)
--
-- SECURITY DEFINER with an explicit membership check on the JOB's vineyard:
-- the caller must be allowed to see the job, and the function may then look
-- at a plan row RLS would hide (that is exactly how a cross-vineyard link is
-- reported instead of masquerading as pending).
-- ---------------------------------------------------------------------------
create or replace function public.spray_job_resistance_link_state(p_job_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_job public.spray_jobs%rowtype;
  v_plan_vineyard uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select * into v_job from public.spray_jobs where id = p_job_id;
  if v_job.id is null then
    raise exception 'Spray job not found';
  end if;

  if not public.is_vineyard_member(v_job.vineyard_id) then
    raise exception 'Insufficient permissions to read spray job %', p_job_id;
  end if;

  if v_job.resistance_plan_id is null then
    return 'none';
  end if;

  select vineyard_id into v_plan_vineyard
  from public.resistance_plans
  where id = v_job.resistance_plan_id;

  if not found then
    return 'pending_plan';
  end if;

  if v_plan_vineyard <> v_job.vineyard_id then
    return 'cross_vineyard_invalid';
  end if;

  return 'linked';
end;
$function$;

revoke all on function public.spray_job_resistance_link_state(uuid) from public;
grant execute on function public.spray_job_resistance_link_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Position -> jobs resolution.
--
-- SECURITY INVOKER on purpose: RLS applies, so a caller only ever sees jobs
-- of vineyards they belong to. The join on vineyard equality is what makes a
-- cross-vineyard link permanently inert even for definers layered on top.
-- Soft-deleted (archived) jobs are excluded.
-- ---------------------------------------------------------------------------
create or replace function public.resistance_position_spray_job_ids(
  p_plan_id uuid,
  p_position_id text
)
returns setof uuid
language sql
stable
as $function$
  select sj.id
  from public.spray_jobs sj
  join public.resistance_plans rp
    on rp.id = sj.resistance_plan_id
   and rp.vineyard_id = sj.vineyard_id
  where sj.resistance_plan_id = p_plan_id
    and sj.resistance_position_id = p_position_id
    and sj.deleted_at is null;
$function$;

grant execute on function public.resistance_position_spray_job_ids(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Derived position progress (requirement: progress is NEVER written back
--    into the plan).
--
--   proposed_paddock_ids  — union of spray_job_paddocks across the position's
--                           live linked jobs (proposed coverage)
--   completed_block_ids   — union of spray_records.block_ids (sql/195,
--                           derived from application_blocks) across live
--                           records referencing those jobs (actual coverage)
--
-- Multi-block partial execution falls out naturally: position covering
-- blocks A+B with job 1 completing A and job 2 still proposed reports
-- proposed {A,B} / completed {A}.
-- ---------------------------------------------------------------------------
create or replace function public.resistance_position_coverage(
  p_plan_id uuid,
  p_position_id text
)
returns table (
  spray_job_count integer,
  proposed_paddock_ids uuid[],
  completed_block_ids uuid[]
)
language sql
stable
as $function$
  with jobs as (
    select id from public.resistance_position_spray_job_ids(p_plan_id, p_position_id) as t(id)
  )
  select
    (select count(*) from jobs)::integer as spray_job_count,
    coalesce(
      (select array_agg(distinct sjp.paddock_id)
       from public.spray_job_paddocks sjp
       where sjp.spray_job_id in (select id from jobs)),
      '{}'::uuid[]
    ) as proposed_paddock_ids,
    coalesce(
      (select array_agg(distinct b.block_id)
       from public.spray_records sr
       cross join lateral unnest(sr.block_ids) as b(block_id)
       where sr.spray_job_id in (select id from jobs)
         and sr.deleted_at is null
         and sr.block_ids is not null),
      '{}'::uuid[]
    ) as completed_block_ids;
$function$;

grant execute on function public.resistance_position_coverage(uuid, text) to authenticated;

comment on function public.resistance_position_coverage(uuid, text) is
  'Derived plan-position progress. Proposed coverage from spray_job_paddocks, '
  'completed coverage from spray_records.block_ids via spray_records.'
  'spray_job_id. Read-only: creating/completing jobs never writes to '
  'resistance_plans and never bumps its server_revision.';

commit;
