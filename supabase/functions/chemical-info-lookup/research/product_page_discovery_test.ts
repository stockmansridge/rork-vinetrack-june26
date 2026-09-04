// Product-page DISCOVERY: recognition and fetch-budget priority.
//
// # The defect these tests close
//
// A registrant's real product page and real approved label were reachable,
// eligible for inspection, and never fetched. Two independent causes, both of
// them about which URLs get to spend a scarce network budget — neither about
// what a fetched document is allowed to prove:
//
//   1. `looksLikeProductPage` matched `product-details?` with a HYPHEN only,
//      so a `/product_detail` route classified as `other`. It remained
//      inspectable, but only by accident of the `other && !isPdf` fallback —
//      indistinguishable from any ordinary web page.
//   2. `inspectCandidateProductPages` drained its queue in pure FIFO order.
//      Since "page-shaped unknown host" describes very nearly every URL on the
//      web, two weak leads ahead of a recognised product page consumed the
//      entire two-ATTEMPT budget.
//
// # What is deliberately NOT changed
//
// Recognition and priority decide what may be READ. Every test below that
// touches promotion asserts the evidence policy is untouched: an unrecognised
// host stays `unknown` trust, `isProductPageCandidate` still demands
// `registrant` trust, and a fetched page still has to state the
// register-resolved product, host its own PDF, and word the link as a label.
//
// The Vicchem page is a FIXTURE — captured from the real APVMA 33182
// registrant page during the audit (HTTP 200, text/html, 13,583 bytes, no
// redirect). Nothing in production matches on "vicchem", "vicol" or "pn=";
// every rule is also asserted generically.

import { assert, assertEquals } from "jsr:@std/assert@1";

import { classifyUrl, isForeignRegulatorHost } from "./classify.ts";
import {
  inspectCandidateProductPages,
  inspectProductPage,
  MAX_PAGE_FETCH_ATTEMPTS,
} from "./page_inspector.ts";
import { selectManufacturerLabel, selectManufacturerSds } from "./linked_documents.ts";
import { projectResearch } from "./authority.ts";
import { cloneResearch } from "./test_fixtures.ts";
import type { ChemicalResearchResult } from "./schema.ts";
import {
  CROPSURE_CATALOGUE_HTML,
  CROPSURE_CATALOGUE_URL,
  CROPSURE_GREENSHIELD_LABEL_URL,
} from "./cropsure_catalogue_fixture.ts";

const VICOL_PAGE = "https://www.vicchem.com/product_detail?pn=19200";
const VICOL_LABEL = "https://www.vicchem.com/prods/label/VICOLWOLabel.pdf";
const VICOL_SDS = "https://www.vicchem.com/prods/msds/sds%20vicol%20winter%20oil.pdf";
const VICOL_REGISTERED_NAME = "VICOL WINTER OIL INSECTICIDE";
const APVMA_ELABEL = "https://elabels.apvma.gov.au/33182.pdf";

/**
 * The captured page structure: an `h1` that states the product, three
 * document buttons with RELATIVE hrefs (one carrying a literal space in the
 * filename), and a footer of site-policy PDFs that must never be mistaken for
 * product documents. The page serves no `<title>`, which is why the product
 * identity has to come from the `h1`.
 */
const VICOL_HTML = `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"></head>
<body>
  <a href="index.aspx">Home</a>
  <a id="BodyContent_rangelink" href="/products_ag.aspx">Agricultural Products</a>
  <form method="post" action="./product_detail?pn=19200" id="Form1">
    <h1>VICOL WINTER OIL Insecticide</h1>
    <p>A highly refined spray oil for use on grapevines and pome fruit.</p>
    <a href="prods/msds/sds vicol winter oil.pdf" target="_blank" class="button large">Safety Data Sheet </a>
    <a href="prods/label/VICOLWOLabel.pdf" target="_blank" class="button large">Product Label</a>
    <a href="prods/pdb/pdb-VICOLWO.pdf" target="_blank" class="button large">Technical Bulletin</a>
    <a href="prods/VicchemHortBrochure.pdf">VICCHEM Horticulture Product Guide</a>
  </form>
  <footer>
    <a href="/terms.pdf">Website Terms &amp; Conditions</a>
    <a href="/privacy.pdf">Privacy Policy</a>
    <a href="/qualitypolicy.pdf">Quality Policy</a>
  </footer>
</body>
</html>`;

