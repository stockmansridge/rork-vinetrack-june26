-- =============================================================================
-- Tests for sql/175_integration_api_stage3c_indexes.sql
--
-- READ-ONLY verification: confirms every Stage 3C API support index exists
-- with the expected shape. Run AFTER applying sql/175. Raises on failure,
-- prints PASS lines on success. Changes nothing.
-- =============================================================================

do $$
declare
  rec record;
  v_def text;
begin
  for rec in
    select * from (values
      ('idx_work_tasks_api_keyset',                'work_tasks',               true),
      ('idx_pruning_activities_api_keyset',        'pruning_activities',       true),
      ('idx_irrigation_sessions_api_keyset',       'irrigation_sessions',      true),
      ('idx_growth_stage_records_api_keyset',      'growth_stage_records',     true),
      ('idx_historical_yield_records_api_keyset',  'historical_yield_records', true),
      ('idx_pins_api_keyset',                      'pins',                     true),
      ('idx_work_tasks_vineyard_date',             'work_tasks',               false),
      ('idx_pruning_entries_vineyard_paddock',     'pruning_entries',          false),
      ('idx_historical_yield_records_vineyard_year','historical_yield_records', false)
    ) as t(index_name, table_name, is_keyset)
  loop
    select pg_get_indexdef(i.indexrelid) into v_def
    from pg_index i
    join pg_class c on c.oid = i.indexrelid
    join pg_class tc on tc.oid = i.indrelid
    join pg_namespace n on n.oid = tc.relnamespace
    where n.nspname = 'public'
      and c.relname = rec.index_name
      and tc.relname = rec.table_name;

    if v_def is null then
      raise exception 'FAIL: index % on public.% is missing', rec.index_name, rec.table_name;
    end if;

    if position('deleted_at IS NULL' in v_def) = 0 then
      raise exception 'FAIL: index % is not partial on deleted_at is null: %', rec.index_name, v_def;
    end if;

    if rec.is_keyset and position('vineyard_id, created_at, id' in v_def) = 0 then
      raise exception 'FAIL: index % does not cover (vineyard_id, created_at, id): %', rec.index_name, v_def;
    end if;

    raise notice 'PASS: % on public.% — %', rec.index_name, rec.table_name, v_def;
  end loop;

  raise notice 'PASS: all 9 Stage 3C API support indexes verified';
end $$;
