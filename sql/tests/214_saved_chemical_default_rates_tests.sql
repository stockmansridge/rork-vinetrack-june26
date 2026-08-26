-- Tests for sql/214 — shared operational default-rate persistence.
--
-- ROLLBACK ONLY. Everything runs inside one transaction that ends in
-- `rollback`, so this is safe to run against production before the migration
-- is approved. It seeds its own rows and asserts on those.
--
-- RUN ORDER
--   sql/214_saved_chemical_default_rates.sql            (the migration)
--   sql/tests/214_saved_chemical_default_rates_tests.sql (this file)
--
-- WHAT THESE TESTS ARE PROTECTING
--
-- Two things, and they pull in opposite directions.
--
-- First, that the column is genuinely OPTIONAL: a Saved Chemical that has
-- never recorded a default must remain completely normal — readable, writable,
-- and never rewritten by this migration. The no-backfill assertion (T4) is the
-- important one. If a future edit ever adds an `update ... set default_rates =`
-- derived from `rate_per_ha`, that test fails, which is exactly the accident
-- worth catching: the derived value would look chosen, and nobody downstream
-- could tell it never was.
--
-- Second, that adding it changed NOTHING about who can reach `saved_chemicals`
-- (T7-T9). A preference column that quietly altered access to the Chemical
-- Store would be a far worse defect than anything it enables.

begin;

do $$
declare
  v_vineyard  uuid := '00000000-0000-4000-8000-0000d3000001';
  v_legacy    uuid := '00000000-0000-4000-8000-0000d3000002';
  v_defaulted uuid := '00000000-0000-4000-8000-0000d3000003';
  v_count     integer;
  v_type      text;
  v_nullable  text;
  v_value     jsonb;
  v_policies  integer;
  v_policies2 integer;
  v_ok        boolean;
  v_default_rates_v1 jsonb := jsonb_build_object(
    'version', 1,
    'per_hectare', null,
    'per_100_litres', jsonb_build_object(
      'option_key', 'default_option_v1_0123456789abcdef0123456789abcdef',
      'rate_ids', jsonb_build_array(
        'rate_v1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'rate_v1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      ),
      'basis', 'per_100_litres',
      'unit', 'L',
      'value', 3,
      'min_value', null,
      'max_value', null,
      'source', 'operator',
      'selected_at', '2026-08-26T00:00:00Z',
      'label_version', null
    )
  );
