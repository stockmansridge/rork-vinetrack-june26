import {
  assert,
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyDefaultRateOptions,
  buildDefaultRateOptions,
  type DefaultRateOption,
} from "./default_rate_options.ts";
import {
  mintDefaultOptionKey,
  validateDefaultRates,
} from "./default_rates.ts";
import {
  assignRateIds,
  type RateIdentityProduct,
  RATE_ID_VERSION,
} from "./rate_identity.ts";

// ---------------------------------------------------------------------------
// Fixtures
//
// Every fixture is stamped by the REAL D1 minter through `assignRateIds`,
// against a locked product. Hand-written ids would prove only that this module
// can group strings; stamping proves it groups the identities the pipeline
// actually produces.
// ---------------------------------------------------------------------------

const VICOL: RateIdentityProduct = {
  country: "AU",
  scheme: "apvma",
  registration_number: "33182",
};

// deno-lint-ignore no-explicit-any
type Jsonish = any;

function use(
  crop: string,
  targetRaw: string,
  rates: Jsonish[],
): Jsonish {
  return { crop, target_raw: targetRaw, rates };
}

function stamped(uses: Jsonish[], product: RateIdentityProduct = VICOL): Jsonish[] {
  const copy = JSON.parse(JSON.stringify(uses));
  assignRateIds(copy, product);
  return copy;
}

/**
 * VICOL, APVMA 33182 — the label this whole gate is shaped by.
 *
 * SIX printed pest rows across two amounts and two jurisdiction sets. A naive
 * producer emits six defaults; the correct one emits two.
 */
function vicolUses(): Jsonish[] {
  const tas = { label: "Tasmania", basis: "per_100_litres", unit: "L", value: 2 };
  const mainland3 = {
    label: "NSW, Vic, SA",
    basis: "per_100_litres",
    unit: "L",
    value: 3,
  };
  const mainland3Scale = {
    label: "NSW, Vic, Qld, SA, WA",
    basis: "per_100_litres",
    unit: "L",
    value: 3,
  };
  const tasScale = { label: "Tasmania", basis: "per_100_litres", unit: "L", value: 2 };

  return stamped([
    // 2 L/100 L — Tasmania multi-mite printed direction, fanned out to three
    // rows by the projection. ONE direction, so ONE rate identity.
    {
      crop: "Grapes",
      target_raw: "Grapeleaf Blister Mites",
      direction_id: null,
      __direction_identity_seed: {
        crop: "Grapes",
        targets: ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"],
        condition: "Tas",
      },
      rates: [{ ...tas }],
    },
    {
      crop: "Grapes",
      target_raw: "European Red Mites",
      direction_id: null,
      __direction_identity_seed: {
        crop: "Grapes",
        targets: ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"],
        condition: "Tas",
      },
      rates: [{ ...tas }],
    },
    {
      crop: "Grapes",
      target_raw: "Two Spotted Mites",
      direction_id: null,
      __direction_identity_seed: {
        crop: "Grapes",
        targets: ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"],
        condition: "Tas",
      },
      rates: [{ ...tas }],
    },
    // 2 L/100 L — Tasmania Grapevine Scale: a SEPARATE printed direction that
    // happens to state the same amount.
    use("Grapes", "Grapevine Scale", [{ ...tasScale }]),
    // 3 L/100 L — European Red Mites, NSW/Vic/SA.
    use("Grapes", "European Red Mites", [{ ...mainland3 }]),
    // 3 L/100 L — Grapevine Scale, NSW/Vic/Qld/SA/WA.
    use("Grapes", "Grapevine Scale", [{ ...mainland3Scale }]),
  ]);
}

// The Tasmania Grapevine Scale row and the mainland Grapevine Scale row share
// crop and target, so their identities must be separated by CONDITION alone.
// If that ever stops being true this fixture collapses and the tests below
// fail loudly rather than quietly asserting less.

// ---------------------------------------------------------------------------
// §14 — VICOL acceptance
// ---------------------------------------------------------------------------

