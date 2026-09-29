import { assert, assertEquals } from "jsr:@std/assert";
import { classifyUrl } from "../research/classify.ts";
import type { MasterRow } from "./contract.ts";
import { lockedWebIdentity } from "./master_backfill.ts";
import { manufacturerDocumentConfirmsIdentity } from "./manufacturer_enrichment.ts";
import { productPagesToInspect, resolveInitialManufacturerLeads } from "../web_identity.ts";
import { labelApprovalIdentifiers } from "../web_lookup.ts";
import { inspectCandidateProductPages, privatePageFetchDiagnostic } from "../research/page_inspector.ts";
import { documentedWeedmasterLead, selectAndFetchManufacturerLead, WEEDMASTER_LABEL_LEAD, WEEDMASTER_PRODUCT_PAGE } from "./documented_label_lead.ts";

Deno.test("challenged locked page selects documented non-label-named lead, fetches once, rejects wrong PDF content", async () => {
  const page = await inspectCandidateProductPages({ fetchFn: (() => Promise.resolve(new Response("challenge", {
    status: 403, headers: { "cf-mitigated": "challenge" },
  }))) as typeof fetch }, [WEEDMASTER_PRODUCT_PAGE], "AU");
  assertEquals(page.attempts[0].outcome, "rejected_browser_challenge");
  const lead = documentedWeedmasterLead({ registrationIdentityKey: "AU:apvma:53576",
    country: "AU", registrationNumber: "53576", registeredProductName: "Nufarm Weedmaster DUO Herbicide",
    registrant: "NUFARM AUSTRALIA LIMITED" });
  assertEquals(lead, WEEDMASTER_LABEL_LEAD);
  assertEquals(classifyUrl(lead!, "AU").kind, "other");
  const wrongPdf = await Deno.readFile(new URL("./chlorostar_leaflet_fixture.pdf", import.meta.url));
  const requests: string[] = [];
  const result = await selectAndFetchManufacturerLead({
    deps: { now: () => new Date(), fetchFn: ((url: string | URL | Request) => {
      requests.push(String(url));
      return Promise.resolve(new Response(wrongPdf, { status: 200, headers: { "content-type": "application/pdf" } }));
    }) as typeof fetch },
    country: "AU", registrant: "Nufarm", registeredProductName: "Weedmaster DUO Herbicide",
    registrationNumber: "53576", activeNames: ["Glyphosate"], productPageUrl: WEEDMASTER_PRODUCT_PAGE,
    linkedLabel: null, directCandidate: "https://cdn.nufarm.com/files/unclassified.pdf",
    storedLabelUrls: [], documentedLead: lead, regulatorUses: [],
  });
  assertEquals(result.candidateRejection, "document_kind_unrecognised");
  assertEquals(result.documented.eligible, true);
  assertEquals(result.manufacturerLabel, WEEDMASTER_LABEL_LEAD);
  assertEquals(result.labelSource, WEEDMASTER_PRODUCT_PAGE);
  assertEquals(requests, [WEEDMASTER_LABEL_LEAD]);
  assertEquals(result.enrichment?.diagnostics.manufacturer_label_fetch_outcome, "fetched");
  assertEquals(result.enrichment?.diagnostics.manufacturer_label_fetch_reason,
    "the fetched PDF did not confirm the locked registration or registered product identity");
  assertEquals(result.enrichment?.diagnostics.manufacturer_label_extract, "failure");
  assertEquals(result.enrichment?.fetchedUrl, null);
  assertEquals(result.enrichment?.uses, []);
  const diagnostic = privatePageFetchDiagnostic(page.attempts, result.directLabel, true, null, "host_not_verified", {
    lead, eligible: result.documented.eligible, rejection: result.documented.rejection,
    selected: result.documented.selected, fetchOutcome: result.enrichment?.diagnostics.manufacturer_label_fetch_outcome ?? null,
    fetchHttpStatus: result.enrichment?.diagnostics.manufacturer_label_http_status ?? null,
    extractOutcome: result.enrichment?.diagnostics.manufacturer_label_extract ?? null,
    identityMismatch: result.enrichment?.diagnostics.identity_mismatch === true,
  });
  assertEquals(diagnostic.pdf_discovery_outcome, "host_not_verified");
  assertEquals((diagnostic.documented_lead as Record<string, unknown>).fetch_started, true);
  assertEquals((diagnostic.documented_lead as Record<string, unknown>).extract_outcome, "failure");
});

