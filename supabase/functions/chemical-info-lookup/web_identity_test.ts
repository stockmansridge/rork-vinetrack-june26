// deno-lint-ignore-file no-import-prefix no-unversioned-import require-await
import { assertEquals, assert } from "jsr:@std/assert";
import { discoverManufacturerUrls, discoverManufacturerUrlsDetailed, findWebMasterIdentities, identityCandidate, identityResearch, manufacturerUrlsFromMaster, selectedIdentity, verifiedManufacturerLead, type WebIdentity } from "./web_identity.ts";
import { manufacturerHostEligible, classifyUrl } from "./research/classify.ts";
import { inspectCandidateProductPages } from "./research/page_inspector.ts";
import { projectResearch } from "./research/authority.ts";
import { withWebEnrichment, vineyardTableRate, vineyardRateSummary, readableV2Label, labelHeaderFacts } from "./web_lookup.ts";
import { authoritativeGroup, resistanceClassificationState } from "./ingestion/activity_groups.ts";
import { selectLabelReferences } from "./grapevine_label.ts";
import { enrichFromManufacturerLabel } from "./ingestion/manufacturer_enrichment.ts";
import { normaliseRegisteredUses } from "./registered_use_normaliser.ts";
import { projectGrapevineUses } from "./grapevine_label.ts";
import { applyRateIdentities } from "./rate_identity.ts";
import { applyDefaultRateOptions } from "./default_rate_options.ts";

const label = "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf";
const master = {
  registered_product_name: "CropSure Beast 200 Herbicide", registrant: "CROPSURE PTY LTD",
  registration_country: "AU", registration_scheme: "apvma", registration_number: "90143",
  review_status: "approved", verification_status: "partially_verified", source_kind: "official_register",
  product_category: "herbicide", active_ingredients: [], registered_uses: Array(512).fill({ crop: "Wheat" }),
  viticulture_rates: { per_hectare: [], per_100_litres: [] },
  verification_sources: [
    { kind: "official_register", reference: "https://portal.apvma.gov.au/pubcris" },
    { kind: "manufacturer_label", name: "label", reference: "https://elabels.apvma.gov.au/90143.pdf" },
    { kind: "manufacturer_label", name: "label", reference: "https://data.gov.au/beast-label.pdf" },
  ],
};

Deno.test("incomplete approved Master Beast remains an identity lead; regulator URL tags cannot promote manufacturer evidence", async () => {
  let calls = 0;
  const found = await findWebMasterIdentities(async (query) => {
    calls++;
    assert(query.includes("beast"));
    return [master, { ...master, registered_product_name: "Beast Cattle Drench", product_category: "veterinary" }];
  }, "Beast", "AU");
  assertEquals(calls, 1);
  assertEquals(found.length, 1);
  assertEquals(identityCandidate(found[0]).registration_number, "90143");
  assertEquals(identityCandidate(found[0]).resistance_classification_state, "unresolved");
  assertEquals(found[0].pageUrls, []);
  assertEquals(found[0].labelUrls, []);
  assertEquals(verifiedManufacturerLead(found[0], "AU"), label);
  assertEquals(verifiedManufacturerLead({ ...found[0], registrationNumber: "12345" }, "AU"), null);
  assertEquals(manufacturerUrlsFromMaster(master, "AU"), { pages: [], labels: [] });
  assertEquals(selectedIdentity(found, "CropSure Beast 200 Herbicide")?.name, found[0].name);
  assertEquals(selectedIdentity(found, "Beast Cattle Drench"), null);
  assertEquals(manufacturerUrlsFromMaster({ verification_sources: [{ kind: "manufacturer_label", reference: label }] }, "AU").labels, [label]);
});

Deno.test("customer manufacturer fallback excludes candidate Master rows and accepts international optional registration", async () => {
  assertEquals(await findWebMasterIdentities(async () => [{ ...master, review_status: "candidate" }], "Beast", "AU"), []);
  for (const country of ["AU", "NZ", "FR", "US", "ZA"]) {
    const found = await findWebMasterIdentities(async () => [{ ...master, registration_country: country,
      registration_scheme: null, registration_number: null }], "Beast", country);
    assertEquals(found.length, 1);
    assertEquals(found[0].registrationNumber, null);
  }
});

