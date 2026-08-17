# Chemical Intelligence JSON Contract (sql/194)

**Contract version:** 1 (`intelligence_schema_version = 1`, `activity_group_table_version = 1`)
**Audience:** Lovable web portal (Stage 2B) and any other backend writer/reader of Chemical Intelligence data.
**Status:** Authoritative. This document describes the wire format that shipping iOS and Android builds already persist and parse. The portal must write byte-compatible JSON; it must not invent variants.

Sources of truth (in order):

- `sql/194_chemical_intelligence.sql` — columns, CHECK constraints, audit views.
- iOS: `ios/VineTrack/App/ChemicalIntelligence/*.swift` (models), `ios/VineTrack/Backend/Models/BackendManagement.swift` (column mapping).
- Android: `android-vinetrack/.../data/chemical/*.kt` (models), `data/SavedChemicalRepository.kt` + `data/model/Models.kt` (column mapping).
- Parity tests: `ios/VineTrackTests/ChemicalSnapshotCaptureTests.swift`, `android .../data/ChemicalIntelligenceParityTest.kt` and siblings.

If this document and the code ever disagree, the code wins — fix the document.

---

## 1. Storage map

Chemical Intelligence lives in two places. There is **no** single nested "intelligence" JSON blob on the server; the aggregate is flattened into columns.

| Where | What |
|---|---|
| `public.saved_chemicals` (sql/194 columns) | The current, editable record: three JSONB array columns + scalar/array projections (section 3). |
| `spray_records.tanks` / `spray_jobs.tanks` JSONB | A frozen, per-spray-line `chemicalSnapshot` object (section 8). History reads the snapshot, never the current chemical. |

The in-app `ChemicalIntelligence` aggregate (with nested `registration` / `verification` keys) is **app-internal only**. Never write that nested shape to Supabase.

## 2. Global encoding rules

