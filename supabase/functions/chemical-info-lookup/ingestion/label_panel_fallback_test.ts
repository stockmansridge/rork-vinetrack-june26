// Gate D4A.3 — regression tests for the authoritative label layout fallback.
//
// Every grapevine assertion below runs against REAL measured positioned text
// from the authoritative APVMA eLabel for 33182
// (sha256 b55905a2612b0c938b44a656c6fa419715eb80468aabc842e667a4fa62c17111),
// including its verbatim "1OO" glyphs. Nothing here is cleaned-up test text:
// the defect these tests pin only exists in the document's own measurements.

import {
  assert,
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

import { VICOL_33182_APVMA_LABEL_ITEMS } from "./seeds/label_fixture_33182_apvma.ts";
import { DITHANE_59688_ITEMS } from "./label_fixture_59688.ts";
import {
  detectStateAwareDfu,
  extractManufacturerLabelUses,
  normaliseDigitGlyphs,
} from "./manufacturer_label.ts";
import { parseDirectionsForUse } from "./label_extract.ts";
import {
  applyPanelLayoutFallback,
  carryForwardStatedPeriods,
  statesCalculableGrapevineRate,
} from "./label_panel_fallback.ts";
import { buildDefaultRateOptions } from "../default_rate_options.ts";
import type { PdfTextItem } from "./contract.ts";

const PRODUCT = {
  country: "AU",
  scheme: "apvma",
  registration_number: "33182",
} as const;

/** The fallback result actually served for the measured VICOL document. */
function vicolFallback() {
  return applyPanelLayoutFallback({
    items: VICOL_33182_APVMA_LABEL_ITEMS,
    regulatorUses: [],
    product: PRODUCT,
  });
}

function grapevineRows(rows: readonly Record<string, unknown>[]) {
  return rows.filter((r) => /grape/i.test(String(r.crop ?? "")));
}

// ---------------------------------------------------------------------------
// A. Digit-glyph repair is bounded to numeric runs
// ---------------------------------------------------------------------------

Deno.test("D4A.3 A — 1OO normalises only inside runs that start with a digit", () => {
  assertEquals(normaliseDigitGlyphs("2 L / 1OO L"), "2 L / 100 L");
  assertEquals(normaliseDigitGlyphs("1OO"), "100");

  // Words that merely CONTAIN O must survive untouched. These are all printed
  // on the very label under test, so a global O→0 replacement would corrupt
  // the document it was meant to repair.
  assertEquals(normaliseDigitGlyphs("Oystershell Scale"), "Oystershell Scale");
  assertEquals(normaliseDigitGlyphs("San Jose Scale"), "San Jose Scale");
  assertEquals(normaliseDigitGlyphs("SA"), "SA");
  assertEquals(normaliseDigitGlyphs("NSW, Vic, Qld, SA, WA"), "NSW, Vic, Qld, SA, WA");
  assertEquals(normaliseDigitGlyphs("CO2"), "CO2");
  assertEquals(normaliseDigitGlyphs("Tas"), "Tas");
  assertEquals(normaliseDigitGlyphs("Do not spray after bud swell"), "Do not spray after bud swell");
});

Deno.test("D4A.3 A — no O is folded in a run that starts with a letter", () => {
  for (const word of ["OO", "O1", "LOO", "IOO", "Oil", "VICOL"]) {
    assertEquals(normaliseDigitGlyphs(word), word);
  }
});

// ---------------------------------------------------------------------------
// B / C. The four printed grapevine directions and their exact states
// ---------------------------------------------------------------------------

Deno.test("D4A.3 B/C — the live VICOL document yields 4 grapevine directions with exact states", () => {
  const parse = extractManufacturerLabelUses(VICOL_33182_APVMA_LABEL_ITEMS);
  assert(parse.found, "a Directions-for-Use table must be located");

  const grapes = parse.uses.filter((u) => /grape/i.test(u.crop));
  assertEquals(grapes.length, 4, "exactly the four printed grapevine directions");

  // A — Tasmania, three mites, 2 L/100 L
  assertEquals(grapes[0].condition, "Tas");
  assertEquals(grapes[0].targets, [
    "Grapeleaf Blister Mites",
    "European Red Mites",
    "Two Spotted Mites",
  ]);
  assertEquals(grapes[0].rates.length, 1);
  assertEquals(grapes[0].rates[0].basis, "per_100_litres");
  assertEquals(grapes[0].rates[0].value, 2);
  assertEquals(grapes[0].rates[0].unit, "L");

  // B — European Red Mites, NSW/Vic/SA, 3 L/100 L
  assertEquals(grapes[1].condition, "NSW, Vic, SA");
  assertEquals(grapes[1].targets, ["European Red Mites"]);
  assertEquals(grapes[1].rates[0].value, 3);

  // C — Grapevine Scale, five mainland states, 3 L/100 L. The state cell wraps
  // across two printed lines ("NSW, Vic," then "Qld, SA,WA") and must rejoin
  // as ONE condition, not two half-conditions.
  assertEquals(grapes[2].condition, "NSW, Vic, Qld, SA, WA");
  assertEquals(grapes[2].targets, ["Grapevine Scale"]);
  assertEquals(grapes[2].rates[0].value, 3);

  // D — Grapevine Scale, Tasmania, 2 L/100 L. The label prints the pest only
  // once, so this direction INHERITS it rather than losing it.
  assertEquals(grapes[3].condition, "Tas");
  assertEquals(grapes[3].targets, ["Grapevine Scale"]);
  assertEquals(grapes[3].rates[0].value, 2);
});

Deno.test("D4A.3 C — no inferred fifth direction and no state is lost", () => {
  const parse = extractManufacturerLabelUses(VICOL_33182_APVMA_LABEL_ITEMS);
  const grapes = parse.uses.filter((u) => /grape/i.test(u.crop));
  assertEquals(grapes.length, 4);
  for (const use of grapes) {
    assert(use.condition && use.condition.length > 0, "every direction keeps a state condition");
    assertEquals(use.rates.length, 1, "one printed amount per direction — never a merged range");
  }
  assertEquals(
    grapes.map((g) => g.condition),
    ["Tas", "NSW, Vic, SA", "NSW, Vic, Qld, SA, WA", "Tas"],
  );
});

// ---------------------------------------------------------------------------
// D / E. Projection and D1 identity
// ---------------------------------------------------------------------------

Deno.test("D4A.3 D/E — 6 projected grapevine rows, 4 direction_ids, 4 rate_ids", () => {
  const fallback = vicolFallback();
  assertEquals(fallback.outcome, "applied");

  const rows = grapevineRows(fallback.uses);
  assertEquals(rows.length, 6, "three targets of direction A fan out; the rest are one each");

  const directionIds = new Set(rows.map((r) => String(r.direction_id)));
  const rateIds = new Set(
    rows.flatMap((r) =>
      (Array.isArray(r.rates) ? r.rates : []).map((x: { rate_id?: string }) => String(x.rate_id))
    ),
  );
  assertEquals(directionIds.size, 4);
  assertEquals(rateIds.size, 4);
  for (const id of directionIds) assert(id.startsWith("direction_v1_"));
  for (const id of rateIds) assert(id.startsWith("rate_v1_"));
});

Deno.test("D4A.3 E — direction A's three targets share ONE direction_id and ONE rate_id", () => {
  const rows = grapevineRows(vicolFallback().uses);
  const tas = rows.filter((r) =>
    (Array.isArray(r.rates) ? r.rates : []).some((x: { label?: string }) => x.label === "Tas")
  );
  const multiMite = tas.filter((r) =>
    ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"].includes(
      String(r.target),
    ) && !/Scale/i.test(String(r.target))
  );
  assertEquals(multiMite.length, 3, "the three mites of the Tasmania direction");
  assertEquals(new Set(multiMite.map((r) => String(r.direction_id))).size, 1);
  assertEquals(
    new Set(
      multiMite.flatMap((r) =>
        (Array.isArray(r.rates) ? r.rates : []).map((x: { rate_id?: string }) => String(x.rate_id))
      ),
    ).size,
    1,
  );
});

