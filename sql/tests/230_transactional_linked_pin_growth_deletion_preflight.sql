-- Read-only preflight for migration 230. Safe to run before applying it.
-- Returns counts only; it never changes production data.
select
  count(*) filter (where g.pin_id is null) as standalone_growth_records,
  count(*) filter (where g.pin_id is not null and p.id is not null) as linked_growth_records,
  count(*) filter (where g.pin_id is not null and p.id is null) as growth_records_with_missing_pin,
  count(*) filter (where p.id is not null and p.vineyard_id <> g.vineyard_id) as cross_vineyard_links,
  count(*) filter (where p.deleted_at is null and g.deleted_at is not null) as active_pin_deleted_growth,
  count(*) filter (where p.deleted_at is not null and g.deleted_at is null) as deleted_pin_active_growth
from public.growth_stage_records g
left join public.pins p on p.id = g.pin_id;

select
  count(*) as active_legacy_growth_pins_without_any_mirror
from public.pins p
where p.deleted_at is null
  and p.growth_stage_code is not null
  and not exists (
    select 1 from public.growth_stage_records g where g.pin_id = p.id
  );

select
  to_regprocedure('public.soft_delete_pin(uuid)') as existing_pin_delete,
  to_regprocedure('public.soft_delete_growth_stage_record(uuid)') as existing_growth_delete,
  to_regclass('public.v_growth_stage_observations') as compatibility_view;
