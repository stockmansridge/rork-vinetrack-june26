-- Apply manually AFTER SQL 261. Permission/privacy only; no data or calculation changes.
begin;

create or replace function public.chemical_inventory_reader_role(p_saved_chemical_id uuid)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_vineyard uuid; v_role text;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select sc.vineyard_id into v_vineyard from public.saved_chemicals sc
    where sc.id=p_saved_chemical_id and sc.deleted_at is null;
  if v_vineyard is not null then v_role := public.vineyard_role(v_vineyard); end if;
  if v_role is null or v_role not in ('owner','manager','supervisor','operator') then
    raise exception 'Vineyard membership required' using errcode='42501';
  end if;
  return v_role;
end;
$$;
create or replace function public.chemical_inventory_require_purchase_writer(p_saved_chemical_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.chemical_inventory_reader_role(p_saved_chemical_id) not in ('owner','manager','supervisor') then
    raise exception 'Owner, Manager or Supervisor purchase access required' using errcode='42501';
  end if;
end;
$$;
revoke all on function public.chemical_inventory_reader_role(uuid) from public, anon;
revoke all on function public.chemical_inventory_require_purchase_writer(uuid) from public, anon;
grant execute on function public.chemical_inventory_reader_role(uuid) to authenticated;
grant execute on function public.chemical_inventory_require_purchase_writer(uuid) to authenticated;

-- Preserve the inspected SQL-261 read implementations in a non-exposed schema.
-- Public wrappers retain their exact names, argument/return types and column order.
-- Redaction occurs on the server after unchanged physical/cost calculations.
create schema if not exists inventory_private;
revoke all on schema inventory_private from public, anon, authenticated;
do $migration$
declare
  target text; fn record; col record; body text; projection text; private_oid oid;
  financial text[]; expected integer;
begin
  foreach target in array array['chemical_inventory_summary','chemical_inventory_purchase_history','chemical_inventory_purchase_history_v2'] loop
    select count(*) into expected from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target;
    if expected<>1 then raise exception 'Expected exactly one public.% signature',target; end if;
    select p.*, pg_get_functiondef(p.oid) definition, pg_get_function_arguments(p.oid) args,
      pg_get_function_result(p.oid) result, pg_get_function_identity_arguments(p.oid) identity_args
      into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target;
    if fn.args <> 'p_saved_chemical_id uuid' or not fn.prosecdef then raise exception 'Unexpected read RPC contract: %',target; end if;
    private_oid := to_regprocedure(format('inventory_private.%I(uuid)',target));
    if private_oid is null then
      if position('perform public.chemical_inventory_require_manager(p_saved_chemical_id);' in fn.definition)=0 then
        raise exception 'Expected SQL 261 manager guard in %; migration aborted',target;
      end if;
      body := replace(fn.definition,'FUNCTION public.'||target||'(', 'FUNCTION inventory_private.'||target||'(');
      body := replace(body,'perform public.chemical_inventory_require_manager(p_saved_chemical_id);',
        'perform public.chemical_inventory_reader_role(p_saved_chemical_id);');
      execute body;
    elsif position('inventory_private.' in fn.definition)=0 then
      raise exception 'Unexpected existing private implementation for %',target;
    end if;
    execute format('revoke all on function inventory_private.%I(uuid) from public, anon, authenticated',target);
    financial := case when target='chemical_inventory_summary' then
      array['latest_unit_cost','currency','estimated_stock_value'] else
      array['total_cost','currency','unit_cost','display_cost_unit'] end;
    projection := '';
    expected := 0;
    for col in select fn.proargnames[i] name, format_type(fn.proallargtypes[i],null) type
      from generate_subscripts(fn.proallargtypes,1) i where fn.proargmodes[i]='t' loop
      if projection<>'' then projection := projection||', '; end if;
      if col.name=any(financial) then
        expected := expected+1;
        projection := projection||format('case when v_costs then r.%I else null::%s end',col.name,col.type);
      else
        -- Fail closed if a future return field adds a financial value not reviewed here.
        if col.name ~ '(cost|currency|value|price)' then raise exception 'Unreviewed financial output: %.%',target,col.name; end if;
        projection := projection||format('r.%I',col.name);
      end if;
    end loop;
    if expected<>cardinality(financial) or projection='' then raise exception 'Read projection drift in %',target; end if;
    execute format('create or replace function public.%I(%s) returns %s language plpgsql security definer set search_path=public,pg_temp as $wrapper$ declare v_costs boolean; begin v_costs := public.chemical_inventory_reader_role(p_saved_chemical_id) in (''owner'',''manager''); return query select %s from inventory_private.%I(p_saved_chemical_id) r; end; $wrapper$',
      target,fn.args,fn.result,projection,target);
    execute format('revoke all on function public.%I(uuid) from public, anon',target);
    execute format('grant execute on function public.%I(uuid) to authenticated',target);
  end loop;

  -- Released legacy purchase clients receive the same writer rule. No overloads added.
  foreach target in array array['chemical_inventory_record_purchase','chemical_inventory_record_purchase_v2'] loop
    select count(*) into expected from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target;
    if expected<>1 then raise exception 'Expected exactly one purchase signature: %',target; end if;
    select pg_get_functiondef(p.oid) definition, pg_get_function_identity_arguments(p.oid) identity_args
      into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target;
    if position('perform public.chemical_inventory_require_manager(p_saved_chemical_id);' in fn.definition)>0 then
      execute replace(fn.definition,'perform public.chemical_inventory_require_manager(p_saved_chemical_id);',
        'perform public.chemical_inventory_require_purchase_writer(p_saved_chemical_id);');
    elsif position('perform public.chemical_inventory_require_purchase_writer(p_saved_chemical_id);' in fn.definition)=0 then
      raise exception 'Purchase authorization drift in %',target;
    end if;
    execute format('revoke all on function public.%I(%s) from public, anon',target,fn.identity_args);
    execute format('grant execute on function public.%I(%s) to authenticated',target,fn.identity_args);
  end loop;

  -- Manager helper and all four management routines from SQL 261 stay unchanged.
  foreach target in array array['chemical_inventory_record_stocktake','chemical_inventory_record_stocktake_v2','chemical_inventory_mark_finished','chemical_inventory_set_settings'] loop
    select count(*) into expected from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target
      and position('perform public.chemical_inventory_require_manager(p_saved_chemical_id);' in pg_get_functiondef(p.oid))>0;
    if expected<>1 then raise exception 'Manager authority drift in %',target; end if;
  end loop;
end;
$migration$;
-- Do not widen raw table SELECT/RLS: only Owner/Manager policies from SQL 261 remain.
-- No backfill, row rewrite, DELETE, stock arithmetic or preferred-rate changes.
notify pgrst,'reload schema';
commit;
