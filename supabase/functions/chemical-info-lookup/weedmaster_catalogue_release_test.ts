// deno-lint-ignore-file no-explicit-any require-await
import { assert, assertEquals } from "jsr:@std/assert";
import {
  buildMasterStructuredResponse, fetchApprovedMaster, masterHasCompleteVineyardData,
  resolveMasterLabelEvidence, searchMaster,
} from "./ingestion/master_lookup.ts";
import { applyDefaultRateOptions } from "./default_rate_options.ts";
import { validateDefaultRates } from "./default_rates.ts";

// Local revision-2 SHAPE, not a live DB export or a real reviewer attestation.
// Reuse the retained serialized directions; never re-extract/apply the PDF.
const retained = JSON.parse(await Deno.readTextFile(new URL(
  "../../../docs/weedmaster-acceptance/synthetic_review_simulation.json", import.meta.url,
)));
const label = retained.proposed_patch.verification_sources[0].reference;
const phalarisRateId = "rate_v1_4efec198ead373a3286939ced245fadf";
const phalarisDirectionId = "direction_v1_1363f3205ca7b639cd5f970a03d91785";
function revisionTwo(status = "candidate"): any {
  return structuredClone({
    ...retained.proposed_patch,
    id: "03dfb9e8-6592-4746-a3bc-295890d32cd1",
    registration_country: "AU", registration_scheme: "apvma", registration_number: "53576",
    registration_identity_key: "AU:apvma:53576", catalogue_version: 2,
    registered_product_name: "Nufarm Weedmaster DUO Herbicide", registrant: "NUFARM AUSTRALIA LIMITED",
    common_names: [], product_category: "herbicide", form_type: "liquid",
    review_status: status, verification_status: "partially_verified", source_kind: "official_register",
    source_reference: "pubcris:53576", verification_conflicts: [], verified_at: null,
    label_reference: null, regulator_label_url: "", manufacturer_label_url: null,
    // Deliberately distinct, unknown register metadata; do not infer equivalence to the PDF.
    label_version: "stored-register-version-fixture", activity_group_table_version: 1,
    intelligence_schema_version: 1,
  });
}

function assertCustomerContract(served: any, row: any): void {
  assertEquals(served.match_source, "master");
  assertEquals(served.master.master_chemical_id, row.id);
  assertEquals(served.master.master_revision, 2);
  assertEquals(served.master.registration_identity_key, "AU:apvma:53576");
  assertEquals(served.verification.status, "partially_verified");
  assertEquals(served.verification.sources, row.verification_sources);
  assertEquals(served.verification.conflicts, row.verification_conflicts);
  assertEquals(served.verification.unresolved_fields, row.verification_unresolved_fields);
  assertEquals(served.registered_uses, row.registered_uses);
  assertEquals(served.viticulture_rates, row.viticulture_rates);
  assertEquals(served.label_urls.manufacturer_label_url, label);
  assertEquals(served.label_urls.regulator_label_url, null);
  assertEquals(served.registration.label_reference, label);
  assertEquals(served.field_provenance.label_reference, "master_catalogue");
  assertEquals(served.registration.label_version, null);
  assertEquals(served.registration.stored_register_label_version, row.label_version);
  assertEquals(served.label_evidence.stored_register_metadata.label_version, row.label_version);
  assertEquals(served.registration.label_version_reference, null);
  assertEquals(served.registration.manufacturer_label_version, "08-09-2022");
  assertEquals(served.label_evidence.same_label_version_established, false);
  assertEquals(served.label_evidence.reviewed_manufacturer_document, row.verification_sources[0]);
  const options = served.default_rate_options;
  assert(options.per_hectare.length > 0 && options.per_100_litres.length > 0);
  const phalaris = options.per_100_litres.filter((option: any) => option.rate_ids.includes(phalarisRateId));
  assertEquals(phalaris.length, 1);
  assertEquals([phalaris[0].basis, phalaris[0].value, phalaris[0].min_value,
    phalaris[0].max_value, phalaris[0].unit], ["per_100_litres", null, 500, 1000, "mL"]);
  assert(phalaris[0].direction_ids.includes(phalarisDirectionId));
  assert(phalaris[0].targets.includes("Phalaris"));
  assert(phalaris[0].conditions.includes("Handgun"));
  const all = [...options.per_hectare, ...options.per_100_litres];
  const supportedIds = new Set(row.registered_uses.flatMap((use: any) =>
    use.rates.filter((rate: any) => ["per_hectare", "range_per_hectare", "per_100_litres", "range_per_100_litres"]
      .includes(rate.basis)).map((rate: any) => rate.rate_id)));
  for (const option of all) {
    assert(option.rate_ids.every((id: string) => supportedIds.has(id)));
    assert(!option.conditions.some((condition: string) => /Knapsack|Wiper|Controlled droplet|Cut stump|LOW VOLUME/i.test(condition)));
    assert(!option.targets.some((target: string) => /Paspalum|Cumbungi|Ludwigia|Phragmites/i.test(target)));
  }
  const choice = { ...phalaris[0], source: "operator" };
  const validated = validateDefaultRates({ version: 1, per_hectare: null, per_100_litres: choice });
  assertEquals(validated.violations, []);
  assertEquals(validated.value?.per_100_litres?.rate_ids, phalaris[0].rate_ids);
}

Deno.test("Weedmaster release: retained manufacturer evidence satisfies readiness and full customer contract", () => {
  const row = revisionTwo();
  const before = structuredClone(row);
  assert(masterHasCompleteVineyardData(row));
  const served = buildMasterStructuredResponse(row);
  assertEquals(applyDefaultRateOptions(served), []);
  assertCustomerContract(JSON.parse(JSON.stringify(served)), row);
  assertEquals(row, before, "serving must never rewrite the stored row");
});

