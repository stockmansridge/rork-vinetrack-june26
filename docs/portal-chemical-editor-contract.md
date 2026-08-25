# Portal implementation contract — Chemical record editor

**Owner:** Lovable (Portal UI and call-sites)
**Backend owner:** Rork (`chemical-info-lookup`, shared contracts, SQL)
**Status:** implementation-ready. iOS ships this structure; the Portal must
match the information architecture, terminology and rules below.

The controls may differ — a browser is not a phone — but a grower must
recognise the same chemical record on both. **Do not design a separate Portal
chemical editor.**

---

## 0. Non-negotiables

The Portal renders and edits. It does not decide.

**The Portal must NOT:**

- rank, re-rank, re-score or fuzzy-match search candidates
- filter candidates out of the returned list
- auto-select a product because it sorted first
- parse label rates, or convert between rate bases
- resolve product identity, or derive a verification status
- infer a resistance group, a withholding period or a re-entry period
- branch on any value in the `diagnostics` envelope

Every one of those is server-owned. Ranking used to live in each client
independently, which is exactly why `Hortitrol winter oil` resolved to APVMA
50067 on the Portal and 33182 on iOS. Reintroducing any of it re-opens that
defect.

---

## 1. Search and candidate rendering

### Request

Send the `client` block on **both** `action: "search"` and
`action: "structured"`:

```jsonc
{
  "action": "search",
  "query": "Hortitrol winter oil",
  "country": "AU",
  "client": {
    "platform": "portal",
    "app_version": "1.4.2",
    "app_build": "318",
    "correlation_id": "b6f0c1e2-…"
  }
}
```

- `platform` — the literal `"portal"`. Never derived from the user agent.
- `correlation_id` — a **fresh UUID per request**, not per session. Log it
  Portal-side; the server echoes it as `diagnostics.correlation_id`, which is
  what lets a Portal console line be joined to a server log line.

All four fields are optional and never affect the answer. Omitting them
degrades diagnostics only.

### Rendering candidates

`results` arrives **in the order it must be displayed**. Render it verbatim.

Each row carries:

| Field | Use |
|---|---|
| `rank_tier` | `approved_master` \| `official_register` \| `suggestion` \| `weak_match` — group headings |
| `rank_relevance` | `exact_name` … `unrelated` — explain an ordering if asked |
| `rank_score` | 0–100, display only |
| `rank_reason` | `"<relevance>/<tier>"`, for support |
| `register_order` | Position *before* ranking. Debug only. |

`weak_match` rows are **demoted, never deleted**. Show them under a heading
such as *"Other register matches"*. A vineyard searching a regional adjuvant by
a generic word must still find it.

### Auto-selection

Read `ranking.exact_registration_number`:

- **non-null** — exactly one candidate is an unambiguous exact identity. Safe
  to select automatically.
- **null** — a human chooses, even if the first row scores highest.

`ranking.ambiguous === true` means several credible products answer the query.
Keep showing the ~2–5 candidates; never collapse to one.

### Detail lookup

Once a candidate is chosen, resolve with **country + exact registration
number** — never by re-sending the original free-text query.

---

## 2. Section order

Exactly this order, on both platforms:

1. **Product**
2. **Active Ingredients & Resistance**
3. **Grapevine Uses & Rates**
4. **Labels & References**
5. **Purchase / Pricing**
6. **Notes**
7. **Advanced / Verification Evidence** (collapsed)

The order is the workflow: identify the product → confirm its chemistry and
resistance → confirm the grapevine rates → reach the labels → save. Pricing,
notes and provenance follow because none of them is why the screen was opened.

### 1. Product

Product name · registration number · category · form/unit · manufacturer.

The registration number belongs **in this section, visible** — not behind a
disclosure. It is the only thing that distinguishes two similarly named
registrations. Label it in the jurisdiction's own words (*"APVMA Registration
Number"* in AU, the ACVM/EPA equivalent in NZ); never a generic
*"Registration Number"*.

Never *demand* it for an unverified record.

### 2. Active Ingredients & Resistance

Per active: name · concentration + unit · classification scheme (FRAC / HRAC /
IRAC / Not applicable) · group code.

Plus a **product-level resistance state badge** from
`resistance_classification_state` (sql/210):

| State | Presentation |
|---|---|
| `classified` | Positive/normal. Show scheme + code. |
| `not_applicable` | **Neutral grey. Not a warning.** |
| `unresolved` | **Warning / orange, clearly visible.** |

