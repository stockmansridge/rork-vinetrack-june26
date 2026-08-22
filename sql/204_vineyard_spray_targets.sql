-- =============================================================================
-- 204: Vineyard spray target library — reusable custom target tags.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) and Android CONSUME it and MUST NOT independently create or
-- modify these objects.
--
-- ---------------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------------
-- sql/193 gave `spray_records` and `spray_jobs` a `targets text[]` column with
-- NO value CHECK, precisely so the target vocabulary could grow per-region
-- without a migration. That decision already lets a vineyard STORE a target
-- VineTrack has no enum case for — Eutypa Dieback, Phomopsis, Black Spot,
-- Light Brown Apple Moth.
--
-- What it does not give is REUSE. An operator who types "Eutypa Dieback" on one
-- Program Step gets no help typing it on the next, and two operators produce
-- "Eutypa dieback" and "eutypa die-back", which are different identifiers and
-- therefore invisible to each other in the Resistance Planner's containment
-- query. The wording is also unrecoverable from the identifier alone: a slug
-- cannot tell you the original had brackets in it.
--
-- This table is the smallest thing that fixes both: a vineyard-scoped map from
-- the stable identifier to the wording the vineyard chose. It is a VOCABULARY,
-- not a relationship — nothing references it, no spray depends on it, and
-- deleting a row can never orphan a record, because the identifier already
-- lives on the spray itself. That is deliberate: the library makes targets
-- reusable and readable, and is never load-bearing for what a spray targeted.
--
-- Built-in targets are NOT stored here. They are compiled into the apps and
-- would only drift.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
-- ---------------------------------------------------------------------------
-- STRICTLY ADDITIVE. One new table, two RPCs. No existing table, column,
-- constraint, index, policy or function is altered. Nothing is backfilled — a
-- vineyard's library starts empty and fills as targets are used.
--
-- Naming and shape mirror `vineyard_custom_pin_types` (sql/170), the existing
-- vineyard-shared user-authored catalogue, so there is one pattern for this
-- kind of thing rather than two.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The library
-- ---------------------------------------------------------------------------
-- Shared across every authorised user of the vineyard (iOS / Android / portal).
-- Never device- or user-specific.
--
-- `identifier` is the slug that goes into spray_records.targets /
-- spray_jobs.targets. `label` is the wording the operator typed. Both are
-- required: an identifier with no wording is unreadable, and wording with no
-- identifier is unmatchable.
create table if not exists public.vineyard_spray_targets (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  identifier text not null check (btrim(identifier) <> ''),
  label text not null check (btrim(label) <> ''),
  is_active boolean not null default true,
  created_by uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One entry per identifier per vineyard. Case-insensitive because the
-- identifier is already lower-cased by the clients and a stray upper-case
-- write must converge rather than duplicate. Inactive rows keep their wording
-- so historical sprays never lose meaning.
create unique index if not exists uq_vineyard_spray_target_active_identifier
  on public.vineyard_spray_targets (vineyard_id, lower(btrim(identifier)))
  where is_active;

create index if not exists idx_vineyard_spray_targets_vineyard
  on public.vineyard_spray_targets (vineyard_id) where is_active;

alter table public.vineyard_spray_targets enable row level security;

-- Read for every member: the target chooser is used by operators recording
-- sprays, not just by the managers who may edit the program.
drop policy if exists "vineyard_spray_targets_select_members" on public.vineyard_spray_targets;
create policy "vineyard_spray_targets_select_members"
on public.vineyard_spray_targets for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

-- No insert/update/delete policies: writes go through the SECURITY DEFINER
-- RPCs below so the database enforces roles and the duplicate rule.

-- ---------------------------------------------------------------------------
-- 2. Catalogue JSON + RPCs
-- ---------------------------------------------------------------------------
create or replace function public.vineyard_spray_target_json(t public.vineyard_spray_targets)
returns jsonb
language sql
stable
set search_path = public
as $function$
  select jsonb_build_object(
    'id', t.id,
    'vineyard_id', t.vineyard_id,
    'identifier', t.identifier,
    'label', t.label,
    'is_active', t.is_active,
    'created_by', t.created_by,
    'created_at', t.created_at,
    'updated_at', t.updated_at
  );
$function$;

-- Idempotent create keyed by the client-generated id (offline-safe replay).
-- A duplicate ACTIVE identifier returns the EXISTING row instead of erroring,
-- so two operators adding "Eutypa Dieback" converge on one shared entry and
-- neither loses their save.
--
-- Anyone who may record a spray may add a target: the alternative is an
-- operator silently dropping the actual target of the spray they are recording
-- because a manager is not available to add the word.
create or replace function public.create_vineyard_spray_target(
  p_id uuid,
  p_vineyard_id uuid,
  p_identifier text,
  p_label text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_existing public.vineyard_spray_targets;
  v_row public.vineyard_spray_targets;
  v_identifier text := lower(btrim(coalesce(p_identifier, '')));
  v_label text := btrim(coalesce(p_label, ''));
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  if not public.has_vineyard_role(
        p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'PERMISSION_DENIED: you cannot add spray targets in this vineyard';
  end if;
  if v_identifier = '' or v_label = '' then
    raise exception 'TARGET_REQUIRED: a target needs a name';
  end if;

  -- Idempotent replay by client id.
  select * into v_existing from public.vineyard_spray_targets where id = p_id;
  if found then
    return public.vineyard_spray_target_json(v_existing);
  end if;

  -- Same identifier already active in this vineyard -> converge.
  select * into v_existing
  from public.vineyard_spray_targets
  where vineyard_id = p_vineyard_id
    and is_active
    and lower(btrim(identifier)) = v_identifier
  limit 1;
  if found then
    return public.vineyard_spray_target_json(v_existing);
  end if;

  insert into public.vineyard_spray_targets (
    id, vineyard_id, identifier, label, created_by
  )
  values (p_id, p_vineyard_id, v_identifier, v_label, auth.uid())
  returning * into v_row;

  return public.vineyard_spray_target_json(v_row);
end;
$function$;

create or replace function public.list_vineyard_spray_targets(
  p_vineyard_id uuid,
  p_include_inactive boolean default false
)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $function$
  select public.vineyard_spray_target_json(t)
  from public.vineyard_spray_targets t
  where t.vineyard_id = p_vineyard_id
    and (p_include_inactive or t.is_active)
    and public.is_vineyard_member(t.vineyard_id)
  order by lower(t.label);
$function$;

revoke all on function public.create_vineyard_spray_target(uuid, uuid, text, text) from public;
revoke all on function public.list_vineyard_spray_targets(uuid, boolean) from public;
grant execute on function public.create_vineyard_spray_target(uuid, uuid, text, text) to authenticated;
grant execute on function public.list_vineyard_spray_targets(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Documentation
-- ---------------------------------------------------------------------------
comment on table public.vineyard_spray_targets is
  'Vineyard-scoped reusable spray target vocabulary. Maps the stable identifier '
  'stored in spray_records.targets / spray_jobs.targets to the wording this '
  'vineyard uses for it. Built-in VineTrack targets are compiled into the apps '
  'and are NOT stored here. Advisory only: a spray never depends on this table, '
  'because the identifier already lives on the spray itself.';

comment on column public.vineyard_spray_targets.identifier is
  'Stable slug written into the targets text[] columns (sql/193), e.g. '
  '''eutypa_dieback''. Lower-cased. Must match what the clients slug the label '
  'to, or the tag will not be recognised on reload.';

comment on column public.vineyard_spray_targets.label is
  'The wording the vineyard chose, verbatim, e.g. ''Eutypa Dieback''. The only '
  'place a custom target''s exact punctuation survives, since the identifier '
  'strips it.';

commit;

-- =============================================================================
-- ROLLBACK (manual)
--
-- begin;
--   drop function if exists public.list_vineyard_spray_targets(uuid, boolean);
--   drop function if exists public.create_vineyard_spray_target(uuid, uuid, text, text);
--   drop function if exists public.vineyard_spray_target_json(public.vineyard_spray_targets);
--   drop table if exists public.vineyard_spray_targets;
-- commit;
--
-- END 204
--
-- Manual actions after applying:
--   * NO backfill. A vineyard's library fills as targets are used. The clients
--     additionally OFFER any identifier already present on that vineyard's own
--     Program Steps, so an existing "Phomopsis" is reusable before this table
--     has ever been written to.
--   * Clients degrade gracefully while this migration is unapplied: the library
--     add is queued, the tag is still written to the step's `targets` array, and
--     the wording still round-trips through the legacy `target` display column.
--   * Lovable/portal + Android: CONSUME the same two RPCs. Do not add a second
--     target vocabulary.
-- =============================================================================
