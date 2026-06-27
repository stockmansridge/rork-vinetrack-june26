# Growth Stage Records Contract

This document describes the dedicated `public.growth_stage_records` table
and the backwards-compatible `public.v_growth_stage_observations` view
that the Lovable web portal (and any future iOS work) can use to read
grape vine E-L growth-stage observations.

Migration: `sql/055_growth_stage_records.sql`.

## Goals

- Store growth observations separately from `public.pins`.
- Keep the existing pin-based growth observations readable for backwards
  compatibility (no schema break on iOS).
- Provide a single read surface (`v_growth_stage_observations`) so
  Lovable can transition incrementally.
- Mirror new growth-stage pins into `growth_stage_records` via `pin_id`
  so updates / soft-deletes can be reconciled.

## Table: `public.growth_stage_records`

| Column              | Type           | Notes                                              |
| ------------------- | -------------- | -------------------------------------------------- |
| `id`                | uuid (PK)      | server default `gen_random_uuid()`                 |
| `vineyard_id`       | uuid           | FK → `vineyards(id)`, cascade delete               |
| `paddock_id`        | uuid           | FK → `paddocks(id)`, set null on delete (best-effort) |
| `pin_id`            | uuid           | FK → `pins(id)`, back-compat link, unique active   |
| `stage_code`        | text (NOT NULL)| E-L code e.g. `EL19`                               |
| `stage_label`       | text           | Display label (e.g. "10% caps off")                |
| `variety`           | text           | Snapshot of variety name at observation time       |
| `variety_id`        | uuid           | Optional pointer into varieties table              |
| `observed_at`       | timestamptz    | default `now()`                                    |
| `latitude`          | double         |                                                    |
| `longitude`         | double         |                                                    |
| `row_number`        | integer        |                                                    |
| `side`              | text           | `Left` / `Right` (matches pin side)                |
| `notes`             | text           |                                                    |
| `photo_paths`       | text[]         | Storage paths into `growth-stage-photos` bucket    |
| `recorded_by_name`  | text           | Friendly observer name (legacy/imported support)   |
| `created_by`        | uuid           | FK → `auth.users(id)`                              |
| `updated_by`        | uuid           | FK → `auth.users(id)`                              |
| `created_at`        | timestamptz    |                                                    |
| `updated_at`        | timestamptz    | trigger `set_updated_at`                           |
| `client_updated_at` | timestamptz    | last-write-wins conflict resolution                |
| `sync_version`      | integer        | bumped on soft-delete                              |
| `deleted_at`        | timestamptz    | soft-delete via RPC                                |

### Constraints / indexes

- Unique active `pin_id` (idempotent mirroring).
- Indexes on `(vineyard_id, observed_at desc)`, `paddock_id`,
  `(vineyard_id, variety)`, `updated_at`, `deleted_at`.

### RLS

- Select: `is_vineyard_member(vineyard_id)`
- Insert / Update: `has_vineyard_role(vineyard_id, owner|manager|supervisor|operator)`
- Hard delete: denied.
- Soft delete via RPC `public.soft_delete_growth_stage_record(p_id uuid)`
  (owner / manager / supervisor only).

## View: `public.v_growth_stage_observations`

Union of:

1. Active rows in `growth_stage_records` (source = `growth_stage_records`).
2. Active pin rows with `growth_stage_code is not null` that have **not**
   been mirrored into the new table (source = `pins`).

This lets the Lovable Growth Stage Records page read both stores during
the transition. Once iOS has finished mirroring legacy pins, the pin
branch will be empty in practice but remains as a safety net.

## Storage bucket: `growth-stage-photos`

- Private bucket. Path convention:
  `{vineyard_id}/{growth_stage_record_id}/{uuid}.jpg`.
- Select / insert / update: vineyard members with field-recording roles.
- Delete: owner / manager / supervisor only.

## Backfill

The migration includes an idempotent insert from existing
`pins.growth_stage_code is not null` rows, preserving:

- `pin_id`, `paddock_id`, `vineyard_id`
- `latitude`, `longitude`, `row_number`, `side`, `notes`
- `photo_path` → `photo_paths[0]`
- `completed_by` → `recorded_by_name`
- `created_by`, `updated_by`, `created_at`, `updated_at`

Existing pins are **not** modified or deleted.

## iOS sync

- Model: `GrowthStageRecord` (local) / `BackendGrowthStageRecord` (server).
- Repository: `SupabaseGrowthStageRecordSyncRepository`.
- Service: `GrowthStageRecordSyncService` (push/pull, last-write-wins).
- Mirror hook: `MigratedDataStore.addPin` / `deletePin` invoke
  `onGrowthStagePinAdded` / `onGrowthStagePinDeleted`, which the service
  uses to create / soft-delete the corresponding record via `pinId`.

The current iOS UI flow continues to read growth observations from
`store.pins` to avoid breaking changes. A future PR can switch the
Growth Stage Records page to read `growthStageRecordSync.records`.
