-- Jonathan: review and apply manually before shipping these inventory clients.
-- Inspected live 2026-10-04: purchases are public.chemical_inventory_purchases.
-- No equivalent production/manufacture date exists. Existing batch_number is NOT NULL
-- with an empty-string default; preserve that legacy contract. New fields are nullable.
-- This transaction patches the inspected function bodies rather than reimplementing
-- container/cost/stocktake maths. Unexpected schema/body drift aborts the transaction.
begin;

alter table public.chemical_inventory_purchases
  add column if not exists batch_date date,
  add column if not exists serial_number text;
comment on column public.chemical_inventory_purchases.batch_date is
  'Optional manufacturer production/batch date. No inferred value or purchase-date constraint.';
comment on column public.chemical_inventory_purchases.serial_number is
  'Optional manufacturer serial text. Trimmed; blank is NULL. Purchase audit metadata.';
comment on table public.chemical_inventory_purchases is
  'Separate immutable purchase audit rows. Retain certification records for at least five years; zero stock, adjustments and Mark Finished must not delete purchase history.';

-- Scope comes from the saved chemical, never a client-supplied vineyard.
-- Existing vineyard_role/has_vineyard_role membership is the authority. Any support
-- session represented by manager-equivalent membership continues through that rule.
create or replace function public.chemical_inventory_require_manager(p_saved_chemical_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_vineyard uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  select sc.vineyard_id into v_vineyard from public.saved_chemicals sc
    where sc.id=p_saved_chemical_id and sc.deleted_at is null;
  if v_vineyard is null or not public.has_vineyard_role(v_vineyard,array['owner','manager']) then
    raise exception 'Vineyard Owner or Manager access required' using errcode='42501';
  end if;
end;
$$;
revoke all on function public.chemical_inventory_require_manager(uuid) from public, anon;
grant execute on function public.chemical_inventory_require_manager(uuid) to authenticated;

-- One purchase_v2 signature only: append optional parameters and remove the old
-- signature in the same transaction. Released named-argument callers omit them.
-- History/summary return shapes are extended at the END for compatibility.
do $migration$
declare
  fn record;
  body text;
  previous text;
  needle text;
  replacement text;
  target text;
  expected integer;
begin
  foreach target in array array[
    'chemical_inventory_record_purchase','chemical_inventory_record_purchase_v2',
    'chemical_inventory_record_stocktake','chemical_inventory_record_stocktake_v2',
    'chemical_inventory_mark_finished','chemical_inventory_set_settings',
    'chemical_inventory_purchase_history','chemical_inventory_purchase_history_v2',
    'chemical_inventory_summary'
  ] loop
    select count(*) into expected from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target;
    if expected<>1 then raise exception 'Expected one unambiguous public.% function; found %',target,expected; end if;
    select p.oid, pg_get_function_identity_arguments(p.oid) args, pg_get_functiondef(p.oid) definition
      into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target;
    body := fn.definition;
    if body like '%System Admin pilot only%' then
      previous := body;
      body := regexp_replace(body,
        'if (v_user|auth.uid\(\)) is null or not public\.is_system_admin\(\) then[[:space:]]+raise exception ''System Admin pilot only'';[[:space:]]+end if;',
        'perform public.chemical_inventory_require_manager(p_saved_chemical_id);');
      if body=previous then raise exception 'Unrecognized pilot guard in %',target; end if;
    elsif body not like '%perform public.chemical_inventory_require_manager(p_saved_chemical_id);%' then
      raise exception 'Unrecognized authorization in %',target;
    end if;

    if target='chemical_inventory_record_purchase_v2' and body not like '%p_batch_date date DEFAULT%' then
      needle := 'p_notes text DEFAULT NULL::text)';
      if position(needle in body)=0 then raise exception 'Purchase signature drift'; end if;
      body := replace(body,needle,'p_notes text DEFAULT NULL::text, p_batch_date date DEFAULT NULL::date, p_serial_number text DEFAULT NULL::text)');
      needle := 'container_count,container_size,container_unit,capacity_base';
      if position(needle in body)=0 then raise exception 'Purchase insert column drift'; end if;
      body := replace(body,needle,needle||',batch_date,serial_number');
      needle := 'p_container_count,p_container_size,v_unit,v_base';
      if position(needle in body)=0 then raise exception 'Purchase insert value drift'; end if;
      body := replace(body,needle,needle||',p_batch_date,nullif(btrim(p_serial_number),'''')');
      execute format('drop function public.%I(%s)',target,fn.args);
    end if;
    if target in ('chemical_inventory_record_purchase','chemical_inventory_record_purchase_v2') then
      body := replace(body,'upper(p_currency)','upper(btrim(p_currency))');
    end if;

    if target='chemical_inventory_purchase_history_v2' and body not like '%batch_date date, serial_number text)%' then
      needle := 'created_at timestamp with time zone)';
      if position(needle in body)=0 then raise exception 'History return signature drift'; end if;
      body := replace(body,needle,'created_at timestamp with time zone, batch_date date, serial_number text)');
      needle := 'p.expiry_date,p.notes,p.created_at';
      if position(needle in body)=0 then raise exception 'History projection drift'; end if;
      body := replace(body,needle,needle||',p.batch_date,p.serial_number');
      execute format('drop function public.%I(%s)',target,fn.args);
    end if;

    if target='chemical_inventory_summary' and body not like '%latest_batch_date date, latest_serial_number text)%' then
      needle := 'estimated_stock_value numeric)';
      if position(needle in body)=0 then raise exception 'Summary return signature drift'; end if;
      body := replace(body,needle,'estimated_stock_value numeric, latest_batch_date date, latest_serial_number text)');
      needle := E'null::numeric;\n    return;';
      if position(needle in body)=0 then raise exception 'Untracked summary projection drift'; end if;
      body := replace(body,needle,E'null::numeric,\n      v_latest.batch_date,\n      v_latest.serial_number;\n    return;');
      needle := E'end;\nend;\n$function$';
      if position(needle in body)=0 then raise exception 'Tracked summary projection drift'; end if;
      body := replace(body,needle,E'end,\n    v_latest.batch_date,\n    v_latest.serial_number;\nend;\n$function$');
      execute format('drop function public.%I(%s)',target,fn.args);
    end if;

    execute body;
    -- Restate least-privilege grants, including functions recreated above.
    select pg_get_function_identity_arguments(p.oid) into fn.args
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=target;
    execute format('revoke all on function public.%I(%s) from public, anon',target,fn.args);
    execute format('grant execute on function public.%I(%s) to authenticated',target,fn.args);
  end loop;
end;
$migration$;

-- Remove the arbitrary-vineyard System Admin DML bypass. Clients mutate through
-- authorized RPCs only. SELECT policies also resolve scope through saved_chemicals.
drop policy if exists chemical_inventory_purchases_admin on public.chemical_inventory_purchases;
drop policy if exists chemical_inventory_stocktakes_admin on public.chemical_inventory_stocktakes;
drop policy if exists chemical_inventory_settings_admin on public.chemical_inventory_settings;
do $$
declare t text;
begin
  foreach t in array array['chemical_inventory_purchases','chemical_inventory_stocktakes','chemical_inventory_settings'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke insert, update, delete, truncate on public.%I from public, anon, authenticated',t);
    execute format('drop policy if exists inventory_manager_read on public.%I',t);
    execute format('create policy inventory_manager_read on public.%I for select to authenticated using (exists (select 1 from public.saved_chemicals sc where sc.id=saved_chemical_id and public.has_vineyard_role(sc.vineyard_id,array[''owner'',''manager''])))',t);
  end loop;
end;
$$;
-- No purchase UPDATE/DELETE, no backfill, no deduplication, no expiry/retention job.
notify pgrst,'reload schema';
commit;
