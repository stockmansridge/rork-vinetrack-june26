import { assert, assertEquals, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyRateIdentities,
  assignRateIds,
  canonicalRateIdentityInput,
  mintRateId,
  normaliseIdentityNumber,
  type RateIdentityProduct,
  type RateIdentityRate,
  sha256Hex,
} from "./rate_identity.ts";
import {
  canonicalDirectionIdentityInput,
  canonicalTargetSet,
  DIRECTION_ID_VERSION,
  DIRECTION_SEED_KEY,
  isLockedProduct,
  mintDirectionId,
  stripStructuredDirectionSeeds,
} from "./rate_identity.ts";
import {
  extractManufacturerLabelUses,
  manufacturerUsesToRegisteredUses,
} from "./ingestion/manufacturer_label.ts";
import { VICOL_33182_LABEL_ITEMS } from "./ingestion/seeds/label_fixture_33182.ts";

// ===========================================================================
// Gate D1 — stable registered rate identity.
//
// The defect being closed: an operator's chosen default rate could only be
// recovered by matching on its NUMBER, so two authoritative directions stating
// the same figure were indistinguishable and the choice was silently
// re-decided on every reopen.
//
// The rule: identity comes from the rate's MEANING, never from the
// circumstances of its retrieval.
// ===========================================================================

const VICOL: RateIdentityProduct = {
  country: "AU",
  scheme: "apvma",
  registration_number: "33182",
};

const rate = (r: Partial<RateIdentityRate>): RateIdentityRate => ({
  basis: "per_100_litres",
  unit: "L",
  value: 3,
  label: "",
  ...r,
});

// ---------------------------------------------------------------------------
// The digest itself. A transcribed constant table must not fail silently.
// ---------------------------------------------------------------------------

Deno.test("sha256 matches the published FIPS 180-4 vectors", () => {
  assertEquals(
    sha256Hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  );
  assertEquals(
    sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
  assertEquals(
    sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  );
});

Deno.test("an id is deterministic, prefixed and never a UUID", () => {
  const id = mintRateId(VICOL, { crop: "Grapevines", target_raw: "Grapevine scale" }, rate({}));
  assert(id.startsWith("rate_v1_"), id);
  assertEquals(id.length, "rate_v1_".length + 32);
  // A UUID would contain dashes and change every call.
  assert(!id.slice(8).includes("-"));
  assertEquals(
    id,
    mintRateId(VICOL, { crop: "Grapevines", target_raw: "Grapevine scale" }, rate({})),
  );
});

// ---------------------------------------------------------------------------
// A. Same semantic rate extracted twice
// ---------------------------------------------------------------------------

Deno.test("A — extracting the same rate twice yields one identity", () => {
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };
  const first = mintRateId(VICOL, use, rate({ label: "NSW" }));
  // A second pass builds fresh objects; nothing is shared between them.
  const second = mintRateId(
    { country: "AU", scheme: "apvma", registration_number: "33182" },
    { crop: "Grapevines", target_raw: "Grapevine scale" },
    { basis: "per_100_litres", unit: "L", value: 3, label: "NSW" },
  );
  assertEquals(first, second);
});

// ---------------------------------------------------------------------------
// B. Array order
// ---------------------------------------------------------------------------

Deno.test("B — reordering the array does not move any identity", () => {
  const build = () => [
    {
      crop: "Grapevines",
      target_raw: "Grapevine scale",
      rates: [rate({ value: 2, label: "Tasmania" }), rate({ value: 3, label: "NSW" })],
    },
    {
      crop: "Grapevines",
      target_raw: "European red mite",
      rates: [rate({ value: 3, label: "NSW" })],
    },
  ];

  const forward = build();
  const reversed = build().reverse();
  reversed[1].rates.reverse();

  assignRateIds(forward, VICOL);
  assignRateIds(reversed, VICOL);

  const idFor = (uses: ReturnType<typeof build>, target: string, value: number) =>
    uses.find((u) => u.target_raw === target)!
      .rates.find((r) => r.value === value)! as RateIdentityRate & { rate_id?: string };

  assertEquals(
    idFor(forward, "Grapevine scale", 2).rate_id,
    idFor(reversed, "Grapevine scale", 2).rate_id,
  );
  assertEquals(
    idFor(forward, "European red mite", 3).rate_id,
    idFor(reversed, "European red mite", 3).rate_id,
  );
});

// ---------------------------------------------------------------------------
// C. Case, whitespace and punctuation
// ---------------------------------------------------------------------------

Deno.test("C — case, whitespace and punctuation differences are not new rates", () => {
  const canonical = mintRateId(
    VICOL,
    { crop: "Grapevines", target_raw: "Grapevine scale" },
    rate({ label: "NSW/Vic/SA" }),
  );
  const reprinted = mintRateId(
    { country: "au", scheme: "APVMA", registration_number: " 33182 " },
    { crop: "  GRAPEVINES ", target_raw: "grapevine  scale" },
    rate({ label: "NSW, Vic, SA", unit: "l" }),
  );
  assertEquals(canonical, reprinted);
});

Deno.test("C — but a genuinely different condition is a different rate", () => {
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };
  assertNotEquals(
    mintRateId(VICOL, use, rate({ label: "NSW/Vic/SA" })),
    mintRateId(VICOL, use, rate({ label: "NSW/Vic/SA/WA" })),
  );
});

// ---------------------------------------------------------------------------
// D. Same number, different target
// ---------------------------------------------------------------------------

Deno.test("D — 3 L/100 L against two targets is two identities", () => {
  const scale = mintRateId(
    VICOL,
    { crop: "Grapevines", target_raw: "Grapevine scale" },
    rate({ value: 3 }),
  );
  const mite = mintRateId(
    VICOL,
    { crop: "Grapevines", target_raw: "European red mite" },
    rate({ value: 3 }),
  );
  // The UI may later present these as ONE operational choice ("3 L/100 L").
  // The registered directions underneath stay distinct, because a compliance
  // record has to say which direction was followed.
  assertNotEquals(scale, mite);
});

