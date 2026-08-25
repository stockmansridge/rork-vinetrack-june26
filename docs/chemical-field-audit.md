# Chemical record — field audit

Classification of every field currently displayed or stored for a vineyard
chemical, and the reasoning behind each verdict. This is the audit that had to
precede the New Chemical redesign (task §6): the screen had grown to expose
research provenance beside label rates, with no statement of which fields the
app actually depends on.

Three verdicts:

- **Critical** — VineTrack cannot calculate, comply, identify the product or
  manage resistance without it.
- **Useful** — genuinely valuable, but the normal save/use workflow does not
  depend on it.
- **Backend / low-value** — research provenance and internal evidence
  metadata. Kept in the record for auditing; removed from the normal screen.

The guiding test for the third category: *does a grower ever act on this?* If
the answer is "no, but support or an auditor might", it belongs behind
Advanced. Storing a field is not a reason to display it.

---

## Critical

| Field | Why it is critical |
|---|---|
| `name` (product name) | Product identity; the one field nothing works without. Mandatory in the save contract. |
| `registration_number` | The ONLY thing that distinguishes two similarly named registrations. Drives register matching, master-catalogue linking and re-verification. |
| `registration_country` | An AU registration and an NZ registration with the same brand name are different products with different label law. Identity is country-scoped. |
| `product_category` | Selects litres vs kilograms in the calculation model. A product without one cannot be dosed. |
| `product_form` / `unit` | Dose arithmetic and pack maths. |
| `active_ingredients[].name` | Resistance is a property of each active, not of the product. A two-active mixture belongs to two groups at once. |
| `active_ingredients[].concentration` + `concentration_unit` | Part of label identity; distinguishes formulations of the same active. Never guessed — a wrong concentration silently mis-doses. |
| `active_ingredients[].activity_group.scheme` | FRAC/HRAC/IRAC. A bare code is ambiguous: FRAC 3 and IRAC 3 are unrelated chemistries. |
| `active_ingredients[].activity_group.code` | The value the Resistance Planner rotates on. |
| `resistance_classification_state` | sql/210. Distinguishes *classified* / *not_applicable* / *unresolved*. Without it an empty group array reads as "no resistance concern", and the Planner would pass two unclassified Group 11 products as a compliant rotation. |
| `registered_uses[].crop` | Establishes that the product is registered on grapevines at all. |
| `registered_uses[].target_raw` | The disease the label names. "Group 11 therefore powdery" is an assumption, not a registration. |
| `registered_uses[].rates[].value` / `min_value` / `max_value` | The spray calculation input. |
| `registered_uses[].rates[].unit` | A number without a unit is not a rate. |
| `registered_uses[].rates[].basis` | `/100 L` and `/ha` are different instructions. Never converted between. |
| `registered_uses[].rates[].condition_ambiguous` | Prevents a spray calculation silently applying one of several rates the label never attributed. |
| `registered_uses[].rates[].label` (condition) | Which condition the rate applies under — and the operator's route to resolving ambiguity. |
| `withholding_period_days` | Compliance. **Nullable** — see the WHP/REI note below. |
| `re_entry_period_hours` | Compliance. **Nullable**. |
| `registered_uses[].restrictions` | Label conditions a grower must observe ("apply while vines are fully dormant"). |
| `label_reference` (official regulator label) | The authoritative document. Expected for anything claiming Verified. |
| `verification_status` (the RESULT) | Whether the record may be trusted. The result is critical; the *evidence* behind it is not. |

### WHP and REI are critical AND nullable

Both belong in this table because a spray cannot be signed off without knowing
whether a withholding period applies. Neither is ever *mandatory to save*: a
label that states no withholding period is a complete label, and demanding a
number would make the operator invent regulatory information. Missing stays
`null`; it is never inferred as `0`.

---

## Useful

| Field | Why it is useful rather than critical |
|---|---|
| `registrant` / manufacturer | Helps confirm the right product, and growers recognise brands. Nothing calculates from it. |
| `product_url` (manufacturer page) | Supplementary reference. Must never substitute for the regulator label. |
| Other-crop registered uses | Real label content and worth keeping in full, but not what a vineyard acts on. Collapsed under "Other crops on this label". |
| `notes` | Free-text operational memory. |
| `purchase.cost_dollars`, `container_size` | Feeds spray cost reporting. Valuable, but pricing must not dominate chemical verification. |
| `pack_size`, `price_per_pack`, `density`, `inventory_quantity` | Fertiliser Calculator inputs. Shown only for fertiliser/nutrient categories. |
| `nitrogen_percent`, `phosphorus_percent`, `potassium_percent`, `analysis_basis` | Fertiliser nutrient analysis. Same conditional visibility. |
| `organic_certified` | Certification reporting. |
| `application_notes` | Fertiliser guidance. |
| `mode_of_action` (legacy free text) | Carried through untouched for old records. Superseded by structured groups; never parsed. |
| `label_version` | Useful when comparing a re-verification against what was previously held. |

---

## Backend / low-value — removed from the normal screen

All of these remain in the record and remain queryable. None is displayed in
the normal workflow.

| Field | Why it left the screen |
|---|---|
| `verification_sources[]` | Rows of source type, extraction method and URLs. The operator needs the verdict, not the working. |
| `field_provenance` | Per-field evidence tier. Genuinely valuable for audit; meaningless as a form field. |
| `match_source` | How the candidate was found. Internal. |
| Discovery envelope (`discovery.outcome`, `adapter`, `cache`) | Pipeline mechanics. |
| `label_extraction` internals (`unbound_rows`, `parser_version`, geometry reasons) | Diagnostic detail for a failed extraction. Belongs to support, not to a grower. |
| `verification_unresolved_fields[]` | Internal field names (`rates:GRAPEVINE`). The *effect* is now shown as a save-contract message in plain words next to the section it concerns. |
| `intelligence_schema_version` | Contract version. Never actionable. |
| `activity_group_table_version` | Which FRAC/HRAC/IRAC table revision classified the row. Audit only. |
| `ai_suggestion` / debug payloads | Never authoritative by definition. |
| `registration_scheme` picker | Derived from the country. Offering it invited a grower to select a register that does not exist in their jurisdiction. |
| `country_code` picker | Set by the lookup; editable only in Advanced for the imported-product case. |
| Sharing notice ("shared with all users of this vineyard") | True, but static text occupying a whole section. Moved to Advanced. |
| `sync_version`, `client_updated_at` | Sync plumbing. Never user-facing. |

---

## What this changed on the screen

Before: 11 top-level sections, with `Product Page URL` beside `Official Label
URL` under a shared heading of "Details", registration identity hidden inside a
"Technical Details" disclosure, and unresolved-field internals printed as raw
column names.

After: 7 sections in workflow order, registration identity promoted into
**Product** (it establishes identity — burying it made the single most
identifying fact the hardest thing to find), the two label references split and
individually named, and every piece of research provenance behind **Advanced /
Verification evidence**.

The verification *result* stayed visible. Only the machinery moved.