Deno.test("accepted manufacturer directions without registration get product-bound canonical options, not invented rates", () => {
  const payload = { registration: { country_code: "FR", scheme: null, registration_number: null },
    registered_uses: [{ crop: "Vineyards", target_raw: "Nutrition", rates: [{ basis: "per_hectare", value: 2, unit: "L", label: "Foliar" }] },
      { crop: "Wheat", target_raw: "Nutrition", rates: [{ basis: "per_hectare", value: 9, unit: "L" }] }] };
  const noLock = structuredClone(payload);
  applyRateIdentities(noLock);
  assertEquals(applyDefaultRateOptions(noLock).length > 0, true);
  applyRateIdentities(payload, { url: "https://maker.example/label.pdf", productName: "Vineyard input" });
  assertEquals(applyDefaultRateOptions(payload), []);
  const served = payload as typeof payload & { default_rate_options: { per_hectare: Array<{ value: number; option_key: string; rate_ids: string[] }> } };
  assertEquals(served.default_rate_options.per_hectare.length, 1);
  assertEquals(served.default_rate_options.per_hectare[0].value, 2);
  const other = structuredClone(noLock);
  applyRateIdentities(other, { url: "https://maker.example/label.pdf", productName: "Different product" });
  applyDefaultRateOptions(other);
  assert((other as unknown as typeof served).default_rate_options.per_hectare[0].option_key !== served.default_rate_options.per_hectare[0].option_key);
});

Deno.test("found product without vineyard rates stays in the staged response for manual rate review", async () => {
  const candidate = { name: "Seaweed input", brand: "Maker", activeIngredient: "", product_category: "biostimulant", source: "research" as const };
  const detail = { product_name: candidate.name, product_category: "biostimulant", registered_uses: [], registration: { country_code: "ZA", scheme: null, registration_number: null } };
  const result = await withWebEnrichment([candidate], 1, async () => ({ candidates: [candidate], detail }));
  assertEquals(result.detail, detail);
});

Deno.test("manufacturer URL discovery timeout makes one low-effort Terra call, never Sol", async () => {
  let calls = 0;
  const identity: WebIdentity = { name: "CropSure Beast 200 Herbicide", registrant: "CROPSURE PTY LTD",
    registrationNumber: "90143", category: "herbicide", activeNames: "", pageUrls: [], labelUrls: [] };
  const result = await discoverManufacturerUrls({ identity, query: "Beast", country: "AU", apiKey: "test", timeoutMs: 4,
    fetchFn: (async (_url, init) => {
      calls++;
      const options = init as { body?: BodyInit; signal?: AbortSignal };
      const body = JSON.parse(String(options?.body));
      assertEquals(body.model, "gpt-5.6-terra");
      assertEquals(body.reasoning.effort, "low");
      assertEquals(body.text.format.name, "manufacturer_urls");
      assertEquals(body.input.includes("CropSure Beast 200 Herbicide"), true);
      assertEquals(body.input.includes("registration: 90143"), true);
      return await new Promise<Response>((_resolve, reject) => {
        options?.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
      });
    }) as typeof fetch,
  });
  assertEquals(result, null);
  assertEquals(calls, 1);
  const candidate = identityCandidate(identity);
  assertEquals(await withWebEnrichment([candidate], 4, async () => null), {
    candidates: [candidate], detail: null, timings: { search_ms: 4, extraction_ms: 0 },
  });
});

Deno.test("known manufacturer domains and unknown matching registrants are leads, never reseller/regulator evidence", async () => {
  const cases = [
    ["Nufarm Weedmaster DUO Herbicide", "Nufarm", "https://nufarm.com/au/product/weedmaster-duo/"],
    ["Farmalinx Chlorostar 900 WG Herbicide", "Farmalinx", "https://farmalinx.com.au/products/chlorostar-900-wg/"],
    ["Katana 250 WG Herbicide", "AgNova", "https://agnova.com.au/products/katana-250-wg/"],
    ["Simanex 900 WG Herbicide", "ADAMA", "https://adama.com/australia/en/products/simanex-900-wg/"],
    ["Conquest Example Herbicide", "Conquest Agriculture", "https://conquestag.com.au/products/example/"],
    ["Unlisted Example Herbicide", "Unlisted Crop Pty Ltd", "https://unlistedcrop.com.au/products/example/"],
  ];
  for (const [name, registrant, url] of cases) {
    const identity: WebIdentity = { name, registrant, registrationNumber: "12345", category: "herbicide",
      activeNames: "Example active", pageUrls: [], labelUrls: [] };
    assertEquals(manufacturerHostEligible(url, "AU", registrant), true, name);
    const searched = await discoverManufacturerUrlsDetailed({ identity, query: name, country: "AU", apiKey: "test",
      fetchFn: (async () => new Response(JSON.stringify({ output: [
        { type: "web_search_call", action: { sources: [{ url }] } },
        { type: "message", content: [{ type: "output_text", text: JSON.stringify({ product_url: url, label_url: null }) }] },
      ] }), { status: 200 })) as typeof fetch });
    assertEquals(searched.leads?.productUrl, url, name);
    assertEquals(searched.leads?.labelUrl, null);
  }
  assertEquals(classifyUrl(cases[5][2], "AU").trust, "unknown");
  assertEquals(manufacturerHostEligible("https://files.unlistedcrop.com.au/label.pdf", "AU", "Unlisted Crop Pty Ltd"), true);
  for (const url of ["https://elders.com.au/products/example/", "https://elabels.apvma.gov.au/12345.pdf",
    "https://random-reseller.com.au/products/example/", "https://unlistedcrop.evil.com/products/example/"]) {
    assertEquals(manufacturerHostEligible(url, "AU", "Unlisted Crop Pty Ltd"), false);
  }
});