Deno.test("D — the same target under a different crop is a different rate", () => {
  assertNotEquals(
    mintRateId(VICOL, { crop: "Grapevines", target_raw: "Scale" }, rate({})),
    mintRateId(VICOL, { crop: "Citrus", target_raw: "Scale" }, rate({})),
  );
});

// ---------------------------------------------------------------------------
// E. Same target, different jurisdiction
// ---------------------------------------------------------------------------

Deno.test("E — jurisdiction is part of semantic identity", () => {
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };
  assertNotEquals(
    mintRateId(VICOL, use, rate({ value: 2, label: "Tasmania" })),
    mintRateId(VICOL, use, rate({ value: 3, label: "NSW/Vic/Qld/SA/WA" })),
  );
  // Even holding the NUMBER constant, the jurisdiction alone separates them.
  assertNotEquals(
    mintRateId(VICOL, use, rate({ value: 3, label: "Tasmania" })),
    mintRateId(VICOL, use, rate({ value: 3, label: "NSW/Vic/Qld/SA/WA" })),
  );
});

// ---------------------------------------------------------------------------
// F / I. The numbers themselves
// ---------------------------------------------------------------------------

Deno.test("F — 2 L and 3 L are different rates", () => {
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };
  assertNotEquals(
    mintRateId(VICOL, use, rate({ value: 2 })),
    mintRateId(VICOL, use, rate({ value: 3 })),
  );
});

Deno.test("I — value, min, max, basis and unit each change identity", () => {
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };
  const base = rate({});
  const baseId = mintRateId(VICOL, use, base);

  assertNotEquals(baseId, mintRateId(VICOL, use, rate({ value: 3.5 })));
  assertNotEquals(baseId, mintRateId(VICOL, use, rate({ unit: "mL" })));
  assertNotEquals(baseId, mintRateId(VICOL, use, rate({ basis: "per_hectare" })));

  const range = rate({ basis: "range_per_100_litres", value: null, min_value: 1, max_value: 2 });
  assertNotEquals(
    mintRateId(VICOL, use, range),
    mintRateId(VICOL, use, { ...range, min_value: 1.5 }),
  );
  assertNotEquals(
    mintRateId(VICOL, use, range),
    mintRateId(VICOL, use, { ...range, max_value: 5 }),
  );
});

Deno.test("I — trailing zeros are the same number, absence is not zero", () => {
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };
  assertEquals(
    mintRateId(VICOL, use, rate({ value: 3 })),
    mintRateId(VICOL, use, rate({ value: 3.0 })),
  );
  assertEquals(normaliseIdentityNumber(3), normaliseIdentityNumber(3.000));
  // "no upper bound" must never hash like "an upper bound of zero".
  assertNotEquals(normaliseIdentityNumber(null), normaliseIdentityNumber(0));
  assertEquals(normaliseIdentityNumber(null), "-");
  assertEquals(normaliseIdentityNumber(0), "0");
});

// ---------------------------------------------------------------------------
// G. Ranges
// ---------------------------------------------------------------------------

Deno.test("G — a true 100–200 mL/100 L range is ONE identity", () => {
  const use = { crop: "Grapevines", target_raw: "Downy mildew" };
  const range: RateIdentityRate = {
    basis: "range_per_100_litres",
    unit: "mL",
    min_value: 100,
    max_value: 200,
    label: "",
  };
  const id = mintRateId(VICOL, use, range);

  // One row, one id — re-minting the same range never splits it.
  assertEquals(id, mintRateId(VICOL, use, { ...range }));

  // And it is not the same thing as either bound quoted on its own.
  assertNotEquals(
    id,
    mintRateId(VICOL, use, { basis: "per_100_litres", unit: "mL", value: 100 }),
  );
  assertNotEquals(
    id,
    mintRateId(VICOL, use, { basis: "per_100_litres", unit: "mL", value: 200 }),
  );
});

// ---------------------------------------------------------------------------
// H. Label version
// ---------------------------------------------------------------------------

Deno.test("H — reissuing the label does not move an unchanged rate", () => {
  // `label_version` is deliberately absent from the canonical input: a 2019
  // and a 2024 label that both state "Grapevine scale, 3 L/100 L, NSW" state
  // the SAME registered direction, and an operator's default must survive the
  // document being reissued. Detecting that the source moved on belongs in the
  // default's snapshot, not in the rate's identity.
  const canonical = canonicalRateIdentityInput(
    VICOL,
    mintDirectionId(VICOL, { crop: "Grapevines", target_raw: "Grapevine scale" }),
    rate({ label: "NSW" }),
  );
  assert(!canonical.includes("label_version"));
  assert(!canonical.includes("2019"));

  const withVersion = {
    ...rate({ label: "NSW" }),
    label_version: "2024-07",
    retrieved_at: "2026-08-26T04:00:00Z",
  } as RateIdentityRate;
  assertEquals(
    mintRateId(VICOL, { crop: "Grapevines", target_raw: "Grapevine scale" }, rate({ label: "NSW" })),
    mintRateId(VICOL, { crop: "Grapevines", target_raw: "Grapevine scale" }, withVersion),
  );
});

Deno.test("retrieval circumstances are excluded from both canonical inputs", () => {
  const excluded = ["fetched_at", "retrieved_at", "request", "cache", "index", "url"];

  const rateCanonical = canonicalRateIdentityInput(
    VICOL,
    mintDirectionId(VICOL, { crop: "Grapevines", target_raw: "Grapevine scale" }),
    rate({ label: "NSW" }),
  );
  const directionCanonical = canonicalDirectionIdentityInput(VICOL, {
    crop: "Grapes",
    targets: ["European Red Mites"],
    condition: "NSW, Vic, SA",
  });

  for (const token of excluded) {
    assert(!rateCanonical.includes(token), `rate input must not mention ${token}`);
    assert(!directionCanonical.includes(token), `direction input must not mention ${token}`);
  }
  // A direction identity never binds the label version either — same reason.
  assert(!directionCanonical.includes("label_version"));
});

