// Manufacturer-label-first grapevine projection.
//
// The acceptance product is VICOL WINTER OIL INSECTICIDE — APVMA 33182: a
// petroleum spray oil whose grapevine entry states two conditional /100 L
// rates by state, with dormancy restrictions and NO hectare rate. Every rule
// this task sets is observable on that one label.

import { assert, assertEquals } from "jsr:@std/assert@1";
import type { WireLabelRate } from "./ingestion/contract.ts";
import {
  deriveLabelReferenceRateRanges,
  GRAPEVINE_CROP_CLASS,
  isGrapevineCrop,
  orderRatesPer100LFirst,
  partitionGrapevineUses,
  projectGrapevineUses,
  selectLabelReferences,
} from "./grapevine_label.ts";

// ---------------------------------------------------------------------------
// §3 — grapevine crop normalisation
// ---------------------------------------------------------------------------

Deno.test("every grapevine wording a label uses normalises to one class", () => {
  for (
    const wording of [
      "GRAPE",
      "GRAPES",
      "GRAPEVINE",
      "GRAPEVINES",
      "Grapevine",
      "grapes",
      "Wine grapes",
      "TABLE GRAPES",
      "DRIED GRAPES",
      "Grape vines",
      "Vines",
      "Vineyards",
    ]
  ) {
    assert(isGrapevineCrop(wording), `${wording} should be grapevine`);
  }
  assertEquals(GRAPEVINE_CROP_CLASS, "Grapevines");
});

Deno.test("GRAPEFRUIT is a citrus and must never match", () => {
  // A substring test would match it. A citrus rate on a vineyard spray record
  // is a wrong dose wearing a plausible name.
  assertEquals(isGrapevineCrop("GRAPEFRUIT"), false);
  assertEquals(isGrapevineCrop("Grapefruit trees"), false);
});

Deno.test("unrelated crops do not match", () => {
  for (const crop of ["ALMONDS", "POME FRUIT", "STONE FRUIT", "CITRUS", "", "   "]) {
    assertEquals(isGrapevineCrop(crop), false, crop);
  }
});

// ---------------------------------------------------------------------------
// §4 / §5 — rates: values, ranges, ordering, no conversion
// ---------------------------------------------------------------------------

const rate = (r: Partial<WireLabelRate>): WireLabelRate => ({
  label: "",
  basis: "per_100_litres",
  unit: "L",
  raw_text: "",
  ...r,
} as WireLabelRate);

Deno.test("/100 L rates are shown before /ha, and NOTHING is dropped", () => {
  const ordered = orderRatesPer100LFirst([
    rate({ basis: "per_hectare", value: 3, unit: "L" }),
    rate({ basis: "range_per_100_litres", min_value: 100, max_value: 200, unit: "mL" }),
    rate({ basis: "other", unit: "", raw_text: "See directions" }),
    rate({ basis: "per_100_litres", value: 2, unit: "L" }),
  ]);
  assertEquals(ordered.map((r) => r.basis), [
    "range_per_100_litres",
    "per_100_litres",
    "per_hectare",
    "other",
  ]);
  assertEquals(ordered.length, 4);
});

Deno.test("ordering is stable — the label's printed order survives", () => {
  const ordered = orderRatesPer100LFirst([
    rate({ value: 3, label: "NSW/Vic/SA" }),
    rate({ value: 2, label: "Tasmania" }),
  ]);
  assertEquals(ordered.map((r) => r.label), ["NSW/Vic/SA", "Tasmania"]);
});

Deno.test("a range stays a range — never collapsed to one number or raw text", () => {
  const [only] = orderRatesPer100LFirst([
    rate({
      basis: "range_per_100_litres",
      min_value: 100,
      max_value: 200,
      unit: "mL",
      raw_text: "100–200 mL/100 L",
    }),
  ]);
  assertEquals(only.min_value, 100);
  assertEquals(only.max_value, 200);
  assertEquals(only.value, undefined);
  assertEquals(only.unit, "mL");
  assertEquals(only.raw_text, "100–200 mL/100 L");
});