Deno.test("known exact UPL page outranks a model-selected reseller", async () => {
  const official = "https://www.uplcorp.com/au/product-details/affix-250-sc";
  const reseller = "https://elders.com.au/products/affix-250-sc";
  const identity: WebIdentity = { name: "AFFIX 250 SC FUNGICIDE", registrant: "UPL Australia",
    registrationNumber: "99999", category: "fungicide", activeNames: "", pageUrls: [], labelUrls: [] };
  const result = await discoverManufacturerUrlsDetailed({ identity, query: identity.name, country: "AU", apiKey: "test",
    fetchFn: (async () => new Response(JSON.stringify({ output: [
      { type: "web_search_call", action: { sources: [{ url: reseller }, { url: official }] } },
      { type: "message", content: [{ type: "output_text", text: JSON.stringify({ product_url: reseller, label_url: null }) }] },
    ] }), { status: 200 })) as typeof fetch });
  assertEquals(result.leads?.productUrl, official);
});

Deno.test("one exact site-bound search permits only a direct manufacturer label PDF", async () => {
  const page = "https://www.nufarm.com.au/products/weedmaster-duo/";
  const pdf = "https://www.nufarm.com.au/labels/weedmaster-duo-label.pdf";
  const identity: WebIdentity = { name: "Nufarm Weedmaster DUO Herbicide", registrant: "Nufarm",
    registrationNumber: "12345", category: "herbicide", activeNames: "Glyphosate", pageUrls: [], labelUrls: [] };
  let calls = 0;
  const run = async (url: string) => discoverManufacturerUrlsDetailed({ identity, query: identity.name, country: "AU",
    apiKey: "test", fallbackHost: "nufarm.com.au", fetchFn: (async (_endpoint, init) => {
      calls++;
      const body = JSON.parse(String((init as { body?: BodyInit })?.body));
      assert(body.input.includes("site:nufarm.com.au label PDF only"));
      return new Response(JSON.stringify({ output: [
        { type: "web_search_call", action: { sources: [{ url }, { url: page }] } },
        { type: "message", content: [{ type: "output_text", text: JSON.stringify({ product_url: page, label_url: url }) }] },
      ] }), { status: 200 });
    }) as typeof fetch });
  assertEquals((await run(pdf)).leads, { productUrl: null, labelUrl: pdf });
  assertEquals((await run("https://elders.com.au/labels/weedmaster-duo-label.pdf")).leads, null);
  assertEquals(calls, 2);
});

Deno.test("failed direct SIMANEX PDF search excludes the original and rejects reseller or extensionless media", async () => {
  const failed = "https://www.adama.com/labels/simanex-old-label.pdf";
  const alternate = "https://www.adama.com/labels/simanex-900-wg-label.pdf";
  const identity: WebIdentity = { name: "SIMANEX 900 WG HERBICIDE", registrant: "ADAMA AUSTRALIA PTY LIMITED",
    registrationNumber: "62917", category: "herbicide", activeNames: "simazine", pageUrls: [], labelUrls: [] };
  for (const [candidate, expected] of [
    [failed, null], [failed + "?download=1", null],
    ["https://elders.com.au/labels/simanex-900-wg-label.pdf", null],
    ["https://portal.apvma.gov.au/labels/simanex-900-wg-label.pdf", null],
    ["http://www.adama.com/labels/simanex-900-wg-label.pdf", null],
    ["https://www.adama.com/australia/en/media/9096/download?attachment=", null], [alternate, alternate],
  ] as const) {
    const found = await discoverManufacturerUrlsDetailed({ identity, query: identity.name, country: "AU", apiKey: "test",
      fallbackHost: "adama.com", excludeUrl: failed, fetchFn: (async (_endpoint, init) => {
        const body = JSON.parse(String((init as { body?: BodyInit } | undefined)?.body));
        assert(body.input.includes("62917") && body.input.includes("simazine") && body.input.includes("site:adama.com"));
        return new Response(JSON.stringify({ output: [
          { type: "web_search_call", action: { sources: [{ url: candidate }] } },
          { type: "message", content: [{ type: "output_text", text: JSON.stringify({ product_url: null, label_url: candidate }) }] },
        ] }), { status: 200 });
      }) as typeof fetch });
    assertEquals(found.leads?.labelUrl ?? null, expected);
  }
});

