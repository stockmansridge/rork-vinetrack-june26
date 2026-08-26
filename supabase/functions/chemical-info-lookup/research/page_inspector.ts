// Deterministic inspection of ONE already-trusted registrant product page.
//
// # Why this exists
//
// `linked_documents.ts` holds the promotion POLICY: a registrant PDF becomes
// manufacturer-label evidence only when it was linked, as a label, from the
// registrant's own product page for the register-resolved product. That policy
// is sound. What it lacked was a trustworthy source of the relationship it
// depends on.
//
// Until now `link_text` / `linked_from_url` arrived from the research model.
// That makes the strongest evidence in the chain the least reproducible part
// of it: a model that misremembers an anchor label, or omits the field on a
// slow day, silently changes what VineTrack believes an approved label is.
// Model recall is a fine way to FIND a page. It is not a way to establish what
// a document is.
//
// So the server reads the page itself. Same policy, deterministic input:
// fetch the one page, parse its anchors, hand them to the same
// `selectManufacturerLabel()` gate. Two runs against the same HTML produce the
// same decision, and the decision can be re-derived by hand from the bytes.
//
// # Deliberately bounded
//
//   * ONE page per call. No recursion, no link-following, no crawl frontier.
//     A crawler that follows links is a crawler that eventually fetches
//     something nobody classified.
//   * The page must ALREADY classify as a trusted registrant product page.
//     This module never widens trust; it only reads what trust already allows.
//   * Redirects are followed, but must LAND on the same registrant host — a
//     product page that redirects to a marketplace is not evidence.
//   * HTTP must succeed and the body must be HTML. A 404 page, a JSON error
//     or a PDF is not a product page.
//   * Byte and link caps, and a hard timeout.
//
// # Fail closed, fail quiet
//
// Every failure returns a NAMED negative result. Nothing here throws, so a
// registrant's website being down degrades manufacturer enrichment and
// nothing else: register identity, chemistry and regulator label evidence are
// untouched. No inspection means no promotion — never a guess.

import { classifyUrl, hostOf } from "./classify.ts";
import type { LinkedDocument } from "./linked_documents.ts";

/** Per-attempt network timeout. Matches the label-document fetcher. */
const FETCH_TIMEOUT_MS = 6000;
/**
 * A product page far past this is not a product page.
 *
 * Enforced as a HARD read bound, not a post-hoc trim: the body is consumed
 * incrementally and the stream is cancelled the moment the count is exceeded,
 * so a hostile or misconfigured host cannot make this function buffer an
 * unbounded response before the limit is noticed.
 */
export const MAX_PAGE_BYTES = 2 * 1024 * 1024;
/** Anchor cap — a document list is small; a sitemap is not what we want. */
const MAX_LINKS = 400;
/**
 * At most this many product-page fetch ATTEMPTS per lookup.
 *
 * Attempts, not successes. Counting successful inspections would let a run of
 * fast failures (404, wrong content-type, off-host redirect) keep the loop
 * going, so a registrant serving errors on every candidate URL could draw far
 * more than two requests out of a single lookup.
 */
export const MAX_PAGE_FETCH_ATTEMPTS = 2;
/** Total wall-clock budget for ALL inspection in one lookup. */
const INSPECTION_BUDGET_MS = 9000;

export type PageInspectionOutcome =
  | "inspected"
  | "rejected_untrusted_page"
  | "rejected_malformed_url"
  | "rejected_off_host_redirect"
  | "rejected_http_error"
  | "rejected_not_html"
  | "rejected_too_large"
  | "rejected_network_error";

/** One anchor found on the page, resolved and normalised. */
export interface InspectedLink extends LinkedDocument {
  /** The href exactly as the page wrote it, before resolution. */
  rawHref: string;
  /** Anchor text alone, entity-decoded and whitespace-collapsed. */
  anchorText: string;
  /** `title` / `aria-label`, when they add wording the anchor text lacked. */
  attributeText: string | null;
  /** Whether the link stays on the page's own registrant domain. */
  sameHost: boolean;
}

