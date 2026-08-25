-- =============================================================================
-- 209: Atomic Portal tractor write + archive RPCs.
--
--   public.portal_upsert_tractor(...)   -- create or update a logical tractor
--   public.portal_archive_tractor(uuid) -- archive a logical tractor
--
-- ---------------------------------------------------------------------------
-- WHAT A "LOGICAL TRACTOR" IS
-- ---------------------------------------------------------------------------
-- Two physical rows that must never drift apart:
--
--   public.tractors            -- the descriptive identity: name, brand,
--                                 model, model_year, serial, VIN, and the
--                                 configured fuel rate. Drives legacy trip
--                                 costing via trips.tractor_id.
--   public.vineyard_machines   -- the operational mirror, with
--                                 machine_type = 'tractor' and
--                                 legacy_tractor_id = tractors.id. Drives the
--                                 Fuel Log, work-task machine lines and the
--                                 machine-based costing path.
--
-- A client performing these as two independent writes can fail between them,
-- and that is exactly how production reached the state sql/207 and sql/208 had
-- to repair by hand: a machine with no tractor. These functions do both sides
-- in one server-side transaction (a function body is atomic), so a caller can
-- never observe or persist half a tractor.
--
-- ---------------------------------------------------------------------------
-- SCHEMA AUDIT THAT SHAPED THIS FILE
-- ---------------------------------------------------------------------------
-- public.vineyard_machines does NOT have brand, model or model_year. Its only
-- descriptive columns are `name`, `notes`, `serial_number` and `vin_number`
-- (sql/097 + sql/105). Brand/model/model_year live ONLY on public.tractors.
--
-- So the mirror is written with the fields it genuinely owns — name, the fuel
-- rate, serial and VIN — and no columns are added to vineyard_machines to
-- duplicate the tractor's descriptive identity. `notes` is deliberately NOT
-- part of this contract: it is a machine-only field, and including it in a
-- full-row write is precisely how a partial update silently erases a value the
-- caller never intended to touch. Existing machine notes are preserved.
--
-- ---------------------------------------------------------------------------
-- WHY SECURITY DEFINER, AND WHAT REPLACES RLS
-- ---------------------------------------------------------------------------
-- Definer rights are required for CORRECTNESS, not convenience: to refuse a
-- cross-vineyard mirror the function must be able to SEE a mirror in a
-- vineyard the caller is not a member of. Under caller rights RLS hides that
-- row, the lookup returns nothing, and the function would "helpfully" create a
-- second mirror — the sql/197 blindness defect, reintroduced.
--
-- Definer rights are therefore paired with explicit, mandatory checks, so
-- nothing is granted that RLS would have refused:
--   * auth.uid() must be present (no anonymous writes);
--   * public.has_vineyard_role(vineyard_id, array['owner','manager']) — the
--     same shared helper the tractors / vineyard_machines RLS policies use,
--     not a new near-miss membership rule;
--   * the target row's OWN vineyard is re-authorised, so passing another
--     vineyard's tractor id cannot move it;
--   * EXECUTE is granted to `authenticated` only.
--
-- ---------------------------------------------------------------------------
-- SYNC COMPATIBILITY (audited against the iOS management-sync contract)
-- ---------------------------------------------------------------------------
--   * Incremental pull filters on `updated_at`. Both tables carry the
--     `set_updated_at` BEFORE UPDATE trigger, and `updated_at` defaults to
--     now() on INSERT, so every row these functions touch is picked up by the
--     next iOS delta. No Portal-specific mechanism is introduced.
--   * `client_updated_at` is what iOS compares for last-writer-wins
--     (`item.clientUpdatedAt ?? item.updatedAt` in ManagementSyncServices), so
--     it is always set — to the caller's supplied timestamp when given, else
--     now(). A Portal edit therefore correctly beats an older device edit.
--   * `sync_version` is bumped on update, matching
--     soft_delete_vineyard_machine. iOS neither reads nor writes this column,
--     so the bump cannot affect it.
--   * Rows are only ever soft-deleted, so iOS replays the delete through the
--     existing tombstone path instead of an absence-based removal.
--
-- Depends on: sql/001 (has_vineyard_role), sql/011 (tractors,
--             soft_delete_tractor), sql/097 (vineyard_machines,
--             soft_delete_vineyard_machine), sql/105 (serial/vin),
--             sql/206 (vineyard guards).
-- =============================================================================

begin;

do $$
begin
  if to_regprocedure('public.has_vineyard_role(uuid, text[])') is null then
    raise exception 'sql/001 not applied — public.has_vineyard_role is missing.';
  end if;
  if to_regprocedure('public.soft_delete_tractor(uuid)') is null then
    raise exception 'sql/011 not applied — public.soft_delete_tractor is missing.';
  end if;
  if to_regprocedure('public.soft_delete_vineyard_machine(uuid)') is null then
    raise exception 'sql/097 not applied — public.soft_delete_vineyard_machine is missing.';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- portal_upsert_tractor