Deno.test("documented lead requires locked product and cannot turn arbitrary manufacturer PDFs into labels", async () => {
  const exact = { registrationIdentityKey: "AU:apvma:53576", country: "AU",
    registrationNumber: "53576", registeredProductName: "Nufarm Weedmaster DUO Herbicide",
    registrant: "NUFARM AUSTRALIA LIMITED" };
  assertEquals(documentedWeedmasterLead({ ...exact, registrationIdentityKey: "AU:apvma:69705" }), null);
  assertEquals(documentedWeedmasterLead({ ...exact, country: "NZ" }), null);
  assertEquals(documentedWeedmasterLead({ ...exact, registrationNumber: "69705" }), null);
  assertEquals(documentedWeedmasterLead({ ...exact, registeredProductName: "Other Herbicide" }), null);
  assertEquals(documentedWeedmasterLead({ ...exact, registrant: "Other Registrant" }), null);
  let calls = 0;
  for (const bad of ["https://elders.com.au/Weedmaster-DUO.pdf", "https://cdn.nufarm.com/Weedmaster-DUO-SDS.pdf",
    "https://cdn.nufarm.com/Weedmaster-DUO-Brochure.pdf", "https://cdn.nufarm.com/other-product.pdf",
    "https://elabels.apvma.gov.au/53576.pdf"]) {
    const result = await selectAndFetchManufacturerLead({
      deps: { now: () => new Date(), fetchFn: (() => { calls++; throw new Error("must not fetch"); }) as typeof fetch },
      country: "AU", registrant: "Nufarm", registeredProductName: "Weedmaster DUO Herbicide",
      registrationNumber: "53576", activeNames: ["Glyphosate"], productPageUrl: WEEDMASTER_PRODUCT_PAGE,
      linkedLabel: null, directCandidate: bad, storedLabelUrls: [], documentedLead: null, regulatorUses: [],
    });
    assertEquals(result.directLabel, null);
    assert(result.candidateRejection);
  }
  const substituted = await selectAndFetchManufacturerLead({
    deps: { now: () => new Date(), fetchFn: (() => { calls++; throw new Error("must not fetch"); }) as typeof fetch },
    country: "AU", registrant: "Nufarm", registeredProductName: "Weedmaster DUO Herbicide",
    registrationNumber: "53576", activeNames: ["Glyphosate"], productPageUrl: WEEDMASTER_PRODUCT_PAGE,
    linkedLabel: null, directCandidate: null, storedLabelUrls: [],
    documentedLead: WEEDMASTER_LABEL_LEAD.replace("Weedmaster-DUO", "Other-Product"), regulatorUses: [],
  });
  assertEquals(substituted.documented.rejection, "product_relationship_unverified");
  assertEquals(substituted.documented.eligible, false);
  assertEquals(substituted.manufacturerLabel, null);
  assertEquals(calls, 0);
});

