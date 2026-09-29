// deno-lint-ignore-file no-import-prefix no-unversioned-import require-await
import { assert, assertEquals } from "jsr:@std/assert";
import { alternateManufacturerLabel, companionDirectionsUrl, companionGrapeDirections, pageMatchesLockedProduct, pairedDirectionsConfirmIdentity, requiresAttachedDirections, verifiesTradingAs } from "./manufacturer_companion.ts";
import { manufacturerHostEligible } from "../research/classify.ts";
import { extractLinks } from "../research/page_inspector.ts";
import { extractManufacturerDocumentText, fetchManufacturerDocument, safeManufacturerFetchReason } from "./manufacturer_document.ts";
import { enrichFromManufacturerLabel, manufacturerDocumentConfirmsIdentity } from "./manufacturer_enrichment.ts";
import { assembleTextLines } from "./label_extract.ts";
import { finishBackfillPreview, markConditionalGrapeWithholding } from "./master_backfill_preview.ts";
import { applyRateIdentities } from "../rate_identity.ts";
import { normaliseRegisteredUses } from "../registered_use_normaliser.ts";
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
  const bound = companionGrapeDirections(items, name);
  assertEquals(bound?.length, 2);
  assertEquals(bound?.map((use) => use.target_raw), ["Downy mildew / Bunch rot", "Black Spot"]);
  assertEquals((bound?.[1].rates as Array<{ basis: string; value: number }>)[0].basis, "per_100_litres");
  assertEquals((bound?.[1].rates as Array<{ basis: string; value: number }>)[0].value, 175);
  assert(bound?.every((use) => !/virus buildup|Use the higher 7-14/.test(String(use.restrictions))));
  assert(bound?.every((use) => /For all uses in this table/.test(String(use.restrictions))));
  assert(bound?.every((use) => /DO NOT exceed 2\.5kg/.test(String(use.restrictions))));
  assertEquals(companionGrapeDirections(items, "Farmalinx Piricarb WG Aphicide"), null);
  assertEquals(companionGrapeDirections(items.filter((item) => item.str !== "175 g/100 L"), name), null,
    "a missing target dose cannot silently become complete grape coverage");
  assertEquals(companionGrapeDirections(items.filter((item) => item.str !== "14" || item.page !== 1), name), null,
    "conditional harvest periods cannot be guessed from numbers elsewhere");
  const result = await enrichFromManufacturerLabel({
    deps: { fetchFn: (async () => new Response(bytes, { status: 200 })) as typeof fetch, now: () => new Date() },
    manufacturerLabelUrl: leaflet, sourcePageUrl: pageUrl, regulatorUses: [],
    registeredProductName: name, activeNames: ["Chlorothalonil"], pairedContainerVerified: true,
    registrant: "Farmalinx Pty Ltd", product: { country: "AU", scheme: "apvma", registration_number: "84047" },
  });
  assertEquals(result.fetchedUrl, leaflet);
  assertEquals(result.uses.length, 2);
  assert(result.uses.some((use) => /grape/i.test(String(use.crop)) &&
    Array.isArray(use.rates) && use.rates.some((rate: { min_value?: number; max_value?: number }) =>
      rate.min_value === 1.5 && rate.max_value === 1.9)), JSON.stringify(result.uses));
  const row = { id: "10000000-0000-4000-8000-000000084047", registration_country: "AU",
    registration_scheme: "apvma", registration_number: "84047", registration_identity_key: "AU:apvma:84047",
    registered_product_name: name, registrant: "Farmalinx Pty Ltd", product_category: "fungicide",
    active_ingredients: [{ name: "Chlorothalonil", concentration: 900, concentration_unit: "g/kg",
      activity_group: { scheme: "frac", code: "M5", common_name: "Multi-site / Chloronitrile" },
      group_source: "authoritative_classification", classification_state: "classified" }],
    resistance_classification_state: "classified", activity_groups: ["M05"], registered_uses: [
      { crop: "Potatoes", target_raw: "Early blight", restrictions: "Preserved existing direction", rates: [] }],
    viticulture_rates: { per_hectare: [], per_100_litres: [] }, verification_sources: [],
    verification_unresolved_fields: ["active_ingredients"], review_status: "candidate", catalogue_version: 1 } as unknown as MasterRow;
  const detail = { registration: { registration_number: "84047", manufacturer_label_url: leaflet,
    manufacturer_package_label_url: container, manufacturer_label_verified: true },
    registered_uses: normaliseRegisteredUses(result.uses),
    verification: { unresolved_fields: ["active_ingredients"] } };
  markConditionalGrapeWithholding(detail, true);
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
  const proposedUses = preview.proposed_patch?.registered_uses as Array<Record<string, unknown>>;
  assertEquals(proposedUses.length, 3);
  assertEquals(proposedUses[0].crop, "Potatoes");
  assertEquals(proposedUses[0].restrictions, "Preserved existing direction");
  assertEquals(proposedUses.slice(1).map((use) => use.target_raw), ["Downy mildew / Bunch rot", "Black Spot"]);
  assertEquals(proposedUses.slice(1).map((use) => use.withholding_statement),
    ["Dessert grapes: 7 days; Wine grapes: 14 days", "Dessert grapes: 7 days; Wine grapes: 14 days"]);
  assert(proposedUses.slice(1).every((use) => use.withholding_period_days == null &&
    typeof use.direction_id === "string" && /DO NOT exceed 2\.5kg/.test(String(use.restrictions))));
  assertEquals(proposedUses.slice(1).map((use) => (use.rates as Array<{ basis: string }>)[0].basis),
    ["range_per_hectare", "per_100_litres"]);
  assert(proposedUses.slice(1).every((use) => (use.rates as Array<{ rate_id: string }>)[0].rate_id));
  assertEquals(preview.proposed_patch?.active_ingredients, undefined);
  assertEquals(preview.proposed_patch?.verification_unresolved_fields, ["withholding_period:GRAPEVINE"]);
  assertEquals((preview.proposed_patch?.viticulture_rates as { per_100_litres: Array<{ value: number }> })
    .per_100_litres[0].value, 175);
  const missingChemistry = { ...row, active_ingredients: [{ name: "Chlorothalonil" }] } as MasterRow;
  const incomplete = await finishBackfillPreview(missingChemistry, "admin", { detail }, true,
    { insertPreview: () => { throw new Error("dry run attempted a write"); } });
  assert((incomplete.proposed_patch?.verification_unresolved_fields as string[]).includes("active_ingredients"));
});

