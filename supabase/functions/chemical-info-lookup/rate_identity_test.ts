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
import { extractManufacturerLabelUses } from "./ingestion/manufacturer_label.ts";
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
    { crop: "Grapevines", target_raw: "Grapevine scale" },
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

Deno.test("retrieval circumstances are excluded from the canonical input", () => {
  const canonical = canonicalRateIdentityInput(
    VICOL,
    { crop: "Grapevines", target_raw: "Grapevine scale" },
    rate({ label: "NSW" }),
  );
  for (const excluded of ["fetched_at", "retrieved_at", "request", "cache", "index", "url"]) {
    assert(!canonical.includes(excluded), `canonical input must not mention ${excluded}`);
  }
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
        { crop: u.crop, target_raw: u.targets.join(", ") },
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
