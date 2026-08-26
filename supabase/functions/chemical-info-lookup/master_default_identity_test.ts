// Gate D4A.2 — Master Catalogue default-identity readiness.
//
// The defect, stated once:
//
//   A COMPLETE approved Master row short-circuits the lookup and is served
//   verbatim. That exit never reaches the D1 product lock point, so a row
//   approved BEFORE D1 carries authoritative grapevine rates with no
//   `rate_v1_` identities — and then cannot produce a single canonical
//   default-rate option. The catalogue's speed became the reason the operator
//   could not save a default.
//
// The repair is NOT to mint on the way out. These tests exist mostly to hold
// that line: a stored row is a POST-fan-out projection, and minting from it
// would invent three printed directions where the label printed one.

import {
  assert,
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyDefaultRateOptions,
  buildDefaultRateOptions,
  inspectDefaultRateOptionIdentityReadiness,
} from "./default_rate_options.ts";
import {
  buildMasterStructuredResponse,
  masterHasCompleteVineyardData,
  masterHasDefaultIdentityReadiness,
} from "./ingestion/master_lookup.ts";
import { mintDefaultOptionKey } from "./default_rates.ts";
import {
  applyRateIdentities,
  assignRateIds,
  type RateIdentityProduct,
  RATE_ID_VERSION,
} from "./rate_identity.ts";

// deno-lint-ignore no-explicit-any
type Jsonish = any;

const VICOL: RateIdentityProduct = {
  country: "AU",
  scheme: "apvma",
  registration_number: "33182",
};

const LABEL = "https://elabels.apvma.gov.au/33182ELBL.pdf";

/** An approved AU master row. Complete under the PRE-D4A.2 rules by default. */
function masterRow(over: Record<string, unknown> = {}): Jsonish {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    registration_country: "AU",
    registration_scheme: "apvma",
    registration_number: "33182",
    registered_product_name: "VICOL WINTER OIL INSECTICIDE",
    review_status: "approved",
    label_reference: LABEL,
    verification_status: "verified",
    // Deliberately EMPTY. Every test below that blocks the fast path does so
    // without the row admitting anything — the row believes it is finished.
    verification_unresolved_fields: [],
    registered_uses: [],
    ...over,
  };
}

const grapesRate = (over: Record<string, unknown> = {}) => ({
  label: "Tasmania",
  basis: "per_100_litres",
  unit: "L",
  value: 2,
  ...over,
});

/**
 * VICOL's six printed pest rows, as the AUTHORITATIVE path reconstructs them:
 * fanned out, but each fan-out still carrying the seed that records it was one
 * printed direction. This is the shape a stored pre-D1 row does NOT have.
 */
function vicolSeededUses(): Jsonish[] {
  const tasMites = {
    crop: "Grapes",
    targets: ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"],
    condition: "Tas",
  };
  const tas = { label: "Tasmania", basis: "per_100_litres", unit: "L", value: 2 };
  return [
    {
      crop: "Grapes",
      target_raw: "Grapeleaf Blister Mites",
      __direction_identity_seed: { ...tasMites },
      rates: [{ ...tas }],
    },
    {
      crop: "Grapes",
      target_raw: "European Red Mites",
      __direction_identity_seed: { ...tasMites },
      rates: [{ ...tas }],
    },
    {
      crop: "Grapes",
      target_raw: "Two Spotted Mites",
      __direction_identity_seed: { ...tasMites },
      rates: [{ ...tas }],
    },
    {
      crop: "Grapes",
      target_raw: "Grapevine Scale",
      rates: [{ label: "Tasmania", basis: "per_100_litres", unit: "L", value: 2 }],
    },
    {
      crop: "Grapes",
      target_raw: "European Red Mites",
      rates: [{ label: "NSW, Vic, SA", basis: "per_100_litres", unit: "L", value: 3 }],
    },
    {
      crop: "Grapes",
      target_raw: "Grapevine Scale",
      rates: [{
        label: "NSW, Vic, Qld, SA, WA",
        basis: "per_100_litres",
        unit: "L",
        value: 3,
      }],
    },
  ];
}

/**
 * The LEGACY stored form of the same label: already fanned out, seeds long
 * since stripped, and written before identities existed.
 */
