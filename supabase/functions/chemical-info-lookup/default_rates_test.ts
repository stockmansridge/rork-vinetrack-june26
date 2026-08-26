import {
  assert,
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildDefaultRateSelection,
  canonicalDefaultOptionInput,
  canonicalRateIds,
  clearDefaultRateBasis,
  DEFAULT_OPTION_ID_VERSION,
  DEFAULT_RATE_BASES,
  DEFAULT_RATES_VERSION,
  type DefaultRateSelectionInput,
  emptyDefaultRates,
  hasAnyDefaultRate,
  mintDefaultOptionKey,
  normaliseDefaultRateBasis,
  type SavedChemicalDefaultRateSelection,
  validateDefaultRates,
  withDefaultRateSelection,
} from "./default_rates.ts";
import {
  mintRateId,
  type RateIdentityProduct,
  RATE_ID_VERSION,
} from "./rate_identity.ts";
import * as mod from "./default_rates.ts";

// ---------------------------------------------------------------------------
// VICOL — APVMA 33182
//
// The product that proves why `rate_ids` is an array. Its label states
// 3 L/100 L under TWO printed directions, so an operator who says "I use 3 L
// per 100 L of VICOL" is relying on both of them at once.
// ---------------------------------------------------------------------------

const VICOL: RateIdentityProduct = {
  country: "AU",
  scheme: "apvma",
  registration_number: "33182",
};

const RATE_3L = { basis: "per_100_litres", unit: "L", value: 3 } as const;
const RATE_2L = { basis: "per_100_litres", unit: "L", value: 2 } as const;

/** European Red Mites — NSW/Vic/SA. */
const ERM_ID = mintRateId(
  VICOL,
  { crop: "Grapes", targets: ["European Red Mites"], condition: "NSW, Vic, SA" },
  { ...RATE_3L, label: "NSW, Vic, SA" },
);

/** Grapevine Scale — NSW/Vic/Qld/SA/WA. */
const SCALE_ID = mintRateId(
  VICOL,
  {
    crop: "Grapes",
    targets: ["Grapevine Scale"],
    condition: "NSW, Vic, Qld, SA, WA",
  },
  { ...RATE_3L, label: "NSW, Vic, Qld, SA, WA" },
);

/** Tasmania 2 L/100 L — a different amount under a different jurisdiction. */
const TAS_ID = mintRateId(
  VICOL,
  {
    crop: "Grapes",
    targets: ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"],
    condition: "Tas",
  },
  { ...RATE_2L, label: "Tasmania" },
);

function selection(
  overrides: Partial<DefaultRateSelectionInput> = {},
): SavedChemicalDefaultRateSelection {
  const built = buildDefaultRateSelection({
    basis: "per_100_litres",
    unit: "L",
    value: 3,
    rate_ids: [ERM_ID, SCALE_ID],
    source: "operator",
    selected_at: "2026-08-26T00:00:00Z",
    ...overrides,
  });
  assertEquals(built.violations, []);
  assert(built.selection);
  return built.selection;
}

// ---------------------------------------------------------------------------
// §16 — the VICOL grouped-default contract
// ---------------------------------------------------------------------------

Deno.test("§16 one selection cites both supporting VICOL directions", () => {
  const sel = selection();

  assertEquals(sel.basis, "per_100_litres");
  assertEquals(sel.unit, "L");
  assertEquals(sel.value, 3);
  assertEquals(sel.min_value, null);
  assertEquals(sel.max_value, null);
  assertEquals(sel.rate_ids.length, 2);
  assertEquals(sel.rate_ids, [ERM_ID, SCALE_ID].sort());
  assert(sel.option_key.startsWith(`${DEFAULT_OPTION_ID_VERSION}_`));
  // Deterministic, never a UUID.
  assertEquals(sel.option_key, selection().option_key);
  assert(!/[0-9a-f]{8}-[0-9a-f]{4}-/.test(sel.option_key));

  // No per-hectare default is fabricated from a per-100 L choice.
  const contract = withDefaultRateSelection(emptyDefaultRates(), sel);
  assertEquals(contract.per_hectare, null);
  assertEquals(contract.per_100_litres?.option_key, sel.option_key);
});

Deno.test("§16 reversing the supporting rate ids yields the same option key", () => {
  const forward = selection({ rate_ids: [ERM_ID, SCALE_ID] });
  const reversed = selection({ rate_ids: [SCALE_ID, ERM_ID] });

  assertEquals(reversed.option_key, forward.option_key);
  assertEquals(reversed.rate_ids, forward.rate_ids);
});