/** The same page, about a DIFFERENT product. Used for the mismatch tests. */
const WRONG_PRODUCT_HTML = VICOL_HTML.replace(
  "<h1>VICOL WINTER OIL Insecticide</h1>",
  "<h1>VICCHEM SUMMER SPRAY OIL</h1>",
);

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

interface StubOptions {
  url?: string;
  status?: number;
  contentType?: string | null;
}

function stubResponse(body: string, options: StubOptions = {}): Response {
  const headers = new Headers();
  if (options.contentType !== null) {
    headers.set("content-type", options.contentType ?? "text/html; charset=utf-8");
  }
  const res = new Response(body, { status: options.status ?? 200, headers });
  Object.defineProperty(res, "url", { value: options.url ?? "", configurable: true });
  return res;
}

/** Serve per-URL bodies and record the exact request ORDER. */
function fetchByUrl(bodies: Record<string, string>): {
  fetchFn: typeof fetch;
  calls: string[];
} {
  const calls: string[] = [];
  const fetchFn = ((input: string | URL | Request) => {
    const url = String(input);
    calls.push(url);
    const body = bodies[url];
    if (body === undefined) {
      return Promise.resolve(stubResponse("<html>Not found</html>", { status: 404, url }));
    }
    return Promise.resolve(stubResponse(body, { url }));
  }) as unknown as typeof fetch;
  return { fetchFn, calls };
}

/** A research result carrying exactly the documents a test cares about. */
function researchWith(productPages: string[], labelCandidates: string[] = []): ChemicalResearchResult {
  const research = cloneResearch();
  research.sources = [];
  research.registration_candidates = [];
  research.documents.sds_candidates = [];
  research.documents.official_label_candidates = labelCandidates.map((url) => ({
    url,
    title: "Approved label",
    domain: new URL(url).host,
    reason: "regulator label document",
  }));
  research.documents.product_page_candidates = productPages.map((url) => ({
    url,
    title: "Product page",
    domain: new URL(url).host,
    reason: "registrant product page",
  }));
  return research;
}

Deno.test("verified catalogue accepts a same-host label anchor omitting only the registrant prefix", async () => {
  const network = fetchByUrl({ [CROPSURE_CATALOGUE_URL]: CROPSURE_CATALOGUE_HTML });
  const inspected = await inspectProductPage(
    { fetchFn: network.fetchFn },
    CROPSURE_CATALOGUE_URL,
    "AU",
  );
  assertEquals(inspected.outcome, "inspected");
  if (inspected.outcome !== "inspected") return;
  assertEquals(inspected.pageProductName, "Fungicide");

  const projection = projectResearch(
    researchWith([CROPSURE_CATALOGUE_URL], ["https://elabels.apvma.gov.au/90279ELBL.pdf"]),
    "AU",
    "apvma",
    "CROPSURE GREENSHIELD 750 WG FUNGICIDE",
    [inspected],
  );
  assertEquals(projection.manufacturerLabelCandidate?.url, CROPSURE_GREENSHIELD_LABEL_URL);
  assertEquals(projection.productPageCandidate?.url, CROPSURE_CATALOGUE_URL);
  assertEquals(projection.extraction.manufacturer_label_url, CROPSURE_GREENSHIELD_LABEL_URL);
  assertEquals(projection.extraction.productURL, CROPSURE_CATALOGUE_URL);
});

Deno.test("verified catalogue still rejects a missing product token or changed variant", () => {
  const page = { pageUrl: CROPSURE_CATALOGUE_URL, pageProductName: "Fungicide" };
  const base = {
    page,
    pageIsTrustedProductPage: true,
    pageIsVerifiedRegistrantDomain: true,
    registeredProductName: "EXAMPLECO RIDGESHIELD 750 WG FUNGICIDE",
  };
  for (const linkText of [
    "RidgeShield Fungicide Label",
    "RidgeShield 750 WG Plus Fungicide Label",
    "OtherShield 750 WG Fungicide Label",
  ]) {
    const selection = selectManufacturerLabel({
      ...base,
      documents: [{ url: "https://cropsure.com/documents/candidate-label.pdf", linkText }],
    });
    assertEquals(selection.label, null, linkText);
  }
});

