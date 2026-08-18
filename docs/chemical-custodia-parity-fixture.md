# Chemical Intelligence — Custodia cross-platform parity fixture

**Status:** Authoritative regression fixture. iOS, Android and the web portal must all produce the outcomes in section 3 for the payload in section 2.
**Pinned by:** `ios/VineTrackTests/ChemicalCustodiaParityTests.swift` and `android-vinetrack/.../data/ChemicalCustodiaParityTest.kt` (byte-identical JSON in both).
**Contract:** `docs/chemical-intelligence-json-contract.md` (sql/194 wire format).

## 1. Why Custodia, and where the values come from

Custodia was chosen because one real product exercises every defect class the
lookup pipeline must never regress on: a two-active mixture, a sibling product
with a near-identical name, the same brand name registered separately in other
countries, per-use rates/WHPs that must not merge, and a narrative re-entry
statement that must not become an invented number.

Resolved from authoritative sources (2026-08-18), **not** from any previously
hard-coded app or portal values:

| Fact | Value | Source |
|---|---|---|
| AU registered product | Custodia 320 SC, **APVMA 66541** | AWRI "Agrochemicals registered for use in Australian viticulture" update (Sept 2012, grant of registration); APVMA label mirror (agrobaseapp AU) |
| Registrant | Adama Australia Pty Ltd (registered originally by Farmoz Pty Ltd, rebranded Adama) | AWRI update; Adama Australia product literature |
| Actives | Azoxystrobin **120 g/L** (FRAC **11**), Tebuconazole **200 g/L** (FRAC **3**), suspension concentrate | Adama Australia tech notes; APVMA label mirror |
| Grapevine use | Powdery mildew; dilute 65 mL/100 L, concentrate 1 L/ha; harvest WHP **4 weeks**; max 2 sprays/season, protectant only; export: no later than 80 % capfall | APVMA label mirror (Directions for Use); AWRI update |
| Wheat use | Rusts/leaf diseases; 315–630 mL/ha; harvest WHP 6 weeks, grazing 21 days | APVMA label mirror |
| Re-entry | Narrative only ("do not re-enter until spray has dried") — **no numeric hours on the label** | Label wording |
| Sibling product | **Custodia Forte, APVMA 91636** — Azoxystrobin 222 g/L + Tebuconazole 370 g/L. Similar name, DIFFERENT registration, different concentrations | Adama Australia product page; APVMA label mirror |
| Same brand overseas | UK "Custodia", MAPP **16393** — a different national registration entirely | HSE/UK label mirror |

> Currency caveat: Adama's current AU grape offering is Custodia Forte; the
> original Custodia registration may lapse or be superseded at any renewal
> cycle. That does not weaken the fixture — it pins pipeline behaviour, not a
> product recommendation — but any future Master Chemical Catalogue seed must
> re-confirm currency against APVMA PubCRIS before approving the row.

## 2. Canonical fixture — `action=structured` response for "Custodia" in Australia

This is exactly what the `chemical-info-lookup` edge function is expected to
return (shape per the JSON contract). Note `retrieved_at` is an ISO-8601
**string** and `verified_at` is `null` — both must decode on every platform.

```json
{
  "product_name": "Custodia 320 SC",
  "product_category": "fungicide",
  "form_type": "liquid",
  "registration": {
    "country_code": "AU",
    "scheme": "apvma",
    "registration_number": "66541",
    "registrant": "Adama Australia Pty Ltd",
    "registered_product_name": "Custodia 320 SC"
  },
  "active_ingredients": [
    {
      "name": "Azoxystrobin",
      "concentration": 120,
      "concentration_unit": "g/L",
      "activity_group": { "scheme": "frac", "code": "11", "common_name": "QoI / Strobilurin" },
      "group_source": "authoritative_classification",
      "identity_source": "ai_interpretation"
    },
    {
      "name": "Tebuconazole",
      "concentration": 200,
      "concentration_unit": "g/L",
      "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
      "group_source": "authoritative_classification",
      "identity_source": "ai_interpretation"
    }
  ],
  "activity_groups": ["11", "3"],
  "activity_group_scheme": "frac",
  "registered_uses": [
    {
      "crop": "Grapevines",
      "target": "powdery_mildew",
      "target_raw": "Powdery mildew",
      "rates": [
        { "label": "Dilute spraying", "basis": "per_100_litres", "value": 65, "unit": "mL" },
        { "label": "Concentrate spraying", "basis": "per_hectare", "value": 1, "unit": "L" }
      ],
      "withholding_period_days": 28,
      "restrictions": "Protectant only. DO NOT apply more than 2 sprays per season. Export grapes: do not use later than 80% capfall. Do not re-enter treated areas until the spray has dried."
    },
    {
      "crop": "Wheat",
      "target_raw": "Stripe rust",
      "rates": [
        { "label": "Standard", "basis": "range_per_hectare", "min_value": 315, "max_value": 630, "unit": "mL" }
      ],
      "withholding_period_days": 42,
      "restrictions": "Harvest WHP 6 weeks. Grazing WHP 21 days."
    }
  ],
  "label_rate_bases": ["per_100_litres", "per_hectare", "range_per_hectare"],
  "verification": {
    "status": "partially_verified",
    "sources": [
      { "kind": "ai_interpretation", "name": "Model extraction (gpt-4o)", "retrieved_at": "2026-08-18T00:00:00Z" },
      { "kind": "authoritative_classification", "name": "VineTrack activity group reference v1 (FRAC/HRAC/IRAC)", "retrieved_at": "2026-08-18T00:00:00Z" }
    ],
    "conflicts": [],
    "unresolved_fields": ["label_reference", "label_version", "re_entry_period_hours"],
    "verified_at": null
  },
  "activity_group_table_version": 1,
  "schema_version": 1
}
```

