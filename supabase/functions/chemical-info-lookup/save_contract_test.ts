import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  type ChemicalSaveInput,
  evaluateChemicalSave,
  isAutoApplicableRate,
  isUsableRate,
  type SaveViolationCode,
} from "./save_contract.ts";

// ===========================================================================
// Task §11 — the mandatory save contract.
//
// The rule being protected: VineTrack must not store a chemical it cannot
// USE. The rule being deliberately NOT enforced: completeness for its own
// sake. WHP, REI and the manufacturer URL stay optional, because forcing an
// operator to supply information the label never printed manufactures
// regulatory data.
// ===========================================================================

/** A record that satisfies the contract, used as the base for each case. */
const valid = (): ChemicalSaveInput => ({
  product_name: "HORTITROL WINTER OIL",
  product_category: "insecticide",
  active_ingredients: [
    { name: "Paraffinic oil", activity_group: { scheme: "not_applicable", code: "" } },
  ],
  registered_uses: [
    {
      crop: "Grapevines",
      target_raw: "Grapevine scale",
      rates: [{ basis: "per_100_litres", value: 2, unit: "L" }],
    },
  ],
  registration: {
    registration_number: "50067",
    country_code: "AU",
    label_reference: "https://portal.apvma.gov.au/label/50067.pdf",
  },
  resistance_classification_state: "not_applicable",
});

const codes = (input: ChemicalSaveInput, intent: "spray_ready" | "verified" = "spray_ready") =>
  evaluateChemicalSave(input, intent).violations.map((v) => v.code);

const has = (input: ChemicalSaveInput, code: SaveViolationCode, intent: "spray_ready" | "verified" = "spray_ready") =>
  codes(input, intent).includes(code);

// ---------------------------------------------------------------------------
// The happy path
// ---------------------------------------------------------------------------

Deno.test("a complete record passes", () => {
  const result = evaluateChemicalSave(valid());
  assert(result.ok, `expected ok, got ${JSON.stringify(result.violations)}`);
  assert(result.hasUsableViticulturalRate);
  assertEquals(result.requiresRateConditionChoice, false);
});

Deno.test("a complete record passes the stricter verified intent too", () => {
  assert(evaluateChemicalSave(valid(), "verified").ok);
});

// ---------------------------------------------------------------------------
// Identity and category
// ---------------------------------------------------------------------------

Deno.test("product name is mandatory", () => {
  assert(has({ ...valid(), product_name: "   " }, "product_name_missing"));
});

Deno.test("product category is mandatory — the calculation needs the unit", () => {
  assert(has({ ...valid(), product_category: "" }, "product_category_missing"));
});

// ---------------------------------------------------------------------------
// Active ingredients
// ---------------------------------------------------------------------------

Deno.test("a product with NO actives is allowed — adjuvants are real products", () => {
  const adjuvant = { ...valid(), active_ingredients: [] };
  assert(!has(adjuvant, "active_ingredient_name_missing"));
  assert(evaluateChemicalSave(adjuvant).ok);
});

Deno.test("an active row with no name is a fault", () => {
  assert(has(
    { ...valid(), active_ingredients: [{ name: "  " }] },
    "active_ingredient_name_missing",
  ));
});

// ---------------------------------------------------------------------------
// Grapevine use
// ---------------------------------------------------------------------------

Deno.test("a grapevine use is mandatory", () => {
  assert(has({ ...valid(), registered_uses: [] }, "grapevine_use_missing"));
});

Deno.test("a label registered only on OTHER crops does not satisfy the grapevine rule", () => {
  const apples: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Apples",
      target_raw: "Codling moth",
      rates: [{ basis: "per_100_litres", value: 9, unit: "L" }],
    }],
  };
  assert(has(apples, "grapevine_use_missing"));
});

Deno.test("'Wine grapes' and 'Grapevines' both count as viticultural", () => {
  for (const crop of ["Grapevines", "Wine grapes", "Table grapes", "Vines"]) {
    const input: ChemicalSaveInput = {
      ...valid(),
      registered_uses: [{
        crop,
        target_raw: "Powdery mildew",
        rates: [{ basis: "per_100_litres", value: 2, unit: "L" }],
      }],
    };
    assert(!has(input, "grapevine_use_missing"), `${crop} should be viticultural`);
  }
});

// ---------------------------------------------------------------------------
// The rate rule — the heart of §11
// ---------------------------------------------------------------------------