export interface InspectedPage {
  outcome: "inspected";
  /** The URL requested. */
  pageUrl: string;
  /** The URL actually read, after redirects. Link resolution uses THIS. */
  finalUrl: string;
  /**
   * The product identity the PAGE states — `<h1>` preferred, `<title>` as
   * fallback. Fed to the policy's `nameCorresponds` check, never to identity.
   */
  pageProductName: string;
  pageProductNameSource: "h1" | "title" | "none";
  links: InspectedLink[];
  /** True when the anchor cap or byte cap truncated what was read. */
  truncated: boolean;
}

export interface PageInspectionFailure {
  outcome: Exclude<PageInspectionOutcome, "inspected">;
  pageUrl: string;
  reason: string;
}

export type PageInspectionResult = InspectedPage | PageInspectionFailure;

export interface PageInspectorDeps {
  fetchFn: typeof fetch;
}

// ---------------------------------------------------------------------------
// HTML text handling
// ---------------------------------------------------------------------------

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  ndash: "\u2013",
  mdash: "\u2014",
  rsquo: "\u2019",
  lsquo: "\u2018",
  ldquo: "\u201c",
  rdquo: "\u201d",
  reg: "\u00ae",
  trade: "\u2122",
  copy: "\u00a9",
  deg: "\u00b0",
  hellip: "\u2026",
};

/**
 * Decode the HTML entities a CMS actually emits.
 *
 * This matters for correctness, not tidiness: an anchor written as
 * `Label &amp; SDS` must reach the policy as `Label & SDS` so the combined-link
 * exclusion fires. Left encoded, the `&amp;` would read as ordinary text and a
 * combined link could be promoted as a label.
 */
export function decodeHtmlEntities(input: string): string {
  return input.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g, (match, body: string) => {
    if (body.startsWith("#")) {
      const isHex = body[1] === "x" || body[1] === "X";
      const code = Number.parseInt(isHex ? body.slice(2) : body.slice(1), isHex ? 16 : 10);
      if (!Number.isFinite(code) || code <= 0 || code > 0x10ffff) return match;
      try {
        return String.fromCodePoint(code);
      } catch {
        return match;
      }
    }
    const named = NAMED_ENTITIES[body.toLowerCase()];
    return named ?? match;
  });
}

/** Strip tags, decode entities, collapse whitespace. */
function textOf(html: string): string {
  return decodeHtmlEntities(html.replace(/<[^>]*>/g, " "))
    .replace(/\s+/g, " ")
    .trim();
}

/** Remove regions whose text content is not page content. */
function stripNonContent(html: string): string {
  return html
    .replace(/<script\b[\s\S]*?<\/script\s*>/gi, " ")
    .replace(/<style\b[\s\S]*?<\/style\s*>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ");
}

const ATTR_PATTERN = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g;

/** Parse an anchor's attribute string into a lowercase-keyed map. */
export function parseAttributes(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  ATTR_PATTERN.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = ATTR_PATTERN.exec(raw)) !== null) {
    const key = m[1].toLowerCase();
    const value = m[2] ?? m[3] ?? m[4] ?? "";
    if (!(key in out)) out[key] = decodeHtmlEntities(value).trim();
  }
  return out;
}

/**
 * Resolve one href against the page's final URL.
 *
 * Returns null for anything that is not a fetchable http(s) document:
 * `mailto:`, `tel:`, `javascript:`, `data:`, bare fragments and malformed
 * hrefs. Percent-encoding is PRESERVED as the page wrote it, which is what
 * keeps `Sprayseal%205L_Digi.pdf` addressable; a literal space is encoded by
 * the URL parser rather than being carried into a request.
 */
export function resolveHref(rawHref: string, baseUrl: string): string | null {
  const href = rawHref.trim();
  if (!href || href.startsWith("#")) return null;
  if (/^(mailto|tel|javascript|data|file|ftp|sms):/i.test(href)) return null;
  let resolved: URL;
  try {
    resolved = new URL(href, baseUrl);
  } catch {
    return null;
  }
  if (resolved.protocol !== "https:" && resolved.protocol !== "http:") return null;
  // The fragment addresses a position inside a document, never a different
  // document — dropping it keeps one PDF from appearing as several links.
  resolved.hash = "";
  return resolved.toString();
}

/** Registrable-domain comparison, so `www.` and sub-hosts still match. */
function sameRegistrableHost(a: string, b: string): boolean {
  const ha = hostOf(a);
  const hb = hostOf(b);
  if (!ha || !hb) return false;
  if (ha === hb) return true;
  return ha.endsWith(`.${hb}`) || hb.endsWith(`.${ha}`);
}