Deno.test("every required rate shape round-trips intact", () => {
  // The five shapes named in the task, asserted field by field.
  const rates: WireLabelRate[] = [
    rate({ basis: "per_100_litres", value: 200, unit: "mL", raw_text: "200 mL/100 L" }),
    rate({ basis: "range_per_100_litres", min_value: 100, max_value: 200, unit: "mL", raw_text: "100–200 mL/100 L" }),
    rate({ basis: "range_per_100_litres", min_value: 2, max_value: 3, unit: "L", raw_text: "2–3 L/100 L" }),
    rate({ basis: "range_per_hectare", min_value: 1.5, max_value: 2, unit: "L", raw_text: "1.5–2 L/ha" }),
    rate({ basis: "per_hectare", value: 3, unit: "L", raw_text: "3 L/ha" }),
  ];
  const out = orderRatesPer100LFirst(rates);
  assertEquals(out.length, 5);
  for (const r of out) {
    assert(r.unit.length > 0);
    assert(r.raw_text.length > 0);
    if (r.basis.startsWith("range_")) {
      assert(typeof r.min_value === "number" && typeof r.max_value === "number");
    } else {
      assert(typeof r.value === "number");
    }
  }
});

Deno.test("two conditional state rates stay two rates, not one range", () => {
  // The label states 3 L/100 L for NSW/Vic/SA and 2 L/100 L for Tasmania.
  // Flattening those into "2–3 L/100 L" would invent a range the label never
  // printed, and would lose which state each applies in.
  const { grapevine } = partitionGrapevineUses([{
    crop: "GRAPEVINES",
    target_raw: "European red mite",
    rates: [
      rate({ value: 3, unit: "L", label: "NSW/Vic/SA", raw_text: "3 L/100 L" }),
      rate({ value: 2, unit: "L", label: "Tasmania", raw_text: "2 L/100 L" }),
    ],
  }]);
  const rates = grapevine[0].rates!;
  assertEquals(rates.length, 2);
  assertEquals(rates.map((r: WireLabelRate) => r.value), [3, 2]);
  assertEquals(rates.map((r: WireLabelRate) => r.label), ["NSW/Vic/SA", "Tasmania"]);
  assert(rates.every((r: WireLabelRate) => r.min_value === undefined));
});

// ---------------------------------------------------------------------------
// §3 — grapevine first, other crops retained
// ---------------------------------------------------------------------------

Deno.test("grapevine uses lead and other crops are retained, not discarded", () => {
  const projection = projectGrapevineUses([
    { crop: "ALMONDS", target_raw: "Scale", rates: [rate({ value: 1, unit: "L" })] },
    { crop: "GRAPEVINES", target_raw: "Grapevine scale", rates: [rate({ value: 2, unit: "L" })] },
    { crop: "POME FRUIT", target_raw: "Mites", rates: [rate({ value: 1, unit: "L" })] },
  ]);
  assertEquals(projection.grapevine_uses.length, 1);
  assertEquals(projection.grapevine_uses[0].crop, "GRAPEVINES");
  // Retained in full — a grower checking whether the drum can be used
  // elsewhere still needs them.
  assertEquals(projection.other_crop_uses.length, 2);
  assertEquals(projection.registered_for_grapevine, true);
});

// ---------------------------------------------------------------------------
// §6 — no grapevine use: a classified reference range, never an invented rate
// ---------------------------------------------------------------------------