// ---------------------------------------------------------------------------
// F / G / H. D4A option acceptance
// ---------------------------------------------------------------------------

Deno.test("D4A.3 F/G — exactly two per-100-L options with two rate_ids each, no per-hectare", () => {
  const { options, violations } = buildDefaultRateOptions(vicolFallback().uses);
  assertEquals(violations, [], "no identity violation may be reported");
  assertEquals(options.per_hectare, [], "the label states no per-hectare grapevine rate");
  assertEquals(options.per_100_litres.length, 2);

  const byValue = (v: number) => options.per_100_litres.find((o) => o.value === v);

  const two = byValue(2);
  assert(two, "the 2 L/100 L option must exist");
  assertEquals(two.unit, "L");
  assertEquals(two.rate_ids.length, 2, "Tasmania multi-mite + Tasmania Grapevine Scale");
  assertEquals(two.direction_ids.length, 2);
  assertEquals(two.conditions, ["Tas"]);

  const three = byValue(3);
  assert(three, "the 3 L/100 L option must exist");
  assertEquals(three.unit, "L");
  assertEquals(three.rate_ids.length, 2, "European Red Mites + Grapevine Scale, mainland");
  assertEquals(three.direction_ids.length, 2);
  assertEquals(
    three.conditions.slice().sort(),
    ["NSW, Vic, Qld, SA, WA", "NSW, Vic, SA"],
  );

  const all = new Set([...two.rate_ids, ...three.rate_ids]);
  assertEquals(all.size, 4, "four unique supporting rate_ids across both options");
});

