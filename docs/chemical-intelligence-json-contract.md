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

See also: `docs/chemical-custodia-parity-fixture.md` (the pinned cross-platform lookup regression fixture — Custodia, AU:apvma:66541) and `docs/master-chemical-catalogue-design.md` (proposed shared catalogue design; no schema applied yet).

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

> **No direction-level `condition` key exists in contract v1.** Where a label conditions a direction by state, that wording is carried on `LabelRate.label` (4.6). See 4.6.1.

### 4.6 LabelRate (`registered_uses[].rates[]`)

| Key | Type | Presence | Notes |
|---|---|---|---|
| `label` | string | always (may be `""`) | What the label calls the rate, e.g. `"Low disease pressure"`. |
| `basis` | enum string | always | Section 5.5. |
| `value` | number | single-rate bases only | |
| `min_value` / `max_value` | number | range bases only | Proposals must start from `min_value`, never the high end. |
| `unit` | string | always | `"L"`, `"mL"`, `"kg"`, `"g"`, … |
| `raw_text` | string | omit unless `basis = "other"` | Verbatim label text for unusual bases. |

#### 4.6.1 State/condition wording on `label`

Australian labels routinely condition a direction by state, and that condition is what distinguishes otherwise identical rates: APVMA 53904 (THIOVIT JET) prints grapevine Powdery Mildew at 100–200 g/100 L for table and drying grapes and 200–600 g/100 L for wine grapes, both `NSW, Vic, Tas, SA, WA only`. Without the wording, those are two unexplained numbers and no client can honestly show which applies.

In contract v1 that wording travels on **`LabelRate.label`** — the key shipping iOS and Android builds already read. Ingestion also uses the condition internally (direction identity, parser row binding, comment scoping, direction comparison), but it is **not** emitted as a separate key.

**Readers must not expect a `condition` key on a registered use in v1.** Take the wording from `label`, and never merge two rates whose `label` differs into a single range — that is exactly the collapse this wording exists to prevent.

*Future (v2, not scheduled here):* a direction-level `condition` field is the correct long-term home, since a condition governs a whole direction rather than an individual rate. Adding it is a coordinated change under section 11 — both app models, tolerant decoding, an `intelligence_schema_version` bump and this document, in one change. Until then `label` is the single normative home and is **not** deprecated.

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

## 12. Shared lookup envelope + master link columns (sql/199)

Stage 1 of the Master Chemical Catalogue (`sql/199_master_chemical_catalogue.sql`)
adds an ADDITIVE envelope to the `chemical-info-lookup` `action=structured`
response and two additive columns on `saved_chemicals`. Everything in sections
1–11 is unchanged; master rows reuse the §4 JSONB shapes byte-for-byte.

### 12.1 Response envelope (`action=structured`)

```json
{
  "...": "the full sql/194 structured payload, exactly as in §7",
  "match_source": "master",
  "master": {
    "master_chemical_id": "c0570d1a-2026-4a66-9541-a99f66541001",
    "master_revision": 4,
    "catalogue_status": "approved",
    "registration_identity_key": "AU:apvma:66541"
  }
}
```

- `match_source`: `"master"` (served from an APPROVED catalogue row — the AI
  was never called) | `"authoritative_candidate"` (Stage 3 ingestion:
  identity + register-backed facts resolved from the jurisdiction's official
  register, but NOT approved — handled exactly like an AI candidate
  everywhere except provenance display) | `"ai_candidate"` (AI extraction,
  unchanged honesty rules) | `"unresolved"` (neither actives nor a
  registration established — route the operator to manual entry). Absent on
  pre-sql/199 servers; treat absent as `ai_candidate` behaviour. Unknown
  values must degrade to `ai_candidate` behaviour — never to a master match.
- `candidate` (additive, Stage 3): `{ master_chemical_id, candidate_revision,
  catalogue_status: "candidate", registration_identity_key }` — present when
  a sql/199 CANDIDATE row backs this lookup. It is review metadata only:
  clients must NEVER treat it as a master match, never write
  `saved_chemicals.master_chemical_id` from it, and both apps' parity suites
  pin that a candidate (or any non-approved `catalogue_status` inside a
  forged `master` block) can never read as `isMasterMatch`.
- `discovery` (additive, Stage 3): `{ adapter, outcome,
  registration_identity_key?, register_status?, error_category? }` — what
  authoritative discovery did (`resolved` | `unresolved` | `ambiguous` |
  `source_unavailable` | `not_supported` | `no_country`).
  `source_unavailable` means the register could not be consulted — it is
  never "product not registered". See `docs/master-chemical-ingestion.md`.
- `master` is present ONLY when `match_source == "master"`. Lookup priority is
  master → AI → manual; a known approved product must never go back through
  the AI. Master matching is exact only: identity key when known, else exact
  (case-insensitive) registered name or exact lower-cased alias that matches
  EXACTLY ONE approved row for the country — never fuzzy, never substring.
- `action=search` results may carry additive `source: "master"` and
  `master_chemical_id` fields; approved master hits are listed first.
- Old clients ignore all of this safely; every key is additive.

### 12.2 New `saved_chemicals` columns

| Column | Type | Meaning |
|---|---|---|
| `master_chemical_id` | `uuid` FK → `master_chemicals.id`, nullable | The catalogue product this record was derived from. |
| `master_source_revision` | `integer`, nullable | `master_chemicals.catalogue_version` at the moment the chemistry was copied. |

