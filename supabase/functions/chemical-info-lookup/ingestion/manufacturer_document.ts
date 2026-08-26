// Bounded fetch of a manufacturer-hosted label document.
//
// # Why this is not `discoverLabelDocumentWithText`
//
// That function is keyed on an APVMA pcode and only ever talks to PubCRIS and
// eLabels. It is the REGULATOR's document fetcher, and correctly so. Until now
// it was also the ONLY code path in the project that turned a label URL into
// label bytes — which is why a manufacturer label could be discovered,
// classified, promoted and returned as a link, and still never be read. The
// URL reached the operator; the rate table inside it did not.
//
// # Trust is inherited, never established here
//
// This module fetches a URL that the authority layer has ALREADY accepted as
// `manufacturer_label`, which means the page it came from was fetched, stated
// the register-resolved product name, and linked this PDF on its own host as a
// label. Nothing here re-opens that decision and nothing here can widen it:
// the caller passes the accepted URL and the page it was accepted from, and
// this module refuses anything that does not still match.
//
// # Fail closed
//
// Every failure is NAMED and returns no bytes. A registrant website that is
// down, slow, serving HTML from a .pdf path, or redirecting to a CDN on
// another domain degrades manufacturer enrichment and nothing else. Register
// identity, chemistry, category and the regulator label are untouched, because
// this module cannot write to any of them — it returns bytes or it returns a
// reason.

import type { AdapterDeps, PdfTextItem } from "./contract.ts";
import { hostOf } from "../research/classify.ts";

/** Per-attempt network timeout. Matches the page inspector's budget. */
export const MANUFACTURER_FETCH_TIMEOUT_MS = 6000;

/**
 * Hard byte ceiling for a manufacturer label.
 *
 * Lower than the regulator fetcher's 25 MiB: eLabels serves scanned
 * multi-hundred-page documents, whereas a registrant's own label is a panel
 * artwork PDF. The measured acceptance document is 1.7 MiB. 12 MiB leaves
 * generous headroom while keeping a hostile or misconfigured host from making
 * an edge function buffer an unbounded response.
 */
export const MAX_MANUFACTURER_PDF_BYTES = 12 * 1024 * 1024;

export type ManufacturerFetchOutcome =
  | "fetched"
  | "rejected_not_https"
  | "rejected_untrusted_host"
  | "rejected_off_host_redirect"
  | "rejected_http_error"
  | "rejected_not_found"
  | "rejected_not_pdf"
  | "rejected_too_large"
  | "rejected_network_error";

export interface ManufacturerDocumentResult {
  outcome: ManufacturerFetchOutcome;
  url: string;
  reason: string;
  /** Present only for `fetched`. */
  bytes?: Uint8Array;
  sha256?: string;
  byteSize?: number;
}

/** Registrable-domain comparison, so `www.` and sub-hosts still match. */
function sameRegistrableHost(a: string, b: string): boolean {
  const ha = hostOf(a);
  const hb = hostOf(b);
  if (!ha || !hb) return false;
  if (ha === hb) return true;
  return ha.endsWith(`.${hb}`) || hb.endsWith(`.${ha}`);
}

/** `%PDF-` magic. A content-type header is a claim; this is the document. */
function looksLikePdf(bytes: Uint8Array): boolean {
  return bytes.length >= 5 &&
    bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 &&
    bytes[3] === 0x46 && bytes[4] === 0x2d;
}