function vicolLegacyStoredUses(): Jsonish[] {
  return vicolSeededUses().map((u: Jsonish) => {
    const copy = JSON.parse(JSON.stringify(u));
    delete copy.__direction_identity_seed;
    return copy;
  });
}

/** The same rows, stamped by the REAL D1 minter against the locked product. */
function stamped(uses: Jsonish[]): Jsonish[] {
  const copy = JSON.parse(JSON.stringify(uses));
  assignRateIds(copy, VICOL);
  return copy;
}

// ===========================================================================
// A/B. A LEGACY MASTER ROW MUST NOT SHORT-CIRCUIT
// ===========================================================================

Deno.test("A: an eligible grapevine rate with NO rate_id blocks the fast path", () => {
  const row = masterRow({
    registered_uses: [{
      crop: "Grapes",
      target_raw: "Grapevine Scale",
      rates: [grapesRate()],
    }],
  });

  // Everything the OLD rule asked for is present and satisfied.
  assertEquals(row.registration_number, "33182");
  assertEquals(row.label_reference, LABEL);
  assertEquals(row.verification_unresolved_fields, []);

  // And it is still not servable, because the one thing it cannot do is hand
  // the operator a default they can persist.
  assertEquals(masterHasDefaultIdentityReadiness(row), false);
  assertEquals(masterHasCompleteVineyardData(row), false);
});

Deno.test("B: a malformed rate_id blocks the fast path just as hard", () => {
  for (
    const bad of [
      "direction_v1_9f2c1d4e",
      "550e8400-e29b-41d4-a716-446655440000",
      "rate_v1",
      "2 L per 100 L",
      "",
    ]
  ) {
    const row = masterRow({
      registered_uses: [{
        crop: "Grapes",
        target_raw: "Grapevine Scale",
        rates: [grapesRate({ rate_id: bad })],
      }],
    });
    assertEquals(
      masterHasCompleteVineyardData(row),
      false,
      `${bad || "(empty)"} must not pass as a persisted rate identity`,
    );
  }
});

// ===========================================================================
// C. A MODERN MASTER ROW KEEPS THE FAST PATH
// ===========================================================================

Deno.test("C: valid D1 identities keep the Master fast path", () => {
  const row = masterRow({ registered_uses: stamped(vicolSeededUses()) });

  assertEquals(masterHasDefaultIdentityReadiness(row), true);
  assertEquals(masterHasCompleteVineyardData(row), true);

  // Served immediately, with real options — no register call is implied.
  const served = buildMasterStructuredResponse(row);
  const violations = applyDefaultRateOptions(served);
  assertEquals(violations, []);
  assertEquals(served.default_rate_options.per_hectare, []);
  assertEquals(served.default_rate_options.per_100_litres.length, 2);
});

Deno.test("C: readiness counts the identities it accepted", () => {
  const readiness = inspectDefaultRateOptionIdentityReadiness(
    stamped(vicolSeededUses()),
  );
  assertEquals(readiness.ready, true);
  assertEquals(readiness.violations, []);
  // Four printed directions, four supporting identities.
  assertEquals(readiness.identified_rate_count, 4);
});

// ===========================================================================
// D/E/F. WHAT MUST NOT BLOCK THE FAST PATH
// ===========================================================================

Deno.test("D: an other-crop rate with no identity does not block", () => {
  const row = masterRow({
    registered_uses: [
      ...stamped([{
        crop: "Grapes",
        target_raw: "Grapevine Scale",
        rates: [grapesRate()],
      }]),
      // No rate_id, and none is needed: a citrus dose can never be a vineyard
      // default, so its identity is not this contract's business.
      {
        crop: "Citrus",
        target_raw: "Citrus Rust Mite",
        rates: [{ label: "", basis: "per_100_litres", unit: "L", value: 1 }],
      },
    ],
  });

  assertEquals(masterHasDefaultIdentityReadiness(row), true);
  assertEquals(masterHasCompleteVineyardData(row), true);

  const served = buildMasterStructuredResponse(row);
  applyDefaultRateOptions(served);
  assertEquals(served.default_rate_options.per_100_litres.length, 1);
  assertEquals(served.default_rate_options.per_100_litres[0].crops, ["Grapes"]);
  // The citrus evidence is still served in full.
  assertEquals(served.other_crop_uses.length, 1);
});