Deno.test("raw_text is excluded for parsed rates, and included for `other`", () => {
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };

  // A punctuation-only reprint of the source wording must not mint a new id.
  assertEquals(
    mintRateId(VICOL, use, { ...rate({}), raw_text: "3 L/100 L" }),
    mintRateId(VICOL, use, { ...rate({}), raw_text: "3 L / 100 L." }),
  );

  // `basis: "other"` carries NO numeric fields, so its verbatim text is the
  // only thing distinguishing two entries on the same use. Excluding it there
  // would be a guaranteed collision, not a hypothetical one.
  const a = mintRateId(VICOL, use, {
    basis: "other",
    unit: "",
    raw_text: "Apply as directed by an agronomist",
  });
  const b = mintRateId(VICOL, use, {
    basis: "other",
    unit: "",
    raw_text: "Consult your reseller before use",
  });
  assertNotEquals(a, b);
});

// ---------------------------------------------------------------------------
// J. Historical records
// ---------------------------------------------------------------------------

Deno.test("J — a historical rate with no rate_id still decodes and is untouched", () => {
  // Exactly the shape stored before this gate existed: no `rate_id` key.
  const historical = {
    crop: "Grapevines",
    target_raw: "Grapevine scale",
    rates: [{ label: "NSW", basis: "per_100_litres", value: 3, unit: "L", raw_text: "3 L/100 L" }],
    withholding_period_days: null,
    re_entry_period_hours: null,
  };
  const before = JSON.parse(JSON.stringify(historical));

  // Reading such a row must not throw, and must not require the field.
  const rateRow = historical.rates[0] as Record<string, unknown>;
  assertEquals(rateRow.rate_id, undefined);

  // Deriving an id for it on READ is possible and deterministic — reported as
  // available, deliberately NOT written back in this gate. No backfill.
  const derived = mintRateId(VICOL, historical, historical.rates[0]);
  assertEquals(derived, mintRateId(VICOL, historical, historical.rates[0]));

  // The historical row itself is unchanged by having been read.
  assertEquals(historical, before);
});

Deno.test("stamping never alters any authoritative label value", () => {
  const uses = [{
    crop: "Grapevines",
    target_raw: "Grapevine scale",
    rates: [{
      label: "NSW",
      basis: "per_100_litres",
      value: 3,
      min_value: null,
      max_value: null,
      unit: "L",
      raw_text: "3 L/100 L",
      condition_ambiguous: true,
    }],
    withholding_period_days: 14,
    re_entry_period_hours: null,
    re_entry_statement: "DO NOT allow entry until the spray has dried.",
    restrictions: "Do not graze.",
  }];
  const before = JSON.parse(JSON.stringify(uses));

  assignRateIds(uses, VICOL);

  const after = JSON.parse(JSON.stringify(uses));
  const strippedRate = { ...after[0].rates[0] };
  delete strippedRate.rate_id;

  assertEquals(strippedRate, before[0].rates[0]);
  assertEquals(after[0].withholding_period_days, 14);
  assertEquals(after[0].re_entry_statement, "DO NOT allow entry until the spray has dried.");
  assertEquals(after[0].restrictions, "Do not graze.");
  assertEquals(after[0].rates.length, 1);
  assert(typeof after[0].rates[0].rate_id === "string");
});

Deno.test("stamping is idempotent", () => {
  const uses = [{
    crop: "Grapevines",
    target_raw: "Grapevine scale",
    rates: [rate({})],
  }];
  assignRateIds(uses, VICOL);
  const first = (uses[0].rates[0] as RateIdentityRate & { rate_id?: string }).rate_id;
  assignRateIds(uses, VICOL);
  const second = (uses[0].rates[0] as RateIdentityRate & { rate_id?: string }).rate_id;
  assertEquals(first, second);
});

Deno.test("a structured response stamps every served view of a row", () => {
  const grapevineUse = {
    crop: "Grapevines",
    target_raw: "Grapevine scale",
    rates: [rate({})],
  };
  const structured = {
    registration: { country_code: "AU", scheme: "apvma", registration_number: "33182" },
    registered_uses: [grapevineUse],
    // A projection that COPIED rather than shared its rows.
    grapevine_uses: [JSON.parse(JSON.stringify(grapevineUse))],
    other_crop_uses: [],
  };

  applyRateIdentities(structured);

  const fromFull = (structured.registered_uses[0].rates[0] as { rate_id?: string }).rate_id;
  const fromProjection =
    (structured.grapevine_uses[0].rates[0] as { rate_id?: string }).rate_id;
  assert(typeof fromFull === "string");
  // A copy is still the same registered rate, so it must carry the same id.
  assertEquals(fromFull, fromProjection);
});

Deno.test("an unresolved product still mints deterministically", () => {
  // Registration may legitimately be unknown. The id stays stable so a client
  // can still persist a choice; it CHANGES once identity is locked, which is
  // correct — the rate became bound to a product it was not bound to before.
  const use = { crop: "Grapevines", target_raw: "Grapevine scale" };
  const unresolved = mintRateId(null, use, rate({}));
  assertEquals(unresolved, mintRateId({}, use, rate({})));
  assertNotEquals(unresolved, mintRateId(VICOL, use, rate({})));
});

// ---------------------------------------------------------------------------
// K. VICOL 33182 — the acceptance case
// ---------------------------------------------------------------------------

