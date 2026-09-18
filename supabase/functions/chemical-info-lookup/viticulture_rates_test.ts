import { assertEquals } from "jsr:@std/assert@1";
import { deriveViticultureRates, isGrapevineCrop } from "./grapevine_label.ts";
import type { WireLabelRate } from "./ingestion/contract.ts";

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