Deno.test("E: a verbatim grapevine direction with no identity does not block", () => {
  const row = masterRow({
    registered_uses: [{
      crop: "Grapes",
      target_raw: "Bunch Rot",
      rates: [{
        label: "",
        basis: "other",
        unit: "",
        raw_text: "Apply as directed by an agronomist",
      }],
    }],
  });

  // It states no calculable amount, so it was never going to become an
  // operational default. Forcing a network enrichment over it would be
  // chasing an identity nothing will ever use.
  assertEquals(masterHasDefaultIdentityReadiness(row), true);
  assertEquals(masterHasCompleteVineyardData(row), true);

  const served = buildMasterStructuredResponse(row);
  applyDefaultRateOptions(served);
  assertEquals(served.default_rate_options, { per_hectare: [], per_100_litres: [] });
});

Deno.test("F: a non-grapevine product stays complete and simply has no options", () => {
  const row = masterRow({
    registered_product_name: "CITRUS-ONLY MITICIDE",
    registered_uses: [
      {
        crop: "Citrus",
        target_raw: "Citrus Rust Mite",
        rates: [{ label: "", basis: "per_100_litres", unit: "L", value: 1 }],
      },
      {
        crop: "Apples",
        target_raw: "Codling Moth",
        rates: [{ label: "", basis: "per_hectare", unit: "L", value: 1.5 }],
      },
    ],
  });

  assertEquals(masterHasCompleteVineyardData(row), true);

  const served = buildMasterStructuredResponse(row);
  const violations = applyDefaultRateOptions(served);
  assertEquals(violations, []);
  assertEquals(served.default_rate_options, { per_hectare: [], per_100_litres: [] });
  // Zero options is not a degradation: nothing about this lookup failed.
  assertEquals(served.registered_for_grapevine, false);
});

Deno.test("F: a row with no registered uses at all is unaffected by this gate", () => {
  for (const uses of [[], null, undefined, "nonsense"]) {
    assertEquals(masterHasDefaultIdentityReadiness(masterRow({ registered_uses: uses })), true);
  }
  // The pre-existing rules still decide those rows on their own terms.
  assertEquals(
    masterHasCompleteVineyardData(masterRow({
      registered_uses: [],
      verification_unresolved_fields: ["rates:GRAPEVINE"],
    })),
    false,
  );
});

// ===========================================================================
// G. THE POINT OF THE WHOLE GATE — NO LOCAL MINT FROM A LEGACY PROJECTION
// ===========================================================================

Deno.test("G: a legacy fanned-out row set is refused, not locally minted", () => {
  const uses = vicolLegacyStoredUses();
  const row = masterRow({ registered_uses: uses });
  const before = JSON.parse(JSON.stringify(uses));

  assertEquals(masterHasCompleteVineyardData(row), false);

  // Nothing was stamped, rewritten, reordered or removed by asking.
  assertEquals(row.registered_uses, before);
  for (const u of row.registered_uses) {
    assertEquals(u.direction_id, undefined);
    for (const r of u.rates) assertEquals(r.rate_id, undefined);
  }
});

Deno.test("G: minting from the stored projection would invent 3 directions for 1", () => {
  // This is the counterfactual the gate refuses, made explicit. If a future
  // developer "fixes" readiness by stamping the served envelope, THIS is what
  // the operator gets — and every assertion below is what breaks.
  const naive = JSON.parse(JSON.stringify(vicolLegacyStoredUses()));
  assignRateIds(naive, VICOL);

  const naiveMiteIds = new Set(
    naive.slice(0, 3).map((u: Jsonish) => u.rates[0].rate_id as string),
  );
  // Three identities for ONE printed direction — D1.2 violated.
  assertEquals(naiveMiteIds.size, 3);

  const naiveDirections = new Set(naive.slice(0, 3).map((u: Jsonish) => u.direction_id));
  assertEquals(naiveDirections.size, 3);

  // And the damage reaches the option: the 2 L default would cite FOUR
  // supporting rates instead of two, so its `option_key` — the thing already
  // persisted in `default_rates` — would differ from the correct one forever.
  const naiveOptions = buildDefaultRateOptions(naive).options.per_100_litres;
  const naiveTwo = naiveOptions.find((o) => o.value === 2);
  assert(naiveTwo);
  assertEquals(naiveTwo.rate_ids.length, 4);

  const correct = buildDefaultRateOptions(stamped(vicolSeededUses())).options
    .per_100_litres.find((o) => o.value === 2);
  assert(correct);
  assertEquals(correct.rate_ids.length, 2);
  assertNotEquals(naiveTwo.option_key, correct.option_key);
});