Deno.test("§16 duplicate rate ids collapse without changing identity", () => {
  const once = selection({ rate_ids: [ERM_ID, SCALE_ID] });
  const twice = selection({ rate_ids: [SCALE_ID, ERM_ID, SCALE_ID, ERM_ID] });

  assertEquals(twice.rate_ids.length, 2);
  assertEquals(twice.option_key, once.option_key);
});

Deno.test("§16 changing either supporting rate id changes the option key", () => {
  const both = selection();
  const ermOnly = selection({ rate_ids: [ERM_ID] });
  const scaleOnly = selection({ rate_ids: [SCALE_ID] });
  const swapped = selection({ rate_ids: [ERM_ID, TAS_ID] });

  assertNotEquals(ermOnly.option_key, both.option_key);
  assertNotEquals(scaleOnly.option_key, both.option_key);
  assertNotEquals(swapped.option_key, both.option_key);
  assertNotEquals(ermOnly.option_key, scaleOnly.option_key);
});

Deno.test("§16 changing 3 L to 2 L changes the option key", () => {
  const three = selection({ value: 3 });
  const two = selection({ value: 2 });

  assertNotEquals(two.option_key, three.option_key);
  assertEquals(two.value, 2);
});

Deno.test("§16 the two VICOL directions have distinct D1 rate identities", () => {
  // The premise of the whole gate: matching on the NUMBER cannot tell these
  // apart — both say 3 — so the identities must differ.
  assertNotEquals(ERM_ID, SCALE_ID);
  assert(ERM_ID.startsWith(`${RATE_ID_VERSION}_`));
  assert(SCALE_ID.startsWith(`${RATE_ID_VERSION}_`));
});

// ---------------------------------------------------------------------------
// §17 — true ranges
// ---------------------------------------------------------------------------

Deno.test("§17 a true range persists as one selection keeping both bounds", () => {
  const sel = selection({ value: null, min_value: 1, max_value: 2 });

  assertEquals(sel.value, null);
  assertEquals(sel.min_value, 1);
  assertEquals(sel.max_value, 2);
  // Never collapsed to a single figure the label did not print.
  assertNotEquals(sel.value as unknown, 1);
  assertNotEquals(sel.value as unknown, 1.5);
  assertNotEquals(sel.value as unknown, 2);

  const contract = withDefaultRateSelection(emptyDefaultRates(), sel);
  assertEquals(contract.per_100_litres?.min_value, 1);
  assertEquals(contract.per_100_litres?.max_value, 2);
});

Deno.test("§17 changing either bound changes the option key", () => {
  const base = selection({ value: null, min_value: 1, max_value: 2 });
  const lower = selection({ value: null, min_value: 0.5, max_value: 2 });
  const upper = selection({ value: null, min_value: 1, max_value: 3 });

  assertNotEquals(lower.option_key, base.option_key);
  assertNotEquals(upper.option_key, base.option_key);
  assertNotEquals(lower.option_key, upper.option_key);
});

Deno.test("§17 a range and a single value never share an option key", () => {
  const range = selection({ value: null, min_value: 3, max_value: 3 });
  const single = selection({ value: 3 });

  // Same numbers, different meaning: "exactly 3" is not "between 3 and 3".
  assertNotEquals(range.option_key, single.option_key);
});

Deno.test("§17 the range basis spelling folds onto its own slot", () => {
  assertEquals(normaliseDefaultRateBasis("range_per_hectare"), "per_hectare");
  assertEquals(normaliseDefaultRateBasis("range_per_100_litres"), "per_100_litres");
  assertEquals(normaliseDefaultRateBasis("other"), null);
  assertEquals(normaliseDefaultRateBasis(""), null);
  assertEquals(normaliseDefaultRateBasis(null), null);

  const sel = selection({ basis: "range_per_100_litres", value: null, min_value: 1, max_value: 2 });
  assertEquals(sel.basis, "per_100_litres");
});

// ---------------------------------------------------------------------------
// §18 — the two bases are independent
// ---------------------------------------------------------------------------

const HA_ID = mintRateId(
  VICOL,
  { crop: "Grapes", targets: ["Grapevine Scale"], condition: "NSW" },
  { basis: "per_hectare", unit: "L", value: 8, label: "NSW" },
);

