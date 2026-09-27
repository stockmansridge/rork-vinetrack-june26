import { assertEquals, assert } from "jsr:@std/assert";
import { discoverManufacturerUrls, findWebMasterIdentities, identityCandidate, identityResearch, manufacturerUrlsFromMaster, selectedIdentity, verifiedManufacturerLead, type WebIdentity } from "./web_identity.ts";
import { withWebEnrichment, vineyardTableRate, vineyardRateSummary, readableV2Label, labelHeaderFacts } from "./web_lookup.ts";
import { authoritativeGroup, resistanceClassificationState } from "./ingestion/activity_groups.ts";
import { selectLabelReferences } from "./grapevine_label.ts";
import { enrichFromManufacturerLabel } from "./ingestion/manufacturer_enrichment.ts";
import { normaliseRegisteredUses } from "./registered_use_normaliser.ts";
import { projectGrapevineUses } from "./grapevine_label.ts";

const label = "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf";
const master = {
  registered_product_name: "CropSure Beast 200 Herbicide", registrant: "CROPSURE PTY LTD",
  registration_country: "AU", registration_scheme: "apvma", registration_number: "90143",
  review_status: "candidate", verification_status: "partially_verified", source_kind: "official_register",
  product_category: "herbicide", active_ingredients: [], registered_uses: Array(512).fill({ crop: "Wheat" }),
  viticulture_rates: { per_hectare: [], per_100_litres: [] },
  verification_sources: [
    { kind: "official_register", reference: "https://portal.apvma.gov.au/pubcris" },
    { kind: "manufacturer_label", name: "label", reference: "https://elabels.apvma.gov.au/90143.pdf" },
    { kind: "manufacturer_label", name: "label", reference: "https://data.gov.au/beast-label.pdf" },
  ],
};

Deno.test("incomplete Master Beast remains an identity candidate; regulator URL tags cannot promote manufacturer evidence", async () => {
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
