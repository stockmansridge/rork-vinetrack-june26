// Deterministic product-page inspection — the evidence layer under the
// manufacturer-label promotion policy.
//
// The structural acceptance case is Omnia's real Sprayseal product page, whose
// document list carries four separate links — SDS, Label, Brochure, TDS — and
// whose Label link resolves to a PDF with no label signature in its filename.
// That page is a FIXTURE, not a special case: nothing below matches on
// "sprayseal", and every rule is also asserted generically.

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  decodeHtmlEntities,
  extractLinks,
  inspectCandidateProductPages,
  extractPageProductName,
  inspectProductPage,
  resolveHref,
} from "./page_inspector.ts";
import {
  selectManufacturerLabel,
  selectManufacturerSds,
} from "./linked_documents.ts";

const OMNIA_PAGE = "https://www.omnia.com.au/products/sprayseal";
const OMNIA_LABEL = "https://www.omnia.com.au/files/2025/07/Sprayseal%205L_Digi.pdf";
const REGISTERED_NAME = "SPRAYSEAL PRUNING WOUND TREATMENT";

/**
 * The shape of Omnia's Sprayseal page: a heading, a site-suffixed title, and a
 * documents list of four distinctly-labelled links. Markup detail (nested
 * spans, an icon-only anchor, relative hrefs, a literal space in one filename)
 * mirrors what real CMS output does to a parser.
 */
const OMNIA_HTML = `<!doctype html>
<html lang="en">
<head>
  <title>Sprayseal | Omnia Specialities Australia</title>
  <script>var analytics = {label: "Label", href: "/files/tracking-label.pdf"};</script>
  <style>.label { color: red; }</style>
</head>
<body>
  <header><a href="/">Home</a><a href="/products">Products</a></header>
  <h1><span class="pt">Sprayseal</span></h1>
  <p>Sprayseal is a pruning wound treatment. Apply at 30 mL/100 L.</p>
  <ul class="documents">
    <li><a href="/files/2025/07/Sprayseal-SDS.pdf">SDS</a></li>
    <li><a href="/files/2025/07/Sprayseal 5L_Digi.pdf">Label</a></li>
    <li><a href="/files/2025/07/Sprayseal-Brochure.pdf">Brochure</a></li>
    <li><a href="/files/2025/07/Sprayseal-TDS.pdf">TDS</a></li>
  </ul>
  <a href="mailto:info@omnia.com.au">Email us</a>
  <a href="#top">Back to top</a>
  <a href="javascript:void(0)">Print</a>
</body>
</html>`;

interface StubOptions {
  url?: string;
  status?: number;
  contentType?: string | null;
  contentLength?: string;
}

/** A Response with a settable `url`, so redirects can be simulated. */
function stubResponse(body: string, options: StubOptions = {}): Response {
  const headers = new Headers();
  if (options.contentType !== null) {
    headers.set("content-type", options.contentType ?? "text/html; charset=utf-8");
  }
  if (options.contentLength) headers.set("content-length", options.contentLength);
  const res = new Response(body, { status: options.status ?? 200, headers });
  Object.defineProperty(res, "url", { value: options.url ?? "", configurable: true });
  return res;
}

/**
 * A fetch stub. Accepts a FACTORY as well as a single response, because a
 * `Response` body can only be read once — reusing one across a multi-page
 * batch silently turns the second page into a "network error" and hides
 * whatever the test meant to prove.
 */
function fetchReturning(res: Response | (() => Response | never)): {
  fetchFn: typeof fetch;
  calls: string[];
} {
  const calls: string[] = [];
  const fetchFn = ((input: string | URL | Request) => {
    calls.push(String(input));
    const value = typeof res === "function" ? res() : res;
    return Promise.resolve(value);
  }) as unknown as typeof fetch;
  return { fetchFn, calls };
}

async function inspectHtml(html: string, options: StubOptions = {}, page = OMNIA_PAGE) {
  const { fetchFn } = fetchReturning(() =>
    stubResponse(html, { url: options.url ?? page, ...options })
  );
  return await inspectProductPage({ fetchFn }, page, "AU");
}

