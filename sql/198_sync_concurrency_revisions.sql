-- =============================================================================
-- 198: Sync integrity — replace device wall-clock concurrency with a
--      SERVER-AUTHORITATIVE revision token.
--
-- RUN THIS FILE AS ONE TRANSACTION (psql --single-transaction, or wrap in
-- begin/commit). Section 6 briefly re-wires the stale-write triggers.
--
-- -----------------------------------------------------------------------------
-- THE DEFECT (introduced by sql/185, inherited by sql/196)
-- -----------------------------------------------------------------------------
-- public.reject_stale_client_write() decided whether an edit was stale by
-- comparing two wall-clock timestamps:
--
--     new.client_updated_at < old.client_updated_at  ->  return null (skip)
--
-- `client_updated_at` is produced by the DEVICE:
--     iOS      ResistancePlanRepository.swift  clock = Date()
--     Android  ResistancePlanRepository.kt     clock = System.currentTimeMillis()
-- while portal / RPC / external-API writers use server now() (sql/186).
--
-- Two independent clocks were being compared as if they were one ordered
-- sequence. Consequences, both real:
--
--   SLOW DEVICE  A phone 10 minutes behind the server opens a row that the
--                portal just saved (stored stamp = server now()), makes a
--                genuine NEW edit, and submits 09:55 against a stored 10:00.
--                The guard reads it as stale and DISCARDS it.
--
--   FAST DEVICE  A phone 10 minutes ahead writes 10:10. That value is stored.
--                Every other device and the portal are now locked out until
--                the server clock passes 10:10 — their honest edits look
--                stale. One bad clock poisons the row for everyone.
--
--   SILENTLY     Returning NULL from a BEFORE UPDATE trigger skips the row
--                without raising. PostgREST reports success (the Android
--                client asks for `return=minimal`, so 204 No Content). The
--                app clears its outbox and shows the edit as saved. The
--                grower's work is gone with no error, anywhere.
--
-- -----------------------------------------------------------------------------
-- THE REPAIR — optimistic concurrency on a server-issued revision
-- -----------------------------------------------------------------------------
-- A wall clock records WHEN A HUMAN EDITED. It is useful metadata and it stays.
-- It is not a concurrency authority and it stops being used as one.
--
--   server_revision  bigint, SERVER-ISSUED. Advances on every update, in one
--                    place, from one clock-free counter. Clients cannot set it;
--                    the bump trigger overwrites whatever they send.
--
--   base_revision    bigint, the version the client's edit was BASED ON. A
--                    TRANSIENT WRITE-ONLY CHANNEL — always stored as NULL
--                    (section 4 explains why this matters for old clients).
--
-- New/updated writers send base_revision. The guard then ignores wall clocks
-- completely and answers the only question that matters: "is this edit based on
-- the version the row is still at?" If not, it RAISES a conflict the client
-- cannot mistake for success.
--
-- Old released clients send no base_revision. They keep the timestamp path, but
-- two things change for them, both strict improvements and neither requiring an
-- app update:
--   * incoming client_updated_at is clamped to now(), so a fast clock can no
--     longer poison a row (section 3);
--   * a discarded write is recorded in public.sync_discarded_writes with its
--     full payload, so the loss is visible and recoverable instead of silent
--     (section 5).
--
-- Fully fixing the slow-clock case for a released client is impossible: it
-- sends nothing that distinguishes "late replay of an old edit" from "new edit
-- made on a slow phone". Only a base_revision can. Hence the staged rollout —
-- this migration is additive and safe to apply on its own, with no client
-- change; clients adopt base_revision afterwards.
--
-- Applies to the three tables clients upsert directly and that carry the
-- stale-write guard:
--     public.pruning_seasons         (sql/185)
--     public.pruning_yield_settings  (sql/185)
--     public.resistance_plans        (sql/196)
-- Resistance Plans are NOT merged element-wise; see section 4.
--
-- No column is dropped, no semantics are removed, no backfill.
-- Verification: sql/tests/198_sync_concurrency_revisions_tests.sql
-- Contract doc: docs/sync-concurrency-contract.md
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Additive columns.
--
-- server_revision starts at 1 for every existing row, so the first versioned
-- write from a new client has a defined base to match against.
-- ---------------------------------------------------------------------------
alter table public.pruning_seasons
  add column if not exists server_revision bigint not null default 1,
  add column if not exists base_revision   bigint null;