// The FOUR grape directions the VICOL WINTER OIL manufacturer label actually
// prints, transcribed from the label's Crop/Pest/State/Rate table.
//
// # The fixture defect this replaces
//
// The first version of this test gave the European Red Mites 3 L row the
// GRAPEVINE SCALE state set ("NSW/Vic/Qld/SA/WA"). The label does not say
// that: European Red Mites at 3 L/100 L is registered in NSW, Vic and SA only
// — not Qld, not WA. A fixture asserting otherwise would have signed off an
// identity built from a jurisdiction the label never granted, which is exactly
// the class of error this gate exists to make impossible.
//
// It also flattened the Tasmania 2 L direction to a single mite. That row
// covers THREE pests, and dropping two of them narrows a registered direction
// the grower is entitled to rely on.
const VICOL_GRAPE_DIRECTIONS = () => [
  {
    crop: "Grapes",
    target_raw: "Grapeleaf Blister Mites, European Red Mites, Two Spotted Mites",
    rates: [rate({ value: 2, label: "Tas" })],
  },
  {
    crop: "Grapes",
    target_raw: "European Red Mites",
    rates: [rate({ value: 3, label: "NSW, Vic, SA" })],
  },
  {
    crop: "Grapes",
    target_raw: "Grapevine Scale",
    rates: [rate({ value: 3, label: "NSW, Vic, Qld, SA, WA" })],
  },
  {
    crop: "Grapes",
    target_raw: "Grapevine Scale",
    rates: [rate({ value: 2, label: "Tas" })],
  },
];

Deno.test("K — VICOL 33182 keeps four registered identities behind two numbers", () => {
  const uses = VICOL_GRAPE_DIRECTIONS();
  assignRateIds(uses, VICOL);

  const all = uses.flatMap((u) => u.rates as (RateIdentityRate & { rate_id: string })[]);
  assertEquals(all.length, 4);

  // FOUR authoritative directions, four identities. Nothing collapsed.
  assertEquals(new Set(all.map((r) => r.rate_id)).size, 4);

  // TWO operational numbers. This is the grouping a later default-rate
  // selection performs — and precisely why that selection must reference a
  // LIST of rate ids rather than a single one: choosing "3 L/100 L" adopts two
  // registered directions at once.
  const byValue = new Map<number, string[]>();
  for (const r of all) {
    byValue.set(r.value as number, [...(byValue.get(r.value as number) ?? []), r.rate_id]);
  }
  assertEquals([...byValue.keys()].sort(), [2, 3]);

  // 3 L/100 L is backed by European Red Mites (NSW, Vic, SA) and Grapevine
  // Scale (NSW, Vic, Qld, SA, WA) — two pests under two DIFFERENT state sets
  // that merely share a number.
  assertEquals(byValue.get(3)!.length, 2);
  assertNotEquals(byValue.get(3)![0], byValue.get(3)![1]);

  // 2 L/100 L is backed by the three-mite row and Grapevine Scale, both Tas —
  // same state, different pests.
  assertEquals(byValue.get(2)!.length, 2);
  assertNotEquals(byValue.get(2)![0], byValue.get(2)![1]);

  // Re-extracting the whole label reproduces the same four identities.
  const second = VICOL_GRAPE_DIRECTIONS();
  assignRateIds(second, VICOL);
  assertEquals(
    second.flatMap((u) => (u.rates as { rate_id: string }[]).map((r) => r.rate_id)).sort(),
    all.map((r) => r.rate_id).sort(),
  );
});

Deno.test("K — the corrected European Red Mites state set is what gets hashed", () => {
  // A regression guard on the correction itself. If the wrong state set ever
  // creeps back the identity moves, proving the jurisdiction is genuinely
  // load-bearing and that the two 3 L rows are not interchangeable.
  const correct = mintRateId(
    VICOL,
    { crop: "Grapes", target_raw: "European Red Mites" },
    rate({ value: 3, label: "NSW, Vic, SA" }),
  );
  const wrong = mintRateId(
    VICOL,
    { crop: "Grapes", target_raw: "European Red Mites" },
    rate({ value: 3, label: "NSW, Vic, Qld, SA, WA" }),
  );
  assertNotEquals(correct, wrong);

  const scale = mintRateId(
    VICOL,
    { crop: "Grapes", target_raw: "Grapevine Scale" },
    rate({ value: 3, label: "NSW, Vic, Qld, SA, WA" }),
  );
  assertNotEquals(correct, scale);
});

Deno.test("K — the LIVE extractor produces those same four directions", () => {
  // Not a synthetic fixture: this runs the real Stage B manufacturer-label
  // extractor over the real VICOL 33182 PDF text layer, so the acceptance
  // evidence cannot drift from what the pipeline actually serves.
  const parse = extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS);
  assert(parse.found, "DIRECTIONS FOR USE table was not located");

  const grapes = parse.uses.filter((u) => /^grapes$/i.test(u.crop));
  assertEquals(grapes.length, 4);

  assertEquals(
    grapes.map((u) => ({
      targets: u.targets,
      condition: u.condition,
      value: u.rates[0]?.value,
      unit: u.rates[0]?.unit,
      basis: u.rates[0]?.basis,
    })),
    [
      {
        targets: ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"],
        condition: "Tas",
        value: 2,
        unit: "L",
        basis: "per_100_litres",
      },
      {
        targets: ["European Red Mites"],
        condition: "NSW, Vic, SA",
        value: 3,
        unit: "L",
        basis: "per_100_litres",
      },
      {
        targets: ["Grapevine Scale"],
        condition: "NSW, Vic, Qld, SA, WA",
        value: 3,
        unit: "L",
        basis: "per_100_litres",
      },
      {
        targets: ["Grapevine Scale"],
        condition: "Tas",
        value: 2,
        unit: "L",
        basis: "per_100_litres",
      },
    ],
  );

  // Minting over the extractor's OWN output yields four distinct identities,
  // stable across a second independent extraction.
  const idsFor = (uses: typeof grapes) =>
    uses.map((u) =>
      mintRateId(
        VICOL,
        { crop: u.crop, targets: u.targets, condition: u.condition },
        { ...u.rates[0], label: u.condition },
      )
    );

  const ids = idsFor(grapes);
  assertEquals(new Set(ids).size, 4);
  assertEquals(idsFor(
    extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS).uses
      .filter((u) => /^grapes$/i.test(u.crop)),
  ), ids);

  assertEquals([...new Set(grapes.map((u) => u.rates[0]?.value))].sort(), [2, 3]);
});

