-- Prompt 4C — guarded Stockmans Ridge three-pin block-link ROLLBACK
-- REVIEW AND RUN MANUALLY only if the applied repair must be reversed.
-- This refuses to overwrite any pin changed after APPLY. It restores only the
-- audited paddock_id (NULL for this package), increments sync_version, and lets
-- the existing pins_set_updated_at trigger set a new server updated_at.
-- A missing audit table means APPLY did not commit; never create it manually.

do $preflight$
begin
  if to_regclass('public.pin_block_link_repair_audit') is null then
    raise exception using
      message = 'APPLY_NOT_COMMITTED: public.pin_block_link_repair_audit does not exist',
      hint = 'There is no committed repair audit to roll back. Do not create the table manually.';
  end if;
end;
$preflight$;

begin transaction isolation level serializable;

do $rollback$
declare
  v_run_id constant uuid := 'a778659b-1a13-4e56-bc1b-f1a340bcb5da';
  v_vineyard_id constant uuid := 'fe952afe-437f-4be7-8cbf-fdd8e630411c';
  v_target_id constant uuid := '53128d1c-d745-4d99-8194-52e0ba08767b';
  v_expected_ids constant uuid[] := array[
    '2e4f7cc6-4876-47d5-b280-30d1ea1259ac'::uuid,
    '2c981eca-2981-435a-ac2a-a10aaaabf0ee'::uuid,
    'b46d0087-76ec-443b-936f-f010c8baffe3'::uuid
  ];
  v_audit record;
  v_current jsonb;
  v_rollback_after jsonb;
  v_audit_count integer;
  v_locked_count integer;
  v_changed_count integer := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended(v_run_id::text, 0));

  select count(*)::integer
    into v_audit_count
    from public.pin_block_link_repair_audit
   where run_id = v_run_id;

  if v_audit_count <> 3 then
    raise exception 'AUDIT_PRECONDITION_FAILED: expected 3 rows for run %, found %', v_run_id, v_audit_count;
  end if;

  -- Validate package identity before either the no-op or active rollback path.
  if exists (
    select 1
      from public.pin_block_link_repair_audit a
     where a.run_id = v_run_id
       and (
         a.vineyard_id <> v_vineyard_id
         or a.target_paddock_id <> v_target_id
         or a.pin_id <> all(v_expected_ids)
         or (a.before_row->>'paddock_id') is not null
       )
  ) then
    raise exception 'AUDIT_PRECONDITION_FAILED: run metadata is not the exact reviewed three-pin repair';
  end if;

  -- An exact repeat of an already completed rollback is a safe no-op only while
  -- every pin still exactly matches the recorded rollback post-image.
  if not exists (
    select 1
      from public.pin_block_link_repair_audit a
      left join public.pins p on p.id = a.pin_id
     where a.run_id = v_run_id
       and (
         a.status <> 'rolled_back'
         or a.rollback_after_row is null
         or to_jsonb(p) is distinct from a.rollback_after_row
       )
  ) then
    raise notice 'Run % is already rolled back exactly; no rows changed.', v_run_id;
    return;
  end if;

  if exists (
    select 1
      from public.pin_block_link_repair_audit a
     where a.run_id = v_run_id
       and (a.status <> 'applied' or a.rollback_after_row is not null)
  ) then
    raise exception 'AUDIT_PRECONDITION_FAILED: run is neither exact rolled-back state nor exact applied state';
  end if;

  -- Lock pins in deterministic order. The exact audited post-image comparison
  -- below is the refusal guard against every subsequent edit, including edits
  -- to fields unrelated to the block link.
  perform p.id
    from public.pins p
   where p.id = any(v_expected_ids)
   order by p.id
   for update;
  get diagnostics v_locked_count = row_count;
  if v_locked_count <> 3 then
    raise exception 'PIN_SET_PRECONDITION_FAILED: expected 3 pin rows, locked %', v_locked_count;
  end if;

  for v_audit in
    select a.*
      from public.pin_block_link_repair_audit a
     where a.run_id = v_run_id
     order by a.pin_id
     for update
  loop
    select to_jsonb(p)
      into v_current
      from public.pins p
     where p.id = v_audit.pin_id;

    if v_current is distinct from v_audit.after_row then
      raise exception 'SUBSEQUENT_EDIT_REFUSAL: pin % no longer matches the audited APPLY post-image', v_audit.pin_id;
    end if;

    update public.pins p
       set paddock_id = nullif(v_audit.before_row->>'paddock_id', '')::uuid,
           sync_version = p.sync_version + 1
     where p.id = v_audit.pin_id
       and p.vineyard_id = v_vineyard_id
       and p.paddock_id = v_target_id
       and p.sync_version is not null
       and to_jsonb(p) = v_audit.after_row
     returning to_jsonb(p) into v_rollback_after;

    if v_rollback_after is null then
      raise exception 'ROLLBACK_CONCURRENCY_FAILED: pin % changed before guarded restore', v_audit.pin_id;
    end if;

    if (v_rollback_after - array['paddock_id', 'updated_at', 'sync_version']::text[])
       is distinct from
       (v_audit.before_row - array['paddock_id', 'updated_at', 'sync_version']::text[]) then
      raise exception 'ROLLBACK_BUSINESS_FIELD_GUARD_FAILED: pin % did not restore only the audited link', v_audit.pin_id;
    end if;
    if v_rollback_after->>'paddock_id' is not null
       or (v_rollback_after->>'sync_version')::integer <> (v_audit.after_row->>'sync_version')::integer + 1 then
      raise exception 'ROLLBACK_MARKER_GUARD_FAILED: pin % has an unexpected link/version result', v_audit.pin_id;
    end if;

    update public.pin_block_link_repair_audit
       set status = 'rolled_back',
           rollback_after_row = v_rollback_after,
           rolled_back_at = clock_timestamp()
     where run_id = v_run_id
       and pin_id = v_audit.pin_id
       and status = 'applied'
       and rollback_after_row is null;
    get diagnostics v_locked_count = row_count;
    if v_locked_count <> 1 then
      raise exception 'ROLLBACK_AUDIT_FINALIZATION_FAILED: expected 1 row for pin %, changed %', v_audit.pin_id, v_locked_count;
    end if;

    v_changed_count := v_changed_count + 1;
  end loop;

  if v_changed_count <> 3 then
    raise exception 'ROLLBACK_EXPECTED_ROW_COUNT_FAILED: expected 3 pin restores, changed %', v_changed_count;
  end if;
end;
$rollback$;

commit;

select
  a.run_id,
  a.pin_id,
  a.status,
  p.paddock_id as restored_block_id,
  p.sync_version as current_sync_version,
  p.updated_at as current_updated_at,
  (to_jsonb(p) = a.rollback_after_row) as current_row_matches_rollback_audit,
  (
    (to_jsonb(p) - array['paddock_id', 'sync_version', 'updated_at']::text[])
    =
    (a.before_row - array['paddock_id', 'sync_version', 'updated_at']::text[])
  ) as unrelated_fields_match_original_before_image
from public.pin_block_link_repair_audit a
left join public.pins p on p.id = a.pin_id
where a.run_id = 'a778659b-1a13-4e56-bc1b-f1a340bcb5da'::uuid
order by a.pin_id;
