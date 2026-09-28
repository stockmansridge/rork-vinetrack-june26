// deno-lint-ignore-file no-import-prefix
import { assert, assertEquals } from "jsr:@std/assert@1";
import { distinctLabelDocument, finalAttemptedLabelUrl, MANUFACTURER_INDEX_TIMEOUT_MS, readManufacturerLabelViaWebIndex, shouldReadManufacturerIndex, type IndexFailureReason } from "./manufacturer_label_index.ts";
import { cloneResearch, responsesEnvelope } from "../research/test_fixtures.ts";
import { normaliseRegisteredUses } from "../registered_use_normaliser.ts";
import { applyRateIdentities, stripStructuredDirectionSeeds } from "../rate_identity.ts";
import { finishBackfillPreview } from "./master_backfill_preview.ts";
import { enrichFromManufacturerLabel } from "./manufacturer_enrichment.ts";
import type { MasterRow } from "./contract.ts";

const url = "https://www.adama.com/australia/sites/adama_australia/files/product-documents/2025-01/10150_Adama_Simanex_A4xWebLabel_F_0.pdf";
const originalUrl = "https://www.adama.com/australia/sites/adama_australia/files/product-documents/2024-12/10150_Adama_Simanex_A4xWebLabel_F_MOA_Contents.pdf";
const locked = { name: "SIMANEX 900 WG HERBICIDE", registrant: "ADAMA AUSTRALIA PTY LIMITED",
  registrationNumber: "62917", activeIngredients: [{ name: "simazine", concentration: 900, concentration_unit: "g/kg" }],
  labelUrl: url, country: "AU", apiKey: "test" };

