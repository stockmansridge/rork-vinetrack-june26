# Soil-aware irrigation — Phase 1

Phase 1 introduces a shared paddock soil profile that powers the iOS
Irrigation Advisor and will be consumed by Lovable in Phase 3.

NSW SEED auto-fill is Phase 2 and is **not** wired yet. The
`source_provider` and `model_version` columns are reserved so the same
table can carry NSW SEED rows once the Edge Function lands.

## Tables

### `public.soil_class_defaults`

Read-only seed data for the irrigation soil class picker.

| Column                              | Notes                                                  |
| ----------------------------------- | ------------------------------------------------------ |
| `irrigation_soil_class` (pk)        | One of the canonical classes (see below)               |
| `label`                             | Human-readable label                                   |
| `default_awc_mm_per_m`              | Default Available Water Capacity (mm per metre of soil)|
| `default_allowed_depletion_percent` | Default management allowed depletion (%)               |
| `default_root_depth_m`              | Default effective root depth (m)                       |
| `infiltration_risk` / `drainage_risk` / `waterlogging_risk` | Qualitative descriptors |
| `sort_order`                        | Display ordering                                       |

Canonical classes seeded today:

```
sand_loamy_sand
sandy_loam
loam
silt_loam
clay_loam
clay_heavy_clay
basalt_clay_loam
shallow_rocky
unknown
```

### `public.paddock_soil_profiles`

One row per paddock (unique on `paddock_id`).

Key columns:

| Column                                | Notes                                              |
| ------------------------------------- | -------------------------------------------------- |
| `vineyard_id` / `paddock_id`          | FK to `vineyards` / `paddocks`                     |
| `source`                              | `manual`, `nsw_seed`, `imported`, `default`, ...   |
| `source_provider`                     | Free text. e.g. `nsw_seed`, `nz_smap`, `usda_ssurgo`, `vic_soil`, `sa_soil` |
| `source_dataset` / `source_feature_id` / `source_name` | Provider provenance         |
| `model_version`                       | e.g. `soil_aware_irrigation_v1`                    |
| `irrigation_soil_class`               | FK to `soil_class_defaults`                        |
| `available_water_capacity_mm_per_m`   | Canonical metric storage                           |
| `effective_root_depth_m`              |                                                    |
| `management_allowed_depletion_percent`|                                                    |
| `infiltration_risk` / `drainage_risk` / `waterlogging_risk` | Provider or manual         |
| `confidence`                          | `high` / `moderate` / `low` / `manual` / null      |
| `is_manual_override`                  | True when a user edited the row                    |
| `manual_notes`                        | Optional free-form notes                           |
| `raw_source_json`                     | Raw provider response (Phase 2 diagnostics)        |

RLS: enabled with **no client policies**. All access flows through the
RPCs below.

## RPCs

All RPCs are `security definer` and gated:

- Read RPCs require `public.is_vineyard_member(vineyard_id)`.
- Write RPCs require `public.has_vineyard_role(vineyard_id, array['owner','manager'])`.

### `get_soil_class_defaults()`

Returns the seeded soil-class default rows. Any authenticated user can
call this so iOS / Lovable can render the picker.

### `get_paddock_soil_profile(p_paddock_id uuid)`

Returns `setof public.paddock_soil_profiles` — zero or one row.

Errors:

- `paddock_id_required` (22023)
- `paddock_not_found` (P0002)
- `not_authorized` (42501)

### `list_vineyard_soil_profiles(p_vineyard_id uuid)`

Returns every soil profile for a vineyard. Used for Block / Paddock list
views.

### `upsert_paddock_soil_profile(...)`

Owner / manager only. Inserts or updates on conflict `(paddock_id)`.

Required: `p_paddock_id`.

Optional / typed:

```
p_irrigation_soil_class               text
p_available_water_capacity_mm_per_m   numeric
p_effective_root_depth_m              numeric
p_management_allowed_depletion_percent numeric
p_soil_landscape                      text
p_soil_description                    text
p_soil_texture_class                  text
p_infiltration_risk                   text
p_drainage_risk                       text
p_waterlogging_risk                   text
p_confidence                          text
p_is_manual_override                  boolean (default true)
p_manual_notes                        text
p_source                              text (default 'manual')
p_source_provider                     text
p_source_dataset                      text
p_source_feature_id                   text
p_source_name                         text
p_country_code                        text
p_region_code                         text
p_lookup_latitude                     double precision
p_lookup_longitude                    double precision
p_raw_source_json                     jsonb
p_model_version                       text (default 'soil_aware_irrigation_v1')
```

Returns the upserted `public.paddock_soil_profiles` row.

Errors:

- `paddock_id_required` (22023)
- `paddock_not_found` (P0002)
- `not_authorized` (42501)
- `invalid_irrigation_soil_class` (22023)
- `invalid_awc` / `invalid_root_depth` / `invalid_allowed_depletion` (22023)

### `delete_paddock_soil_profile(p_paddock_id uuid)`

Owner / manager only. Hard-deletes the single row. Returns `void`.

## Irrigation Advisor changes

`IrrigationCalculator.calculate(...)` now takes an optional `SoilProfileInputs`
and additionally returns:

- `soilAdvice` (`sandyFrequent`, `loamNormal`, `clayCaution`, `shallow`, `generic`)
- `rootZoneCapacityMm`, `readilyAvailableWaterMm` (derived)
- `soilAdviceText`, `soilCautionText`

Decision rules in v1 are **descriptive only** — they do not change the
recommended irrigation depth so users can build trust before deeper
soil-driven rules land in v2. Caution copy fires for heavy clay with
significant forecast rain, and for sandy soils when a single irrigation
exceeds readily available water.

## Provider keys (forward-compatible)

`source_provider` is plain text. Reserved keys:

```
manual        - hand-entered values
nsw_seed      - Phase 2 NSW SEED Edge Function
imported      - bulk migration
default       - global defaults
nz_smap       - future
usda_ssurgo   - future
vic_soil      - future
sa_soil       - future
```

## Disclaimer

Wherever provider-derived soil data is shown:

> Soil information is estimated from NSW SEED mapping and may not reflect
> site-specific vineyard soil conditions. Adjust soil class and
> water-holding values using your own soil knowledge where needed.

Phase 1 only renders this disclaimer when `source = 'nsw_seed'`. The
manual editor surfaces a softer "values are defaults; override where
possible" hint instead.