Deno.test("empty locked Weedmaster Master row resolves the observed pair before discovery or page inspection", async () => {
  const row = {
    id: "03dfb9e8-6592-4746-a3bc-295890d32cd1", registration_country: "AU",
    registration_scheme: "apvma", registration_number: "53576", registration_identity_key: "AU:apvma:53576",
    registrant: "NUFARM AUSTRALIA LIMITED", registered_product_name: "Nufarm Weedmaster DUO Herbicide",
    active_ingredients: [{ name: "Glyphosate Present As The Isopropylamine And Mono-ammoni",
      concentration: 360, concentration_unit: "g/L" }],
    verification_sources: [],
  } as unknown as MasterRow;
  const before = JSON.stringify(row);
  const identity = lockedWebIdentity(row);
  assert(identity);
  assertEquals(identity.pageUrls, []);
  assertEquals(identity.labelUrls, []);
  let discoveryCalls = 0;
  const initial = await resolveInitialManufacturerLeads({ identity, country: row.registration_country,
    registrationIdentityKey: row.registration_identity_key,
    discover: () => { discoveryCalls++; return Promise.resolve({ leads: null, reason: "host_not_verified" }); } });
  assertEquals(initial.leads, { productUrl: WEEDMASTER_PRODUCT_PAGE, labelUrl: null });
  assertEquals(initial.documentedLead, WEEDMASTER_LABEL_LEAD);
  assertEquals(initial.discoveryOutcome, "not_attempted");
  assertEquals(discoveryCalls, 0);
  const pageUrls = productPagesToInspect(identity, initial.leads, initial.documentedLead);
  assertEquals(pageUrls, []);
  const wrongPdf = await Deno.readFile(new URL("./chlorostar_leaflet_fixture.pdf", import.meta.url));
  const requests: string[] = [];
  const inspected = await inspectCandidateProductPages({ fetchFn: (() => {
    throw new Error("no page fetch expected");
  }) as typeof fetch }, pageUrls, "AU");
  assertEquals(inspected.attempts, []);
  const result = await selectAndFetchManufacturerLead({
    deps: { now: () => new Date(), fetchFn: ((url: string | URL | Request) => {
      requests.push(String(url));
      return Promise.resolve(new Response(wrongPdf, { status: 200, headers: { "content-type": "application/pdf" } }));
    }) as typeof fetch },
    country: row.registration_country, registrant: identity.registrant,
    registeredProductName: identity.name, registrationNumber: identity.registrationNumber,
    activeNames: row.active_ingredients.map((a) => a.name),
    productPageUrl: initial.leads?.productUrl ?? null, documentedProductPageUrl: WEEDMASTER_PRODUCT_PAGE,
    inspectedPageUrl: null, linkedLabel: null, directCandidate: initial.leads?.labelUrl ?? null,
    storedLabelUrls: identity.labelUrls, documentedLead: initial.documentedLead, regulatorUses: [],
  });
  assertEquals(result.documented.selected, true);
  assertEquals(result.labelSource, WEEDMASTER_PRODUCT_PAGE);
  assertEquals(requests, [WEEDMASTER_LABEL_LEAD]);
  assertEquals(result.enrichment?.diagnostics.manufacturer_label_fetch_outcome, "fetched");
  assertEquals(result.enrichment?.diagnostics.manufacturer_label_extract, "failure");
  assertEquals(result.enrichment?.fetchedUrl, null);
  assertEquals(result.enrichment?.uses, []);
  const diagnostic = privatePageFetchDiagnostic(inspected.attempts, result.directLabel, true, null,
    "not_attempted", { lead: result.documented.lead, identityMatched: initial.identityMatched,
      pairSupplied: !!initial.documentedLead, eligible: result.documented.eligible,
      rejection: result.documented.rejection, selected: result.documented.selected,
      fetchOutcome: result.enrichment?.diagnostics.manufacturer_label_fetch_outcome ?? null,
      fetchHttpStatus: result.enrichment?.diagnostics.manufacturer_label_http_status ?? null,
      extractOutcome: result.enrichment?.diagnostics.manufacturer_label_extract ?? null,
      verified: false, identityMismatch: result.enrichment?.diagnostics.identity_mismatch === true }, initial.discoveryOutcome);
  assertEquals(diagnostic.initial_discovery_outcome, "not_attempted");
  assertEquals(diagnostic.failed_page_fallback_discovery_outcome, "not_attempted");
  const documented = diagnostic.documented_lead as Record<string, unknown>;
  assertEquals(documented.locked_identity_matched, true);
  assertEquals(documented.pair_supplied, true);
  assertEquals(documented.selected, true);
  assertEquals(documented.fetch_started, true);
  assertEquals(documented.fetch_outcome, "fetched");
  assertEquals(documented.verified, false);
  assertEquals(documented.extract_outcome, "failure");
  assertEquals(diagnostic.attempts, []);
  assertEquals(JSON.stringify(row), before);
  for (const text of [
    "Nufarm OTHER Herbicide Glyphosate Present As The Isopropylamine And Mono-ammoni APVMA 53576",
    "Nufarm Weedmaster DUO Herbicide Other Active APVMA 53576",
  ]) {
    assertEquals(manufacturerDocumentConfirmsIdentity({ text, registrationNumber: row.registration_number,
      registeredProductName: row.registered_product_name,
      activeNames: row.active_ingredients.map((a) => a.name) }), false);
  }
  // Printed approval is checked after a readable label, independently of the header/chemistry gate.
  assertEquals(labelApprovalIdentifiers("APVMA Approval No: 69705", "AU").numbers.includes(row.registration_number), false);
});

