// deno-lint-ignore-file no-import-prefix no-unversioned-import require-await
import { assert, assertEquals } from "jsr:@std/assert";
import { alternateManufacturerLabel, companionDirectionsUrl, pageMatchesLockedProduct, pairedDirectionsConfirmIdentity, requiresAttachedDirections, verifiesTradingAs } from "./manufacturer_companion.ts";
import { manufacturerHostEligible } from "../research/classify.ts";
import { extractLinks } from "../research/page_inspector.ts";
import { extractManufacturerDocumentText } from "./manufacturer_document.ts";
import { enrichFromManufacturerLabel, manufacturerDocumentConfirmsIdentity } from "./manufacturer_enrichment.ts";
import { assembleTextLines } from "./label_extract.ts";
import { finishBackfillPreview } from "./master_backfill_preview.ts";
import { applyRateIdentities } from "../rate_identity.ts";
import type { MasterRow } from "./contract.ts";
import type { InspectedPage } from "../research/page_inspector.ts";

const pageUrl = "https://www.farmalinx.com.au/product/chlorostar-900-wg-fungicide/";
const container = "https://www.farmalinx.com.au/wp-content/uploads/2018/01/Chlorostar-900-WG-10kg-Label.pdf";
const leaflet = "https://www.farmalinx.com.au/wp-content/uploads/pdf/Chlorostar%20900%20WG%2024pp%20Leaflet.pdf";
const name = "Farmalinx Chlorostar 900 WG Fungicide";
const page = (html: string): InspectedPage => ({ outcome: "inspected", pageUrl, finalUrl: pageUrl,
  pageProductName: "Chlorostar 900 WG Fungicide", pageProductNameSource: "h1",
  links: extractLinks(html, pageUrl).links, truncated: false });

Deno.test("container label refers to attached directions and only the same-host leaflet qualifies", async () => {
  const bytes = await Deno.readFile(new URL("./chlorostar_container_fixture.pdf", import.meta.url));
  const items = await extractManufacturerDocumentText({ fetchFn: fetch, now: () => new Date() }, bytes);
  assert(items);
  const text = assembleTextLines(items).map((line) => line.text).join("\n");
  assertEquals(requiresAttachedDirections(text), true);
  assert(manufacturerDocumentConfirmsIdentity({ text, registeredProductName: name,
    registrationNumber: "84047", activeNames: ["Chlorothalonil"] }));
  assert(pageMatchesLockedProduct(name, "Chlorostar 900 WG Fungicide", "Farmalinx Pty Ltd"));
  const inspected = page(`<a href="${container}">Chlorostar 900 WG Fungicide LABEL</a>
    <a href="${leaflet}">Chlorostar 900 WG Fungicide LEAFLET</a>
    <a href="https://elders.com.au/leaflet.pdf">Directions for Use</a>
    <a href="https://elabels.apvma.gov.au/84047.pdf">Product Leaflet</a>
    <a href="https://www.farmalinx.com.au/sds.pdf">Safety Data Sheet LEAFLET</a>`);
  assertEquals(companionDirectionsUrl(inspected, name, "AU", "Farmalinx Pty Ltd", container), leaflet);
  assertEquals(companionDirectionsUrl(page(`<a href="https://elders.com.au/leaflet.pdf">LEAFLET</a>`), name,
    "AU", "Farmalinx Pty Ltd", container), null);
  assertEquals(companionDirectionsUrl({ ...inspected, pageProductName: "Other 900 WG" }, name,
    "AU", "Farmalinx Pty Ltd", container), null);
});

