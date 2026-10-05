-- LOCAL/rollback-only focused SQL 263 contracts. Run via
-- python scripts/test_yield_authoritative_vines.py; never run fixtures in production.
create function pg_temp.yield_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Yield contract failed: %', label; end if;
end $$;

create function pg_temp.yield_check(v uuid, b uuid, vines double precision, basis text) returns void
language plpgsql as $$ declare result jsonb; begin
  result := public._pruning_block_estimate(v,b);
  perform pg_temp.yield_assert((result #>> '{inputs,vine_count}')::double precision = vines, 'exact count ' || basis);
  perform pg_temp.yield_assert(result #>> '{inputs,vine_count_basis}' = basis, 'basis ' || basis);
  perform pg_temp.yield_assert(abs((result ->> 'block_base_tonnes')::double precision - vines * 10 * 120 / 1000000) < 1e-9, 'formula uses exact vines');
end $$;

do $tests$
<<tests>>
declare
  v uuid := '26300000-0000-4000-8000-000000000001';
  b uuid := '26300000-0000-4000-8000-000000000002';
  v_current int;
  polygon jsonb := '[{"latitude":-34.5121,"longitude":138.7128},{"latitude":-34.5091,"longitude":138.7128},{"latitude":-34.5091,"longitude":138.7138},{"latitude":-34.5121,"longitude":138.7138}]';
  rows_json jsonb := '[]';
  manual_rows jsonb;
  fallback double precision;
  e jsonb;
  before_history jsonb;
  before_priority jsonb;
  old_pruning uuid;
  old_manual uuid;
  i int;
  length_m double precision;
  lon double precision;
  new_rows jsonb;
begin
  insert into public.vineyards(id,timezone,season_start_month,season_start_day)
    values(v,'Australia/Sydney',7,1);
  v_current := public.resolve_vineyard_vintage_year(v,(now() at time zone 'Australia/Sydney')::date);
  for i in 0..2 loop
    length_m := (array[240.0,252.0,250.0])[i+1];
    lon := 138.7128 + i * 0.000027;
    rows_json := rows_json || jsonb_build_array(jsonb_build_object('number',i+1,
      'startPoint',jsonb_build_object('latitude',-34.5121,'longitude',lon),
      'endPoint',jsonb_build_object('latitude',-34.5121+length_m/111320,'longitude',lon)));
  end loop;
  manual_rows := jsonb_set(rows_json,'{0,vineCountOverride}','158');
  insert into public.paddocks(id,vineyard_id,name,polygon_points,rows,vine_spacing,variety_allocations)
    values(b,v,'Yield fixture',polygon,rows_json,1.5,'[]');
  insert into public.pruning_yield_settings(vineyard_id,paddock_id,vines_per_ha) values(v,b,2200);
  fallback := public._paddock_polygon_area_hectares(polygon) * 2200;

  -- 1: positive block override basis + formula.
  update public.paddocks set vine_count_override=500 where id=b;
  perform pg_temp.yield_check(v,b,500,'block_vine_count_override');
  raise notice 'T1 passed: block override';

  -- 2: row-effective basis, including calculated untouched rows.
  update public.paddocks set vine_count_override=null, rows=manual_rows where id=b;
  perform pg_temp.yield_check(v,b,493,'row_effective_vine_count');
  raise notice 'T2 passed: row-effective basis';

  -- 3: every manual count is used, untouched row rounds 166.67 to 167.
  update public.paddocks set rows=jsonb_set(manual_rows,'{1,vineCountOverride}','150') where id=b;
  perform pg_temp.yield_check(v,b,475,'row_effective_vine_count');
  perform pg_temp.yield_assert(public._yield_row_effective_vine_count(manual_rows,polygon,1.5)=158+168+167,'manual plus untouched rows');
  raise notice 'T3 passed: mixed manual/calculated rows and rounding';

  -- 4: block precedence over rows.
  update public.paddocks set vine_count_override=500 where id=b;
  perform pg_temp.yield_check(v,b,500,'block_vine_count_override');
  raise notice 'T4 passed: block wins over rows';

  -- 5: clearing restores the saved area x density path, not row geometry total.
  update public.paddocks set vine_count_override=null, rows=rows_json where id=b;
  perform pg_temp.yield_check(v,b,fallback,'block_area_x_vines_per_ha');
  perform pg_temp.yield_assert((select vines_per_ha=2200 from public.pruning_yield_settings where paddock_id=b),'saved density is not replaced');
  raise notice 'T5 passed: saved density fallback and clearing';

  -- 6 + 7: persisted source_inputs count/basis exactly match calculation input.
  update public.paddocks set rows=manual_rows where id=b;
  select source_inputs into e from public.season_yield_estimates where paddock_id=b and vintage=v_current and deleted_at is null;
  perform pg_temp.yield_assert((e ->> 'vine_count')::double precision=493,'source_inputs exact count');
  raise notice 'T6 passed: persisted source_inputs.vine_count';
  perform pg_temp.yield_assert(e ->> 'vine_count_basis'='row_effective_vine_count','source_inputs correct basis');
  raise notice 'T7 passed: persisted source_inputs.vine_count_basis';

  -- 8: sync-safe UPDATE trigger refreshes current pruning estimates, including
  -- spacing and untouched row geometry (not just the explicit override field).
  update public.paddocks set rows=jsonb_set(manual_rows,'{0,vineCountOverride}','160') where id=b;
  perform pg_temp.yield_assert((select source_inputs ->> 'vine_count'='495' from public.season_yield_estimates where paddock_id=b and vintage=v_current and deleted_at is null),'row edit triggers refresh');
  update public.paddocks set vine_spacing=2 where id=b;
  -- 160 manual + 126 calculated + 125 calculated.
  perform pg_temp.yield_assert((select (source_inputs ->> 'vine_count')::double precision=411 from public.season_yield_estimates where paddock_id=b and vintage=v_current and deleted_at is null),'spacing edit triggers refresh');
  new_rows := jsonb_set(manual_rows,'{1,endPoint,latitude}',to_jsonb(-34.5121+300.0/111320));
  update public.paddocks set rows=new_rows,vine_spacing=1.5 where id=b;
  perform pg_temp.yield_assert((select (source_inputs ->> 'vine_count')::double precision=525 from public.season_yield_estimates where paddock_id=b and vintage=v_current and deleted_at is null),'geometry edit triggers refresh');
  raise notice 'T8 passed: backend row/spacing/geometry refresh';

  -- 9: both higher-priority sources survive refresh byte-for-byte.
  for i in 1..2 loop
    update public.season_yield_estimates set estimate_source=case when i=1 then 'bunch_count' else 'manual' end,
      base_estimate_tonnes=42,source_inputs='{"vine_count":10000,"historical":true}'
      where paddock_id=b and vintage=v_current and deleted_at is null;
    select to_jsonb(s) into before_priority from public.season_yield_estimates s where paddock_id=b and vintage=v_current and deleted_at is null;
    update public.paddocks set vine_count_override=600+i where id=b;
    select to_jsonb(s) into e from public.season_yield_estimates s where paddock_id=b and vintage=v_current and deleted_at is null;
    perform pg_temp.yield_assert(e=before_priority,'higher priority ' || i || ' is immutable to pruning refresh');
  end loop;
  raise notice 'T9 passed: manual and bunch_count priority protection';

  -- 10: prior-vintage snapshots are untouched, even pruning-calculator rows.
  insert into public.season_yield_estimates(vineyard_id,vintage,paddock_id,planting_group_key,estimate_source,base_estimate_tonnes,source_inputs)
    values(v,v_current-1,b,'old-pruning','pruning_calculator',12,'{"vine_count":10000}') returning id into old_pruning;
  insert into public.season_yield_estimates(vineyard_id,vintage,paddock_id,planting_group_key,estimate_source,base_estimate_tonnes,source_inputs)
    values(v,v_current-2,b,'old-manual','manual',13,'{"vine_count":11000}') returning id into old_manual;
  select jsonb_agg(to_jsonb(s) order by s.id) into before_history from public.season_yield_estimates s where id in(old_pruning,old_manual);
  update public.paddocks set vine_count_override=800 where id=b;
  perform pg_temp.yield_assert((select jsonb_agg(to_jsonb(s) order by s.id)=before_history from public.season_yield_estimates s where id in(old_pruning,old_manual)),'prior vintage immutable');
  raise notice 'T10 passed: historical snapshots untouched';

  -- 11: zero/negative/decimal/out-of-range row overrides are absence.
  update public.paddocks set vine_count_override=0, rows=jsonb_set(rows_json,'{0,vineCountOverride}','0') where id=b;
  perform pg_temp.yield_check(v,b,fallback,'block_area_x_vines_per_ha');
  for e in select x from jsonb_array_elements('[-1,1.5,100001,"bad"]') x loop
    perform pg_temp.yield_assert(public._yield_row_effective_vine_count(jsonb_set(rows_json,'{0,vineCountOverride}',e),polygon,1.5) is null,'invalid row ignored');
  end loop;
  update public.paddocks set vine_count_override=-1,rows=manual_rows where id=b;
  perform pg_temp.yield_check(v,b,493,'row_effective_vine_count');
  raise notice 'T11 passed: validity parity';

  -- 12: missing spacing/geometry contributes nothing, never invents rows.
  perform pg_temp.yield_assert(public._yield_row_effective_vine_count(manual_rows,polygon,0)=158,'manual row survives unavailable spacing');
  perform pg_temp.yield_assert(public._yield_row_effective_vine_count('[{"vineCountOverride":158},{"number":2}]',polygon,1.5)=158,'unmapped row contributes nothing');
  raise notice 'T12 passed: unavailable row behaviour';

  -- 13: updates unrelated to count-driving data do not refresh anything.
  select to_jsonb(s) into before_priority from public.season_yield_estimates s where paddock_id=b and vintage=v_current and deleted_at is null;
  update public.paddocks set name='Renamed fixture' where id=b;
  select to_jsonb(s) into e from public.season_yield_estimates s where paddock_id=b and vintage=v_current and deleted_at is null;
  perform pg_temp.yield_assert(e=before_priority,'unrelated update does not reconcile');
  perform pg_temp.yield_assert((select vine_count_override=-1 from public.paddocks where id=b),'row total never persisted into block override');
  raise notice 'T13 passed: no unrelated refresh or override writeback';

  -- 14: internal helpers stay non-client-callable after replacement/rerun.
  perform pg_temp.yield_assert(not has_function_privilege('authenticated','public._pruning_block_estimate(uuid,uuid)','execute'),'calculator ACL');
  perform pg_temp.yield_assert(not has_function_privilege('anon','public._yield_row_effective_vine_count(jsonb,jsonb,double precision)','execute'),'row resolver ACL');
  perform pg_temp.yield_assert(not has_function_privilege('authenticated','public._refresh_pruning_yield_estimates(uuid,integer)','execute'),'refresh ACL');
  raise notice 'T14 passed: internal ACLs and migration idempotence';
end;
$tests$;
