-- =============================================================================
-- 221: Canonical seasonal (pre-harvest) yield estimates
--
-- Shared VineTrack Supabase project — the single backend behind iOS, Android
-- and the Lovable portal.
--
-- WHAT THIS MIGRATION MAKES AUTHORITATIVE
--   * the Vintage a damage record belongs to        (damage_records.vintage)
--   * the Vintage an estimation session belongs to  (yield_estimation_sessions.vintage)
--   * the BASE (undamaged) seasonal yield estimate  (season_yield_estimates)
--   * the estimate SOURCE and its priority          (manual > bunch_count > pruning_calculator)
--   * variety / planting-group identity for those estimates
--
-- WHAT THIS MIGRATION DELIBERATELY DOES **NOT** DO
--   * It never calculates, stores or returns a damage-ADJUSTED yield.
--     The damage engines stay exactly where they are today (iOS
--     `MigratedDataStore.damageFactor(for:)`, Android
--     `List<DamageRecord>.damageFactor(paddockId)`, and the portal's own
--     implementation). This migration only tells every client WHICH damage
--     records belong to the selected Vintage and what the BASE tonnes are;
--     each client then runs its existing engine and honours its existing
--     "Apply damage" toggle. Parity is enforced by the shared fixtures in
--     docs/season-yield-damage-parity-fixtures.md, not by a fourth formula.
--   * It does not touch Actual Yield, picking_records, or any cost report.
--   * It does not add a second vintage resolver. Everything routes through
--     public.resolve_vineyard_vintage_year(uuid, date) (sql/119).
--   * It does not change polygon_points, damage_percent, damage type/status,
--     soft deletion, overlap behaviour or damage permissions.
--
-- ADDITIVE ONLY. Idempotent: safe to re-run over an already-applied SQL 221.
--
-- Audited against live schema conventions before writing:
--   * membership roles  = owner | manager | supervisor | operator (sql/001)
--   * role helpers      = public.is_vineyard_member(uuid),
--                         public.has_vineyard_role(uuid, text[])
--   * soft delete       = deleted_at timestamptz + updated_by uuid; hard
--                         DELETE denied by an RLS policy (sql/014 pattern)
--   * sync columns      = client_updated_at + sync_version + updated_at
--                         maintained by public.set_updated_at()
--   * block identity    = paddock_id with NO foreign key (sql/181, sql/180)
--   * planting identity = public.planting_group_key(variety, clone, rootstock)
--                         (sql/184) over paddocks.variety_allocations[]
--   * block area        = public._paddock_polygon_area_hectares(jsonb)
--                         (sql/095 — mirrors the app's areaHectares formula)
--
-- ---------------------------------------------------------------------------
-- REVIEW NOTES — please confirm these two judgement calls before applying
-- ---------------------------------------------------------------------------
--  (1) Damage vintage basis uses `coalesce(date_observed, date)::date`
--      exactly as specified. Unlike work_tasks (sql/119 §4) this does NOT
--      convert the timestamptz to the vineyard's local time first. For a
--      record observed within a few hours of the season boundary the two
--      approaches can differ by one Vintage. Say the word and the trigger
--      switches to `(coalesce(date_observed, date) at time zone
--      vineyards.timezone)::date` for exact parity with work-task costing.
--  (2) The backfill UPDATEs fire each table's existing set_updated_at
--      trigger, so every backfilled damage record / session gets a new
--      updated_at and will be re-pulled once by each device. That is
--      intentional — it is how existing installs learn their vintage — but
--      it does mean a one-off sync of those two tables after apply.
-- =============================================================================


-- ===========================================================================
-- A. damage_records.vintage
-- ===========================================================================

alter table public.damage_records
  add column if not exists vintage integer null;

comment on column public.damage_records.vintage is
  'Season (vintage) this damage belongs to, resolved by public.resolve_vineyard_vintage_year(vineyard_id, coalesce(date_observed, date)::date). Server-resolved when a client omits it or sends an implausible value; an explicit plausible client value is preserved. Clients MUST filter damage by this column — never by a locally recomputed season. (SQL 221)';

create index if not exists damage_records_vineyard_vintage_idx
  on public.damage_records (vineyard_id, vintage)
  where deleted_at is null;

create or replace function public.damage_records_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := coalesce(new.date_observed, new.date)::date;

  if tg_op = 'UPDATE' then
    v_basis_changed :=
         coalesce(new.date_observed, new.date)
           is distinct from coalesce(old.date_observed, old.date)
      or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;

    -- Old client moved the observation date without knowing about vintage:
    -- follow the date. A client that explicitly restated the vintage in the
    -- same write is trusted below.
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  -- Old-client compatibility: absent or nonsense vintage is resolved server
  -- side BEFORE any constraint check, so a queued offline replay from an
  -- un-updated build can never be rejected.
  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;

  return new;
end;
$fn$;

drop trigger if exists damage_records_resolve_vintage on public.damage_records;
create trigger damage_records_resolve_vintage
  before insert or update on public.damage_records
  for each row execute function public.damage_records_resolve_vintage();

-- Backfill (see review note 2 about updated_at).
do $backfill_damage$
declare
  v_before integer;
  v_after  integer;
begin
  select count(*) into v_before from public.damage_records where vintage is null;

  update public.damage_records d
     set vintage = public.resolve_vineyard_vintage_year(
                     d.vineyard_id,
                     coalesce(d.date_observed, d.date)::date
                   )
   where d.vintage is null;

  select count(*) into v_after from public.damage_records where vintage is null;
  raise notice 'SQL 221 · damage_records vintage backfill: % rows needed a vintage, % still null',
    v_before, v_after;
end
$backfill_damage$;

-- Only tighten once the backfill genuinely left nothing behind.
do $notnull_damage$
begin
  if exists (select 1 from public.damage_records where vintage is null) then
    raise notice 'SQL 221 · damage_records.vintage LEFT NULLABLE — % rows unresolved',
      (select count(*) from public.damage_records where vintage is null);
  else
    begin
      alter table public.damage_records alter column vintage set not null;
      raise notice 'SQL 221 · damage_records.vintage set NOT NULL';
    exception when others then
      raise notice 'SQL 221 · damage_records.vintage NOT NULL skipped: %', sqlerrm;
    end;
  end if;
end
$notnull_damage$;


-- ===========================================================================
-- B. yield_estimation_sessions.vintage
--
-- The COLUMN is authoritative. Nothing may read a vintage out of `payload`
-- — the payload contract is unchanged and untouched here.
--
-- Incomplete sessions (is_completed = false) still carry a vintage so they
-- sort and filter correctly, but they never contribute to the canonical
-- estimate: only a completed session may be promoted into
-- season_yield_estimates as a `bunch_count` row (later phase).
-- ===========================================================================

alter table public.yield_estimation_sessions
  add column if not exists vintage integer null;

comment on column public.yield_estimation_sessions.vintage is
  'Season (vintage) this estimation session belongs to, resolved by public.resolve_vineyard_vintage_year(vineyard_id, coalesce(session_created_at, created_at)::date). Authoritative — never read a vintage out of payload. Incomplete sessions never feed season_yield_estimates. (SQL 221)';

create index if not exists yield_estimation_sessions_vineyard_vintage_idx
  on public.yield_estimation_sessions (vineyard_id, vintage)
  where deleted_at is null;

create or replace function public.yield_estimation_sessions_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := coalesce(new.session_created_at, new.created_at, now())::date;

  if tg_op = 'UPDATE' then
    v_basis_changed :=
         coalesce(new.session_created_at, new.created_at)
           is distinct from coalesce(old.session_created_at, old.created_at)
      or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;

    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;

  return new;
end;
$fn$;

drop trigger if exists yield_estimation_sessions_resolve_vintage on public.yield_estimation_sessions;
create trigger yield_estimation_sessions_resolve_vintage
  before insert or update on public.yield_estimation_sessions
  for each row execute function public.yield_estimation_sessions_resolve_vintage();

do $backfill_sessions$
declare
  v_before integer;
  v_after  integer;
begin
  select count(*) into v_before from public.yield_estimation_sessions where vintage is null;

  update public.yield_estimation_sessions s
     set vintage = public.resolve_vineyard_vintage_year(
                     s.vineyard_id,
                     coalesce(s.session_created_at, s.created_at)::date
                   )
   where s.vintage is null;

  select count(*) into v_after from public.yield_estimation_sessions where vintage is null;
  raise notice 'SQL 221 · yield_estimation_sessions vintage backfill: % rows needed a vintage, % still null',
    v_before, v_after;
end
$backfill_sessions$;

do $notnull_sessions$
begin
  if exists (select 1 from public.yield_estimation_sessions where vintage is null) then
    raise notice 'SQL 221 · yield_estimation_sessions.vintage LEFT NULLABLE — % rows unresolved',
      (select count(*) from public.yield_estimation_sessions where vintage is null);
  else
    begin
      alter table public.yield_estimation_sessions alter column vintage set not null;
      raise notice 'SQL 221 · yield_estimation_sessions.vintage set NOT NULL';
    exception when others then
      raise notice 'SQL 221 · yield_estimation_sessions.vintage NOT NULL skipped: %', sqlerrm;
    end;
  end if;
end
$notnull_sessions$;


-- ===========================================================================
-- C. Shared helpers
-- ===========================================================================

-- Estimate-source priority. manual beats bunch_count beats pruning_calculator.
-- A pruning refresh may only write over rank <= its own rank.
create or replace function public.season_yield_estimate_source_rank(p_source text)
returns integer
language sql
immutable
as $fn$
  select case lower(btrim(coalesce(p_source, '')))
           when 'manual'             then 3
           when 'bunch_count'        then 2
           when 'pruning_calculator' then 1
           else 0
         end;
$fn$;

-- paddocks.variety_allocations[] elements are written by three clients and
-- have accumulated key aliases over time (camelCase from iOS/Swift, plus the
-- snake_case @JsonNames aliases Android accepts). These two readers take the
-- first present alias in priority order so SQL sees exactly what the apps see.
create or replace function public._season_alloc_text(p_elem jsonb, p_keys text[])
returns text
language sql
immutable
as $fn$
  select nullif(btrim(p_elem ->> k.key), '')
    from unnest(p_keys) with ordinality as k(key, ord)
   where jsonb_typeof(p_elem -> k.key) = 'string'
     and nullif(btrim(p_elem ->> k.key), '') is not null
   order by k.ord
   limit 1;
$fn$;

create or replace function public._season_alloc_number(p_elem jsonb, p_keys text[])
returns double precision
language sql
immutable
as $fn$
  select (p_elem ->> k.key)::double precision
    from unnest(p_keys) with ordinality as k(key, ord)
   where jsonb_typeof(p_elem -> k.key) = 'number'
   order by k.ord
   limit 1;
$fn$;

revoke all on function public.season_yield_estimate_source_rank(text) from public;
revoke all on function public._season_alloc_text(jsonb, text[]) from public;
revoke all on function public._season_alloc_number(jsonb, text[]) from public;
grant execute on function public.season_yield_estimate_source_rank(text) to authenticated;
grant execute on function public._season_alloc_text(jsonb, text[]) to authenticated;
grant execute on function public._season_alloc_number(jsonb, text[]) to authenticated;


-- ===========================================================================
-- D. season_yield_estimates — the canonical BASE estimate
--
-- Grain: one active row per (vineyard_id, vintage, paddock_id,
-- planting_group_key). Stores UNADJUSTED tonnes only.
--
-- base_estimate_tonnes IS NULL + is_estimate_available = false means
-- "not configured" — never zero. setup_warnings names every missing input
-- so the apps can send the user straight to the right settings screen.
-- ===========================================================================

create table if not exists public.season_yield_estimates (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  vintage integer not null,

  -- No FK, matching pruning_yield_settings / picking_records: a removed block
  -- simply stops being surfaced by the clients.
  paddock_id uuid not null,

  -- Planting identity (sql/184). Canonicalised by the before-write trigger.
  planting_group_key text not null,
  variety_key text null,
  variety_name text not null default '',
  clone text null,
  rootstock text null,
  variety_allocation_ids uuid[] null,
  allocation_percent double precision not null default 100,
  is_unallocated boolean not null default false,

  estimate_source text not null default 'pruning_calculator',
  base_estimate_tonnes double precision null,
  is_estimate_available boolean not null default false,
  source_inputs jsonb not null default '{}'::jsonb,
  setup_warnings jsonb not null default '[]'::jsonb,
  calculated_at timestamptz not null default now(),

  -- Set when the row came from a COMPLETED yield_estimation_session.
  source_session_id uuid null,
  notes text not null default '',

  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

do $c$
begin
  alter table public.season_yield_estimates
    add constraint season_yield_estimates_vintage_check
    check (vintage between 2000 and 2100);
exception when duplicate_object then null;
end $c$;

do $c$
begin
  alter table public.season_yield_estimates
    add constraint season_yield_estimates_source_check
    check (estimate_source in ('pruning_calculator', 'bunch_count', 'manual'));
exception when duplicate_object then null;
end $c$;

do $c$
begin
  alter table public.season_yield_estimates
    add constraint season_yield_estimates_percent_check
    check (allocation_percent >= 0 and allocation_percent <= 100);
exception when duplicate_object then null;
end $c$;

do $c$
begin
  alter table public.season_yield_estimates
    add constraint season_yield_estimates_tonnes_check
    check (base_estimate_tonnes is null or base_estimate_tonnes >= 0);
exception when duplicate_object then null;
end $c$;

-- "Available" must mean a real number is present. Missing inputs stay NULL —
-- they are never flattened to 0 tonnes.
do $c$
begin
  alter table public.season_yield_estimates
    add constraint season_yield_estimates_availability_check
    check (is_estimate_available = false or base_estimate_tonnes is not null);
exception when duplicate_object then null;
end $c$;

do $c$
begin
  alter table public.season_yield_estimates
    add constraint season_yield_estimates_group_key_check
    check (btrim(planting_group_key) <> '');
exception when duplicate_object then null;
end $c$;

-- ONE active estimate per block + planting group + vintage.
create unique index if not exists season_yield_estimates_active_key
  on public.season_yield_estimates (vineyard_id, vintage, paddock_id, planting_group_key)
  where deleted_at is null;

create index if not exists season_yield_estimates_vineyard_vintage_idx
  on public.season_yield_estimates (vineyard_id, vintage)
  where deleted_at is null;

create index if not exists season_yield_estimates_paddock_idx
  on public.season_yield_estimates (paddock_id)
  where deleted_at is null;

create index if not exists season_yield_estimates_updated_at_idx
  on public.season_yield_estimates (updated_at);

create index if not exists season_yield_estimates_deleted_at_idx
  on public.season_yield_estimates (deleted_at);

comment on table public.season_yield_estimates is
  'Canonical BASE (undamaged) seasonal yield estimate, strictly scoped to one vintage. One active row per vineyard + vintage + block + planting group. Source priority manual > bunch_count > pruning_calculator. Damage is NEVER applied here — each client applies its own damage engine on top (SQL 221).';
comment on column public.season_yield_estimates.base_estimate_tonnes is
  'Unadjusted tonnes. NULL = not configured (see setup_warnings) — never write 0 to mean "unknown".';
comment on column public.season_yield_estimates.planting_group_key is
  'public.planting_group_key(variety_name, clone, rootstock) — the same identity the picking log uses (sql/184).';
comment on column public.season_yield_estimates.is_unallocated is
  'True for the residual "Unallocated variety" group: the share of the block not covered by paddocks.variety_allocations[].';

create or replace function public.season_yield_estimates_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  new.estimate_source := lower(btrim(coalesce(new.estimate_source, 'pruning_calculator')));
  new.variety_name    := btrim(coalesce(new.variety_name, ''));
  new.clone           := nullif(btrim(coalesce(new.clone, '')), '');
  new.rootstock       := nullif(btrim(coalesce(new.rootstock, '')), '');
  new.variety_key     := nullif(btrim(coalesce(new.variety_key, '')), '');

  -- Server-canonicalised identity: a client can never fork the group key.
  new.planting_group_key := public.planting_group_key(
    new.variety_name, new.clone, new.rootstock
  );

  if new.allocation_percent is null then
    new.allocation_percent := 100;
  end if;
  new.allocation_percent := least(100, greatest(0, new.allocation_percent));

  -- Missing inputs never become zero tonnes.
  if new.base_estimate_tonnes is null then
    new.is_estimate_available := false;
  end if;

  if new.calculated_at is null then
    new.calculated_at := now();
  end if;

  -- A genuine client upsert resurrects a soft-deleted row (sql/181 pattern).
  -- The soft-delete RPC does not touch client_updated_at, so it is unaffected.
  if tg_op = 'UPDATE' and new.client_updated_at is distinct from old.client_updated_at then
    new.deleted_at := null;
  end if;

  return new;
end;
$fn$;

create or replace trigger season_yield_estimates_before_write
before insert or update on public.season_yield_estimates
for each row execute function public.season_yield_estimates_before_write();

create or replace trigger season_yield_estimates_set_updated_at
before update on public.season_yield_estimates
for each row execute function public.set_updated_at();

-- RLS — identical shape to pruning_yield_settings (sql/181 §3).
alter table public.season_yield_estimates enable row level security;

drop policy if exists "season_yield_estimates_select_members" on public.season_yield_estimates;
create policy "season_yield_estimates_select_members"
on public.season_yield_estimates for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "season_yield_estimates_insert_members" on public.season_yield_estimates;
create policy "season_yield_estimates_insert_members"
on public.season_yield_estimates for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "season_yield_estimates_update_members" on public.season_yield_estimates;
create policy "season_yield_estimates_update_members"
on public.season_yield_estimates for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "season_yield_estimates_no_client_hard_delete" on public.season_yield_estimates;
create policy "season_yield_estimates_no_client_hard_delete"
on public.season_yield_estimates for delete
to authenticated
using (false);

grant select, insert, update on public.season_yield_estimates to authenticated;

create or replace function public.soft_delete_season_yield_estimate(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.season_yield_estimates where id = p_id;
  if v_vineyard_id is null then raise exception 'Season yield estimate not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete season yield estimate';
  end if;
  update public.season_yield_estimates
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$fn$;
revoke all on function public.soft_delete_season_yield_estimate(uuid) from public;
grant execute on function public.soft_delete_season_yield_estimate(uuid) to authenticated;


-- ===========================================================================
-- E. Pruning Yield Calculator — canonical per-block computation
--
--   buds_per_vine = spurs_per_vine × buds_per_spur   (spur)
--                 = canes_per_vine × buds_per_cane   (cane)
--
--   tonnes = vines × buds_per_vine × bunches_per_bud × bunch_weight_grams
--            ÷ 1,000,000
--
--   vines  = block vine_count_override, when set and > 0
--            otherwise block area (ha) × vines_per_ha
--
-- Any missing input yields is_available = false plus named warnings. Never 0.
-- ===========================================================================

create or replace function public._pruning_block_estimate(
  p_vineyard_id uuid,
  p_paddock_id  uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  b                record;
  s                record;
  v_has_settings   boolean := false;
  v_area           double precision;
  v_vines          double precision := null;
  v_vine_basis     text := null;
  v_buds_per_vine  double precision := null;
  v_method         text := 'spur';
  v_tonnes         double precision := null;
  v_available      boolean := true;
  v_warnings       text[] := '{}';
  v_keys           text[] := '{}';
  v_groups         jsonb[] := '{}';
  v_elem           jsonb;
  v_pct            double precision;
  v_total_pct      double precision := 0;
  v_name           text;
  v_clone          text;
  v_rootstock      text;
  v_vkey           text;
  v_alloc_id       text;
  v_ids            jsonb;
  v_gkey           text;
  v_idx            integer;
  v_unalloc_key    text;
begin
  select p.id, p.name, p.polygon_points, p.vine_count_override, p.variety_allocations
    into b
    from public.paddocks p
   where p.id = p_paddock_id
     and p.vineyard_id = p_vineyard_id
     and p.deleted_at is null;

  if not found then
    return null;
  end if;

  select *
    into s
    from public.pruning_yield_settings
   where vineyard_id = p_vineyard_id
     and paddock_id = p_paddock_id
     and deleted_at is null
   limit 1;
  v_has_settings := found;

  v_area := coalesce(public._paddock_polygon_area_hectares(b.polygon_points), 0);

  -- ---- inputs -------------------------------------------------------------
  if not v_has_settings then
    v_available := false;
    v_warnings := v_warnings || 'missing_pruning_settings';
  else
    v_method := lower(btrim(coalesce(s.prune_method, 'spur')));

    if v_method = 'cane' then
      if coalesce(s.canes_per_vine, 0) <= 0 then
        v_available := false;
        v_warnings := v_warnings || 'missing_canes_per_vine';
      end if;
      if coalesce(s.buds_per_cane, 0) <= 0 then
        v_available := false;
        v_warnings := v_warnings || 'missing_buds_per_cane';
      end if;
      if v_available then
        v_buds_per_vine := s.canes_per_vine * s.buds_per_cane;
      end if;
    else
      if coalesce(s.spurs_per_vine, 0) <= 0 then
        v_available := false;
        v_warnings := v_warnings || 'missing_spurs_per_vine';
      end if;
      if coalesce(s.buds_per_spur, 0) <= 0 then
        v_available := false;
        v_warnings := v_warnings || 'missing_buds_per_spur';
      end if;
      if v_available then
        v_buds_per_vine := s.spurs_per_vine * s.buds_per_spur;
      end if;
    end if;

    if coalesce(s.bunches_per_bud, 0) <= 0 then
      v_available := false;
      v_warnings := v_warnings || 'missing_bunches_per_bud';
    end if;

    if coalesce(s.bunch_weight_grams, 0) <= 0 then
      v_available := false;
      v_warnings := v_warnings || 'missing_bunch_weight_grams';
    end if;
  end if;

  -- ---- vine count ---------------------------------------------------------
  if coalesce(b.vine_count_override, 0) > 0 then
    v_vines := b.vine_count_override::double precision;
    v_vine_basis := 'block_vine_count_override';
  elsif v_has_settings and coalesce(s.vines_per_ha, 0) > 0 and v_area > 0 then
    v_vines := v_area * s.vines_per_ha;
    v_vine_basis := 'block_area_x_vines_per_ha';
  else
    v_available := false;
    if v_area <= 0 then
      v_warnings := v_warnings || 'missing_block_area';
    end if;
    if v_has_settings and coalesce(s.vines_per_ha, 0) <= 0 then
      v_warnings := v_warnings || 'missing_vines_per_ha';
    end if;
    v_warnings := v_warnings || 'missing_vine_count';
  end if;

  -- ---- block tonnes -------------------------------------------------------
  if v_available
     and v_vines is not null
     and v_buds_per_vine is not null then
    v_tonnes := v_vines
              * v_buds_per_vine
              * s.bunches_per_bud
              * s.bunch_weight_grams
              / 1000000.0;
  else
    v_available := false;
    v_tonnes := null;
  end if;

  -- ---- planting groups ----------------------------------------------------
  if jsonb_typeof(coalesce(b.variety_allocations, '[]'::jsonb)) = 'array' then
    for v_elem in
      select jsonb_array_elements(coalesce(b.variety_allocations, '[]'::jsonb))
    loop
      if jsonb_typeof(v_elem) <> 'object' then
        continue;
      end if;

      v_pct := coalesce(
        public._season_alloc_number(v_elem, array['percent', 'percentage']), 0
      );
      if v_pct <= 0 then
        continue;
      end if;
      if v_pct > 100 then
        v_pct := 100;
        v_warnings := v_warnings || 'allocation_percent_over_100';
      end if;

      v_vkey := public._season_alloc_text(
        v_elem, array['varietyKey', 'variety_key', 'key']
      );
      v_name := public._season_alloc_text(
        v_elem, array['name', 'varietyName', 'variety_name']
      );
      v_clone := public._season_alloc_text(v_elem, array['clone']);
      v_rootstock := public._season_alloc_text(
        v_elem, array['rootstock', 'root_stock']
      );
      v_alloc_id := public._season_alloc_text(v_elem, array['id']);

      -- Display-name fallback: vineyard list first, then the shared catalogue.
      if v_name is null and v_vkey is not null then
        select display_name into v_name
          from public.vineyard_grape_varieties
         where vineyard_id = p_vineyard_id
           and variety_key = v_vkey
           and is_active
         limit 1;

        if v_name is null then
          select display_name into v_name
            from public.grape_variety_catalog
           where key = v_vkey
           limit 1;
        end if;
      end if;

      if v_name is null then
        -- An allocation with no resolvable identity folds into the residual
        -- group rather than inventing a new label.
        v_name := 'Unallocated variety';
        v_clone := null;
        v_rootstock := null;
        v_vkey := null;
        v_warnings := v_warnings || 'allocation_missing_variety_identity';
      end if;

      v_gkey := public.planting_group_key(v_name, v_clone, v_rootstock);
      v_ids := case
                 when v_alloc_id is not null
                      and v_alloc_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                 then jsonb_build_array(v_alloc_id)
                 else '[]'::jsonb
               end;

      v_total_pct := v_total_pct + v_pct;
      v_idx := array_position(v_keys, v_gkey);

      if v_idx is null then
        v_keys := v_keys || v_gkey;
        v_groups := v_groups || jsonb_build_object(
          'planting_group_key', v_gkey,
          'variety_key', v_vkey,
          'variety_name', v_name,
          'clone', v_clone,
          'rootstock', v_rootstock,
          'variety_allocation_ids', v_ids,
          'allocation_percent', v_pct,
          'is_unallocated', (v_name = 'Unallocated variety')
        );
      else
        -- Two physical allocations of the same variety+clone+rootstock are ONE
        -- planting group (sql/184): merge the percentages, keep both ids.
        v_groups[v_idx] := v_groups[v_idx] || jsonb_build_object(
          'allocation_percent',
            (v_groups[v_idx] ->> 'allocation_percent')::double precision + v_pct,
          'variety_allocation_ids',
            (v_groups[v_idx] -> 'variety_allocation_ids') || v_ids
        );
      end if;
    end loop;
  end if;

  -- Residual share of the block: "Unallocated variety".
  if v_total_pct < 99.9999 then
    v_unalloc_key := public.planting_group_key('Unallocated variety', null, null);
    v_idx := array_position(v_keys, v_unalloc_key);

    if v_idx is null then
      v_keys := v_keys || v_unalloc_key;
      v_groups := v_groups || jsonb_build_object(
        'planting_group_key', v_unalloc_key,
        'variety_key', null,
        'variety_name', 'Unallocated variety',
        'clone', null,
        'rootstock', null,
        'variety_allocation_ids', '[]'::jsonb,
        'allocation_percent', 100 - v_total_pct,
        'is_unallocated', true
      );
    else
      v_groups[v_idx] := v_groups[v_idx] || jsonb_build_object(
        'allocation_percent',
          (v_groups[v_idx] ->> 'allocation_percent')::double precision
          + (100 - v_total_pct)
      );
    end if;

    if v_total_pct > 0 then
      v_warnings := v_warnings || 'block_allocations_under_100';
    else
      v_warnings := v_warnings || 'block_has_no_variety_allocations';
    end if;
  end if;

  return jsonb_build_object(
    'paddock_id', b.id,
    'paddock_name', b.name,
    'area_hectares', v_area,
    'is_available', v_available,
    'block_base_tonnes', v_tonnes,
    'warnings', coalesce(
      (select jsonb_agg(distinct w order by w) from unnest(v_warnings) as w),
      '[]'::jsonb
    ),
    'groups', coalesce(to_jsonb(v_groups), '[]'::jsonb),
    'inputs', jsonb_build_object(
      'has_pruning_settings', v_has_settings,
      'prune_method', case when v_has_settings then v_method else null end,
      'bunches_per_bud', case when v_has_settings then s.bunches_per_bud else null end,
      'buds_per_spur', case when v_has_settings then s.buds_per_spur else null end,
      'spurs_per_vine', case when v_has_settings then s.spurs_per_vine else null end,
      'buds_per_cane', case when v_has_settings then s.buds_per_cane else null end,
      'canes_per_vine', case when v_has_settings then s.canes_per_vine else null end,
      'vines_per_ha', case when v_has_settings then s.vines_per_ha else null end,
      'bunch_weight_grams', case when v_has_settings then s.bunch_weight_grams else null end,
      'buds_per_vine', v_buds_per_vine,
      'vine_count', v_vines,
      'vine_count_basis', v_vine_basis,
      'vine_count_override', b.vine_count_override,
      'area_hectares', v_area,
      'block_base_tonnes', v_tonnes,
      'formula', 'vines × buds_per_vine × bunches_per_bud × bunch_weight_grams ÷ 1000000'
    )
  );
end;
$fn$;

revoke all on function public._pruning_block_estimate(uuid, uuid) from public;
grant execute on function public._pruning_block_estimate(uuid, uuid) to authenticated;


-- ===========================================================================
-- F. refresh_pruning_yield_estimates
--
-- Safe + idempotent. NEVER downgrades: a group already carrying a
-- bunch_count or manual estimate is skipped and counted, not overwritten.
-- ===========================================================================

-- Internal worker: no auth checks, so the migration's own backfill (which
-- runs with auth.uid() = null) can reuse the exact same code path the RPC
-- uses. Not granted to any client role.
create or replace function public._refresh_pruning_yield_estimates(
  p_vineyard_id uuid,
  p_vintage     integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r                 record;
  v_block           jsonb;
  v_grp             jsonb;
  v_existing        record;
  v_group_keys      text[];
  v_ids             uuid[];
  v_tonnes          double precision;
  v_available       boolean;
  v_inserted        integer := 0;
  v_updated         integer := 0;
  v_skipped         integer := 0;
  v_soft_deleted    integer := 0;
  v_orphaned        integer := 0;
  v_blocks          integer := 0;
  v_unavailable     integer := 0;
  v_n               integer;
begin
  for r in
    select p.id, p.name
      from public.paddocks p
     where p.vineyard_id = p_vineyard_id
       and p.deleted_at is null
     order by p.name
  loop
    v_block := public._pruning_block_estimate(p_vineyard_id, r.id);
    if v_block is null then
      continue;
    end if;

    v_blocks := v_blocks + 1;
    v_available := coalesce((v_block ->> 'is_available')::boolean, false);
    if not v_available then
      v_unavailable := v_unavailable + 1;
    end if;

    v_group_keys := '{}';

    for v_grp in select jsonb_array_elements(v_block -> 'groups')
    loop
      v_group_keys := v_group_keys || (v_grp ->> 'planting_group_key');

      v_tonnes := case
                    when v_available and (v_block ->> 'block_base_tonnes') is not null
                    then (v_block ->> 'block_base_tonnes')::double precision
                         * (v_grp ->> 'allocation_percent')::double precision
                         / 100.0
                    else null
                  end;

      select array_agg(x::uuid)
        into v_ids
        from jsonb_array_elements_text(
               coalesce(v_grp -> 'variety_allocation_ids', '[]'::jsonb)
             ) as x;

      select *
        into v_existing
        from public.season_yield_estimates e
       where e.vineyard_id = p_vineyard_id
         and e.vintage = p_vintage
         and e.paddock_id = r.id
         and e.planting_group_key = (v_grp ->> 'planting_group_key')
         and e.deleted_at is null
       limit 1;

      if found then
        -- Priority guard: a pruning refresh may never demote a richer source.
        if public.season_yield_estimate_source_rank(v_existing.estimate_source)
           > public.season_yield_estimate_source_rank('pruning_calculator') then
          v_skipped := v_skipped + 1;
          continue;
        end if;

        update public.season_yield_estimates
           set variety_key            = nullif(v_grp ->> 'variety_key', ''),
               variety_name           = coalesce(v_grp ->> 'variety_name', ''),
               clone                  = nullif(v_grp ->> 'clone', ''),
               rootstock              = nullif(v_grp ->> 'rootstock', ''),
               variety_allocation_ids = v_ids,
               allocation_percent     = (v_grp ->> 'allocation_percent')::double precision,
               is_unallocated         = coalesce((v_grp ->> 'is_unallocated')::boolean, false),
               estimate_source        = 'pruning_calculator',
               base_estimate_tonnes   = v_tonnes,
               is_estimate_available  = (v_tonnes is not null),
               source_inputs          = v_block -> 'inputs',
               setup_warnings         = v_block -> 'warnings',
               calculated_at          = now(),
               source_session_id      = null,
               updated_by             = auth.uid()
         where id = v_existing.id;

        v_updated := v_updated + 1;
      else
        insert into public.season_yield_estimates (
          vineyard_id, vintage, paddock_id,
          planting_group_key, variety_key, variety_name, clone, rootstock,
          variety_allocation_ids, allocation_percent, is_unallocated,
          estimate_source, base_estimate_tonnes, is_estimate_available,
          source_inputs, setup_warnings, calculated_at, created_by, updated_by
        ) values (
          p_vineyard_id, p_vintage, r.id,
          v_grp ->> 'planting_group_key',
          nullif(v_grp ->> 'variety_key', ''),
          coalesce(v_grp ->> 'variety_name', ''),
          nullif(v_grp ->> 'clone', ''),
          nullif(v_grp ->> 'rootstock', ''),
          v_ids,
          (v_grp ->> 'allocation_percent')::double precision,
          coalesce((v_grp ->> 'is_unallocated')::boolean, false),
          'pruning_calculator',
          v_tonnes,
          (v_tonnes is not null),
          v_block -> 'inputs',
          v_block -> 'warnings',
          now(),
          auth.uid(),
          auth.uid()
        );

        v_inserted := v_inserted + 1;
      end if;
    end loop;

    -- Planting groups that no longer exist on this block: retire ONLY the
    -- pruning rows. A manual or bunch-count row is left for a human to remove.
    update public.season_yield_estimates e
       set deleted_at = now(),
           updated_by = auth.uid()
     where e.vineyard_id = p_vineyard_id
       and e.vintage = p_vintage
       and e.paddock_id = r.id
       and e.deleted_at is null
       and e.estimate_source = 'pruning_calculator'
       and not (e.planting_group_key = any(v_group_keys));

    get diagnostics v_n = row_count;
    v_soft_deleted := v_soft_deleted + v_n;
  end loop;

  -- Blocks removed from the vineyard entirely.
  update public.season_yield_estimates e
     set deleted_at = now(),
         updated_by = auth.uid()
   where e.vineyard_id = p_vineyard_id
     and e.vintage = p_vintage
     and e.deleted_at is null
     and e.estimate_source = 'pruning_calculator'
     and not exists (
       select 1
         from public.paddocks p
        where p.id = e.paddock_id
          and p.vineyard_id = p_vineyard_id
          and p.deleted_at is null
     );

  get diagnostics v_orphaned = row_count;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'vintage', p_vintage,
    'refreshed_at', now(),
    'blocks_processed', v_blocks,
    'blocks_unavailable', v_unavailable,
    'rows_inserted', v_inserted,
    'rows_updated', v_updated,
    'rows_skipped_higher_priority', v_skipped,
    'rows_soft_deleted_stale_group', v_soft_deleted,
    'rows_soft_deleted_removed_block', v_orphaned
  );
end;
$fn$;

revoke all on function public._refresh_pruning_yield_estimates(uuid, integer) from public, authenticated, anon;

create or replace function public.refresh_pruning_yield_estimates(
  p_vineyard_id uuid,
  p_vintage     integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not public.has_vineyard_role(
       p_vineyard_id, array['owner','manager','supervisor','operator']
     ) then
    raise exception 'Insufficient permissions to refresh yield estimates'
      using errcode = '42501';
  end if;
  if p_vintage is null or p_vintage < 2000 or p_vintage > 2100 then
    raise exception 'invalid_vintage' using errcode = '22023';
  end if;

  return public._refresh_pruning_yield_estimates(p_vineyard_id, p_vintage);
end;
$fn$;

revoke all on function public.refresh_pruning_yield_estimates(uuid, integer) from public;
grant execute on function public.refresh_pruning_yield_estimates(uuid, integer) to authenticated;


-- ===========================================================================
-- G. get_season_yield_base_overview
--
-- BASE figures only. Deliberately takes NO apply_damage argument: damage is
-- applied by each client's own engine, on top of these numbers, using the
-- damage records it loaded for the SAME vintage.
-- ===========================================================================

create or replace function public.get_season_yield_base_overview(
  p_vineyard_id uuid,
  p_vintage     integer
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'Vineyard membership required' using errcode = '42501';
  end if;
  if p_vintage is null or p_vintage < 2000 or p_vintage > 2100 then
    raise exception 'invalid_vintage' using errcode = '22023';
  end if;

  with est_rows as (
    select e.*,
           p.name as paddock_name,
           coalesce(public._paddock_polygon_area_hectares(p.polygon_points), 0)
             as area_hectares
      from public.season_yield_estimates e
      left join public.paddocks p
        on p.id = e.paddock_id
       and p.vineyard_id = e.vineyard_id
       and p.deleted_at is null
     where e.vineyard_id = p_vineyard_id
       and e.vintage = p_vintage
       and e.deleted_at is null
  ),
  block_warnings as (
    select r.paddock_id, w.code
      from est_rows r
      cross join lateral jsonb_array_elements_text(
        coalesce(r.setup_warnings, '[]'::jsonb)
      ) as w(code)
     group by r.paddock_id, w.code
  ),
  blocks as (
    select r.paddock_id,
           max(r.paddock_name) as paddock_name,
           max(r.area_hectares) as area_hectares,
           bool_and(r.is_estimate_available) as is_estimate_available,
           case when bool_and(r.is_estimate_available)
                then sum(r.base_estimate_tonnes) end as base_estimate_tonnes,
           (array_agg(
              r.estimate_source
              order by public.season_yield_estimate_source_rank(r.estimate_source) desc,
                       r.calculated_at desc
            ))[1] as estimate_source,
           max(r.calculated_at) as calculated_at,
           (array_agg(
              r.source_inputs
              order by public.season_yield_estimate_source_rank(r.estimate_source) desc,
                       r.calculated_at desc
            ))[1] as source_inputs,
           jsonb_agg(
             jsonb_build_object(
               'estimate_id', r.id,
               'planting_group_key', r.planting_group_key,
               'variety_key', r.variety_key,
               'variety_name', r.variety_name,
               'clone', r.clone,
               'rootstock', r.rootstock,
               'variety_allocation_ids', to_jsonb(coalesce(r.variety_allocation_ids, '{}'::uuid[])),
               'allocation_percent', r.allocation_percent,
               'is_unallocated', r.is_unallocated,
               'estimate_source', r.estimate_source,
               'base_estimate_tonnes', r.base_estimate_tonnes,
               'is_estimate_available', r.is_estimate_available,
               'calculated_at', r.calculated_at,
               'source_session_id', r.source_session_id,
               'setup_warnings', r.setup_warnings
             )
             order by r.allocation_percent desc, r.variety_name
           ) as groups
      from est_rows r
     group by r.paddock_id
  ),
  varieties as (
    select coalesce(nullif(r.variety_key, ''), r.planting_group_key) as variety_identity,
           (array_agg(r.variety_name order by r.base_estimate_tonnes desc nulls last))[1]
             as variety_name,
           (array_agg(r.variety_key order by r.base_estimate_tonnes desc nulls last))[1]
             as variety_key,
           bool_and(r.is_estimate_available) as is_estimate_available,
           bool_or(r.is_unallocated) as is_unallocated,
           case when bool_and(r.is_estimate_available)
                then sum(r.base_estimate_tonnes) end as base_estimate_tonnes,
           jsonb_agg(distinct r.paddock_id) as paddock_ids,
           jsonb_agg(distinct r.planting_group_key) as planting_group_keys
      from est_rows r
     group by coalesce(nullif(r.variety_key, ''), r.planting_group_key)
  ),
  totals as (
    select coalesce(sum(r.base_estimate_tonnes) filter (where r.is_estimate_available), 0)
             as total_base_estimate_tonnes,
           count(*) as rows_total,
           count(*) filter (where r.is_estimate_available) as rows_available,
           count(distinct r.paddock_id) as blocks_total,
           max(r.calculated_at) as calculated_at,
           (array_agg(
              r.estimate_source
              order by public.season_yield_estimate_source_rank(r.estimate_source) desc,
                       r.calculated_at desc
            ))[1] as estimate_source
      from est_rows r
  )
  select jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'vintage', p_vintage,
    'total_base_estimate_tonnes', t.total_base_estimate_tonnes,
    'estimate_source', coalesce(t.estimate_source, 'none'),
    'calculated_at', t.calculated_at,
    'varieties', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'variety_identity', v.variety_identity,
                 'variety_key', v.variety_key,
                 'variety_name', v.variety_name,
                 'is_unallocated', v.is_unallocated,
                 'is_estimate_available', v.is_estimate_available,
                 'base_estimate_tonnes', v.base_estimate_tonnes,
                 'paddock_ids', v.paddock_ids,
                 'planting_group_keys', v.planting_group_keys
               )
               order by v.base_estimate_tonnes desc nulls last, v.variety_name
             )
        from varieties v
    ), '[]'::jsonb),
    'blocks', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'paddock_id', b.paddock_id,
                 'block_name', b.paddock_name,
                 'area_hectares', b.area_hectares,
                 'estimate_source', b.estimate_source,
                 'is_estimate_available', b.is_estimate_available,
                 'base_estimate_tonnes', b.base_estimate_tonnes,
                 'calculated_at', b.calculated_at,
                 'source_inputs', b.source_inputs,
                 'setup_warnings', coalesce((
                   select jsonb_agg(bw.code order by bw.code)
                     from block_warnings bw
                    where bw.paddock_id = b.paddock_id
                 ), '[]'::jsonb),
                 'groups', b.groups
               )
               order by b.base_estimate_tonnes desc nulls last, b.paddock_name
             )
        from blocks b
    ), '[]'::jsonb),
    'source_inputs', jsonb_build_object(
      'summary', jsonb_build_object(
        'blocks_total', t.blocks_total,
        'rows_total', t.rows_total,
        'rows_available', t.rows_available,
        'rows_unavailable', t.rows_total - t.rows_available,
        'damage_applied', false,
        'note', 'Base (undamaged) figures only. Apply damage client-side using damage_records filtered to this vintage.'
      ),
      'blocks', coalesce((
        select jsonb_object_agg(b.paddock_id::text, b.source_inputs)
          from blocks b
         where b.source_inputs is not null
      ), '{}'::jsonb)
    ),
    'setup_warnings', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'code', bw.code,
                 'paddock_id', bw.paddock_id,
                 'block_name', (select b.paddock_name from blocks b where b.paddock_id = bw.paddock_id)
               )
               order by bw.code, bw.paddock_id
             )
        from block_warnings bw
    ), '[]'::jsonb)
  )
  into v_result
  from totals t;

  return coalesce(v_result, jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'vintage', p_vintage,
    'total_base_estimate_tonnes', 0,
    'estimate_source', 'none',
    'calculated_at', null,
    'varieties', '[]'::jsonb,
    'blocks', '[]'::jsonb,
    'source_inputs', jsonb_build_object(
      'summary', jsonb_build_object(
        'blocks_total', 0, 'rows_total', 0, 'rows_available', 0,
        'rows_unavailable', 0, 'damage_applied', false
      ),
      'blocks', '{}'::jsonb
    ),
    'setup_warnings', jsonb_build_array(
      jsonb_build_object('code', 'no_estimates_for_vintage', 'paddock_id', null, 'block_name', null)
    )
  ));