// ===========================================================================
// Gate D1.2 — ONE PRINTED DIRECTION = ONE IDENTITY.
//
// The defect: `registered_uses` carries one target per row, so a printed
// direction naming three pests is FANNED OUT into three rows. Identity was
// being derived after that fan-out, from each row's single surviving pest —
// which minted three identities for one regulatory direction and, because the
// projection shared one rate object across the three rows, let whichever row
// was stamped last overwrite its siblings.
//
// The rule: identity belongs to the printed direction, minted while the
// direction still holds its complete target set, then copied verbatim onto
// every projected row.
// ===========================================================================

interface ProjectedRow {
  crop: string;
  target: string;
  direction_id: string;
  rates: {
    rate_id: string;
    value?: number | null;
    basis?: string;
    unit?: string;
    label?: string;
  }[];
}

/** One printed direction, in the extractor's own shape. */
const printed = (targets: string[], condition: string, value: number) => ({
  crop: "Grapes",
  targets,
  condition,
  rates: [{
    label: "",
    basis: "per_100_litres",
    value,
    unit: "L",
    raw_text: `${value} L / 100 L`,
  }],
  restrictions: null,
});

const project = (dirs: ReturnType<typeof printed>[]): ProjectedRow[] =>
  manufacturerUsesToRegisteredUses(dirs as never, {
    product: VICOL,
  }) as unknown as ProjectedRow[];

const projectVicol = (): ProjectedRow[] =>
  project(
    extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS).uses
      .filter((u) => /^grapes$/i.test(u.crop)) as unknown as ReturnType<typeof printed>[],
  );

const pair = (r: ProjectedRow) => `${r.direction_id}::${r.rates[0].rate_id}`;

// ---------------------------------------------------------------------------
// A. One direction, three targets
// ---------------------------------------------------------------------------

Deno.test("D1.2 A — a three-pest direction is 3 rows but ONE identity", () => {
  const rows = project([
    printed(["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"], "Tas", 2),
  ]);

  // The projection still serves one row per pest — that part is unchanged.
  assertEquals(rows.length, 3);
  assertEquals(rows.map((r) => r.target), [
    "Grapeleaf Blister Mites",
    "European Red Mites",
    "Two Spotted Mites",
  ]);

  // But it is ONE regulatory direction stating ONE rate.
  assertEquals(new Set(rows.map((r) => r.direction_id)).size, 1);
  assertEquals(new Set(rows.map((r) => r.rates[0].rate_id)).size, 1);
  assert(rows[0].direction_id.startsWith(`${DIRECTION_ID_VERSION}_`));
  assert(rows[0].rates[0].rate_id.startsWith("rate_v1_"));
});

// ---------------------------------------------------------------------------
// B / C. Order independence
// ---------------------------------------------------------------------------

Deno.test("D1.2 B — fan-out row order does not decide any identity", () => {
  const rows = project([
    printed(["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"], "Tas", 2),
  ]);
  const byTarget = new Map(rows.map((r) => [r.target, pair(r)]));

  // Reversing the served rows cannot change what any row carries — the ids
  // were copied onto each row, never computed from its position.
  const reversed = [...rows].reverse();
  for (const row of reversed) {
    assertEquals(pair(row), byTarget.get(row.target));
  }
  assertEquals(new Set(reversed.map((r) => r.direction_id)).size, 1);
});

Deno.test("D1.2 C — reordering targets[] in the source changes nothing", () => {
  const forward = project([
    printed(["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"], "Tas", 2),
  ]);
  const shuffled = project([
    printed(["Two Spotted Mites", "Grapeleaf Blister Mites", "European Red Mites"], "Tas", 2),
  ]);

  // The label's reading order is a typesetting fact, not a regulatory one.
  assertEquals(shuffled[0].direction_id, forward[0].direction_id);
  assertEquals(shuffled[0].rates[0].rate_id, forward[0].rates[0].rate_id);

  // Duplicate wording collapses too — a pest listed twice is still one pest.
  const duplicated = project([
    printed(
      ["European Red Mites", "Grapeleaf Blister Mites", "european red mites", "Two Spotted Mites"],
      "Tas",
      2,
    ),
  ]);
  assertEquals(duplicated[0].direction_id, forward[0].direction_id);

  assertEquals(canonicalTargetSet({ targets: ["B", "a", "B "] }), ["a", "b"]);
});

// ---------------------------------------------------------------------------
// D. The target SET is load-bearing
// ---------------------------------------------------------------------------

Deno.test("D1.2 D — adding or removing a genuine target is a new direction", () => {
  const three = project([
    printed(["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"], "Tas", 2),
  ])[0];
  const two = project([
    printed(["Grapeleaf Blister Mites", "European Red Mites"], "Tas", 2),
  ])[0];
  const four = project([
    printed(
      ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites", "Bryobia Mites"],
      "Tas",
      2,
    ),
  ])[0];

  // A direction covering different pests is a different registered direction,
  // even at an identical rate and jurisdiction.
  assertNotEquals(two.direction_id, three.direction_id);
  assertNotEquals(four.direction_id, three.direction_id);
  assertNotEquals(two.rates[0].rate_id, three.rates[0].rate_id);
  assertNotEquals(four.rates[0].rate_id, three.rates[0].rate_id);
});

// ---------------------------------------------------------------------------
// E. Same number, two printed directions
// ---------------------------------------------------------------------------

Deno.test("D1.2 E — one number stated by two directions is two identities", () => {
  const rows = project([
    printed(["European Red Mites"], "NSW, Vic, SA", 3),
    printed(["Grapevine Scale"], "NSW, Vic, Qld, SA, WA", 3),
  ]);

  assertEquals(rows.length, 2);
  assertNotEquals(rows[0].direction_id, rows[1].direction_id);
  assertNotEquals(rows[0].rates[0].rate_id, rows[1].rates[0].rate_id);
  // Same number — that is exactly why identity cannot be the number.
  assertEquals(rows[0].rates[0].value, rows[1].rates[0].value);
});

// ---------------------------------------------------------------------------
// F / G / H / I. The real VICOL projection
// ---------------------------------------------------------------------------