## 3. Required outcomes — identical on iOS, Android and the portal

After converting the payload into the structured model (and before any human
verify step):

1. **Actives stay separate.** Exactly 2 actives: Azoxystrobin 120 g/L and
   Tebuconazole 200 g/L, each with its own concentration, unit and group
   (FRAC 11 / FRAC 3). Never one merged string; never a swapped concentration.
2. **Canonical groups.** Queryable codes are `["3", "11"]` — sorted
   canonically regardless of active order, one entry per group, never
   `["3 + 11"]`. Scheme `frac`.
3. **Country-scoped identity.** Registration identity key is
   `AU:apvma:66541`. UK Custodia (MAPP 16393) produces `GB:other:16393` — a
   different identity. Rates/actives must never cross that boundary.
4. **AI can never verify.** Resolved verification status is
   `partially_verified`; the product is not resistance-dependable. Even a
   stored `verified` claim resolves back down while `unresolved_fields` is
   non-empty. Promotion to Verified is a human step, only ever recorded with
   authoritative evidence.
5. **Uses stay attached.** Two registered uses. Grapevines: 65 mL/100 L
   (dilute) + 1 L/ha (concentrate), WHP 28 days, restrictions retained
   verbatim (incl. "80% capfall"). Wheat: 315–630 mL/ha range (never
   collapsed to a midpoint), WHP 42 days. The two WHPs never bleed into each
   other.
6. **Re-entry honesty.** `re_entry_period_hours` is **absent** on both uses —
   the label statement is narrative and stays in `restrictions`;
   `re_entry_period_hours` is listed in `unresolved_fields`. No conversion of
   "until spray has dried" into hours, ever.
7. **Legacy projections are outputs.** `active_ingredient` projection is
   `"Azoxystrobin 120 g/L + Tebuconazole 200 g/L"`; `chemical_group`
   projection is `"3 + 11"`. Nothing parses them back.
8. **Similar names never merge.** Custodia Forte (`AU:apvma:91636`,
   222/370 g/L) must never auto-match Custodia: the duplicate gate keys off
   registration identity only, and spray-line name matching requires an exact
   (trimmed, case-insensitive), UNIQUE name — no substring or fuzzy matching.
9. **Historical immunity.** A spray recorded with Custodia freezes this
   chemistry into its line snapshot; later correcting or re-verifying the
   product must not restate that history (pinned by the snapshot suites).

## 4. Portal notes

- Write the record through the sql/194 columns per the JSON contract
  (`registration_number "66541"`, `registration_scheme "apvma"`,
  `registration_country "AU"`, `activity_groups {'3','11'}` …).
- The portal's Lookup → Apply must consume `active_ingredients[]` as the
  source of truth — never re-parse the display string
  `"Azoxystrobin 120 g/L + Tebuconazole 200 g/L"`.
- On save, duplicate-check on the registration identity key before inserting a
  second "Custodia" for the same vineyard; offer "update existing" exactly as
  the apps do.

## 5. Master catalogue envelope variant (sql/199)

When this product is served from the APPROVED Master Chemical Catalogue, the
response is the §2 payload with its closing brace replaced by (identical
fragment in both test suites):

```json
,
  "match_source": "master",
  "master": {
    "master_chemical_id": "c0570d1a-2026-4a66-9541-a99f66541001",
    "master_revision": 4,
    "catalogue_status": "approved",
    "registration_identity_key": "AU:apvma:66541"
  }
}
```

Required outcomes, pinned by the same two suites:

1. Decodes with each platform's standard lookup decoder; `match_source` of
   `ai_candidate` / `unresolved` / absent never reads as a master match.
2. The envelope is ADDITIVE — chemistry converts identically to §3, and the
   evidence gate still rules (master-served is not verified-by-magic).
3. Applying a master-served lookup stores `master_chemical_id` +
   `master_source_revision` on the vineyard record; AI-sourced saves leave any
   stored link untouched (columns omitted, never nulled). Vineyard commercial
   edits (price, stock) never move the link; a later master revision is
   detectable as `master_revision > master_source_revision` — resolved only
   via Re-verify, never by silent rewrite.