Write rules (portal MUST honour, mirroring both apps):

1. Set BOTH columns together, and only when applying a `match_source:"master"`
   lookup (`master.master_chemical_id` / `master.master_revision`).
2. Every other write — vineyard edits, AI-sourced matches, manual entry —
   OMITS both columns entirely (never writes `null`), so an existing link is
   never cleared or invented. Vineyard-private fields (stock, price, supplier,
   pack size, notes) never live on the master row.
3. The vineyard record keeps its OWN sql/194 chemistry copy; nothing may
   depend on a live join to `master_chemicals` for spray calculations.
4. “Updated verified information available” = current
   `master_chemicals.catalogue_version > saved.master_source_revision`;
   resolution happens ONLY through the Re-verify diff flow — master updates
   never rewrite vineyard rows or spray snapshots.
5. Only `review_status = 'approved'` master rows are readable by normal users;
   candidates/retired rows are admin-only (RLS-enforced, not a client filter).
   Catalogue writes are system-admin only; `review_status` (catalogue
   lifecycle) must never be conflated with `verification_status` (§5.1).

Pinned by the master-envelope cases in `ChemicalCustodiaParityTests.swift` /
`ChemicalCustodiaParityTest.kt` and by `sql/tests/199_master_chemical_catalogue_tests.sql`.

### 12.3 Jurisdiction rules (country scoping — portal MUST honour)

The vineyard's country (`vineyards.country`, set in the vineyard profile) is
the authoritative jurisdiction for every chemical lookup. No schema change is
involved: the column has existed since sql/001, and both apps and the portal
read the same value. Display names normalise to ISO 3166-1 alpha-2 before
comparison ("Australia" → `AU`, "United Kingdom"/"uk" → `GB`; both apps use an
identical table in `ChemicalRegistration.normaliseCountry`). The supported
vineyard country set and alias rules are pinned in
`docs/vineyard-country-contract.md` ("VineTrack Supported Vineyard Countries —
Contract v1", 30 countries — note that vineyard-country support does NOT imply
a wired chemical register for that country).

1. Pass the vineyard's country on EVERY `chemical-info-lookup` call (`country`
   body field, all actions). NEVER substitute the browser or device locale —
   the locale says where the machine is set up, not where the vines grow. A
   missing vineyard country fails CLOSED: search is disabled with a "set your
   vineyard's country" prompt, and nothing can be verified.
2. The server scopes master-catalogue matching to that country (the identity
   key embeds it; name/alias matching filters on `registration_country`, and
   the served row is re-checked against the requested country) and stamps the
   AI extraction's `registration.country_code` with the REQUESTED country —
   the AI's own country claims are never trusted. With no country supplied it
   returns `"country"` in `verification.unresolved_fields` and no master
   match is possible.
3. Clients still gate every `action=structured` response before consuming it
   (both apps route through `ChemicalJurisdiction`; the portal must mirror
   it): reject when the country prefix of `master.registration_identity_key`
   differs from the vineyard country, or when `registration.country_code` is
   non-empty and differs. A rejected response is handled exactly like a
   failed lookup — nothing converted, previewed, saved or linked.
4. Consequently a cross-country row can never become a master match, and a
   foreign label's rates, withholding periods, re-entry statements or
   registered uses can never enter a Saved Chemical. Pinned by the GB
   Custodia counter-fixture (`GB:other:16393`) in both parity suites (§10)
   and `docs/chemical-custodia-parity-fixture.md` §6.
5. Re-verify keys on the RECORD's own registration country; the vineyard
   country is only a fallback when the record carries none, and the check is
   refused entirely when neither exists. Re-verification never re-keys a
   record to a different country's label.

### 12.4 Saved Chemical jurisdiction suitability (computed, never stored)

Rules 1–5 stop foreign data getting IN. This rule governs what an
already-saved record may CLAIM when the vineyard's country differs from the
record's own `registration.country_code` (e.g. an `AU:apvma:66541` product
viewed from an NZ vineyard):

- Suitability is computed on read — `compatible` (countries match),
  `mismatch` (both known, different) or `unknown` (either side has no
  country). Nothing is persisted and the record is NEVER re-keyed. Both apps
  compute it in `ChemicalJurisdiction.suitability`; the portal must mirror
  it.
- On `mismatch`, identity and chemistry stand — name, actives,
  concentrations, FRAC/HRAC/IRAC groups and the original registration
  identity — but the record's registered uses, label rates, withholding
  periods, re-entry statements and label restrictions are NOT
  vineyard-authoritative. Present them as another jurisdiction's label
  ("Registered for Australia — current vineyard is New Zealand", "Verify a
  New Zealand registration before using label-specific guidance"). Never
  silently substitute another country's registration; never hard-block the
  product — the requirement is no false label authority, not a fake
  regulatory stop.
- Re-verify on a mismatched record re-checks its OWN registration (rule 5) —
  useful for confirming what the product IS — but its result must never be
  presented as "verified for this vineyard".
- `unknown` is not a mismatch: legacy/manual records without a registration
  country show no banner (they already carry no label authority), and a
  vineyard without a country stays fail-closed per rule 1.
- Resistance chemistry is unaffected by suitability: FRAC/HRAC/IRAC groups
  keep feeding resistance tracking regardless of label country. Only
  country-scoped registration logic (e.g. which products a published
  national strategy may recommend) keys on jurisdiction, and it does so
  separately.