Deno.test("D1.2 F — real VICOL: 6 rows, 4 directions, 4 rates, 2 numbers", () => {
  const rows = projectVicol();

  assertEquals(rows.length, 6);
  assertEquals(new Set(rows.map((r) => r.direction_id)).size, 4);
  assertEquals(new Set(rows.map((r) => r.rates[0].rate_id)).size, 4);
  assertEquals([...new Set(rows.map((r) => r.rates[0].value))].sort(), [2, 3]);

  // Direction and rate identity agree exactly: four of each, one per printed
  // direction, never four-and-six.
  assertEquals(new Set(rows.map(pair)).size, 4);
});

Deno.test("D1.2 G — the three Tasmania mite rows share one identity pair", () => {
  const rows = projectVicol();
  const tasMites = rows.filter((r) =>
    r.rates[0].label === "Tas" && r.target !== "Grapevine Scale"
  );

  assertEquals(tasMites.length, 3);
  assertEquals(tasMites.map((r) => r.target), [
    "Grapeleaf Blister Mites",
    "European Red Mites",
    "Two Spotted Mites",
  ]);
  assertEquals(new Set(tasMites.map((r) => r.direction_id)).size, 1);
  assertEquals(new Set(tasMites.map((r) => r.rates[0].rate_id)).size, 1);

  // And that shared identity is NOT the Tasmania Grapevine Scale direction,
  // which states the same 2 L/100 L in the same state.
  const tasScale = rows.find((r) =>
    r.target === "Grapevine Scale" && r.rates[0].label === "Tas"
  )!;
  assertEquals(tasScale.rates[0].value, 2);
  assertNotEquals(tasScale.direction_id, tasMites[0].direction_id);
  assertNotEquals(tasScale.rates[0].rate_id, tasMites[0].rates[0].rate_id);
});

Deno.test("D1.2 H — the two 3 L/100 L directions stay separate", () => {
  const rows = projectVicol();
  const threes = rows.filter((r) => r.rates[0].value === 3);

  assertEquals(threes.length, 2);
  assertEquals(threes.map((r) => r.target), ["European Red Mites", "Grapevine Scale"]);
  assertEquals(threes.map((r) => r.rates[0].label), [
    "NSW, Vic, SA",
    "NSW, Vic, Qld, SA, WA",
  ]);
  assertNotEquals(threes[0].direction_id, threes[1].direction_id);
  assertNotEquals(threes[0].rates[0].rate_id, threes[1].rates[0].rate_id);

  // The future operational "3 L/100 L" option references BOTH rate ids — two,
  // not the three-plus rows a per-target identity would have produced.
  assertEquals(new Set(threes.map((r) => r.rates[0].rate_id)).size, 2);
});

Deno.test("D1.2 I — repeated extraction reproduces the same four of each", () => {
  const first = projectVicol();
  const second = projectVicol();

  assertEquals(
    second.map((r) => r.direction_id).sort(),
    first.map((r) => r.direction_id).sort(),
  );
  assertEquals(
    second.map((r) => r.rates[0].rate_id).sort(),
    first.map((r) => r.rates[0].rate_id).sort(),
  );
  assertEquals(new Set(second.map((r) => r.direction_id)).size, 4);
  assertEquals(new Set(second.map((r) => r.rates[0].rate_id)).size, 4);
});

// ---------------------------------------------------------------------------
// J. No shared mutable rate object
// ---------------------------------------------------------------------------

Deno.test("D1.2 J — projected rows never share a rate object", () => {
  const rows = projectVicol();

  // Every rate object is a distinct instance. While they were shared, an
  // in-place stamp on one row silently rewrote its siblings, so the identity a
  // row advertised depended on which row happened to be processed last.
  const instances = new Set(rows.map((r) => r.rates[0]));
  assertEquals(instances.size, rows.length);

  // Proof it is a real copy, not just a distinct wrapper: mutating one row's
  // rate leaves every sibling untouched.
  const tasMites = rows.filter((r) =>
    r.rates[0].label === "Tas" && r.target !== "Grapevine Scale"
  );
  const shared = tasMites[0].rates[0].rate_id;
  tasMites[0].rates[0].rate_id = "rate_v1_tampered";
  assertEquals(tasMites[1].rates[0].rate_id, shared);
  assertEquals(tasMites[2].rates[0].rate_id, shared);
});

Deno.test("D1.2 J — a carried direction_id is honoured, never re-derived", () => {
  // Re-stamping a projection must not recompute identity from the single
  // surviving target: by this point the direction's full target set is gone,
  // so recomputation is exactly the D1.1 defect.
  const rows = projectVicol();
  const before = rows.map(pair);

  assignRateIds(rows, VICOL);
  assertEquals(rows.map(pair), before);

  // Idempotent however many times it runs.
  assignRateIds(rows, VICOL);
  assertEquals(rows.map(pair), before);
});

// ===========================================================================
// Gate D1.3 — PRODUCT-BOUND IDENTITY CONSISTENCY.
//
// The defect: `direction_id` is product-bound, but the research path minted it
// BEFORE the register had confirmed which product the direction belonged to,
// passing a null product. The resulting hash was built from
// `country=- scheme=- number=-`, written into the real `direction_id` field,
// and then honoured verbatim once identity resolved — so one registered
// direction carried one identity via research and a different one via the
// manufacturer label, and `rate_id` inherited the split.
//
// The rule: a persistable identity is minted ONLY against a locked product.
// Until then the printed direction's grouping travels as an internal seed.
// ===========================================================================

const OTHER_PRODUCT: RateIdentityProduct = {
  country: "AU",
  scheme: "apvma",
  registration_number: "99999",
};

/** The single European Red Mites direction from §8. */
const ERM_DIRECTION = () => [printed(["European Red Mites"], "NSW, Vic, SA", 3)];

/** The VICOL Tasmania three-mite direction from §9. */
const TAS_MITE_DIRECTION = () => [
  printed(["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"], "Tas", 2),
];

/**
 * PATH A — manufacturer label with product identity ALREADY locked when the
 * projection runs, so identity is minted inline.
 */
