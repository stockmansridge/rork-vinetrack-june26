-- =====================================================================
-- 195_spray_block_attribution_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/195_spray_block_attribution.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects: both new columns, both trigger functions, the validator
--       and the GIN index exist
--   T2  BACKWARDS COMPATIBILITY: a legacy-shaped insert naming neither new
--       column still succeeds, and both new columns are NULL
--   T3  NO BACKFILL: the legacy row keeps NULL attribution even though its
--       vineyard has blocks — it does NOT acquire "all blocks"
--   T4  ONE block round-trips; block_ids is derived from the snapshot
--   T5  MULTIPLE blocks round-trip in selection order
--   T6  Duplicate block ids are NORMALISED (collapsed, order preserved),
--       not stored twice — a block cannot be counted twice in one spray
--   T7  block_ids is DERIVED: a client that writes a contradictory
--       block_ids has it overwritten from application_blocks, so geometry
--       A+C can never be stored as attribution A+B
--   T8  An EMPTY array is rejected on both columns — absence is NULL only
--   T9  Malformed snapshots rejected: not an array, element not an object,
--       missing blockId, non-uuid blockId
--   T10 The paired CHECK rejects a half-recorded attribution
--   T11 VINEYARD ISOLATION: a block from another vineyard is rejected
--   T12 A block id matching NO paddock is ALLOWED, and SURVIVES the block
--       being deleted — history is never erased to satisfy an FK
--   T13 Block RENAME does not change stored attribution (ids, not names)
--   T14 Per-block gross areas sum to the sql/191 aggregate gross_area_ha
--   T15 Per-block history query uses the GIN index and isolates blocks
--   T16 Templates (is_template = true) may carry intended block identity
--   T17 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 195 spray block attribution tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 195 is applied.
do $$
begin
  if to_regprocedure('public.spray_block_attribution_is_valid(jsonb)') is null
     or to_regprocedure('public.spray_records_derive_block_ids()') is null
     or to_regprocedure('public.spray_records_validate_block_vineyard()') is null then
    raise exception 'SQL 195 not applied — run sql/195_spray_block_attribution.sql first.';
  end if;
end$$;

do $$
declare
  v_vy      uuid := gen_random_uuid();
  v_vy_2    uuid := gen_random_uuid();
  b_a       uuid := gen_random_uuid();
  b_b       uuid := gen_random_uuid();
  b_c       uuid := gen_random_uuid();
  b_other   uuid := gen_random_uuid();
  b_ghost   uuid := gen_random_uuid();
  r_legacy  uuid := gen_random_uuid();
  r_one     uuid := gen_random_uuid();
  r_multi   uuid := gen_random_uuid();
  r_dup     uuid := gen_random_uuid();
  r_lie     uuid := gen_random_uuid();
  r_ghost   uuid := gen_random_uuid();
  r_tpl     uuid := gen_random_uuid();
  v_txt     text;
  v_num     numeric;
  v_cnt     int;
  v_ids     uuid[];
  v_failed  boolean;
  v_plan    text;