Deno.test("THE case: product and grapevine use found, but no rate extracted", () => {
  // Research identified the product and the use, and produced no rate. The
  // record must not save as though it is ready for the Spray Tool.
  const noRate: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{ crop: "Grapevines", target_raw: "Grapevine scale", rates: [] }],
  };
  const result = evaluateChemicalSave(noRate);
  assert(!result.ok);
  assert(result.violations.some((v) => v.code === "usable_rate_missing"));
  // The message tells the operator exactly what to do.
  assertEquals(
    result.violations.find((v) => v.code === "usable_rate_missing")?.message,
    "Rate not found — enter the rate from the label before saving.",
  );
});

Deno.test("verbatim wording is NOT a usable rate", () => {
  // "Apply as directed by an agronomist" is worth storing and cannot produce
  // a dose. Treating raw_text as a rate is what let unusable chemicals in.
  const verbatim: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [{ basis: "other", unit: "", raw_text: "Apply as directed by an agronomist" }],
    }],
  };
  const result = evaluateChemicalSave(verbatim);
  assert(!result.hasUsableViticulturalRate);
  assert(result.violations.some((v) => v.code === "usable_rate_missing"));
  // …but the verbatim entry itself is not reported as malformed.
  assert(!result.violations.some((v) => v.code === "rate_basis_unrecognised"));
});

Deno.test("a rate needs a unit", () => {
  assert(isUsableRate({ basis: "per_100_litres", value: 2, unit: "L" }));
  assert(!isUsableRate({ basis: "per_100_litres", value: 2, unit: "" }));
});

Deno.test("a rate needs a recognised basis", () => {
  assert(!isUsableRate({ basis: "per_acre", value: 2, unit: "L" }));
  assert(!isUsableRate({ basis: "", value: 2, unit: "L" }));
  assert(!isUsableRate({ basis: "other", unit: "", raw_text: "as directed" }));
});

Deno.test("a rate needs a positive number", () => {
  assert(!isUsableRate({ basis: "per_hectare", value: 0, unit: "L" }));
  assert(!isUsableRate({ basis: "per_hectare", value: -2, unit: "L" }));
  assert(!isUsableRate({ basis: "per_hectare", unit: "L" }));
});

Deno.test("a range rate needs both ends, in order", () => {
  assert(isUsableRate({
    basis: "range_per_100_litres", min_value: 150, max_value: 200, unit: "mL",
  }));
  assert(!isUsableRate({ basis: "range_per_100_litres", min_value: 150, unit: "mL" }));
  assert(!isUsableRate({
    basis: "range_per_100_litres", min_value: 200, max_value: 150, unit: "mL",
  }));
});

Deno.test("an inverted range is reported so the operator can fix it", () => {
  const inverted: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Botrytis",
      rates: [{ basis: "range_per_hectare", min_value: 5, max_value: 1, unit: "L" }],
    }],
  };
  assert(has(inverted, "rate_range_inverted"));
});

Deno.test("either rate basis satisfies the contract", () => {
  const hectareOnly: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Weeds",
      rates: [{ basis: "per_hectare", value: 4, unit: "L" }],
    }],
  };
  // /100 L is PREFERRED downstream; it is not required here. A hectare-only
  // label is a complete label.
  assert(evaluateChemicalSave(hectareOnly).ok);
});

Deno.test("both bases together satisfy the contract and neither is demanded", () => {
  const both: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [
        { basis: "per_100_litres", value: 2, unit: "L" },
        { basis: "per_hectare", value: 4, unit: "L" },
      ],
    }],
  };
  assert(evaluateChemicalSave(both).ok);
});

// ---------------------------------------------------------------------------
// Ambiguous conditions (§5 handoff)
// ---------------------------------------------------------------------------

Deno.test("an ambiguous rate is usable but never auto-applied", () => {
  const rate = { basis: "per_100_litres", value: 2, unit: "L", condition_ambiguous: true };
  assert(isUsableRate(rate), "the number is authoritative");
  assert(!isAutoApplicableRate(rate), "the association is not");
});

Deno.test("a use whose ONLY rates are ambiguous saves, but flags a choice", () => {
  const ambiguous: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [
        { basis: "per_100_litres", value: 2, unit: "L", condition_ambiguous: true },
        { basis: "per_100_litres", value: 3, unit: "L", condition_ambiguous: true },
      ],
    }],
  };
  const result = evaluateChemicalSave(ambiguous);
  // The label really does state these rates, so the record is storable…
  assert(result.ok);
  // …but a calculation must ask the operator which condition applies.
  assert(result.requiresRateConditionChoice);
});

Deno.test("one unambiguous rate clears the choice flag", () => {
  const mixed: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [
        { basis: "per_100_litres", value: 2, unit: "L", condition_ambiguous: true },
        { basis: "per_hectare", value: 4, unit: "L" },
      ],
    }],
  };
  assertEquals(evaluateChemicalSave(mixed).requiresRateConditionChoice, false);
});

// ---------------------------------------------------------------------------
// Resistance state (§10 handoff)
// ---------------------------------------------------------------------------

