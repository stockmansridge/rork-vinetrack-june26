-- =====================================================================
-- 100_maintenance_logs_equipment_link.sql
-- =====================================================================
-- Step 1: migration-safe equipment identity for maintenance_logs.
--
-- Goal: keep the existing item_name display snapshot exactly as-is, while
-- adding optional stable equipment linkage for new and backfilled rows.
--
-- Design / safety guarantees:
--   * Strictly additive. Two NEW nullable columns only:
--       - equipment_source text   (which catalog table the link points at)
--       - equipment_ref_id  uuid  (the linked equipment row id)
--   * item_name is NEVER read-modified. It is preserved verbatim.
--   * No column is made NOT NULL. No RLS change. No rename / drop.
--   * spray_records is untouched.
--   * Fully idempotent and safe to re-run.
--
-- Allowed equipment_source values:
--   vineyard_machine | tractor | spray_equipment | equipment_item | free_text
-- (equipment_ref_id is NULL for free_text and NULL for rows left for review.)
--
-- Backfill matching (per maintenance_logs row, scoped to the SAME vineyard,
-- trimmed + case-insensitive on item_name):
--   priority 1: vineyard_machines.name
--   priority 2: tractors.name OR tractor display name (brand + model)
--   priority 3: spray_equipment.name
--   priority 4: equipment_items.name
-- Only the HIGHEST priority tier that has any match is considered. If that
-- tier has exactly one active match -> link it. If it has more than one ->
-- AMBIGUOUS: leave both columns NULL and surface the row for manual review.
-- If no tier matches at all -> equipment_source = 'free_text', ref_id NULL.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Additive columns + value guard
-- ---------------------------------------------------------------------
alter table public.maintenance_logs
  add column if not exists equipment_source text null;

alter table public.maintenance_logs
  add column if not exists equipment_ref_id uuid null;

comment on column public.maintenance_logs.equipment_source is
  'Optional stable equipment link source: vineyard_machine | tractor | spray_equipment | equipment_item | free_text. NULL = not yet classified. item_name remains the authoritative display snapshot.';
comment on column public.maintenance_logs.equipment_ref_id is
  'Optional id of the linked equipment row in the table named by equipment_source. NULL for free_text or rows awaiting manual review.';

-- Guard the allowed values (NULL still allowed). Idempotent re-add.
alter table public.maintenance_logs
  drop constraint if exists maintenance_logs_equipment_source_check;
alter table public.maintenance_logs
  add constraint maintenance_logs_equipment_source_check
  check (
    equipment_source is null
    or equipment_source in (
      'vineyard_machine', 'tractor', 'spray_equipment', 'equipment_item', 'free_text'
    )
  );

create index if not exists idx_maintenance_logs_equipment_ref
  on public.maintenance_logs (equipment_source, equipment_ref_id);

-- ---------------------------------------------------------------------
-- 2. Backfill (only rows not yet classified and not soft-deleted)
-- ---------------------------------------------------------------------
do $backfill$
declare
  r record;
  v_key text;
  v_id uuid;
  v_count int;
  v_linked int := 0;
  v_free int := 0;
  v_ambiguous int := 0;