// ---------------------------------------------------------------------------
// §1 — underscore product-detail recognition
// ---------------------------------------------------------------------------

Deno.test("§1 a product_detail URL is RECOGNISED as a product page", () => {
  const c = classifyUrl(VICOL_PAGE, "AU");
  assertEquals(c.kind, "product_page");
  assertEquals(c.isInspectableProductPage, true);
});

Deno.test("§1 recognition does NOT confer trust on an unrecognised host", () => {
  const c = classifyUrl(VICOL_PAGE, "AU");
  // The whole point: the URL shape earns a READ, never authority.
  assertEquals(c.trust, "unknown");
  assertEquals(c.isProductPageCandidate, false);
  assertEquals(c.isOfficialLabelCandidate, false);
});

Deno.test("§1 hyphen and underscore separators are equivalent, generically", () => {
  const forms = [
    "https://example-registrant.com/product-detail?id=1",
    "https://example-registrant.com/product-details?id=1",
    "https://example-registrant.com/product_detail?id=1",
    "https://example-registrant.com/product_details?id=1",
  ];
  for (const url of forms) {
    const c = classifyUrl(url, "AU");
    assertEquals(c.kind, "product_page", `${url} should be a product page`);
    assertEquals(c.trust, "unknown", `${url} must not gain trust from its shape`);
  }
});

Deno.test("§1 the change did not turn unrelated underscore paths into product pages", () => {
  // The widening is confined to the product-detail token. A page about
  // company detail, or a detail view of something else, is unaffected.
  for (
    const url of [
      "https://example-registrant.com/company_detail?id=1",
      "https://example-registrant.com/detail?id=1",
      "https://example-registrant.com/order_details",
    ]
  ) {
    assertEquals(classifyUrl(url, "AU").kind, "other", url);
  }
});

Deno.test("§1 a registrant host serving product_detail is still a product-page CANDIDATE", () => {
  // The other side of the same rule: recognition plus registrant trust is what
  // `isProductPageCandidate` has always required, and still does.
  const c = classifyUrl("https://nufarm.com.au/product_detail?pn=9", "AU");
  assertEquals(c.kind, "product_page");
  assertEquals(c.trust, "registrant");
  assertEquals(c.isProductPageCandidate, true);
});

// ---------------------------------------------------------------------------
// §6 — the starvation regression
// ---------------------------------------------------------------------------

const GENERIC_A = "https://agri-news-example.com/articles/winter-oil-spraying";
const GENERIC_B = "https://another-unknown-example.com/info/oils";

Deno.test("§6 STARVATION: a recognised product page outranks two generic leads", async () => {
  // Both generic leads are legitimately inspectable — `other` on an
  // unrecognised host, non-PDF — which is exactly why FIFO starved the real
  // page. They arrive FIRST in discovery order.
  assertEquals(classifyUrl(GENERIC_A, "AU").isInspectableProductPage, true);
  assertEquals(classifyUrl(GENERIC_B, "AU").isInspectableProductPage, true);
  assertEquals(classifyUrl(GENERIC_A, "AU").kind, "other");
  assertEquals(classifyUrl(GENERIC_B, "AU").kind, "other");

  const { fetchFn, calls } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const { pages, attempts } = await inspectCandidateProductPages(
    { fetchFn },
    [GENERIC_A, GENERIC_B, VICOL_PAGE],
    "AU",
  );

  // The recognised page is requested FIRST, despite arriving last.
  assertEquals(calls[0], VICOL_PAGE);
  // And the budget is untouched: still two ATTEMPTS, never three.
  assertEquals(calls.length, 2);
  assertEquals(calls.length, MAX_PAGE_FETCH_ATTEMPTS);
  assertEquals(attempts.length, 2);
  assertEquals(pages.length, 1);
  assertEquals(pages[0].pageProductName, "VICOL WINTER OIL Insecticide");
});

