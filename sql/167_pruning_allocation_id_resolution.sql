-- =====================================================================
-- 167_pruning_allocation_id_resolution.sql
-- Corrective migration for SQL 166 (pruning activities + allocations)
-- =====================================================================
-- PROBLEM
--
-- `apply_pruning_activity_allocation` resolved the allocation id as:
--
--     supplied id  ->  derive_pruning_allocation_id(activity, block)
--
-- The derived id is only correct for allocations that the activity RPCs
-- created themselves. Two very common cases do NOT own a derived id:
--
--   * a MIGRATED LEGACY entry — SQL 166 projects it as an activity keyed by
--     the entry's own id, so the allocation id is the ORIGINAL entry id, not
--     `derive(activity, block)`;
--   * any allocation written before/outside the activity RPCs (portal,
--     `record_pruning_entry`, an imported historic row).
--
-- So an `update_pruning_activity` payload that OMITTED the allocation id
-- derived a *second* id for the same (activity, block) pair. That either
-- tripped `pruning_entries_activity_block_unique` and rolled the whole save
-- back, or — for a client that then re-sent the derived id — left the real
-- allocation outside `v_kept`, releasing its quarters and soft-deleting it.
-- Either way the user's edit failed or silently lost the block.
--
-- FIX
--
-- Resolution order, now explicit and shared:
--
--   1. a VALID supplied allocation id
--        — it must already be THIS activity's allocation for THIS block, or
--          be an id that is not in use anywhere while the block has no
--          allocation yet;
--   2. the EXISTING live allocation for (activity, block)
--        — this is the case that was missing;
--   2b. the allocation previously REMOVED from (activity, block)
--        — re-adding a block revives its own row instead of forking a new one;
--   3. the deterministic derived id, for a genuinely new block.
--
-- A supplied id belonging to ANOTHER activity — or to another block of this
-- activity — is REJECTED: it is never reassigned, the owning row is never
-- touched, and the allocation resolves canonically instead. The rejection is
-- reported back in the allocation result (and therefore in the audit detail
-- and the canonical response the apps adopt), so a bad client id is visible
-- rather than silent, without wedging an offline queue.
--
-- Nothing else changes: no schema change, no data change, same signature,
-- same return shape plus three additive diagnostic fields.
--
-- Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------------
-- 0. Guard — refuse to install on a database without SQL 166
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.pruning_activities') is null
     or to_regprocedure('public.apply_pruning_activity_allocation(uuid, uuid, date, text, text, text, integer, timestamptz, jsonb, integer)') is null
     or to_regprocedure('public.derive_pruning_allocation_id(uuid, uuid)') is null then
    raise exception 'SQL 167 needs SQL 166 — run sql/166_pruning_activities.sql first.';
  end if;
end$$;

-- The invariant this migration protects. Declared again defensively: one live
-- allocation per (activity, block), for ever.
create unique index if not exists pruning_entries_activity_block_unique
  on public.pruning_entries (pruning_activity_id, paddock_id)
  where pruning_activity_id is not null and deleted_at is null;

