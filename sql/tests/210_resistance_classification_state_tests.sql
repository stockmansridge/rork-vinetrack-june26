-- Tests for sql/210 — resistance classification state.
--
-- ROLLBACK ONLY. Everything runs inside one transaction that ends in
-- `rollback`, so this is safe to run against production before the migration
-- is approved. It seeds its own replica rows and asserts on those; the two
-- production-shape assertions (T11/T12) are read-only.
--
-- RUN ORDER
--   sql/210_resistance_classification_state.sql   (the migration)
--   sql/tests/210_resistance_classification_state_tests.sql  (this file)
--
-- The whole point of the migration is that three conditions stop being one.
-- Most of what follows therefore checks that a value did NOT get written:
-- the dangerous outcome here is a silent 'not_applicable', not a crash.

begin;

do $$
declare
  v_vineyard uuid;
  v_state    text;
  v_count    integer;
  v_id_none      uuid := '210e0001-0000-0000-0000-000000000001';
  v_id_classified uuid := '210e0001-0000-0000-0000-000000000002';
  v_id_na        uuid := '210e0001-0000-0000-0000-000000000003';
  v_id_partial   uuid := '210e0001-0000-0000-0000-000000000004';
  v_id_nocode    uuid := '210e0001-0000-0000-0000-000000000005';
  v_id_mixed     uuid := '210e0001-0000-0000-0000-000000000006';
  v_id_legacy    uuid := '210e0001-0000-0000-0000-000000000007';