Deno.test("§6 discovery order is preserved WITHIN each priority class", async () => {
  const { fetchFn, calls } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  await inspectCandidateProductPages({ fetchFn }, [GENERIC_A, GENERIC_B, VICOL_PAGE], "AU");
  // A before B — the second slot goes to the earlier-discovered generic lead.
  assertEquals(calls, [VICOL_PAGE, GENERIC_A]);
});

Deno.test("§6 two recognised product pages keep their own discovery order", async () => {
  const second = "https://example-registrant.com/product_detail?pn=2";
  const { fetchFn, calls } = fetchByUrl({});
  await inspectCandidateProductPages({ fetchFn }, [VICOL_PAGE, second, GENERIC_A], "AU");
  assertEquals(calls, [VICOL_PAGE, second]);
});

Deno.test("§6 the cap still counts ATTEMPTS, not successes", async () => {
  // Three recognised pages, all 404. Priority must not hand out extra requests.
  const { fetchFn, calls } = fetchByUrl({});
  const { pages, attempts } = await inspectCandidateProductPages(
    { fetchFn },
    [
      "https://example-registrant.com/product_detail?pn=1",
      "https://example-registrant.com/product_detail?pn=2",
      "https://example-registrant.com/product_detail?pn=3",
    ],
    "AU",
  );
  assertEquals(calls.length, 2);
  assertEquals(pages.length, 0);
  assert(attempts.every((a) => a.outcome === "rejected_http_error"));
});

Deno.test("§6 prioritisation is pure: the same leads always produce the same order", async () => {
  const leads = [GENERIC_B, VICOL_PAGE, GENERIC_A];
  const first = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  await inspectCandidateProductPages({ fetchFn: first.fetchFn }, leads, "AU");
  const second = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  await inspectCandidateProductPages({ fetchFn: second.fetchFn }, leads, "AU");
  assertEquals(first.calls, second.calls);
  assertEquals(first.calls, [VICOL_PAGE, GENERIC_B]);
});

Deno.test("§6 duplicates are still collapsed before the budget is spent", async () => {
  const { fetchFn, calls } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  await inspectCandidateProductPages(
    { fetchFn },
    [VICOL_PAGE, VICOL_PAGE, GENERIC_A],
    "AU",
  );
  assertEquals(calls, [VICOL_PAGE, GENERIC_A]);
});

// ---------------------------------------------------------------------------
// §7 — the VICOL acceptance case, end to end through the real policy
// ---------------------------------------------------------------------------

Deno.test("§7 ACCEPTANCE: the fixture page yields exactly the Product Label PDF", async () => {
  const { fetchFn } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const result = await inspectProductPage({ fetchFn }, VICOL_PAGE, "AU");
  assertEquals(result.outcome, "inspected");
  if (result.outcome !== "inspected") return;

  assertEquals(result.pageProductName, "VICOL WINTER OIL Insecticide");
  assertEquals(result.pageProductNameSource, "h1");

  const selection = selectManufacturerLabel({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: classifyUrl(result.finalUrl, "AU").isInspectableProductPage,
    registeredProductName: VICOL_REGISTERED_NAME,
    documents: result.links,
  });
  assertEquals(selection.label?.url, VICOL_LABEL);
  assertEquals(selection.label?.linkText, "Product Label");

  // §4: the served casing is the page's own. Nothing lowercases the path.
  assert(selection.label!.url.includes("VICOLWOLabel.pdf"));
  assert(!selection.label!.url.includes("vicolwolabel.pdf"));
});

Deno.test("§7 ACCEPTANCE: the label and the product page both reach the projection", async () => {
  const { fetchFn } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const inspection = await inspectCandidateProductPages({ fetchFn }, [VICOL_PAGE], "AU");

  const projection = projectResearch(
    researchWith([VICOL_PAGE], [APVMA_ELABEL]),
    "AU",
    "apvma",
    VICOL_REGISTERED_NAME,
    inspection.pages,
  );

  assertEquals(projection.manufacturerLabelCandidate?.url, VICOL_LABEL);
  // The product page is EARNED through the accepted label chain (§3) — it is
  // still not a classified product-page candidate on its own.
  assertEquals(projection.productPageCandidate?.url, VICOL_PAGE);
  assertEquals(classifyUrl(VICOL_PAGE, "AU").isProductPageCandidate, false);

  // §4: three independent URLs, none substituted for another.
  assertEquals(projection.extraction.manufacturer_label_url, VICOL_LABEL);
  assertEquals(projection.extraction.productURL, VICOL_PAGE);
  assertEquals(projection.extraction.regulator_label_url, APVMA_ELABEL);
  assertEquals(projection.extraction.label_reference, APVMA_ELABEL);
  assertEquals(projection.extraction.sdsURL, VICOL_SDS);
});