-- ---------------------------------------------------------------------------
-- 1. resolve_pruning_allocation_id — THE single resolution rule
--
--    Returns:
--      { "allocation_id": uuid,
--        "source": "supplied" | "existing" | "revived" | "derived",
--        "supplied_allocation_id": uuid | null,
--        "rejected_allocation_id": uuid | null,
--        "rejected_reason": text | null }
--
--    Read-only and side-effect free, so it is safe to call from a report, a
--    diagnostic query or a test as well as from the write path.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_pruning_allocation_id(
  p_activity_id uuid,
  p_paddock_id uuid,
  p_supplied uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_live      uuid;
  v_dead      uuid;
  v_exists    boolean := false;
  v_owner_act uuid;
  v_owner_pad uuid;
  v_rejected  uuid;
  v_reason    text;
begin
  if p_activity_id is null then
    raise exception 'resolve_pruning_allocation_id: activity id is required';
  end if;
  if p_paddock_id is null then
    raise exception 'resolve_pruning_allocation_id: block id is required';
  end if;

  -- (2) the live allocation this activity already holds for this block
  select e.id into v_live
  from public.pruning_entries e
  where e.pruning_activity_id = p_activity_id
    and e.paddock_id = p_paddock_id
    and e.deleted_at is null
  order by e.allocation_index, e.created_at, e.id
  limit 1;

  -- (2b) …or the one it removed earlier, so a re-add revives it in place
  if v_live is null then
    select e.id into v_dead
    from public.pruning_entries e
    where e.pruning_activity_id = p_activity_id
      and e.paddock_id = p_paddock_id
      and e.deleted_at is not null
    order by e.deleted_at desc, e.allocation_index, e.id
    limit 1;
  end if;

  -- (1) a supplied id, validated against the activity AND the block
  if p_supplied is not null then
    select e.pruning_activity_id, e.paddock_id
      into v_owner_act, v_owner_pad
    from public.pruning_entries e
    where e.id = p_supplied;
    v_exists := found;

    if v_exists and v_owner_act is distinct from p_activity_id then
      -- Never reassign another activity's allocation.
      v_rejected := p_supplied;
      v_reason := 'belongs_to_another_activity';
    elsif v_exists and v_owner_pad is distinct from p_paddock_id then
      -- Never move an allocation between blocks; that would drag its quarters.
      v_rejected := p_supplied;
      v_reason := 'belongs_to_another_block';
    elsif v_live is not null and v_live <> p_supplied then
      -- The block already has a live allocation; a second one is impossible.
      v_rejected := p_supplied;
      v_reason := 'block_already_has_allocation';
    elsif not v_exists and v_dead is not null then
      -- Prefer reviving the block's own removed row over forking a new id.
      v_rejected := p_supplied;
      v_reason := 'block_allocation_revived';
    else
      return jsonb_build_object(
        'allocation_id', p_supplied,
        'source', 'supplied',
        'supplied_allocation_id', p_supplied,
        'rejected_allocation_id', null,
        'rejected_reason', null
      );
    end if;
  end if;

  if v_live is not null then
    return jsonb_build_object(
      'allocation_id', v_live,
      'source', 'existing',
      'supplied_allocation_id', p_supplied,
      'rejected_allocation_id', v_rejected,
      'rejected_reason', v_reason
    );
  end if;

  if v_dead is not null then
    return jsonb_build_object(
      'allocation_id', v_dead,
      'source', 'revived',
      'supplied_allocation_id', p_supplied,
      'rejected_allocation_id', v_rejected,
      'rejected_reason', v_reason
    );
  end if;

  -- (3) a genuinely new block for this activity
  return jsonb_build_object(
    'allocation_id', public.derive_pruning_allocation_id(p_activity_id, p_paddock_id),
    'source', 'derived',
    'supplied_allocation_id', p_supplied,
    'rejected_allocation_id', v_rejected,
    'rejected_reason', v_reason
  );
end;
$$;

comment on function public.resolve_pruning_allocation_id(uuid, uuid, uuid) is
  'SQL 167: canonical allocation-id resolution for a (pruning activity, block) pair — valid supplied id, else the existing live allocation, else the allocation removed earlier from the same pair, else the deterministic derived id. An id owned by another activity or another block is rejected and reported, never reassigned.';

revoke all on function public.resolve_pruning_allocation_id(uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_pruning_allocation_id(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. apply_pruning_activity_allocation — same signature, robust resolution
--    (body identical to SQL 166 §8 except the id block and the three extra
--    diagnostic fields in the result)
-- ---------------------------------------------------------------------------
create or replace function public.apply_pruning_activity_allocation(
  p_activity_id uuid,
  p_vineyard_id uuid,
  p_entry_date date,
  p_worker text,
  p_method text,
  p_notes text,
  p_vintage_year integer,
  p_client_updated_at timestamptz,
  p_allocation jsonb,
  p_allocation_index integer
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_paddock uuid;
  v_supplied uuid;
  v_resolution jsonb;
  v_alloc uuid;
  v_season uuid;
  v_prev_season uuid;
  v_segs jsonb := '[]'::jsonb;
  v_raw integer := 0;
  v_requested integer := 0;
  v_attributed integer := 0;
  v_removed integer := 0;
  v_conflicts jsonb := '[]'::jsonb;
  v_keys text[] := '{}';
  v_seg jsonb;
  v_row_id uuid;
  v_row_num integer;
  v_seg_num integer;
  v_label text;
  v_owner uuid;
  v_vines integer;
begin
  begin
    v_paddock := nullif(p_allocation->>'paddock_id', '')::uuid;
  exception when others then
    v_paddock := null;
  end;
  if v_paddock is null then
    raise exception 'pruning allocation is missing paddock_id';
  end if;

  -- An invalid or foreign block aborts the whole activity (atomicity rule).
  if not exists (
    select 1 from public.paddocks
    where id = v_paddock and vineyard_id = p_vineyard_id and deleted_at is null
  ) then
    raise exception 'pruning allocation block % does not belong to this vineyard', v_paddock;
  end if;

  -- ---- allocation identity (SQL 167) --------------------------------------
  -- A malformed id is treated as "not supplied": an old build must never wedge
  -- its offline queue on a typo.
  begin
    v_supplied := coalesce(
      nullif(p_allocation->>'id', '')::uuid,
      nullif(p_allocation->>'allocation_id', '')::uuid
    );
  exception when others then
    v_supplied := null;
  end;

  v_resolution := public.resolve_pruning_allocation_id(p_activity_id, v_paddock, v_supplied);
  v_alloc := (v_resolution->>'allocation_id')::uuid;

  -- CANONICAL season per allocation, from the ACTIVITY date (SQL 161).
  v_season := public.resolve_pruning_season(
    p_vineyard_id, v_paddock, p_entry_date, null, p_client_updated_at
  );

  -- ---- canonicalise the requested quarter set -----------------------------
  select count(*) into v_raw
  from jsonb_array_elements(
    case when jsonb_typeof(p_allocation->'segments') = 'array'
      then p_allocation->'segments' else '[]'::jsonb end
  );

  with raw as (
    select coalesce(nullif(e->>'row', '')::integer, 0) as row_num,
           coalesce(nullif(e->>'segment', '')::integer, 0) as seg_num,
           lower(nullif(e->>'row_id', '')) as row_id,
           nullif(e->>'label', '') as label
    from jsonb_array_elements(
      case when jsonb_typeof(p_allocation->'segments') = 'array'
        then p_allocation->'segments' else '[]'::jsonb end
    ) e
  ),
  keyed as (
    select *, coalesce(row_id, 'n' || row_num::text) as k
    from raw where seg_num between 1 and 4
  ),
  uniq as (
    select distinct on (k, seg_num) * from keyed order by k, seg_num, label nulls last
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'row', row_num, 'segment', seg_num, 'row_id', row_id, 'label', label
         ) order by row_num, seg_num), '[]'::jsonb)
  into v_segs from uniq;

  -- Convenience form: whole rows (all four quarters each).
  if v_segs = '[]'::jsonb and jsonb_typeof(p_allocation->'rows') = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object('row', r, 'segment', q)
             order by r, q), '[]'::jsonb)
    into v_segs
    from (select distinct nullif(e, '')::integer as r
          from jsonb_array_elements_text(p_allocation->'rows') e) rr,
         generate_series(1, 4) q
    where rr.r is not null;
    v_raw := jsonb_array_length(v_segs);
  end if;

  v_requested := coalesce(jsonb_array_length(v_segs), 0);
  v_vines := coalesce(nullif(p_allocation->>'estimated_vines', '')::integer, 0);

  -- ---- the allocation row -------------------------------------------------
  select pruning_season_id into v_prev_season
  from public.pruning_entries where id = v_alloc;

  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    pruning_method, notes, vintage_year, created_by, client_updated_at,
    pruning_activity_id, allocation_index
  ) values (
    v_alloc, p_vineyard_id, v_season, v_paddock, p_entry_date, coalesce(p_worker, ''),
    coalesce(p_method, 'spur'), coalesce(p_notes, ''), p_vintage_year, auth.uid(),
    p_client_updated_at, p_activity_id, p_allocation_index
  )
  on conflict (id) do update
  set pruning_season_id = excluded.pruning_season_id,
      paddock_id = excluded.paddock_id,
      entry_date = excluded.entry_date,
      worker_or_crew = excluded.worker_or_crew,
      pruning_method = excluded.pruning_method,
      notes = excluded.notes,
      vintage_year = excluded.vintage_year,
      client_updated_at = excluded.client_updated_at,
      pruning_activity_id = excluded.pruning_activity_id,
      allocation_index = excluded.allocation_index,
      -- Re-adding a previously removed block revives its allocation in place.
      deleted_at = null,
      updated_by = auth.uid(),
      updated_at = now();

  -- A date edit that crossed a pruning year moves this allocation's quarters
  -- with it; a quarter the target season already holds is released, never
  -- stolen (identical rule to SQL 161 §4).
  if v_prev_season is not null and v_prev_season is distinct from v_season then
    update public.pruning_row_segments s
    set completed = false, completed_at = null, completed_by = null,
        pruning_entry_id = null, updated_at = now()
    where s.pruning_entry_id = v_alloc
      and exists (
        select 1 from public.pruning_row_segments x
        where x.pruning_season_id = v_season
          and x.segment_number = s.segment_number
          and (
            (s.paddock_row_id is not null and x.paddock_row_id = s.paddock_row_id)
            or (s.paddock_row_id is null and x.paddock_row_id is null and x.row_number = s.row_number)
          )
      );

    update public.pruning_row_segments s
    set pruning_season_id = v_season, updated_at = now()
    where s.pruning_entry_id = v_alloc;
  end if;

  -- ---- pass 1: claim every quarter in the new set -------------------------
  for v_seg in select * from jsonb_array_elements(v_segs)
  loop
    v_row_num := coalesce(nullif(v_seg->>'row', '')::integer, 0);
    v_seg_num := coalesce(nullif(v_seg->>'segment', '')::integer, 0);
    v_label := coalesce(nullif(v_seg->>'label', ''), v_row_num::text);
    begin
      v_row_id := nullif(v_seg->>'row_id', '')::uuid;
    exception when others then
      v_row_id := null;
    end;

    if v_row_id is null then
      select (elem->>'id')::uuid into v_row_id
      from public.paddocks p
      cross join lateral jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
      where p.id = v_paddock
        and jsonb_typeof(elem->'number') = 'number'
        and (elem->>'number')::integer = v_row_num
        and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      limit 1;
    end if;

    if v_row_id is not null then
      v_keys := array_append(v_keys, 'id:' || lower(v_row_id::text) || ':' || v_seg_num);

      update public.pruning_row_segments s
      set paddock_row_id = v_row_id,
          row_label = coalesce(s.row_label, v_label),
          updated_at = now()
      where s.pruning_season_id = v_season
        and s.paddock_row_id is null
        and s.row_number = v_row_num
        and not exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = v_season
            and x.paddock_row_id = v_row_id
            and x.segment_number = s.segment_number
        );

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id, paddock_row_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season, v_paddock, v_row_id,
        v_row_num, v_label, v_seg_num,
        true, now(), coalesce(p_worker, ''), v_alloc
      )
      on conflict (pruning_season_id, paddock_row_id, segment_number) where paddock_row_id is not null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_number = excluded.row_number,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;

      select pruning_entry_id into v_owner
      from public.pruning_row_segments
      where pruning_season_id = v_season
        and paddock_row_id = v_row_id
        and segment_number = v_seg_num
      limit 1;
    else
      v_keys := array_append(v_keys, 'num:' || v_row_num || ':' || v_seg_num);

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season, v_paddock,
        v_row_num, v_label, v_seg_num,
        true, now(), coalesce(p_worker, ''), v_alloc
      )
      on conflict (pruning_season_id, row_number, segment_number) where paddock_row_id is null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;

      select pruning_entry_id into v_owner
      from public.pruning_row_segments
      where pruning_season_id = v_season
        and paddock_row_id is null
        and row_number = v_row_num
        and segment_number = v_seg_num
      limit 1;
    end if;

    if v_owner is distinct from v_alloc then
      v_conflicts := v_conflicts || jsonb_build_object(
        'paddock_id', v_paddock, 'row', v_row_num, 'segment', v_seg_num,
        'reason', 'already_completed_by_another_entry'
      );
    end if;
  end loop;

  -- ---- pass 2: release quarters removed from this allocation ---------------
  update public.pruning_row_segments s
  set completed = false, completed_at = null, completed_by = null,
      pruning_entry_id = null, updated_at = now()
  where s.pruning_entry_id = v_alloc
    and not (
      (case
        when s.paddock_row_id is not null then 'id:' || lower(s.paddock_row_id::text) || ':' || s.segment_number
        else 'num:' || s.row_number || ':' || s.segment_number
      end) = any (v_keys)
    );
  get diagnostics v_removed = row_count;

  select count(*)::integer into v_attributed
  from public.pruning_row_segments where pruning_entry_id = v_alloc;

  update public.pruning_entries
  set row_equivalents_completed = v_attributed / 4.0,
      estimated_vines_completed = case
        when v_requested > 0
        then round(v_vines::numeric * least(v_attributed, v_requested) / v_requested)::integer
        else 0
      end,
      updated_at = now()
  where id = v_alloc;

  return jsonb_build_object(
    'allocation_id', v_alloc,
    'paddock_id', v_paddock,
    'allocation_index', p_allocation_index,
    'pruning_season_id', v_season,
    'season_year', (select season_year from public.pruning_seasons where id = v_season),
    'vintage_year', p_vintage_year,
    'season_changed', v_prev_season is not null and v_prev_season is distinct from v_season,
    'requested', v_requested,
    'attributed', v_attributed,
    'removed', v_removed,
    'duplicates_removed', greatest(v_raw - v_requested, 0),
    'quarters_declared', nullif(p_allocation->>'quarters', '')::integer,
    'conflicts', v_conflicts,
    -- SQL 167 diagnostics — additive, so existing clients keep working.
    'allocation_id_source', v_resolution->>'source',
    'supplied_allocation_id', v_resolution->'supplied_allocation_id',
    'rejected_allocation_id', v_resolution->'rejected_allocation_id',
    'rejected_allocation_id_reason', v_resolution->'rejected_reason'
  );