// ---------------------------------------------------------------------------
// The acceptance case, end to end through the real policy
// ---------------------------------------------------------------------------

Deno.test("ACCEPTANCE: the real page yields exactly the Label PDF", async () => {
  const result = await inspectHtml(OMNIA_HTML);
  assertEquals(result.outcome, "inspected");
  if (result.outcome !== "inspected") return;

  assertEquals(result.pageProductName, "Sprayseal");
  assertEquals(result.pageProductNameSource, "h1");

  // The selection runs through the UNCHANGED promotion policy. The inspector
  // only supplies what the page actually says.
  const selection = selectManufacturerLabel({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: result.links,
  });
  assertEquals(selection.label?.url, OMNIA_LABEL);
  assertEquals(selection.label?.linkText, "Label");
});

Deno.test("ACCEPTANCE: brochure and TDS are never promoted as label evidence", async () => {
  const result = await inspectHtml(OMNIA_HTML);
  if (result.outcome !== "inspected") throw new Error("expected inspection");

  // Remove the label link: the page still offers three PDFs on the registrant's
  // own host, and not one of them may stand in for an approved label.
  const withoutLabel = result.links.filter((l) => l.url !== OMNIA_LABEL);
  const selection = selectManufacturerLabel({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: withoutLabel,
  });
  assertEquals(selection.label, null);
  const kinds = selection.rejected.map((r) => r.outcome);
  assert(kinds.includes("rejected_excluded_kind"));
});

Deno.test("ACCEPTANCE: the SDS is retained under its own identity", async () => {
  const result = await inspectHtml(OMNIA_HTML);
  if (result.outcome !== "inspected") throw new Error("expected inspection");

  const sds = selectManufacturerSds({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: result.links,
  });
  assertEquals(sds.sds?.url, "https://www.omnia.com.au/files/2025/07/Sprayseal-SDS.pdf");

  // And it is NOT the label — the two identities never collapse.
  const label = selectManufacturerLabel({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: result.links,
  });
  assert(label.label?.url !== sds.sds?.url);
});

Deno.test("script and style contents are not read as links", async () => {
  // The fixture hides a `/files/tracking-label.pdf` inside a <script>. A naive
  // regex parser would promote it: the filename even says "label".
  const result = await inspectHtml(OMNIA_HTML);
  if (result.outcome !== "inspected") throw new Error("expected inspection");
  assert(!result.links.some((l) => l.url.includes("tracking-label")));
});

// ---------------------------------------------------------------------------
// href resolution
// ---------------------------------------------------------------------------

Deno.test("relative hrefs resolve against the page URL", () => {
  const { links } = extractLinks(
    `<a href="/files/a.pdf">Label</a><a href="../b.pdf">Label</a><a href="c.pdf">Label</a>`,
    "https://www.omnia.com.au/products/sprayseal",
  );
  assertEquals(links.map((l) => l.url), [
    "https://www.omnia.com.au/files/a.pdf",
    "https://www.omnia.com.au/b.pdf",
    "https://www.omnia.com.au/products/c.pdf",
  ]);
});

Deno.test("a literal space in an href is encoded, not dropped", async () => {
  // The real Omnia label link is written with a space and must arrive as
  // %20 — this is precisely the URL that URL-only classification refuses.
  const result = await inspectHtml(OMNIA_HTML);
  if (result.outcome !== "inspected") throw new Error("expected inspection");
  const label = result.links.find((l) => l.linkText === "Label");
  assertEquals(label?.url, OMNIA_LABEL);
  assertEquals(label?.rawHref, "/files/2025/07/Sprayseal 5L_Digi.pdf");
});

Deno.test("existing percent-encoding is preserved exactly", () => {
  const { links } = extractLinks(
    `<a href="/files/Sprayseal%205L_Digi.pdf">Label</a>`,
    OMNIA_PAGE,
  );
  assertEquals(links[0].url, "https://www.omnia.com.au/files/Sprayseal%205L_Digi.pdf");
});

