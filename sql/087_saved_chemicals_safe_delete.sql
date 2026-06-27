-- 087_saved_chemicals_safe_delete.sql
--
-- Safe archive / hard delete RPCs for `public.saved_chemicals`.
--
-- Context:
--   * `saved_chemicals` already supports soft-delete via the `deleted_at`
--     timestamptz column (added in 011_management_sync.sql) and an
--     existing `soft_delete_saved_chemical(uuid)` RPC that returns void.
--   * Client tables (`spray_jobs.chemical_lines`, `spray_records.tanks`)
--     reference `saved_chemicals.id` inside JSONB, NOT via foreign keys,
--     so the database cannot block hard deletes by itself.
--   * Hard deleting a chemical that has been used in any spray job, spray
--     record, trip, costing, etc. would corrupt historical and compliance
--     reports.
--
-- This migration adds:
--   1. `public.soft_delete_saved_chemicals(p_id uuid) returns jsonb`
--        Archives a chemical by setting `deleted_at = now()`. Idempotent
--        if the row is already archived. Returns
--          { ok: true,  archived: true,  id: <uuid> }
--        or
--          { ok: false, reason: 'not_found' }.
--        Note the plural function name as requested by the client; the
--        existing singular `soft_delete_saved_chemical` is left in place
--        for backward compatibility.
--
--   2. `public.hard_delete_unused_saved_chemical(p_id uuid) returns jsonb`
--        Permanently deletes a saved chemical only when it has never been
--        referenced by any operational or historical record. Uses the
--        text representation of the relevant JSONB columns so it works
--        regardless of whether the chemical id is stored under
--        `chemicalId`, `chemical_id`, `savedChemicalId`, or
--        `saved_chemical_id` (the Swift / backend models use both
--        spellings in different places).
--        Returns
--          { ok: true,  deleted: true, id: <uuid> }
--        on success, or
--          { ok: false, reason: 'chemical_in_use',
--            message: 'This chemical has been used and cannot be permanently
--                      deleted. You can archive it instead.',
--            usages: { spray_jobs: n, spray_records: m, ... } }
--        when the chemical is referenced.
--
-- Both RPCs require authentication and owner/manager role on the
-- chemical's vineyard, matching the existing soft-delete policy.