Deno.test("§7 the starved ordering is what makes the acceptance case reachable", async () => {
  // The same lead set the live path produces: weak leads first, real page last.
  const { fetchFn } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const inspection = await inspectCandidateProductPages(
    { fetchFn },
    [GENERIC_A, GENERIC_B, VICOL_PAGE],
    "AU",
  );
  const projection = projectResearch(
    researchWith([GENERIC_A, GENERIC_B, VICOL_PAGE], [APVMA_ELABEL]),
    "AU",
    "apvma",
    VICOL_REGISTERED_NAME,
    inspection.pages,
  );
  assertEquals(projection.manufacturerLabelCandidate?.url, VICOL_LABEL);
  assertEquals(projection.productPageCandidate?.url, VICOL_PAGE);
});

// ---------------------------------------------------------------------------
// §8 — negative trust: priority earns nothing
// ---------------------------------------------------------------------------

Deno.test("§8 search engines and resellers are never fetched", async () => {
  const untrusted = [
    "https://www.google.com/search?q=vicol+winter+oil+label",
    "https://www.elders.com.au/products/vicol-winter-oil",
    "https://www.bing.com/search?q=vicol",
    "https://www.amazon.com.au/products/vicol",
  ];
  for (const url of untrusted) {
    assertEquals(classifyUrl(url, "AU").isInspectableProductPage, false, url);
  }

  const { fetchFn, calls } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  await inspectCandidateProductPages({ fetchFn }, [...untrusted, VICOL_PAGE], "AU");
  // Not merely deprioritised — never requested at all.
  assertEquals(calls, [VICOL_PAGE]);
});

Deno.test("§8 a foreign regulator host earns no authority, and hosts no label", () => {
  // A foreign regulator is classified `unknown` for THIS country — country is
  // a hard identity boundary, so ACVM cannot speak for an AU lookup.
  const page = classifyUrl("https://acvm.mpi.govt.nz/product_detail?pn=19200", "AU");
  assertEquals(page.trust, "unknown");
  assertEquals(page.isProductPageCandidate, false);
  assertEquals(page.isOfficialLabelCandidate, false);

  // And a PDF it serves is never an official label candidate for AU.
  const pdf = classifyUrl("https://acvm.mpi.govt.nz/docs/label-123.pdf", "AU");
  assertEquals(pdf.trust, "unknown");
  assertEquals(pdf.isOfficialLabelCandidate, false);
  assertEquals(pdf.isInspectableProductPage, false);
});

// ---------------------------------------------------------------------------
// §9 — the jurisdiction boundary: a foreign regulator is never inspectable
//
// The tests in §1–§8 exposed this. `trustFor` maps a foreign regulator to
// `unknown` (correct: it has no AUTHORITY here), and unknown hosts are
// deliberately readable so an unlisted registrant like Vicchem can be
// discovered (also correct). Composed, those two rules let another country's
// government register into the unknown-host manufacturer-label earning path.
//
// The fix refuses it on IDENTITY, not on URL shape, and not by inventing a new
// trust tier. The `unknown` tier and the whole public `SourceTrustTier` enum
// are unchanged.
// ---------------------------------------------------------------------------

/** Every host in the registry, by the country that owns it. */
const AU_REGULATOR_HOSTS = [
  "apvma.gov.au",
  "elabels.apvma.gov.au",
  "portal.apvma.gov.au",
  "data.gov.au",
  "legislation.gov.au",
  "agriculture.gov.au",
];
const NZ_REGULATOR_HOSTS = [
  "acvm.mpi.govt.nz",
  "eatsafe.nzfsa.govt.nz",
  "mpi.govt.nz",
  "epa.govt.nz",
  "legislation.govt.nz",
  "nzfsa.govt.nz",
];

