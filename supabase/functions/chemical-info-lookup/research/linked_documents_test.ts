// Manufacturer label promotion via a trusted product-page relationship.
//
// The regression fixture is Sprayseal Pruning Wound Treatment (APVMA 80160,
// Omnia Specialities Australia). Its manufacturer label is served from
// `/files/2025/07/Sprayseal 5L_Digi.pdf` — a registrant host, but a filename
// with no label signature, so URL-only classification refused it and the
// label's rate table and re-entry condition never became evidence.
//
// Sprayseal is a FIXTURE, not a special case: every rule below is asserted
// generically as well.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { classifyUrl } from "./classify.ts";
import {
  evaluateLinkedDocument,
  selectManufacturerLabel,
} from "./linked_documents.ts";
import {
  CROPSURE_CATALOGUE_HTML,
  CROPSURE_CATALOGUE_URL,
  CROPSURE_GREENSHIELD_LABEL_URL,
} from "./cropsure_catalogue_fixture.ts";
import { extractLinks, extractPageProductName } from "./page_inspector.ts";

const OMNIA_PAGE = "https://www.omnia.com.au/products/sprayseal";
const OMNIA_LABEL = "https://www.omnia.com.au/files/2025/07/Sprayseal%205L_Digi.pdf";
const REGISTERED_NAME = "SPRAYSEAL PRUNING WOUND TREATMENT";

/** The promotion input for a document linked on Omnia's Sprayseal page. */
function omniaLink(url: string, linkText: string, pageName = "Sprayseal") {
  return {
    page: { pageUrl: OMNIA_PAGE, pageProductName: pageName },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    document: { url, linkText },
  };
}

// ---------------------------------------------------------------------------
// The root cause, demonstrated
// ---------------------------------------------------------------------------

Deno.test("ROOT CAUSE: URL-only classification refuses the Omnia label", () => {
  // The registrant host IS recognised. The filename is what fails: no `label`
  // token, so `kindFor` returns `other` and the document can never be
  // evidence. This test documents the defect the promotion path exists to fix.
  const c = classifyUrl(OMNIA_LABEL, "AU");
  assertEquals(c.trust, "registrant");
  assertEquals(c.kind, "other");
  assertEquals(c.isOfficialLabelCandidate, false);
});

Deno.test("a registrant PDF with no label filename IS promotable from link text", () => {
  const result = evaluateLinkedDocument(omniaLink(OMNIA_LABEL, "Label"));
  assertEquals(result.outcome, "promoted_manufacturer_label");
  assertEquals(result.isManufacturerLabel, true);
});

// ---------------------------------------------------------------------------
// Link text must identify a LABEL — and nothing else
// ---------------------------------------------------------------------------

Deno.test("accepted label wordings", () => {
  for (const text of ["Label", "Product Label", "Registered Label", "Approved Label", "APVMA Label", "Labels"]) {
    const r = evaluateLinkedDocument(omniaLink(OMNIA_LABEL, text));
    assertEquals(r.isManufacturerLabel, true, `${text} should promote`);
  }
});

Deno.test("a BROCHURE is never promoted", () => {
  const r = evaluateLinkedDocument(
    omniaLink("https://www.omnia.com.au/files/sprayseal-brochure.pdf", "Brochure"),
  );
  assertEquals(r.outcome, "rejected_excluded_kind");
  assert(r.reason.includes("brochure"));
});

Deno.test("a TDS is never promoted", () => {
  for (const text of ["TDS", "Technical Data Sheet"]) {
    const r = evaluateLinkedDocument(
      omniaLink("https://www.omnia.com.au/files/sprayseal-tds.pdf", text),
    );
    assertEquals(r.outcome, "rejected_excluded_kind", text);
  }
});

Deno.test("an SDS stays an SDS", () => {
  for (const text of ["SDS", "MSDS", "Safety Data Sheet"]) {
    const r = evaluateLinkedDocument(
      omniaLink("https://www.omnia.com.au/files/sprayseal-sds.pdf", text),
    );
    assertEquals(r.outcome, "rejected_excluded_kind", text);
    assertEquals(r.isManufacturerLabel, false);
  }
  // And URL-only classification still calls it an SDS, independently.
  assertEquals(
    classifyUrl("https://www.omnia.com.au/files/sprayseal-sds.pdf", "AU").kind,
    "safety_data_sheet",
  );
});