const viaManufacturer = (
  dirs: ReturnType<typeof printed>[],
  product: RateIdentityProduct = VICOL,
): ProjectedRow[] =>
  manufacturerUsesToRegisteredUses(dirs as never, { product }) as unknown as ProjectedRow[];

/**
 * PATH B — discovery BEFORE identity resolution: the projection runs with no
 * locked product, so it mints nothing and carries a seed; the register locks
 * the product only afterwards.
 */
const viaDiscoveryThenLock = (
  dirs: ReturnType<typeof printed>[],
  product: RateIdentityProduct = VICOL,
): ProjectedRow[] => {
  const rows = manufacturerUsesToRegisteredUses(dirs as never, {}) as Record<string, unknown>[];
  // Pre-lock: no persistable identity exists yet.
  for (const row of rows) {
    assertEquals(row.direction_id, undefined);
    for (const r of row.rates as Record<string, unknown>[]) {
      assertEquals(r.rate_id, undefined);
    }
  }
  // The register speaks. THIS is the only place a persistable id is minted.
  assignRateIds(rows, product);
  return rows as unknown as ProjectedRow[];
};

Deno.test("D1.3 — a product is locked only with country, scheme AND number", () => {
  assert(isLockedProduct(VICOL));
  assert(!isLockedProduct(null));
  assert(!isLockedProduct({}));
  // A research lead with a guessed number but no confirmed scheme is NOT a
  // lock, and neither is a register outage that left the number unknown.
  assert(!isLockedProduct({ country: "AU", registration_number: "33182" }));
  assert(!isLockedProduct({ country: "AU", scheme: "apvma" }));
  assert(!isLockedProduct({ country: "", scheme: "apvma", registration_number: "33182" }));
});

// ---------------------------------------------------------------------------
// §8 — THE PRINCIPAL ACCEPTANCE TEST
// ---------------------------------------------------------------------------

Deno.test("D1.3 §8 — manufacturer and research paths agree on ONE identity", () => {
  const a = viaManufacturer(ERM_DIRECTION());
  const b = viaDiscoveryThenLock(ERM_DIRECTION());

  assertEquals(a.length, 1);
  assertEquals(b.length, 1);

  // The same registered direction of the same registered product — ONE
  // identity, whichever path discovered it. Before this gate these differed.
  assertEquals(b[0].direction_id, a[0].direction_id);
  assertEquals(b[0].rates[0].rate_id, a[0].rates[0].rate_id);

  // And it is genuinely product-bound, not an accidental match on the old
  // product-less hash.
  assert(a[0].direction_id.startsWith(`${DIRECTION_ID_VERSION}_`));
  assertNotEquals(
    a[0].direction_id,
    mintDirectionId(null, {
      crop: "Grapes",
      targets: ["European Red Mites"],
      condition: "NSW, Vic, SA",
    }),
  );
});

// ---------------------------------------------------------------------------
// §9 — multi-target cross-path
// ---------------------------------------------------------------------------

Deno.test("D1.3 §9 — the three-mite direction agrees across both paths", () => {
  const a = viaManufacturer(TAS_MITE_DIRECTION());
  const b = viaDiscoveryThenLock(TAS_MITE_DIRECTION());

  assertEquals(a.length, 3);
  assertEquals(b.length, 3);

  // One direction, one rate — on each path independently.
  assertEquals(new Set(a.map((r) => r.direction_id)).size, 1);
  assertEquals(new Set(b.map((r) => r.direction_id)).size, 1);
  assertEquals(new Set(a.map((r) => r.rates[0].rate_id)).size, 1);
  assertEquals(new Set(b.map((r) => r.rates[0].rate_id)).size, 1);

  // And the SAME pair across paths: the complete target set survived the
  // pre-resolution fan-out through the seed, so the late mint saw all three
  // pests rather than one.
  for (const row of b) {
    assertEquals(row.direction_id, a[0].direction_id);
    assertEquals(row.rates[0].rate_id, a[0].rates[0].rate_id);
  }
});

Deno.test("D1.3 §9 — a differently ordered discovery fan-out still agrees", () => {
  const a = viaManufacturer(TAS_MITE_DIRECTION());
  // Research may legitimately emit the pests in another order.
  const shuffled = viaDiscoveryThenLock([
    printed(["Two Spotted Mites", "European Red Mites", "Grapeleaf Blister Mites"], "Tas", 2),
  ]);

  assertEquals(new Set(shuffled.map((r) => r.direction_id)).size, 1);
  assertEquals(shuffled[0].direction_id, a[0].direction_id);
  assertEquals(shuffled[0].rates[0].rate_id, a[0].rates[0].rate_id);
});

// ---------------------------------------------------------------------------
// §10 — product separation
// ---------------------------------------------------------------------------

Deno.test("D1.3 §10 — the same direction under two registrations differs", () => {
  const onVicol = viaManufacturer(ERM_DIRECTION(), VICOL);
  const onOther = viaManufacturer(ERM_DIRECTION(), OTHER_PRODUCT);

  // Identical crop, targets, condition and rate — different products.
  assertNotEquals(onOther[0].direction_id, onVicol[0].direction_id);
  assertNotEquals(onOther[0].rates[0].rate_id, onVicol[0].rates[0].rate_id);

  // The separation holds through discovery too: a direction found before
  // resolution binds to whichever product actually locks.
  const lockedLate = viaDiscoveryThenLock(ERM_DIRECTION(), OTHER_PRODUCT);
  assertEquals(lockedLate[0].direction_id, onOther[0].direction_id);
  assertNotEquals(lockedLate[0].direction_id, onVicol[0].direction_id);
});

// ---------------------------------------------------------------------------
// §6 — never resolved
// ---------------------------------------------------------------------------