Deno.test("no grapevine use produces a reference range, explicitly classified", () => {
  const projection = projectGrapevineUses([
    { crop: "ALMONDS", rates: [rate({ value: 100, unit: "mL", basis: "per_100_litres" })] },
    { crop: "POME FRUIT", rates: [rate({ value: 200, unit: "mL", basis: "per_100_litres" })] },
  ]);

  assertEquals(projection.registered_for_grapevine, false);
  // No grapevine use is INVENTED.
  assertEquals(projection.grapevine_uses.length, 0);

  const [ref] = projection.label_reference_rate_ranges;
  assertEquals(ref.classification, "not_registered_for_grapevine");
  assertEquals(ref.min_value, 100);
  assertEquals(ref.max_value, 200);
  assertEquals(ref.unit, "mL");
  assertEquals(ref.basis, "per_100_litres");
  assertEquals(ref.derived_from_crops, ["ALMONDS", "POME FRUIT"]);
  assert(ref.note.includes("not registered"));
});

Deno.test("a reference range is NEVER produced when grapevine IS registered", () => {
  // Both on one screen is how an unregistered reference range gets sprayed.
  const projection = projectGrapevineUses([
    { crop: "GRAPEVINES", rates: [rate({ value: 2, unit: "L" })] },
    { crop: "ALMONDS", rates: [rate({ value: 100, unit: "mL" })] },
  ]);
  assertEquals(projection.label_reference_rate_ranges, []);
});

Deno.test("bases are never combined into one range", () => {
  const ranges = deriveLabelReferenceRateRanges([
    { crop: "ALMONDS", rates: [rate({ value: 100, unit: "mL", basis: "per_100_litres" })] },
    { crop: "ALMONDS", rates: [rate({ value: 200, unit: "mL", basis: "per_100_litres" })] },
    { crop: "ALMONDS", rates: [rate({ value: 4, unit: "L", basis: "per_hectare" })] },
    { crop: "ALMONDS", rates: [rate({ value: 8, unit: "L", basis: "per_hectare" })] },
  ]);
  assertEquals(ranges.length, 2);
  const per100 = ranges.find((r) => r.basis === "per_100_litres")!;
  const perHa = ranges.find((r) => r.basis === "per_hectare")!;
  assertEquals([per100.min_value, per100.max_value, per100.unit], [100, 200, "mL"]);
  assertEquals([perHa.min_value, perHa.max_value, perHa.unit], [4, 8, "L"]);
});

Deno.test("range bounds contribute both ends", () => {
  const [ref] = deriveLabelReferenceRateRanges([{
    crop: "ALMONDS",
    rates: [rate({ basis: "range_per_100_litres", min_value: 100, max_value: 200, unit: "mL" })],
  }]);
  assertEquals([ref.min_value, ref.max_value], [100, 200]);
});

Deno.test("mixed units on one basis fail closed rather than pick one", () => {
  // "100 mL to 3 L" is arithmetic, not a label reading.
  const ranges = deriveLabelReferenceRateRanges([
    { crop: "A", rates: [rate({ value: 100, unit: "mL", basis: "per_100_litres" })] },
    { crop: "B", rates: [rate({ value: 3, unit: "L", basis: "per_100_litres" })] },
  ]);
  assertEquals(ranges.length, 0);
});

Deno.test("verbatim-only rates never enter a reference range", () => {
  const ranges = deriveLabelReferenceRateRanges([{
    crop: "ALMONDS",
    rates: [rate({ basis: "other", unit: "", raw_text: "See directions for use" })],
  }]);
  assertEquals(ranges, []);
});

// ---------------------------------------------------------------------------
// §2 — manufacturer label first, regulator label second
// ---------------------------------------------------------------------------

Deno.test("manufacturer and regulator labels are separate fields, both kept", () => {
  const refs = selectLabelReferences({
    manufacturerLabelUrl: "https://vicchem.com/labels/vicol-winter-oil.pdf",
    regulatorLabelUrl: "https://elabels.apvma.gov.au/33182.pdf",
    productUrl: "https://vicchem.com/products/vicol-winter-oil",
  });
  assertEquals(refs.manufacturer_label_url, "https://vicchem.com/labels/vicol-winter-oil.pdf");
  assertEquals(refs.regulator_label_url, "https://elabels.apvma.gov.au/33182.pdf");
  assertEquals(refs.manufacturer_product_url, "https://vicchem.com/products/vicol-winter-oil");
});