alter table public.pruning_yield_settings
  add column if not exists server_revision bigint not null default 1,
  add column if not exists base_revision   bigint null;

alter table public.resistance_plans
  add column if not exists server_revision bigint not null default 1,
  add column if not exists base_revision   bigint null;

comment on column public.resistance_plans.server_revision is
  'Server-issued optimistic-concurrency token. Advances on every update. Clients cannot set it. This — not client_updated_at — decides whether an edit is stale.';
comment on column public.resistance_plans.base_revision is
  'Transient write-only channel: the server_revision the client edit was based on. Always stored NULL; never read back.';
comment on column public.resistance_plans.client_updated_at is
  'When the human edited, from the device clock. Metadata and display only. NOT a concurrency authority (see sql/198).';

-- ---------------------------------------------------------------------------
-- 2. Discarded-write audit trail.
--
-- The legacy timestamp path still skips a stale write, but never invisibly
-- again: the whole rejected row is kept so support can recover a grower's lost
-- edit, and so the frequency of this path is measurable during the rollout.
--
-- Written ONLY by the SECURITY DEFINER guard. No client insert/update/delete
-- policy exists, so the trail cannot be tampered with from an app.
-- ---------------------------------------------------------------------------
create table if not exists public.sync_discarded_writes (
  id                        bigserial primary key,
  table_name                text        not null,
  row_id                    uuid        null,
  vineyard_id               uuid        null,
  reason                    text        not null,
  attempted_client_updated_at timestamptz null,
  stored_client_updated_at    timestamptz null,
  stored_server_revision    bigint      null,
  attempted_by              uuid        null,
  attempted_payload         jsonb       not null,
  attempted_at              timestamptz not null default now()
);

create index if not exists idx_sync_discarded_writes_vineyard
  on public.sync_discarded_writes (vineyard_id, attempted_at desc);
create index if not exists idx_sync_discarded_writes_row
  on public.sync_discarded_writes (table_name, row_id, attempted_at desc);

alter table public.sync_discarded_writes enable row level security;

-- Members may see that a write to THEIR vineyard was discarded. Rows with a
-- null vineyard_id (unattributable) are visible to nobody through the API.
drop policy if exists "sync_discarded_writes_select_members" on public.sync_discarded_writes;
create policy "sync_discarded_writes_select_members"
on public.sync_discarded_writes for select
to authenticated
using (vineyard_id is not null and public.is_vineyard_member(vineyard_id));

grant select on public.sync_discarded_writes to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Clock clamp — kills the fast-device defect for EVERY client.
--
-- A stored client_updated_at may never be in the server's future. A phone
-- running 10 minutes ahead therefore cannot park an unreachable timestamp on
-- the row and lock out every other device until the server catches up.
--
-- least() with a NULL argument yields NULL, so a client that sends no timestamp
-- is unaffected. No tolerance window: a device a few seconds ahead is clamped a
-- few seconds, which changes nothing observable.
-- ---------------------------------------------------------------------------
create or replace function public.clamp_client_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.client_updated_at is not null then
    new.client_updated_at := least(new.client_updated_at, now());
  end if;
  return new;
end;
$$;

comment on function public.clamp_client_updated_at() is
  'Clamps a client-supplied client_updated_at to server now(). Prevents a fast device clock from poisoning a row against all other writers (sql/198).';

-- ---------------------------------------------------------------------------
-- 4. The concurrency guard.
--
-- Replaces the body of the sql/185 guard. CREATE OR REPLACE keeps the OID, so
-- any trigger still bound to it changes behaviour atomically with no window in
-- which a table is unguarded.
--
-- SECURITY DEFINER because it writes public.sync_discarded_writes, which is
-- RLS-protected. Under caller rights the audit insert would be silently
-- filtered for exactly the writers we most need to record — the same class of
-- bug fixed in sql/197. search_path is pinned.
--
-- WHY base_revision IS NEVER PERSISTED
-- PostgREST `resolution=merge-duplicates` only assigns the columns present in
-- the request body. If base_revision were stored, an OLD client's upsert — which
-- omits the column — would leave the previous value in place, and the guard
-- would read that stale number as if the old client had sent it and raise a
-- conflict on a write that is perfectly fine. Nulling it on every write keeps
-- the two paths strictly independent, which is what makes the staged rollout
-- safe. The value is preserved in the audit trail when it matters, not on the row.
--
-- WHOLE-DOCUMENT CONFLICTS, NEVER ELEMENT-WISE MERGE (unchanged from sql/196)
-- If device A moves the Group 11 spray earlier and device B deletes that
-- position, there is no defensible automatic merge: any row-wise reconciliation
-- can produce an ordered sequence NEITHER operator authored and then present it
-- as a resistance-compliant plan. One authored version wins, or the client is
-- told there is a conflict. This guard does the latter for versioned writers.
-- ---------------------------------------------------------------------------
create or replace function public.reject_stale_client_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base        bigint;
  v_new         jsonb;
  v_vineyard    uuid;
  v_row_id      uuid;