Deno.test("recognised manufacturer label endpoints without PDF suffix reach PDF-byte and identity checks", async () => {
  const wrongPdf = await Deno.readFile(new URL("./chlorostar_leaflet_fixture.pdf", import.meta.url));
  for (const endpoint of ["getlabel", "viewlabel"]) {
    const url = `https://nufarm.com/au/${endpoint}?product=weedmaster-duo`;
    assertEquals(classifyUrl(url, "AU").kind, "label_document");
    const requests: string[] = [];
    const result = await selectAndFetchManufacturerLead({
      deps: { now: () => new Date(), fetchFn: ((requested: string | URL | Request) => {
        requests.push(String(requested));
        return Promise.resolve(new Response(wrongPdf, { status: 200, headers: { "content-type": "application/pdf" } }));
      }) as typeof fetch },
      country: "AU", registrant: "Nufarm", registeredProductName: "Weedmaster DUO Herbicide",
      registrationNumber: "53576", activeNames: ["Glyphosate"], productPageUrl: WEEDMASTER_PRODUCT_PAGE,
      linkedLabel: null, directCandidate: url, storedLabelUrls: [], documentedLead: null, regulatorUses: [],
    });
    assertEquals(result.candidateRejection, null);
    assertEquals(result.directLabel, url);
    assertEquals(requests, [url]);
    assertEquals(result.enrichment?.diagnostics.manufacturer_label_fetch_outcome, "fetched");
    assertEquals(result.enrichment?.diagnostics.manufacturer_label_extract, "failure");
    assertEquals(result.enrichment?.fetchedUrl, null);
    assertEquals(result.enrichment?.uses, []);
  }
});

Deno.test("no candidates select no documented lead and never fetch", async () => {
  let calls = 0;
  const result = await selectAndFetchManufacturerLead({
    deps: { now: () => new Date(), fetchFn: (() => { calls++; throw new Error("must not fetch"); }) as typeof fetch },
    country: "AU", registrant: "Nufarm", registeredProductName: "Weedmaster DUO Herbicide",
    registrationNumber: "53576", productPageUrl: WEEDMASTER_PRODUCT_PAGE,
    linkedLabel: null, directCandidate: null, storedLabelUrls: [], documentedLead: null, regulatorUses: [],
  });
  assertEquals(result.directLabel, null);
  assertEquals(result.manufacturerLabel, null);
  assertEquals(result.enrichment, null);
  assertEquals(result.documented, { lead: null, eligible: false, rejection: null, selected: false });
  const diagnostic = privatePageFetchDiagnostic([], result.directLabel, false, "no_eligible_manufacturer_pdf_lead",
    "search_no_candidate", { lead: result.documented.lead, eligible: result.documented.eligible,
      rejection: result.documented.rejection, selected: result.documented.selected,
      fetchOutcome: null, fetchHttpStatus: null, extractOutcome: null, identityMismatch: false });
  assertEquals(diagnostic.documented_lead && (diagnostic.documented_lead as Record<string, unknown>).considered, false);
  assertEquals(diagnostic.documented_lead && (diagnostic.documented_lead as Record<string, unknown>).eligible, false);
  assertEquals(diagnostic.documented_lead && (diagnostic.documented_lead as Record<string, unknown>).selected, false);
  assertEquals(diagnostic.documented_lead && (diagnostic.documented_lead as Record<string, unknown>).fetch_started, false);
  assertEquals(calls, 0);
});