async function sha256Hex(buffer: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Fetch an accepted manufacturer label document.
 *
 * `sourcePageUrl` is the product page the label was accepted FROM. The
 * document must remain on that page's registrable domain both before the
 * request (the URL as accepted) and after it (wherever redirects landed) —
 * a label that redirects to a third-party CDN has left the registrant's chain
 * of custody, and a document nobody can attribute is not evidence.
 */
export async function fetchManufacturerDocument(
  deps: AdapterDeps,
  labelUrl: string,
  sourcePageUrl: string,
): Promise<ManufacturerDocumentResult> {
  const trimmed = (labelUrl ?? "").trim();
  const fail = (
    outcome: ManufacturerFetchOutcome,
    reason: string,
  ): ManufacturerDocumentResult => ({ outcome, url: trimmed, reason });

  let requested: URL;
  try {
    requested = new URL(trimmed);
  } catch {
    return fail("rejected_not_https", "URL could not be parsed");
  }
  // Plain HTTP is refused outright: a label fetched over a channel anybody can
  // rewrite is not evidence, and silently upgrading the scheme would be
  // guessing at a host's configuration.
  if (requested.protocol !== "https:") {
    return fail(
      "rejected_not_https",
      `refused ${requested.protocol}// — a label document must be fetched over HTTPS`,
    );
  }

  if (!sameRegistrableHost(requested.toString(), sourcePageUrl)) {
    return fail(
      "rejected_untrusted_host",
      `the document host ${hostOf(requested.toString()) || "(unparseable)"} is not the ` +
        `product page's host ${hostOf(sourcePageUrl) || "(unparseable)"} — a third-party ` +
        `document linked from a manufacturer page is still a third party`,
    );
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), MANUFACTURER_FETCH_TIMEOUT_MS);
  try {
    const res = await deps.fetchFn(requested.toString(), {
      headers: {
        "Accept": "application/pdf,*/*",
        "User-Agent":
          "Mozilla/5.0 (compatible; VineTrack-ChemicalLookup/1.0; +https://rork.app)",
      },
      redirect: "follow",
      signal: ctrl.signal,
    });

    const finalUrl = (res.url && /^https?:\/\//i.test(res.url))
      ? res.url
      : requested.toString();

    const discard = async () => {
      try {
        await res.body?.cancel();
      } catch { /* already released */ }
    };

    // A redirect that leaves the registrant's domain ends the chain of custody.
    if (!sameRegistrableHost(finalUrl, requested.toString())) {
      await discard();
      return fail(
        "rejected_off_host_redirect",
        `redirected off the registrant domain to ${hostOf(finalUrl) || "an unparseable host"}`,
      );
    }
    // ...and an HTTPS document must not be downgraded by its own redirect.
    if (!/^https:/i.test(finalUrl)) {
      await discard();
      return fail("rejected_not_https", "redirected to a non-HTTPS URL");
    }

    if (res.status === 404 || res.status === 410) {
      await discard();
      return fail(
        "rejected_not_found",
        `HTTP ${res.status} — the registrant does not serve this document`,
      );
    }
    if (!res.ok) {
      await discard();
      return fail("rejected_http_error", `HTTP ${res.status}`);
    }

    // A DECLARED oversize is refused without reading a byte. An absent or
    // dishonest Content-Length is caught by the post-read check below.
    const declared = Number.parseInt(res.headers.get("content-length") ?? "", 10);
    if (Number.isFinite(declared) && declared > MAX_MANUFACTURER_PDF_BYTES) {
      await discard();
      return fail(
        "rejected_too_large",
        `declared ${declared} bytes, over the ${MAX_MANUFACTURER_PDF_BYTES}-byte budget`,
      );
    }

    const buffer = await res.arrayBuffer();
    if (buffer.byteLength > MAX_MANUFACTURER_PDF_BYTES) {
      return fail(
        "rejected_too_large",
        `read ${buffer.byteLength} bytes, over the ${MAX_MANUFACTURER_PDF_BYTES}-byte budget`,
      );
    }

    const bytes = new Uint8Array(buffer);
    // The BYTES decide, not the content-type header. Registrant sites
    // routinely serve PDFs as application/octet-stream, and just as routinely
    // serve an HTML "page not found" with a 200 from a .pdf path.
    if (!looksLikePdf(bytes)) {
      return fail(
        "rejected_not_pdf",
        "the response did not begin with the PDF signature — a 200 that is not " +
          "a document proves nothing about the label",
      );
    }

    return {
      outcome: "fetched",
      url: finalUrl,
      reason: `fetched ${buffer.byteLength} bytes from the registrant's own host`,
      bytes,
      sha256: await sha256Hex(buffer),
      byteSize: buffer.byteLength,
    };
  } catch (err) {
    // Timeout, DNS failure, TLS failure, aborted body — one answer: no bytes,
    // so no practical data. The lookup continues on regulator evidence.
    return fail(
      "rejected_network_error",
      err instanceof Error ? err.message : String(err),
    );
  } finally {
    clearTimeout(timer);
  }
}

/** Contained text extraction: any failure returns null, never propagates. */
export async function extractManufacturerDocumentText(
  deps: AdapterDeps,
  bytes: Uint8Array,
): Promise<PdfTextItem[] | null> {
  try {
    const extractor = deps.extractPdfText ??
      (await import("./label_extract.ts")).extractPdfTextItems;
    return await extractor(bytes);
  } catch (err) {
    console.error(
      "manufacturer label text extraction failed:",
      err instanceof Error ? err.message : String(err),
    );
    return null;
  }
}
