-- LOCAL disposable fixture harness only: scripts/test_chemical_inventory_contract.py.
-- Exercises actual inspected inventory function bodies plus migration, not live data.
begin;
-- The Python runner establishes this marker only after checking its local connection.
do $$
begin
  if current_database() <> 'inventory_contract_test'
    or inet_server_addr() is not null
    or current_setting('request.inventory_contract_runner',true) is distinct from 'local-fixture' then
    raise exception 'Run only through scripts/test_chemical_inventory_contract.py in the disposable local inventory_contract_test database';
  end if;
end;
$$;
do $$
declare
  vineyard uuid := gen_random_uuid(); chemical uuid := gen_random_uuid(); other uuid := gen_random_uuid();
  other_vineyard uuid := gen_random_uuid();
  owner_id uuid := gen_random_uuid(); manager_id uuid := gen_random_uuid();
  supervisor_id uuid := gen_random_uuid(); operator_id uuid := gen_random_uuid(); admin_id uuid := gen_random_uuid();
  legacy_id uuid; new_id uuid; duplicate_id uuid; r record; actor uuid; operation text; n integer;
  before_summary jsonb; after_summary jsonb;
begin
  -- Before creating vineyards, the fixture must reproduce the real FK rejection.
  begin
    insert into public.saved_chemicals(id,vineyard_id,product_form) values (chemical,vineyard,'liquid');
    raise exception 'Fixture allowed a saved chemical with a nonexistent vineyard';
  exception when foreign_key_violation then null; end;
  raise notice 'PASS fixture: nonexistent vineyard rejected by saved_chemicals FK';
  insert into public.vineyards(id,name) values
    (vineyard,'Inventory Contract Test'),(other_vineyard,'Inventory Contract Other');
  insert into public.saved_chemicals(id,vineyard_id,product_form) values
    (chemical,vineyard,'liquid'),(other,other_vineyard,'liquid');
  insert into public.vineyard_members values (vineyard,owner_id,'owner'),(vineyard,manager_id,'manager'),
    (vineyard,supervisor_id,'supervisor'),(vineyard,operator_id,'operator');
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  legacy_id := public.chemical_inventory_record_purchase_v2(chemical,'2026-04-10',2,20,'L',100);
  perform public.chemical_inventory_summary(chemical);
  raise notice 'PASS 1: Owner can read/mutate; released purchase arguments still succeed';
  select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=legacy_id;
  if r.batch_date is not null or r.serial_number is not null or r.quantity<>40 or r.unit_cost<>2.5 then
    raise exception 'Legacy NULL fields or derived purchase maths changed'; end if;
  raise notice 'PASS 2: omitted optional fields are NULL; container quantity and cost unchanged';
  perform set_config('request.jwt.claim.sub',manager_id::text,true);
  new_id := public.chemical_inventory_record_purchase_v2(chemical,'2026-04-11',2,20,'L',100,
    ' aud ',' LOT-A ',' Supplier ',' Invoice ',null,' notes ','2025-12-01',' SN-A/007 ');
  perform public.chemical_inventory_summary(chemical);
  select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=new_id;
  if r.batch_number<>'LOT-A' or r.batch_date<>'2025-12-01'::date or r.serial_number<>'SN-A/007'
    or r.currency<>'AUD' or r.supplier<>'Supplier' or r.invoice_reference<>'Invoice' or r.notes<>'notes' then
    raise exception 'New traceability roundtrip/trim failed'; end if;
  raise notice 'PASS 3: Manager can read/mutate; exact metadata roundtrips; date may predate purchase';
  duplicate_id := public.chemical_inventory_record_purchase_v2(chemical,'2026-04-10',2,20,'L',100,
    'AUD',' LOT-A ',null,null,null,null,null,'  ');
  select count(*) into n from public.chemical_inventory_purchase_history_v2(chemical);
  if n<>3 or duplicate_id=new_id then raise exception 'Purchases merged'; end if;
  select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=duplicate_id;
  if r.batch_date is not null or r.serial_number is not null then raise exception 'Blank serial/null date fabricated'; end if;
  raise notice 'PASS 4: repeated batches remain distinct; explicit NULL and blank serial stored as NULL';
  select * into r from public.chemical_inventory_summary(chemical);
  if r.latest_batch_date<>'2025-12-01'::date or r.latest_serial_number<>'SN-A/007' or r.latest_batch_number<>'LOT-A' then
    raise exception 'Latest purchase projection failed'; end if;
  raise notice 'PASS 5: untracked summary exposes latest metadata without replacing history';

  foreach actor in array array[supervisor_id,operator_id,admin_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);
    perform set_config('request.test_admin',(actor=admin_id)::text,true);
    begin
      perform public.chemical_inventory_record_purchase_v2(chemical,'2026-04-10',1,20,'L',0);
      raise exception 'Unauthorized purchase succeeded';
    exception when insufficient_privilege then null; end;
    begin
      perform public.chemical_inventory_record_stocktake_v2(chemical,0,'L');
      raise exception 'Unauthorized stocktake succeeded';
    exception when insufficient_privilege then null; end;
    begin
      perform public.chemical_inventory_mark_finished(chemical);
      raise exception 'Unauthorized Mark Finished succeeded';
    exception when insufficient_privilege then null; end;
    begin
      perform public.chemical_inventory_set_settings(chemical);
      raise exception 'Unauthorized settings succeeded';
    exception when insufficient_privilege then null; end;
    begin
      perform public.chemical_inventory_record_purchase(chemical,'2026-04-10',1,'L',0);
      raise exception 'Legacy purchase bypass';
    exception when insufficient_privilege then null; end;
    begin
      perform public.chemical_inventory_record_stocktake(chemical,0,'L');
      raise exception 'Legacy stocktake bypass';
    exception when insufficient_privilege then null; end;
  end loop;
  raise notice 'PASS 6: Supervisor, Operator and System Admin without membership denied all mutation paths';
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  begin
    perform public.chemical_inventory_record_purchase_v2(other,'2026-04-10',1,20,'L',0);
    raise exception 'Cross-vineyard purchase succeeded';
  exception when insufficient_privilege then null; end;
  raise notice 'PASS 7: vineyard scope resolved from saved chemical, not caller identity/admin status';

  -- Compare the actual pre-migration and post-migration calculation outputs.
  perform set_config('request.test_admin','true',true);
  perform public.chemical_inventory_record_stocktake_v2(chemical,12,'L','opening_stock',1,20,'L',null,now()-interval '1 day');
  perform public.chemical_inventory_set_settings(chemical,true,null,null,20);
  select to_jsonb(s) into before_summary from public.inventory_test_original_summary(chemical) s;
  select to_jsonb(s)-'latest_batch_date'-'latest_serial_number' into after_summary from public.chemical_inventory_summary(chemical) s;
  if before_summary is distinct from after_summary then raise exception 'Inventory calculations changed: % vs %',before_summary,after_summary; end if;
  if (after_summary->>'current_quantity')::numeric<>132 or (after_summary->>'gross_available_quantity')::numeric<>132 then
    raise exception 'Unexpected physical/container fixture'; end if;
  raise notice 'PASS 8: every existing summary field matches the original live function (container-aware stock/value/threshold)';
  perform public.chemical_inventory_mark_finished(chemical,' audit retained ');
  select count(*) into n from public.chemical_inventory_purchase_history_v2(chemical);
  if n<>3 then raise exception 'Mark Finished removed history'; end if;
  select * into r from public.chemical_inventory_purchase_history_v2(chemical) where purchase_id=new_id;
  if r.serial_number<>'SN-A/007' or r.batch_date<>'2025-12-01'::date then raise exception 'Finished rewrote metadata'; end if;
  raise notice 'PASS 9: Mark Finished preserves all distinct purchase and batch history';
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='chemical_inventory_record_purchase_v2';
  if n<>1 then raise exception 'Ambiguous purchase overload'; end if;
  raise notice 'PASS 10: one purchase_v2 signature after migration and repeat application';
  if has_table_privilege('authenticated','public.chemical_inventory_purchases','DELETE')
    or has_table_privilege('authenticated','public.chemical_inventory_purchases','UPDATE')
    or has_table_privilege('authenticated','public.chemical_inventory_purchases','INSERT') then
    raise exception 'Direct audit-row mutation granted'; end if;
  raise notice 'PASS 11: authenticated purchase writes/deletes restricted to authorized RPCs';
end;
$$;
rollback;
