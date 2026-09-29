import { extractManufacturerDocumentText } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_document.ts";
const bytes = await Deno.readFile(new URL("../docs/weedmaster-acceptance/weedmaster_duo_documented.pdf", import.meta.url));
const items = await extractManufacturerDocumentText({ now: () => new Date(), fetchFn: (() => { throw Error("network forbidden"); }) as typeof fetch }, bytes);
if (!items) throw Error("No items");
for (const page of [13]) {
  const filtered = items.filter((i) => i.page === page && (i.y > 330 && i.y < 391));
  console.log(`PAGE ${page} ${filtered.length}\n` + filtered.map((i) => `${i.x.toFixed(1)},${i.y.toFixed(1)} ${i.str}`).join("\n"));
}
