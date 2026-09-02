# Seasonal yield — shared damage parity fixtures (area-weighted)

Status: **contract proposal, pending database apply.** Companion to
`sql/221_season_yield_estimates.sql`.

This document is the **authoritative behavioural contract** for the damage
engines on all three clients — the Lovable portal's existing engine, and the
revised iOS and Android engines.

> **Pre-existing parity defect, found during this work.** The shipped iOS
> (`MigratedDataStore.damageFactor(for:)`) and Android
> (`List<DamageRecord>.damageFactor(paddockId)`) engines are
> *percent-multiplicative* — `∏(1 − pct/100)` — which ignores polygon area
> entirely. The portal uses the intended *area-weighted* contract below.
> After SQL 221 is applied, iOS and Android must be corrected to match this
> document. Until then the two mobile engines are wrong by this contract;
> the fixtures below pin values that clearly distinguish the correct
> area-weighted result from the old multiplicative one.

Every platform must produce the numbers below **exactly**, to a tolerance of
`1e-9`. Round only at render time, never in the calculation.

---

## 1. The contract

For each eligible damage record:

```text
mapped_area_ha     = area of the damage polygon
                     (reference geometry: _paddock_polygon_area_hectares,
                      sql/095 — equirectangular shoelace, mPerDegLat
                      111320.0, mPerDegLon 111320·cos(centroidLat))

effective_loss_ha  = mapped_area_ha × damage_percent ÷ 100
```

For each block (calculated **independently per block**):

```text
block_effective_loss_ha = Σ effective_loss_ha over the block's eligible records

damage_factor           = min(1, block_effective_loss_ha ÷ block_area_ha)

damage_reduction_t      = block_base_estimate_tonnes × damage_factor
adjusted_estimate_t     = block_base_estimate_tonnes − damage_reduction_t
```

Then — and only then — aggregate:

```text
variety adjusted   = Σ adjusted over the block's planting groups
                     (each group gets base × its allocation share, then the
                      SAME block damage_factor is applied to that share)
vineyard adjusted  = Σ adjusted over all blocks
```

Never apply one vineyard-wide percentage to all blocks, and never blend
block factors into a vineyard factor.

Key rules:

- **Cap each block at 100%.** `min(1, ·)` — a block can never lose more than
  its whole base estimate, and adjusted tonnes can never go negative.
- **Polygon overlap may overstate loss.** Overlapping polygons double-count
  the same ground. This is existing behaviour and stays: surfaces must keep
  warning the user about overlaps.
- **Missing or invalid polygon geometry** on a damage record follows the
  existing eligibility/warning behaviour: the record is **excluded from the
  area sums** and surfaces a warning (`damage_record_without_polygon`). It
  must never become a whole-block percentage loss, and it must never be
  treated as full-block loss.
- **Block area unavailable** (block has no polygon and no stored area): the
  factor cannot be computed — show base only with a
  `block_area_unavailable` warning. Never assume 100% or 0% loss.
- **Vintage matching.** Only records whose `damage_records.vintage` equals
  the selected Vintage are eligible (read the column added by SQL 221 —
  never recomputed from a date on the client). Deleted records
  (`deleted_at IS NOT NULL`) are never eligible. Damage type, severity and
  status do not affect eligibility.
- **Apply Damage toggle.** Off by default and shows the untouched base
  estimate; on shows the area-weighted adjusted estimate. The toggle is a
  display choice — it never rewrites stored data. Both figures stay
  available while the toggle exists.

---

## 2. Shared block fixtures

All blocks belong to one vineyard with `season_start_month = 9`,
`season_start_day = 1` and `timezone = 'Australia/Sydney'`, so 2 Sep 2026
and 1 Mar 2027 both resolve to **Vintage 2027** (vineyard-local, per SQL 221).

Base tonnes come from the pruning formula:
`vines × buds/vine × bunches/bud × bunch weight (g) ÷ 1,000,000`.