function indexedResponse(changes?: (research: ReturnType<typeof cloneResearch>) => void, source = url, documentUrl = url,
  actions?: Record<string, unknown>[]) {
  const research = cloneResearch();
  research.product = { ...research.product, searched_name: locked.name, canonical_name: locked.name,
    registrant: locked.registrant, source_refs: [documentUrl] };
  research.registration_candidates = [{ scheme: "apvma", number: "62917/107619", registered_product_name: locked.name,
    country: "AU", source_url: documentUrl, source_domain: "www.adama.com", confidence: "high", reason: "Printed label approval" }];
  research.active_ingredients = [{ ...research.active_ingredients[0], name: "simazine", concentration: 900,
    concentration_unit: "g/kg", source_refs: [documentUrl] }];
  const entries: Array<[string, string, number, string, string, string]> = [
    ["Qld", "light", 2, "kg", "ha", "Use only if vines are at least two years old."],
    ["Qld", "heavy", 4, "kg", "ha", "Use only if vines are at least two years old."],
    ["NSW, Vic, SA, Tas, WA", "light", 1.25, "kg", "ha", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
    ["NSW, Vic, SA, Tas, WA", "light", 60, "g", "100 L", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
    ["NSW, Vic, SA, Tas, WA", "heavy", 2.5, "kg", "ha", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
    ["NSW, Vic, SA, Tas, WA", "heavy", 120, "g", "100 L", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
  ];
  research.registered_uses = entries.map(([states, soil, value, unit, basis, comment]) => ({
    crop: "Grapevines", targets: ["Weeds"], whp: null, rei: null, restrictions: [comment], source_refs: [documentUrl],
    rates: [{ label: `State: ${states}; Soil: ${soil}`, basis: basis === "ha" ? "per_hectare" : "per_100_litres",
      value, min_value: null, max_value: null, unit, raw_text: `${value} ${unit}/${basis}`, source_refs: [documentUrl] }],
  }));
  changes?.(research);
  const payload = responsesEnvelope(research) as Record<string, unknown>;
  payload.output = [
    ...(actions ?? [{ type: "search", sources: [{ url: source }] }]).map((action) => ({ type: "web_search_call", action })),
    { type: "message", content: [{ type: "output_text", text: JSON.stringify(research) }] },
  ];
  return new Response(JSON.stringify(payload), { status: 200 });
}

function fetchFor(response: Response, onRequest?: (body: Record<string, unknown>) => void): typeof fetch {
  return ((_url, init) => { onRequest?.(JSON.parse(String((init as { body?: BodyInit } | undefined)?.body)));
    return Promise.resolve(response); }) as typeof fetch;
}

Deno.test("only 403/429 failed verified fetches with no successful alternate reach the index", () => {
  assertEquals(shouldReadManufacturerIndex(403, false), true);
  assertEquals(shouldReadManufacturerIndex(429, false), true);
  for (const code of [200, 404, 500, null]) assertEquals(shouldReadManufacturerIndex(code, false), false);
  assertEquals(shouldReadManufacturerIndex(403, true), false);
});

Deno.test("two access-denied ADAMA PDFs index only the final attempted alternate and retain its provenance", async () => {
  const attempted: string[] = [];
  const deniedFetch = ((request: string | URL | Request) => {
    attempted.push(String(request));
    return Promise.resolve(new Response("", { status: 403 }));
  }) as typeof fetch;
  const original = await enrichFromManufacturerLabel({ deps: { fetchFn: deniedFetch, now: () => new Date() },
    manufacturerLabelUrl: originalUrl, sourcePageUrl: originalUrl, regulatorUses: [], registeredProductName: locked.name });
  const alternate = await enrichFromManufacturerLabel({ deps: { fetchFn: deniedFetch, now: () => new Date() },
    manufacturerLabelUrl: url, sourcePageUrl: url, regulatorUses: [], registeredProductName: locked.name });
  assertEquals(attempted, [originalUrl, url]);
  assertEquals(original.diagnostics.manufacturer_label_http_status, 403);
  assertEquals(alternate.diagnostics.manufacturer_label_http_status, 403);
  assertEquals(shouldReadManufacturerIndex(original.diagnostics.manufacturer_label_http_status, false), true);
  const indexedLabelUrl = finalAttemptedLabelUrl(originalUrl, url, true);
  assertEquals(indexedLabelUrl, url);
  assertEquals(finalAttemptedLabelUrl(originalUrl, url, false), originalUrl);
  assertEquals(distinctLabelDocument(originalUrl, url), true);
  assertEquals(distinctLabelDocument(originalUrl, `${originalUrl}?download=1`), false);
  const result = await readManufacturerLabelViaWebIndex({ ...locked, labelUrl: indexedLabelUrl,
    fetchFn: fetchFor(indexedResponse(undefined, url, indexedLabelUrl), (body) => {
      assert(String(body.instructions).includes(indexedLabelUrl));
      assert(!String(body.instructions).includes(originalUrl));
    }) });
  assertEquals(result.status, "ready");
  if (result.status !== "ready") return;
  assertEquals(result.uses.length, 6);
  assertEquals(result.uses.map((use) => use.source_refs), Array(6).fill([url]));
  assertEquals(result.uses.map((use) => (use.rates as Array<{ source_refs: string[] }>)[0].source_refs), Array(6).fill([url]));
  const uses = normaliseRegisteredUses(result.uses);
  const row: MasterRow = { id: "10000000-0000-4000-8000-000000000629", registration_country: "AU",
    registration_scheme: "apvma", registration_number: "62917", registration_identity_key: "AU:apvma:62917",
    registered_product_name: locked.name, registrant: locked.registrant, common_names: [], product_category: "herbicide",
    form_type: "solid", active_ingredients: locked.activeIngredients, activity_groups: [], activity_group_scheme: null,
    resistance_classification_state: "unresolved", registered_uses: [], label_rate_bases: [], label_reference: null,
    label_version: null, verification_status: "partially_verified", verification_sources: [],
    verification_conflicts: [], verification_unresolved_fields: [], verified_at: null,
    source_kind: "official_register", source_reference: "pubcris:62917", retrieved_at: null,
    review_status: "approved", catalogue_version: 1, activity_group_table_version: 1, intelligence_schema_version: 1 };
  const detail = { registration: { country_code: "AU", scheme: "apvma", registration_number: "62917", registrant: locked.registrant,
    manufacturer_label_url: indexedLabelUrl, manufacturer_label_verified: true,
    manufacturer_label_retrieval_method: "web_search_index" as const, manufacturer_label_identifiers: result.identifiers },
    active_ingredients: result.actives, registered_uses: uses };
  applyRateIdentities(detail);
  stripStructuredDirectionSeeds(detail);
  const preview = await finishBackfillPreview(row, "admin", { detail }, true,
    { insertPreview: () => { throw Error("dry-run must not write"); } });
  assertEquals(preview.status, "preview_ready", JSON.stringify(preview.evidence));
  assertEquals((preview.proposed_patch?.verification_sources as Array<{ reference: string }>)[0].reference, url);
  assertEquals((preview.proposed_patch?.registered_uses as Array<{ source_refs: string[]; rates: Array<{ source_refs: string[] }> }>)
    .flatMap((use) => [use.source_refs[0], ...use.rates.map((rate) => rate.source_refs[0])]).every((ref) => ref === url), true);
  const originalOnly = await readManufacturerLabelViaWebIndex({ ...locked, labelUrl: originalUrl,
    fetchFn: fetchFor(indexedResponse(undefined, url, originalUrl)) });
  assertEquals(originalOnly, { status: "label_index_unavailable", reason: "exact_url_not_consulted" });
  const thirdPdf = url.replace("_0.pdf", "_1.pdf");
  const thirdOnly = await readManufacturerLabelViaWebIndex({ ...locked, labelUrl: indexedLabelUrl,
    fetchFn: fetchFor(indexedResponse(undefined, thirdPdf, thirdPdf)) });
  assertEquals(thirdOnly, { status: "label_index_unavailable", reason: "exact_url_not_consulted" });
});

Deno.test("indexed SIMANEX requires exact PDF in search, open_page, find_in_page or citation evidence", async () => {
  const productPage = "https://www.adama.com/australia/en/crop-protection/simanex";
  const search = { type: "search", sources: [{ url: productPage }] };
  const read = (actions: Record<string, unknown>[]) => readManufacturerLabelViaWebIndex({ ...locked,
    fetchFn: fetchFor(indexedResponse(undefined, productPage, url, actions)) });
  // The model's source_refs alone do not establish consultation of the PDF.
  assertEquals(await read([search]), { status: "label_index_unavailable", reason: "exact_url_not_consulted" });
  for (const actionType of ["open_page", "find_in_page"]) {
    const accepted = await read([search, { type: actionType, url }]);
    assertEquals(accepted.status, "ready", actionType);
    if (accepted.status === "ready") {
      assertEquals(accepted.uses.length, 6);
      assertEquals(accepted.uses.every((use) => (use.source_refs as string[])[0] === url), true);
    }
    for (const other of [url.replace("_0.pdf", "_1.pdf"), `${url}?download=1`,
      "https://elders.com.au/simanex.pdf", "https://portal.apvma.gov.au/simanex.pdf"]) {
      assertEquals(await read([search, { type: actionType, url: other }]),
        { status: "label_index_unavailable", reason: "exact_url_not_consulted" });
    }
    assertEquals(await read([search, { type: actionType, url: url.replace("https:", "http:") }]),
      { status: "label_index_unavailable", reason: "exact_url_not_consulted" });
  }
});

Deno.test("manufacturer index uses one bounded 60-second Responses attempt and fixed transport categories", async () => {
  assertEquals(MANUFACTURER_INDEX_TIMEOUT_MS, 60_000);
  const cases: Array<[string, () => Promise<Response>, string]> = [
    ["timeout", () => Promise.reject(new DOMException("sensitive token", "AbortError")), "index_request_timeout"],
    ["transient", () => Promise.resolve(new Response("sensitive token", { status: 429 })), "index_request_transient"],
    ["permanent", () => Promise.resolve(new Response("sensitive token", { status: 401 })), "index_request_permanent"],
    ["refusal", () => Promise.resolve(new Response(JSON.stringify({ output: [{ type: "message",
      content: [{ type: "refusal", refusal: "sensitive token" }] }] }), { status: 200 })), "index_request_refusal"],
    ["malformed", () => Promise.resolve(new Response("sensitive token", { status: 200 })), "malformed_index_result"],
  ];
  for (const [category, respond, reason] of cases) {
    let calls = 0;
    const fetchFn = ((_request: string | URL | Request, init?: RequestInit) => {
      calls++;
      assert(init?.signal instanceof AbortSignal, `${category} must have a bounded abort signal`);
      return respond();
    }) as typeof fetch;
    const result = await readManufacturerLabelViaWebIndex({ ...locked, fetchFn });
    assertEquals(result.status, "label_index_unavailable");
    if (result.status !== "label_index_unavailable") throw Error("unexpected indexed result");
    assertEquals(result.reason, reason);
    assertEquals(calls, 1, `${category} must not retry`);
    assertEquals(JSON.stringify(result).includes("sensitive token"), false);
  }
});

Deno.test("indexed failures expose only fixed, sanitised codes in dry-run evidence", async () => {
  const noEvidence = new Response(JSON.stringify({ ...responsesEnvelope(cloneResearch()),
    output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(cloneResearch()) }] }] }), { status: 200 });
  const result = await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(noEvidence) });
  assertEquals(result, { status: "label_index_unavailable", reason: "no_web_search_evidence" });
  if (result.status !== "label_index_unavailable") return;
  const row: MasterRow = { id: "10000000-0000-4000-8000-000000000629", registration_country: "AU",
    registration_scheme: "apvma", registration_number: "62917", registration_identity_key: "AU:apvma:62917",
    registered_product_name: locked.name, registrant: locked.registrant, common_names: [], product_category: "herbicide",
    form_type: "solid", active_ingredients: locked.activeIngredients, activity_groups: [], activity_group_scheme: null,
    resistance_classification_state: "unresolved", registered_uses: [], label_rate_bases: [], label_reference: null,
    label_version: null, verification_status: "partially_verified", verification_sources: [],
    verification_conflicts: [], verification_unresolved_fields: [], verified_at: null,
    source_kind: "official_register", source_reference: "pubcris:62917", retrieved_at: null,
    review_status: "approved", catalogue_version: 1, activity_group_table_version: 1, intelligence_schema_version: 1 };
  const preview = await finishBackfillPreview(row, "admin", { discovery_reason: `label_index_unavailable: ${result.reason}` }, true,
    { insertPreview: () => { throw Error("failed evidence cannot write"); } });
  assertEquals(preview.status, "manufacturer_label_not_found");
  assertEquals(preview.evidence.reason, "label_index_unavailable: no_web_search_evidence");
});