Deno.test("§9A AU lookup: every NZ regulator host is non-inspectable, whatever the path", () => {
  for (const host of NZ_REGULATOR_HOSTS) {
    assertEquals(isForeignRegulatorHost(host, "AU"), true, host);
    for (
      const path of [
        "/product_detail?pn=19200",
        "/product-details/winter-oil",
        "/products/winter-oil",
        "/product/winter-oil",
        "/some/other/page",
        "/portfolio/oils",
      ]
    ) {
      const c = classifyUrl(`https://${host}${path}`, "AU");
      assertEquals(c.isInspectableProductPage, false, `${host}${path}`);
      assertEquals(c.isProductPageCandidate, false, `${host}${path}`);
      assertEquals(c.isOfficialLabelCandidate, false, `${host}${path}`);
    }
  }
});

Deno.test("§9B NZ lookup: every AU regulator host is non-inspectable, whatever the path", () => {
  for (const host of AU_REGULATOR_HOSTS) {
    assertEquals(isForeignRegulatorHost(host, "NZ"), true, host);
    for (const path of ["/product_detail?pn=1", "/product-details/x", "/products/x", "/page"]) {
      const c = classifyUrl(`https://${host}${path}`, "NZ");
      assertEquals(c.isInspectableProductPage, false, `${host}${path}`);
      assertEquals(c.isProductPageCandidate, false, `${host}${path}`);
      assertEquals(c.isOfficialLabelCandidate, false, `${host}${path}`);
    }
  }
});

Deno.test("§9C the underscore recognition does NOT reopen the boundary", () => {
  // The URL is still RECOGNISED as page-shaped — the classifier does not lie
  // about what the path looks like. It is refused on host identity instead,
  // which is why no future path pattern can reopen this.
  const c = classifyUrl("https://acvm.mpi.govt.nz/product_detail?pn=19200", "AU");
  assertEquals(c.kind, "product_page");
  assertEquals(c.trust, "unknown");
  assertEquals(c.isInspectableProductPage, false);
  assert(
    c.reason.includes("NZ regulator host carries no authority for AU"),
    `reason should name the jurisdiction: ${c.reason}`,
  );
});

Deno.test("§9D a foreign regulator consumes ZERO fetch attempts", async () => {
  const foreign = "https://acvm.mpi.govt.nz/product_detail?pn=19200";
  const { fetchFn, calls } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const { pages } = await inspectCandidateProductPages(
    { fetchFn },
    [foreign, VICOL_PAGE],
    "AU",
  );
  // Filtered before the queue, so it never reached a bucket and never spent
  // an attempt. VICOL is still read.
  assertEquals(calls, [VICOL_PAGE]);
  assertEquals(pages.length, 1);
  assertEquals(pages[0].pageProductName, "VICOL WINTER OIL Insecticide");
});

Deno.test("§9E two foreign leads cannot starve one legitimate registrant", async () => {
  // This is the exact shape of the defect: against a 2-attempt cap, two
  // recognised-but-foreign leads ahead of the real page would have consumed
  // the whole budget.
  const { fetchFn, calls } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const { pages } = await inspectCandidateProductPages(
    { fetchFn },
    [
      "https://acvm.mpi.govt.nz/product_detail?pn=1",
      "https://epa.govt.nz/product_detail?pn=2",
      VICOL_PAGE,
    ],
    "AU",
  );
  assertEquals(calls, [VICOL_PAGE]);
  assertEquals(calls.length, 1);
  assert(calls.length < MAX_PAGE_FETCH_ATTEMPTS, "the cap was not even reached");
  assertEquals(pages.length, 1);
});

Deno.test("§9F an unlisted REGISTRANT is untouched by the boundary", () => {
  // Vicchem is merely unrecognised, not a foreign regulator. The generic
  // unknown-host earning mechanism must survive this fix intact.
  assertEquals(isForeignRegulatorHost("vicchem.com", "AU"), false);
  const c = classifyUrl(VICOL_PAGE, "AU");
  assertEquals(c.trust, "unknown");
  assertEquals(c.kind, "product_page");
  assertEquals(c.isInspectableProductPage, true);
  // Unchanged: reading is not trusting.
  assertEquals(c.isProductPageCandidate, false);
  assertEquals(c.isOfficialLabelCandidate, false);
});