Deno.test("Nufarm's own CDN PDF is a document lead, not proof of locked Weedmaster chemistry", async () => {
  const candidate = "https://cdn.nufarm.com/wp-content/uploads/sites/22/2018/05/13085258/0533-Nufarm-Weedmaster-DUO-Herbicide.pdf";
  const product = "https://nufarm.com/au/product/weedmaster-duo/";
  assertEquals(manufacturerHostEligible(candidate, "AU", "Nufarm"), true);
  const bytes = await Deno.readFile(new URL("./chlorostar_leaflet_fixture.pdf", import.meta.url));
  const fetched = await fetchManufacturerDocument({ fetchFn: (() => Promise.resolve(new Response(bytes))) as typeof fetch,
    now: () => new Date() }, candidate, product);
  assertEquals(fetched.outcome, "fetched");
  const text = assembleTextLines((await extractManufacturerDocumentText({ fetchFn: fetch, now: () => new Date() },
    fetched.bytes!)) ?? []).map((line) => line.text).join("\n");
  assertEquals(manufacturerDocumentConfirmsIdentity({ text, registeredProductName: "Weedmaster DUO Herbicide",
    registrationNumber: "53576", activeNames: ["Glyphosate"] }), false);
  const rejected = await fetchManufacturerDocument({ fetchFn: (() => Promise.resolve(new Response("blocked", {
    status: 403, headers: { "cf-mitigated": "challenge" } }))) as typeof fetch,
    now: () => new Date() }, candidate, product);
  assertEquals(rejected.outcome, "rejected_browser_challenge");
});

