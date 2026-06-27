-- =====================================================================
-- 105_equipment_serial_vin.sql
-- =====================================================================
-- Equipment identification: add Serial number and VIN number to every
-- equipment/machine asset table.
--
-- Goal:
--   * Allow operators to record an optional Serial number and VIN number
--     against any machinery/equipment asset (tractors, spray equipment,
--     vineyard machines, and "other" equipment items).
--
-- Safety / compatibility guarantees:
--   * Strictly additive. Every column is NEW and NULLABLE — no existing
--     column is renamed, dropped, or made NOT NULL.
--   * Existing rows keep working: serial_number / vin_number default NULL.
--   * No selectors, reports, fuel logs, maintenance logs, trips, work
--     tasks, or costing flows reference these columns, so they are
--     unaffected. Consumers that `select *` simply gain two trailing
--     nullable fields they can ignore.
--   * vineyard_id, created_by, updated_by, created_at, updated_at,
--     deleted_at, client_updated_at, sync_version and existing RLS
--     policies are untouched.
--   * No format validation is enforced at the DB layer — equipment serial
--     and VIN formats vary widely. Values are stored as free text.
--   * Fully idempotent and safe to re-run / safe to apply to production.
--
-- public.equipment_items already has serial_number (sql/053). This
-- migration only adds vin_number there, and adds BOTH columns to the
-- remaining three asset tables.
-- =====================================================================

-- ---------------------------------------------------------------------
-- tractors
-- ---------------------------------------------------------------------
alter table public.tractors
  add column if not exists serial_number text null;
alter table public.tractors
  add column if not exists vin_number text null;

comment on column public.tractors.serial_number is
  'Optional equipment serial number. Free text, nullable. No format validation.';
comment on column public.tractors.vin_number is
  'Optional vehicle identification number (VIN). Free text, nullable. Not forced to 17 chars.';

-- ---------------------------------------------------------------------
-- spray_equipment
-- ---------------------------------------------------------------------
alter table public.spray_equipment
  add column if not exists serial_number text null;
alter table public.spray_equipment
  add column if not exists vin_number text null;

comment on column public.spray_equipment.serial_number is
  'Optional equipment serial number. Free text, nullable. No format validation.';
comment on column public.spray_equipment.vin_number is
  'Optional vehicle identification number (VIN). Free text, nullable. Not forced to 17 chars.';

-- ---------------------------------------------------------------------
-- vineyard_machines
-- ---------------------------------------------------------------------
alter table public.vineyard_machines
  add column if not exists serial_number text null;
alter table public.vineyard_machines
  add column if not exists vin_number text null;

comment on column public.vineyard_machines.serial_number is
  'Optional equipment serial number. Free text, nullable. No format validation.';
comment on column public.vineyard_machines.vin_number is
  'Optional vehicle identification number (VIN). Free text, nullable. Not forced to 17 chars.';

-- ---------------------------------------------------------------------
-- equipment_items (serial_number already exists — add vin_number only)
-- ---------------------------------------------------------------------
alter table public.equipment_items
  add column if not exists vin_number text null;

comment on column public.equipment_items.vin_number is
  'Optional vehicle identification number (VIN). Free text, nullable. Not forced to 17 chars.';
