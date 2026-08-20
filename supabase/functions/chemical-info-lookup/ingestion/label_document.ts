// Official label DOCUMENT discovery (Stage LD-1) — AU / APVMA eLabels.
//
// PURPOSE
//   The PubCRIS register extract points at the current label APPROVAL record
//   (labelreg → label_version) but not at the label DOCUMENT itself. The
//   APVMA publishes the approved label as a PDF on its eLabels host, and the
//   PubCRIS portal's own "View label" action redirects there. This module
//   discovers that document for an ALREADY-RESOLVED registration identity
//   and returns its URL plus retrieval provenance (timestamp, and SHA-256 +
//   byte size when the PDF bytes were actually fetched).
//
// DISCOVERY DISCIPLINE
//   * Runs ONLY for register-resolved identities: the pcode comes from
//     apvma.ts resolveDetails, which unresolved/ambiguous/unavailable
//     outcomes never reach. No document is ever looked up for an unverified
//     identity.
//   * The URL is CONFIRMED, never trusted blindly. Primary confirmation is
//     the PubCRIS portal's own view-label redirect for this exact pcode
//     (strictly validated: https, the official eLabels host, a .pdf path
//     naming this pcode). The deterministic eLabels URL pattern is only a
//     FALLBACK, and it counts only when the PDF bytes are actually fetched
//     and verified (%PDF magic) from the official host.
//   * Fail-soft, never fail-closed of identity: a timeout / 404 / bad
//     payload returns null — register identity, chemistry and Stage 4 label
//     evidence are never degraded by a document outage. One special case:
//     after the portal HAS confirmed the URL, a merely-transient document
//     host failure still returns the confirmed URL (document: null); the
//     hash provenance completes on a later pass.
//   * NO rate/WHP/REI parsing here — this module only DISCOVERS the
//     document and (Stage LD-2) hands its extracted text layer to
//     label_extract.ts. NO AI involvement.
//   * Text extraction failures are contained HERE: items become null and
//     the discovery result is byte-identical to a no-extraction pass.
//   * Transport cache only (same SourceCache discipline as the register
//     adapter): no database or storage infrastructure.
//
// WHAT THIS MODULE WILL NEVER DO
//   * Serve a constructed URL that nothing confirmed.
//   * Treat "document unavailable" as "product or label does not exist".
//   * Interpret label content (parsing lives in label_extract.ts).

import type {
  AdapterDeps,
  LabelDocumentDiscovery,
  PdfTextItem,
  WireDataSource,
} from "./contract.ts";
import { extractPdfTextItems } from "./label_extract.ts";
import { identityKey } from "./contract.ts";
import {
  NEGATIVE_TTL_MS,
  RESOLVED_TTL_MS,
  SourceCache,
  UNAVAILABLE_TTL_MS,
} from "./cache.ts";

/** The APVMA's official label-document host. Nothing else is ever accepted. */
export const ELABELS_HOST = "elabels.apvma.gov.au";

const PORTAL_BASE = "https://portal.apvma.gov.au/pubcris";

/** Per-attempt network timeout. */
const ATTEMPT_TIMEOUT_MS = 6000;
/** Overall discovery budget (measured on the injected clock). */
const DISCOVERY_BUDGET_MS = 15000;
/** Refuse to buffer/hash anything implausibly large for a label PDF. */
const MAX_PDF_BYTES = 25 * 1024 * 1024;

const CACHE_SOURCE = "apvma_labeldoc";

/**
 * The PubCRIS portal's view-label action for one product. Its response is a
 * tiny HTML stub whose only payload is a window.location.replace(...) to the
 * current approved label document.
 */
export function pubcrisViewLabelUrl(pcode: string): string {
  const url = new URL(PORTAL_BASE);
  url.searchParams.set("p_p_id", "pubcrisportlet_WAR_pubcrisportlet");
  url.searchParams.set("p_p_lifecycle", "1");
  url.searchParams.set("p_p_state", "normal");
  url.searchParams.set("p_p_mode", "view");
  url.searchParams.set("_pubcrisportlet_WAR_pubcrisportlet_id", pcode);
  url.searchParams.set(
    "_pubcrisportlet_WAR_pubcrisportlet_javax.portlet.action",
    "viewLabel",
  );
  return url.toString();
}

/** The deterministic eLabels document URL (FALLBACK — must verify by fetch). */
export function elabelsUrlFor(pcode: string): string {
  return `https://${ELABELS_HOST}/${pcode}ELBL.pdf`;
}

const REDIRECT_PATTERN = /window\.location\.replace\('([^']+)'\)/;

/**
 * Extract and STRICTLY validate the label-document redirect from the portal
 * stub. Anything short of an https URL on the official eLabels host, with a
 * .pdf path that names this exact pcode, is rejected (fail soft — the
 * fallback path still requires verified PDF bytes).
 */