function bothBases() {
  const perHa = selection({ basis: "per_hectare", value: 8, rate_ids: [HA_ID] });
  const per100 = selection();
  return withDefaultRateSelection(
    withDefaultRateSelection(emptyDefaultRates(), perHa),
    per100,
  );
}

Deno.test("§18 both bases persist independently with independent keys", () => {
  const contract = bothBases();

  assertEquals(contract.version, DEFAULT_RATES_VERSION);
  assertEquals(contract.per_hectare?.basis, "per_hectare");
  assertEquals(contract.per_hectare?.value, 8);
  assertEquals(contract.per_100_litres?.basis, "per_100_litres");
  assertEquals(contract.per_100_litres?.value, 3);
  assertNotEquals(contract.per_hectare?.option_key, contract.per_100_litres?.option_key);
  assert(hasAnyDefaultRate(contract));

  // Survives a round trip through the reader unchanged.
  const read = validateDefaultRates(JSON.parse(JSON.stringify(contract)));
  assertEquals(read.violations, []);
  assertEquals(read.value, contract);
});

Deno.test("§18 clearing one basis leaves the other untouched", () => {
  const contract = bothBases();

  const clearedHa = clearDefaultRateBasis(contract, "per_hectare");
  assertEquals(clearedHa.per_hectare, null);
  assertEquals(clearedHa.per_100_litres, contract.per_100_litres);

  const clearedBoth = clearDefaultRateBasis(clearedHa, "per_100_litres");
  assertEquals(clearedBoth.per_100_litres, null);
  assert(!hasAnyDefaultRate(clearedBoth));
  // The original is not mutated.
  assert(hasAnyDefaultRate(contract));
});

Deno.test("§18 no conversion occurs between the two bases", () => {
  const contract = bothBases();
  const ha = contract.per_hectare!;
  const per100 = contract.per_100_litres!;

  // Each keeps its own label amount; neither is derived from the other by any
  // factor, because converting needs a water volume that belongs to the job.
  assertEquals(ha.value, 8);
  assertEquals(per100.value, 3);
  assertNotEquals(ha.rate_ids, per100.rate_ids);

  // A per-hectare-only product records nothing on the other basis.
  const haOnly = withDefaultRateSelection(emptyDefaultRates(), ha);
  assertEquals(haOnly.per_100_litres, null);
  const per100Only = withDefaultRateSelection(emptyDefaultRates(), per100);
  assertEquals(per100Only.per_hectare, null);
});

// ---------------------------------------------------------------------------
// §19 — nothing is ever backfilled
// ---------------------------------------------------------------------------

Deno.test("§19 a legacy chemical with rate_per_ha and rates records no default", () => {
  // Exactly the row shape this gate refuses to mine: a real operator rate and
  // a populated legacy rates array, with no recorded default.
  const legacyRow = {
    id: "0d2f6b0e-6a1f-4d3a-9d21-3f1f6f3c1a77",
    name: "Legacy Product",
    rate_per_ha: 2.5,
    unit: "Litres",
    rates: [
      { id: "a", label: "Standard", value: 2.5, basis: "per_hectare" },
      { id: "b", label: "High pressure", value: 3.5, basis: "per_hectare" },
    ],
    registered_uses: [
      { crop: "Grapes", target_raw: "Powdery Mildew", rates: [RATE_3L] },
    ],
    default_rates: null,
  };

  const read = validateDefaultRates(legacyRow.default_rates);
  assertEquals(read.value, null);
  // Absence is normal, not a fault.
  assertEquals(read.violations, []);
  assert(!hasAnyDefaultRate(read.value));

  // Undefined (column not selected at all) behaves identically.
  assertEquals(validateDefaultRates(undefined).value, null);
  assertEquals(validateDefaultRates(undefined).violations, []);
});

Deno.test("§19 the module exposes no path from legacy values to a default", () => {
  // A structural guarantee, not a behavioural one: there is no helper anyone
  // could call to synthesise a default, so none can be added by accident.
  const names = Object.keys(mod);
  for (const name of names) {
    assert(
      !/legacy|backfill|infer|derive|migrate|from_?rate/i.test(name),
      `default_rates must expose no legacy-derivation helper, found "${name}"`,
    );
  }
  // And every constructor demands explicit registered rate ids.
  const built = buildDefaultRateSelection({
    basis: "per_hectare",
    unit: "Litres",
    value: 2.5,
    rate_ids: [],
    source: "operator",
  });
  assertEquals(built.selection, null);
  assertEquals(built.violations[0].code, "rate_ids_missing");
});