Deno.test("D4A.3 F — no six-row option explosion", () => {
  const { options } = buildDefaultRateOptions(vicolFallback().uses);
  assertEquals(
    options.per_100_litres.length,
    2,
    "six projected rows must group into two operational amounts",
  );
});

Deno.test("D4A.3 H — other crops stay in registered_uses but never enter options", () => {
  const fallback = vicolFallback();
  const crops = new Set(fallback.uses.map((u) => String(u.crop)));
  // The same label registers pome fruit, stone fruit and almonds. They must
  // survive the re-read — the fallback reads the whole table, not just grapes.
  assert(crops.has("Pome Fruit"), "pome fruit rows are preserved");
  assert(crops.has("Stone Fruit"), "stone fruit rows are preserved");
  assert(crops.has("Almonds"), "almond rows are preserved");

  const { options } = buildDefaultRateOptions(fallback.uses);
  const optionRateIds = new Set(options.per_100_litres.flatMap((o) => o.rate_ids));
  const otherCropRateIds = fallback.uses
    .filter((u) => !/grape/i.test(String(u.crop)))
    .flatMap((u) =>
      (Array.isArray(u.rates) ? u.rates : []).map((r: { rate_id?: string }) => String(r.rate_id))
    );
  for (const id of otherCropRateIds) {
    assertFalse(optionRateIds.has(id), `other-crop rate ${id} must never support an option`);
  }
  for (const option of options.per_100_litres) {
    for (const crop of option.crops) assert(/grape/i.test(crop), `option cites only grapes: ${crop}`);
  }
});

// ---------------------------------------------------------------------------
// I. The ordinary eLabel path is untouched
// ---------------------------------------------------------------------------

Deno.test("D4A.3 I — an ordinary single-column eLabel does not route to the fallback", () => {
  // Dithane 59688 is the measured ordinary eLabel. It prints no State column,
  // so the state-aware parser must never claim it.
  assertFalse(detectStateAwareDfu(DITHANE_59688_ITEMS).present);
});