Deno.test("SIMANEX indexed manufacturer label retains six independent state/soil doses and distinct comments", async () => {
  const result = await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse(), (body) => {
    const tool = (body.tools as Array<Record<string, unknown>>)[0];
    assertEquals(tool.filters, { allowed_domains: ["www.adama.com"] });
    assertEquals(tool.user_location, { type: "approximate", country: "AU" });
    assert(String(body.instructions).includes(url));
    assert(String(body.instructions).includes("Do not use APVMA, regulators, resellers"));
  }) });
  assertEquals(result.status, "ready");
  if (result.status !== "ready") return;
  assertEquals(result.identifiers.printed_values, ["62917/107619"]);
  assertEquals(result.uses.length, 6);
  const uses = normaliseRegisteredUses(result.uses);
  const detail = { registration: { country_code: "AU", scheme: "apvma", registration_number: "62917" }, registered_uses: uses };
  applyRateIdentities(detail);
  stripStructuredDirectionSeeds(detail);
  assertEquals(uses.map((u) => `${u.conditions} | ${u.rates[0].raw_text}`), [
    "State: QLD; Soil: light | 2 kg/ha", "State: QLD; Soil: heavy | 4 kg/ha",
    "State: NSW, VIC, SA, TAS, WA; Soil: light | 1.25 kg/ha",
    "State: NSW, VIC, SA, TAS, WA; Soil: light | 60 g/100 L",
    "State: NSW, VIC, SA, TAS, WA; Soil: heavy | 2.5 kg/ha",
    "State: NSW, VIC, SA, TAS, WA; Soil: heavy | 120 g/100 L",
  ]);
  assertEquals(new Set(uses.map((u) => u.rates[0].rate_id)).size, 6);
  assertEquals(new Set(uses.map((u) => u.direction_id)).size, 4);
  assertEquals(uses.map((u) => u.rates[0].source_refs[0]), Array(6).fill(url));
  assertEquals(uses.map((u) => u.source_refs[0]), Array(6).fill(url));
  assert(uses[0].restrictions.includes("two years"));
  assert(uses[2].restrictions.includes("split applications"));
  assertEquals(JSON.stringify(result).includes("sha256"), false);
  assertEquals(JSON.stringify(result).includes("byte_size"), false);
  const row: MasterRow = { id: "10000000-0000-4000-8000-000000000629", registration_country: "AU",
    registration_scheme: "apvma", registration_number: "62917", registration_identity_key: "AU:apvma:62917",
    registered_product_name: locked.name, registrant: locked.registrant, common_names: [], product_category: "herbicide",
    form_type: "solid", active_ingredients: locked.activeIngredients, activity_groups: [], activity_group_scheme: null,
    resistance_classification_state: "unresolved", registered_uses: [], label_rate_bases: [], label_reference: null,
    label_version: null, verification_status: "partially_verified", verification_sources: [],
    verification_conflicts: [], verification_unresolved_fields: [], verified_at: null,
    source_kind: "official_register", source_reference: "pubcris:62917", retrieved_at: null,
    review_status: "approved", catalogue_version: 1, activity_group_table_version: 1, intelligence_schema_version: 1 };
  let writes = 0;
  const indexedDetail = {
    registration: { registration_number: "62917", registrant: locked.registrant, manufacturer_label_url: url,
      manufacturer_label_verified: true, manufacturer_label_retrieval_method: "web_search_index" as const,
      manufacturer_label_identifiers: result.identifiers }, active_ingredients: result.actives,
    registered_uses: uses,
  };
  const store = { insertPreview: () => { writes++; return Promise.resolve({ id: "not-written" }); } };
  const preview = await finishBackfillPreview(row, "admin", { detail: indexedDetail }, true, store);
  assertEquals(preview.status, "preview_ready");
  assertEquals(preview.findings.vineyard_rates_added, true);
  assertEquals(writes, 0);
  assertEquals((preview.proposed_patch?.registered_uses as Array<{ rates: unknown[] }>).length, 4);
  assertEquals((preview.proposed_patch?.registered_uses as Array<{ rates: unknown[] }>).reduce((n, use) => n + use.rates.length, 0), 6);
  assertEquals((preview.proposed_patch?.verification_sources as Array<Record<string, unknown>>)[0].retrieval_method, "web_search_index");
  assertEquals("sha256" in (preview.proposed_patch ?? {}), false);
  const repeated = await finishBackfillPreview({ ...row, ...preview.proposed_patch } as MasterRow,
    "admin", { detail: indexedDetail }, true, store);
  assertEquals(repeated.status, "no_material_change");
  assertEquals(writes, 0);
});