Deno.test("§14 VICOL 33182 produces exactly two per-100 L options", () => {
  const { options, violations } = buildDefaultRateOptions(vicolUses());

  assertEquals(violations, []);
  assertEquals(options.per_100_litres.length, 2);
  // No /ha option is fabricated from a label that states none.
  assertEquals(options.per_hectare, []);

  const [two, three] = options.per_100_litres;

  // Deterministic ordering: ascending single values, so 2 L precedes 3 L.
  assertEquals(two.value, 2);
  assertEquals(three.value, 3);

  for (const option of [two, three]) {
    assertEquals(option.basis, "per_100_litres");
    assertEquals(option.unit, "L");
    assertEquals(option.min_value, null);
    assertEquals(option.max_value, null);
    // TWO supporting printed directions each — never six pest rows, never one.
    assertEquals(option.rate_ids.length, 2);
    assertEquals(option.direction_ids.length, 2);
  }

  // Four distinct supporting identities across the two options.
  const all = new Set([...two.rate_ids, ...three.rate_ids]);
  assertEquals(all.size, 4);
  for (const id of all) assert(id.startsWith(`${RATE_ID_VERSION}_`));

  // No duplicate 2 L or 3 L option.
  assertEquals(new Set(options.per_100_litres.map((o) => o.option_key)).size, 2);
  assertNotEquals(two.option_key, three.option_key);
});

Deno.test("§14 the 3 L option explains itself with both targets and conditions", () => {
  const { options } = buildDefaultRateOptions(vicolUses());
  const three = options.per_100_litres.find((o) => o.value === 3)!;

  assertEquals(three.targets, ["European Red Mites", "Grapevine Scale"]);
  assertEquals(three.conditions, ["NSW, Vic, Qld, SA, WA", "NSW, Vic, SA"]);
  assertEquals(three.crops, ["Grapes"]);
});

Deno.test("§14 the 2 L option groups the fanned-out Tasmania direction once", () => {
  const { options } = buildDefaultRateOptions(vicolUses());
  const two = options.per_100_litres.find((o) => o.value === 2)!;

  // Three projected pest ROWS share one printed direction, so they contribute
  // ONE identity, not three. Plus the separate Tasmania scale direction.
  assertEquals(two.rate_ids.length, 2);
  assertEquals(two.direction_ids.length, 2);
  assertEquals(two.targets, [
    "European Red Mites",
    "Grapeleaf Blister Mites",
    "Grapevine Scale",
    "Two Spotted Mites",
  ]);
  assertEquals(two.conditions, ["Tasmania"]);
});

Deno.test("§14 option output is stable when the label rows are shuffled", () => {
  const forward = buildDefaultRateOptions(vicolUses()).options;
  const shuffled = vicolUses().reverse();
  const reversed = buildDefaultRateOptions(shuffled).options;

  assertEquals(reversed, forward);
});

// ---------------------------------------------------------------------------
// §15 — true ranges
// ---------------------------------------------------------------------------

Deno.test("§15 a 1-2 L/ha range is one option keeping both bounds", () => {
  const uses = stamped([
    use("Grapes", "Powdery Mildew", [{
      label: "",
      basis: "range_per_hectare",
      unit: "L",
      min_value: 1,
      max_value: 2,
    }]),
  ]);

  const { options, violations } = buildDefaultRateOptions(uses);
  assertEquals(violations, []);
  assertEquals(options.per_hectare.length, 1);
  assertEquals(options.per_100_litres, []);

  const option = options.per_hectare[0];
  assertEquals(option.basis, "per_hectare");
  assertEquals(option.value, null);
  assertEquals(option.min_value, 1);
  assertEquals(option.max_value, 2);
  // Never split into 1 and 2, never averaged to 1.5.
  assertEquals(options.per_hectare.map((o) => o.value), [null]);
  assertNotEquals(option.min_value, option.max_value);
});

Deno.test("§15 the range option key is exactly the D3 minter's", () => {
  const uses = stamped([
    use("Grapes", "Powdery Mildew", [{
      label: "",
      basis: "range_per_hectare",
      unit: "L",
      min_value: 1,
      max_value: 2,
    }]),
  ]);
  const option = buildDefaultRateOptions(uses).options.per_hectare[0];

  assertEquals(
    option.option_key,
    mintDefaultOptionKey(
      "per_hectare",
      { unit: "L", value: null, min_value: 1, max_value: 2 },
      option.rate_ids,
    ),
  );
});