Deno.test("non-document schemes and bare fragments are skipped", () => {
  assertEquals(resolveHref("mailto:info@omnia.com.au", OMNIA_PAGE), null);
  assertEquals(resolveHref("tel:+61390000000", OMNIA_PAGE), null);
  assertEquals(resolveHref("javascript:void(0)", OMNIA_PAGE), null);
  assertEquals(resolveHref("data:application/pdf;base64,AAAA", OMNIA_PAGE), null);
  assertEquals(resolveHref("#documents", OMNIA_PAGE), null);
  assertEquals(resolveHref("   ", OMNIA_PAGE), null);
});

Deno.test("a malformed href is skipped, not guessed at", () => {
  assertEquals(resolveHref("ht!tp://omnia.com.au/x.pdf", "not-a-url"), null);
  const { links } = extractLinks(`<a href="http://">Label</a><a>Label</a>`, OMNIA_PAGE);
  assertEquals(links.length, 0);
});

Deno.test("the fragment is dropped so one PDF is one document", () => {
  const { links } = extractLinks(
    `<a href="/files/a.pdf#page=2">Label</a><a href="/files/a.pdf">Label</a>`,
    OMNIA_PAGE,
  );
  assertEquals(links.length, 1);
});

// ---------------------------------------------------------------------------
// Host handling
// ---------------------------------------------------------------------------

Deno.test("www and apex are the same registrant host", () => {
  const { links } = extractLinks(
    `<a href="https://www.omnia.com.au/files/a.pdf">Label</a>`,
    "https://omnia.com.au/products/sprayseal",
  );
  assertEquals(links[0].sameHost, true);
});

Deno.test("a subdomain of the registrant is still the registrant", () => {
  const { links } = extractLinks(
    `<a href="https://cdn.omnia.com.au/files/a.pdf">Label</a>`,
    OMNIA_PAGE,
  );
  assertEquals(links[0].sameHost, true);
});

