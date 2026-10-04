-- LOCAL disposable fixture only. Execute through scripts/test_chemical_inventory_permissions.py.
begin;
do $$ begin
  if current_database()<>'inventory_contract_test' or inet_server_addr() is not null
    or current_setting('request.inventory_contract_runner',true) is distinct from 'local-fixture' then
    raise exception 'Use the Python runner in the disposable local inventory_contract_test database';
  end if;
end $$;
do $tests$
declare
  vineyard uuid := gen_random_uuid(); other_vineyard uuid := gen_random_uuid();
  chemical uuid := gen_random_uuid(); other uuid := gen_random_uuid();
  owner_id uuid := gen_random_uuid(); manager_id uuid := gen_random_uuid();
  supervisor_id uuid := gen_random_uuid(); operator_id uuid := gen_random_uuid(); admin_id uuid := gen_random_uuid();
  legacy_id uuid; new_id uuid; duplicate_id uuid; actor uuid; actor_role text; operation text;
  r record; n integer; original jsonb; actual jsonb; physical jsonb; financial jsonb; before_count integer;
  summary_costs text[] := array['latest_unit_cost','currency','estimated_stock_value'];
  history_costs text[] := array['total_cost','currency','unit_cost','display_cost_unit'];
begin
  begin
    insert into public.saved_chemicals(id,vineyard_id,product_form) values(chemical,vineyard,'liquid');
    raise exception 'Missing vineyard FK';
  exception when foreign_key_violation then null; end;
  insert into public.vineyards(id,name) values(vineyard,'Inventory Contract Test'),(other_vineyard,'Inventory Contract Other');
  insert into public.saved_chemicals(id,vineyard_id,product_form) values(chemical,vineyard,'liquid'),(other,other_vineyard,'liquid');
  insert into public.vineyard_members values(vineyard,owner_id,'owner'),(vineyard,manager_id,'manager'),
    (vineyard,supervisor_id,'supervisor'),(vineyard,operator_id,'operator');
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  legacy_id := public.chemical_inventory_record_purchase_v2(chemical,'2026-04-10',2,20,'L',100);
  select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=legacy_id;
  if r.batch_date is not null or r.serial_number is not null or r.quantity<>40 or r.unit_cost<>2.5 then
    raise exception 'Legacy payload/NULL/container/cost regression'; end if;
  raise notice 'PASS 1: real vineyard FK, old V2 purchase payload and NULL traceability/container maths';
  new_id := public.chemical_inventory_record_purchase_v2(chemical,'2026-04-11',2,20,'L',100,' aud ',' LOT-A ',' Supplier ',' Invoice ','2027-12-01',' notes ','2025-12-01',' SN-A/007 ');
  duplicate_id := public.chemical_inventory_record_purchase_v2(chemical,'2026-04-10',2,20,'L',100,'AUD','LOT-A',null,null,null,null,null,'  ');
  select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=new_id;
  if r.batch_number<>'LOT-A' or r.batch_date<>'2025-12-01'::date or r.serial_number<>'SN-A/007'
    or r.supplier<>'Supplier' or r.expiry_date<>'2027-12-01'::date or r.currency<>'AUD' then raise exception 'Traceability roundtrip'; end if;
  select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=duplicate_id;
  if r.batch_date is not null or r.serial_number is not null then raise exception 'Nullable traceability changed'; end if;
  select count(*) into n from public.chemical_inventory_purchase_history_v2(chemical);
  if n<>3 or new_id=duplicate_id then raise exception 'Purchase rows merged'; end if;
  raise notice 'PASS 2: Batch/Lot, batch date, serial, supplier, expiry roundtrip; blank serial NULL; distinct rows';

  -- Both untracked and tracked summary branches must redact without changing physical data.
  for n in 1..2 loop
    perform set_config('request.jwt.claim.sub',owner_id::text,true);
    if n=2 then perform public.chemical_inventory_record_stocktake_v2(chemical,12,'L','opening_stock',1,20,'L',null,now()-interval '1 day'); end if;
    select to_jsonb(s) into original from public.inventory_test_original_chemical_inventory_summary(chemical) s;
    foreach actor in array array[owner_id,manager_id,supervisor_id,operator_id] loop
      perform set_config('request.jwt.claim.sub',actor::text,true);
      select role into actor_role from public.vineyard_members where user_id=actor;
      select to_jsonb(s) into actual from public.chemical_inventory_summary(chemical) s;
      if actor_role in ('owner','manager') then
        if actual is distinct from original or actual->>'latest_unit_cost' is null or actual->>'currency' is null then raise exception 'Manager financial summary changed'; end if;
        if n=2 and (actual->>'estimated_stock_value')::numeric<>330 then raise exception 'Stock value maths changed'; end if;
      else
        if actual->>'latest_unit_cost' is not null or actual->>'currency' is not null or actual->>'estimated_stock_value' is not null then raise exception 'Summary financial leak for %',actor_role; end if;
        if (actual-summary_costs) is distinct from (original-summary_costs) then raise exception 'Physical summary changed'; end if;
        if actual->>'latest_batch_number'<>'LOT-A' or actual->>'latest_serial_number'<>'SN-A/007' then raise exception 'Traceability missing'; end if;
      end if;
    end loop;
  end loop;
  raise notice 'PASS 3: Owner/Manager complete summary; Supervisor/Operator NULL costs, identical stock/status/traceability (both branches)';

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  select jsonb_agg(to_jsonb(h) order by purchase_id) into original from public.inventory_test_original_chemical_inventory_purchase_history_v2(chemical) h;
  foreach actor in array array[owner_id,manager_id,supervisor_id,operator_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);
    select role into actor_role from public.vineyard_members where user_id=actor;
    select jsonb_agg(to_jsonb(h) order by purchase_id) into actual from public.chemical_inventory_purchase_history_v2(chemical) h;
    if actor_role in ('owner','manager') then
      if actual is distinct from original then raise exception 'Owner/Manager history changed'; end if;
    else
      for r in select value row from jsonb_array_elements(actual) loop
        if r.row->>'total_cost' is not null or r.row->>'currency' is not null or r.row->>'unit_cost' is not null or r.row->>'display_cost_unit' is not null then raise exception 'History cost leak'; end if;
      end loop;
      select jsonb_agg(value-history_costs order by value->>'purchase_id') into physical from jsonb_array_elements(actual);
      select jsonb_agg(value-history_costs order by value->>'purchase_id') into financial from jsonb_array_elements(original);
      if physical is distinct from financial then raise exception 'Physical history changed'; end if;
      for r in select * from public.chemical_inventory_purchase_history(chemical) loop
        if r.total_cost is not null or r.currency is not null or r.unit_cost is not null or r.display_cost_unit is not null then raise exception 'Legacy history leak'; end if;
      end loop;
    end if;
  end loop;
  raise notice 'PASS 4: both history RPCs server-redact financials; V2 physical/traceability rows and identities unchanged';

  perform set_config('request.jwt.claim.sub',supervisor_id::text,true);
  perform public.chemical_inventory_record_purchase_v2(chemical,'2026-04-09',1,20,'L',50);
  perform public.chemical_inventory_record_purchase(chemical,'2026-04-08',20,'L',50);
  select count(*) into before_count from public.chemical_inventory_purchase_history_v2(chemical);
  raise notice 'PASS 5: Supervisor can record V2 and released legacy purchases';
  foreach actor in array array[supervisor_id,operator_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);
    foreach operation in array array[
      'select public.chemical_inventory_record_stocktake($1,0,''L'')',
      'select public.chemical_inventory_record_stocktake_v2($1,0,''L'')',
      'select public.chemical_inventory_mark_finished($1)',
      'select public.chemical_inventory_set_settings($1)'
    ] loop
      begin execute operation using chemical; raise exception 'Unauthorized management succeeded';
      exception when insufficient_privilege then null; end;
    end loop;
    if actor=operator_id then
      begin perform public.chemical_inventory_record_purchase_v2(chemical,'2026-04-10',1,20,'L',50); raise exception 'Operator V2 purchase succeeded'; exception when insufficient_privilege then null; end;
      begin perform public.chemical_inventory_record_purchase(chemical,'2026-04-10',20,'L',50); raise exception 'Operator legacy purchase succeeded'; exception when insufficient_privilege then null; end;
    end if;
  end loop;
  raise notice 'PASS 6: Operator cannot purchase; Supervisor/Operator denied stocktake, opening/correction, finished and settings';
  foreach actor in array array[owner_id,manager_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);
    perform public.chemical_inventory_record_stocktake(chemical,20,'L');
    perform public.chemical_inventory_record_stocktake_v2(chemical,20,'L');
    perform public.chemical_inventory_set_settings(chemical,true,null,null,20);
    perform public.chemical_inventory_mark_finished(chemical);
    select count(*) into n from public.chemical_inventory_purchase_history_v2(chemical);
    if n<>before_count then raise exception 'History removed by management'; end if;
    select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=new_id;
    if r.serial_number<>'SN-A/007' or r.batch_date<>'2025-12-01'::date then raise exception 'History rewritten'; end if;
  end loop;
  raise notice 'PASS 7: Owner/Manager management succeeds; Mark Finished preserves every purchase and metadata';

  foreach actor in array array[owner_id,manager_id,supervisor_id,operator_id,admin_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);
    perform set_config('request.test_admin','true',true);
    foreach operation in array array[
      'select public.chemical_inventory_summary($1)',
      'select public.chemical_inventory_purchase_history_v2($1)',
      'select public.chemical_inventory_purchase_history($1)',
      'select public.chemical_inventory_record_purchase_v2($1,''2026-04-10'',1,20,''L'',50)'
    ] loop
      begin execute operation using other; raise exception 'Wrong vineyard permitted'; exception when insufficient_privilege then null; end;
      if actor=admin_id then
        begin execute operation using chemical; raise exception 'Admin-only access permitted'; exception when insufficient_privilege then null; end;
      end if;
    end loop;
  end loop;
  perform set_config('request.jwt.claim.sub','',true);
  begin perform public.chemical_inventory_summary(chemical); raise exception 'Anonymous reader'; exception when insufficient_privilege then null; end;
  raise notice 'PASS 8: cross-vineyard, nonmember System Admin and unauthenticated reads/writes rejected';

  -- Run actual SELECT as authenticated so superuser cannot conceal an RLS leak.
  foreach actor in array array[supervisor_id,operator_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);
    execute 'set local role authenticated';
    select count(*) into n from public.chemical_inventory_purchases;
    if n<>0 then raise exception 'Raw purchase RLS exposes costs'; end if;
    select count(*) into n from public.chemical_inventory_stocktakes;
    if n<>0 then raise exception 'Raw stocktake RLS widened'; end if;
    select * into r from public.chemical_inventory_summary(chemical);
    if r.latest_unit_cost is not null or r.estimated_stock_value is not null or r.currency is not null then raise exception 'Authenticated RPC financial leak'; end if;
    begin perform inventory_private.chemical_inventory_summary(chemical); raise exception 'Private bypass'; exception when insufficient_privilege then null; end;
    execute 'reset role';
  end loop;
  raise notice 'PASS 9: authenticated member RPC works; raw table and private implementation access blocked';
  if exists(select 1 from inventory_test_signatures old join pg_proc p on p.proname=old.proname join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and (old.args<>pg_get_function_arguments(p.oid) or old.result<>pg_get_function_result(p.oid))) then raise exception 'Public RPC signature changed'; end if;
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='public' and p.proname='chemical_inventory_record_purchase_v2';
  if n<>1 then raise exception 'Purchase overload introduced'; end if;
  raise notice 'PASS 10: public RPC argument/return contracts unchanged; one V2 overload; repeat SQL 262 application succeeds';
end;
$tests$;
rollback;