// ---------------------------------------------------------------------------
// §13 — validation behaviour
// ---------------------------------------------------------------------------

Deno.test("§13 an unsupported version is refused rather than reinterpreted", () => {
  const v2 = { version: 2, per_hectare: null, per_100_litres: null };
  const read = validateDefaultRates(v2);

  assertEquals(read.value, null);
  assertEquals(read.violations[0].code, "version_unsupported");
});

Deno.test("§13 a non-object value is refused without throwing", () => {
  for (const bad of [[], "x", 3, true]) {
    const read = validateDefaultRates(bad);
    assertEquals(read.value, null);
    assertEquals(read.violations[0].code, "not_an_object");
  }
});

Deno.test("§13 a basis that disagrees with its slot is rejected", () => {
  const sel = selection();
  const wrongSlot = { version: 1, per_hectare: sel, per_100_litres: null };
  const read = validateDefaultRates(wrongSlot);

  assertEquals(read.value?.per_hectare, null);
  assertEquals(read.violations[0].code, "basis_slot_mismatch");
  // The record itself is still readable.
  assertEquals(read.value?.version, DEFAULT_RATES_VERSION);
});

Deno.test("§13 malformed selections are dropped, the good basis survives", () => {
  const good = selection({ basis: "per_hectare", value: 8, rate_ids: [HA_ID] });
  const read = validateDefaultRates({
    version: 1,
    per_hectare: good,
    per_100_litres: { ...selection(), rate_ids: [] },
  });

  // The whole chemical stays usable; only the unreadable choice is discarded.
  assertEquals(read.value?.per_hectare?.value, 8);
  assertEquals(read.value?.per_100_litres, null);
  assertEquals(read.violations[0].code, "rate_ids_missing");
});

Deno.test("§13 rate ids must be D1 registered-rate identities", () => {
  const read = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...selection(), rate_ids: ["direction_v1_abc", ERM_ID] },
  });

  assertEquals(read.value?.per_100_litres, null);
  assertEquals(read.violations[0].code, "rate_id_malformed");

  // A UUID is refused for the same reason.
  const uuid = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...selection(), rate_ids: ["3f1f6f3c-1a77-4d3a-9d21-0d2f6b0e6a1f"] },
  });
  assertEquals(uuid.value?.per_100_litres, null);
});

Deno.test("§13 amount shape must be exactly one of value or range", () => {
  const both = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...selection(), value: 3, min_value: 1, max_value: 2 },
  });
  assertEquals(both.value?.per_100_litres, null);
  assertEquals(both.violations[0].code, "amount_shape_invalid");

  const neither = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...selection(), value: null },
  });
  assertEquals(neither.value?.per_100_litres, null);
  assertEquals(neither.violations[0].code, "amount_shape_invalid");

  const halfRange = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...selection(), value: null, min_value: 1, max_value: null },
  });
  assertEquals(halfRange.value?.per_100_litres, null);
});

Deno.test("§13 non-finite amounts and inverted ranges are refused", () => {
  for (const bad of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
    // JSON cannot carry these, but an in-process caller can.
    const read = validateDefaultRates({
      version: 1,
      per_hectare: null,
      per_100_litres: { ...selection(), value: bad },
    });
    assertEquals(read.value?.per_100_litres, null);
  }

  const inverted = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...selection(), value: null, min_value: 2, max_value: 1 },
  });
  assertEquals(inverted.value?.per_100_litres, null);
  assertEquals(inverted.violations[0].code, "amount_range_inverted");
});

Deno.test("§13 the label unit is required and never inferred", () => {
  const read = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...selection(), unit: "  " },
  });

  assertEquals(read.value?.per_100_litres, null);
  assertEquals(read.violations[0].code, "unit_missing");
});

Deno.test("§13 an option key that disagrees with its content is refused", () => {
  const sel = selection();
  const tampered = validateDefaultRates({
    version: 1,
    per_hectare: null,
    // The amount was edited; the key was not.
    per_100_litres: { ...sel, value: 4 },
  });

  assertEquals(tampered.value?.per_100_litres, null);
  assertEquals(tampered.violations[0].code, "option_key_mismatch");

  const keyOnly = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...sel, option_key: `${DEFAULT_OPTION_ID_VERSION}_deadbeef` },
  });
  assertEquals(keyOnly.value?.per_100_litres, null);
});