Deno.test("indexed vineyard-rate failures return only their fixed diagnostic codes", async () => {
  const cases: Array<[IndexFailureReason, (research: ReturnType<typeof cloneResearch>) => void]> = [
    ["rate_no_vineyard_rows", (research) => { research.registered_uses = []; }],
    ["rate_use_source_mismatch", (research) => { research.registered_uses[0].source_refs = []; }],
    ["rate_source_mismatch", (research) => { research.registered_uses[0].rates[0].source_refs = []; }],
    ["rate_value_invalid", (research) => { research.registered_uses[0].rates[0].value = 0; }],
    ["rate_raw_text_missing", (research) => { research.registered_uses[0].rates[0].raw_text = null; }],
    ["rate_basis_unrecognised", (research) => { research.registered_uses[0].rates[0].basis = "other"; }],
    ["rate_unit_unrecognised", (research) => { research.registered_uses[0].rates[0].unit = "litres"; }],
    ["rate_raw_text_mismatch", (research) => { research.registered_uses[0].rates[0].raw_text = "unparseable"; }],
    ["rate_state_soil_missing", (research) => { research.registered_uses[0].rates[0].label = "Soil: light"; }],
    ["simanex_completeness_failed", (research) => { research.registered_uses.pop(); }],
  ];
  for (const [reason, change] of cases) {
    const result = await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse(change)) });
    assertEquals(result, { status: "label_index_unavailable", reason });
  }
  for (const [reason, change] of [
    ["rate_value_invalid", (research: ReturnType<typeof cloneResearch>) => { research.registered_uses[0].rates[0].value = null; }],
    ["rate_raw_text_missing", (research: ReturnType<typeof cloneResearch>) => { research.registered_uses[0].rates[0].raw_text = ""; }],
    ["rate_unit_unrecognised", (research: ReturnType<typeof cloneResearch>) => { research.registered_uses[0].rates[0].unit = null; }],
  ] as const) {
    assertEquals(await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse(change)) }),
      { status: "label_index_unavailable", reason });
  }
});