export function extractConfirmedLabelUrl(
  html: string,
  pcode: string,
): string | null {
  const match = REDIRECT_PATTERN.exec(html);
  if (!match) return null;
  let url: URL;
  try {
    url = new URL(match[1]);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  if (url.hostname.toLowerCase() !== ELABELS_HOST) return null;
  const path = url.pathname;
  if (!path.toLowerCase().endsWith(".pdf")) return null;
  // The redirect was requested FOR this pcode; a document named for a
  // different product would be an uncertain association — rejected.
  if (!path.includes(pcode)) return null;
  return url.toString();
}

// ---------------------------------------------------------------------------
// Bounded fetch helpers (injected fetch; every failure contained)
// ---------------------------------------------------------------------------

type TextFetch =
  | { ok: true; text: string }
  | { ok: false };

async function fetchStubText(deps: AdapterDeps, url: string): Promise<TextFetch> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ATTEMPT_TIMEOUT_MS);
  try {
    const res = await deps.fetchFn(url, {
      headers: {
        "Accept": "text/html",
        "User-Agent":
          "Mozilla/5.0 (compatible; VineTrack-ChemicalLookup/1.0; +https://rork.app)",
      },
      redirect: "follow",
      signal: ctrl.signal,
    });
    if (!res.ok) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return { ok: false };
    }
    const text = await res.text();
    return { ok: true, text };
  } catch {
    return { ok: false };
  } finally {
    clearTimeout(timer);
  }
}

type PdfFetch =
  | { ok: true; sha256: string; byte_size: number; bytes: Uint8Array }
  | { ok: false; category: "not_found" | "transient" };