end;
$$;

comment on function public.apply_pruning_activity_allocation(
  uuid, uuid, date, text, text, text, integer, timestamptz, jsonb, integer) is
  'SQL 166 §8, corrected by SQL 167: applies ONE block allocation inside the caller''s transaction. The allocation id is resolved by resolve_pruning_allocation_id, so an omitted id reuses the activity''s existing allocation for that block (including migrated legacy entries) instead of deriving a second one.';

revoke all on function public.apply_pruning_activity_allocation(
  uuid, uuid, date, text, text, text, integer, timestamptz, jsonb, integer) from public, anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 3. Validation — the migration ABORTS if any of these fail
-- ---------------------------------------------------------------------------
do $$
declare
  n integer;
  probe_activity uuid := gen_random_uuid();
  probe_block    uuid := gen_random_uuid();
  r jsonb;
begin
  if to_regprocedure('public.resolve_pruning_allocation_id(uuid, uuid, uuid)') is null then
    raise exception 'SQL 167: resolve_pruning_allocation_id missing';
  end if;
  if to_regprocedure('public.apply_pruning_activity_allocation(uuid, uuid, date, text, text, text, integer, timestamptz, jsonb, integer)') is null then
    raise exception 'SQL 167: apply_pruning_activity_allocation signature changed';
  end if;

  -- Signatures the activity RPCs call must be untouched.
  if to_regprocedure('public.record_pruning_activity(uuid, uuid, jsonb, jsonb, timestamptz)') is null
     or to_regprocedure('public.update_pruning_activity(uuid, jsonb, jsonb, timestamptz)') is null then
    raise exception 'SQL 167: the activity RPC contract changed unexpectedly';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'pruning_entries_activity_block_unique'
  ) then
    raise exception 'SQL 167: the one-allocation-per-(activity, block) index is missing';
  end if;

  if has_function_privilege('anon',
    'public.resolve_pruning_allocation_id(uuid, uuid, uuid)', 'execute') then
    raise exception 'SQL 167: anon must not execute resolve_pruning_allocation_id';
  end if;

  -- Read-only smoke test: an unknown pair must fall through to the derived id.
  r := public.resolve_pruning_allocation_id(probe_activity, probe_block, null);
  if r->>'source' <> 'derived'
     or (r->>'allocation_id')::uuid <> public.derive_pruning_allocation_id(probe_activity, probe_block) then
    raise exception 'SQL 167: derived fallback broken (%)', r;
  end if;

  -- Production state: no activity/block pair may hold two live allocations.
  select count(*) into n
  from (
    select pruning_activity_id, paddock_id
    from public.pruning_entries
    where pruning_activity_id is not null and deleted_at is null
    group by 1, 2 having count(*) > 1
  ) t;
  if n > 0 then
    raise exception 'SQL 167: % activity/block pairs already hold duplicate live allocations', n;
  end if;

  raise notice 'SQL 167 pruning allocation id resolution: APPLIED';
end$$;

-- ---------------------------------------------------------------------------
-- 4. Verification (run manually; read-only)
-- ---------------------------------------------------------------------------
-- Which allocations do NOT own a derived id (i.e. the rows the old code broke)?
-- select e.pruning_activity_id, e.paddock_id, e.id as allocation_id,
--        public.derive_pruning_allocation_id(e.pruning_activity_id, e.paddock_id) as derived
-- from public.pruning_entries e
-- where e.pruning_activity_id is not null and e.deleted_at is null
--   and e.id <> public.derive_pruning_allocation_id(e.pruning_activity_id, e.paddock_id)
-- order by e.entry_date desc;
--
-- Resolve what an id-less update payload would now target:
-- select public.resolve_pruning_allocation_id('<activity-uuid>', '<paddock-uuid>');
--
-- Duplicate live allocations (must always return zero rows):
-- select pruning_activity_id, paddock_id, count(*)
-- from public.pruning_entries
-- where pruning_activity_id is not null and deleted_at is null
-- group by 1, 2 having count(*) > 1;