// ---------------------------------------------------------------------------
// §16 — independent bases
// ---------------------------------------------------------------------------

Deno.test("§16 per-ha and per-100 L options coexist without converting", () => {
  const uses = stamped([
    use("Grapes", "Botrytis", [
      { label: "Dilute", basis: "per_100_litres", unit: "L", value: 2 },
      { label: "Concentrate", basis: "per_hectare", unit: "L", value: 1.5 },
    ]),
  ]);

  const { options, violations } = buildDefaultRateOptions(uses);
  assertEquals(violations, []);
  assertEquals(options.per_hectare.length, 1);
  assertEquals(options.per_100_litres.length, 1);

  const ha = options.per_hectare[0];
  const per100 = options.per_100_litres[0];

  assertEquals(ha.value, 1.5);
  assertEquals(per100.value, 2);
  assertNotEquals(ha.option_key, per100.option_key);
  // Never cross-grouped: each cites only its own rate.
  assertEquals(ha.rate_ids.length, 1);
  assertEquals(per100.rate_ids.length, 1);
  assertNotEquals(ha.rate_ids[0], per100.rate_ids[0]);
});

Deno.test("§16 identical amounts on different bases never merge", () => {
  const uses = stamped([
    use("Grapes", "Botrytis", [
      { label: "A", basis: "per_100_litres", unit: "L", value: 2 },
      { label: "B", basis: "per_hectare", unit: "L", value: 2 },
    ]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare.length, 1);
  assertEquals(options.per_100_litres.length, 1);
  assertNotEquals(
    options.per_hectare[0].option_key,
    options.per_100_litres[0].option_key,
  );
});

// ---------------------------------------------------------------------------
// §17 — same amount, different printed directions
// ---------------------------------------------------------------------------

Deno.test("§17 two directions stating one amount become one option", () => {
  const uses = stamped([
    use("Grapes", "Downy Mildew", [{
      label: "NSW",
      basis: "per_hectare",
      unit: "kg",
      value: 1.2,
    }]),
    use("Grapes", "Powdery Mildew", [{
      label: "Vic",
      basis: "per_hectare",
      unit: "kg",
      value: 1.2,
    }]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare.length, 1);

  const option = options.per_hectare[0];
  assertEquals(option.rate_ids.length, 2);
  assertEquals(option.targets, ["Downy Mildew", "Powdery Mildew"]);
  assertEquals(option.conditions, ["NSW", "Vic"]);
  assertEquals(option.value, 1.2);
});

Deno.test("§17 grouping survives the same rate appearing twice", () => {
  // Two projections of ONE direction produce the same identity, which must
  // collapse rather than look like two supporting directions.
  const row = use("Grapes", "Downy Mildew", [{
    label: "NSW",
    basis: "per_hectare",
    unit: "kg",
    value: 1.2,
  }]);
  const uses = stamped([row, JSON.parse(JSON.stringify(row))]);

  const { options } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare.length, 1);
  assertEquals(options.per_hectare[0].rate_ids.length, 1);
});

// ---------------------------------------------------------------------------
// §18 — different amounts must not merge
// ---------------------------------------------------------------------------

Deno.test("§18 two amounts on one basis stay two options", () => {
  const uses = stamped([
    use("Grapes", "Grapevine Scale", [{
      label: "Low",
      basis: "per_100_litres",
      unit: "L",
      value: 2,
    }]),
    use("Grapes", "Grapevine Scale", [{
      label: "High",
      basis: "per_100_litres",
      unit: "L",
      value: 3,
    }]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  // Same crop, same target text — only the amount differs.
  assertEquals(options.per_100_litres.length, 2);
  assertEquals(options.per_100_litres.map((o) => o.value), [2, 3]);
  assertNotEquals(
    options.per_100_litres[0].option_key,
    options.per_100_litres[1].option_key,
  );
});

Deno.test("§18 a single value and a range of the same number stay separate", () => {
  const uses = stamped([
    use("Grapes", "A", [{ label: "", basis: "per_hectare", unit: "L", value: 2 }]),
    use("Grapes", "B", [{
      label: "",
      basis: "range_per_hectare",
      unit: "L",
      min_value: 2,
      max_value: 2,
    }]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare.length, 2);
});

// ---------------------------------------------------------------------------
// §7 — label units are preserved, never converted
// ---------------------------------------------------------------------------

Deno.test("§7 L and mL are not collapsed into one option", () => {
  const uses = stamped([
    use("Grapes", "A", [{ label: "", basis: "per_100_litres", unit: "L", value: 3 }]),
    use("Grapes", "B", [{
      label: "",
      basis: "per_100_litres",
      unit: "mL",
      value: 3000,
    }]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  assertEquals(options.per_100_litres.length, 2);
  assertEquals(
    options.per_100_litres.map((o) => o.unit).sort(),
    ["L", "mL"],
  );
});

Deno.test("§7 the same unit in two spellings is one option", () => {
  const uses = stamped([
    use("Grapes", "A", [{ label: "", basis: "per_hectare", unit: "L", value: 3 }]),
    use("Grapes", "B", [{ label: "", basis: "per_hectare", unit: "l", value: 3 }]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare.length, 1);
  assertEquals(options.per_hectare[0].rate_ids.length, 2);
  // A deterministic spelling is chosen; the key is unaffected either way.
  assertEquals(options.per_hectare[0].unit, "L");
});

// ---------------------------------------------------------------------------
// §19 — missing or malformed rate identity
// ---------------------------------------------------------------------------

Deno.test("§19 a rate without a rate_id yields no option and no crash", () => {
  // Deliberately NOT stamped: the product never locked, so nothing was minted.
  const uses = [
    use("Grapes", "Powdery Mildew", [{
      label: "NSW",
      basis: "per_hectare",
      unit: "L",
      value: 2,
    }]),
  ];

  const { options, violations } = buildDefaultRateOptions(uses);

  assertEquals(options.per_hectare, []);
  assertEquals(options.per_100_litres, []);
  assertEquals(violations.length, 1);
  assertEquals(violations[0].code, "rate_id_missing");
  assertEquals(violations[0].basis, "per_hectare");

  // The authoritative use row itself is untouched — it is evidence, and this
  // module only ever reads it.
  assertEquals(uses[0].rates[0].value, 2);
  assertEquals(uses[0].rates[0].rate_id, undefined);
});

Deno.test("§19 no synthetic identity is invented for an unidentified rate", () => {
  const uses = [
    use("Grapes", "Powdery Mildew", [{
      basis: "per_hectare",
      unit: "L",
      value: 2,
      label: "",
    }]),
  ];
  buildDefaultRateOptions(uses);

  // Nothing was written back onto the row — no id, no index handle, no target
  // fallback that would change on the next extraction.
  assertEquals(Object.keys(uses[0].rates[0]).sort(), [
    "basis",
    "label",
    "unit",
    "value",
  ]);
});

Deno.test("§19 a malformed or non-rate identity is refused", () => {
  const uses = [
    use("Grapes", "A", [{
      rate_id: "direction_v1_abcdef",
      basis: "per_hectare",
      unit: "L",
      value: 2,
      label: "",
    }]),
    use("Grapes", "B", [{
      rate_id: "3f1f6f3c-1a77-4d3a-9d21-0d2f6b0e6a1f",
      basis: "per_hectare",
      unit: "L",
      value: 3,
      label: "",
    }]),
  ];

  const { options, violations } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare, []);
  assertEquals(violations.length, 2);
  assertEquals(new Set(violations.map((v) => v.code)), new Set(["rate_id_malformed"]));
});

Deno.test("§19 identified rates still produce options alongside unidentified ones", () => {
  const good = stamped([
    use("Grapes", "A", [{ label: "", basis: "per_hectare", unit: "L", value: 2 }]),
  ]);
  const mixed = [
    ...good,
    use("Grapes", "B", [{ label: "", basis: "per_hectare", unit: "L", value: 5 }]),
  ];

  const { options, violations } = buildDefaultRateOptions(mixed);
  // One good option survives; the unidentified row is reported, not fatal.
  assertEquals(options.per_hectare.length, 1);
  assertEquals(options.per_hectare[0].value, 2);
  assertEquals(violations.length, 1);
});

// ---------------------------------------------------------------------------
// §9 — the option is already safe to persist
// ---------------------------------------------------------------------------

Deno.test("§9 an option plus provenance validates as a D3 selection", () => {
  const { options } = buildDefaultRateOptions(vicolUses());
  const option = options.per_100_litres.find((o) => o.value === 3)!;

  // Exactly what a D4B client will do: take the canonical object, add
  // provenance, store it. Nothing is recomputed on the client.
  const persisted = {
    version: 1,
    per_hectare: null,
    per_100_litres: {
      option_key: option.option_key,
      rate_ids: option.rate_ids,
      basis: option.basis,
      unit: option.unit,
      value: option.value,
      min_value: option.min_value,
      max_value: option.max_value,
      source: "operator",
      selected_at: "2026-08-26T00:00:00Z",
      label_version: null,
    },
  };

  const read = validateDefaultRates(persisted);
  assertEquals(read.violations, []);
  assertEquals(read.value?.per_100_litres?.option_key, option.option_key);
  assertEquals(read.value?.per_100_litres?.rate_ids.length, 2);
});

Deno.test("§9 every emitted option key is the D3 minter's own answer", () => {
  const { options } = buildDefaultRateOptions(vicolUses());
  for (const basis of ["per_hectare", "per_100_litres"] as const) {
    for (const o of options[basis]) {
      assertEquals(
        o.option_key,
        mintDefaultOptionKey(
          o.basis,
          { unit: o.unit, value: o.value, min_value: o.min_value, max_value: o.max_value },
          o.rate_ids,
        ),
      );
      assert(o.option_key.startsWith("default_option_v1_"));
    }
  }
});

// ---------------------------------------------------------------------------
// §10/§12 — provenance is absent, display metadata is inert
// ---------------------------------------------------------------------------

Deno.test("§10 a canonical option never pretends a selection happened", () => {
  const { options } = buildDefaultRateOptions(vicolUses());
  for (const o of options.per_100_litres) {
    const keys = Object.keys(o);
    assert(!keys.includes("selected_at"), "options must not carry selected_at");
    assert(!keys.includes("source"), "options must not carry selection provenance");
  }
});

Deno.test("§12 display metadata does not affect the option key", () => {
  const base = buildDefaultRateOptions(stamped([
    use("Grapes", "Downy Mildew", [{
      label: "NSW",
      basis: "per_hectare",
      unit: "L",
      value: 2,
    }]),
  ])).options.per_hectare[0];

  // The same amount and the same supporting identity, reached through a
  // fixture whose crop/target wording differs, must key identically once the
  // rate ids match — proven by minting from the ids alone.
  assertEquals(
    base.option_key,
    mintDefaultOptionKey("per_hectare", { unit: "L", value: 2 }, base.rate_ids),
  );
  // And metadata is present for the UI regardless.
  assertEquals(base.targets, ["Downy Mildew"]);
  assertEquals(base.conditions, ["NSW"]);
});

Deno.test("§12 an ambiguous condition is surfaced without changing identity", () => {
  const plain = stamped([
    use("Grapes", "A", [{ label: "", basis: "per_hectare", unit: "L", value: 2 }]),
  ]);
  const ambiguous = JSON.parse(JSON.stringify(plain));
  ambiguous[0].rates[0].condition_ambiguous = true;

  const a = buildDefaultRateOptions(plain).options.per_hectare[0];
  const b = buildDefaultRateOptions(ambiguous).options.per_hectare[0];

  assertEquals(a.condition_ambiguous, false);
  assertEquals(b.condition_ambiguous, true);
  // `condition_ambiguous` is not part of the D1 rate identity either, so the
  // whole option is identical apart from the flag.
  assertEquals(b.option_key, a.option_key);
});

// ---------------------------------------------------------------------------
// §13 — deterministic ordering
// ---------------------------------------------------------------------------

Deno.test("§13 options sort by amount, then ranges, then key", () => {
  const uses = stamped([
    use("Grapes", "D", [{
      label: "",
      basis: "per_hectare",
      unit: "L",
      min_value: 1,
      max_value: 4,
    }]),
    use("Grapes", "C", [{ label: "", basis: "per_hectare", unit: "L", value: 9 }]),
    use("Grapes", "A", [{ label: "", basis: "per_hectare", unit: "L", value: 1 }]),
    use("Grapes", "E", [{
      label: "",
      basis: "per_hectare",
      unit: "L",
      min_value: 1,
      max_value: 2,
    }]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  const shape = options.per_hectare.map((o: DefaultRateOption) =>
    o.value !== null ? `v${o.value}` : `r${o.min_value}-${o.max_value}`
  );
  assertEquals(shape, ["v1", "v9", "r1-2", "r1-4"]);
});

Deno.test("§13 supporting lists are sorted, not parser order", () => {
  const { options } = buildDefaultRateOptions(vicolUses());
  for (const basis of ["per_hectare", "per_100_litres"] as const) {
    for (const o of options[basis]) {
      assertEquals([...o.rate_ids].sort(), o.rate_ids);
      assertEquals([...o.direction_ids].sort(), o.direction_ids);
      assertEquals([...o.targets].sort(), o.targets);
      assertEquals([...o.conditions].sort(), o.conditions);
      assertEquals([...o.crops].sort(), o.crops);
    }
  }
});

// ---------------------------------------------------------------------------
// §3/§21 — the response field, derived at the boundary
// ---------------------------------------------------------------------------

Deno.test("§3 applyDefaultRateOptions attaches the field additively", () => {
  const structured: Jsonish = {
    registration: { registration_number: "33182" },
    registered_uses: vicolUses(),
    active_ingredients: [],
  };
  const before = JSON.parse(JSON.stringify(structured.registered_uses));

  const violations = applyDefaultRateOptions(structured);

  assertEquals(violations, []);
  assertEquals(structured.default_rate_options.per_100_litres.length, 2);
  assertEquals(structured.default_rate_options.per_hectare, []);
  // registered_uses is evidence and is left exactly as it was found.
  assertEquals(structured.registered_uses, before);
  // Nothing else on the response was touched.
  assertEquals(structured.registration.registration_number, "33182");
});

Deno.test("§21 derivation is idempotent and reads only registered_uses", () => {
  const structured: Jsonish = {
    registered_uses: vicolUses(),
    // A projection carrying the SAME rate objects. Reading it as well would
    // double-count directions, so it must be ignored.
    grapevine_uses: vicolUses(),
  };

  applyDefaultRateOptions(structured);
  const first = JSON.parse(JSON.stringify(structured.default_rate_options));
  applyDefaultRateOptions(structured);

  assertEquals(structured.default_rate_options, first);
  for (const o of structured.default_rate_options.per_100_litres) {
    assertEquals(o.rate_ids.length, 2);
  }
});

Deno.test("§21 a response with no registered uses gets empty options", () => {
  for (const value of [undefined, null, [], "nonsense", 3]) {
    const structured: Jsonish = { registered_uses: value };
    const violations = applyDefaultRateOptions(structured);
    assertEquals(violations, []);
    assertEquals(structured.default_rate_options, {
      per_hectare: [],
      per_100_litres: [],
    });
  }
});

Deno.test("§21 malformed rows are skipped without throwing", () => {
  const structured: Jsonish = {
    registered_uses: [
      null,
      "nonsense",
      { rates: null },
      { rates: [null, "x", { basis: "other", unit: "", raw_text: "As directed" }] },
      ...vicolUses(),
    ],
  };

  const violations = applyDefaultRateOptions(structured);
  assertEquals(violations, []);
  // The good rows still produced their options.
  assertEquals(structured.default_rate_options.per_100_litres.length, 2);
});

Deno.test("a verbatim 'other' rate can never become an operational option", () => {
  const uses = stamped([
    use("Grapes", "A", [{
      label: "",
      basis: "other",
      unit: "",
      raw_text: "Apply as directed by an agronomist",
    }]),
  ]);

  const { options, violations } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare, []);
  assertEquals(options.per_100_litres, []);
  // Not a violation either: an unparseable direction is honest evidence, not
  // a missing identity.
  assertEquals(violations, []);
});

Deno.test("an inverted or non-finite amount produces no option", () => {
  const uses = stamped([
    use("Grapes", "A", [{
      label: "",
      basis: "range_per_hectare",
      unit: "L",
      min_value: 5,
      max_value: 1,
    }]),
    use("Grapes", "B", [{
      label: "",
      basis: "per_hectare",
      unit: "L",
      value: Number.NaN,
    }]),
  ]);

  const { options } = buildDefaultRateOptions(uses);
  assertEquals(options.per_hectare, []);
});