Deno.test("§9G/§9H resellers and search engines stay non-inspectable", () => {
  for (const url of ["https://www.elders.com.au/product_detail?pn=1", "https://nutrien.com.au/products/x"]) {
    const c = classifyUrl(url, "AU");
    assertEquals(c.trust, "reseller");
    assertEquals(c.isInspectableProductPage, false, url);
  }
  for (const url of ["https://www.google.com/search?q=x", "https://duckduckgo.com/products/x"]) {
    const c = classifyUrl(url, "AU");
    assertEquals(c.trust, "search_engine");
    assertEquals(c.isInspectableProductPage, false, url);
  }
});

Deno.test("§9I the CURRENT country's register and regulator are unchanged", () => {
  // The boundary must not cost the local register anything.
  const elabel = classifyUrl(APVMA_ELABEL, "AU");
  assertEquals(isForeignRegulatorHost("elabels.apvma.gov.au", "AU"), false);
  assertEquals(elabel.trust, "official_register");
  assertEquals(elabel.kind, "label_document");
  assertEquals(elabel.isOfficialLabelCandidate, true, "AU eLabel still a label candidate");

  const auRegulator = classifyUrl("https://agriculture.gov.au/docs/label-x.pdf", "AU");
  assertEquals(auRegulator.trust, "regulator");
  assertEquals(auRegulator.isOfficialLabelCandidate, true);

  // And symmetrically for NZ.
  const nzRegister = classifyUrl("https://acvm.mpi.govt.nz/label/123.pdf", "NZ");
  assertEquals(isForeignRegulatorHost("acvm.mpi.govt.nz", "NZ"), false);
  assertEquals(nzRegister.trust, "official_register");
  assertEquals(nzRegister.isOfficialLabelCandidate, true);
});

Deno.test("§9 the boundary is symmetric and registry-driven, not hardcoded", () => {
  // Neither direction is special-cased, and an unknown country code leaves
  // both regulators foreign rather than accidentally trusting one.
  assertEquals(isForeignRegulatorHost("apvma.gov.au", "AU"), false);
  assertEquals(isForeignRegulatorHost("apvma.gov.au", "NZ"), true);
  assertEquals(isForeignRegulatorHost("acvm.mpi.govt.nz", "NZ"), false);
  assertEquals(isForeignRegulatorHost("acvm.mpi.govt.nz", "AU"), true);
  assertEquals(isForeignRegulatorHost("apvma.gov.au", "US"), true);
  assertEquals(isForeignRegulatorHost("acvm.mpi.govt.nz", "US"), true);
  // Case and `www.` are normalised the same way the classifier does it.
  assertEquals(isForeignRegulatorHost("apvma.gov.au", "nz"), true);
  assertEquals(classifyUrl("https://WWW.APVMA.GOV.AU/product_detail?pn=1", "NZ").isInspectableProductPage, false);
  // A sub-host of a foreign regulator is still foreign.
  assertEquals(isForeignRegulatorHost("data.acvm.mpi.govt.nz", "AU"), true);
  // A host that merely CONTAINS a regulator name is not one.
  assertEquals(isForeignRegulatorHost("apvma.gov.au.example.com", "NZ"), false);
});

Deno.test("§8 a reseller serving product_detail is still a reseller", () => {
  // Recognition applies to every host equally; trust does not.
  const c = classifyUrl("https://www.elders.com.au/product_detail?pn=1", "AU");
  assertEquals(c.kind, "product_page");
  assertEquals(c.trust, "reseller");
  assertEquals(c.isInspectableProductPage, false);
  assertEquals(c.isProductPageCandidate, false);
});

Deno.test("§8 an arbitrary PDF is neither inspectable nor a label", async () => {
  const pdf = "https://some-unknown-host.example/files/winter-oil.pdf";
  const c = classifyUrl(pdf, "AU");
  assertEquals(c.isInspectableProductPage, false);
  assertEquals(c.isOfficialLabelCandidate, false);

  const { fetchFn, calls } = fetchByUrl({});
  await inspectCandidateProductPages({ fetchFn }, [pdf], "AU");
  assertEquals(calls.length, 0);
});