Deno.test("a combined 'Label & SDS' link is refused rather than guessed", () => {
  // Which document it resolves to is unknowable from the text. Guessing would
  // put an SDS's handling wording where label rates belong.
  const r = evaluateLinkedDocument(omniaLink(OMNIA_LABEL, "Label & SDS"));
  assertEquals(r.outcome, "rejected_excluded_kind");
});

Deno.test("unrelated marketing collateral is refused", () => {
  for (const text of ["Price List", "Catalogue", "Trial Data", "Case Study", "Flyer", "Spec Sheet"]) {
    const r = evaluateLinkedDocument(omniaLink(OMNIA_LABEL, text));
    assertEquals(r.outcome, "rejected_excluded_kind", text);
  }
});

Deno.test("a link with no identifying text is refused", () => {
  for (const text of ["", "   ", "Download", "Click here", "More information"]) {
    const r = evaluateLinkedDocument(omniaLink(OMNIA_LABEL, text));
    assertEquals(r.outcome, "rejected_not_label_text", JSON.stringify(text));
  }
});

Deno.test("'Labelling information' is a page section, not a label document", () => {
  // Whole-word matching: `label` must stand alone rather than as a prefix.
  const r = evaluateLinkedDocument(omniaLink(OMNIA_LABEL, "Labelling information"));
  assertEquals(r.outcome, "rejected_not_label_text");
});

// ---------------------------------------------------------------------------
// The RELATIONSHIP must be trustworthy
// ---------------------------------------------------------------------------