--
-- Create (p_tractor_id null, or an id that does not exist yet) or update
-- (p_tractor_id of an existing ACTIVE tractor in p_vineyard_id).
--
-- Returns one row carrying both ids and the resulting state, so the Portal
-- does not need a follow-up SELECT to refresh its cache.
-- ---------------------------------------------------------------------------
create or replace function public.portal_upsert_tractor(
  p_vineyard_id uuid,
  p_name text default null,
  p_brand text default '',
  p_model text default '',
  p_model_year integer default null,
  p_fuel_usage_l_per_hour double precision default 0,
  p_serial_number text default null,
  p_vin_number text default null,
  p_tractor_id uuid default null,
  p_client_updated_at timestamptz default null
)
returns table (
  tractor_id uuid,
  machine_id uuid,
  vineyard_id uuid,
  name text,
  brand text,
  model text,
  model_year integer,
  fuel_usage_l_per_hour double precision,
  serial_number text,
  vin_number text,
  machine_type text,
  fuel_tracking_enabled boolean,
  available_for_job_costing boolean,
  updated_at timestamptz,
  was_created boolean,
  mirror_was_created boolean
)
language plpgsql
volatile
security definer
set search_path = public
as $function$
declare
  v_uid        uuid := auth.uid();
  v_now        timestamptz := now();
  v_client_ts  timestamptz := coalesce(p_client_updated_at, now());
  v_brand      text := btrim(coalesce(p_brand, ''));
  v_model      text := btrim(coalesce(p_model, ''));
  v_name       text := nullif(btrim(coalesce(p_name, '')), '');
  v_serial     text := nullif(btrim(coalesce(p_serial_number, '')), '');
  v_vin        text := nullif(btrim(coalesce(p_vin_number, '')), '');
  -- fuel_usage_l_per_hour is NOT NULL on both tables and 0 is the schema's
  -- "not set" convention. A null argument therefore becomes 0 — never a
  -- fabricated rate, and never an attempted NULL insert.
  v_rate       double precision := coalesce(p_fuel_usage_l_per_hour, 0);
  v_tractor    public.tractors%rowtype;
  v_machine    public.vineyard_machines%rowtype;
  v_created    boolean := false;
  v_mirror_new boolean := false;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_vineyard_id is null then
    raise exception 'A vineyard is required' using errcode = '22004';
  end if;

  if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to manage tractors for this vineyard'
      using errcode = '42501';
  end if;

  if v_rate < 0 then
    raise exception 'Fuel usage cannot be negative' using errcode = '23514';
  end if;

  -- Fall back to "Brand Model" so the Portal is not forced to duplicate the
  -- app's display-name rule. One of the two must produce something.
  if v_name is null then
    v_name := nullif(btrim(v_brand || ' ' || v_model), '');
  end if;
  if v_name is null then
    raise exception 'A tractor name, or a brand and model, is required'
      using errcode = '22004';
  end if;

  if p_tractor_id is not null then
    select * into v_tractor from public.tractors t where t.id = p_tractor_id;
  end if;

  -- ---- the tractor row ----------------------------------------------------
  if v_tractor.id is null then
    insert into public.tractors (
      id, vineyard_id, name, brand, model, model_year,
      fuel_usage_l_per_hour, serial_number, vin_number,
      created_by, updated_by, client_updated_at
    )
    values (
      coalesce(p_tractor_id, gen_random_uuid()), p_vineyard_id, v_name, v_brand, v_model,
      p_model_year, v_rate, v_serial, v_vin,
      v_uid, v_uid, v_client_ts
    )
    returning * into v_tractor;
    v_created := true;
  else
    -- Re-authorise against the row's OWN vineyard, then refuse to move it.
    -- Passing another vineyard's tractor id must never re-home the asset.
    if v_tractor.vineyard_id is distinct from p_vineyard_id then
      raise exception
        'Tractor % belongs to a different vineyard and cannot be updated from this one',
        v_tractor.id
        using errcode = '23514';
    end if;
    if v_tractor.deleted_at is not null then
      raise exception 'Tractor % is archived and cannot be updated', v_tractor.id
        using errcode = '23514';
    end if;

    update public.tractors t
       set name                  = v_name,
           brand                 = v_brand,
           model                 = v_model,
           model_year            = p_model_year,
           fuel_usage_l_per_hour = v_rate,
           serial_number         = v_serial,
           vin_number            = v_vin,
           updated_by            = v_uid,
           client_updated_at     = v_client_ts,
           sync_version          = t.sync_version + 1
     where t.id = v_tractor.id
    returning * into v_tractor;
  end if;

  -- ---- the machine mirror -------------------------------------------------
  -- At most one ACTIVE mirror can exist per tractor
  -- (uq_vineyard_machines_legacy_tractor, sql/097). An ARCHIVED mirror is
  -- deliberately ignored rather than resurrected: archiving was a decision,
  -- and the partial unique index permits a fresh mirror alongside it.
  select * into v_machine
    from public.vineyard_machines m
   where m.legacy_tractor_id = v_tractor.id
     and m.deleted_at is null
   order by m.created_at
   limit 1;

  if v_machine.id is null then
    -- Self-repair, scoped to the tractor being written. An active tractor
    -- with no mirror is the sql/207 defect inverted: it would be invisible to
    -- the Fuel Log and to machine-based costing. This function is the one
    -- place that knows the correct mirror shape, so it creates the missing
    -- one rather than leaving a half tractor behind. It repairs only THIS
    -- tractor — no global backfill is performed here.
    insert into public.vineyard_machines (
      vineyard_id, name, machine_type,
      fuel_tracking_enabled, available_for_job_costing,
      fuel_usage_l_per_hour, serial_number, vin_number, legacy_tractor_id,
      created_by, updated_by, client_updated_at
    )
    values (
      v_tractor.vineyard_id, v_name, 'tractor',
      -- Operational defaults for a tractor mirror, matching the sql/097
      -- backfill: a tractor was always usable for trip costing, so its
      -- mirror is job-costing eligible.
      true, true,
      v_rate, v_serial, v_vin, v_tractor.id,
      v_uid, v_uid, v_client_ts
    )
    returning * into v_machine;
    v_mirror_new := true;
  else
    if v_machine.vineyard_id is distinct from v_tractor.vineyard_id then
      -- Do not adopt. Re-homing a machine would move its fuel history into
      -- another vineyard; sql/206 would refuse the write anyway, but failing
      -- here gives a readable error instead of a raw trigger message.
      raise exception
        'Machine % is linked to this tractor but belongs to a different vineyard',
        v_machine.id
        using errcode = '23514';
    end if;

    update public.vineyard_machines m
       set name                  = v_name,
           machine_type          = 'tractor',
           fuel_usage_l_per_hour = v_rate,
           serial_number         = v_serial,
           vin_number            = v_vin,
           -- fuel_tracking_enabled and available_for_job_costing are
           -- deliberately NOT rewritten on update. They are operational
           -- switches the grower owns; forcing them true on every edit is a
           -- full-row-replace defect that would silently re-enable fuel
           -- tracking someone had turned off. `notes` is left alone for the
           -- same reason.
           updated_by            = v_uid,
           client_updated_at     = v_client_ts,
           sync_version          = m.sync_version + 1
     where m.id = v_machine.id
    returning * into v_machine;
  end if;

  -- ---- postconditions, before the caller sees anything --------------------
  if v_machine.legacy_tractor_id is distinct from v_tractor.id
     or v_machine.machine_type is distinct from 'tractor'
     or v_machine.vineyard_id is distinct from v_tractor.vineyard_id then
    raise exception 'Tractor % and its machine mirror did not end up linked', v_tractor.id
      using errcode = '23514';
  end if;

  return query
  select
    v_tractor.id,
    v_machine.id,
    v_tractor.vineyard_id,
    v_tractor.name,
    v_tractor.brand,
    v_tractor.model,
    v_tractor.model_year,
    v_tractor.fuel_usage_l_per_hour,
    v_tractor.serial_number,
    v_tractor.vin_number,
    v_machine.machine_type,
    v_machine.fuel_tracking_enabled,
    v_machine.available_for_job_costing,
    greatest(v_tractor.updated_at, v_machine.updated_at),
    v_created,
    v_mirror_new;