Deno.test("D4A.3 I — the ordinary parser's reading of 59688 is byte-identical", () => {
  const before = JSON.stringify(parseDirectionsForUse(DITHANE_59688_ITEMS));
  const fallback = applyPanelLayoutFallback({
    items: DITHANE_59688_ITEMS,
    regulatorUses: [],
    product: { country: "AU", scheme: "apvma", registration_number: "59688" },
  });
  assertEquals(fallback.outcome, "geometry_absent");
  assertEquals(fallback.uses, []);
  // Running the fallback must not mutate the items it was handed.
  assertEquals(JSON.stringify(parseDirectionsForUse(DITHANE_59688_ITEMS)), before);
});

Deno.test("D4A.3 I — a working grapevine parse is never displaced", () => {
  const working = [{
    crop: "Grapevines",
    target: "Powdery Mildew",
    rates: [{ basis: "per_100_litres", value: 25, unit: "mL", label: "", raw_text: "25 mL/100 L" }],
  }];
  const fallback = applyPanelLayoutFallback({
    items: VICOL_33182_APVMA_LABEL_ITEMS,
    regulatorUses: working,
    product: PRODUCT,
  });
  assertEquals(fallback.outcome, "not_needed");
  assertEquals(fallback.uses, []);
});

// ---------------------------------------------------------------------------
// J. A malformed / ambiguous panel does not activate the fallback
// ---------------------------------------------------------------------------

Deno.test("D4A.3 J — a rate/state panel with no DIRECTIONS FOR USE heading is refused", () => {
  const items: PdfTextItem[] = [
    { page: 1, x: 10, y: 200, width: 40, str: "Crop" },
    { page: 1, x: 60, y: 200, width: 40, str: "Pest" },
    { page: 1, x: 110, y: 200, width: 40, str: "State" },
    { page: 1, x: 160, y: 200, width: 40, str: "Rate" },
    { page: 1, x: 10, y: 190, width: 40, str: "Grapes" },
    { page: 1, x: 110, y: 190, width: 40, str: "Tas" },
    { page: 1, x: 160, y: 190, width: 60, str: "2 L / 1OO L" },
  ];
  assertFalse(detectStateAwareDfu(items).present, "a marketing panel is not a DFU table");
  const fallback = applyPanelLayoutFallback({ items, regulatorUses: [], product: PRODUCT });
  assertEquals(fallback.outcome, "geometry_absent");
  assertEquals(fallback.uses, []);
});

Deno.test("D4A.3 J — a DFU table with no state column is refused", () => {
  const items: PdfTextItem[] = [
    { page: 1, x: 10, y: 220, width: 120, str: "DIRECTIONS FOR USE" },
    { page: 1, x: 10, y: 200, width: 40, str: "Crop" },
    { page: 1, x: 60, y: 200, width: 40, str: "Pest" },
    { page: 1, x: 160, y: 200, width: 40, str: "Rate" },
    { page: 1, x: 220, y: 200, width: 80, str: "Critical Comments" },
    { page: 1, x: 10, y: 190, width: 40, str: "Grapes" },
    { page: 1, x: 160, y: 190, width: 60, str: "2 L / 1OO L" },
  ];
  assertFalse(detectStateAwareDfu(items).present);
  assertEquals(
    applyPanelLayoutFallback({ items, regulatorUses: [], product: PRODUCT }).outcome,
    "geometry_absent",
  );
});

Deno.test("D4A.3 J — geometry that matches but states no calculable rate stays unresolved", () => {
  const items: PdfTextItem[] = [
    { page: 1, x: 10, y: 220, width: 120, str: "DIRECTIONS FOR USE" },
    { page: 1, x: 10, y: 200, width: 40, str: "Crop" },
    { page: 1, x: 60, y: 200, width: 40, str: "Pest" },
    { page: 1, x: 110, y: 200, width: 40, str: "State" },
    { page: 1, x: 160, y: 200, width: 40, str: "Rate" },
    { page: 1, x: 10, y: 190, width: 40, str: "Grapes" },
    { page: 1, x: 60, y: 190, width: 40, str: "Scale" },
    { page: 1, x: 110, y: 190, width: 40, str: "Tas" },
    { page: 1, x: 160, y: 190, width: 90, str: "As directed by adviser" },
  ];
  assert(detectStateAwareDfu(items).present, "the geometry itself does match");
  const fallback = applyPanelLayoutFallback({ items, regulatorUses: [], product: PRODUCT });
  assertEquals(fallback.outcome, "parse_unusable");
  assertEquals(fallback.uses, [], "an honest unresolved result beats a guessed parse");
});