1. **Keys are `snake_case`** inside every sql/194 JSONB value. (Exception: the snapshot's *container* key `chemicalSnapshot` is camelCase because the surrounding legacy `tanks` payload is camelCase — see section 8.)
2. **Absent means omitted.** An unknown/absent optional field is **omitted from the JSON entirely — never written as `null`**. Both apps do this (Android `explicitNulls = false`; iOS `encodeIfPresent`). Readers must treat a missing key and `null` identically.
3. **Numbers are JSON numbers**, not strings (`"concentration": 200`, `"min_value": 1.0`).
4. **Timestamps are ISO-8601 UTC strings** wherever they appear *inside* JSONB (`retrieved_at`, `captured_at`), e.g. `"2026-08-15T00:00:00Z"`. Fractional seconds are optional — iOS writes them (`…T00:00:00.000Z`), Android may not. Readers must accept both. `verified_at` is a `timestamptz` **column**, not JSON; any ISO-8601 value PostgREST accepts is fine.
5. **Enum values travel as their raw strings** (section 5). Unknown values must degrade safely on read (section 9), never fail the record.
6. **Never write empty-string sentinels** for absent optionals; omit the key.

## 3. Column reference — `public.saved_chemicals`

| Column | Type | Contents |
|---|---|---|
| `active_ingredients` | `jsonb` | Array of **ActiveIngredient** (section 4.1). Source of truth for chemistry. |
| `activity_groups` | `text[]` | **Derived.** Bare group codes, e.g. `{'3','11'}` — one entry per group, **never** `{'3 + 11'}`. Always rewritten from `active_ingredients` on every structured write (section 6). |
| `activity_group_scheme` | `text` | **Derived.** Scheme of the first canonical group. CHECK: `frac`, `hrac`, `irac`, `not_applicable`, or NULL. |
| `registration_country` | `text` | ISO-2 country code, uppercase (`AU`, `NZ`). |
| `registration_scheme` | `text` | CHECK: `apvma`, `acvm`, `nz_epa`, `other`, or NULL. |
| `registration_number` | `text` | Register's product number, verbatim. |
| `registrant` | `text` | Registrant of record. |
| `registered_product_name` | `text` | Exact registered product name. |
| `label_reference` | `text` | URL / document id of the label consulted. |
| `label_version` | `text` | Label version or approval date string. |
| `verification_status` | `text NOT NULL DEFAULT 'unverified'` | CHECK: `verified`, `partially_verified`, `unverified`, `needs_match`, `conflict`. Apps persist the **resolved** status (section 6.3). |
| `verification_sources` | `jsonb` | Array of **DataSource** (4.3). |
| `verification_conflicts` | `jsonb` | Array of **Conflict** (4.4). Non-empty **must** force status `conflict`. |
| `verification_unresolved_fields` | `text[]` | Field names the lookup explicitly could not resolve. |
| `verified_at` | `timestamptz` | When verification last ran. |
| `registered_uses` | `jsonb` | Array of **RegisteredUse** (4.5). |
| `label_rate_bases` | `text[]` | **Derived.** Distinct `basis` values across all uses' rates. Vocabulary: `per_100_litres`, `per_hectare`, `range_per_100_litres`, `range_per_hectare`, `other` (no DB CHECK by design). |
| `activity_group_table_version` | `integer` | Revision of the app-side FRAC/HRAC/IRAC reference table that classified this row. Currently `1`. |
| `intelligence_schema_version` | `integer NOT NULL DEFAULT 0` | Payload contract version. Current contract: `1`. `0` = pre-contract row. |

Legacy scalar columns `active_ingredient` (text) and `chemical_group` (text) remain, and are written as **derived display projections** whenever structured intelligence exists (section 6.4). Nothing may calculate from them.

## 4. JSON object schemas

### 4.1 ActiveIngredient (`active_ingredients[]`, also inside snapshots)

The unit that carries an activity group. A product does **not** have a group; each active does — a two-active mixture genuinely belongs to two groups at once.

| Key | Type | Presence | Notes |
|---|---|---|---|
| `name` | string | always | Active's common (ISO) name, trimmed, e.g. `"Tebuconazole"`. May be `""` only in legacy-seeded candidates. |
| `concentration` | number | omit when unknown | Label value, e.g. `200`. Never guessed. |
| `concentration_unit` | enum string | omit when unknown | `"g/L"`, `"g/kg"`, `"% w/w"`, `"% w/v"`, `"CFU/g"` — exact casing/spacing. |
| `activity_group` | ActivityGroup | omit when unknown | Absence = "group not established" (a legitimate, visible state). |
| `group_source` | DataSourceKind | omit when no group | Where the group came from, per-active. |
| `identity_source` | DataSourceKind | omit when unknown | Where identity/concentration came from. |

A group only counts as verified evidence when `group_source` is authoritative (section 5.3) **and** the group is resistance-relevant (real scheme + non-empty code).

### 4.2 ActivityGroup

| Key | Type | Presence | Notes |
|---|---|---|---|
| `scheme` | enum string | always | `"frac"`, `"hrac"`, `"irac"`, `"not_applicable"`. |
| `code` | string | always | Normalised: uppercase; `GROUP`/`FRAC`/`HRAC`/`IRAC`/`MOA`/`CODE` prefixes stripped; trailing parenthetical dropped (`"11 (QoI)"` → `"11"`); internal spaces removed. E.g. `"3"`, `"11"`, `"M5"`, `"4A"`, `"G"`. |
| `common_name` | string | omit when none | Display sugar only (`"QoI / Strobilurin"`). Never parsed or compared. |

### 4.3 DataSource (`verification_sources[]`)

| Key | Type | Presence | Notes |
|---|---|---|---|
| `kind` | DataSourceKind | always | Section 5.3. |
| `name` | string | always | e.g. `"APVMA PUBCRIS"`, `"VineTrack activity group reference v1 (FRAC/HRAC/IRAC)"`. |
| `reference` | string | omit when none | URL or document identifier. |
| `retrieved_at` | ISO-8601 string | omit when none | When the source was consulted. |

### 4.4 Conflict (`verification_conflicts[]`)

A specific disagreement between two sources about one field. Surfaced verbatim; software never picks a winner.

| Key | Type | Presence | Notes |
|---|---|---|---|
| `field` | string | always | e.g. `"activity_group"`, `"concentration"`. |
| `active_ingredient_name` | string | omit when not field-specific | |
| `extracted_value` | string | always | What the label/AI extraction claimed. |
| `authoritative_value` | string | always | What the authoritative source says. |
| `extracted_source` | DataSourceKind | always | |
| `authoritative_source` | DataSourceKind | always | |

**Invariant:** if this array is non-empty, `verification_status` must be `conflict`. Both apps enforce it on read regardless of the stored status; the portal must enforce it on write.

### 4.5 RegisteredUse (`registered_uses[]`)

| Key | Type | Presence | Notes |
|---|---|---|---|
| `crop` | string | always | Label wording, e.g. `"Grapes (winegrapes)"`. |
| `target_raw` | string | always | Target exactly as the label words it, e.g. `"Powdery mildew"`. |
| `target` | enum string | omit unless it maps cleanly | VineTrack spray target: `"powdery_mildew"`, `"downy_mildew"`, `"botrytis"`, `"weeds"`, `"nutrition_biostimulant"`, `"other"`. Readers re-derive from `target_raw` when absent — never force-fit. |
| `rates` | LabelRate[] | always (may be `[]`) | |
| `withholding_period_days` | integer | omit when unstated | |
| `re_entry_period_hours` | integer | omit when unstated | |
| `restrictions` | string | omit when none | Verbatim label restriction text. |

### 4.6 LabelRate (`registered_uses[].rates[]`)

| Key | Type | Presence | Notes |
|---|---|---|---|
| `label` | string | always (may be `""`) | What the label calls the rate, e.g. `"Low disease pressure"`. |
| `basis` | enum string | always | Section 5.5. |
| `value` | number | single-rate bases only | |
| `min_value` / `max_value` | number | range bases only | Proposals must start from `min_value`, never the high end. |
| `unit` | string | always | `"L"`, `"mL"`, `"kg"`, `"g"`, … |
| `raw_text` | string | omit unless `basis = "other"` | Verbatim label text for unusual bases. |

## 5. Enum vocabularies (closed; raw strings)

### 5.1 `verification_status`
`verified` · `partially_verified` · `unverified` · `needs_match` · `conflict`
(DB CHECK enforces exactly these.)

### 5.2 `activity_group_scheme` / `ActivityGroup.scheme`
`frac` · `hrac` · `irac` · `not_applicable`
A bare code is ambiguous — FRAC 3 and IRAC 3 are unrelated chemistries — so the scheme always travels with the code.

### 5.3 DataSourceKind (`kind`, `group_source`, `identity_source`, conflict sources)
| Raw | Authoritative? | Meaning |
|---|---|---|
| `official_register` | yes | National regulator record (APVMA, ACVM/EPA). |
| `manufacturer_label` | yes | Registrant's approved label. |
| `authoritative_classification` | yes | FRAC/HRAC/IRAC table — authoritative for the group and nothing else. |
| `viticulture_reference` | no | Industry spray guide cross-check. |
| `ai_interpretation` | no | AI/search reading. A lead, never a verification. |
| `manual_entry` | no (self-reported) | Typed by the operator. |
| `legacy_record` | no (self-reported) | Read out of a pre-194 free-text field. |

### 5.4 `registration_scheme`
`apvma` (AU) · `acvm` (NZ) · `nz_epa` (NZ) · `other`

### 5.5 `label_rate_bases[]` / `LabelRate.basis`
`per_100_litres` · `per_hectare` · `range_per_100_litres` · `range_per_hectare` · `other`
This is the **label's** rate basis, deliberately independent of the spray carrier volume basis (sql/192).

### 5.6 Concentration units
`g/L` · `g/kg` · `% w/w` · `% w/v` · `CFU/g` (exact casing and spacing).

## 6. Write rules the portal MUST honour

### 6.1 Derived columns never drift
On **every** write that carries structured intelligence:

- `activity_groups` := every active's group code, **de-duplicated by `scheme:code` and sorted** (scheme, then numeric prefix, then full code — `3` before `11` before `M5`), filtered to resistance-relevant groups only. Entry order of actives must not change the stored array.
- `activity_group_scheme` := scheme of the first canonical group (or omitted when there are none).
- `label_rate_bases` := distinct `basis` values across all `registered_uses[].rates`, in first-seen order.

### 6.2 Registration is flattened
`registration_country`, `registration_scheme`, `registration_number`, `registrant`, `registered_product_name`, `label_reference`, `label_version` are scalar columns. Country is normalised to ISO-2 uppercase. The registered identity key used in snapshots is `"{COUNTRY}:{scheme|unknown}:{NUMBER uppercased}"`, e.g. `"AU:apvma:62764"` — country is part of the key on purpose.

### 6.3 Status honesty: persist the RESOLVED status
Both apps re-derive the status from evidence on every write and persist **that**, so confidence can be lowered on write but never raised:

- `verification_conflicts` non-empty → `conflict`, unconditionally.
- `verified` requires ALL of: stored claim `verified`; every active's group authoritative (`group_source` in 5.3-authoritative AND resistance-relevant group); an evidenced registration identity (authoritative shape **and** at least one non-self-reported source or active identity); at least one authoritative cited source; empty `verification_unresolved_fields`.
- Otherwise, with real authoritative evidence → `partially_verified`; with none → `unverified`. `needs_match` is preserved for never-matched records.
- A hand-typed registration number alone is **not** evidence — self-reported sources (`manual_entry`, `legacy_record`) cannot underwrite any promotion.

### 6.4 Legacy projections are outputs only
Whenever structured intelligence exists, also write:

- `chemical_group` := codes joined with `" + "` → `"3 + 11"`.
- `active_ingredient` := active display labels joined with `" + "` → `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"` (numbers: integers bare, otherwise max 4 significant digits — both apps format identically).

Never parse these strings back. Never store `"3 + 11"` inside `activity_groups`.

### 6.5 No intelligence = no columns
A write that carries no structured intelligence must **omit every sql/194 column** (PATCH semantics), so an intelligence-unaware edit can never blank a previously verified record. Do not send `null`s.

### 6.6 Versions
Stamp `intelligence_schema_version = 1` and `activity_group_table_version = 1` (current values) on structured writes. Bump `intelligence_schema_version` only via a coordinated contract change (section 11).

## 7. Canonical example — full sql/194 write

The worked mixture both platforms use in their tests (Tebuconazole + Azoxystrobin, verified against APVMA). Column values as they land in the row:

```json
{
  "active_ingredients": [
    {
      "name": "Tebuconazole",
      "concentration": 200,
      "concentration_unit": "g/L",
      "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI" },
      "group_source": "authoritative_classification",
      "identity_source": "official_register"
    },
    {
      "name": "Azoxystrobin",
      "concentration": 120,
      "concentration_unit": "g/L",
      "activity_group": { "scheme": "frac", "code": "11", "common_name": "QoI / Strobilurin" },
      "group_source": "authoritative_classification",
      "identity_source": "official_register"
    }
  ],
  "activity_groups": ["3", "11"],
  "activity_group_scheme": "frac",
  "registration_country": "AU",
  "registration_scheme": "apvma",
  "registration_number": "70001",
  "registrant": "Example Crop Science",
  "registered_product_name": "Example Duo Fungicide",
  "label_reference": "https://portal.apvma.gov.au/pubcris/70001/label.pdf",
  "label_version": "2025-03",
  "verification_status": "verified",
  "verification_sources": [
    {
      "kind": "official_register",
      "name": "APVMA PUBCRIS",
      "reference": "https://portal.apvma.gov.au/pubcris",
      "retrieved_at": "2026-08-15T00:00:00Z"
    },
    {
      "kind": "authoritative_classification",
      "name": "VineTrack activity group reference v1 (FRAC/HRAC/IRAC)"
    }
  ],
  "verification_conflicts": [],
  "verification_unresolved_fields": [],
  "verified_at": "2026-08-15T00:00:00Z",
  "registered_uses": [
    {
      "crop": "Grapes (winegrapes)",
      "target_raw": "Powdery mildew",
      "target": "powdery_mildew",
      "rates": [
        {
          "label": "Standard",
          "basis": "range_per_hectare",
          "min_value": 1.0,
          "max_value": 1.5,
          "unit": "L"
        }
      ],
      "withholding_period_days": 30,
      "re_entry_period_hours": 24
    }
  ],
  "label_rate_bases": ["range_per_hectare"],
  "activity_group_table_version": 1,
  "intelligence_schema_version": 1
}
```

Written alongside it (derived legacy projections): `"chemical_group": "3 + 11"`, `"active_ingredient": "Tebuconazole 200 g/L + Azoxystrobin 120 g/L"`.

A conflict entry, for reference:

```json
{
  "field": "activity_group",
  "active_ingredient_name": "Azoxystrobin",
  "extracted_value": "3",
  "authoritative_value": "11",
  "extracted_source": "ai_interpretation",
  "authoritative_source": "authoritative_classification"
}
```

## 8. Spray line snapshot — `chemicalSnapshot` inside `tanks`

Each chemical line object inside the `spray_records.tanks` / `spray_jobs.tanks` JSONB may carry a `chemicalSnapshot` (container key camelCase to match the surrounding legacy tank keys; everything **inside** is snake_case). It freezes what VineTrack believed at application time; correcting a product later must never restate history. Whoever records a spray writes it; the portal should treat existing snapshots as read-only.

| Key | Type | Presence | Notes |
|---|---|---|---|
| `saved_chemical_id` | UUID string | omit when unknown | Case may differ by platform (iOS uppercase, Android lowercase) — compare case-insensitively. |
| `product_name` | string | omit when unknown | Name as displayed at application time. |
| `active_ingredients` | ActiveIngredient[] | always (may be `[]`) | Frozen copy. |
| `activity_groups` | string[] | always (may be `[]`) | Bare codes, duplicated so readers never reconstruct. |
| `verification_status` | enum raw | always | The **resolved** status at capture time. |
| `registration_identity_key` | string | omit when never matched | `"AU:apvma:62764"`. |
| `country_code` | string | omit when none | |
| `schema_version` | integer | always | `ChemicalIntelligence` schema version at capture (0 for legacy-only snapshots). |
| `activity_group_table_version` | integer | always | |
| `legacy_chemical_group` | string | omit when none | The displayed legacy string, for faithful reproduction only. |
| `captured_at` | ISO-8601 string | omit when unknown | iOS always writes fractional seconds; Android writes `Instant.now().toString()`. Readers accept both. |

Example:

```json
"chemicalSnapshot": {
  "saved_chemical_id": "5b8e0f7e-2f6a-4b6e-9dc4-1a2b3c4d5e6f",
  "product_name": "Example Duo Fungicide",
  "active_ingredients": [ /* same objects as section 7 */ ],
  "activity_groups": ["3", "11"],
  "verification_status": "verified",
  "registration_identity_key": "AU:apvma:70001",
  "country_code": "AU",
  "schema_version": 1,
  "activity_group_table_version": 1,
  "legacy_chemical_group": "3 + 11",
  "captured_at": "2026-08-15T00:00:00.000Z"
}
```

A line with nothing structured either carries no snapshot at all, or (when only a legacy display string existed) a minimal snapshot with `verification_status: "unverified"`, `schema_version: 0` and `legacy_chemical_group` — never a snapshot that implies knowledge that didn't exist.

## 9. Read rules (defensive decode)

Both apps degrade unknown values instead of failing a record; the portal must do the same:

| Situation | Behaviour |
|---|---|
| Unknown `verification_status` | Read as `unverified` (downgrade is the only safe direction). |
| Unknown DataSource `kind` | Read as `ai_interpretation` — never as authoritative. |
| Unknown activity group `scheme` | Read as `not_applicable` (group becomes unusable, record survives). |
| Unknown `registration_scheme` | Read as `other`. |
| Unknown `LabelRate.basis` | Read as `other`. |
| Missing `target` | Derive conservatively from `target_raw` (powdery/downy/botrytis/weeds keywords); else leave unset. |
| Missing arrays / missing sql/194 columns | Treat as empty / not-yet-migrated; never fail the chemical. |
| `verification_conflicts` non-empty | Treat status as `conflict` regardless of the stored value. |
| Structured intelligence "exists" | When actives, registered uses, or a registration identity are present; otherwise fall back to a `needs_match` legacy candidate seeded from the free-text columns (candidates are tagged `legacy_record` and can never pass as verified). |

## 10. Cross-platform parity verification (2026-08-17)

Verified by field-by-field comparison of the persisted encoders:

- **Key names:** identical across all seven wire types (iOS `CodingKeys` vs Android `@SerialName`): ActiveIngredient, ActivityGroup, DataSource, Conflict, RegisteredUse, LabelRate, ChemicalLineSnapshot, plus the flattened column DTOs (`BackendSavedChemicalUpsert` ↔ `ChemicalInsert`/`ChemicalPatch`).
- **Enum raw values:** identical across all six vocabularies (sections 5.1–5.6).
- **Null handling:** identical observable output — Android `Json { encodeDefaults = true; explicitNulls = false }` omits nulls and keeps non-null defaults; iOS synthesized encoding omits nil optionals and always writes non-optionals.
- **Status honesty:** both write paths persist the resolved status (`IntelFields` on Android; `BackendSavedChemical.upsert` on iOS, "the RESOLVED status, never the stored one").
- **Derived columns:** both derive `activity_groups` (same canonical ordering), `activity_group_scheme` (first group), `label_rate_bases`, and the legacy projections with matching number formatting (`formatChemicalNumber` deliberately mirrors iOS `%.4g`).
- **Pinned by tests:** iOS `ChemicalSnapshotCaptureTests` "The snapshot serialises the shared snake_case shape" asserts every snapshot key, the raw status string and the ISO `captured_at`; Android `ChemicalIntelligenceParityTest` round-trips full `SavedChemical` rows and `tanks` payloads through kotlinx JSON with the same fixtures (APVMA 62764/70001, Azoxystrobin 250 g/L FRAC 11, `verified_at "2026-08-15T00:00:00Z"`); `ChemicalIntelligenceTest(s)` on both platforms pin canonical group ordering (`["3","11"]` regardless of entry order) and reload equality.

Two non-breaking asymmetries exist and are absorbed by the read rules:

1. **`registered_uses[].target`** — iOS derives the mapped target at construction and therefore usually persists it; Android leaves it unset and derives on read. Semantics converge; stored bytes may differ on this one optional key. Portal rule: populate `target` only when the mapping is clean, otherwise omit.
2. **Intelligence-free upserts** — the iOS sync payload always includes `verification_status` (falling back to `"needs_match"`) and `intelligence_schema_version` (`0`) because those DTO fields are non-optional, while Android omits every sql/194 column. Portal rule: follow section 6.5 and omit all sql/194 columns when there is nothing structured to write.

## 11. Change control

- The vocabulary CHECKs in sql/194 (`verification_status`, `activity_group_scheme`, `registration_scheme`) are closed; extending them is a schema change, not a portal decision.
- `activity_groups` codes deliberately have **no** DB CHECK — the FRAC/HRAC/IRAC vocabulary grows annually; the typed enums in the apps are the enforcement point.
- Any additive field in the JSONB objects requires: update both app models, keep decoding tolerant, bump `intelligence_schema_version`, and update this document in the same change.
- Never repurpose or rename an existing key; historical snapshots in `tanks` are immutable evidence.
