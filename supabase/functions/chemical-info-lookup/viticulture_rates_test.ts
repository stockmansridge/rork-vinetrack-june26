import { assertEquals } from "jsr:@std/assert@1";
import { deriveViticultureRates, isGrapevineCrop } from "./grapevine_label.ts";
import type { LabelUseClaim, WireLabelRate } from "./ingestion/contract.ts";
import { bindDfuRows, parseDualPowerSprayerRows, type TextLine } from "./ingestion/label_extract.ts";

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
