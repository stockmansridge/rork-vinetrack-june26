# Seasonal yield — shared damage parity fixtures

Status: **contract proposal, pending database apply.** Companion to
`sql/221_season_yield_estimates.sql`.

iOS, Android and the Lovable portal each keep their **own** damage engine.
The database supplies the base (undamaged) tonnes and says which damage
records belong to the selected Vintage; it never returns an adjusted figure.
These fixtures are how we prove the three engines still agree.

Every platform must produce the numbers below **exactly**, to a tolerance of
`1e-9`. Round only at render time, never in the calculation.

---

## 1. The engine being pinned

Verified in the shipped code, not assumed:

| Platform | Implementation |
|---|---|
| iOS | `MigratedDataStore.damageFactor(for:)` — `MigratedDataStore+Yield.swift` |
| Android | `List<DamageRecord>.damageFactor(paddockId)` — `data/model/DamageRecord.kt` |
| Portal | Lovable's own equivalent |

Both shipped engines are byte-for-byte the same rule:

```text
damage factor (per block) = Π over eligible records of (1 − clamp(percent, 0, 100) ÷ 100)
                            clamped into [0, 1]
                          = 1.0 when the block has no eligible records

adjusted tonnes  = base tonnes × damage factor
reduction tonnes = base tonnes − adjusted tonnes
```

Three consequences that the fixtures deliberately lock in:

1. **The factor is percent-multiplicative, not area-weighted.** A damage
   record's polygon area does not enter the factor at all. "Mapped area" and
   "effective loss area" below are *reporting* values (Android already shows
   `effectiveLossHa = Σ area × percent ÷ 100` on the Damage Records screen);
   they must match across platforms too, but they never feed the tonnes.
2. **The cap is inherent.** Multiplying survival fractions can never take the
   combined loss above 100%; the explicit `clamp`/`coerceIn(0, 1)` is only a
   guard against a corrupt percent. Fixture 4 pins both halves of that.
3. **Order does not matter.** Multiplication is commutative, so record order,
   sync order and list sort must never change the result.

### Eligibility — which records may enter the product

A damage record counts for a block+vintage **only** when all of these hold:

- `deleted_at IS NULL`
- `paddock_id` = the block being estimated
- `vintage` = the currently selected Vintage (read from the column added by
  SQL 221 — never recomputed from a date on the client, never inferred from
  today's date)

Damage type, severity and status do **not** affect eligibility. That
behaviour is unchanged by SQL 221.

### Apply Damage toggle

Off by default. Off shows base tonnes; on shows adjusted tonnes. The toggle
is a display choice only — it never rewrites stored data, and both figures
are always available.

---

## 2. Shared block fixtures

All blocks belong to one vineyard with `season_start_month = 9`,
`season_start_day = 1`, so 2 Sep 2026 and 1 Mar 2027 both resolve to
**Vintage 2027**.

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
| Damage factor | 1.0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0 |
| Adjusted tonnes | 2.16 |

With no records the factor is exactly `1.0`, so Apply Damage on and off must
show the identical number.

### Fixture 2 — One 20% damage polygon

Block A, V2027. One record: 20%, mapped polygon 0.5 ha.

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.5 |
| Effective loss area (ha) | 0.1 |
| Damage factor | 0.8 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0.432 |
| Adjusted tonnes | 1.728 |

### Fixture 3 — Multiple non-overlapping records

Block A, V2027. Two records: 20% over 0.5 ha, and 10% over 0.25 ha.

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.75 |
| Effective loss area (ha) | 0.125 |
| Damage factor | 0.72 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0.6048 |
| Adjusted tonnes | 1.5552 |

`0.8 × 0.9 = 0.72`. Note this is **not** `1 − (0.20 + 0.10)`: the second
record damages what the first one left. Reversing the record order must give
the identical 0.72.

### Fixture 4 — Combined loss capped at 100% per block

**4a — heavy but not total.** Block A, V2027. Records: 60% over 0.5 ha, 70%
over 0.5 ha.

| Value | Expected |
|---|---|
| Mapped area (ha) | 1.0 |
| Effective loss area (ha) | 0.65 |
| Damage factor | 0.12 |
| Base tonnes | 2.16 |
| Reduction tonnes | 1.9008 |
| Adjusted tonnes | 0.2592 |

Naively adding percentages would give 130% loss. The engine gives 88%
(`1 − 0.4 × 0.3`), which is the capped, correct answer.

**4b — total loss.** Same block, plus a third record: 100% over 0.2 ha.

| Value | Expected |
|---|---|
| Mapped area (ha) | 1.2 |
| Effective loss area (ha) | 0.85 |
| Damage factor | 0.0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 2.16 |
| Adjusted tonnes | 0.0 |

Adjusted tonnes must be exactly `0`, never negative.

### Fixture 5 — Two vintages, damage in only one

Block A. One damage record only: 20%, 0.5 ha, observed 10 Mar 2026 →
Vintage 2026.

Selected Vintage **2026** (base 1.8):

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.5 |
| Effective loss area (ha) | 0.1 |
| Damage factor | 0.8 |
| Base tonnes | 1.8 |
| Reduction tonnes | 0.36 |
| Adjusted tonnes | 1.44 |

Selected Vintage **2027** (base 2.16):

| Value | Expected |
|---|---|
| Mapped area (ha) | 0 |
| Effective loss area (ha) | 0 |
| Damage factor | 1.0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0 |
| Adjusted tonnes | 2.16 |

Switching the Vintage selector must move between these two answers with no
cached value from the other Vintage appearing at any point, including during
loading.

### Fixture 6 — Deleted / ineligible record

Block A, V2027, two records that must both be ignored:

- 20% over 0.5 ha with `deleted_at` set
- 30% over 0.5 ha with `vintage = 2026`

| Value | Expected |
|---|---|
| Mapped area (ha) | 0 |
| Effective loss area (ha) | 0 |
| Damage factor | 1.0 |
| Base tonnes | 2.16 |
| Reduction tonnes | 0 |
| Adjusted tonnes | 2.16 |

### Fixture 7 — Two blocks, only one damaged

V2027. Block A has one 20% record over 0.5 ha; Block B has none.

| Value | Block A | Block B | Vineyard total |
|---|---|---|---|
| Mapped area (ha) | 0.5 | 0 | 0.5 |
| Effective loss area (ha) | 0.1 | 0 | 0.1 |
| Damage factor | 0.8 | 1.0 | n/a |
| Base tonnes | 2.16 | 3.6 | 5.76 |
| Reduction tonnes | 0.432 | 0 | 0.432 |
| Adjusted tonnes | 1.728 | 3.6 | 5.328 |

A vineyard-level damage factor is never computed. Totals are always the sum
of per-block adjusted figures — `5.76 × some blended factor` is wrong.

### Fixture 8 — Mixed-variety block, applied proportionally

Block D, V2027, one 20% record over 0.5 ha. The factor is worked out **once
for the block** and then applied to each planting group's share.

| Planting group | Base tonnes | Damage factor | Reduction tonnes | Adjusted tonnes |
|---|---|---|---|---|
| Shiraz · MV6 · 101-14 (60%) | 1.296 | 0.8 | 0.2592 | 1.0368 |
| Cabernet Sauvignon (30%) | 0.648 | 0.8 | 0.1296 | 0.5184 |
| Unallocated variety (10%) | 0.216 | 0.8 | 0.0432 | 0.1728 |
| **Block total** | **2.16** | 0.8 | **0.432** | **1.728** |

Block-level figures:

| Value | Expected |
|---|---|
| Mapped area (ha) | 0.5 |
| Effective loss area (ha) | 0.1 |

Damage is per block, then split by variety — never matched to a variety by
polygon overlap, and never recomputed per variety. The three adjusted values
must sum to the block adjusted total.

---

## 4. What each platform asserts

Each platform owns a test that builds these fixtures locally and checks every
cell above:

- **Database** — `sql/tests/221_season_yield_estimates_tests.sql` pins the
  base tonnes (2.16 / 3.6 / 1.8), the mixed-variety split (1.296 / 0.648 /
  0.216) and the vintage scoping. It does **not** test damage; the database
  never applies it.
- **iOS** — a `VineTrackTests` case feeding these base figures through
  `MigratedDataStore.damageFactor(for:)`.
- **Android** — the equivalent over `List<DamageRecord>.damageFactor(...)`.
- **Portal** — Lovable's own equivalent against the same table.

When a fixture changes, it changes here first, then in all three suites.
