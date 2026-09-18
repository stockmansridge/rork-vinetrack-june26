import { assertEquals } from "jsr:@std/assert@1";
import { deriveViticultureRates, isGrapevineCrop } from "./grapevine_label.ts";
import type { LabelUseClaim, WireLabelRate } from "./ingestion/contract.ts";
import {
  bindDfuRows,
  type DfuRow,
  parseDirectionsForUse,
  parseDualPowerSprayerRows,
  type TextLine,
} from "./ingestion/label_extract.ts";

const rate = (basis: WireLabelRate["basis"], unit: string, value?: number, min?: number, max?: number): WireLabelRate => ({
  label: "", basis, unit, raw_text: value === undefined ? `${min}–${max}` : `${value}`,
  ...(value === undefined ? { min_value: min, max_value: max } : { value }),
});

Deno.test("viticulture recognises composite vineyard headings without matching grapefruit", () => {
  assertEquals(isGrapevineCrop("ORCHARDS, PLANTATIONS AND VINEYARDS"), true);
  assertEquals(isGrapevineCrop("GRAPEFRUIT"), false);
});

Deno.test("APVMA 46516 retains both registered vineyard bases", () => {
  const result = deriveViticultureRates([{ crop: "ORCHARDS, PLANTATIONS AND VINEYARDS", rates: [
    rate("range_per_hectare", "L", undefined, 2.4, 3.2),
    rate("range_per_100_litres", "mL", undefined, 240, 320),
  ] }]);
  assertEquals(result.per_hectare.map((r) => [r.min_value, r.max_value, r.unit]), [[2.4, 3.2, "L"]]);
  assertEquals(result.per_100_litres.map((r) => [r.min_value, r.max_value, r.unit]), [[240, 320, "mL"]]);
});

Deno.test("different vineyard directions remain separate options", () => {
  const result = deriveViticultureRates([
    { crop: "Grapes", rates: [rate("per_100_litres", "mL", 40)] },
    { crop: "Grapevines", rates: [rate("range_per_100_litres", "mL", undefined, 80, 100)] },
  ]);
  assertEquals(result.per_100_litres.length, 2);
  assertEquals(result.per_100_litres[0].value, 40);
  assertEquals([result.per_100_litres[1].min_value, result.per_100_litres[1].max_value], [80, 100]);
});

Deno.test("APVMA 52518 recovers a crop prefix only when the remaining fungicide target matches", () => {
  const rows: DfuRow[] = [{
    crop_text: "",
    target_lines: [
      "Grapes Downy mildew",
      "Note: russeting (Plasmopara viticola)",
      "of some table Bunch rot",
      "grape varieties (Botrytis cinerea)",
      "may occur",
    ],
    rate_text: "1.8 – 2.3 L/ha",
    rate_basis: null,
    rate_ha_text: "",
    whp_text: "Dessert 7 Wine 14",
    comments_text: "Spray at first appearance of the foliage disease.",
    rate_unit_hint: null,
  }];
  const claims: LabelUseClaim[] = [{
    crop: "GRAPEVINE",
    target_raw: "DOWNY MILDEW ON GRAPE",
    statements: [],
  }];

  const binding = bindDfuRows(rows, claims);
  assertEquals(binding.ratesByClaim.get(0)?.map((item) => [
    item.basis,
    item.min_value,
    item.max_value,
    item.unit,
  ]), [["range_per_hectare", 1.8, 2.3, "L"]]);
  assertEquals(binding.unbound, []);
});

Deno.test("standalone Vines rows bind explicit rates without treating category headings as crops", () => {
  const fixtures = [
    { raw: "250 g/100 L", basis: "per_100_litres", value: 250, min: undefined, max: undefined },
    { raw: "95 to 135 g/ 100L", basis: "range_per_100_litres", value: undefined, min: 95, max: 135 },
    { raw: "115 to 165g/ 100L", basis: "range_per_100_litres", value: undefined, min: 115, max: 165 },
    { raw: "100 – 130 g/100 L", basis: "range_per_100_litres", value: undefined, min: 100, max: 130 },
  ];
  for (const fixture of fixtures) {
    const row: DfuRow = {
      crop_text: "Vines",
      target_lines: ["Downy mildew", "(Plasmopara viticola)"],
      rate_text: fixture.raw,
      rate_basis: null,
      rate_ha_text: "",
      whp_text: "",
      comments_text: "Apply as the registered direction states.",
      rate_unit_hint: null,
    };
    const binding = bindDfuRows([row], [{
      crop: "VINE",
      target_raw: "DOWNY MILDEW ON GRAPE",
      statements: [],
    }]);
    assertEquals(binding.ratesByClaim.get(0)?.map((item) => [
      item.basis,
      item.value,
      item.min_value,
      item.max_value,
      item.unit,
    ]), [[fixture.basis, fixture.value, fixture.min, fixture.max, "g"]]);
    assertEquals(binding.unbound, []);
  }

  const categoryRow: DfuRow = {
    crop_text: "TREE AND VINE CROPS",
    target_lines: ["Downy mildew"],
    rate_text: "250 g/100 L",
    rate_basis: null,
    rate_ha_text: "",
    whp_text: "",
    comments_text: "",
    rate_unit_hint: null,
  };
  const categoryBinding = bindDfuRows([categoryRow], [{
    crop: "VINE",
    target_raw: "DOWNY MILDEW ON GRAPE",
    statements: [],
  }]);
  assertEquals(categoryBinding.ratesByClaim.size, 0);
});