Deno.test("D1.3 §6 — an unresolved product mints no persistable identity", () => {
  const rows = manufacturerUsesToRegisteredUses(
    TAS_MITE_DIRECTION() as never,
    {},
  ) as Record<string, unknown>[];

  // No fabricated registration, therefore no ids. These rows are not eligible
  // to become operational defaults anyway.
  for (const row of rows) {
    assertEquals(row.direction_id, undefined);
    for (const r of row.rates as Record<string, unknown>[]) {
      assertEquals(r.rate_id, undefined);
    }
  }

  // Stamping with a still-unlocked product changes nothing — and clears the
  // internal seed so it cannot escape to a client.
  assignRateIds(rows, { country: "AU" });
  for (const row of rows) {
    assertEquals(row.direction_id, undefined);
    assertEquals(row[DIRECTION_SEED_KEY], undefined);
  }

  // The label facts are untouched throughout.
  assertEquals((rows[0].rates as Record<string, unknown>[])[0].value, 2);
  assertEquals(rows.length, 3);
});

Deno.test("D1.3 — the internal seed never reaches a served response", () => {
  const rows = manufacturerUsesToRegisteredUses(
    TAS_MITE_DIRECTION() as never,
    {},
  ) as Record<string, unknown>[];

  // It exists pre-lock, carrying the COMPLETE target set the fan-out discards.
  const seed = rows[0][DIRECTION_SEED_KEY] as { targets: string[] };
  assertEquals(seed.targets.length, 3);

  // Locking mints the ids and clears the seed in one pass.
  assignRateIds(rows, VICOL);
  for (const row of rows) {
    assertEquals(row[DIRECTION_SEED_KEY], undefined);
    assert(typeof row.direction_id === "string");
  }

  // And the structured-level sweep clears it on the never-resolved path.
  const unresolvedStructured = {
    registration: null,
    registered_uses: manufacturerUsesToRegisteredUses(TAS_MITE_DIRECTION() as never, {}),
    grapevine_uses: manufacturerUsesToRegisteredUses(TAS_MITE_DIRECTION() as never, {}),
    other_crop_uses: [],
  };
  stripStructuredDirectionSeeds(unresolvedStructured);
  for (const row of unresolvedStructured.registered_uses as Record<string, unknown>[]) {
    assertEquals(row[DIRECTION_SEED_KEY], undefined);
  }
  for (const row of unresolvedStructured.grapevine_uses as Record<string, unknown>[]) {
    assertEquals(row[DIRECTION_SEED_KEY], undefined);
  }
});

// ---------------------------------------------------------------------------
// §11 — cache / repeat
// ---------------------------------------------------------------------------

Deno.test("D1.3 §11 — live, repeated, cached and discovered rows all agree", () => {
  const live = viaManufacturer(ERM_DIRECTION());
  const repeated = viaManufacturer(ERM_DIRECTION());

  // A cached structured response is JSON that already carries its ids; a
  // re-stamp on read must not move them.
  const cached = JSON.parse(JSON.stringify(live)) as Record<string, unknown>[];
  assignRateIds(cached, VICOL);

  const pairOf = (r: ProjectedRow) => `${r.direction_id}::${r.rates[0].rate_id}`;
  assertEquals(repeated.map(pairOf), live.map(pairOf));
  assertEquals((cached as unknown as ProjectedRow[]).map(pairOf), live.map(pairOf));
  assertEquals(viaDiscoveryThenLock(ERM_DIRECTION()).map(pairOf), live.map(pairOf));
});

// ---------------------------------------------------------------------------
// §12 — the VICOL acceptance survives D1.3
// ---------------------------------------------------------------------------

Deno.test("D1.3 §12 — real VICOL still 6 rows / 4 directions / 4 rates / 2 values", () => {
  const rows = projectVicol();

  assertEquals(rows.length, 6);
  assertEquals(new Set(rows.map((r) => r.direction_id)).size, 4);
  assertEquals(new Set(rows.map((r) => r.rates[0].rate_id)).size, 4);
  assertEquals([...new Set(rows.map((r) => r.rates[0].value))].sort(), [2, 3]);

  // The Tas multi-mite direction: 3 rows, one pair.
  const tasMites = rows.filter((r) =>
    r.rates[0].label === "Tas" && r.target !== "Grapevine Scale"
  );
  assertEquals(tasMites.length, 3);
  assertEquals(new Set(tasMites.map(pair)).size, 1);

  // The other three directions each keep their own pair.
  const others = rows.filter((r) => !tasMites.includes(r));
  assertEquals(others.length, 3);
  assertEquals(new Set(others.map(pair)).size, 3);

  // And all four are reproduced by the discovery-then-lock path.
  const viaDiscovery = viaDiscoveryThenLock(
    extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS).uses
      .filter((u) => /^grapes$/i.test(u.crop)) as unknown as ReturnType<typeof printed>[],
  );
  assertEquals(viaDiscovery.map(pair).sort(), rows.map(pair).sort());
});

// ---------------------------------------------------------------------------
// K. Historical rows
// ---------------------------------------------------------------------------

Deno.test("D1.2 K — historical rows with neither id still decode", () => {
  const historical = [{
    crop: "Grapevines",
    target_raw: "Grapevine scale",
    rates: [{ label: "NSW", basis: "per_100_litres", value: 3, unit: "L" }],
    withholding_period_days: null,
  }] as Record<string, unknown>[];

  const rateRow = (historical[0].rates as Record<string, unknown>[])[0];
  assertEquals(historical[0].direction_id, undefined);
  assertEquals(rateRow.rate_id, undefined);

  // A single-target row is its own printed direction — the correct reading for
  // a source that publishes one pest per direction, not a fallback.
  assignRateIds(historical, VICOL);
  assert(typeof historical[0].direction_id === "string");
  assert(typeof rateRow.rate_id === "string");

  // Deterministic, and equal to minting the same row directly.
  assertEquals(
    rateRow.rate_id,
    mintRateId(VICOL, { crop: "Grapevines", target_raw: "Grapevine scale" }, {
      label: "NSW",
      basis: "per_100_litres",
      value: 3,
      unit: "L",
    }),
  );

  // No backfill: nothing here rewrote the label facts.
  assertEquals(rateRow.value, 3);
  assertEquals(rateRow.unit, "L");
  assertEquals(historical[0].withholding_period_days, null);
});