// ===========================================================================
// H/I. VICOL ACCEPTANCE — LEGACY MASTER THROUGH TO CANONICAL OPTIONS
// ===========================================================================

Deno.test("H: the legacy VICOL master keeps its registration but not the fast path", () => {
  const row = masterRow({ registered_uses: vicolLegacyStoredUses() });

  // Under the old rules this was a complete fast hit: registration, label,
  // grapevine rates, nothing unresolved.
  assertEquals(row.registration_number, "33182");
  assertEquals(row.verification_unresolved_fields, []);
  assert(row.registered_uses.some((u: Jsonish) => u.rates.length > 0));

  assertEquals(masterHasCompleteVineyardData(row), false);

  // The identity survives to pin the enrichment that follows — this row is
  // set aside, never discarded, and no other registration is searched for.
  const served = buildMasterStructuredResponse(row);
  assertEquals(served.registration.registration_number, "33182");
  assertEquals(served.registration.country_code, "AU");
  assertEquals(served.registration.scheme, "apvma");
  assertEquals(served.master.master_chemical_id, row.id);
});

Deno.test("I: the resolved D1 path then yields the canonical VICOL options", () => {
  // What the authoritative path produces once 33182 is reconstructed from its
  // label: the seeds exist, so the mint is sound.
  const structured: Jsonish = {
    registration: {
      country_code: "AU",
      scheme: "apvma",
      registration_number: "33182",
    },
    registered_uses: vicolSeededUses(),
  };

  applyRateIdentities(structured);
  const violations = applyDefaultRateOptions(structured);

  assertEquals(violations, []);
  const opts = structured.default_rate_options;
  assertEquals(opts.per_hectare, []);
  assertEquals(opts.per_100_litres.length, 2);

  const [two, three] = opts.per_100_litres;
  assertEquals(two.value, 2);
  assertEquals(three.value, 3);
  assertEquals(two.rate_ids.length, 2);
  assertEquals(three.rate_ids.length, 2);

  const unique = new Set([...two.rate_ids, ...three.rate_ids]);
  assertEquals(unique.size, 4);
  for (const id of unique) assert(id.startsWith(`${RATE_ID_VERSION}_`));

  // The reconstructed product is now a MODERN master row: storing this result
  // would restore the fast path for every later lookup.
  assertEquals(
    masterHasCompleteVineyardData(
      masterRow({ registered_uses: structured.registered_uses }),
    ),
    true,
  );
});

// ===========================================================================
// J. THE FAST PATH'S OPTIONS ARE THE D3 CANONICAL ONES
// ===========================================================================

Deno.test("J: a served modern Master row's option keys are the D3 minter's own", () => {
  const row = masterRow({ registered_uses: stamped(vicolSeededUses()) });
  const served = buildMasterStructuredResponse(row);
  applyDefaultRateOptions(served);

  for (const option of served.default_rate_options.per_100_litres) {
    assertEquals(
      option.option_key,
      mintDefaultOptionKey(
        option.basis,
        {
          unit: option.unit,
          value: option.value,
          min_value: option.min_value,
          max_value: option.max_value,
        },
        option.rate_ids,
      ),
    );
  }
});

// ===========================================================================
// Fail-soft (§16) — a degraded fallback still serves the chemical
// ===========================================================================

Deno.test("a legacy row served as the incomplete fallback keeps its evidence", () => {
  // When enrichment fails outright, index.ts still serves the incomplete
  // master. That path must lose neither the chemical nor its label rows — it
  // simply cannot offer a persistable default.
  const row = masterRow({ registered_uses: vicolLegacyStoredUses() });
  const served = buildMasterStructuredResponse(row);
  const violations = applyDefaultRateOptions(served);

  assertEquals(served.registered_uses.length, 6);
  assertEquals(served.grapevine_uses.length, 6);
  assertEquals(served.registered_for_grapevine, true);
  assertEquals(served.registration.registration_number, "33182");

  // No option is fabricated, and the reason is reported rather than hidden.
  assertEquals(served.default_rate_options, { per_hectare: [], per_100_litres: [] });
  assert(violations.length > 0);
  for (const v of violations) assertEquals(v.code, "rate_id_missing");
});