Deno.test("the resistance state must be STATED", () => {
  assert(has({ ...valid(), resistance_classification_state: "" }, "resistance_state_missing"));
  assert(has({ ...valid(), resistance_classification_state: null }, "resistance_state_missing"));
  assert(has(
    { ...valid(), resistance_classification_state: "probably fine" },
    "resistance_state_missing",
  ));
});

Deno.test("all three states are acceptable answers", () => {
  for (const state of ["classified", "not_applicable", "unresolved"]) {
    const input = { ...valid(), resistance_classification_state: state };
    assert(
      !has(input, "resistance_state_missing"),
      `${state} must be an acceptable answer`,
    );
  }
});

Deno.test("'unresolved' does not block a save", () => {
  // Honest ignorance is storable. It is silence that is not.
  assert(evaluateChemicalSave({
    ...valid(),
    resistance_classification_state: "unresolved",
  }).ok);
});

// ---------------------------------------------------------------------------
// Verified intent
// ---------------------------------------------------------------------------

Deno.test("a verified product needs registration identity", () => {
  const noNumber: ChemicalSaveInput = {
    ...valid(),
    registration: { country_code: "AU", label_reference: "https://x/y.pdf" },
  };
  assert(has(noNumber, "registration_identity_missing", "verified"));
  // …but the same record is fine as an unverified store entry.
  assert(!has(noNumber, "registration_identity_missing", "spray_ready"));
});

Deno.test("a verified product needs the official regulator label", () => {
  const noLabel: ChemicalSaveInput = {
    ...valid(),
    registration: { registration_number: "50067", country_code: "AU" },
  };
  assert(has(noLabel, "official_label_missing", "verified"));
  assert(!has(noLabel, "official_label_missing", "spray_ready"));
});

// ---------------------------------------------------------------------------
// What must NEVER be mandatory
// ---------------------------------------------------------------------------

Deno.test("WHP is never required, and null stays null", () => {
  const noWhp: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [{ basis: "per_100_litres", value: 2, unit: "L" }],
      withholding_period_days: null,
    }],
  };
  const result = evaluateChemicalSave(noWhp, "verified");
  assert(result.ok, "a label that states no WHP is still a complete label");
  assertEquals(
    result.violations.filter((v) => v.field === "withholding_period").length,
    0,
  );
});

Deno.test("REI is never required", () => {
  const noRei: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [{ basis: "per_100_litres", value: 2, unit: "L" }],
      re_entry_period_hours: null,
    }],
  };
  assert(evaluateChemicalSave(noRei, "verified").ok);
});

Deno.test("the contract never reads WHP or REI at all", () => {
  // Belt and braces: a zero must not be treated as more complete than a null,
  // or a future edit would start rewarding invented values.
  const withZero: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [{ basis: "per_100_litres", value: 2, unit: "L" }],
      withholding_period_days: 0,
      re_entry_period_hours: 0,
    }],
  };
  assertEquals(
    evaluateChemicalSave(withZero).violations,
    evaluateChemicalSave(valid()).violations,
  );
});

Deno.test("a manufacturer URL is never required", () => {
  // It is not even an input to the contract — proven by the verified path
  // passing without one.
  assert(evaluateChemicalSave(valid(), "verified").ok);
});

// ---------------------------------------------------------------------------
// Reporting quality
// ---------------------------------------------------------------------------

Deno.test("every violation is reported at once, not one at a time", () => {
  const empty: ChemicalSaveInput = {};
  const result = evaluateChemicalSave(empty, "verified");
  const found = new Set(result.violations.map((v) => v.code));
  assert(found.has("product_name_missing"));
  assert(found.has("product_category_missing"));
  assert(found.has("grapevine_use_missing"));
  assert(found.has("resistance_state_missing"));
  assert(found.has("registration_identity_missing"));
  assert(found.has("official_label_missing"));
});

Deno.test("several malformed rates produce one actionable message", () => {
  const messy: ChemicalSaveInput = {
    ...valid(),
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Scale",
      rates: [
        { basis: "per_100_litres", value: 0, unit: "L" },
        { basis: "per_100_litres", value: -1, unit: "L" },
        { basis: "per_hectare", value: 0, unit: "L" },
      ],
    }],
  };
  const invalid = evaluateChemicalSave(messy).violations
    .filter((v) => v.code === "rate_value_invalid");
  assertEquals(invalid.length, 1, "the operator should not read the same sentence three times");
});

Deno.test("every violation names a field the form can focus", () => {
  const result = evaluateChemicalSave({}, "verified");
  assert(result.violations.every((v) => v.field.length > 0));
  assert(result.violations.every((v) => v.message.length > 0));
});