Deno.test("indexed result cannot substitute reseller, regulator, another PDF, or a query variant", async () => {
  for (const source of ["https://elders.com.au/simanex.pdf", "https://portal.apvma.gov.au/simanex.pdf",
    url.replace("_0.pdf", "_1.pdf"), `${url}?other=1`]) {
    const result = await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse(undefined, source)) });
    assertEquals(result.status, "label_index_unavailable");
  }
  for (const labelUrl of ["https://elders.com.au/simanex-label.pdf", "https://portal.apvma.gov.au/simanex-label.pdf",
    "https://www.adama.com/simanex-sds.pdf", "https://www.adama.com/simanex-brochure.pdf"]) {
    const result = await readManufacturerLabelViaWebIndex({ ...locked, labelUrl, fetchFn: (() => { throw Error("unexpected request"); }) as typeof fetch });
    assertEquals(result.status, "label_index_unavailable");
  }
  assertEquals((await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse(undefined, `${url}#page=2`)) })).status, "ready");
});

Deno.test("indexed label mismatched identity fails closed; unsupported rows never turn into evidence", async () => {
  const changes: Array<(research: ReturnType<typeof cloneResearch>) => void> = [
    (r) => { r.product.canonical_name = "SIMANEX 800 WG HERBICIDE"; },
    (r) => { r.registration_candidates[0].number = "99999/107619"; },
    (r) => { r.active_ingredients[0].name = "atrazine"; },
    (r) => { r.active_ingredients[0].concentration = 800; },
  ];
  for (const change of changes) assertEquals((await readManufacturerLabelViaWebIndex({ ...locked,
    fetchFn: fetchFor(indexedResponse(change)) })).status, "identity_conflict");
  assertEquals((await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse((r) => {
    r.registered_uses[0].rates[0].source_refs = ["https://elders.com.au/simanex.pdf"];
  })) })).status, "label_index_unavailable");
  assertEquals((await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse((r) => {
    r.registered_uses.pop();
  })) })).status, "label_index_unavailable");
  assertEquals((await readManufacturerLabelViaWebIndex({ ...locked, fetchFn: fetchFor(indexedResponse((r) => {
    r.registered_uses[0].rates[0].label = "Soil: light";
  })) })).status, "label_index_unavailable");
});