Deno.test("D4A.3 J — no items means no fallback", () => {
  assertEquals(
    applyPanelLayoutFallback({ items: null, regulatorUses: [], product: PRODUCT }).outcome,
    "geometry_absent",
  );
  assertEquals(
    applyPanelLayoutFallback({ items: [], regulatorUses: [], product: PRODUCT }).outcome,
    "geometry_absent",
  );
});

// ---------------------------------------------------------------------------
// K. The unrepaired "1OO" measurement remains available
// ---------------------------------------------------------------------------

Deno.test("D4A.3 K — the 1OO text-layer cell survives beside the repaired raw_text", () => {
  const rows = grapevineRows(vicolFallback().uses);
  for (const row of rows) {
    const rates = Array.isArray(row.rates) ? row.rates : [];
    for (const rate of rates as { raw_text: string; text_layer_text?: string }[]) {
      assert(/\/ 100 L/.test(rate.raw_text), `raw_text is the repaired cell: ${rate.raw_text}`);
      assertEquals(
        rate.text_layer_text,
        rate.raw_text.replace("100", "1OO"),
        "the PDF text layer's own unrepaired extraction stays auditable",
      );
      assert(
        rate.text_layer_text!.includes("1OO"),
        "the literal letter-O extraction is preserved",
      );
    }
  }
});

Deno.test("D4A.3 K — text_layer_text is absent when nothing needed repair", () => {
  const items: PdfTextItem[] = [
    { page: 1, x: 10, y: 220, width: 120, str: "DIRECTIONS FOR USE" },
    { page: 1, x: 10, y: 200, width: 40, str: "Crop" },
    { page: 1, x: 60, y: 200, width: 40, str: "Pest" },
    { page: 1, x: 110, y: 200, width: 40, str: "State" },
    { page: 1, x: 160, y: 200, width: 40, str: "Rate" },
    { page: 1, x: 10, y: 190, width: 40, str: "Grapes" },
    { page: 1, x: 60, y: 190, width: 40, str: "Scale" },
    { page: 1, x: 110, y: 190, width: 40, str: "Tas" },
    { page: 1, x: 160, y: 190, width: 60, str: "2 L / 100 L" },
  ];
  const parse = extractManufacturerLabelUses(items);
  assertEquals(parse.uses[0].rates[0].raw_text, "2 L / 100 L");
  assertFalse(
    "text_layer_text" in (parse.uses[0].rates[0] as unknown as Record<string, unknown>),
    "a cell that needed no repair gains no new field",
  );
});

// ---------------------------------------------------------------------------
// 13. Live-shape regression — the exact production defect must never return
// ---------------------------------------------------------------------------

Deno.test("D4A.3 §13 — the collapsed four-rate pseudo-direction can never return", () => {
  const FORBIDDEN = "2 L / 1OO L 3 L / 1OO L 3 L / 1OO L 2 L / 1OO L";

  // The ordinary parser really does produce it on this document: that is the
  // production defect, reproduced here rather than described.
  const ordinary = parseDirectionsForUse(VICOL_33182_APVMA_LABEL_ITEMS);
  const collapsed = (ordinary.rows as { crop_text?: string; rate_text?: string }[]).some(
    (r) => /grape/i.test(String(r.crop_text ?? "")) && r.rate_text === FORBIDDEN,
  );
  assert(collapsed, "the fixture must still reproduce the live defect");

  // What is SERVED must not.
  const served = grapevineRows(vicolFallback().uses);
  assert(served.length > 0);
  for (const row of served) {
    const rates = Array.isArray(row.rates) ? row.rates : [];
    assert(rates.length > 0, "a grapevine row must state a rate");
    for (const rate of rates as { basis: string; raw_text: string; unit: string }[]) {
      assertFalse(
        rate.basis === "other",
        `no grapevine rate may remain verbatim-only: ${rate.raw_text}`,
      );
      assertEquals(rate.basis, "per_100_litres");
      assertEquals(rate.unit, "L");
      assertFalse(rate.raw_text === FORBIDDEN, "the collapsed cell must never be served");
      assertFalse(
        /1OO/.test(rate.raw_text),
        "no served rate keeps an unrepaired glyph in its calculable reading",
      );
    }
  }
});