/**
 * Extract the product identity the page states about itself.
 *
 * `<h1>` first because that is the page's own heading for its subject. The
 * `<title>` is a fallback and is trimmed of the site-name suffix CMSs append
 * ("Sprayseal | Omnia Australia"), which would otherwise defeat name
 * correspondence for a page that is perfectly well identified.
 */
export function extractPageProductName(
  html: string,
): { name: string; source: "h1" | "title" | "none" } {
  const h1 = /<h1\b[^>]*>([\s\S]*?)<\/h1\s*>/i.exec(html);
  if (h1) {
    const name = textOf(h1[1]);
    if (name) return { name, source: "h1" };
  }
  const title = /<title\b[^>]*>([\s\S]*?)<\/title\s*>/i.exec(html);
  if (title) {
    const full = textOf(title[1]);
    // Take the leading segment: the subject comes before the separator.
    const lead = full.split(/\s+[|\u2013\u2014\u00b7]\s+/)[0]?.trim() ?? full;
    const name = lead || full;
    if (name) return { name, source: "title" };
  }
  return { name: "", source: "none" };
}

const ANCHOR_PATTERN = /<a\b([^>]*)>([\s\S]*?)<\/a\s*>/gi;

/**
 * Extract every resolvable anchor from a page's HTML.
 *
 * Exported so the parser can be tested against real-world markup directly,
 * with no network and no fetch stubbing.
 */
export function extractLinks(
  html: string,
  baseUrl: string,
): { links: InspectedLink[]; truncated: boolean } {
  const cleaned = stripNonContent(html);
  const links: InspectedLink[] = [];
  const seen = new Set<string>();
  let truncated = false;

  ANCHOR_PATTERN.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = ANCHOR_PATTERN.exec(cleaned)) !== null) {
    if (links.length >= MAX_LINKS) {
      truncated = true;
      break;
    }
    const attrs = parseAttributes(m[1] ?? "");
    const rawHref = attrs.href ?? "";
    const url = resolveHref(rawHref, baseUrl);
    if (!url) continue;

    const anchorText = textOf(m[2] ?? "");
    // `title` and `aria-label` frequently carry the wording an icon-only or
    // image link lacks ("Download the Sprayseal label"). Included because
    // omitting them loses real evidence — and it is only ever WORDING: the
    // policy still decides what the wording means.
    const attrPieces = [attrs.title, attrs["aria-label"]]
      .map((v) => (v ?? "").trim())
      .filter((v) => v.length > 0 && v.toLowerCase() !== anchorText.toLowerCase());
    const attributeText = attrPieces.length ? attrPieces.join(" ") : null;

    const linkText = [anchorText, attributeText].filter((v) => v && v.length).join(" ").trim();

    // Same URL linked twice (icon + text) is one document. Keep the entry
    // with the richer wording rather than whichever came first.
    const existingIndex = seen.has(url) ? links.findIndex((l) => l.url === url) : -1;
    if (existingIndex >= 0) {
      if (linkText.length > links[existingIndex].linkText.length) {
        links[existingIndex] = {
          ...links[existingIndex],
          linkText,
          anchorText,
          attributeText,
        };
      }
      continue;
    }
    seen.add(url);

    links.push({
      url,
      linkText,
      rawHref,
      anchorText,
      attributeText,
      sameHost: sameRegistrableHost(url, baseUrl),
    });
  }

  return { links, truncated };
}

// ---------------------------------------------------------------------------
// Bounded fetch
// ---------------------------------------------------------------------------

function isHtmlContentType(value: string | null): boolean {
  if (!value) return false;
  const type = value.split(";")[0]?.trim().toLowerCase() ?? "";
  return type === "text/html" || type === "application/xhtml+xml";
}

type BoundedBody =
  | { ok: true; html: string }
  | { ok: false; bytesRead: number };