begin

  -- =====================================================================
  -- T1. The column exists, is jsonb, and is nullable
  --
  -- Nullable with no DEFAULT is the whole semantic: "no default recorded" has
  -- to be a state the database can hold. A `default '{}'::jsonb` would make
  -- every row assert an empty contract it never agreed to.
  -- =====================================================================
  select data_type, is_nullable
    into v_type, v_nullable
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'saved_chemicals'
     and column_name = 'default_rates';

  if v_type is null then
    raise exception 'T1 FAILED: saved_chemicals.default_rates is missing';
  end if;
  if v_type <> 'jsonb' then
    raise exception 'T1 FAILED: default_rates must be jsonb, found %', v_type;
  end if;
  if v_nullable <> 'YES' then
    raise exception 'T1 FAILED: default_rates must be nullable';
  end if;

  select count(*) into v_count
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'saved_chemicals'
     and column_name = 'default_rates'
     and column_default is not null;
  if v_count <> 0 then
    raise exception 'T1 FAILED: default_rates must have no column default';
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. Seed: a legacy chemical, exactly the shape that must NOT be mined
  --
  -- A real operator rate and a populated legacy `rates` array. This is the
  -- data a backfill would have looked tempting against.
  -- =====================================================================
  insert into public.vineyards (id, name)
       values (v_vineyard, 'D3 Test Vineyard')
  on conflict (id) do nothing;

  insert into public.saved_chemicals (
    id, vineyard_id, name, rate_per_ha, unit, rates, client_updated_at
  ) values (
    v_legacy, v_vineyard, 'D3 Legacy Product', 2.5, 'Litres',
    jsonb_build_array(
      jsonb_build_object('label', 'Standard',      'value', 2.5, 'basis', 'per_hectare'),
      jsonb_build_object('label', 'High pressure', 'value', 3.5, 'basis', 'per_hectare')
    ),
    now()
  );
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3. Existing rows are readable and untouched
  -- =====================================================================
  select rate_per_ha is not distinct from 2.5
     and jsonb_array_length(rates) = 2
    into v_ok
    from public.saved_chemicals
   where id = v_legacy;

  if not coalesce(v_ok, false) then
    raise exception 'T3 FAILED: legacy chemistry was altered by the migration';
  end if;
  raise notice 'T3 passed';

  -- =====================================================================
  -- T4. NO BACKFILL — the mandatory assertion
  --
  -- rate_per_ha > 0 and rates populated, yet default_rates stays NULL. If
  -- this ever fails, something is synthesising an operator choice that was
  -- never made.
  -- =====================================================================
  select default_rates into v_value
    from public.saved_chemicals
   where id = v_legacy;

  if v_value is not null then
    raise exception 'T4 FAILED: default_rates was backfilled to %', v_value;
  end if;

  -- And no PRE-EXISTING row anywhere carries a value either.
  select count(*) into v_count
    from public.saved_chemicals
   where default_rates is not null;
  if v_count <> 0 then
    raise exception 'T4 FAILED: % existing rows already carry default_rates', v_count;
  end if;
  raise notice 'T4 passed';

  -- =====================================================================
  -- T5. A v1 contract round-trips unchanged
  --
  -- Including the two rate_ids that make VICOL work. The database stores the
  -- array verbatim; it does not collapse, reorder or reinterpret it.
  -- =====================================================================
  insert into public.saved_chemicals (
    id, vineyard_id, name, unit, default_rates, client_updated_at
  ) values (
    v_defaulted, v_vineyard, 'D3 Defaulted Product', 'Litres',
    v_default_rates_v1, now()
  );

  select default_rates into v_value
    from public.saved_chemicals
   where id = v_defaulted;

  if v_value is distinct from v_default_rates_v1 then
    raise exception 'T5 FAILED: default_rates did not round-trip: %', v_value;
  end if;
  if jsonb_array_length(v_value -> 'per_100_litres' -> 'rate_ids') <> 2 then
    raise exception 'T5 FAILED: both supporting rate_ids must survive';
  end if;
  if (v_value -> 'per_hectare') <> 'null'::jsonb then
    raise exception 'T5 FAILED: the unselected basis must stay null';
  end if;
  raise notice 'T5 passed';

  -- =====================================================================
  -- T6. The shape guard accepts objects and NULL, rejects everything else
  --
  -- Conservative on purpose: an array or scalar is not a contract in ANY
  -- version, so refusing it costs no forward compatibility. Detailed v1
  -- semantics belong to the shared application validator, not to a CHECK
  -- that would freeze the contract in the hardest place to change.
  -- =====================================================================
  begin
    update public.saved_chemicals set default_rates = '[]'::jsonb where id = v_defaulted;
    raise exception 'T6 FAILED: a JSON array was accepted';
  exception
    when check_violation then null;
  end;

  begin
    update public.saved_chemicals set default_rates = '3'::jsonb where id = v_defaulted;
    raise exception 'T6 FAILED: a JSON number was accepted';
  exception
    when check_violation then null;
  end;

  -- NULL is always allowed: clearing a default is a normal operator action.
  update public.saved_chemicals set default_rates = null where id = v_defaulted;
  update public.saved_chemicals set default_rates = v_default_rates_v1 where id = v_defaulted;

  -- A FUTURE version object is accepted by the database. Rejecting it here
  -- would stop a newer client writing its own contract into a column this
  -- migration does not own the semantics of.
  update public.saved_chemicals
     set default_rates = jsonb_build_object('version', 2)
   where id = v_defaulted;
  update public.saved_chemicals set default_rates = v_default_rates_v1 where id = v_defaulted;
  raise notice 'T6 passed';

  -- =====================================================================
  -- T7. RLS is still enabled and NO new policy was added
  --
  -- The column must ride on the table's existing access rules. A policy
  -- mentioning default_rates would mean this migration invented an access
  -- path of its own.
  -- =====================================================================
  select relrowsecurity into v_ok
    from pg_class
   where oid = 'public.saved_chemicals'::regclass;
  if not coalesce(v_ok, false) then
    raise exception 'T7 FAILED: RLS is no longer enabled on saved_chemicals';
  end if;

  select count(*) into v_count
    from pg_policies
   where schemaname = 'public'
     and tablename = 'saved_chemicals'
     and (coalesce(qual, '') ilike '%default_rates%'
       or coalesce(with_check, '') ilike '%default_rates%'
       or policyname ilike '%default_rate%');
  if v_count <> 0 then
    raise exception 'T7 FAILED: % policies reference default_rates', v_count;
  end if;
  raise notice 'T7 passed';

  -- =====================================================================
  -- T8. Column privileges match an existing column exactly
  --
  -- `rate_per_ha` is the comparison because it is the ordinary, long-standing
  -- operator-owned column on this table. If default_rates is reachable by the
  -- same grantees with the same privileges, then no role gained or lost
  -- anything, and no service-role-only dependency was introduced.
  -- =====================================================================
  select count(*) into v_count
    from (
      select grantee, privilege_type
        from information_schema.column_privileges
       where table_schema = 'public'
         and table_name = 'saved_chemicals'
         and column_name = 'default_rates'
      except
      select grantee, privilege_type
        from information_schema.column_privileges
       where table_schema = 'public'
         and table_name = 'saved_chemicals'
         and column_name = 'rate_per_ha'
    ) extra;
  if v_count <> 0 then
    raise exception 'T8 FAILED: default_rates has % privileges rate_per_ha lacks', v_count;
  end if;

  select count(*) into v_count
    from (
      select grantee, privilege_type
        from information_schema.column_privileges
       where table_schema = 'public'
         and table_name = 'saved_chemicals'
         and column_name = 'rate_per_ha'
      except
      select grantee, privilege_type
        from information_schema.column_privileges
       where table_schema = 'public'
         and table_name = 'saved_chemicals'
         and column_name = 'default_rates'
    ) missing;
  if v_count <> 0 then
    raise exception 'T8 FAILED: default_rates is missing % privileges', v_count;
  end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T9. No trigger and no index were added for this column
  --
  -- A trigger could rewrite an operator's choice; an index would cost every
  -- write for a value that is only ever read alongside its own row.
  -- =====================================================================
  select count(*) into v_count
    from pg_indexes
   where schemaname = 'public'
     and tablename = 'saved_chemicals'
     and indexdef ilike '%default_rates%';
  if v_count <> 0 then
    raise exception 'T9 FAILED: an index on default_rates was created';
  end if;

  select count(*) into v_count
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
   where t.tgrelid = 'public.saved_chemicals'::regclass
     and not t.tgisinternal
     and pg_get_functiondef(p.oid) ilike '%default_rates%';
  if v_count <> 0 then
    raise exception 'T9 FAILED: a trigger writes default_rates';
  end if;
  raise notice 'T9 passed';

  -- =====================================================================
  -- T10. Writing a default does not disturb the legacy projections
  --
  -- `rate_per_ha` and `rates` remain compatibility projections. Recording a
  -- default must not touch them, and clearing a default must not touch them
  -- either — otherwise an operator changing a preference would silently
  -- restate the product.
  -- =====================================================================
  update public.saved_chemicals
     set default_rates = v_default_rates_v1
   where id = v_legacy;

  select rate_per_ha is not distinct from 2.5
     and jsonb_array_length(rates) = 2
    into v_ok
    from public.saved_chemicals
   where id = v_legacy;
  if not coalesce(v_ok, false) then
    raise exception 'T10 FAILED: writing default_rates altered legacy values';
  end if;

  update public.saved_chemicals set default_rates = null where id = v_legacy;

  select rate_per_ha is not distinct from 2.5
     and jsonb_array_length(rates) = 2
     and default_rates is null
    into v_ok
    from public.saved_chemicals
   where id = v_legacy;
  if not coalesce(v_ok, false) then
    raise exception 'T10 FAILED: clearing default_rates altered legacy values';
  end if;
  raise notice 'T10 passed';

  -- =====================================================================
  -- T11. The two basis slots are independent
  --
  -- Recording a per-hectare default must not create, alter or remove the
  -- per-100 L one. There is no conversion between them: that needs a water
  -- volume belonging to the job, not to the product.
  -- =====================================================================
  update public.saved_chemicals
     set default_rates = jsonb_set(
       v_default_rates_v1,
       '{per_hectare}',
       jsonb_build_object(
         'option_key', 'default_option_v1_fedcba9876543210fedcba9876543210',
         'rate_ids', jsonb_build_array('rate_v1_cccccccccccccccccccccccccccccccc'),
         'basis', 'per_hectare',
         'unit', 'L',
         'value', 8,
         'min_value', null,
         'max_value', null,
         'source', 'operator',
         'selected_at', null,
         'label_version', null
       )
     )
   where id = v_defaulted;

  select default_rates into v_value
    from public.saved_chemicals
   where id = v_defaulted;

  if (v_value -> 'per_100_litres' ->> 'value') <> '3' then
    raise exception 'T11 FAILED: the per-100 L default changed when per-ha was set';
  end if;
  if (v_value -> 'per_hectare' ->> 'value') <> '8' then
    raise exception 'T11 FAILED: the per-ha default was not stored';
  end if;
  if (v_value -> 'per_hectare' ->> 'option_key')
     = (v_value -> 'per_100_litres' ->> 'option_key') then
    raise exception 'T11 FAILED: the two bases must have independent option keys';
  end if;

  -- Clearing one leaves the other exactly as it was.
  update public.saved_chemicals
     set default_rates = jsonb_set(default_rates, '{per_hectare}', 'null'::jsonb)
   where id = v_defaulted;

  select default_rates into v_value
    from public.saved_chemicals
   where id = v_defaulted;
  if (v_value -> 'per_hectare') <> 'null'::jsonb then
    raise exception 'T11 FAILED: per-ha default was not cleared';
  end if;
  if (v_value -> 'per_100_litres' ->> 'value') <> '3' then
    raise exception 'T11 FAILED: clearing per-ha disturbed the per-100 L default';
  end if;
  raise notice 'T11 passed';

  -- =====================================================================
  -- T12. Historical spray records are untouched
  --
  -- A default is a preference about FUTURE work. Nothing about it may restate
  -- what was actually applied.
  -- =====================================================================
  select count(*) into v_count
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('spray_records', 'spray_jobs')
     and column_name = 'default_rates';
  if v_count <> 0 then
    raise exception 'T12 FAILED: default_rates leaked onto spray history';
  end if;
  raise notice 'T12 passed';

  raise notice 'ALL 214 TESTS PASSED';
end $$;

rollback;