end;
$fn$;

revoke all on function public.get_season_yield_base_overview(uuid, integer) from public;
grant execute on function public.get_season_yield_base_overview(uuid, integer) to authenticated;


-- ===========================================================================
-- H. Pruning backfill — CURRENT vintage only
--
-- Only vineyards that already have saved Pruning Yield Calculator settings
-- are touched, and only for the vintage that today's date resolves to for
-- that vineyard. Historical vintages are never invented.
-- ===========================================================================

do $backfill_estimates$
declare
  v         record;
  v_vintage integer;
  v_res     jsonb;
  v_count   integer := 0;
begin
  for v in
    select distinct s.vineyard_id
      from public.pruning_yield_settings s
     where s.deleted_at is null
  loop
    v_vintage := public.resolve_vineyard_vintage_year(v.vineyard_id, current_date);
    v_res := public._refresh_pruning_yield_estimates(v.vineyard_id, v_vintage);
    v_count := v_count + 1;
    raise notice 'SQL 221 · pruning backfill vineyard % vintage % → %',
      v.vineyard_id, v_vintage, v_res;
  end loop;

  raise notice 'SQL 221 · pruning backfill complete: % vineyard(s), % estimate row(s) total',
    v_count, (select count(*) from public.season_yield_estimates where deleted_at is null);
end
$backfill_estimates$;

notify pgrst, 'reload schema';