| Block | Area (ha) | Vines | Method | Buds/vine | Bunches/bud | Bunch wt (g) | Base tonnes |
|---|---|---|---|---|---|---|---|
| A (V2027) | 2.0000 | 1000 (override) | spur | 2 × 6 = 12 | 1.5 | 120 | **2.16** |
| A (V2026) | 2.0000 | 1000 (override) | spur | 2 × 6 = 12 | 1.5 | 100 | **1.8** |
| B (V2027) | 1.5000 | 500 (override) | cane | 10 × 4 = 40 | 1.5 | 120 | **3.6** |
| D (V2027) | 2.0000 | 1000 (override) | spur | 2 × 6 = 12 | 1.5 | 120 | **2.16** |

Block D is mixed-variety:

| Planting group | Allocation | Base tonnes |
|---|---|---|
| Shiraz · MV6 · 101-14 | 60% | 1.296 |
| Cabernet Sauvignon | 30% | 0.648 |
| Unallocated variety | 10% | 0.216 |

---

## 3. Fixtures

### Fixture 1 — No damage

Block A, Vintage 2027, no damage records.

| Value | Expected |
|---|---|
| Mapped area (ha) | 0 |
| Effective loss area (ha) | 0 |
| Damage factor | 0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0 |
| Adjusted tonnes | 2.16 |

With no eligible records the factor is exactly `0`, so Apply Damage on and
off must show the identical number.

### Fixture 2 — 20% intensity over 10% of the block *(defect distinguisher)*

Block A (2.0 ha), V2027. One record: 20% intensity, polygon covering
**0.2 ha — only 10% of the block**.

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.2 |
| Effective loss area (ha) | 0.04 |
| Damage factor | 0.02 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0.0432 |
| Adjusted tonnes | 2.1168 |

**A 20% intensity record over 10% of a block must produce a 2% block yield
reduction — not 20%.** The old multiplicative engines would return a factor
of 0.8 and an adjusted 1.728 t (a 20% reduction). If a platform prints
1.728 here, it is still running the defective engine.

### Fixture 3 — Multiple non-overlapping records

Block A (2.0 ha), V2027. Two records: 20% over 0.2 ha, and 10% over 0.3 ha.

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.5 |
| Effective loss area (ha) | 0.07 |
| Damage factor | 0.035 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0.0756 |
| Adjusted tonnes | 2.0844 |

`(0.2 × 0.20) + (0.3 × 0.10) = 0.07 ha` of the block's 2.0 ha. Note this is
**not** the multiplicative 0.72 factor the old engines produce, and not a
naive `1 − (0.20 + 0.10)` either. Record order must not change the sum.

### Fixture 4 — Combined loss capped at 100% per block

**4a — cap engaged.** Block A (2.0 ha), V2027. Records: 60% over 2.0 ha and
70% over 2.0 ha.

| Value | Expected |
|---|---|
| Mapped area (ha) | 4.0 |
| Effective loss area (ha) | 2.6 |
| Damage factor | 1.0 (capped from 1.3) |
| Base tonnes | 2.16 |
| Reduction tonnes | 2.16 |
| Adjusted tonnes | 0.0 |

Effective loss (2.6 ha) exceeds the block area, so the factor caps at 1.0
and the block loses its whole base estimate — never more.

**4b — total loss without the cap being engaged.** Same block, single
record: 100% over 2.0 ha.

| Value | Expected |
|---|---|
| Mapped area (ha) | 2.0 |
| Effective loss area (ha) | 2.0 |
| Damage factor | 1.0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 2.16 |
| Adjusted tonnes | 0.0 |

Adjusted tonnes must be exactly `0`, never negative.

### Fixture 5 — Two vintages, damage in only one

Block A. One damage record only: 20% over 0.2 ha, observed 10 Mar 2026 →
Vintage 2026.

