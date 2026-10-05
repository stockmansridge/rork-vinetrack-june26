-- 265_fertigation_system_admin_preview.sql
--
-- Fertigation development foundation.
--
-- Goals:
--   1. Reuse spray_jobs templates for seasonal Program Steps with
--      operation_type = 'Fertigation'.
--   2. Link a completed irrigation session to one fertigation application.
--   3. Freeze planned + actual product facts separately from the reusable
--      Program Step.
--   4. Keep EVERY fertigation read/write behind System Admin while this feature
--      is under development. Normal users must not even receive fertigation
--      Program Steps through the legacy spray_jobs feed.
--
-- IMPORTANT:
--   - This migration does not change existing spray/irrigation calculations.
--   - Existing irrigation session RPCs remain untouched.
--   - Existing non-fertigation spray_jobs keep their current RLS behaviour.

-- ---------------------------------------------------------------------------
-- 1. Hide/protect Fertigation Program Steps from non-System-Admins.
-- ---------------------------------------------------------------------------

drop policy if exists spray_jobs_fertigation_dev_select_guard on public.spray_jobs;
create policy spray_jobs_fertigation_dev_select_guard
on public.spray_jobs
as restrictive
for select
to authenticated
using (
  coalesce(operation_type, '') <> 'Fertigation'
  or public.is_system_admin()
);

drop policy if exists spray_jobs_fertigation_dev_insert_guard on public.spray_jobs;
create policy spray_jobs_fertigation_dev_insert_guard
on public.spray_jobs
as restrictive
for insert
to authenticated
with check (
  coalesce(operation_type, '') <> 'Fertigation'
  or public.is_system_admin()
);

drop policy if exists spray_jobs_fertigation_dev_update_guard on public.spray_jobs;
create policy spray_jobs_fertigation_dev_update_guard
on public.spray_jobs
as restrictive
for update
to authenticated
using (
  coalesce(operation_type, '') <> 'Fertigation'
  or public.is_system_admin()
)
with check (
  coalesce(operation_type, '') <> 'Fertigation'
  or public.is_system_admin()
);

-- ---------------------------------------------------------------------------
-- 2. Operational fertigation tables.
-- ---------------------------------------------------------------------------

create table if not exists public.fertigation_applications (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  irrigation_session_id uuid not null references public.irrigation_sessions(id) on delete restrict,
  program_step_id uuid null references public.spray_jobs(id) on delete set null,

  -- Frozen Program facts: history never changes when the reusable step changes.
  program_step_name text null,
  growth_stage_code text null,
  notes text null,

  status text not null default 'completed'
    check (status in ('completed', 'reversed')),

  created_at timestamptz not null default now(),
  created_by uuid null references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid null references auth.users(id) on delete set null,
  reversed_at timestamptz null,
  reversed_by uuid null references auth.users(id) on delete set null,

  constraint fertigation_applications_one_per_irrigation_session
    unique (irrigation_session_id)
);

create index if not exists fertigation_applications_vineyard_idx
  on public.fertigation_applications(vineyard_id, created_at desc);

create index if not exists fertigation_applications_program_step_idx
  on public.fertigation_applications(program_step_id)
  where program_step_id is not null;

alter table public.fertigation_applications enable row level security;