-- =====================================================================
-- soft_delete_saved_chemicals(p_id uuid) -> jsonb
-- =====================================================================
create or replace function public.soft_delete_saved_chemicals(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
  v_already_archived boolean;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_id');
  end if;

  select vineyard_id, (deleted_at is not null)
    into v_vineyard_id, v_already_archived
    from public.saved_chemicals
   where id = p_id;

  if v_vineyard_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to archive saved chemical';
  end if;

  update public.saved_chemicals
     set deleted_at = coalesce(deleted_at, now()),
         updated_by = auth.uid()
   where id = p_id;

  return jsonb_build_object(
    'ok', true,
    'archived', true,
    'already_archived', coalesce(v_already_archived, false),
    'id', p_id
  );
end;
$function$;

revoke all on function public.soft_delete_saved_chemicals(uuid) from public;
grant execute on function public.soft_delete_saved_chemicals(uuid) to authenticated;

comment on function public.soft_delete_saved_chemicals(uuid) is
  'Archive (soft-delete) a saved_chemicals row by setting deleted_at. '
  'Owner/manager only. Returns jsonb { ok, archived, already_archived, id } '
  'or { ok:false, reason:''not_found'' }.';

-- =====================================================================
-- hard_delete_unused_saved_chemical(p_id uuid) -> jsonb
-- =====================================================================
-- Safety gate. Walks every table that could possibly reference a saved
-- chemical id and refuses the delete if any usage is found.
--
-- Tables checked:
--   * spray_jobs.chemical_lines         (jsonb array of chemical lines)
--   * spray_records.tanks               (jsonb tank mix with chemicals)
--   * trips                             (jsonb columns, defensive scan)
--   * Generic FK fallback: any other table that grows a foreign key
--     referencing saved_chemicals.id is automatically respected because
--     this RPC also asks the catalog for inbound FKs and runs an
--     EXISTS check against each one.
-- =====================================================================
create or replace function public.hard_delete_unused_saved_chemical(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
  v_id_text text;
  v_spray_jobs_count bigint := 0;
  v_spray_records_count bigint := 0;
  v_trips_count bigint := 0;
  v_fk_total_count bigint := 0;
  v_usages jsonb := '{}'::jsonb;
  v_fk record;
  v_fk_count bigint;
  v_sql text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_id');
  end if;

  select vineyard_id into v_vineyard_id
    from public.saved_chemicals
   where id = p_id;

  if v_vineyard_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete saved chemical';
  end if;

  v_id_text := p_id::text;

  -- ---------------------------------------------------------------
  -- spray_jobs.chemical_lines (JSONB array, keys vary by client:
  -- chemicalId / chemical_id / savedChemicalId / saved_chemical_id)
  -- ---------------------------------------------------------------
  if to_regclass('public.spray_jobs') is not null then
    execute format($sql$
      select count(*)
        from public.spray_jobs sj
       where sj.chemical_lines is not null
         and sj.chemical_lines::text ilike %L
    $sql$, '%' || v_id_text || '%')
      into v_spray_jobs_count;
  end if;

  -- ---------------------------------------------------------------
  -- spray_records.tanks (JSONB; chemicals are nested with
  -- savedChemicalId / saved_chemical_id)
  -- ---------------------------------------------------------------
  if to_regclass('public.spray_records') is not null then
    execute format($sql$
      select count(*)
        from public.spray_records sr
       where sr.tanks is not null
         and sr.tanks::text ilike %L
    $sql$, '%' || v_id_text || '%')
      into v_spray_records_count;
  end if;

  -- ---------------------------------------------------------------
  -- trips: defensive scan of any jsonb columns. Trips can carry
  -- chemical snapshots for costing.
  -- ---------------------------------------------------------------
  if to_regclass('public.trips') is not null then
    select coalesce(sum(c), 0) into v_trips_count
      from (
        select count(*) as c
          from public.trips t,
               lateral (
                 select string_agg(
                          case
                            when (to_jsonb(t) -> col.column_name) is not null
                            then (to_jsonb(t) -> col.column_name)::text
                            else ''
                          end,
                          ' '
                        ) as blob
                   from information_schema.columns col
                  where col.table_schema = 'public'
                    and col.table_name = 'trips'
                    and col.data_type in ('jsonb', 'json')
               ) j
         where j.blob ilike '%' || v_id_text || '%'
      ) s;
  end if;

  -- ---------------------------------------------------------------
  -- Generic catalog-driven check: any other table that has a real FK
  -- column referencing saved_chemicals.id. This future-proofs the RPC
  -- against new tables added later (chemical_purchases, trip_chemicals,
  -- costing rollups, etc.).
  -- ---------------------------------------------------------------
  for v_fk in
    select tc.table_schema,
           tc.table_name,
           kcu.column_name
      from information_schema.table_constraints tc
      join information_schema.key_column_usage kcu
        on tc.constraint_name = kcu.constraint_name
       and tc.table_schema = kcu.table_schema
      join information_schema.constraint_column_usage ccu
        on ccu.constraint_name = tc.constraint_name
       and ccu.table_schema = tc.table_schema
     where tc.constraint_type = 'FOREIGN KEY'
       and ccu.table_schema = 'public'
       and ccu.table_name = 'saved_chemicals'
       and ccu.column_name = 'id'
  loop
    v_sql := format(
      'select count(*) from %I.%I where %I = $1',
      v_fk.table_schema, v_fk.table_name, v_fk.column_name
    );
    execute v_sql into v_fk_count using p_id;
    if coalesce(v_fk_count, 0) > 0 then
      v_fk_total_count := v_fk_total_count + v_fk_count;
      v_usages := v_usages || jsonb_build_object(
        v_fk.table_name || '.' || v_fk.column_name,
        v_fk_count
      );
    end if;
  end loop;

  -- ---------------------------------------------------------------
  -- If used anywhere → refuse.
  -- ---------------------------------------------------------------
  if v_spray_jobs_count > 0
     or v_spray_records_count > 0
     or v_trips_count > 0
     or v_fk_total_count > 0
  then
    if v_spray_jobs_count > 0 then
      v_usages := v_usages || jsonb_build_object('spray_jobs', v_spray_jobs_count);
    end if;
    if v_spray_records_count > 0 then
      v_usages := v_usages || jsonb_build_object('spray_records', v_spray_records_count);
    end if;
    if v_trips_count > 0 then
      v_usages := v_usages || jsonb_build_object('trips', v_trips_count);
    end if;

    return jsonb_build_object(
      'ok', false,
      'reason', 'chemical_in_use',
      'message',
        'This chemical has been used and cannot be permanently deleted. '
        'You can archive it instead.',
      'usages', v_usages,
      'id', p_id
    );
  end if;

  -- ---------------------------------------------------------------
  -- Truly unused → hard delete. Bypasses the
  -- saved_chemicals_no_client_hard_delete RLS policy because this
  -- function is security definer.
  -- ---------------------------------------------------------------
  delete from public.saved_chemicals where id = p_id;

  return jsonb_build_object(
    'ok', true,
    'deleted', true,
    'id', p_id
  );
end;
$function$;

revoke all on function public.hard_delete_unused_saved_chemical(uuid) from public;
grant execute on function public.hard_delete_unused_saved_chemical(uuid) to authenticated;

comment on function public.hard_delete_unused_saved_chemical(uuid) is
  'Permanently delete a saved_chemicals row only if it is not referenced '
  'by any spray_jobs.chemical_lines, spray_records.tanks, trips jsonb '
  'columns, or any FK pointing at saved_chemicals.id. Owner/manager only. '
  'Returns jsonb { ok, deleted, id } on success or '
  '{ ok:false, reason:''chemical_in_use'', message, usages, id } when blocked.';