Deno.test("Katana stored manufacturer label survives variable web search, without a second discovery call", async () => {
  const labelUrl = "https://agnova.com.au/labels/katana-250-wg-label.pdf";
  const identity: WebIdentity = { name: "Katana 250 WG Herbicide", registrant: "AgNova",
    registrationNumber: "12345", category: "herbicide", activeNames: "Example active", pageUrls: [],
    labelUrls: manufacturerUrlsFromMaster({ registrant: "AgNova", verification_sources: [
      { kind: "manufacturer_label", reference: labelUrl }] }, "AU").labels };
  assertEquals(identity.labelUrls, [labelUrl]);
  const select = async (search: () => Promise<unknown>) => identity.labelUrls[0] ?? await search();
  let searches = 0;
  for (const _variant of [null, "https://reseller.example/katana.pdf"]) {
    const found = await select(() => { searches++; return Promise.resolve(_variant); });
    assertEquals(found, labelUrl);
  }
  assertEquals(searches, 0);
});

Deno.test("unlisted registrant product page supplies own-host label link absent from search results", async () => {
  const page = "https://unlistedcrop.com.au/products/example/";
  const labelUrl = "https://unlistedcrop.com.au/files/12345.pdf";
  const identity: WebIdentity = { name: "Unlisted Example Herbicide", registrant: "Unlisted Crop Pty Ltd",
    registrationNumber: "12345", category: "herbicide", activeNames: "Example active", pageUrls: [], labelUrls: [] };
  const inspected = await inspectCandidateProductPages({ fetchFn: (async () => new Response(
    `<html><title>Unlisted Example Herbicide</title><h1>Unlisted Example Herbicide</h1><a href="${labelUrl}">Download Product Label</a></html>`,
    { status: 200, headers: { "Content-Type": "text/html" } })) as typeof fetch }, [page], "AU");
  assertEquals(inspected.pages.length, 1);
  const projected = projectResearch(identityResearch(identity, identity.name, "AU", { productUrl: page, labelUrl: null }),
    "AU", null, identity.name, inspected.pages);
  assertEquals(projected.manufacturerLabelCandidate?.url, labelUrl);
  assertEquals(classifyUrl(labelUrl, "AU").trust, "unknown");
});

Deno.test("Beast manufacturer PDF fixture verifies identity and prints 1–5 L/ha without AI", async () => {
  const bytes = await Deno.readFile(new URL("./ingestion/beast_label_fixture.pdf", import.meta.url));
  const result = await enrichFromManufacturerLabel({
    deps: { fetchFn: (async () => new Response(bytes, { status: 200, headers: { "Content-Type": "application/pdf" } })) as typeof fetch,
      now: () => new Date() },
    manufacturerLabelUrl: label, sourcePageUrl: label, regulatorUses: [], registeredProductName: "CropSure Beast 200 Herbicide",
    product: { country: "AU", scheme: "apvma", registration_number: "90143" },
  });
  assertEquals(readableV2Label(result), label);
  assert(result.labelText?.includes("Vineyards"));
  const facts = labelHeaderFacts(result.labelText ?? "");
  assertEquals(authoritativeGroup("Glufosinate-ammonium")?.code, "10");
  assertEquals(facts.active?.concentration, 200);
  assertEquals(facts.group, { scheme: "hrac", code: "10" });
  assertEquals(resistanceClassificationState([{ activity_group: authoritativeGroup(facts.active?.name ?? "") }]), "classified");
  assertEquals(selectLabelReferences({ manufacturerLabelUrl: label, regulatorLabelUrl: label }), {
    manufacturer_label_url: label, regulator_label_url: null, manufacturer_product_url: null,
    sds_url: null, label_reference: label,
  });
  const row = vineyardTableRate(result.labelText ?? "");
  assert(row);
  const projected = projectGrapevineUses(normaliseRegisteredUses([row]));
  assertEquals(projected.registered_for_grapevine, true);
  assertEquals(vineyardRateSummary(projected.grapevine_uses).map(({ basis, unit, min_value, max_value }) =>
    ({ basis, unit, min_value, max_value })), [{ basis: "per_hectare", unit: "L", min_value: 1, max_value: 5 }]);
  const research = identityResearch({ name: "CropSure Beast 200 Herbicide", registrant: "CROPSURE PTY LTD",
    registrationNumber: "90143", category: "herbicide", activeNames: "", pageUrls: [], labelUrls: [label] }, "Beast", "AU",
    { productUrl: null, labelUrl: label });
  assertEquals(research.documents.official_label_candidates[0].url, label);
});