begin
  v_base := new.base_revision;
  -- Transient channel: consumed here, never stored. See the note above.
  new.base_revision := null;

  -- ---------------------------------------------------------------------
  -- Versioned path: server_revision is the authority. Wall clocks are not
  -- consulted at all, so ANY amount of device clock skew is irrelevant.
  -- ---------------------------------------------------------------------
  if v_base is not null then
    if v_base <> old.server_revision then
      -- Explicit, machine-readable, impossible to mistake for success.
      -- SQLSTATE class PT maps to an HTTP status in PostgREST (PT409 -> 409
      -- Conflict). Clients match on the MESSAGE 'REVISION_CONFLICT', which is
      -- the stable signal even behind a gateway that rewrites the status.
      raise exception 'REVISION_CONFLICT'
        using errcode = 'PT409',
              detail  = json_build_object(
                          'code',            'REVISION_CONFLICT',
                          'table',           tg_table_name,
                          'server_revision', old.server_revision,
                          'base_revision',   v_base
                        )::text,
              hint    = 'Reload the row, re-apply your edit on top of the current version, and resubmit with base_revision = server_revision.';
    end if;
    return new;
  end if;

  -- ---------------------------------------------------------------------
  -- Legacy path: no base_revision, so the client cannot express what it based
  -- its edit on. The timestamp comparison is retained — dropping it would let
  -- a late offline replay overwrite a newer edit, which is worse than the skew
  -- it causes — but the discard is now recorded instead of vanishing.
  -- Both sides have already been clamped by clamp_client_updated_at().
  -- ---------------------------------------------------------------------
  if new.client_updated_at is not null
     and old.client_updated_at is not null
     and new.client_updated_at < old.client_updated_at then

    v_new      := to_jsonb(new);
    v_vineyard := nullif(v_new->>'vineyard_id', '')::uuid;
    v_row_id   := nullif(v_new->>'id', '')::uuid;

    insert into public.sync_discarded_writes (
      table_name, row_id, vineyard_id, reason,
      attempted_client_updated_at, stored_client_updated_at,
      stored_server_revision, attempted_by, attempted_payload
    ) values (
      tg_table_name, v_row_id, v_vineyard, 'stale_client_updated_at',
      new.client_updated_at, old.client_updated_at,
      old.server_revision, auth.uid(), v_new
    );

    return null;
  end if;

  return new;
end;
$$;

comment on function public.reject_stale_client_write() is
  'Concurrency guard. base_revision present -> server_revision decides (clock-independent), mismatch raises REVISION_CONFLICT/PT409. Absent -> legacy clamped-timestamp path, and any discard is recorded in sync_discarded_writes (sql/198).';

-- ---------------------------------------------------------------------------
-- 5. Server-issued revision bump.
--
-- Runs on EVERY write, after the guard, so the counter advances for mobile
-- upserts, portal PATCHes, RPCs and server-side maintenance alike. Assigning
-- unconditionally from old.server_revision is also what makes the token
-- untrustable-by-clients: whatever a client puts in server_revision is
-- overwritten here.
-- ---------------------------------------------------------------------------
create or replace function public.bump_server_revision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.server_revision := 1;
  else
    new.server_revision := old.server_revision + 1;
  end if;
  new.base_revision := null;
  return new;
end;
$$;

comment on function public.bump_server_revision() is
  'Advances the server-issued concurrency token on every write and discards any client-supplied value (sql/198).';