4. Custodia Forte (`AU:apvma:91636`) and UK Custodia (`GB:other:16393`) can
   never inherit this master identity.
5. `sql/199` seeds this fixture into `public.master_chemicals` as a
   **candidate** (id `c0570d1a-2026-4a66-9541-a99f66541001`), so it is NEVER
   served to lookups until an admin re-confirms APVMA PubCRIS currency and
   approves it (Stage 2 review). The `master_revision: 4` above is a test
   value exercising drift detection, not the seeded row's revision (which is 1).

## 6. Cross-jurisdiction counter-fixture (GB Custodia, MAPP 16393)

The SAME brand name registered under a DIFFERENT country's label law. Both
test suites carry this payload byte-identically (`CUSTODIA_GB_FIXTURE_JSON` /
`custodiaGBFixtureJSON`) — cereal uses only, a different rate (2 L/ha), a
numeric re-entry period (48 h) and a different WHP (35 days), none of which
exist on the AU label:

```json
{
  "product_name": "Custodia",
  "product_category": "fungicide",
  "form_type": "liquid",
  "registration": {
    "country_code": "GB",
    "scheme": "other",
    "registration_number": "16393",
    "registrant": "Adama Agricultural Solutions UK Ltd",
    "registered_product_name": "Custodia"
  },
  "active_ingredients": [
    { "name": "Azoxystrobin", "concentration": 120, "concentration_unit": "g/L",
      "activity_group": { "scheme": "frac", "code": "11", "common_name": "QoI / Strobilurin" },
      "group_source": "authoritative_classification", "identity_source": "ai_interpretation" },
    { "name": "Tebuconazole", "concentration": 200, "concentration_unit": "g/L",
      "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
      "group_source": "authoritative_classification", "identity_source": "ai_interpretation" }
  ],
  "activity_groups": ["11", "3"],
  "activity_group_scheme": "frac",
  "registered_uses": [
    { "crop": "Winter wheat", "target_raw": "Septoria leaf blotch",
      "rates": [ { "label": "Standard", "basis": "per_hectare", "value": 2, "unit": "L" } ],
      "withholding_period_days": 35, "re_entry_period_hours": 48,
      "restrictions": "Latest application before grain milky ripe (GS 71). Maximum 2 applications per crop." }
  ],
  "label_rate_bases": ["per_hectare"],
  "verification": { "status": "partially_verified", "sources": […], "conflicts": [],
    "unresolved_fields": ["label_reference", "label_version"], "verified_at": null },
  "activity_group_table_version": 1,
  "schema_version": 1
}
```

A master-served variant exists too (suffix swap as in §5) with
`"registration_identity_key": "GB:other:16393"`, master id
`b1638c93-2026-4b77-8642-b88f16393002`, revision 2.

Required outcomes, pinned by the same two suites (the portal must reproduce
them — see JSON contract §12.3):

1. The vineyard's country (`vineyards.country`) is the ONLY lookup
   jurisdiction. Never the device/browser locale — with no vineyard country,
   search fails closed and NOTHING from a lookup is consumable or verifiable.
2. For an AU vineyard, this GB payload is rejected OUTRIGHT by the
   jurisdiction gate (`ChemicalJurisdiction`, both platforms) — handled
   exactly like a failed lookup, so the GB rates, WHP (35), re-entry (48 h)
   and winter-wheat uses can never be converted, previewed, saved, linked or
   verified. The same payload passes for a GB vineyard: the block is
   jurisdiction, not decode.
3. The GB MASTER envelope can never become a master match for an AU vineyard
   — rejected before `isMasterMatch` is ever consulted, so neither the GB
   link nor the GB chemistry can be threaded into a save. Equally the AU
   master envelope is rejected for an NZ vineyard.
4. Re-verify keys on the record's own registration country (`AU:apvma:66541`
   stays AU even when the vineyard fallback says NZ); with no country
   anywhere it is refused, never guessed.
5. Country display names normalise to ISO codes identically on both
   platforms ("United Kingdom"/"uk" → GB, "Australia" → AU); an unmapped
   name can never equal a server-stamped ISO code, so the gate fails closed
   for it.
6. Saved Chemical suitability is COMPUTED, never stored
   (`ChemicalJurisdiction.suitability`, JSON contract §12.4): the AU record
   (`AU:apvma:66541`) viewed from an NZ vineyard reads `mismatch(AU, NZ)` —
   identity and FRAC 3 + 11 chemistry retained, AU uses/rates/WHP/re-entry
   NOT treated as NZ-authoritative, and re-verifying it (which stays keyed
   to AU) can never produce "verified for NZ". The inverse GB-in-AU case
   reads `mismatch(GB, AU)`.
7. `compatible` requires both countries known and equal; `unknown` (legacy
   record without a registration country, or vineyard country unset) shows
   no mismatch banner but also establishes no label authority.