end;
$function$;

comment on function public.portal_upsert_tractor(uuid, text, text, text, integer, double precision, text, text, uuid, timestamptz) is
  'Creates or updates a logical tractor (public.tractors + its linked vineyard_machines mirror) in ONE transaction (sql/209). Owner/manager only, via has_vineyard_role. Cross-vineyard updates and cross-vineyard mirrors are refused. Creates the mirror with machine_type=tractor, fuel_tracking_enabled=true, available_for_job_costing=true; on UPDATE those two switches and machine notes are preserved, not rewritten. A null fuel rate becomes 0, the schema convention for "not set" — no rate is ever invented.';

revoke all on function public.portal_upsert_tractor(uuid, text, text, text, integer, double precision, text, text, uuid, timestamptz) from public;
grant execute on function public.portal_upsert_tractor(uuid, text, text, text, integer, double precision, text, text, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- portal_archive_tractor
--
-- Soft-deletes the tractor and its active mirror together. Historical rows
-- (trips, fuel logs, spray records, maintenance logs) are NOT touched: they
-- keep their tractor_id / machine_id and keep resolving against the archived
-- rows, which is what the historical-resolution contract requires.
-- ---------------------------------------------------------------------------
create or replace function public.portal_archive_tractor(p_tractor_id uuid)
returns table (
  tractor_id uuid,
  machine_id uuid,
  archived_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $function$
declare
  v_uid       uuid := auth.uid();
  v_tractor   public.tractors%rowtype;
  v_machine_id uuid;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select * into v_tractor from public.tractors t where t.id = p_tractor_id;
  if not found then
    raise exception 'Tractor not found' using errcode = 'P0002';
  end if;

  if not public.has_vineyard_role(v_tractor.vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to archive tractors for this vineyard'
      using errcode = '42501';
  end if;

  select m.id into v_machine_id
    from public.vineyard_machines m
   where m.legacy_tractor_id = p_tractor_id
     and m.deleted_at is null
     and m.vineyard_id = v_tractor.vineyard_id
   order by m.created_at
   limit 1;

  -- Delegate to the existing soft-delete functions rather than writing
  -- deleted_at directly. They already encode this project's soft-delete
  -- semantics (including their own authorisation), so there is exactly one
  -- definition of what archiving means, and no hard delete is possible.
  if v_tractor.deleted_at is null then
    perform public.soft_delete_tractor(p_tractor_id);
  end if;

  if v_machine_id is not null then
    perform public.soft_delete_vineyard_machine(v_machine_id);
  end if;

  return query
  select
    p_tractor_id,
    v_machine_id,
    (select t.deleted_at from public.tractors t where t.id = p_tractor_id);
end;
$function$;

comment on function public.portal_archive_tractor(uuid) is
  'Soft-deletes a logical tractor: the public.tractors row and its active vineyard_machines mirror, in one transaction (sql/209). Owner/manager only. Delegates to soft_delete_tractor / soft_delete_vineyard_machine so archive semantics have a single definition. Never hard deletes, and never modifies trips, fuel logs, spray records or any other historical reference — those keep resolving against the archived rows.';

revoke all on function public.portal_archive_tractor(uuid) from public;
grant execute on function public.portal_archive_tractor(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Prove the postcondition inside the same transaction that created it.
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  select string_agg(x, ', ')
    into v_missing
    from (
      select 'portal_upsert_tractor' as x
       where to_regprocedure(
         'public.portal_upsert_tractor(uuid, text, text, text, integer, double precision, text, text, uuid, timestamptz)'
       ) is null
      union all
      select 'portal_archive_tractor'
       where to_regprocedure('public.portal_archive_tractor(uuid)') is null
    ) s;

  if v_missing is not null then
    raise exception 'SQL 209 FAILED: missing objects: %', v_missing;
  end if;

  raise notice 'SQL 209: portal tractor upsert + archive RPCs installed. No data was migrated.';
end$$;

commit;

-- =============================================================================
-- PORTAL CALL CONTRACT (for Lovable)
--
--   -- create
--   select * from public.portal_upsert_tractor(
--     p_vineyard_id           => '…'::uuid,
--     p_name                  => 'Kubota M092-N',   -- optional if brand+model
--     p_brand                 => 'Kubota',
--     p_model                 => 'M092-N',
--     p_model_year            => null,              -- optional
--     p_fuel_usage_l_per_hour => 7.5,               -- 0 = not set
--     p_serial_number         => null,
--     p_vin_number            => null
--   );
--
--   -- update: same call, plus the existing tractor id
--   select * from public.portal_upsert_tractor(
--     p_vineyard_id => '…'::uuid,
--     p_tractor_id  => '…'::uuid,
--     …
--   );
--
--   -- archive
--   select * from public.portal_archive_tractor('…'::uuid);
--
-- Returns one row. `tractor_id` and `machine_id` identify the two physical
-- rows; `was_created` / `mirror_was_created` say what happened.
--
-- Errors are raised, so PostgREST returns a non-2xx and the Portal fails
-- closed:
--   28000 not signed in
--   42501 not an owner/manager of that vineyard
--   22004 missing vineyard, or no name/brand+model
--   23514 cross-vineyard tractor or mirror, negative rate, archived tractor
--   P0002 tractor not found (archive)
--
-- NOT part of this contract, by design:
--   * machine `notes` — a machine-only field, preserved untouched;
--   * fuel_tracking_enabled / available_for_job_costing on UPDATE — set true
--     at creation, then owned by the grower;
--   * brand / model / model_year on the mirror — those columns do not exist
--     on vineyard_machines and are not being added.
--
-- ROLLBACK:
--   begin;
--     drop function if exists public.portal_upsert_tractor(uuid, text, text, text, integer, double precision, text, text, uuid, timestamptz);
--     drop function if exists public.portal_archive_tractor(uuid);
--   commit;
-- END 209
-- =============================================================================
