import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { extractManufacturerDocumentText } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_document.ts";
import { bindVineyardReferencedTables } from "../supabase/functions/chemical-info-lookup/ingestion/vineyard_table_binding.ts";

Deno.test("read-only retained Weedmaster PDF produces corrected Phalaris proposal", async () => {
  const pdf = await Deno.readFile("docs/weedmaster-acceptance/weedmaster_duo_documented.pdf");
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", pdf)))
    .map((n) => n.toString(16).padStart(2, "0")).join("");
  assertEquals(hash, "69213c077e191e99682e515884d7667156367ea7ab927ecdac2882f4d0ec39b8");
  const items = await extractManufacturerDocumentText({ now: () => new Date(),
    fetchFn: (() => { throw Error("network forbidden"); }) as typeof fetch }, pdf);
  assert(items);
  const proposal = bindVineyardReferencedTables(items,
    { country: "AU", scheme: "apvma", registration_number: "53576" },
    "WITHHOLDING PERIOD: NOT REQUIRED WHEN USED AS DIRECTED");
  const phalaris = proposal.uses.filter((use) => use.target === "Phalaris");
  assertEquals(phalaris.length, 1);
  const rates = phalaris[0].rates as Array<Record<string, unknown>>;
  const handgun = rates.find((rate) => rate.label === "Handgun");
  assert(handgun);
  assertEquals(handgun.raw_text, "500 mL-1 L/100L");
  assertEquals(handgun.basis, "range_per_100_litres");
  assertEquals([handgun.min_value, handgun.max_value, handgun.unit], [500, 1000, "mL"]);
  assertEquals(handgun.value, undefined);
  assertEquals(rates.find((rate) => rate.label === "Boom")?.raw_text, "3-6 L/ha");
  assertEquals(rates.find((rate) => rate.label === "Knapsack")?.basis, "other");
  console.log(JSON.stringify({ status: "non_writing_proposal", registration_identity_key: "AU:apvma:53576",
    document_sha256: hash, direction_id: phalaris[0].direction_id, rates }));
});