-- ---------------------------------------------------------------------------
-- 6. Trigger wiring.
--
-- Names are numerically prefixed because Postgres fires same-event triggers in
-- ALPHABETICAL order and this sequence is load-bearing:
--   t10 clamp   normalise the incoming clock BEFORE anything compares it
--   t20 guard   accept / conflict / discard
--   t30 bump    only reached if the row survived the guard
-- The sql/185 and sql/196 trigger names are dropped so no table ends up with
-- both the old and the new wiring.
-- ---------------------------------------------------------------------------
drop trigger if exists pruning_seasons_stale_write_guard        on public.pruning_seasons;
drop trigger if exists pruning_yield_settings_stale_write_guard on public.pruning_yield_settings;
drop trigger if exists resistance_plans_stale_write_guard       on public.resistance_plans;

create or replace trigger t10_clamp_client_clock
before insert or update on public.pruning_seasons
for each row execute function public.clamp_client_updated_at();
create or replace trigger t20_concurrency_guard
before update on public.pruning_seasons
for each row execute function public.reject_stale_client_write();
create or replace trigger t30_bump_server_revision
before insert or update on public.pruning_seasons
for each row execute function public.bump_server_revision();

create or replace trigger t10_clamp_client_clock
before insert or update on public.pruning_yield_settings
for each row execute function public.clamp_client_updated_at();
create or replace trigger t20_concurrency_guard
before update on public.pruning_yield_settings
for each row execute function public.reject_stale_client_write();
create or replace trigger t30_bump_server_revision
before insert or update on public.pruning_yield_settings
for each row execute function public.bump_server_revision();

create or replace trigger t10_clamp_client_clock
before insert or update on public.resistance_plans
for each row execute function public.clamp_client_updated_at();
create or replace trigger t20_concurrency_guard
before update on public.resistance_plans
for each row execute function public.reject_stale_client_write();
create or replace trigger t30_bump_server_revision
before insert or update on public.resistance_plans
for each row execute function public.bump_server_revision();

-- ---------------------------------------------------------------------------
-- 7. Postconditions.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  v_missing text := '';
begin
  foreach t in array array['pruning_seasons','pruning_yield_settings','resistance_plans']
  loop
    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = t
         and column_name = 'server_revision'
    ) then
      v_missing := v_missing || format(' %s.server_revision', t);
    end if;
    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = t
         and column_name = 'base_revision'
    ) then
      v_missing := v_missing || format(' %s.base_revision', t);
    end if;
    if not exists (
      select 1 from pg_trigger g
        join pg_class c on c.oid = g.tgrelid
       where c.relname = t and g.tgname = 't20_concurrency_guard' and not g.tgisinternal
    ) then
      v_missing := v_missing || format(' %s.t20_concurrency_guard', t);
    end if;
    if not exists (
      select 1 from pg_trigger g
        join pg_class c on c.oid = g.tgrelid
       where c.relname = t and g.tgname = 't30_bump_server_revision' and not g.tgisinternal
    ) then
      v_missing := v_missing || format(' %s.t30_bump_server_revision', t);
    end if;
  end loop;

  if v_missing <> '' then
    raise exception 'sql/198 incomplete, missing:%', v_missing;
  end if;

  -- Both cross-table writers must be able to see past RLS.
  if not (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'reject_stale_client_write') then
    raise exception 'sql/198: reject_stale_client_write() must be SECURITY DEFINER (it writes RLS-protected sync_discarded_writes)';
  end if;

  raise notice 'sql/198 applied: server-authoritative revisions live on 3 tables';
end$$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- ROLLBACK (restores the sql/185 + sql/196 behaviour exactly, including its
-- silent-discard defect — only for an emergency revert):
--
--   drop trigger if exists t10_clamp_client_clock    on public.pruning_seasons;
--   drop trigger if exists t20_concurrency_guard     on public.pruning_seasons;
--   drop trigger if exists t30_bump_server_revision  on public.pruning_seasons;
--   (repeat for pruning_yield_settings and resistance_plans)
--
--   create or replace function public.reject_stale_client_write()
--   returns trigger language plpgsql as $$
--   begin
--     if new.client_updated_at is not null and old.client_updated_at is not null
--        and new.client_updated_at < old.client_updated_at then
--       return null;
--     end if;
--     return new;
--   end; $$;
--
--   create trigger pruning_seasons_stale_write_guard before update
--     on public.pruning_seasons for each row
--     execute function public.reject_stale_client_write();
--   (repeat for the other two tables, matching sql/185 / sql/196 names)
--
-- Leave the columns and public.sync_discarded_writes in place — they are inert
-- without the triggers, and the audit trail is evidence worth keeping.
-- ---------------------------------------------------------------------------
