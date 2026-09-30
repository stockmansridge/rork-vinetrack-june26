// deno-lint-ignore-file no-explicit-any require-await
import { assert, assertEquals } from "jsr:@std/assert";
import {
  buildMasterStructuredResponse, fetchApprovedMaster, masterHasCompleteVineyardData,
  resolveMasterLabelEvidence, searchMaster,
} from "./ingestion/master_lookup.ts";
import { applyDefaultRateOptions } from "./default_rate_options.ts";
import { validateDefaultRates } from "./default_rates.ts";

// Default: complete applied-snapshot derivative with ONLY reviewer identity redacted.
// Optional CLI argument: private, byte-identical actual snapshot. Never re-extract/apply.
const fixturePath = Deno.args[0] ?? new URL(
  "../../../docs/weedmaster-acceptance/revision-2-shared/master-revision-2.sanitized-fixture.json", import.meta.url,
);
const bytes = await Deno.readFile(fixturePath);
const input = JSON.parse(new TextDecoder().decode(bytes));
const retained = input.row ?? input;
if (Deno.args[0]) {
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)))
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
  assertEquals(hash, "6daee0d6d2502a897cac988123ead3f6a1db07ec3f75ad5032be6ed40ac4c3a6");
}
const retainedBefore = structuredClone(retained);
const label = "https://cdn.nufarm.com/wp-content/uploads/sites/22/2018/05/13085258/0533-Nufarm-Weedmaster-DUO-Herbicide.pdf";
const phalarisRateId = "rate_v1_4efec198ead373a3286939ced245fadf";
const phalarisDirectionId = "direction_v1_1363f3205ca7b639cd5f970a03d91785";
function revisionTwo(status = "candidate"): any {
  const clone = structuredClone(retained);
  clone.review_status = status; // the only substitution for the hypothetical approved path
  return clone;
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
  assertEquals(served.label_evidence.reviewed_manufacturer_document, row.verification_sources[6]);
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

Deno.test("Weedmaster release: full actual input keeps source order, counts and flattened identity relationships", () => {
  const row = revisionTwo();
  assertEquals(row.review_status, "candidate");
  assertEquals(row.catalogue_version, 2);
  assertEquals(row.registered_uses.length, 582);
  assertEquals(row.registered_uses.filter((use: any) => use.crop === "Vineyards").length, 70);
  assertEquals(row.verification_sources.length, 7);
  for (const index of [3, 4]) {
    assertEquals(row.verification_sources[index].kind, "manufacturer_label");
    assertEquals(new URL(row.verification_sources[index].reference).hostname, "data.gov.au");
  }
  assertEquals(row.verification_sources[6].reference, label);
  assertEquals(resolveMasterLabelEvidence(row).manufacturerSource, row.verification_sources[6]);
  assertEquals(row.viticulture_rates.per_hectare.length, 66);
  assertEquals(row.viticulture_rates.per_100_litres.length, 71);
  const flat = row.viticulture_rates.per_100_litres.find((rate: any) => rate.rate_id === phalarisRateId);
  assert(!("target_raw" in flat) && !("direction_id" in flat) && !("method" in flat));
  const direction = row.registered_uses.find((use: any) => use.direction_id === phalarisDirectionId);
  assertEquals(direction.rates.find((rate: any) => rate.rate_id === phalarisRateId), flat);
});

Deno.test("Weedmaster release: retained manufacturer evidence satisfies readiness and full customer contract", () => {
  const row = revisionTwo();
  const before = structuredClone(row);
  assert(masterHasCompleteVineyardData(row));
  const served = buildMasterStructuredResponse(row);
  assertEquals(applyDefaultRateOptions(served), []);
  assertCustomerContract(JSON.parse(JSON.stringify(served)), row);
  assertEquals(row, before, "serving must never rewrite the stored row");
});

Deno.test("Weedmaster release: actual canonical option survives persistence JSON and shared read-back, not a Portal UI test", () => {
  const row = revisionTwo();
  const served = buildMasterStructuredResponse(row);
  assertEquals(applyDefaultRateOptions(served), []);
  // Deliberate test choice by persisted identity; never auto-select the first option.
  const option = served.default_rate_options.per_100_litres.find((entry: any) => entry.rate_ids.includes(phalarisRateId));
  assert(option);
  const selection = {
    option_key: option.option_key, rate_ids: option.rate_ids, basis: option.basis,
    unit: option.unit, value: option.value, min_value: option.min_value, max_value: option.max_value,
    source: "operator" as const, selected_at: null, label_version: served.registration.manufacturer_label_version,
  };
  const payload = {
    master_chemical_id: row.id, master_source_revision: row.catalogue_version,
    default_rates: { version: 1 as const, per_hectare: null, per_100_litres: selection },
  };
  const readBack = validateDefaultRates(JSON.parse(JSON.stringify(payload)).default_rates);
  assertEquals(readBack.violations, []);
  assertEquals(readBack.value, payload.default_rates);
  const supportingDirections = row.registered_uses.filter((use: any) =>
    use.rates.some((rate: any) => readBack.value?.per_100_litres?.rate_ids.includes(rate.rate_id)));
  assertEquals(supportingDirections.map((use: any) => use.direction_id).sort(), option.direction_ids);
  const actualPhalaris = supportingDirections.find((use: any) => use.direction_id === phalarisDirectionId);
  assertEquals(actualPhalaris, retained.registered_uses.find((use: any) => use.direction_id === phalarisDirectionId));
  assertEquals(option.conditions, ["Handgun"]);
  assertEquals(validateDefaultRates({ ...payload.default_rates,
    per_100_litres: { ...selection, rate_ids: [] } }).violations[0].code, "rate_ids_missing");
  assertEquals(validateDefaultRates({ ...payload.default_rates,
    per_100_litres: { ...selection, source: "manual" } }).violations[0].code, "source_unrecognised");
  console.log(JSON.stringify({ basis_option_counts: {
    per_hectare: served.default_rate_options.per_hectare.length,
    per_100_litres: served.default_rate_options.per_100_litres.length }, option, payload,
    shared_read_back_violations: readBack.violations, portal_path_executed: false }));
  assertEquals(retained, retainedBefore);
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
    Object.assign(row.verification_sources[6].reviewed_visual_declaration, change);
    assertEquals(masterHasCompleteVineyardData(row), false);
  }
});

Deno.test("Weedmaster release: retained warnings are not missing-rate gates; real rate gaps still block", () => {
  const row = revisionTwo();
  assertEquals(row.verification_unresolved_fields.length, 32);
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
    assertEquals(retained, retainedBefore);
    assertEquals(retained.review_status, "candidate");
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
  }
});