Deno.test("Weedmaster release: untrusted, SDS, product and mismatched visual sources cannot satisfy readiness", () => {
  for (const reference of [
    "https://random-reseller.com.au/weedmaster-label.pdf",
    "https://elabels.apvma.gov.au/53576ELBL.pdf",
    "https://cdn.nufarm.com/weedmaster-sds.pdf",
    "https://nufarm.com/au/product/weedmaster-duo/",
    "http://cdn.nufarm.com/weedmaster-label.pdf",
  ]) {
    const row = revisionTwo();
    row.verification_sources = [{ kind: "manufacturer_label", reference }];
    assertEquals(masterHasCompleteVineyardData(row), false, reference);
    assertEquals(buildMasterStructuredResponse(row).label_urls.manufacturer_label_url, null);
  }
  for (const change of [{ source_url: `${label}?different` }, { document_sha256: "bad" },
    { reviewed_by: "" }, { reviewed_at: "bad" }, { method: "ai_transcription" }]) {
    const row = revisionTwo();
    Object.assign(row.verification_sources[0].reviewed_visual_declaration, change);
    assertEquals(masterHasCompleteVineyardData(row), false);
  }
});

Deno.test("Weedmaster release: retained warnings are not missing-rate gates; real rate gaps still block", () => {
  const row = revisionTwo();
  assertEquals(row.verification_unresolved_fields.length, 11);
  assert(masterHasCompleteVineyardData(row));
  row.verification_unresolved_fields.push("RATES:GRAPEVINE:Phalaris");
  assertEquals(masterHasCompleteVineyardData(row), false);
  const missingIdentity = revisionTwo();
  delete missingIdentity.registered_uses.find((use: any) => use.target_raw === "Phalaris")
    .rates.find((rate: any) => rate.label === "Handgun").rate_id;
  assertEquals(masterHasCompleteVineyardData(missingIdentity), false);
});

Deno.test("Weedmaster release: top-level and legacy links remain compatible; versions are never merged", () => {
  const row = revisionTwo();
  row.regulator_label_url = "https://elabels.apvma.gov.au/53576ELBL.pdf";
  const refs = resolveMasterLabelEvidence(row).references;
  assertEquals(refs.manufacturer_label_url, label);
  assertEquals(refs.regulator_label_url, row.regulator_label_url);
  assertEquals(refs.label_reference, row.regulator_label_url);
  row.regulator_label_url = null;
  row.label_reference = label;
  row.verification_sources = [];
  assert(masterHasCompleteVineyardData(row));
  assertEquals(resolveMasterLabelEvidence(row).references.manufacturer_label_url, label);
  assertEquals(buildMasterStructuredResponse(row).registration.manufacturer_label_version, null);
});

Deno.test("Weedmaster release: candidate is not a customer-approved catalogue hit; approval is a separate decision", async () => {
  const row = revisionTwo();
  const queries: string[] = [];
  const select = async (query: string): Promise<any[]> => {
    queries.push(query);
    assert(query.includes("review_status=eq.approved"));
    return row.review_status === "approved" ? [row] : [];
  };
  assertEquals(await fetchApprovedMaster(select, row.registered_product_name, "AU", "53576", "apvma"), null);
  assertEquals(await searchMaster(select, "Weedmaster", "AU"), []);
  row.review_status = "approved"; // hypothetical local approval, never a production write
  const hits = await searchMaster(select, "Weedmaster", "AU");
  assertEquals(hits[0].registration_number, "53576");
  assertEquals(hits[0].master_chemical_id, row.id);
  assertEquals((await fetchApprovedMaster(select, hits[0].name, "AU", "53576", "apvma"))?.id, row.id);
  assert(queries.length > 0);
});

Deno.test("Weedmaster release: real structured handler serves hypothetical approved revision 2 with only one mocked Master read", async () => {
  const row = revisionTwo("approved");
  const before = structuredClone(row);
  type Handler = (request: Request) => Promise<Response>;
  let captured: Handler | null = null;
  const originalServe = Deno.serve;
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  try {
    // No actual environment secrets, servers, network or writes are used.
    Deno.env.get = (key: string) => ({ SUPABASE_URL: "https://catalogue.test",
      SUPABASE_SERVICE_ROLE_KEY: "mock-only", OPENAI_API_KEY: "mock-only" } as Record<string, string>)[key];
    Deno.serve = ((handler: Handler) => { captured = handler; return {}; }) as unknown as typeof Deno.serve;
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      requests.push(url.href);
      assertEquals(init?.method ?? "GET", "GET", "no writes");
      assertEquals(url.origin, "https://catalogue.test", "discovery/enrichment is forbidden");
      assertEquals(url.pathname, "/rest/v1/master_chemicals");
      assertEquals(url.searchParams.get("review_status"), "eq.approved");
      assertEquals(url.searchParams.get("registration_identity_key"), "eq.AU:apvma:53576");
      return new Response(JSON.stringify([row]), { headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    await import("./index.ts");
    const handler = captured as Handler | null;
    assert(handler);
    const response = await handler(new Request("https://function.test/chemical-info-lookup", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ action: "structured", country: "Australia",
        productName: row.registered_product_name, registrationNumber: "53576", registrationScheme: "apvma" }),
    }));
    assertEquals(response.status, 200);
    const served = await response.json();
    assertCustomerContract(served, row);
    assertEquals(requests.length, 1);
    assertEquals(row, before);
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
  }
});