/**
 * Read a response body incrementally, refusing to hold more than
 * `MAX_PAGE_BYTES` of it.
 *
 * # Why streaming rather than `res.text()` followed by a length check
 *
 * `await res.text()` buffers the WHOLE body first. Trimming afterwards makes
 * the string shorter but does nothing about the memory already committed, so a
 * host that omits Content-Length — or declares a false one — decides how much
 * this function allocates. On a shared Edge runtime that is a denial-of-service
 * surface, not a tidiness issue.
 *
 * Here the count is checked per chunk and the stream is CANCELLED as soon as it
 * is exceeded, so peak memory is bounded by the limit plus one chunk.
 *
 * UTF-8 is decoded with `{ stream: true }` so a multi-byte character split
 * across a chunk boundary is reassembled rather than becoming replacement
 * characters — which matters here, because a mangled `®` or `–` inside a
 * heading is a mangled product name, and product names decide correspondence.
 */
async function readBoundedHtml(res: Response): Promise<BoundedBody> {
  if (!res.body) {
    // No stream to meter (some runtimes give a null body for empty responses).
    const text = await res.text();
    const size = new TextEncoder().encode(text).byteLength;
    return size > MAX_PAGE_BYTES ? { ok: false, bytesRead: size } : { ok: true, html: text };
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder("utf-8");
  let bytesRead = 0;
  let html = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value || value.byteLength === 0) continue;

      bytesRead += value.byteLength;
      if (bytesRead > MAX_PAGE_BYTES) {
        try {
          await reader.cancel();
        } catch { /* ignore */ }
        return { ok: false, bytesRead };
      }
      html += decoder.decode(value, { stream: true });
    }
    // Flush any trailing partial sequence.
    html += decoder.decode();
    return { ok: true, html };
  } finally {
    try {
      reader.releaseLock();
    } catch { /* already released by cancel() */ }
  }
}

/**
 * Fetch and inspect ONE trusted registrant product page.
 *
 * The page must already classify as a registrant product page for this
 * country. That check is repeated here rather than trusted from the caller:
 * this function performs a network request on a URL, and the guard that
 * decides which URLs deserve one belongs next to the request.
 */