Deno.test("§8 a page whose product does not correspond promotes NOTHING", async () => {
  const { fetchFn } = fetchByUrl({ [VICOL_PAGE]: WRONG_PRODUCT_HTML });
  const inspection = await inspectCandidateProductPages({ fetchFn }, [VICOL_PAGE], "AU");
  assertEquals(inspection.pages.length, 1, "it was read — reading is not trusting");

  const projection = projectResearch(
    researchWith([VICOL_PAGE], [APVMA_ELABEL]),
    "AU",
    "apvma",
    VICOL_REGISTERED_NAME,
    inspection.pages,
  );
  assertEquals(projection.manufacturerLabelCandidate, null);
  // And with no accepted label, the page earns no product-page status either.
  assertEquals(projection.productPageCandidate, null);
  assertEquals(projection.extraction.manufacturer_label_url, null);
  assertEquals(projection.extraction.productURL, null);
  // The regulator's label is untouched by the manufacturer path failing.
  assertEquals(projection.extraction.regulator_label_url, APVMA_ELABEL);
});

Deno.test("§8 the same-host SDS is never promoted as the label", async () => {
  const { fetchFn } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const result = await inspectProductPage({ fetchFn }, VICOL_PAGE, "AU");
  if (result.outcome !== "inspected") throw new Error("expected inspection");

  const context = {
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: VICOL_REGISTERED_NAME,
    documents: result.links,
  };
  const label = selectManufacturerLabel(context);
  const sds = selectManufacturerSds(context);
  assertEquals(label.label?.url, VICOL_LABEL);
  assertEquals(sds.sds?.url, VICOL_SDS);
  assert(label.label?.url !== sds.sds?.url, "the two identities never collapse");

  // With the label link removed, the SDS, bulletin and brochure on the SAME
  // host must not stand in for it.
  const withoutLabel = {
    ...context,
    documents: result.links.filter((l) => l.url !== VICOL_LABEL),
  };
  assertEquals(selectManufacturerLabel(withoutLabel).label, null);
});

Deno.test("§8 a combined 'Label & SDS' link is refused, not resolved by guesswork", async () => {
  const combined = VICOL_HTML.replace(
    ">Product Label<",
    ">Label &amp; SDS<",
  );
  const { fetchFn } = fetchByUrl({ [VICOL_PAGE]: combined });
  const inspection = await inspectCandidateProductPages({ fetchFn }, [VICOL_PAGE], "AU");

  const projection = projectResearch(
    researchWith([VICOL_PAGE], [APVMA_ELABEL]),
    "AU",
    "apvma",
    VICOL_REGISTERED_NAME,
    inspection.pages,
  );
  assertEquals(projection.manufacturerLabelCandidate, null);
  assertEquals(projection.productPageCandidate, null);
});

Deno.test("§8 the technical bulletin and brochure are refused by wording", async () => {
  const { fetchFn } = fetchByUrl({ [VICOL_PAGE]: VICOL_HTML });
  const result = await inspectProductPage({ fetchFn }, VICOL_PAGE, "AU");
  if (result.outcome !== "inspected") throw new Error("expected inspection");

  const selection = selectManufacturerLabel({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: VICOL_REGISTERED_NAME,
    documents: result.links.filter((l) => l.url !== VICOL_LABEL),
  });
  assertEquals(selection.label, null);
  const outcomes = selection.rejected.map((r) => r.outcome);
  assert(outcomes.includes("rejected_excluded_kind"));
});

Deno.test("§8 an untrusted page cannot promote even a correctly worded label", () => {
  // The policy gate itself, independent of the queue: no trusted page, no
  // promotion, whatever the link says.
  const selection = selectManufacturerLabel({
    page: { pageUrl: VICOL_PAGE, pageProductName: "VICOL WINTER OIL Insecticide" },
    pageIsTrustedProductPage: false,
    registeredProductName: VICOL_REGISTERED_NAME,
    documents: [{ url: VICOL_LABEL, linkText: "Product Label" }],
  });
  assertEquals(selection.label, null);
  assertEquals(selection.rejected[0]?.outcome, "rejected_untrusted_page");
});