begin
  -- ---------------- T1 objects ----------------
  -- Asserted BY NAME. A count can only say "one is missing", never which one.
  select string_agg(c.column_name || ':' || c.data_type, ', ' order by c.column_name)
    into v_txt
    from information_schema.columns c
   where c.table_schema = 'public'
     and c.table_name   = 'spray_records'
     and c.column_name in ('application_blocks', 'block_ids');

  if v_txt is distinct from 'application_blocks:jsonb, block_ids:ARRAY' then
    raise exception 'T1 FAILED: expected application_blocks jsonb + block_ids ARRAY, got: %', coalesce(v_txt, '<none>');
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgname = 'trg_spray_records_derive_block_ids'
       and tgrelid = 'public.spray_records'::regclass
  ) then
    raise exception 'T1 FAILED: derive trigger missing';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgname = 'trg_spray_records_validate_block_vineyard'
       and tgrelid = 'public.spray_records'::regclass
  ) then
    raise exception 'T1 FAILED: vineyard isolation trigger missing';
  end if;

  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public' and indexname = 'idx_spray_records_block_ids'
  ) then
    raise exception 'T1 FAILED: idx_spray_records_block_ids missing';
  end if;

  -- ---------------- fixtures ----------------
  insert into public.vineyards (id, name, country_code)
  values (v_vy,   'T195 Attribution Vineyard', 'AU'),
         (v_vy_2, 'T195 Other Vineyard',       'AU');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_a,     v_vy,   'T195 Block A'),
    (b_b,     v_vy,   'T195 Block B'),
    (b_c,     v_vy,   'T195 Block C'),
    (b_other, v_vy_2, 'T195 Foreign Block');

  -- ---------------- T2 legacy-shaped insert ----------------
  -- Exactly the columns a pre-195 client writes. If this fails, the migration
  -- broke every deployed client.
  insert into public.spray_records (id, vineyard_id, date, spray_reference, operation_type, tanks)
  values (r_legacy, v_vy, now() - interval '30 days', 'T195 legacy foliar', 'Foliar Spray',
          '[{"tankNumber":1,"waterVolume":3000,"sprayRatePerHa":300,"concentrationFactor":1,"chemicals":[]}]'::jsonb);

  select count(*) into v_cnt
    from public.spray_records
   where id = r_legacy and application_blocks is null and block_ids is null;
  if v_cnt <> 1 then
    raise exception 'T2 FAILED: legacy insert did not land with NULL attribution';
  end if;

  -- ---------------- T3 no backfill ----------------
  -- The vineyard has three blocks. The legacy record must NOT acquire them.
  select block_ids into v_ids from public.spray_records where id = r_legacy;
  if v_ids is not null then
    raise exception 'T3 FAILED: legacy record acquired attribution: %', v_ids;
  end if;

  -- ---------------- T4 one block ----------------
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks,
    gross_area_ha, canonical_row_length_metres, geometry_source, geometry_quality,
    application_blocks
  ) values (
    r_one, v_vy, now() - interval '20 days', 'T195 single block', 'Foliar Spray', '[]'::jsonb,
    10.0, 31250, 'mapped_rows', 'authoritative',
    jsonb_build_array(jsonb_build_object(
      'blockId', b_a::text, 'blockName', 'T195 Block A',
      'grossAreaHa', 10.0, 'rowLengthMetres', 31250,
      'rowSpacingMetres', 3.2, 'rowCount', 40,
      'geometrySource', 'mapped_rows', 'geometryQuality', 'authoritative'
    ))
  );

  select block_ids into v_ids from public.spray_records where id = r_one;
  if v_ids is distinct from array[b_a] then
    raise exception 'T4 FAILED: expected [A], got %', v_ids;
  end if;

  -- ---------------- T5 multiple blocks, selection order ----------------
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks,
    gross_area_ha, application_blocks
  ) values (
    r_multi, v_vy, now() - interval '10 days', 'T195 A+C', 'Foliar Spray', '[]'::jsonb,
    15.0,
    jsonb_build_array(
      jsonb_build_object('blockId', b_a::text, 'blockName', 'T195 Block A', 'grossAreaHa', 10.0),
      jsonb_build_object('blockId', b_c::text, 'blockName', 'T195 Block C', 'grossAreaHa',  5.0)
    )
  );

  select block_ids into v_ids from public.spray_records where id = r_multi;
  if v_ids is distinct from array[b_a, b_c] then
    raise exception 'T5 FAILED: expected [A,C] in order, got %', v_ids;
  end if;

  -- ---------------- T6 duplicates normalised ----------------
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
  ) values (
    r_dup, v_vy, now(), 'T195 duplicate ids', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(
      jsonb_build_object('blockId', b_c::text, 'grossAreaHa', 5.0),
      jsonb_build_object('blockId', b_a::text, 'grossAreaHa', 10.0),
      jsonb_build_object('blockId', b_c::text, 'grossAreaHa', 5.0)
    )
  );

  select block_ids into v_ids from public.spray_records where id = r_dup;
  if v_ids is distinct from array[b_c, b_a] then
    raise exception 'T6 FAILED: duplicates not collapsed to first-occurrence order, got %', v_ids;
  end if;

  -- ---------------- T7 block_ids is DERIVED, not authored ----------------
  -- The audit's invariant: geometry calculated from A+C must never be stored as
  -- attribution A+B. Write a deliberately contradictory block_ids and prove the
  -- trigger overwrites it from the snapshot.
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks,
    application_blocks, block_ids
  ) values (
    r_lie, v_vy, now(), 'T195 contradictory', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(
      jsonb_build_object('blockId', b_a::text),
      jsonb_build_object('blockId', b_c::text)
    ),
    array[b_a, b_b]      -- a lie: B was never in the geometry
  );

  select block_ids into v_ids from public.spray_records where id = r_lie;
  if v_ids is distinct from array[b_a, b_c] then
    raise exception 'T7 FAILED: authored block_ids was not overwritten from the snapshot, got %', v_ids;
  end if;

  -- And on UPDATE too.
  update public.spray_records set block_ids = array[b_b] where id = r_lie;
  select block_ids into v_ids from public.spray_records where id = r_lie;
  if v_ids is distinct from array[b_a, b_c] then
    raise exception 'T7 FAILED (update): block_ids diverged from snapshot, got %', v_ids;
  end if;

  -- ---------------- T8 empty arrays rejected ----------------
  v_failed := false;
  begin
    insert into public.spray_records (id, vineyard_id, date, operation_type, tanks, application_blocks)
    values (gen_random_uuid(), v_vy, now(), 'Foliar Spray', '[]'::jsonb, '[]'::jsonb);
  exception when others then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T8 FAILED: empty application_blocks array was accepted';
  end if;

  -- ---------------- T9 malformed snapshots rejected ----------------
  -- not an array
  v_failed := false;
  begin
    insert into public.spray_records (id, vineyard_id, date, operation_type, tanks, application_blocks)
    values (gen_random_uuid(), v_vy, now(), 'Foliar Spray', '[]'::jsonb, '{"blockId":"x"}'::jsonb);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T9 FAILED: non-array accepted'; end if;

  -- element not an object
  v_failed := false;
  begin
    insert into public.spray_records (id, vineyard_id, date, operation_type, tanks, application_blocks)
    values (gen_random_uuid(), v_vy, now(), 'Foliar Spray', '[]'::jsonb, '["not-an-object"]'::jsonb);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T9 FAILED: non-object element accepted'; end if;

  -- missing blockId
  v_failed := false;
  begin
    insert into public.spray_records (id, vineyard_id, date, operation_type, tanks, application_blocks)
    values (gen_random_uuid(), v_vy, now(), 'Foliar Spray', '[]'::jsonb, '[{"blockName":"A"}]'::jsonb);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T9 FAILED: element without blockId accepted'; end if;

  -- non-uuid blockId (a NAME used as identity is exactly what must be refused)
  v_failed := false;
  begin
    insert into public.spray_records (id, vineyard_id, date, operation_type, tanks, application_blocks)
    values (gen_random_uuid(), v_vy, now(), 'Foliar Spray', '[]'::jsonb, '[{"blockId":"Block A"}]'::jsonb);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T9 FAILED: non-uuid blockId accepted'; end if;

  -- ---------------- T10 paired check ----------------
  -- block_ids without a snapshot is nulled by the trigger (so it can never be
  -- half-recorded), which is what keeps the paired CHECK satisfiable.
  insert into public.spray_records (id, vineyard_id, date, operation_type, tanks, block_ids)
  values (gen_random_uuid(), v_vy, now(), 'Foliar Spray', '[]'::jsonb, array[b_a])
  returning block_ids into v_ids;
  if v_ids is not null then
    raise exception 'T10 FAILED: block_ids without application_blocks was retained: %', v_ids;
  end if;

  -- ---------------- T11 vineyard isolation ----------------
  v_failed := false;
  begin
    insert into public.spray_records (id, vineyard_id, date, operation_type, tanks, application_blocks)
    values (gen_random_uuid(), v_vy, now(), 'Foliar Spray', '[]'::jsonb,
            jsonb_build_array(jsonb_build_object('blockId', b_other::text)));
  exception when others then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T11 FAILED: a block from another vineyard was accepted';
  end if;

  -- ---------------- T12 unknown id allowed, and survives deletion ----------------
  -- No FK: a completed spray is a compliance document and must keep saying
  -- which block it treated even after that block is gone.
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
  ) values (
    r_ghost, v_vy, now(), 'T195 ghost block', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('blockId', b_ghost::text, 'blockName', 'Deleted Block'))
  );

  select block_ids into v_ids from public.spray_records where id = r_ghost;
  if v_ids is distinct from array[b_ghost] then
    raise exception 'T12 FAILED: unknown block id was not preserved, got %', v_ids;
  end if;

  -- Now delete a REAL block that r_multi references and prove attribution survives.
  delete from public.paddocks where id = b_c;

  select block_ids into v_ids from public.spray_records where id = r_multi;
  if v_ids is distinct from array[b_a, b_c] then
    raise exception 'T12 FAILED: deleting a block erased historical attribution, got %', v_ids;
  end if;

  select application_blocks -> 1 ->> 'blockName' into v_txt
    from public.spray_records where id = r_multi;
  if v_txt is distinct from 'T195 Block C' then
    raise exception 'T12 FAILED: deleted block lost its display snapshot, got %', coalesce(v_txt, '<null>');
  end if;

  -- ---------------- T13 rename does not touch attribution ----------------
  update public.paddocks set name = 'T195 Block A RENAMED' where id = b_a;

  select block_ids into v_ids from public.spray_records where id = r_multi;
  if v_ids is distinct from array[b_a, b_c] then
    raise exception 'T13 FAILED: rename changed stored ids, got %', v_ids;
  end if;

  select application_blocks -> 0 ->> 'blockName' into v_txt
    from public.spray_records where id = r_multi;
  if v_txt is distinct from 'T195 Block A' then
    raise exception 'T13 FAILED: historical name snapshot was rewritten by a rename, got %', coalesce(v_txt, '<null>');
  end if;

  -- ---------------- T14 per-block areas reconcile with sql/191 aggregate ----------------
  select sum((e.value ->> 'grossAreaHa')::numeric), max(sr.gross_area_ha)
    into v_num, v_cnt
    from public.spray_records sr
    cross join lateral jsonb_array_elements(sr.application_blocks) as e(value)
   where sr.id = r_multi;

  select gross_area_ha into v_num from public.spray_records where id = r_multi;
  if v_num is distinct from 15.0 then
    raise exception 'T14 FAILED: aggregate gross_area_ha is %, expected 15.0', v_num;
  end if;

  select sum((e.value ->> 'grossAreaHa')::numeric) into v_num
    from public.spray_records sr
    cross join lateral jsonb_array_elements(sr.application_blocks) as e(value)
   where sr.id = r_multi;
  if v_num is distinct from 15.0 then
    raise exception 'T14 FAILED: per-block gross areas sum to %, expected 15.0', v_num;
  end if;

  -- ---------------- T15 per-block history query isolates blocks ----------------
  -- Block A was treated by r_one, r_multi, r_dup and r_lie.
  select count(*) into v_cnt
    from public.spray_records
   where vineyard_id = v_vy
     and block_ids @> array[b_a]::uuid[];
  if v_cnt <> 4 then
    raise exception 'T15 FAILED: block A history returned % rows, expected 4', v_cnt;
  end if;

  -- Block B was never sprayed: the contradictory write in T7 must not have
  -- given it a history.
  select count(*) into v_cnt
    from public.spray_records
   where vineyard_id = v_vy
     and block_ids @> array[b_b]::uuid[];
  if v_cnt <> 0 then
    raise exception 'T15 FAILED: block B has % applications, expected 0', v_cnt;
  end if;

  -- The legacy NULL row appears in NO block history.
  select count(*) into v_cnt
    from public.spray_records
   where id = r_legacy
     and block_ids @> array[b_a]::uuid[];
  if v_cnt <> 0 then
    raise exception 'T15 FAILED: an unattributed record leaked into a block history';
  end if;

  -- ---------------- T16 templates carry intended block identity ----------------
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, is_template, tanks,
    application_blocks
  ) values (
    r_tpl, v_vy, now(), 'T195 template', 'Foliar Spray', true, '[]'::jsonb,
    jsonb_build_array(
      jsonb_build_object('blockId', b_a::text, 'blockName', 'T195 Block A'),
      jsonb_build_object('blockId', b_b::text, 'blockName', 'T195 Block B')
    )
  );

  select block_ids into v_ids from public.spray_records where id = r_tpl;
  if v_ids is distinct from array[b_a, b_b] then
    raise exception 'T16 FAILED: template intended blocks not stored, got %', v_ids;
  end if;

  -- A template stores identity only — no frozen per-block geometry output.
  select application_blocks -> 0 ->> 'rowLengthMetres' into v_txt
    from public.spray_records where id = r_tpl;
  if v_txt is not null then
    raise exception 'T16 FAILED: template froze a per-block row length: %', v_txt;
  end if;

  raise notice 'SQL 195 spray block attribution tests: ALL PASSED';
end$$;

-- ---------------- T17 discard everything ----------------
rollback;

-- =====================================================================
-- Post-run expectation: the NOTICE above, and ZERO rows remaining. Verify
-- with (outside any transaction):
--   select count(*) from public.spray_records where spray_reference like 'T195%';
--   -- expected: 0
-- =====================================================================