export async function inspectProductPage(
  deps: PageInspectorDeps & { now?: () => Date },
  pageUrl: string,
  countryCode: string,
): Promise<PageInspectionResult> {
  const trimmed = (pageUrl ?? "").trim();
  if (!/^https?:\/\//i.test(trimmed)) {
    return {
      outcome: "rejected_malformed_url",
      pageUrl: trimmed,
      reason: "not an absolute http(s) URL",
    };
  }
  let requested: URL;
  try {
    requested = new URL(trimmed);
  } catch {
    return {
      outcome: "rejected_malformed_url",
      pageUrl: trimmed,
      reason: "URL could not be parsed",
    };
  }

  const classification = classifyUrl(requested.toString(), countryCode);
  if (!classification.isInspectableProductPage) {
    return {
      outcome: "rejected_untrusted_page",
      pageUrl: trimmed,
      reason:
        `not a trusted registrant product page (${classification.trust}/` +
        `${classification.kind}) — search engines and resellers are discovery ` +
        `routes, never pages worth reading for evidence`,
    };
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await deps.fetchFn(requested.toString(), {
      headers: {
        "Accept": "text/html,application/xhtml+xml",
        "User-Agent":
          "Mozilla/5.0 (compatible; VineTrack-ChemicalLookup/1.0; +https://rork.app)",
      },
      redirect: "follow",
      signal: ctrl.signal,
    });

    const finalUrl = (res.url && /^https?:\/\//i.test(res.url))
      ? res.url
      : requested.toString();

    if (!res.ok) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return {
        outcome: "rejected_http_error",
        pageUrl: trimmed,
        reason: `HTTP ${res.status} — a page that did not load is not evidence`,
      };
    }

    // A redirect that leaves the registrant's domain ends the chain of
    // custody: whatever answered is not the registrant's product page.
    if (!sameRegistrableHost(finalUrl, requested.toString())) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return {
        outcome: "rejected_off_host_redirect",
        pageUrl: trimmed,
        reason: `redirected off the registrant domain to ${hostOf(finalUrl) || "an unparseable host"}`,
      };
    }

    if (!isHtmlContentType(res.headers.get("content-type"))) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return {
        outcome: "rejected_not_html",
        pageUrl: trimmed,
        reason:
          `content-type ${res.headers.get("content-type") ?? "absent"} is not HTML`,
      };
    }

    // A DECLARED oversize is refused without reading a byte. This is an
    // optimisation only — an absent or dishonest Content-Length is caught by
    // the incremental read below, which is the actual bound.
    const declared = Number.parseInt(res.headers.get("content-length") ?? "", 10);
    if (Number.isFinite(declared) && declared > MAX_PAGE_BYTES) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return {
        outcome: "rejected_too_large",
        pageUrl: trimmed,
        reason: `declared ${declared} bytes, over the ${MAX_PAGE_BYTES}-byte page budget`,
      };
    }

    const body = await readBoundedHtml(res);
    if (!body.ok) {
      // Deliberately NOT parsed. A truncated page is a page whose document
      // list may have been cut in half, and half a document list is an
      // excellent way to promote the wrong PDF as the label.
      return {
        outcome: "rejected_too_large",
        pageUrl: trimmed,
        reason:
          `response exceeded the ${MAX_PAGE_BYTES}-byte page budget (stopped ` +
          `after ${body.bytesRead} bytes); an oversized page is refused, never ` +
          `parsed from a truncated body`,
      };
    }

    const { name, source } = extractPageProductName(body.html);
    const { links, truncated } = extractLinks(body.html, finalUrl);

    return {
      outcome: "inspected",
      pageUrl: trimmed,
      finalUrl,
      pageProductName: name,
      pageProductNameSource: source,
      links,
      truncated,
    };
  } catch (err) {
    // Timeout, DNS failure, TLS failure, aborted body — all the same answer:
    // no evidence was obtained, so nothing is promoted. The lookup continues.
    return {
      outcome: "rejected_network_error",
      pageUrl: trimmed,
      reason: err instanceof Error ? err.message : String(err),
    };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Batch inspection for one lookup
// ---------------------------------------------------------------------------

/** What was attempted, and how it ended. Logged for §11-style auditing. */
export interface PageInspectionAttempt {
  url: string;
  outcome: PageInspectionOutcome;
  reason: string;
  linkCount: number;
}

/**
 * Inspect the candidate product pages for ONE lookup, within a hard budget.
 *
 * Discovery hands this function a list of URLs it believes are the registrant's
 * product page — from the research model's candidates and from its relationship
 * hints. Those are LEADS. This function makes at most
 * `MAX_PAGE_FETCH_ATTEMPTS` fetch ATTEMPTS among the ones that already classify
 * as trusted registrant product pages, and stops early once the wall-clock
 * budget is spent, so a slow or broken registrant site degrades enrichment
 * instead of the lookup.
 *
 * Never throws. An empty result simply means no manufacturer promotion.
 */
export async function inspectCandidateProductPages(
  deps: PageInspectorDeps & { now?: () => Date },
  candidateUrls: string[],
  countryCode: string,
): Promise<{ pages: InspectedPage[]; attempts: PageInspectionAttempt[] }> {
  const now = deps.now ?? (() => new Date());
  const startedMs = now().getTime();
  const pages: InspectedPage[] = [];
  const attempts: PageInspectionAttempt[] = [];

  const seen = new Set<string>();
  const queue: string[] = [];
  for (const raw of candidateUrls) {
    const url = (raw ?? "").trim();
    if (!url || seen.has(url)) continue;
    seen.add(url);
    // Pre-filter on classification so the page budget is spent on pages that
    // could actually qualify, rather than on search results and resellers.
    if (!classifyUrl(url, countryCode).isInspectableProductPage) continue;
    queue.push(url);
  }

  // ATTEMPTS, not successes: a page that 404s or serves the wrong content type
  // still cost a request, and the cap exists to bound requests.
  let attemptsMade = 0;
  for (const url of queue) {
    if (attemptsMade >= MAX_PAGE_FETCH_ATTEMPTS) break;
    if (now().getTime() - startedMs > INSPECTION_BUDGET_MS) {
      attempts.push({
        url,
        outcome: "rejected_network_error",
        reason: "inspection budget exhausted before this page was attempted",
        linkCount: 0,
      });
      break;
    }
    attemptsMade++;
    const result = await inspectProductPage(deps, url, countryCode);
    if (result.outcome === "inspected") {
      pages.push(result);
      attempts.push({
        url,
        outcome: "inspected",
        reason: `read ${result.links.length} links; page identifies as "${result.pageProductName}"`,
        linkCount: result.links.length,
      });
    } else {
      attempts.push({
        url,
        outcome: result.outcome,
        reason: result.reason,
        linkCount: 0,
      });
    }
  }

  return { pages, attempts };
}