Deno.test("D4A.3 §13 — label_rate_bases can no longer be ['other'] for this document", () => {
  const bases = new Set(
    vicolFallback().uses.flatMap((u) =>
      (Array.isArray(u.rates) ? u.rates : []).map((r: { basis?: string }) => r.basis)
    ),
  );
  assertFalse(bases.has("other"), "no rate on this label is unreadable any more");
  assert(bases.has("per_100_litres"));
});

// ---------------------------------------------------------------------------
// Eligibility helper + period carry-forward
// ---------------------------------------------------------------------------

Deno.test("D4A.3 — statesCalculableGrapevineRate ignores verbatim-only and non-grape rows", () => {
  assertFalse(statesCalculableGrapevineRate([]));
  assertFalse(
    statesCalculableGrapevineRate([
      { crop: "Grapevines", rates: [{ basis: "other", unit: "", raw_text: "2 L / 1OO L" }] },
    ]),
    "a verbatim-only grapevine rate is not calculable",
  );
  assertFalse(
    statesCalculableGrapevineRate([
      { crop: "Pome Fruit", rates: [{ basis: "per_100_litres", value: 2, unit: "L" }] },
    ]),
    "another crop's working rate says nothing about grapes",
  );
  assert(
    statesCalculableGrapevineRate([
      { crop: "Grapes", rates: [{ basis: "per_100_litres", value: 2, unit: "L" }] },
    ]),
  );
});

Deno.test("D4A.3 — a rate repair never costs a withholding period the lookup already had", () => {
  const original = [
    { crop: "Grapes", target: "Grapevine Scale", withholding_period_days: 1, re_entry_period_hours: 12 },
  ];
  const rows = [
    { crop: "Grapes", target: "Grapevine Scale", withholding_period_days: null, re_entry_period_hours: null },
    { crop: "Almonds", target: "Bryobia Mites", withholding_period_days: null, re_entry_period_hours: null },
  ];
  const carried = carryForwardStatedPeriods(rows, original);
  assertEquals(carried[0].withholding_period_days, 1);
  assertEquals(carried[0].re_entry_period_hours, 12);
  // A crop the register never spoke about gains nothing.
  assertEquals(carried[1].withholding_period_days, null);
  assertEquals(carried[1].re_entry_period_hours, null);
});

Deno.test("D4A.3 — carry-forward never overwrites a period the re-read states", () => {
  const carried = carryForwardStatedPeriods(
    [{ crop: "Grapes", withholding_period_days: 3 }],
    [{ crop: "Grapes", withholding_period_days: 1 }],
  );
  assertEquals(carried[0].withholding_period_days, 3);
});