`not_applicable` must not be styled as a fault. An adjuvant with no resistance
group is a correct, complete record; colouring it red trains growers to "fix"
something already right.

`unresolved` is the one that needs attention — it means the product is
currently left out of resistance warnings and the Resistance Planner. Say so.

Never render a blank where a state exists. The three-way distinction is the
entire point of sql/210.

### 3. Grapevine Uses & Rates — the most important section

Group by **grapevine target/use**, not by database field. Per use:

- target pest/disease
- **`/100 L` rate(s) first**
- `/ha` rate(s) underneath, where present
- the condition/timing attached to each rate
- WHP
- REI
- important restrictions

Other crops stay available but secondary — collapsed under *"Other crops on
this label"*.

Conceptually:

```text
Grapevine — Grapevine Scale

  Preferred rate      2 L / 100 L      (Dilute spraying)
  Also registered     4 L / ha         (Airblast)
  WHP                 Not stated
  Resistance          Not applicable
  Restrictions        Apply as a post-pruning application while
                      vines are fully dormant.
```

### 4. Labels & References

**Two distinct fields.** Not one "link".

- **Official regulator label** — the authoritative document. Name it after the
  regulator (*"APVMA label"*), give it a prominent **Open label** action, and
  prefer the official PDF. Expected for anything Verified.
- **Manufacturer reference** — a separate, visibly secondary, optional field.

A marketing page must never be able to pass for an approved label. Manufacturer
information is supplementary and never substitutes for the regulatory label.

### 5. Purchase / Pricing

Compact and secondary. Pricing must not dominate chemical verification.

### 6. Notes

Plain optional free text.

### 7. Advanced / Verification Evidence

**Collapsed by default.** Everything below moves here:

`field_provenance` · `verification.sources` · `match_source` · discovery
metadata · label-extraction internals · `intelligence_schema_version` ·
`activity_group_table_version` · `verification_unresolved_fields` internals ·
AI suggestion/debug payloads · the register-scheme and country pickers.

The verification **result** (`verification_status`) stays visible outside the
disclosure. Growers need the verdict, not the working.

---

## 3. Rates — the structured contract

A registered use holds an **array** of independent rates. Never one rate.

```jsonc
{
  "crop": "Grapevines",
  "target_raw": "Grapevine scale",
  "rates": [
    { "label": "Dilute spraying",      "basis": "per_100_litres",
      "value": 2, "unit": "L", "raw_text": "Dilute spraying: 2 L/100 L …" },
    { "label": "Concentrate spraying", "basis": "per_100_litres",
      "value": 3, "unit": "L", "raw_text": "…" },
    { "label": "Airblast",             "basis": "per_hectare",
      "value": 4, "unit": "L", "raw_text": "…" }
  ]
}
```

Bases: `per_100_litres` · `per_hectare` · `range_per_100_litres` ·
`range_per_hectare` · `other`.

Rules:

- **Retain every rate.** Multiple `/100 L` rates stay separate. Multiple `/ha`
  rates stay separate. Both bases coexist on one use.
- **Never convert between bases.** A `/100 L`-only label has no hectare rate,
  and vice versa. Converting would require a carrier volume the label never
  stated.
- **Never discard the hectare rate.** The `/100 L` preference is presentation
  and calculation ordering only.
- **Prefer an unambiguous `/100 L` rate** for the spray workflow when one
  exists — that is the basis VineTrack's dilute/concentrate calculations are
  built on.
- Ranges keep **both** bounds. Never flatten to a single value. When a range
  must propose one number, propose the **low** end.
- `basis: "other"` carries verbatim wording only. It is **not a usable rate** —
  no calculation may run on it — but it is a faithful record and must be kept
  and displayed.
- Each rate's `label` is its **condition** ("Dilute spraying", "Early season").
  Display it with its rate. Never merge several rates into one string.
- `raw_text` is the verbatim label wording. Preserve it alongside the
  structured values.

### `condition_ambiguous`

When `true`: the label states several rates on that basis and the server could
not prove which condition governs which number.

- The numbers **are** authoritative. Show them all.
- The **association** is not. Say so plainly — e.g. *"The label states these
  rates without saying which condition applies to each."*
- **Do not auto-select or auto-apply an ambiguous rate to a spray
  calculation.** The operator must resolve the condition first.
- Resolution is **naming the condition** — entering/selecting the `label`.
  Changing the rate value, the unit or the basis resolves **nothing**: none of
  those says *when* the rate applies.