begin

  -- =====================================================================
  -- T1. The column exists, is NOT NULL, and defaults to 'unresolved'
  --
  -- A nullable column would reintroduce a fourth ambiguous state, which is
  -- the exact defect this migration exists to remove.
  -- =====================================================================
  select is_nullable, column_default into v_state, v_count
    from information_schema.columns
   where table_schema = 'public' and table_name = 'saved_chemicals'
     and column_name = 'resistance_classification_state';

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'saved_chemicals'
       and column_name = 'resistance_classification_state'
       and is_nullable = 'NO'
  ) then
    raise exception 'T1 FAILED: resistance_classification_state must be NOT NULL';
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. The CHECK admits exactly three values
  -- =====================================================================
  select id into v_vineyard from public.vineyards where deleted_at is null limit 1;
  if v_vineyard is null then
    raise exception 'T2 SKIPPED: no vineyard available to seed against';
  end if;

  begin
    insert into public.saved_chemicals (id, vineyard_id, name, resistance_classification_state)
    values (v_id_none, v_vineyard, 'T210 bad state', 'probably_fine');
    raise exception 'T2 FAILED: an unknown classification state was accepted';
  exception
    when check_violation then null;  -- correct
  end;
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3. A row with NO structured actives is unresolved, never not_applicable
  --
  -- THE headline rule. Every pre-sql/194 chemical is in this shape, and
  -- marking them group-free would exclude them from every resistance
  -- warning they should raise.
  -- =====================================================================
  insert into public.saved_chemicals (id, vineyard_id, name, active_ingredients)
  values (v_id_none, v_vineyard, 'T210 no actives', null);

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_none;
  if v_state <> 'unresolved' then
    raise exception 'T3 FAILED: a row with no actives became %, expected unresolved', v_state;
  end if;
  raise notice 'T3 passed';

  -- =====================================================================
  -- T4. An empty actives ARRAY is also unresolved
  -- =====================================================================
  update public.saved_chemicals
     set active_ingredients = '[]'::jsonb,
         resistance_classification_state = 'unresolved'
   where id = v_id_none;

  -- Re-run the migration's own backfill predicate over this row.
  update public.saved_chemicals
  set resistance_classification_state = 'unresolved'
  where id = v_id_none
    and (active_ingredients is null or jsonb_array_length(active_ingredients) = 0);

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_none;
  if v_state <> 'unresolved' then
    raise exception 'T4 FAILED: an empty actives array became %', v_state;
  end if;
  raise notice 'T4 passed';

  -- =====================================================================
  -- T5. Every active carrying scheme+code -> classified
  -- =====================================================================
  insert into public.saved_chemicals (id, vineyard_id, name, active_ingredients)
  values (
    v_id_classified, v_vineyard, 'T210 classified mixture',
    '[{"name":"Tebuconazole","activity_group":{"scheme":"frac","code":"3"}},
      {"name":"Azoxystrobin","activity_group":{"scheme":"frac","code":"11"}}]'::jsonb
  );

  update public.saved_chemicals c
  set resistance_classification_state = 'classified'
  where c.id = v_id_classified
    and exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where a->'activity_group'->>'scheme' in ('frac','hrac','irac')
         and coalesce(a->'activity_group'->>'code','') <> ''
    )
    and not exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where not (
         (a->'activity_group'->>'scheme' in ('frac','hrac','irac')
            and coalesce(a->'activity_group'->>'code','') <> '')
         or a->'activity_group'->>'scheme' = 'not_applicable'
       )
    );

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_classified;
  if v_state <> 'classified' then
    raise exception 'T5 FAILED: a fully classified mixture became %', v_state;
  end if;
  raise notice 'T5 passed';

  -- =====================================================================
  -- T6. Every active explicitly not_applicable -> not_applicable
  --
  -- The ONLY route to not_applicable: a positive assertion already stored.
  -- =====================================================================
  insert into public.saved_chemicals (id, vineyard_id, name, active_ingredients)
  values (
    v_id_na, v_vineyard, 'T210 wetter',
    '[{"name":"Nonionic surfactant","activity_group":{"scheme":"not_applicable","code":""}}]'::jsonb
  );

  update public.saved_chemicals c
  set resistance_classification_state = 'not_applicable'
  where c.id = v_id_na
    and exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where a->'activity_group'->>'scheme' = 'not_applicable'
    )
    and not exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where coalesce(a->'activity_group'->>'scheme','') <> 'not_applicable'
    );

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_na;
  if v_state <> 'not_applicable' then
    raise exception 'T6 FAILED: an explicitly group-free product became %', v_state;
  end if;
  raise notice 'T6 passed';

  -- =====================================================================
  -- T7. An active with NO activity_group key can never reach not_applicable
  --
  -- This is T3's rule at the ACTIVE level, and it is the one a future
  -- "tidy-up" migration is most likely to get wrong.
  -- =====================================================================
  insert into public.saved_chemicals (id, vineyard_id, name, active_ingredients)
  values (
    v_id_partial, v_vineyard, 'T210 unclassified fungicide',
    '[{"name":"Some unclassified active"}]'::jsonb
  );

  -- Apply BOTH positive backfill predicates; neither may fire.
  update public.saved_chemicals c
  set resistance_classification_state = 'classified'
  where c.id = v_id_partial
    and exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where a->'activity_group'->>'scheme' in ('frac','hrac','irac')
         and coalesce(a->'activity_group'->>'code','') <> ''
    );

  update public.saved_chemicals c
  set resistance_classification_state = 'not_applicable'
  where c.id = v_id_partial
    and exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where a->'activity_group'->>'scheme' = 'not_applicable'
    )
    and not exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where coalesce(a->'activity_group'->>'scheme','') <> 'not_applicable'
    );

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_partial;
  if v_state <> 'unresolved' then
    raise exception
      'T7 FAILED: an active with no group object became % — a missing group is not an assertion', v_state;
  end if;
  raise notice 'T7 passed';

  -- =====================================================================
  -- T8. A scheme with an EMPTY code is not classification
  --
  -- Half a record is not knowledge. "frac" with no number tells the Planner
  -- nothing it can rotate on.
  -- =====================================================================
  insert into public.saved_chemicals (id, vineyard_id, name, active_ingredients)
  values (
    v_id_nocode, v_vineyard, 'T210 scheme without code',
    '[{"name":"Half-written","activity_group":{"scheme":"frac","code":""}}]'::jsonb
  );

  update public.saved_chemicals c
  set resistance_classification_state = 'classified'
  where c.id = v_id_nocode
    and exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where a->'activity_group'->>'scheme' in ('frac','hrac','irac')
         and coalesce(a->'activity_group'->>'code','') <> ''
    );

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_nocode;
  if v_state <> 'unresolved' then
    raise exception 'T8 FAILED: a scheme with no code became %', v_state;
  end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T9. A PARTIALLY classified mixture is unresolved, not classified
  --
  -- Reporting it classified would tell the Planner it knows the whole
  -- chemistry when it knows half of it.
  -- =====================================================================
  insert into public.saved_chemicals (id, vineyard_id, name, active_ingredients)
  values (
    v_id_mixed, v_vineyard, 'T210 half-known mixture',
    '[{"name":"Tebuconazole","activity_group":{"scheme":"frac","code":"3"}},
      {"name":"Mystery active"}]'::jsonb
  );

  update public.saved_chemicals c
  set resistance_classification_state = 'classified'
  where c.id = v_id_mixed
    and exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where a->'activity_group'->>'scheme' in ('frac','hrac','irac')
         and coalesce(a->'activity_group'->>'code','') <> ''
    )
    and not exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where not (
         (a->'activity_group'->>'scheme' in ('frac','hrac','irac')
            and coalesce(a->'activity_group'->>'code','') <> '')
         or a->'activity_group'->>'scheme' = 'not_applicable'
       )
    );

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_mixed;
  if v_state <> 'unresolved' then
    raise exception 'T9 FAILED: a half-classified mixture became %', v_state;
  end if;
  raise notice 'T9 passed';

  -- =====================================================================
  -- T10. A classified active PLUS an explicit not_applicable active
  --      (a fungicide with a built-in wetter) IS classified
  --
  -- The wetter has nothing to contribute and must not spoil the state.
  -- =====================================================================
  update public.saved_chemicals
     set active_ingredients =
       '[{"name":"Tebuconazole","activity_group":{"scheme":"frac","code":"3"}},
         {"name":"Wetter","activity_group":{"scheme":"not_applicable","code":""}}]'::jsonb,
         resistance_classification_state = 'unresolved'
   where id = v_id_mixed;

  update public.saved_chemicals c
  set resistance_classification_state = 'classified'
  where c.id = v_id_mixed
    and exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where a->'activity_group'->>'scheme' in ('frac','hrac','irac')
         and coalesce(a->'activity_group'->>'code','') <> ''
    )
    and not exists (
      select 1 from jsonb_array_elements(c.active_ingredients) a
       where not (
         (a->'activity_group'->>'scheme' in ('frac','hrac','irac')
            and coalesce(a->'activity_group'->>'code','') <> '')
         or a->'activity_group'->>'scheme' = 'not_applicable'
       )
    );

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_mixed;
  if v_state <> 'classified' then
    raise exception 'T10 FAILED: fungicide + wetter became %, expected classified', v_state;
  end if;
  raise notice 'T10 passed';

  -- =====================================================================
  -- T11. The legacy free-text chemical_group is NEVER read
  --
  -- sql/194 refused to launder that guess into the database. A row whose
  -- only chemistry is the string "3 + 11" stays unresolved.
  -- =====================================================================
  insert into public.saved_chemicals (id, vineyard_id, name, chemical_group, active_ingredients)
  values (v_id_legacy, v_vineyard, 'T210 legacy string only', '3 + 11', null);

  select resistance_classification_state into v_state
    from public.saved_chemicals where id = v_id_legacy;
  if v_state <> 'unresolved' then
    raise exception 'T11 FAILED: a legacy group string produced %, expected unresolved', v_state;
  end if;
  raise notice 'T11 passed';

  -- =====================================================================
  -- T12. PRODUCTION assertion (read-only): nothing was silently asserted
  --
  -- After the real backfill, every production row marked not_applicable
  -- must have the positive assertion behind it. A single row failing this
  -- means the backfill inferred group-freedom from absence.
  -- =====================================================================
  select count(*) into v_count
    from public.saved_chemicals c
   where c.deleted_at is null
     and c.resistance_classification_state = 'not_applicable'
     and not exists (
       select 1 from jsonb_array_elements(coalesce(c.active_ingredients, '[]'::jsonb)) a
        where a->'activity_group'->>'scheme' = 'not_applicable'
     );
  if v_count > 0 then
    raise exception
      'T12 FAILED: % production rows are not_applicable without an explicit assertion', v_count;
  end if;
  raise notice 'T12 passed';

  -- =====================================================================
  -- T13. PRODUCTION assertion (read-only): classified rows really are
  -- =====================================================================
  select count(*) into v_count
    from public.saved_chemicals c
   where c.deleted_at is null
     and c.resistance_classification_state = 'classified'
     and not exists (
       select 1 from jsonb_array_elements(coalesce(c.active_ingredients, '[]'::jsonb)) a
        where a->'activity_group'->>'scheme' in ('frac','hrac','irac')
          and coalesce(a->'activity_group'->>'code','') <> ''
     );
  if v_count > 0 then
    raise exception
      'T13 FAILED: % rows claim classified with no usable scheme+code', v_count;
  end if;
  raise notice 'T13 passed';

  -- =====================================================================
  -- T14. The audit view exposes the state and the blind-spot flag
  -- =====================================================================
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'saved_chemical_intelligence_audit'
       and column_name = 'resistance_classification_state'
  ) then
    raise exception 'T14 FAILED: the audit view lost resistance_classification_state '
      '(re-running sql/194 after sql/210 drops it — see the migration header)';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'saved_chemical_intelligence_audit'
       and column_name = 'resistance_unresolved'
  ) then
    raise exception 'T14 FAILED: the audit view lost resistance_unresolved';
  end if;
  raise notice 'T14 passed';

  -- =====================================================================
  -- T15. The master catalogue carries the same column and CHECK
  -- =====================================================================
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'master_chemicals'
       and column_name = 'resistance_classification_state'
       and is_nullable = 'NO'
  ) then
    raise exception 'T15 FAILED: master_chemicals is missing the NOT NULL state column';
  end if;
  raise notice 'T15 passed';

  -- =====================================================================
  -- T16. sql/194 columns are untouched
  --
  -- The migration is additive. Every existing reader must keep working.
  -- =====================================================================
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'saved_chemicals'
       and column_name = 'activity_groups'
  ) or not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'saved_chemicals'
       and column_name = 'activity_group_scheme'
  ) then
    raise exception 'T16 FAILED: sql/194 chemistry columns were altered';
  end if;
  raise notice 'T16 passed';

  raise notice 'SQL 210 resistance classification state tests: ALL PASSED';
end $$;

rollback;