Deno.test("the legacy field keeps pointing at the AUTHORITATIVE document", () => {
  // Shipped builds read one field. Pointing it at the manufacturer document
  // would silently downgrade what an installed app calls "the label".
  const refs = selectLabelReferences({
    manufacturerLabelUrl: "https://vicchem.com/labels/vicol.pdf",
    regulatorLabelUrl: "https://elabels.apvma.gov.au/33182.pdf",
  });
  assertEquals(refs.label_reference, "https://elabels.apvma.gov.au/33182.pdf");
});

Deno.test("with no regulator label the legacy field falls back to the manufacturer's", () => {
  const refs = selectLabelReferences({
    manufacturerLabelUrl: "https://vicchem.com/labels/vicol.pdf",
  });
  assertEquals(refs.label_reference, "https://vicchem.com/labels/vicol.pdf");
  assertEquals(refs.regulator_label_url, null);
});

Deno.test("a regulator URL offered as the manufacturer label is reclassified", () => {
  // Otherwise the UI prints one document twice under two headings.
  const refs = selectLabelReferences({
    manufacturerLabelUrl: "https://elabels.apvma.gov.au/33182.pdf",
  });
  assertEquals(refs.manufacturer_label_url, null);
  assertEquals(refs.regulator_label_url, "https://elabels.apvma.gov.au/33182.pdf");
});

Deno.test("a product page is never promoted to a label", () => {
  const refs = selectLabelReferences({
    productUrl: "https://vicchem.com/products/vicol-winter-oil",
  });
  assertEquals(refs.manufacturer_label_url, null);
  assertEquals(refs.regulator_label_url, null);
  assertEquals(refs.label_reference, null);
  assertEquals(refs.manufacturer_product_url, "https://vicchem.com/products/vicol-winter-oil");
});

Deno.test("non-http junk is rejected rather than served as a link", () => {
  const refs = selectLabelReferences({
    manufacturerLabelUrl: "not a url",
    regulatorLabelUrl: "   ",
    productUrl: "javascript:alert(1)",
  });
  assertEquals(refs.manufacturer_label_url, null);
  assertEquals(refs.regulator_label_url, null);
  assertEquals(refs.manufacturer_product_url, null);
});

// ---------------------------------------------------------------------------
// §9 — APVMA 33182 acceptance
// ---------------------------------------------------------------------------

/**
 * VICOL WINTER OIL INSECTICIDE — APVMA 33182, as the label states it.
 *
 * A petroleum spray oil. The grapevine entry carries two conditional /100 L
 * rates by state, dormancy restrictions, and NO hectare rate.
 */
const VICOL_33182 = {
  product_name: "VICOL WINTER OIL INSECTICIDE",
  product_category: "Insecticide",
  registration_number: "33182",
  registrant: "Victorian Chemical Company Pty Ltd",
  active_ingredients: [{
    name: "Petroleum Oil",
    concentration: 861,
    concentration_unit: "g/L",
    activity_group: { scheme: "not_applicable", code: null },
  }],
  manufacturer_label_url: "https://vicchem.com.au/labels/vicol-winter-oil.pdf",
  regulator_label_url: "https://elabels.apvma.gov.au/33182.pdf",
  registered_uses: [
    {
      crop: "GRAPEVINES",
      target_raw: "European red mite",
      rates: [
        rate({ basis: "per_100_litres", value: 3, unit: "L", label: "NSW/Vic/SA", raw_text: "3 L/100 L" }),
        rate({ basis: "per_100_litres", value: 2, unit: "L", label: "Tasmania", raw_text: "2 L/100 L" }),
      ],
      restrictions: "Apply as a post-pruning application while vines are fully dormant.",
      withholding_period_days: null,
      re_entry_period_hours: null,
    },
    {
      crop: "GRAPEVINES",
      target_raw: "Grapevine scale",
      rates: [
        rate({ basis: "per_100_litres", value: 2, unit: "L", label: "Dormant vines", raw_text: "2 L/100 L" }),
      ],
      restrictions: "Post-pruning, dormant vines only.",
      withholding_period_days: null,
      re_entry_period_hours: null,
    },
    {
      crop: "POME FRUIT",
      target_raw: "San Jose scale",
      rates: [rate({ basis: "per_100_litres", value: 1, unit: "L", raw_text: "1 L/100 L" })],
    },
  ],
};