Selected Vintage **2026** (base 1.8):

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.2 |
| Effective loss area (ha) | 0.04 |
| Damage factor | 0.02 |
| Base tonnes | 1.8 |
| Reduction tonnes | 0.036 |
| Adjusted tonnes | 1.764 |

Selected Vintage **2027** (base 2.16):

| Value | Expected |
|---|---|
| Mapped area (ha) | 0 |
| Effective loss area (ha) | 0 |
| Damage factor | 0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0 |
| Adjusted tonnes | 2.16 |

Switching the Vintage selector must move between these two answers with no
cached value from the other Vintage appearing at any point, including during
loading.

### Fixture 6 — Deleted, wrong-vintage and polygon-less records

Block A (2.0 ha), V2027, three records that must all be excluded:

- 20% over 0.5 ha with `deleted_at` set
- 30% over 0.5 ha with `vintage = 2026`
- 20% with **no polygon geometry** (`polygon_points` null/empty)

| Value | Expected |
|---|---|
| Mapped area (ha) | 0 |
| Effective loss area (ha) | 0 |
| Damage factor | 0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0 |
| Adjusted tonnes | 2.16 |
| Warnings | `damage_record_without_polygon` |

The polygon-less record is excluded from the area sums and warned about —
it must never be treated as a 20% whole-block loss.

### Fixture 7 — Two blocks, only one damaged

V2027. Block A (2.0 ha) has one 20% record over 0.2 ha; Block B (1.5 ha)
has none.

| Value | Block A | Block B | Vineyard total |
|---|---|---|---|
| Mapped area (ha) | 0.2 | 0 | 0.2 |
| Effective loss area (ha) | 0.04 | 0 | 0.04 |
| Damage factor | 0.02 | 0 | n/a |
| Base tonnes | 2.16 | 3.6 | 5.76 |
| Reduction tonnes | 0.0432 | 0 | 0.0432 |
| Adjusted tonnes | 2.1168 | 3.6 | 5.7168 |

Each block is calculated independently; a vineyard-level damage factor is
never computed. Totals are always the sum of per-block figures.

### Fixture 8 — Mixed-variety block, factor applied proportionally

Block D (2.0 ha), V2027, one 20% record over 0.2 ha. The factor is worked
out **once for the block** (`0.04 ÷ 2.0 = 0.02`) and then applied to each
planting group's share of the base.

| Planting group | Base tonnes | Damage factor | Reduction tonnes | Adjusted tonnes |
|---|---|---|---|---|
| Shiraz · MV6 · 101-14 (60%) | 1.296 | 0.02 | 0.02592 | 1.27008 |
| Cabernet Sauvignon (30%) | 0.648 | 0.02 | 0.01296 | 0.63504 |
| Unallocated variety (10%) | 0.216 | 0.02 | 0.00432 | 0.21168 |
| **Block total** | **2.16** | 0.02 | **0.0432** | **2.1168** |

Block-level figures:

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.2 |
| Effective loss area (ha) | 0.04 |

Damage is per block, then split by variety — never matched to a variety by
polygon overlap, and never recomputed per variety. The three adjusted values
must sum to the block adjusted total.

---

## 4. What each platform asserts

- **Database** — `sql/tests/221_season_yield_estimates_tests.sql` pins the
  base tonnes (2.16 / 3.6 / 1.8), the mixed-variety split (1.296 / 0.648 /
  0.216) and vineyard-local vintage scoping. It does **not** test damage:
  the database stores base estimates only.
- **iOS** — a `VineTrackTests` case feeding these fixtures through the
  revised area-weighted engine (replacing
  `MigratedDataStore.damageFactor(for:)`).
- **Android** — the equivalent over a revised engine (replacing
  `List<DamageRecord>.damageFactor(...)`).
- **Portal** — Lovable's existing area-weighted engine against the same
  table, asserting the same numbers.

When a fixture changes, it changes here first, then in all three suites.