Deno.test("an off-domain PDF is marked and REFUSED, however it is labelled", () => {
  const { links } = extractLinks(
    `<a href="https://cdn.thirdparty.example/files/label.pdf">Product Label</a>`,
    OMNIA_PAGE,
  );
  assertEquals(links[0].sameHost, false);

  const selection = selectManufacturerLabel({
    page: { pageUrl: OMNIA_PAGE, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: links,
  });
  assertEquals(selection.label, null);
  assertEquals(selection.rejected[0].outcome, "rejected_cross_host");
});

// ---------------------------------------------------------------------------
// Page identity
// ---------------------------------------------------------------------------

Deno.test("the h1 states the page's product", () => {
  const r = extractPageProductName(`<h1 class="x"><span>Sprayseal</span></h1>`);
  assertEquals(r, { name: "Sprayseal", source: "h1" });
});

Deno.test("with no h1 the title is used, minus the site-name suffix", () => {
  const r = extractPageProductName(
    `<head><title>Sprayseal | Omnia Specialities Australia</title></head><body></body>`,
  );
  assertEquals(r, { name: "Sprayseal", source: "title" });
});

Deno.test("with neither h1 nor title there is no page identity", async () => {
  const html = `<html><body><a href="/files/a.pdf">Label</a></body></html>`;
  const result = await inspectHtml(html);
  if (result.outcome !== "inspected") throw new Error("expected inspection");
  assertEquals(result.pageProductName, "");
  assertEquals(result.pageProductNameSource, "none");

  // An unidentified page cannot confer label status: `nameCorresponds` has
  // nothing to check, so promotion fails closed.
  const selection = selectManufacturerLabel({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: result.links,
  });
  assertEquals(selection.label, null);
});

Deno.test("a page about a DIFFERENT product promotes nothing", async () => {
  const html = OMNIA_HTML.replace(
    "<span class=\"pt\">Sprayseal</span>",
    "<span class=\"pt\">Vine Guard Copper Fungicide</span>",
  );
  const result = await inspectHtml(html);
  if (result.outcome !== "inspected") throw new Error("expected inspection");
  assertEquals(result.pageProductName, "Vine Guard Copper Fungicide");

  const selection = selectManufacturerLabel({
    page: { pageUrl: result.finalUrl, pageProductName: result.pageProductName },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: result.links,
  });
  assertEquals(selection.label, null);
  assert(selection.rejected.some((r) => r.outcome === "rejected_product_mismatch"));
});

// ---------------------------------------------------------------------------
// Entities and wording
// ---------------------------------------------------------------------------

Deno.test("HTML entities are decoded before the wording is judged", () => {
  assertEquals(decodeHtmlEntities("Label &amp; SDS"), "Label & SDS");
  assertEquals(decodeHtmlEntities("Label&nbsp;(PDF)"), "Label (PDF)");
  assertEquals(decodeHtmlEntities("Sprayseal&#174;"), "Sprayseal\u00ae");
  assertEquals(decodeHtmlEntities("Sprayseal&#xAE;"), "Sprayseal\u00ae");
  assertEquals(decodeHtmlEntities("100% &unknownentity; left"), "100% &unknownentity; left");
});

Deno.test("a combined 'Label &amp; SDS' link is REFUSED once decoded", () => {
  // Encoded, the text reads "Label &amp; SDS" and the SDS exclusion would miss
  // — promoting a link that might resolve to either document.
  const { links } = extractLinks(
    `<a href="/files/combined.pdf">Label &amp; SDS</a>`,
    OMNIA_PAGE,
  );
  assertEquals(links[0].linkText, "Label & SDS");
  const selection = selectManufacturerLabel({
    page: { pageUrl: OMNIA_PAGE, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: links,
  });
  assertEquals(selection.label, null);
  assertEquals(selection.rejected[0].outcome, "rejected_excluded_kind");
});

Deno.test("title and aria-label supply wording an icon link lacks", () => {
  const { links } = extractLinks(
    `<a href="/files/a.pdf" title="Sprayseal Label (PDF)"><img src="/i/pdf.svg"></a>` +
      `<a href="/files/b.pdf" aria-label="Safety Data Sheet"><img src="/i/pdf.svg"></a>`,
    OMNIA_PAGE,
  );
  assertEquals(links[0].anchorText, "");
  assertEquals(links[0].linkText, "Sprayseal Label (PDF)");
  assertEquals(links[1].linkText, "Safety Data Sheet");

  // And the wording still only INFORMS the policy — the SDS stays refused.
  const selection = selectManufacturerLabel({
    page: { pageUrl: OMNIA_PAGE, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents: links,
  });
  assertEquals(selection.label?.url, "https://www.omnia.com.au/files/a.pdf");
});

Deno.test("the same document linked twice keeps the richer wording", () => {
  const { links } = extractLinks(
    `<a href="/files/a.pdf"><img src="/i.svg"></a><a href="/files/a.pdf">Product Label</a>`,
    OMNIA_PAGE,
  );
  assertEquals(links.length, 1);
  assertEquals(links[0].linkText, "Product Label");
});

// ---------------------------------------------------------------------------
// Transport: every failure is named, and none of them throws
// ---------------------------------------------------------------------------

Deno.test("an untrusted page is never even fetched", async () => {
  const { fetchFn, calls } = fetchReturning(() => stubResponse(OMNIA_HTML));
  const search = await inspectProductPage(
    { fetchFn },
    "https://www.google.com/search?q=sprayseal+label",
    "AU",
  );
  assertEquals(search.outcome, "rejected_untrusted_page");

  const reseller = await inspectProductPage(
    { fetchFn },
    "https://www.elders.com.au/products/sprayseal",
    "AU",
  );
  assertEquals(reseller.outcome, "rejected_untrusted_page");

  // The guard runs BEFORE the network, so discovery-only hosts are not even
  // contacted on VineTrack's behalf.
  assertEquals(calls.length, 0);
});

Deno.test("a malformed page URL is rejected without a fetch", async () => {
  const { fetchFn, calls } = fetchReturning(() => stubResponse(OMNIA_HTML));
  assertEquals(
    (await inspectProductPage({ fetchFn }, "omnia.com.au/products/sprayseal", "AU")).outcome,
    "rejected_malformed_url",
  );
  assertEquals((await inspectProductPage({ fetchFn }, "", "AU")).outcome, "rejected_malformed_url");
  assertEquals(calls.length, 0);
});

Deno.test("an HTTP error is not a product page", async () => {
  const result = await inspectHtml("<html>Not found</html>", { status: 404 });
  assertEquals(result.outcome, "rejected_http_error");
  assert(result.outcome !== "inspected" && result.reason.includes("404"));
});

Deno.test("a non-HTML body is refused", async () => {
  assertEquals(
    (await inspectHtml("%PDF-1.4", { contentType: "application/pdf" })).outcome,
    "rejected_not_html",
  );
  assertEquals(
    (await inspectHtml("{}", { contentType: "application/json" })).outcome,
    "rejected_not_html",
  );
  assertEquals(
    (await inspectHtml("<html></html>", { contentType: null })).outcome,
    "rejected_not_html",
  );
});

Deno.test("an implausibly large page is refused before buffering", async () => {
  const result = await inspectHtml(OMNIA_HTML, { contentLength: String(50 * 1024 * 1024) });
  assertEquals(result.outcome, "rejected_too_large");
});

Deno.test("a timeout or network failure fails CLOSED and never throws", async () => {
  const { fetchFn } = fetchReturning(() => {
    throw new DOMException("The signal has been aborted", "AbortError");
  });
  const result = await inspectProductPage({ fetchFn }, OMNIA_PAGE, "AU");
  assertEquals(result.outcome, "rejected_network_error");
  assert(result.outcome !== "inspected" && result.reason.includes("aborted"));
});

Deno.test("links resolve against the FINAL url after a redirect", async () => {
  // The page redirected to a new path; a relative href must resolve against
  // where the document actually came from, not where it was requested.
  const result = await inspectHtml(
    `<h1>Sprayseal</h1><a href="Sprayseal-Label.pdf">Label</a>`,
    { url: "https://www.omnia.com.au/products/vineyard/sprayseal-pruning-wound-treatment" },
  );
  if (result.outcome !== "inspected") throw new Error("expected inspection");
  assertEquals(
    result.links[0].url,
    "https://www.omnia.com.au/products/vineyard/Sprayseal-Label.pdf",
  );
});

Deno.test("a redirect OFF the registrant domain ends the chain of custody", async () => {
  const result = await inspectHtml(OMNIA_HTML, {
    url: "https://www.marketplace.example/listing/sprayseal",
  });
  assertEquals(result.outcome, "rejected_off_host_redirect");
});

Deno.test("a redirect within the registrant domain is fine", async () => {
  const result = await inspectHtml(OMNIA_HTML, {
    url: "https://omnia.com.au/products/sprayseal",
  });
  assertEquals(result.outcome, "inspected");
});

Deno.test("the anchor cap bounds a page that links to everything", async () => {
  const many = Array.from(
    { length: 500 },
    (_, i) => `<a href="/files/doc-${i}.pdf">Doc ${i}</a>`,
  ).join("");
  const result = await inspectHtml(`<h1>Sprayseal</h1>${many}`);
  if (result.outcome !== "inspected") throw new Error("expected inspection");
  assertEquals(result.links.length, 400);
  assertEquals(result.truncated, true);
});

// ---------------------------------------------------------------------------
// Batch inspection for one lookup
// ---------------------------------------------------------------------------

Deno.test("only pages that already classify as trusted are fetched", async () => {
  const { fetchFn, calls } = fetchReturning(() => stubResponse(OMNIA_HTML, { url: OMNIA_PAGE }));
  const { pages, attempts } = await inspectCandidateProductPages(
    { fetchFn },
    [
      "https://www.google.com/search?q=sprayseal",
      "https://www.elders.com.au/products/sprayseal",
      "https://www.omnia.com.au/products/sprayseal",
    ],
    "AU",
  );
  // One fetch, for the one page that could ever qualify. The page budget is
  // never spent proving a search engine is a search engine.
  assertEquals(calls.length, 1);
  assertEquals(pages.length, 1);
  assertEquals(attempts.length, 1);
  assertEquals(attempts[0].outcome, "inspected");
});

Deno.test("the page budget caps how many registrant pages are read", async () => {
  const { fetchFn, calls } = fetchReturning(() => stubResponse(OMNIA_HTML, { url: OMNIA_PAGE }));
  const { pages } = await inspectCandidateProductPages(
    { fetchFn },
    [
      "https://www.omnia.com.au/products/sprayseal",
      "https://www.omnia.com.au/products/sprayseal-5l",
      "https://www.omnia.com.au/products/sprayseal-20l",
      "https://www.omnia.com.au/products/sprayseal-200l",
    ],
    "AU",
  );
  assertEquals(calls.length, 2);
  assertEquals(pages.length, 2);
});

Deno.test("duplicate leads are inspected once", async () => {
  const { fetchFn, calls } = fetchReturning(() => stubResponse(OMNIA_HTML, { url: OMNIA_PAGE }));
  await inspectCandidateProductPages(
    { fetchFn },
    [OMNIA_PAGE, OMNIA_PAGE, OMNIA_PAGE],
    "AU",
  );
  assertEquals(calls.length, 1);
});

Deno.test("a failing registrant site degrades enrichment, not the lookup", async () => {
  const { fetchFn } = fetchReturning(() => {
    throw new TypeError("error sending request for url");
  });
  const { pages, attempts } = await inspectCandidateProductPages(
    { fetchFn },
    [OMNIA_PAGE],
    "AU",
  );
  assertEquals(pages.length, 0);
  assertEquals(attempts[0].outcome, "rejected_network_error");
});

Deno.test("an exhausted time budget stops further page fetches", async () => {
  // A registrant site that answers slowly must not hold the lookup open.
  let tick = 0;
  const clock = () => new Date(1_800_000_000_000 + (tick++ === 0 ? 0 : 30_000));
  const { fetchFn, calls } = fetchReturning(() => stubResponse(OMNIA_HTML, { url: OMNIA_PAGE }));
  const { attempts } = await inspectCandidateProductPages(
    { fetchFn, now: clock },
    ["https://www.omnia.com.au/products/sprayseal", "https://www.omnia.com.au/products/other"],
    "AU",
  );
  assertEquals(calls.length, 0);
  assertEquals(attempts[0].outcome, "rejected_network_error");
  assert(attempts[0].reason.includes("budget"));
});

// ---------------------------------------------------------------------------
// The inspector reads RELATIONSHIPS, never facts
// ---------------------------------------------------------------------------

Deno.test("a rate printed on the product page never becomes a rate", async () => {
  // The real Omnia page states "30 mL/100 L" in its marketing copy, and the
  // correct label rate happens to be 30 mL/100 L. That coincidence is exactly
  // the trap: a page-scraped number that agrees with the label today would
  // still be marketing copy, and would keep being served after the label
  // changed. The inspector returns links and a page name. Nothing else.
  const result = await inspectHtml(OMNIA_HTML);
  if (result.outcome !== "inspected") throw new Error("expected inspection");

  const keys = Object.keys(result).sort();
  assertEquals(keys, [
    "finalUrl",
    "links",
    "outcome",
    "pageProductName",
    "pageProductNameSource",
    "pageUrl",
    "truncated",
  ]);
  const serialised = JSON.stringify(result);
  assert(!serialised.includes("30 mL"), "no rate text is carried out of the page");
});