Deno.test("§13 the v1 source vocabulary is closed and excludes inferred", () => {
  for (const source of ["operator", "recommended"] as const) {
    const sel = selection({ source });
    assertEquals(sel.source, source);
  }

  for (const bad of ["inferred", "", "guessed", null]) {
    const read = validateDefaultRates({
      version: 1,
      per_hectare: null,
      per_100_litres: { ...selection(), source: bad },
    });
    assertEquals(read.value?.per_100_litres, null);
    assertEquals(read.violations[0].code, "source_unrecognised");
  }
});

// ---------------------------------------------------------------------------
// §10/§11 — what identity is made of, and what it must ignore
// ---------------------------------------------------------------------------

Deno.test("§11 provenance never participates in the option key", () => {
  const base = selection();

  const otherSource = selection({ source: "recommended" });
  const otherTime = selection({ selected_at: "1999-01-01T00:00:00Z" });
  const noTime = selection({ selected_at: null });
  const labelled = selection({ label_version: "2024-03" });

  for (const variant of [otherSource, otherTime, noTime, labelled]) {
    assertEquals(variant.option_key, base.option_key);
  }

  // Provenance is still stored — it just does not decide identity.
  assertEquals(otherSource.source, "recommended");
  assertEquals(labelled.label_version, "2024-03");
  assertEquals(noTime.selected_at, null);
});

Deno.test("§11 unreadable provenance is dropped without losing the default", () => {
  const sel = selection({ selected_at: null, label_version: null });
  const read = validateDefaultRates({
    version: 1,
    per_hectare: null,
    per_100_litres: { ...sel, selected_at: 12345, label_version: {} },
  });

  // The choice survives; only the circumstances of it are discarded.
  assertEquals(read.value?.per_100_litres?.option_key, sel.option_key);
  assertEquals(read.value?.per_100_litres?.selected_at, null);
  assertEquals(read.value?.per_100_litres?.label_version, null);
  assertEquals(read.violations[0].code, "provenance_malformed");
});

Deno.test("§10 identity moves with basis, unit and amount", () => {
  const base = selection();

  assertNotEquals(selection({ unit: "mL" }).option_key, base.option_key);
  assertNotEquals(
    selection({ basis: "per_hectare", rate_ids: [HA_ID] }).option_key,
    selection({ basis: "per_100_litres", rate_ids: [HA_ID] }).option_key,
  );
});

Deno.test("§10 canonical input is stable under formatting differences", () => {
  const a = canonicalDefaultOptionInput("per_100_litres", { unit: "L", value: 3 }, [
    ERM_ID,
    SCALE_ID,
  ]);
  const b = canonicalDefaultOptionInput("per_100_litres", { unit: " l ", value: 3.0 }, [
    ` ${SCALE_ID} `,
    ERM_ID,
  ]);
  assertEquals(a, b);
  assertEquals(
    mintDefaultOptionKey("per_100_litres", { unit: "L", value: 3 }, [ERM_ID, SCALE_ID]),
    mintDefaultOptionKey("per_100_litres", { unit: "l", value: 3.0 }, [SCALE_ID, ERM_ID]),
  );
});

Deno.test("§10 canonical input cannot be confused across field boundaries", () => {
  // Field-splitting safety: "ab"+"c" must not hash like "a"+"bc".
  const left = canonicalDefaultOptionInput("per_hectare", { unit: "ab", value: 1 }, ["c"]);
  const right = canonicalDefaultOptionInput("per_hectare", { unit: "a", value: 1 }, ["bc"]);
  assertNotEquals(left, right);
});

Deno.test("§10 an absent bound is distinct from a zero bound", () => {
  const absent = canonicalDefaultOptionInput("per_hectare", { unit: "L", value: 1 }, ["x"]);
  const zeroMax = canonicalDefaultOptionInput(
    "per_hectare",
    { unit: "L", value: 1, max_value: 0 },
    ["x"],
  );
  assertNotEquals(absent, zeroMax);
});

Deno.test("canonicalRateIds trims, de-duplicates and sorts", () => {
  assertEquals(canonicalRateIds([" b ", "a", "b", "", null, undefined]), ["a", "b"]);
  assertEquals(canonicalRateIds(null), []);
  assertEquals(canonicalRateIds([]), []);
});

Deno.test("the basis vocabulary is exactly the two structured spellings", () => {
  assertEquals([...DEFAULT_RATE_BASES], ["per_hectare", "per_100_litres"]);
  assertEquals(DEFAULT_RATES_VERSION, 1);
});