Deno.test("Farmalinx leaflet has locked product identity and printed grape directions", async () => {
  const bytes = await Deno.readFile(new URL("./chlorostar_leaflet_fixture.pdf", import.meta.url));
  const items = await extractManufacturerDocumentText({ fetchFn: fetch, now: () => new Date() }, bytes);
  assert(items);
  const text = assembleTextLines(items).map((line) => line.text).join("\n");
  assert(pairedDirectionsConfirmIdentity(text, name, "Farmalinx Pty Ltd", "84047"));
  assertEquals(manufacturerDocumentConfirmsIdentity({ text, registrationNumber: "84047",
    registeredProductName: name, activeNames: ["Chlorothalonil"] }), false);
  assert(/grapes/i.test(text));
  assert(/downy\s+mildew/i.test(text));
  assert(/bunch\s+rot/i.test(text));
  assert(/1\.5/.test(text) && /1\.9/.test(text) && /kg\s*\/\s*ha/i.test(text));
  const result = await enrichFromManufacturerLabel({
    deps: { fetchFn: (async () => new Response(bytes, { status: 200 })) as typeof fetch, now: () => new Date() },
    manufacturerLabelUrl: leaflet, sourcePageUrl: pageUrl, regulatorUses: [],
    registeredProductName: name, activeNames: ["Chlorothalonil"], pairedContainerVerified: true,
    registrant: "Farmalinx Pty Ltd", product: { country: "AU", scheme: "apvma", registration_number: "84047" },
  });
  assertEquals(result.fetchedUrl, leaflet);
  assert(result.uses.some((use) => /grape/i.test(String(use.crop)) &&
    Array.isArray(use.rates) && use.rates.some((rate: { min_value?: number; max_value?: number }) =>
      rate.min_value === 1.5 && rate.max_value === 1.9)), JSON.stringify(result.uses));
  const row = { id: "10000000-0000-4000-8000-000000084047", registration_country: "AU",
    registration_scheme: "apvma", registration_number: "84047", registration_identity_key: "AU:apvma:84047",
    registered_product_name: name, registrant: "Farmalinx Pty Ltd", product_category: "fungicide",
    active_ingredients: [{ name: "Chlorothalonil", concentration: 900, concentration_unit: "g/kg" }],
    resistance_classification_state: "classified", activity_groups: ["M05"], registered_uses: [],
    viticulture_rates: { per_hectare: [], per_100_litres: [] }, verification_sources: [],
    verification_unresolved_fields: [], review_status: "candidate", catalogue_version: 1 } as unknown as MasterRow;
  const detail = { registration: { registration_number: "84047", manufacturer_label_url: leaflet,
    manufacturer_package_label_url: container, manufacturer_label_verified: true }, registered_uses: result.uses };
  applyRateIdentities({ registration: { country_code: "AU", scheme: "apvma", registration_number: "84047" },
    registered_uses: detail.registered_uses });
  const preview = await finishBackfillPreview(row, "admin", { detail }, true,
    { insertPreview: () => { throw new Error("dry run attempted a write"); } });
  assertEquals(preview.status, "preview_ready");
  assertEquals(preview.findings.vineyard_rates_added, true);
  assertEquals((preview.proposed_patch?.viticulture_rates as { per_hectare: Array<{ min_value: number; max_value: number }> })
    .per_hectare.map((rate) => [rate.min_value, rate.max_value]), [[1.5, 1.9]]);
  assertEquals((preview.proposed_patch?.verification_sources as Array<{ reference: string }>).map((source) => source.reference),
    [leaflet, container]);
  assertEquals((preview.proposed_patch?.registered_uses as Array<{ withholding_period_text?: string }>)[0]
    .withholding_period_text, "Dessert grapes: 7 days; Wine grapes: 14 days");
});

Deno.test("failed direct PDF chooses one different own-host product-page label, never the same URL", () => {
  const failed = "https://www.adama.com/labels/simanex-old-label.pdf";
  const current = "https://www.adama.com/labels/simanex-current-label.pdf";
  const finalUrl = "https://www.adama.com/products/simanex-900-wg";
  const inspected: InspectedPage = { ...page(""), finalUrl, pageProductName: "SIMANEX 900 WG HERBICIDE",
    links: extractLinks(`<a href="${failed}">Label</a><a href="${current}">Product Label</a>
    <a href="https://elders.com.au/label.pdf">Product Label</a>
    <a href="https://www.adama.com/labels/simanex-sds.pdf">SDS</a>`, finalUrl).links };
  assertEquals(alternateManufacturerLabel(inspected, "SIMANEX 900 WG HERBICIDE", "AU", "ADAMA", failed), current);
  assertEquals(alternateManufacturerLabel({ ...inspected, links: inspected.links.filter((link) => link.url !== current) },
    "SIMANEX 900 WG HERBICIDE", "AU", "ADAMA", failed), null);
});

Deno.test("legal trading-as relationship is specific, not fuzzy brand trust", () => {
  assert(verifiesTradingAs("© 2026 Grochem Australia Pty Ltd trading as 7 Worlds Ag", "Grochem Australia Pty Ltd"));
  assertEquals(verifiesTradingAs("7 Worlds Ag makes products like Grochem", "Grochem Australia Pty Ltd"), false);
  assertEquals(manufacturerHostEligible("https://7worlds.com.au/products/crop-doc-600-2/", "AU", "Grochem Australia Pty Ltd"), true);
  assertEquals(manufacturerHostEligible("https://7worlds.com.au/products/crop-doc-600-2/", "AU", "Other Registrant"), false);
  assertEquals(manufacturerHostEligible("https://7worlds.com.au.evil.com/products/crop-doc-600-2/", "AU", "Grochem Australia Pty Ltd"), false);
});