Deno.test("33182: label references are both populated, manufacturer first", () => {
  const refs = selectLabelReferences({
    manufacturerLabelUrl: VICOL_33182.manufacturer_label_url,
    regulatorLabelUrl: VICOL_33182.regulator_label_url,
  });
  assertEquals(refs.manufacturer_label_url, "https://vicchem.com.au/labels/vicol-winter-oil.pdf");
  assertEquals(refs.regulator_label_url, "https://elabels.apvma.gov.au/33182.pdf");
});

Deno.test("33182: category and chemical class are kept separate from concentration", () => {
  assertEquals(VICOL_33182.product_category, "Insecticide");
  const active = VICOL_33182.active_ingredients[0];
  assertEquals(active.name, "Petroleum Oil");
  assertEquals(active.concentration, 861);
  assertEquals(active.concentration_unit, "g/L");
  // A petroleum oil has no IRAC group. That is an ASSERTION, not a gap.
  assertEquals(active.activity_group.scheme, "not_applicable");
});

Deno.test("33182: grapevine uses lead, pome fruit is retained but secondary", () => {
  const p = projectGrapevineUses(VICOL_33182.registered_uses);
  assertEquals(p.registered_for_grapevine, true);
  assertEquals(p.grapevine_uses.length, 2);
  assertEquals(
    p.grapevine_uses.map((u) => u.target_raw),
    ["European red mite", "Grapevine scale"],
  );
  assertEquals(p.other_crop_uses.length, 1);
  assertEquals(p.other_crop_uses[0].crop, "POME FRUIT");
  // A registered product never gets a reference range.
  assertEquals(p.label_reference_rate_ranges, []);
});

Deno.test("33182: both 2 L and 3 L /100 L survive with the right conditions", () => {
  const p = projectGrapevineUses(VICOL_33182.registered_uses);
  const mite = p.grapevine_uses.find((u) => u.target_raw === "European red mite")!;

  assertEquals(mite.rates.length, 2);
  const byCondition = new Map<string, number>(
    mite.rates.map((r: WireLabelRate) => [r.label, r.value as number]),
  );
  assertEquals(byCondition.get("NSW/Vic/SA"), 3);
  assertEquals(byCondition.get("Tasmania"), 2);

  // Two conditional readings, NOT one 2–3 L range.
  assert(mite.rates.every((r: WireLabelRate) => r.basis === "per_100_litres"));
  assert(mite.rates.every((r: WireLabelRate) => r.min_value === undefined));
});

Deno.test("33182: no hectare rate is invented", () => {
  const p = projectGrapevineUses(VICOL_33182.registered_uses);
  const everyRate = p.grapevine_uses.flatMap((u) => u.rates as WireLabelRate[]);
  assert(everyRate.length > 0);
  assert(
    everyRate.every((r) => r.basis === "per_100_litres"),
    "the label states no /ha rate, so none may appear",
  );
});

Deno.test("33182: dormancy and post-pruning restrictions are retained", () => {
  const p = projectGrapevineUses(VICOL_33182.registered_uses);
  for (const use of p.grapevine_uses) {
    assert(
      /post-pruning/i.test(use.restrictions) && /dormant/i.test(use.restrictions),
      `restriction lost for ${use.target_raw}`,
    );
  }
});

Deno.test("33182: unstated WHP and REI stay null, never zero", () => {
  const p = projectGrapevineUses(VICOL_33182.registered_uses);
  for (const use of p.grapevine_uses) {
    assertEquals(use.withholding_period_days, null);
    assertEquals(use.re_entry_period_hours, null);
  }
});