create table if not exists public.fertigation_application_products (
  id uuid primary key,
  fertigation_application_id uuid not null
    references public.fertigation_applications(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  saved_chemical_id uuid null references public.saved_chemicals(id) on delete set null,

  -- Frozen product identity + rate/quantity facts.
  product_name text not null,
  product_category text null,
  product_form text null,

  planned_rate numeric null check (planned_rate is null or planned_rate >= 0),
  rate_basis text null
    check (rate_basis is null or rate_basis in (
      'per_hectare',
      'per_vine',
      'per_irrigation_cycle'
    )),
  rate_unit text null,

  planned_quantity numeric null
    check (planned_quantity is null or planned_quantity >= 0),
  actual_quantity numeric null
    check (actual_quantity is null or actual_quantity >= 0),
  quantity_unit text null,

  cost_per_unit numeric null check (cost_per_unit is null or cost_per_unit >= 0),
  product_snapshot jsonb not null default '{}'::jsonb,
  sort_order integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists fertigation_products_application_idx
  on public.fertigation_application_products(fertigation_application_id, sort_order);

create index if not exists fertigation_products_saved_chemical_idx
  on public.fertigation_application_products(saved_chemical_id)
  where saved_chemical_id is not null;

alter table public.fertigation_application_products enable row level security;

-- Deliberately NO direct client table policies during development.
-- Reads/writes are only through the checked RPCs below.

-- ---------------------------------------------------------------------------
-- 3. Shared System-Admin + vineyard-membership guard.
-- ---------------------------------------------------------------------------

create or replace function public._fertigation_require_dev_access(p_vineyard_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'fertigation_access_denied: authentication required'
      using errcode = '42501';
  end if;

  if not public.is_system_admin() then
    raise exception 'fertigation_access_denied: System Admin required during development'
      using errcode = '42501';
  end if;

  if p_vineyard_id is null or not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'fertigation_access_denied: vineyard membership required'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public._fertigation_require_dev_access(uuid)
  from public, anon, authenticated;

create or replace function public.get_fertigation_capabilities(p_vineyard_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_allowed boolean := false;
begin
  v_allowed :=
    auth.uid() is not null
    and public.is_system_admin()
    and p_vineyard_id is not null
    and public.is_vineyard_member(p_vineyard_id);

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'development_gate', 'system_admin',
    'can_view_fertigation', v_allowed,
    'can_manage_fertigation_program', v_allowed,
    'can_record_fertigation', v_allowed,
    'can_edit_fertigation', v_allowed,
    'can_reverse_fertigation', v_allowed
  );
end;
$$;

revoke all on function public.get_fertigation_capabilities(uuid) from public, anon;
grant execute on function public.get_fertigation_capabilities(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Read helpers.
-- ---------------------------------------------------------------------------

create or replace function public.list_fertigation_program_steps(p_vineyard_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._fertigation_require_dev_access(p_vineyard_id);

  return coalesce((
    select jsonb_agg(to_jsonb(j) order by j.growth_stage_code nulls last, j.name, j.id)
    from public.spray_jobs j
    where j.vineyard_id = p_vineyard_id
      and j.is_template = true
      and j.deleted_at is null
      and j.operation_type = 'Fertigation'
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_fertigation_program_steps(uuid) from public, anon;
grant execute on function public.list_fertigation_program_steps(uuid) to authenticated;

create or replace function public.get_irrigation_fertigation(p_irrigation_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vineyard_id uuid;
begin
  select s.vineyard_id into v_vineyard_id
  from public.irrigation_sessions s
  where s.id = p_irrigation_session_id;

  if v_vineyard_id is null then
    raise exception 'fertigation_not_found: irrigation session not found'
      using errcode = 'P0002';
  end if;

  perform public._fertigation_require_dev_access(v_vineyard_id);

  return (
    select to_jsonb(a) || jsonb_build_object(
      'products',
      coalesce((
        select jsonb_agg(to_jsonb(p) order by p.sort_order, p.id)
        from public.fertigation_application_products p
        where p.fertigation_application_id = a.id
      ), '[]'::jsonb)
    )
    from public.fertigation_applications a
    where a.irrigation_session_id = p_irrigation_session_id
  );
end;
$$;

revoke all on function public.get_irrigation_fertigation(uuid) from public, anon;
grant execute on function public.get_irrigation_fertigation(uuid) to authenticated;

create or replace function public.list_fertigation_applications(
  p_vineyard_id uuid,
  p_vintage_year integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._fertigation_require_dev_access(p_vineyard_id);

  return coalesce((
    select jsonb_agg(
      to_jsonb(a)
      || jsonb_build_object(
        'session_date', s.session_date,
        'vintage_year', s.vintage_year,
        'irrigation_system_id', s.irrigation_system_id,
        'valve_id', s.valve_id,
        'total_volume_litres', s.total_volume_litres,
        'duration_minutes', s.duration_minutes,
        'irrigation_status', s.status,
        'products', coalesce((
          select jsonb_agg(to_jsonb(p) order by p.sort_order, p.id)
          from public.fertigation_application_products p
          where p.fertigation_application_id = a.id
        ), '[]'::jsonb)
      )
      order by s.session_date desc, a.created_at desc
    )
    from public.fertigation_applications a
    join public.irrigation_sessions s on s.id = a.irrigation_session_id
    where a.vineyard_id = p_vineyard_id
      and (p_vintage_year is null or s.vintage_year = p_vintage_year)
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_fertigation_applications(uuid, integer) from public, anon;
grant execute on function public.list_fertigation_applications(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Create/update one fertigation application.
--
-- p_products is an array. Each object may contain:
--   id, saved_chemical_id, product_name,
--   planned_rate, rate_basis, rate_unit,
--   planned_quantity, actual_quantity, quantity_unit, cost_per_unit.
--
-- If planned_quantity is omitted, the server derives it where it can:
--   per_hectare         = rate x frozen irrigated hectares
--   per_vine            = rate x frozen serviced vines
--   per_irrigation_cycle = rate
-- ---------------------------------------------------------------------------

create or replace function public.upsert_irrigation_fertigation(
  p_id uuid,
  p_vineyard_id uuid,
  p_irrigation_session_id uuid,
  p_program_step_id uuid default null,
  p_notes text default null,
  p_products jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.irrigation_sessions;
  v_step public.spray_jobs;
  v_app public.fertigation_applications;
  v_item jsonb;
  v_saved public.saved_chemicals;
  v_product_id uuid;
  v_saved_id uuid;
  v_name text;
  v_category text;
  v_form text;
  v_rate numeric;
  v_basis text;
  v_rate_unit text;
  v_planned numeric;
  v_actual numeric;
  v_quantity_unit text;
  v_cost numeric;
  v_area_ha numeric;
  v_vines numeric;
  v_sort integer := 0;
begin
  perform public._fertigation_require_dev_access(p_vineyard_id);

  if p_id is null then
    raise exception 'invalid_id: fertigation application id is required';
  end if;
  if p_irrigation_session_id is null then
    raise exception 'invalid_irrigation_session: irrigation session is required';
  end if;
  if jsonb_typeof(coalesce(p_products, '[]'::jsonb)) <> 'array' then
    raise exception 'invalid_products: products must be a JSON array';
  end if;

  select * into v_session
  from public.irrigation_sessions
  where id = p_irrigation_session_id
    and vineyard_id = p_vineyard_id;

  if not found then
    raise exception 'invalid_irrigation_session: irrigation session does not belong to this vineyard';
  end if;

  if v_session.deleted_at is not null or v_session.status = 'reversed' then
    raise exception 'irrigation_session_reversed: fertigation cannot be attached to a reversed irrigation session';
  end if;

  if p_program_step_id is not null then
    select * into v_step
    from public.spray_jobs
    where id = p_program_step_id
      and vineyard_id = p_vineyard_id
      and is_template = true
      and deleted_at is null
      and operation_type = 'Fertigation';

    if not found then
      raise exception 'invalid_program_step: linked Program Step must be an active Fertigation template in this vineyard';
    end if;
  end if;

  -- Frozen allocation facts from the irrigation session.
  select
    case
      when count(*) > 0 and count(*) filter (where serviced_area_m2 is null) = 0
      then sum(serviced_area_m2) / 10000.0
      else null
    end,
    case
      when count(*) > 0 and count(*) filter (where serviced_vine_count is null) = 0
      then sum(serviced_vine_count)
      else null
    end
  into v_area_ha, v_vines
  from public.irrigation_session_blocks
  where session_id = p_irrigation_session_id;

  insert into public.fertigation_applications (
    id, vineyard_id, irrigation_session_id, program_step_id,
    program_step_name, growth_stage_code, notes,
    status, created_by, updated_by
  )
  values (
    p_id, p_vineyard_id, p_irrigation_session_id, p_program_step_id,
    case when p_program_step_id is null then null else v_step.name end,
    case when p_program_step_id is null then null else v_step.growth_stage_code end,
    p_notes, 'completed', auth.uid(), auth.uid()
  )
  on conflict (irrigation_session_id) do update
  set
    program_step_id = excluded.program_step_id,
    program_step_name = excluded.program_step_name,
    growth_stage_code = excluded.growth_stage_code,
    notes = excluded.notes,
    status = 'completed',
    reversed_at = null,
    reversed_by = null,
    updated_at = now(),
    updated_by = auth.uid()
  returning * into v_app;

  delete from public.fertigation_application_products
  where fertigation_application_id = v_app.id;

  for v_item in
    select value from jsonb_array_elements(coalesce(p_products, '[]'::jsonb))
  loop
    v_sort := v_sort + 1;
    v_product_id := coalesce(nullif(v_item->>'id', '')::uuid, gen_random_uuid());
    v_saved_id := nullif(v_item->>'saved_chemical_id', '')::uuid;
    v_rate := nullif(v_item->>'planned_rate', '')::numeric;
    v_basis := nullif(v_item->>'rate_basis', '');
    v_rate_unit := nullif(v_item->>'rate_unit', '');
    v_planned := nullif(v_item->>'planned_quantity', '')::numeric;
    v_actual := nullif(v_item->>'actual_quantity', '')::numeric;
    v_quantity_unit := nullif(v_item->>'quantity_unit', '');
    v_cost := nullif(v_item->>'cost_per_unit', '')::numeric;

    if v_rate is not null and v_rate < 0 then
      raise exception 'invalid_rate: planned rate cannot be negative';
    end if;
    if v_actual is not null and v_actual < 0 then
      raise exception 'invalid_actual_quantity: actual quantity cannot be negative';
    end if;
    if v_basis is not null and v_basis not in ('per_hectare','per_vine','per_irrigation_cycle') then
      raise exception 'invalid_rate_basis: unsupported fertigation rate basis';
    end if;

    v_name := nullif(trim(coalesce(v_item->>'product_name', '')), '');
    v_category := null;
    v_form := null;
    v_saved := null;

    if v_saved_id is not null then
      select * into v_saved
      from public.saved_chemicals
      where id = v_saved_id
        and vineyard_id = p_vineyard_id
        and deleted_at is null;

      if not found then
        raise exception 'invalid_product: saved chemical does not belong to this vineyard';
      end if;

      v_name := v_saved.name;
      v_category := nullif(v_saved.product_category, '');
      v_form := nullif(v_saved.product_form, '');

      if v_cost is null and v_saved.price_per_pack is not null
         and v_saved.pack_size is not null and v_saved.pack_size > 0 then
        v_cost := v_saved.price_per_pack / v_saved.pack_size;
      end if;
    end if;

    if v_name is null then
      raise exception 'invalid_product: every fertigation product needs a name';
    end if;

    if v_planned is null and v_rate is not null then
      v_planned := case v_basis
        when 'per_hectare' then
          case when v_area_ha is null then null else v_rate * v_area_ha end
        when 'per_vine' then
          case when v_vines is null then null else v_rate * v_vines end
        when 'per_irrigation_cycle' then v_rate
        else null
      end;
    end if;

    if v_quantity_unit is null then
      v_quantity_unit := v_rate_unit;
    end if;

    insert into public.fertigation_application_products (
      id, fertigation_application_id, vineyard_id, saved_chemical_id,
      product_name, product_category, product_form,
      planned_rate, rate_basis, rate_unit,
      planned_quantity, actual_quantity, quantity_unit,
      cost_per_unit, product_snapshot, sort_order
    )
    values (
      v_product_id, v_app.id, p_vineyard_id, v_saved_id,
      v_name, v_category, v_form,
      v_rate, v_basis, v_rate_unit,
      v_planned, v_actual, v_quantity_unit,
      v_cost,
      case when v_saved_id is null then
        jsonb_build_object('product_name', v_name)
      else
        jsonb_build_object(
          'saved_chemical_id', v_saved.id,
          'name', v_saved.name,
          'product_category', v_saved.product_category,
          'product_form', v_saved.product_form,
          'pack_size', v_saved.pack_size,
          'pack_unit', v_saved.pack_unit,
          'price_per_pack', v_saved.price_per_pack,
          'nitrogen_percent', v_saved.nitrogen_percent,
          'phosphorus_percent', v_saved.phosphorus_percent,
          'potassium_percent', v_saved.potassium_percent,
          'analysis_basis', v_saved.analysis_basis
        )
      end,
      v_sort
    );
  end loop;

  return public.get_irrigation_fertigation(p_irrigation_session_id);
end;
$$;

revoke all on function public.upsert_irrigation_fertigation(
  uuid, uuid, uuid, uuid, text, jsonb
) from public, anon;
grant execute on function public.upsert_irrigation_fertigation(
  uuid, uuid, uuid, uuid, text, jsonb
) to authenticated;

create or replace function public.reverse_fertigation_application(
  p_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app public.fertigation_applications;
begin
  select * into v_app
  from public.fertigation_applications
  where id = p_id;

  if not found then
    raise exception 'fertigation_not_found: fertigation application not found'
      using errcode = 'P0002';
  end if;

  perform public._fertigation_require_dev_access(v_app.vineyard_id);

  update public.fertigation_applications
  set
    status = 'reversed',
    notes = case
      when nullif(trim(coalesce(p_reason, '')), '') is null then notes
      when nullif(trim(coalesce(notes, '')), '') is null then trim(p_reason)
      else notes || E'\nReversal: ' || trim(p_reason)
    end,
    reversed_at = now(),
    reversed_by = auth.uid(),
    updated_at = now(),
    updated_by = auth.uid()
  where id = p_id
  returning * into v_app;

  return public.get_irrigation_fertigation(v_app.irrigation_session_id);
end;
$$;

revoke all on function public.reverse_fertigation_application(uuid, text) from public, anon;
grant execute on function public.reverse_fertigation_application(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Keep fertigation status aligned when an irrigation session is reversed.
--    No existing irrigation RPC is modified.
-- ---------------------------------------------------------------------------

create or replace function public._fertigation_follow_irrigation_reversal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (
    (new.status = 'reversed' and old.status is distinct from new.status)
    or (new.deleted_at is not null and old.deleted_at is null)
  ) then
    update public.fertigation_applications
    set
      status = 'reversed',
      reversed_at = coalesce(reversed_at, now()),
      reversed_by = coalesce(reversed_by, new.updated_by),
      updated_at = now(),
      updated_by = coalesce(new.updated_by, updated_by)
    where irrigation_session_id = new.id
      and status <> 'reversed';
  end if;
  return new;
end;
$$;

revoke all on function public._fertigation_follow_irrigation_reversal()
  from public, anon, authenticated;

drop trigger if exists fertigation_follow_irrigation_reversal
  on public.irrigation_sessions;

create trigger fertigation_follow_irrigation_reversal
after update of status, deleted_at
on public.irrigation_sessions
for each row
execute function public._fertigation_follow_irrigation_reversal();

-- ---------------------------------------------------------------------------
-- 7. Security posture.
-- ---------------------------------------------------------------------------

revoke all on table public.fertigation_applications from anon, authenticated;
revoke all on table public.fertigation_application_products from anon, authenticated;

-- SECURITY DEFINER RPCs above are the only authenticated client surface and
-- each one explicitly checks System Admin + vineyard membership.
