import { assert, assertEquals } from "jsr:@std/assert";
import { classifyUrl } from "../research/classify.ts";
import { inspectCandidateProductPages, privatePageFetchDiagnostic } from "../research/page_inspector.ts";
import { documentedWeedmasterLead, selectAndFetchManufacturerLead, WEEDMASTER_LABEL_LEAD, WEEDMASTER_PRODUCT_PAGE } from "./documented_label_lead.ts";

Deno.test("challenged locked page selects documented non-label-named lead, fetches once, rejects wrong PDF content", async () => {
  const page = await inspectCandidateProductPages({ fetchFn: (() => Promise.resolve(new Response("challenge", {
    status: 403, headers: { "cf-mitigated": "challenge" },
  }))) as typeof fetch }, [WEEDMASTER_PRODUCT_PAGE], "AU");
  assertEquals(page.attempts[0].outcome, "rejected_browser_challenge");
  const lead = documentedWeedmasterLead({ registrationIdentityKey: "AU:apvma:53576",
    productPageUrl: WEEDMASTER_PRODUCT_PAGE, pageFailed: page.attempts[0].httpStatus === 403 });
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
  assertEquals(documentedWeedmasterLead({ registrationIdentityKey: "AU:apvma:69705",
    productPageUrl: WEEDMASTER_PRODUCT_PAGE, pageFailed: true }), null);
  assertEquals(documentedWeedmasterLead({ registrationIdentityKey: "AU:apvma:53576",
    productPageUrl: "https://nufarm.com/au/product/other/", pageFailed: true }), null);
  assertEquals(documentedWeedmasterLead({ registrationIdentityKey: "AU:apvma:53576",
    productPageUrl: WEEDMASTER_PRODUCT_PAGE, pageFailed: false }), null);
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