Deno.test("D4A.3 — duplicate AGREEING values carry, and order cannot matter", () => {
  const original = [
    { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
    { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
    { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
  ];
  const rows = [{ crop: "Grapes", withholding_period_days: null, re_entry_period_hours: null }];

  const carried = carryForwardStatedPeriods(rows, original);
  assertEquals(carried[0].withholding_period_days, 1);
  assertEquals(carried[0].re_entry_period_hours, 12);

  // Reversing the originals must not change the answer — the rule is
  // unanimity, never "whichever row came first".
  const reversed = carryForwardStatedPeriods(rows, [...original].reverse());
  assertEquals(reversed[0].withholding_period_days, 1);
  assertEquals(reversed[0].re_entry_period_hours, 12);
});

Deno.test("D4A.3 — one null plus one stated value carries the stated value", () => {
  // "Not stated here" does not contradict "stated there", so a null must never
  // count as a competing value.
  const rows = [{ crop: "Grapes", withholding_period_days: null, re_entry_period_hours: null }];

  const nullFirst = carryForwardStatedPeriods(rows, [
    { crop: "Grapes", withholding_period_days: null, re_entry_period_hours: null },
    { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
  ]);
  assertEquals(nullFirst[0].withholding_period_days, 1);
  assertEquals(nullFirst[0].re_entry_period_hours, 12);

  // Same answer when the stated row comes first, and when the sibling omits
  // the field entirely rather than setting it null.
  const statedFirst = carryForwardStatedPeriods(rows, [
    { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
    { crop: "Grapes" },
  ]);
  assertEquals(statedFirst[0].withholding_period_days, 1);
  assertEquals(statedFirst[0].re_entry_period_hours, 12);
});

Deno.test("D4A.3 — CONFLICTING values are never chosen between", () => {
  const carried = carryForwardStatedPeriods(
    [{ crop: "Grapes", withholding_period_days: null, re_entry_period_hours: null }],
    [
      { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
      { crop: "Grapes", withholding_period_days: 7, re_entry_period_hours: 24 },
    ],
  );
  assertEquals(
    carried[0].withholding_period_days,
    null,
    "a contested period stays a visible gap rather than a fabricated number",
  );
  assertEquals(carried[0].re_entry_period_hours, null);
});

Deno.test("D4A.3 — WHP and re-entry are resolved INDEPENDENTLY", () => {
  // Withholding periods disagree while re-entry periods agree. One contested
  // fact must not suppress an uncontested, unrelated one.
  const whpContested = carryForwardStatedPeriods(
    [{ crop: "Grapes", withholding_period_days: null, re_entry_period_hours: null }],
    [
      { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
      { crop: "Grapes", withholding_period_days: 7, re_entry_period_hours: 12 },
    ],
  );
  assertEquals(whpContested[0].withholding_period_days, null);
  assertEquals(whpContested[0].re_entry_period_hours, 12);

  // The mirror image.
  const reiContested = carryForwardStatedPeriods(
    [{ crop: "Grapes", withholding_period_days: null, re_entry_period_hours: null }],
    [
      { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 12 },
      { crop: "Grapes", withholding_period_days: 1, re_entry_period_hours: 24 },
    ],
  );
  assertEquals(reiContested[0].withholding_period_days, 1);
  assertEquals(reiContested[0].re_entry_period_hours, null);
});

Deno.test("D4A.3 — another crop's disagreement cannot suppress this crop's period", () => {
  const carried = carryForwardStatedPeriods(
    [{ crop: "Grapes", withholding_period_days: null }],
    [
      { crop: "Grapes", withholding_period_days: 1 },
      { crop: "Almonds", withholding_period_days: 7 },
      { crop: "Almonds", withholding_period_days: 14 },
    ],
  );
  assertEquals(carried[0].withholding_period_days, 1);
});

Deno.test("D4A.3 — carry-forward mutates neither input", () => {
  const rows = [{ crop: "Grapes", withholding_period_days: null }];
  const original = [{ crop: "Grapes", withholding_period_days: 1 }];
  const before = JSON.stringify({ rows, original });
  const carried = carryForwardStatedPeriods(rows, original);
  assertEquals(carried[0].withholding_period_days, 1);
  assertEquals(rows[0].withholding_period_days, null, "the input row is untouched");
  assertEquals(JSON.stringify({ rows, original }), before);
});

Deno.test("D4A.3 — a non-finite period is neither carried nor counted as a rival", () => {
  const carried = carryForwardStatedPeriods(
    [{ crop: "Grapes", withholding_period_days: null }],
    [
      { crop: "Grapes", withholding_period_days: Number.NaN },
      { crop: "Grapes", withholding_period_days: 1 },
    ],
  );
  assertEquals(carried[0].withholding_period_days, 1, "NaN neither carries nor contests");
});