Deno.test("unbound paired grape table cannot be promoted to a writable manufacturer preview", async () => {
  const bytes = await Deno.readFile(new URL("./chlorostar_leaflet_fixture.pdf", import.meta.url));
  const items = await extractManufacturerDocumentText({ fetchFn: fetch, now: () => new Date() }, bytes);
  assert(items);
  const result = await enrichFromManufacturerLabel({
    deps: { fetchFn: (() => Promise.resolve(new Response(bytes, { status: 200 }))) as typeof fetch,
      now: () => new Date(), extractPdfText: () => Promise.resolve(items.filter((item) => item.str !== "175 g/100 L")) },
    manufacturerLabelUrl: leaflet, sourcePageUrl: pageUrl, regulatorUses: [],
    registeredProductName: name, activeNames: ["Chlorothalonil"], pairedContainerVerified: true,
    registrant: "Farmalinx Pty Ltd", product: { country: "AU", scheme: "apvma", registration_number: "84047" },
  });
  assertEquals(result.fetchedUrl, null);
  assertEquals(result.uses, []);
  assertEquals(result.diagnostics.manufacturer_label_fetch_reason, "paired_table_binding_unresolved");
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

Deno.test("fetch failure reports only a fixed subtype or validated HTTP status", async () => {
  const selected = "https://www.adama.com/labels/simanex-900-wg-label.pdf?token=secret";
  const result = await fetchManufacturerDocument({ now: () => new Date(), fetchFn: (async (_url, init) => {
    assertEquals((init as { headers?: Record<string, string> } | undefined)?.headers?.["User-Agent"],
      "Mozilla/5.0 (compatible; VineTrack-ChemicalLookup/1.0; +https://rork.app)");
    return new Response("Denied", { status: 403 });
  }) as typeof fetch }, selected, selected);
  assertEquals(result.outcome, "rejected_http_error");
  assertEquals(result.httpStatus, 403);
  assertEquals(safeManufacturerFetchReason(result.outcome, result.httpStatus), "label_fetch_http_403");
  assertEquals(safeManufacturerFetchReason("rejected_not_pdf"), "label_fetch_failed_not_pdf");
  assertEquals(safeManufacturerFetchReason("rejected_off_host_redirect"), "label_fetch_failed_off_host_redirect");
  assertEquals(safeManufacturerFetchReason("rejected_network_error"), "label_fetch_failed_network_error");
  assertEquals(safeManufacturerFetchReason("rejected_http_error", 999), "label_fetch_failed_http_error");
  for (const status of [429, 500])
    assertEquals(safeManufacturerFetchReason("rejected_http_error", status), `label_fetch_http_${status}`);
  for (const subtype of ["not_https", "untrusted_host", "off_host_redirect", "not_found", "not_pdf", "too_large", "network_error"] as const)
    assertEquals(safeManufacturerFetchReason(`rejected_${subtype}`), `label_fetch_failed_${subtype}`);
});

Deno.test("manufacturer fetch logs status, outcome and both URLs without query secrets or response text", async () => {
  const selected = "https://www.adama.com/labels/simanex-label.pdf?token=private";
  const final = "https://www.adama.com/labels/simanex-current-label.pdf?signature=private";
  const original = console.info;
  const logs: string[] = [];
  console.info = (...args: unknown[]) => { logs.push(args.map(String).join(" ")); };
  try {
    const fetched = await fetchManufacturerDocument({ now: () => new Date(), fetchFn: (async () => {
      const response = new Response("secret response", { status: 429, headers: { "content-type": "text/html" } });
      Object.defineProperty(response, "url", { value: final });
      return response;
    }) as typeof fetch }, selected, selected);
    assertEquals(fetched.outcome, "rejected_http_error");
    assertEquals(logs.length, 1);
    const event = JSON.parse(logs[0].slice("manufacturer_document_fetch ".length));
    assertEquals(event.selected_url, "https://www.adama.com/labels/simanex-label.pdf");
    assertEquals(event.http_status, 429);
    assertEquals(event.outcome, "rejected_http_error");
    assertEquals(typeof event.elapsed_ms, "number");
    assertEquals(logs[0].includes("private") || logs[0].includes("secret response"), false);
    assertEquals(event.final_url, "https://www.adama.com/labels/simanex-current-label.pdf");
  } finally { console.info = original; }
});

Deno.test("legal trading-as relationship is specific, not fuzzy brand trust", () => {
  assert(verifiesTradingAs("© 2026 Grochem Australia Pty Ltd trading as 7 Worlds Ag", "Grochem Australia Pty Ltd"));
  assertEquals(verifiesTradingAs("7 Worlds Ag makes products like Grochem", "Grochem Australia Pty Ltd"), false);
  assertEquals(manufacturerHostEligible("https://7worlds.com.au/products/crop-doc-600-2/", "AU", "Grochem Australia Pty Ltd"), true);
  assertEquals(manufacturerHostEligible("https://7worlds.com.au/products/crop-doc-600-2/", "AU", "Other Registrant"), false);
  assertEquals(manufacturerHostEligible("https://7worlds.com.au.evil.com/products/crop-doc-600-2/", "AU", "Grochem Australia Pty Ltd"), false);
});