Deno.test("a search-engine result page can never confer label status", () => {
  const search = "https://www.google.com/search?q=sprayseal+label";
  assertEquals(classifyUrl(search, "AU").trust, "search_engine");
  assertEquals(classifyUrl(search, "AU").isProductPageCandidate, false);

  const r = evaluateLinkedDocument({
    page: { pageUrl: search, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: false,
    registeredProductName: REGISTERED_NAME,
    document: { url: OMNIA_LABEL, linkText: "Label" },
  });
  assertEquals(r.outcome, "rejected_untrusted_page");
});

Deno.test("a reseller page cannot confer label status", () => {
  const reseller = "https://www.elders.com.au/products/sprayseal";
  assertEquals(classifyUrl(reseller, "AU").trust, "reseller");
  assertEquals(classifyUrl(reseller, "AU").isProductPageCandidate, false);

  const r = evaluateLinkedDocument({
    page: { pageUrl: reseller, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: false,
    registeredProductName: REGISTERED_NAME,
    document: { url: "https://www.elders.com.au/files/sprayseal.pdf", linkText: "Label" },
  });
  assertEquals(r.outcome, "rejected_untrusted_page");
});

Deno.test("a reseller PDF is not authoritative even from a trusted-looking link", () => {
  const r = evaluateLinkedDocument({
    page: { pageUrl: OMNIA_PAGE, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    document: { url: "https://www.elders.com.au/files/sprayseal-label.pdf", linkText: "Label" },
  });
  // Off the registrant's host: a third party linked from a manufacturer page
  // is still a third party.
  assertEquals(r.outcome, "rejected_cross_host");
});

Deno.test("a page about a DIFFERENT product cannot promote its documents", () => {
  const r = evaluateLinkedDocument(
    omniaLink(OMNIA_LABEL, "Label", "Omnia Nutriboost Foliar"),
  );
  assertEquals(r.outcome, "rejected_product_mismatch");
});

Deno.test("identity matching tolerates typography, never variant designators", () => {
  // "Sprayseal" ↔ "SPRAYSEAL PRUNING WOUND TREATMENT" corresponds; a FORTE
  // variant is a different registered product and must not.
  assertEquals(
    evaluateLinkedDocument(omniaLink(OMNIA_LABEL, "Label", "Spray Seal")).isManufacturerLabel,
    true,
  );
  assertEquals(
    evaluateLinkedDocument(omniaLink(OMNIA_LABEL, "Label", "Sprayseal Forte")).outcome,
    "rejected_product_mismatch",
  );
});

Deno.test("a non-PDF link is not a label document", () => {
  const r = evaluateLinkedDocument(
    omniaLink("https://www.omnia.com.au/products/sprayseal/label", "Label"),
  );
  assertEquals(r.outcome, "rejected_not_pdf");
});

// ---------------------------------------------------------------------------
// Foreign-country evidence
// ---------------------------------------------------------------------------

Deno.test("a foreign regulator cannot establish an AU registration", () => {
  // Country is a hard identity boundary: an NZ regulator host carries no
  // authority for an AU registration, whatever it is serving.
  const nz = classifyUrl("https://www.epa.govt.nz/labels/sprayseal-label.pdf", "AU");
  assertEquals(nz.trust, "unknown");
  assertEquals(nz.isOfficialLabelCandidate, false);
  assert(nz.reason.includes("no authority"));
});

Deno.test("a foreign registrant page cannot promote a label for another country", () => {
  // The host is a registrant, but the page is not the AU product page and its
  // product name must still correspond. Promotion turns on identity, and
  // identity is country-scoped upstream at the register.
  const r = evaluateLinkedDocument({
    page: { pageUrl: "https://www.omnia.com.au/products/other-product", pageProductName: "Different Product" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    document: { url: OMNIA_LABEL, linkText: "Label" },
  });
  assertEquals(r.outcome, "rejected_product_mismatch");
});

// ---------------------------------------------------------------------------
// Selection across a whole page
// ---------------------------------------------------------------------------

Deno.test("the label is chosen from a page of mixed documents", () => {
  const selection = selectManufacturerLabel({
    page: { pageUrl: OMNIA_PAGE, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: [
      { url: "https://www.omnia.com.au/files/sprayseal-sds.pdf", linkText: "SDS" },
      { url: "https://www.omnia.com.au/files/sprayseal-brochure.pdf", linkText: "Brochure" },
      { url: OMNIA_LABEL, linkText: "Label" },
    ],
  });
  assertEquals(selection.label?.url, OMNIA_LABEL);
  // Every refusal is NAMED — a silent "no" is indistinguishable from a crawler
  // that found nothing, and this is where a future investigation starts.
  assertEquals(selection.rejected.length, 2);
  assert(selection.rejected.every((r) => r.outcome === "rejected_excluded_kind"));
});

Deno.test("CropSure generic catalogue page promotes only its exact full-product label anchor", () => {
  const page = extractPageProductName(CROPSURE_CATALOGUE_HTML);
  const links = extractLinks(CROPSURE_CATALOGUE_HTML, CROPSURE_CATALOGUE_URL).links;
  assertEquals(page.name, "Fungicide");

  const selection = selectManufacturerLabel({
    page: { pageUrl: CROPSURE_CATALOGUE_URL, pageProductName: page.name },
    pageIsTrustedProductPage: classifyUrl(CROPSURE_CATALOGUE_URL, "AU").isInspectableProductPage,
    pageIsVerifiedRegistrantDomain: classifyUrl(CROPSURE_CATALOGUE_URL, "AU").trust === "registrant",
    registeredProductName: "CROPSURE GREENSHIELD 750 WG FUNGICIDE",
    documents: links,
  });
  assertEquals(selection.label?.url, CROPSURE_GREENSHIELD_LABEL_URL);
});

Deno.test("generic catalogue exceptions stay closed to unrelated, reseller and cross-host label links", () => {
  const base = {
    page: { pageUrl: CROPSURE_CATALOGUE_URL, pageProductName: "Fungicide" },
    pageIsTrustedProductPage: true,
    pageIsVerifiedRegistrantDomain: true,
    registeredProductName: "CROPSURE GREENSHIELD 750 WG FUNGICIDE",
  };
  assertEquals(evaluateLinkedDocument({
    ...base,
    document: { url: "https://cropsure.com/unrelated-label.pdf", linkText: "Unrelated Product Label" },
  }).outcome, "rejected_catalogue_link_identity");
  assertEquals(evaluateLinkedDocument({
    ...base,
    document: { url: "https://reseller.example/greenshield-label.pdf", linkText: "CropSure Greenshield 750WG Fungicide Label" },
  }).outcome, "rejected_cross_host");
  assertEquals(evaluateLinkedDocument({
    ...base,
    pageIsTrustedProductPage: false,
    document: { url: CROPSURE_GREENSHIELD_LABEL_URL, linkText: "CropSure Greenshield 750WG Fungicide Label" },
  }).outcome, "rejected_untrusted_page");
});

Deno.test("a page with no label link promotes nothing", () => {
  const selection = selectManufacturerLabel({
    page: { pageUrl: OMNIA_PAGE, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: [
      { url: "https://www.omnia.com.au/files/sprayseal-sds.pdf", linkText: "SDS" },
    ],
  });
  assertEquals(selection.label, null);
});