- Once named, the flag clears **for that rate only**. Siblings stay open.

An ambiguous rate does **not** block saving. The label really does state it.

---

## 4. WHP / REI

- Missing stays `null`. **Never infer `0`.**
- Never display `0 days` or `0 hours` unless authoritative information supports
  zero.
- Unstated → *"Not stated"*.
- `0` may read as *"Not required when used as directed"* **only** where the
  label's own wording carries that phrase, or the payload cites the
  manufacturer's approved label as a source. An AI-only or operator-typed zero
  stays a plain *"0 days"*.
- Neither field is ever mandatory to save.

---

## 5. Mandatory save rules

The authoritative implementation is
`supabase/functions/chemical-info-lookup/save_contract.ts`
(`evaluateChemicalSave`). Call it or mirror it exactly — do not invent a
parallel rule set.

### Required for a spray-ready chemical

- product name
- product category (the calculation model needs it to pick litres vs kilograms)
- at least one active ingredient **name**, where the product has actives at all
  (a product with no actives is a legitimate adjuvant — absence is not a fault;
  a half-typed row with no name is)
- at least one **grapevine** registered use
- at least one **usable rate** on a grapevine use
- rate unit
- recognised rate basis
- a stated `resistance_classification_state`

### Additionally required to save as Verified

- registration number **and** country
- official regulator label reference

### Never mandatory

WHP · REI · manufacturer URL · a resistance *code* (`not_applicable` and
`unresolved` are both acceptable answers — only silence is refused).

### A rate counts as usable only when it has

- a positive numeric `value`, **or** an ordered `min_value`/`max_value` pair
- a non-empty `unit`
- a basis in {`per_100_litres`, `per_hectare`, `range_per_100_litres`,
  `range_per_hectare`}

A non-empty `raw_text` is **not** sufficient.

### Error presentation

Show each violation **against the section it belongs to**, using the
`field` on each violation (`product_name`, `product_category`,
`active_ingredients`, `registered_uses`, `rates`, `registration`,
`label_reference`, `resistance`).

**Do not** show a generic validation error at the foot of the form.

Use these exact messages:

- `Rate not found — enter the rate from the label before saving.`
- `A verified product needs a link to the official regulator label.`
- `A verified product needs its registration number and country.`
- `Choose the product category so VineTrack knows how to measure it.`
- `Add the grapevine use this product is registered for.`
- `Set the resistance group, or mark it as not applicable.`

### The "never make it worse" rule — required

Measure the record **as opened** and remember which violations it already had.
A pre-existing violation must **not** block saving; only a violation this edit
*introduces* may.

Without this, every legacy record becomes uneditable: a
pre-Chemical-Intelligence product has no structured grapevine use and no
structured rate, so an operator opening one to fix a price would find Save
permanently disabled — and a record that cannot be saved cannot be repaired.

- Pre-existing faults → show as **guidance** (neutral styling), with wording
  such as *"This was already missing before you opened the product — you can
  still save, and fill it in when you have the label."*
- New faults → show as **blocking** warnings and disable Save.
- A brand-new record has no baseline, so the full contract applies.
- A compliant record can never be edited into non-compliance.

### Manual entry

Manual entry stays possible when automated research fails, and must satisfy the
**same** minimum functional requirements. A manual record stays clearly
**Unverified** — manual entry never manufactures verification.

---

## 6. Diagnostics

Both responses carry a `diagnostics` envelope; `search` also carries `ranking`.
Both are additive.

Diagnostics are **observation only**. Never branch on them. A lookup that
answers differently because the Portal asked would destroy the parity guarantee
the envelope exists to prove.

---

## 7. Production parity verification — OPEN

Still outstanding, and not closed by this document. Once the diagnostic-enabled
`chemical-info-lookup` is deployed and the Portal sends its `client` block, run:

```text
query:   Hortitrol winter oil
country: AU
```

and return, from the Portal response:

1. `diagnostics.server.lookup_version`
2. `diagnostics.server.project_ref`
3. `diagnostics.candidate_registration_numbers` (in order)
4. `diagnostics.degraded`

These are compared against the iOS run. iOS computes a one-line fingerprint —
`build|project|country|method|[ordered registrations]` — and the two platforms
must produce identical strings.

Then select the same registration on both and confirm the structured payload
matches: identity, active ingredients, resistance classification, grapevine
uses, `/100 L` rates, `/ha` rates, restrictions, official label, manufacturer
reference, and that WHP/REI are `null` rather than `0` where the label is
silent.
