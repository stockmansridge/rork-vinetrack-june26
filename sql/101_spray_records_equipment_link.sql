-- =====================================================================
-- 101_spray_records_equipment_link.sql
-- =====================================================================
-- Step 2: migration-safe equipment identity for spray_records.
--
-- Goal: keep the existing free-text equipment snapshots exactly as-is
-- (tractor, equipment_type, tractor_gear), while adding optional stable
-- equipment linkage for new and backfilled rows.
--
-- Design / safety guarantees:
--   * Strictly additive. Three NEW nullable columns only:
--       - machine_id          uuid  -> public.vineyard_machines(id)
--       - tractor_id          uuid  -> public.tractors(id)
--       - spray_equipment_id  uuid  -> public.spray_equipment(id)
--   * tractor / equipment_type / tractor_gear are NEVER read-modified.
--   * No column is made NOT NULL. No RLS change. No rename / drop.
--   * maintenance_logs is untouched (handled by SQL 100).
--   * Fully idempotent and safe to re-run.
--   * Old app versions ignore the new columns; old rows still render
--     from the existing text fields.
--
-- Backfill (per spray_records row, scoped to the SAME vineyard, trimmed +
-- case-insensitive). The text fields are matched independently:
--   tractor text:
--     priority 1: vineyard_machines.name           -> machine_id
--     priority 2: tractors.name OR brand+model      -> tractor_id
--     (only the highest tier with any match is considered; if it has
--      exactly one active match -> link it; if more than one -> ambiguous,
--      leave NULL and surface for review)
--   equipment_type text:
--     spray_equipment.name                          -> spray_equipment_id
--     (exactly one active match -> link; otherwise leave NULL)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Additive columns
-- ---------------------------------------------------------------------
alter table public.spray_records
  add column if not exists machine_id uuid null;

alter table public.spray_records
  add column if not exists tractor_id uuid null;

alter table public.spray_records
  add column if not exists spray_equipment_id uuid null;

comment on column public.spray_records.machine_id is
  'Optional stable link to public.vineyard_machines(id), backfilled/derived from the tractor text snapshot. The tractor text remains the authoritative display snapshot.';
comment on column public.spray_records.tractor_id is
  'Optional stable link to public.tractors(id), backfilled/derived from the tractor text snapshot when no vineyard_machine match exists.';
comment on column public.spray_records.spray_equipment_id is
  'Optional stable link to public.spray_equipment(id), backfilled/derived from the equipment_type text snapshot.';

create index if not exists idx_spray_records_machine_id
  on public.spray_records (machine_id);
create index if not exists idx_spray_records_tractor_id
  on public.spray_records (tractor_id);
create index if not exists idx_spray_records_spray_equipment_id
  on public.spray_records (spray_equipment_id);

-- ---------------------------------------------------------------------
-- 2. Backfill (only rows not soft-deleted and not yet linked)
-- ---------------------------------------------------------------------
do $backfill$
declare
  r record;
  v_tractor_key text;
  v_equip_key text;
  v_id uuid;
  v_count int;
  v_machine_linked int := 0;
  v_tractor_linked int := 0;
  v_equip_linked int := 0;
  v_ambiguous int := 0;
begin
  -- collect ambiguous rows for the review report
  create temporary table if not exists tmp_spray_equipment_ambiguous (
    spray_record_id uuid,
    vineyard_id uuid,
    text_value text,
    matched_source text,
    match_count int
  ) on commit drop;

  for r in
    select id, vineyard_id, tractor, equipment_type
      from public.spray_records
     where deleted_at is null
       and (machine_id is null and tractor_id is null and spray_equipment_id is null)
  loop
    -- ---- tractor text -> machine_id (priority 1) / tractor_id (priority 2) ----
    v_tractor_key := lower(btrim(coalesce(r.tractor, '')));
    if v_tractor_key <> '' then
      -- priority 1: vineyard_machines.name
      select count(*) into v_count
        from public.vineyard_machines m
       where m.vineyard_id = r.vineyard_id
         and m.deleted_at is null
         and lower(btrim(coalesce(m.name, ''))) = v_tractor_key;
      if v_count > 0 then
        if v_count = 1 then
          select m.id into v_id
            from public.vineyard_machines m
           where m.vineyard_id = r.vineyard_id
             and m.deleted_at is null
             and lower(btrim(coalesce(m.name, ''))) = v_tractor_key
           limit 1;
          update public.spray_records set machine_id = v_id where id = r.id;
          v_machine_linked := v_machine_linked + 1;
        else
          insert into tmp_spray_equipment_ambiguous
            values (r.id, r.vineyard_id, r.tractor, 'vineyard_machine', v_count);
          v_ambiguous := v_ambiguous + 1;
        end if;
      else
        -- priority 2: tractors.name OR brand+model display name
        select count(*) into v_count
          from public.tractors t
         where t.vineyard_id = r.vineyard_id
           and t.deleted_at is null
           and (
             lower(btrim(coalesce(t.name, ''))) = v_tractor_key
             or lower(btrim(coalesce(t.brand, '') || ' ' || coalesce(t.model, ''))) = v_tractor_key
           );
        if v_count = 1 then
          select t.id into v_id
            from public.tractors t
           where t.vineyard_id = r.vineyard_id
             and t.deleted_at is null
             and (
               lower(btrim(coalesce(t.name, ''))) = v_tractor_key
               or lower(btrim(coalesce(t.brand, '') || ' ' || coalesce(t.model, ''))) = v_tractor_key
             )
           limit 1;
          update public.spray_records set tractor_id = v_id where id = r.id;
          v_tractor_linked := v_tractor_linked + 1;
        elsif v_count > 1 then
          insert into tmp_spray_equipment_ambiguous
            values (r.id, r.vineyard_id, r.tractor, 'tractor', v_count);
          v_ambiguous := v_ambiguous + 1;
        end if;
      end if;
    end if;

    -- ---- equipment_type text -> spray_equipment_id ----
    v_equip_key := lower(btrim(coalesce(r.equipment_type, '')));
    if v_equip_key <> '' then
      select count(*) into v_count
        from public.spray_equipment s
       where s.vineyard_id = r.vineyard_id
         and s.deleted_at is null
         and lower(btrim(coalesce(s.name, ''))) = v_equip_key;
      if v_count = 1 then
        select s.id into v_id
          from public.spray_equipment s
         where s.vineyard_id = r.vineyard_id
           and s.deleted_at is null
           and lower(btrim(coalesce(s.name, ''))) = v_equip_key
         limit 1;
        update public.spray_records set spray_equipment_id = v_id where id = r.id;
        v_equip_linked := v_equip_linked + 1;
      elsif v_count > 1 then
        insert into tmp_spray_equipment_ambiguous
          values (r.id, r.vineyard_id, r.equipment_type, 'spray_equipment', v_count);
        v_ambiguous := v_ambiguous + 1;
      end if;
    end if;
  end loop;

  raise notice 'spray_records equipment backfill: machine_linked=%, tractor_linked=%, spray_equipment_linked=%, ambiguous=%',
    v_machine_linked, v_tractor_linked, v_equip_linked, v_ambiguous;
end
$backfill$;

-- ---------------------------------------------------------------------
-- 3. Manual-review report: ambiguous rows left unlinked (ids intentionally
--    NULL). Inspect and resolve by hand. Text snapshots remain untouched.
-- ---------------------------------------------------------------------
select *
  from tmp_spray_equipment_ambiguous
 order by vineyard_id, matched_source, text_value;