Deno.test("APVMA 40146 binds plural Cutworms to its explicit registered cutworm claim", () => {
  const row: DfuRow = {
    crop_text: "Grapes (butt treatments only)",
    target_lines: ["Cutworms"],
    rate_text: "160 to 200 mL/ 100 L water",
    rate_basis: null,
    rate_ha_text: "",
    whp_text: "",
    comments_text: "Use higher rate where high insect pressure occurs.",
    rate_unit_hint: null,
  };
  const binding = bindDfuRows([row], [{
    crop: "GRAPE",
    target_raw: "CUTWORM - AGROTIS SPP.",
    statements: [],
  }]);
  assertEquals(binding.ratesByClaim.get(0)?.map((item) => [
    item.basis,
    item.min_value,
    item.max_value,
    item.unit,
  ]), [["range_per_100_litres", 160, 200, "mL"]]);
  assertEquals(binding.unbound, []);
});

Deno.test("APVMA 52710 merged herbicide quantities remain unbound without a target", () => {
  const rows: DfuRow[] = [{
    crop_text: "",
    target_lines: ["Vines established", "at least 3 years in", "Qld and for 12 months"],
    rate_text: "1.3 to 2.5 kg 3.9 kg",
    rate_basis: null,
    rate_ha_text: "",
    whp_text: "",
    comments_text: "Use the higher rate on heavier soils.",
    rate_unit_hint: null,
  }];
  const claims: LabelUseClaim[] = [{ crop: "VINE OVER 3 YEARS OLD", target_raw: "GERANIUM", statements: [] }];

  const binding = bindDfuRows(rows, claims);
  assertEquals(binding.ratesByClaim.size, 0);
  assertEquals(binding.unbound.map((item) => item.reason), ["no_corresponding_claim"]);
});

Deno.test("APVMA 51547 tree-and-vine insecticide heading preserves its explicit 100 L basis", () => {
  const item = (y: number, x: number, str: string) => ({
    page: 1,
    x,
    y,
    width: Math.max(str.length * 4, 2),
    str,
  });
  const items = [
    item(800, 20, "DIRECTIONS FOR USE"),
    item(790, 20, "NOT TO BE USED FOR ANY PURPOSE"),
    item(780, 20, "Table 1: Tree and Vine crops"),
    item(760, 20, "TREE AND"),
    item(760, 150, "INSECT PEST"),
    item(760, 300, "RATE/ 100 L"),
    item(760, 430, "CRITICAL COMMENTS"),
    item(750, 20, "VINE CROPS"),
    item(730, 20, "Grapes"),
    item(730, 150, "Longtail mealybug"),
    item(730, 300, "30 – 60 mL"),
    item(730, 430, "Apply twice, 14-21 days apart."),
    item(700, 20, "NOT TO BE USED FOR ANY PURPOSE"),
  ];
  const parsed = parseDirectionsForUse(items);
  const binding = bindDfuRows(parsed.rows, [{
    crop: "GRAPE",
    target_raw: "LONGTAILED MEALY BUG",
    statements: [],
  }]);

  assertEquals(parsed.rows.map((row) => [row.crop_text, row.rate_basis, row.rate_text]), [
    ["Grapes", "per_100_litres", "30 – 60 mL"],
  ]);
  assertEquals(binding.ratesByClaim.get(0)?.map((rate) => [
    rate.basis,
    rate.min_value,
    rate.max_value,
    rate.unit,
  ]), [["range_per_100_litres", 30, 60, "mL"]]);
});

Deno.test("APVMA dual Power Sprayer columns independently reproduce the 46516 fixture", () => {
  const line = (y: number, entries: Array<[number, string]>): TextLine => ({
    page: 1,
    y,
    items: entries.map(([x, str]) => ({ x, width: Math.max(str.length * 4, 2), str })),
    text: entries.map(([, str]) => str).join(""),
  });
  const lines: TextLine[] = [
    line(730, [[136, "Weeds"]]),
    line(720, [[41, "Crop/Situation"], [195, "States"], [255, "Power Sprayer"], [416, "Critical Comments"]]),
    line(710, [[128, "Controlled"]]),
    line(700, [[300, "/100 L"]]),
    line(690, [[250, "/ha"]]),
    line(680, [[286, "(Spot Spray)"]]),
    line(670, [[30, "Public Service"], [117, "Most annual"], [188, "All States"], [232, "2.4 to 3.2 L"], [285, "240 to"], [344, "Use the high rate"]]),
    line(660, [[30, "Areas, Orchards and"], [117, "grasses and"], [232, "(a)"], [285, "320 mL"], [344, "for established weeds"]]),
    line(650, [[30, "Vineyards"], [117, "broadleaf weeds"], [232, "see below"], [285, "(b)"]]),
  ];
  const rows = parseDualPowerSprayerRows(lines);
  const claims: LabelUseClaim[] = [
    { crop: "VINEYARD", target_raw: "BROADLEAF WEEDS", statements: [] },
  ];
  const binding = bindDfuRows(rows, claims);
  const rates = deriveViticultureRates([{ crop: "VINEYARD", rates: binding.ratesByClaim.get(0) }]);
  assertEquals(rates.per_hectare.map((r) => [r.min_value, r.max_value, r.unit]), [[2.4, 3.2, "L"]]);
  assertEquals(rates.per_100_litres.map((r) => [r.min_value, r.max_value, r.unit]), [[240, 320, "mL"]]);
});