begin
  -- collect ambiguous rows for the review report
  create temporary table if not exists tmp_maint_equipment_ambiguous (
    maintenance_log_id uuid,
    vineyard_id uuid,
    item_name text,
    matched_source text,
    match_count int
  ) on commit drop;

  for r in
    select id, vineyard_id, item_name
      from public.maintenance_logs
     where deleted_at is null
       and equipment_source is null
  loop
    v_key := lower(btrim(coalesce(r.item_name, '')));

    -- Empty item_name -> treat as free_text (nothing to match against).
    if v_key = '' then
      update public.maintenance_logs
         set equipment_source = 'free_text'
       where id = r.id;
      v_free := v_free + 1;
      continue;
    end if;

    -- priority 1: vineyard_machines.name
    select count(*) into v_count
      from public.vineyard_machines m
     where m.vineyard_id = r.vineyard_id
       and m.deleted_at is null
       and lower(btrim(coalesce(m.name, ''))) = v_key;
    if v_count > 0 then
      if v_count = 1 then
        select m.id into v_id
          from public.vineyard_machines m
         where m.vineyard_id = r.vineyard_id
           and m.deleted_at is null
           and lower(btrim(coalesce(m.name, ''))) = v_key
         limit 1;
        update public.maintenance_logs
           set equipment_source = 'vineyard_machine', equipment_ref_id = v_id
         where id = r.id;
        v_linked := v_linked + 1;
      else
        insert into tmp_maint_equipment_ambiguous
          values (r.id, r.vineyard_id, r.item_name, 'vineyard_machine', v_count);
        v_ambiguous := v_ambiguous + 1;
      end if;
      continue;
    end if;

    -- priority 2: tractors.name OR tractor display name (brand + model)
    select count(*) into v_count
      from public.tractors t
     where t.vineyard_id = r.vineyard_id
       and t.deleted_at is null
       and (
         lower(btrim(coalesce(t.name, ''))) = v_key
         or lower(btrim(coalesce(t.brand, '') || ' ' || coalesce(t.model, ''))) = v_key
       );
    if v_count > 0 then
      if v_count = 1 then
        select t.id into v_id
          from public.tractors t
         where t.vineyard_id = r.vineyard_id
           and t.deleted_at is null
           and (
             lower(btrim(coalesce(t.name, ''))) = v_key
             or lower(btrim(coalesce(t.brand, '') || ' ' || coalesce(t.model, ''))) = v_key
           )
         limit 1;
        update public.maintenance_logs
           set equipment_source = 'tractor', equipment_ref_id = v_id
         where id = r.id;
        v_linked := v_linked + 1;
      else
        insert into tmp_maint_equipment_ambiguous
          values (r.id, r.vineyard_id, r.item_name, 'tractor', v_count);
        v_ambiguous := v_ambiguous + 1;
      end if;
      continue;
    end if;

    -- priority 3: spray_equipment.name
    select count(*) into v_count
      from public.spray_equipment s
     where s.vineyard_id = r.vineyard_id
       and s.deleted_at is null
       and lower(btrim(coalesce(s.name, ''))) = v_key;
    if v_count > 0 then
      if v_count = 1 then
        select s.id into v_id
          from public.spray_equipment s
         where s.vineyard_id = r.vineyard_id
           and s.deleted_at is null
           and lower(btrim(coalesce(s.name, ''))) = v_key
         limit 1;
        update public.maintenance_logs
           set equipment_source = 'spray_equipment', equipment_ref_id = v_id
         where id = r.id;
        v_linked := v_linked + 1;
      else
        insert into tmp_maint_equipment_ambiguous
          values (r.id, r.vineyard_id, r.item_name, 'spray_equipment', v_count);
        v_ambiguous := v_ambiguous + 1;
      end if;
      continue;
    end if;

    -- priority 4: equipment_items.name
    select count(*) into v_count
      from public.equipment_items e
     where e.vineyard_id = r.vineyard_id
       and e.deleted_at is null
       and lower(btrim(coalesce(e.name, ''))) = v_key;
    if v_count > 0 then
      if v_count = 1 then
        select e.id into v_id
          from public.equipment_items e
         where e.vineyard_id = r.vineyard_id
           and e.deleted_at is null
           and lower(btrim(coalesce(e.name, ''))) = v_key
         limit 1;
        update public.maintenance_logs
           set equipment_source = 'equipment_item', equipment_ref_id = v_id
         where id = r.id;
        v_linked := v_linked + 1;
      else
        insert into tmp_maint_equipment_ambiguous
          values (r.id, r.vineyard_id, r.item_name, 'equipment_item', v_count);
        v_ambiguous := v_ambiguous + 1;
      end if;
      continue;
    end if;

    -- no match anywhere -> free_text
    update public.maintenance_logs
       set equipment_source = 'free_text'
     where id = r.id;
    v_free := v_free + 1;
  end loop;

  raise notice 'maintenance_logs equipment backfill: linked=%, free_text=%, ambiguous=%',
    v_linked, v_free, v_ambiguous;
end
$backfill$;

-- ---------------------------------------------------------------------
-- 3. Manual-review report: ambiguous rows left unlinked (equipment_source
--    and equipment_ref_id intentionally NULL). Inspect and resolve by hand.
-- ---------------------------------------------------------------------
select *
  from tmp_maint_equipment_ambiguous
 order by vineyard_id, item_name;