async function sha256Hex(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function looksLikePdf(bytes: Uint8Array): boolean {
  // "%PDF-"
  return bytes.length >= 5 &&
    bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 &&
    bytes[3] === 0x46 && bytes[4] === 0x2d;
}

async function fetchPdfOnce(deps: AdapterDeps, url: string): Promise<PdfFetch> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ATTEMPT_TIMEOUT_MS);
  try {
    const res = await deps.fetchFn(url, {
      headers: {
        "Accept": "application/pdf,*/*",
        "User-Agent":
          "Mozilla/5.0 (compatible; VineTrack-ChemicalLookup/1.0; +https://rork.app)",
      },
      redirect: "follow",
      signal: ctrl.signal,
    });
    if (res.status === 404 || res.status === 410) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return { ok: false, category: "not_found" };
    }
    if (!res.ok) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return { ok: false, category: "transient" };
    }
    const declared = Number.parseInt(res.headers.get("content-length") ?? "", 10);
    if (Number.isFinite(declared) && declared > MAX_PDF_BYTES) {
      try {
        await res.body?.cancel();
      } catch { /* ignore */ }
      return { ok: false, category: "transient" };
    }
    const buffer = await res.arrayBuffer();
    if (buffer.byteLength > MAX_PDF_BYTES) return { ok: false, category: "transient" };
    const bytes = new Uint8Array(buffer);
    if (!looksLikePdf(bytes)) {
      // A 200 that is not a PDF (maintenance page, error HTML) proves
      // nothing about the document — treated as a host problem.
      return { ok: false, category: "transient" };
    }
    return {
      ok: true,
      sha256: await sha256Hex(buffer),
      byte_size: buffer.byteLength,
      bytes,
    };
  } catch {
    return { ok: false, category: "transient" };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Fetch the PDF with ONE retry on transient failure (the eLabels host drops
 * connections intermittently — measured during the LD audit). 404/410 is
 * definitive and never retried.
 */
async function fetchPdfWithRetry(
  deps: AdapterDeps,
  url: string,
  startedMs: number,
): Promise<PdfFetch> {
  const first = await fetchPdfOnce(deps, url);
  if (first.ok || first.category === "not_found") return first;
  if (deps.now().getTime() - startedMs > DISCOVERY_BUDGET_MS) return first;
  return await fetchPdfOnce(deps, url);
}

// ---------------------------------------------------------------------------
// Discovery (cache-fronted, fail-soft)
// ---------------------------------------------------------------------------

interface CachedDiscovery {
  doc: LabelDocumentDiscovery | null;
  items: PdfTextItem[] | null;
}

const cache = new SourceCache();

/** Test hook: clears the module cache between deno test cases. */
export function clearLabelDocumentCache(): void {
  cache.clear();
}

/** Discovery plus the document's extracted text layer (Stage LD-2 input). */
export interface LabelDocumentWithText {
  doc: LabelDocumentDiscovery | null;
  /**
   * Positioned text items from the fetched PDF, or null when no bytes were
   * fetched this pass OR extraction failed — a null here is ALWAYS
   * fail-soft: the discovery result is byte-identical either way.
   */
  items: PdfTextItem[] | null;
}

/** Contained text extraction: any failure returns null, never propagates. */
async function extractItems(
  deps: AdapterDeps,
  bytes: Uint8Array,
): Promise<PdfTextItem[] | null> {
  try {
    const extractor = deps.extractPdfText ?? extractPdfTextItems;
    return await extractor(bytes);
  } catch (err) {
    console.error(
      "label document text extraction failed:",
      err instanceof Error ? err.message : String(err),
    );
    return null;
  }
}

/**
 * Discover the official label document for a register-RESOLVED pcode and,
 * when its bytes were fetched, extract the text layer for Stage LD-2.
 *
 * Returns:
 *   * full discovery (URL + sha256/byte size) when the document was fetched
 *     — plus text items unless extraction failed (contained, fail-soft);
 *   * URL-only discovery when the portal confirmed the URL but the document
 *     host failed transiently (provenance completes on a later pass);
 *   * null when nothing could be confirmed — the caller keeps
 *     `label_reference` honestly unresolved and NOTHING else changes.
 */
export async function discoverLabelDocumentWithText(
  deps: AdapterDeps,
  pcode: string,
): Promise<LabelDocumentWithText> {
  const trimmed = pcode.trim();
  if (!trimmed) return { doc: null, items: null };

  const nowMs = deps.now().getTime();
  const key = `label_document:${trimmed}`;
  const cached = cache.get<CachedDiscovery>("AU", CACHE_SOURCE, key, nowMs);
  if (cached) return { doc: cached.value.doc, items: cached.value.items };

  const retrievedAt = deps.now().toISOString();
  const startedMs = nowMs;
  const finish = (
    doc: LabelDocumentDiscovery | null,
    items: PdfTextItem[] | null,
    ttlMs: number,
  ): LabelDocumentWithText => {
    cache.set(
      "AU",
      CACHE_SOURCE,
      key,
      { doc, items } satisfies CachedDiscovery,
      ttlMs,
      nowMs,
      retrievedAt,
      identityKey("AU", "apvma", trimmed),
    );
    return { doc, items };
  };

  // 1) Preferred: the register portal's own view-label redirect.
  const stub = await fetchStubText(deps, pubcrisViewLabelUrl(trimmed));
  const confirmedUrl = stub.ok ? extractConfirmedLabelUrl(stub.text, trimmed) : null;

  if (confirmedUrl) {
    const pdf = await fetchPdfWithRetry(deps, confirmedUrl, startedMs);
    if (pdf.ok) {
      return finish(
        {
          url: confirmedUrl,
          confirmation: "pubcris_view_label",
          retrieved_at: retrievedAt,
          document: { sha256: pdf.sha256, byte_size: pdf.byte_size },
        },
        await extractItems(deps, pdf.bytes),
        RESOLVED_TTL_MS,
      );
    }
    if (pdf.category === "not_found") {
      // The portal named a document that is not there: nothing to reference.
      return finish(null, null, NEGATIVE_TTL_MS);
    }
    // Transient document-host failure AFTER portal confirmation: the URL is
    // authoritative on its own; the hash provenance completes later.
    return finish({
      url: confirmedUrl,
      confirmation: "pubcris_view_label",
      retrieved_at: retrievedAt,
      document: null,
    }, null, UNAVAILABLE_TTL_MS);
  }

  // 2) Fallback: the deterministic eLabels pattern — counts ONLY when the
  //    PDF bytes are actually fetched and verified from the official host.
  if (deps.now().getTime() - startedMs > DISCOVERY_BUDGET_MS) {
    return finish(null, null, UNAVAILABLE_TTL_MS);
  }
  const fallbackUrl = elabelsUrlFor(trimmed);
  const pdf = await fetchPdfWithRetry(deps, fallbackUrl, startedMs);
  if (pdf.ok) {
    return finish(
      {
        url: fallbackUrl,
        confirmation: "document_fetch",
        retrieved_at: retrievedAt,
        document: { sha256: pdf.sha256, byte_size: pdf.byte_size },
      },
      await extractItems(deps, pdf.bytes),
      RESOLVED_TTL_MS,
    );
  }
  // A definitive 404 after a DEFINITIVE portal answer with no label link
  // means this product has no eLabel today (negative-cacheable); anything
  // else is treated as transient so the next lookup retries soon.
  const definitiveAbsence = stub.ok && pdf.category === "not_found";
  return finish(null, null, definitiveAbsence ? NEGATIVE_TTL_MS : UNAVAILABLE_TTL_MS);
}

/**
 * Stage LD-1 view of discovery (document only). Same cache, same behaviour
 * — kept so every LD-1 call site and regression stays byte-identical.
 */
export async function discoverLabelDocument(
  deps: AdapterDeps,
  pcode: string,
): Promise<LabelDocumentDiscovery | null> {
  return (await discoverLabelDocumentWithText(deps, pcode)).doc;
}

/**
 * The manufacturer_label evidence entry for a discovered label document.
 * The APVMA-approved label IS the registrant's approved label (JSON contract
 * §5.3) — same source kind as the Stage 4 label evidence.
 */
export function labelDocumentSource(
  pcode: string,
  doc: LabelDocumentDiscovery,
): WireDataSource {
  const detail = doc.document
    ? `PDF sha256 ${doc.document.sha256}, ${doc.document.byte_size} bytes`
    : "URL confirmed via PubCRIS; PDF not retrieved this pass";
  return {
    kind: "manufacturer_label",
    name: `APVMA-approved label document (eLabels) — product ${pcode} (${detail})`,
    reference: doc.url,
    retrieved_at: doc.retrieved_at,
  };
}
