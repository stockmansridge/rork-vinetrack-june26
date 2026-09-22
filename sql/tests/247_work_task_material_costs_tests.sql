-- sql/247 Work Task Material Costs — rollback-only foundation checks.
-- Run AFTER sql/247_work_task_material_costs.sql in a non-production validation session.
begin;

do $objects$
begin
  if to_regclass('public.material_catalogue') is null
     or to_regclass('public.vineyard_materials') is null
     or to_regclass('public.work_task_materials') is null then
    raise exception 'SQL 247 material tables are missing';
  end if;
  if (select count(*) from public.material_catalogue) <> 18 then
    raise exception 'expected exactly 18 base catalogue rows';
  end if;
  if not exists (
    select 1 from public.material_catalogue
    where key = 'material.trellis.gripple'
      and name = 'Gripple / Wire Joiner-Tensioner'
      and default_unit = 'Each'
  ) then
    raise exception 'Gripple base catalogue row is missing or incorrect';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'work_task_materials'
      and column_name = 'total_cost' and is_generated = 'ALWAYS'
  ) then
    raise exception 'work_task_materials.total_cost is not generated';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'material_catalogue'
      and policyname = 'material_catalogue_select_authenticated'
  ) then
    raise exception 'catalogue read policy missing';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'vineyard_materials'
      and policyname = 'vineyard_materials_select_members'
  ) then
    raise exception 'vineyard library isolation policy missing';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'work_task_materials'
      and policyname = 'work_task_materials_select_members'
  ) then
    raise exception 'task material isolation policy missing';
  end if;
end;
$objects$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at
) values
  ('24700000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'sql247-owner-a@test.local', 'x', now(), now(), now()),
  ('24700000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'sql247-owner-b@test.local', 'x', now(), now(), now());

insert into public.profiles (id, email) values
  ('24700000-0000-4000-8000-000000000001', 'sql247-owner-a@test.local'),
  ('24700000-0000-4000-8000-000000000002', 'sql247-owner-b@test.local')
on conflict (id) do nothing;

insert into public.vineyards (id, name) values
  ('24700000-0000-4000-8000-000000000101', 'SQL 247 Vineyard A'),
  ('24700000-0000-4000-8000-000000000102', 'SQL 247 Vineyard B');

insert into public.vineyard_members (vineyard_id, user_id, role) values
  ('24700000-0000-4000-8000-000000000101', '24700000-0000-4000-8000-000000000001', 'owner'),
  ('24700000-0000-4000-8000-000000000102', '24700000-0000-4000-8000-000000000002', 'owner');

insert into public.work_tasks (id, vineyard_id, task_type, created_by) values
  ('24700000-0000-4000-8000-000000000201', '24700000-0000-4000-8000-000000000101', 'Trellis repair', '24700000-0000-4000-8000-000000000001'),
  ('24700000-0000-4000-8000-000000000202', '24700000-0000-4000-8000-000000000102', 'Trellis repair', '24700000-0000-4000-8000-000000000002');

insert into public.vineyard_materials (
  id, vineyard_id, base_material_id, name, category, unit,
  default_unit_cost, is_custom, created_by
) values
  (
    '24700000-0000-4000-8000-000000000301',
    '24700000-0000-4000-8000-000000000101',
    (select id from public.material_catalogue where key = 'material.trellis.gripple'),
    'Gripple / Wire Joiner-Tensioner', 'Trellis', 'Each', 1.8200, false,
    '24700000-0000-4000-8000-000000000001'
  ),
  (
    '24700000-0000-4000-8000-000000000302',
    '24700000-0000-4000-8000-000000000101',
    null, 'Gripple Plus Medium', 'Trellis', 'Each', 2.1500, true,
    '24700000-0000-4000-8000-000000000001'
  );

insert into public.work_task_materials (
  id, work_task_id, vineyard_id, vineyard_material_id,
  material_name, category, unit, quantity, unit_cost, created_by
) values
  (
    '24700000-0000-4000-8000-000000000401',
    '24700000-0000-4000-8000-000000000201',
    '24700000-0000-4000-8000-000000000101',
    '24700000-0000-4000-8000-000000000302',
    'Gripple Plus Medium', 'Trellis', 'Each', 3, 12.4000,
    '24700000-0000-4000-8000-000000000001'
  ),
  (
    '24700000-0000-4000-8000-000000000402',
    '24700000-0000-4000-8000-000000000201',
    '24700000-0000-4000-8000-000000000101',
    null, 'Trellis Wire', 'Trellis', 'Metre', 42.5, 0.3100,
    '24700000-0000-4000-8000-000000000001'
  );

do $costs$
declare
  v_total numeric;
  v_failed boolean := false;
begin
  select sum(total_cost) into v_total
  from public.work_task_materials
  where work_task_id = '24700000-0000-4000-8000-000000000201';
  if v_total <> 50.38 then
    raise exception 'decimal material total mismatch: %', v_total;
  end if;

  update public.vineyard_materials
     set default_unit_cost = 18.5000, is_active = false
   where id = '24700000-0000-4000-8000-000000000302';
  if not exists (
    select 1 from public.work_task_materials
    where id = '24700000-0000-4000-8000-000000000401'
      and material_name = 'Gripple Plus Medium'
      and unit_cost = 12.4000
      and total_cost = 37.20
  ) then
    raise exception 'library reprice/deactivation changed the historical snapshot';
  end if;

  begin
    insert into public.work_task_materials (
      work_task_id, vineyard_id, material_name, category, unit, quantity, unit_cost
    ) values (
      '24700000-0000-4000-8000-000000000202',
      '24700000-0000-4000-8000-000000000101',
      'Cross-vineyard line', 'Other', 'Each', 1, 1
    );
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'cross-vineyard work task material was accepted';
  end if;
end;
$costs$;

-- Vineyard A's owner sees A's private library and cannot see B's task rows.
set local role authenticated;
select set_config('request.jwt.claim.sub', '24700000-0000-4000-8000-000000000001', true);

do $rls$
begin
  if (select count(*) from public.vineyard_materials) <> 2 then
    raise exception 'Vineyard A owner cannot read own material library';
  end if;
  if exists (
    select 1 from public.work_task_materials
    where vineyard_id = '24700000-0000-4000-8000-000000000102'
  ) then
    raise exception 'Vineyard A owner can read Vineyard B material rows';
  end if;
end;
$rls$;

reset role;
select set_config('request.jwt.claim.sub', '', true);

do $done$
begin
  raise notice 'SQL 247 Work Task Material Costs tests: ALL PASSED';
end;
$done$;

rollback;
