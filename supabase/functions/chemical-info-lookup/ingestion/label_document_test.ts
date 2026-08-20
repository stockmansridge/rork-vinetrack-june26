// Stage LD-1 tests — official label DOCUMENT discovery + provenance.
//
// Scope pinned by these tests (docs/chemical-label-document-extraction-design.md):
//   LD-A  Sprayseal 80160: portal-confirmed eLabels URL + fetched-PDF
//         provenance (sha256/bytes) → label_reference resolves as
//         manufacturer_label; Stage 4 claims/WHP untouched; candidate
//         payload carries the reference.
//   LD-B  Custodia Forte 91636: transient PDF-host failure AFTER portal
//         confirmation → label_reference still resolves (URL-only
//         provenance); the chemical lookup is otherwise byte-identical.
//   LD-C  Definitive 404 → NO reference served; register result undamaged.
//   LD-D  Portal down → deterministic eLabels URL counts ONLY with verified
//         PDF bytes (confirmation: document_fetch).
//   LD-E  Everything down → fail soft; register data fully intact.
//   LD-F  Foreign-host redirect is rejected and never fetched.
//   LD-G  unresolved/ambiguous identities NEVER attempt document discovery.
//   LD-H  Discovery is cache-fronted (no repeat fetches inside TTL).
//   LD-I  A 200 that is not a PDF proves nothing (URL-only provenance).
//
// No rate/WHP/REI parsing is exercised here — that is LD-2, not built yet.

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  discoverLabelDocument,
  ELABELS_HOST,
  elabelsUrlFor,
  extractConfirmedLabelUrl,
  labelDocumentSource,
  pubcrisViewLabelUrl,
} from "./label_document.ts";
import { APVMA_RESOURCES, clearApvmaCache } from "./apvma.ts";
import {
  buildCandidatePayload,
  buildRegisterOnlyStructured,
  discoverAuthoritative,
} from "./ingest.ts";
import type { AdapterDeps } from "./contract.ts";

// ---------------------------------------------------------------------------
// Fixtures — live PubCRIS values (Sprayseal 80160, Custodia Forte 91636)
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

interface RegisterData {
  products: Row[];
  prodcon: Record<string, Row[]>;
  constit: Record<string, string>;
  labelreg: Record<string, Row[]>;
  produse: Record<string, Row[]>;
  hosts: Record<string, string>;
  pests: Record<string, string>;
  prodcom: Record<string, Row[]>;
}

const SPRAYSEAL_ROW: Row = {
  pcode: "80160",
  fpname: "Sprayseal Pruning Wound Treatment",
  sname: "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2030 0:00",
};

const CUSTODIA_FORTE_ROW: Row = {
  pcode: "91636",
  fpname: "CUSTODIA FORTE FUNGICIDE",
  sname: "ADAMA AUSTRALIA PTY LIMITED",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2029 0:00",
};

function sprayRegister(): RegisterData {
  return {
    products: [SPRAYSEAL_ROW],
    prodcon: {
      "80160": [
        { pcode: "80160", ccode: "TZTB", ctype: "A", camount: "430.000000", cucode: "g/L" },
      ],
    },
    constit: { TZTB: "TEBUCONAZOLE" },
    labelreg: {
      "80160": [{ pcode: "80160", regno: "113355", regdate: "1/07/2025 0:00" }],
    },
    produse: {
      "80160": [
        { pcode: "80160", hostcode: "FRVG", pestcode: "YDIEB" },
      ],
    },
    hosts: { FRVG: "GRAPEVINE" },
    pests: { YDIEB: "EUTYPA DIEBACK" },
    prodcom: {
      "80160": [{
        pcode: "80160",
        seq: 1,
        applic:
          "WITHHOLDING PERIODS\nHarvest\nGRAPEVINES: DO NOT HARVEST FOR 4 WEEKS AFTER APPLICATION.",
      }],
    },
  };
}

function forteRegister(): RegisterData {
  return {
    products: [CUSTODIA_FORTE_ROW],
    prodcon: {
      "91636": [
        { pcode: "91636", ccode: "PMAZ", ctype: "A", camount: "222.000000", cucode: "g/L" },
        { pcode: "91636", ccode: "TZTB", ctype: "A", camount: "370.000000", cucode: "g/L" },
      ],
    },
    constit: { PMAZ: "AZOXYSTROBIN", TZTB: "TEBUCONAZOLE" },
    labelreg: {
      "91636": [{ pcode: "91636", regno: "132920", regdate: "2/03/2022 9:50:13 AM" }],
    },
    produse: {
      "91636": [{ pcode: "91636", hostcode: "FRVG", pestcode: "YMIP" }],
    },
    hosts: { FRVG: "GRAPEVINE" },
    pests: { YMIP: "POWDERY MILDEW" },
    prodcom: {},
  };
}

// ---------------------------------------------------------------------------
// Multi-host fetch harness (register CKAN + portal stub + eLabels PDF)
// ---------------------------------------------------------------------------

// Copied into a fresh ArrayBuffer-backed view: TextEncoder returns a
// Uint8Array<ArrayBufferLike>, which strict BufferSource typing rejects.
const PDF_BYTES = new Uint8Array(new TextEncoder().encode(
  "%PDF-1.6\n1 0 obj\n<< /Producer (VineTrack LD-1 fixture) >>\nendobj\ntrailer\n%%EOF\n",
));

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** The live portal stub shape: a page whose payload is one JS redirect. */
function stubHtml(redirectUrl: string): string {
  return `<html><body><button class="colour float-right" onclick="javascript:window.location.replace('${redirectUrl}');">View label</button></body></html>`;
}

function pdfResponse(): Response {
  return new Response(PDF_BYTES, {
    status: 200,
    headers: { "Content-Type": "application/pdf" },
  });
}

type HostHandler = (url: URL) => Response | "reject";

interface Hosts {
  register: RegisterData;
  portal?: HostHandler;
  elabels?: HostHandler;
}

function wordsMatch(q: string, fpname: string): boolean {
  const words = new Set(fpname.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean));
  return q.toLowerCase().split(/\s+/).filter(Boolean).every((t) => words.has(t));
}

function ckanRespond(data: RegisterData, url: URL): Response {
  const respond = (records: Row[]): Response =>
    new Response(JSON.stringify({ success: true, result: { records } }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  const resource = url.searchParams.get("resource_id") ?? "";
  const q = url.searchParams.get("q");
  const filtersRaw = url.searchParams.get("filters");
  // deno-lint-ignore no-explicit-any
  const filters: any = filtersRaw ? JSON.parse(filtersRaw) : null;

  let records: Row[] = [];
  if (resource === APVMA_RESOURCES.product) {
    records = data.products;
    if (filters?.pcode) records = records.filter((r) => r.pcode === filters.pcode);
    if (q) records = records.filter((r) => wordsMatch(q, String(r.fpname)));
  } else if (resource === APVMA_RESOURCES.productConstituents) {
    records = data.prodcon[filters?.pcode] ?? [];
  } else if (resource === APVMA_RESOURCES.constituentNames) {
    const codes: string[] = Array.isArray(filters?.ccode) ? filters.ccode : [];
    records = codes.map((c) => ({ ccode: c, cname: data.constit[c] })).filter((r) => r.cname);
  } else if (resource === APVMA_RESOURCES.labelRegistrations) {
    records = data.labelreg[filters?.pcode] ?? [];
  } else if (resource === APVMA_RESOURCES.productUses) {
    records = data.produse[filters?.pcode] ?? [];
  } else if (resource === APVMA_RESOURCES.hosts) {
    const codes: string[] = Array.isArray(filters?.hostcode) ? filters.hostcode : [];
    records = codes.map((c) => ({ hostcode: c, hostdesc: data.hosts[c] })).filter((r) => r.hostdesc);
  } else if (resource === APVMA_RESOURCES.pests) {
    const codes: string[] = Array.isArray(filters?.pestcode) ? filters.pestcode : [];
    records = codes.map((c) => ({ pestcode: c, pestdesc: data.pests[c] })).filter((r) => r.pestdesc);
  } else if (resource === APVMA_RESOURCES.productComments) {
    records = data.prodcom[filters?.pcode] ?? [];
  }
  return respond(records);
}

function makeFetch(hosts: Hosts, log: string[]): typeof fetch {
  return ((input: Request | URL | string): Promise<Response> => {
    const url = new URL(String(input));
    log.push(url.toString());
    if (url.hostname === "data.gov.au") {
      return Promise.resolve(ckanRespond(hosts.register, url));
    }
    if (url.hostname === "portal.apvma.gov.au") {
      const out = hosts.portal?.(url) ?? "reject";
      return out === "reject"
        ? Promise.reject(new Error("connection dropped"))
        : Promise.resolve(out);
    }
    if (url.hostname === ELABELS_HOST) {
      const out = hosts.elabels?.(url) ?? "reject";
      return out === "reject"
        ? Promise.reject(new Error("connection dropped"))
        : Promise.resolve(out);
    }
    return Promise.reject(new Error(`forbidden host: ${url.hostname}`));
  }) as typeof fetch;
}

function makeDeps(hosts: Hosts, log: string[]): AdapterDeps {
  return {
    fetchFn: makeFetch(hosts, log),
    now: () => new Date("2026-08-20T00:00:00Z"),
  };
}

function countHost(log: string[], host: string): number {
  return log.filter((u) => u.includes(host)).length;
}

// ===========================================================================
// URL construction + redirect validation (deterministic units)
// ===========================================================================

Deno.test("LD: portal view-label URL is built for the exact pcode; redirect extraction is strictly validated", () => {
  const stubUrl = pubcrisViewLabelUrl("80160");
  assert(stubUrl.startsWith("https://portal.apvma.gov.au/pubcris?"));
  assert(stubUrl.includes("_pubcrisportlet_WAR_pubcrisportlet_id=80160"));
  assert(stubUrl.includes("viewLabel"));

  const good = "https://elabels.apvma.gov.au/80160ELBL.pdf";
  assertEquals(extractConfirmedLabelUrl(stubHtml(good), "80160"), good);
  assertEquals(elabelsUrlFor("80160"), good);

  // Everything short of https + official host + .pdf + this pcode fails.
  assertEquals(extractConfirmedLabelUrl("<html>no redirect</html>", "80160"), null);
  assertEquals(
    extractConfirmedLabelUrl(stubHtml("http://elabels.apvma.gov.au/80160ELBL.pdf"), "80160"),
    null,
    "plain http is rejected",
  );
  assertEquals(
    extractConfirmedLabelUrl(stubHtml("https://evil.example.com/80160ELBL.pdf"), "80160"),
    null,
    "foreign hosts are rejected",
  );
  assertEquals(
    extractConfirmedLabelUrl(stubHtml("https://elabels.apvma.gov.au/80160ELBL.txt"), "80160"),
    null,
    "non-PDF paths are rejected",
  );
  assertEquals(
    extractConfirmedLabelUrl(stubHtml("https://elabels.apvma.gov.au/91636ELBL.pdf"), "80160"),
    null,
    "a document named for a DIFFERENT product is an uncertain association — rejected",
  );
});

// ===========================================================================
// LD-A — Sprayseal 80160: full document discovery (the audit regression)
// ===========================================================================

Deno.test("LD-A: Sprayseal 80160 — portal-confirmed eLabels URL + PDF sha256 resolve label_reference as manufacturer_label; Stage 4 evidence untouched", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const expectedUrl = "https://elabels.apvma.gov.au/80160ELBL.pdf";
  const deps = makeDeps({
    register: sprayRegister(),
    portal: () => new Response(stubHtml(expectedUrl), { status: 200 }),
    elabels: () => pdfResponse(),
  }, log);

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps);
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration!;

  const expectedSha = await sha256Hex(PDF_BYTES);
  assertEquals(reg.label_document?.url, expectedUrl);
  assertEquals(reg.label_document?.confirmation, "pubcris_view_label");
  assertEquals(reg.label_document?.document?.sha256, expectedSha);
  assertEquals(reg.label_document?.document?.byte_size, PDF_BYTES.byteLength);
  assert(
    !reg.unresolved_fields.includes("label_reference"),
    "authoritative discovery clears the label_reference gap",
  );
  const docSource = reg.sources.find(
    (s) => s.kind === "manufacturer_label" && s.name.includes("label document"),
  );
  assert(docSource, "document provenance entry recorded");
  assertEquals(docSource!.reference, expectedUrl);
  assert(docSource!.name.includes(expectedSha), "sha256 recorded for reproducibility");
  assert(docSource!.retrieved_at, "retrieval timestamp recorded");

  // Serving path: the reference is populated with manufacturer_label
  // provenance and the unresolved list stays coherent (R12 invariant).
  const merged = buildRegisterOnlyStructured(reg, 1);
  assertEquals(merged.registration.label_reference, expectedUrl);
  assertEquals(merged.field_provenance.label_reference, "manufacturer_label");
  assert(!merged.verification.unresolved_fields.includes("label_reference"));

  // LD-1 changes NOTHING about label facts: claims/WHP still come from
  // Stage 4 evidence, rates stay per-context unresolved (LD-2 is not built).
  const use = merged.registered_uses.find(
    // deno-lint-ignore no-explicit-any
    (u: any) => u.crop === "GRAPEVINE" && u.target_raw === "EUTYPA DIEBACK",
  );
  assert(use, "label claim served");
  assertEquals(use.withholding_period_days, 28);
  assert(merged.verification.unresolved_fields.includes("rates:GRAPEVINE"));

  // The candidate row carries the authoritative reference.
  const payload = buildCandidatePayload(merged, "Spray Seal", reg, "2026-08-20T00:00:00Z", 1);
  assert(payload);
  assertEquals(payload!.label_reference, expectedUrl);
});

// ===========================================================================
// LD-B — Custodia Forte 91636: transient PDF host must not break the lookup
// ===========================================================================

Deno.test("LD-B: Custodia Forte 91636 — portal confirms the URL, eLabels drops the connection → label_reference still resolves; register data untouched", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const expectedUrl = "https://elabels.apvma.gov.au/91636ELBL.pdf";
  const deps = makeDeps({
    register: forteRegister(),
    portal: () => new Response(stubHtml(expectedUrl), { status: 200 }),
    elabels: () => "reject", // the flakiness measured during the LD audit
  }, log);

  const discovery = await discoverAuthoritative("AU", "CUSTODIA FORTE FUNGICIDE", null, deps);
  assertEquals(discovery.outcome, "resolved", "PDF-host failure never breaks the lookup");
  const reg = discovery.registration!;
  assertEquals(reg.registration_identity_key, "AU:apvma:91636");

  assertEquals(reg.label_document?.url, expectedUrl);
  assertEquals(reg.label_document?.confirmation, "pubcris_view_label");
  assertEquals(reg.label_document?.document, null, "no PDF bytes → no invented hash");
  assert(!reg.unresolved_fields.includes("label_reference"));
  const docSource = reg.sources.find(
    (s) => s.kind === "manufacturer_label" && s.name.includes("label document"),
  );
  assert(docSource!.name.includes("PDF not retrieved"), "provenance states the document was not fetched");

  // Register-backed facts are fully intact.
  assertEquals(reg.active_ingredients.length, 2);
  assertEquals(reg.registered_product_name, "CUSTODIA FORTE FUNGICIDE");

  const merged = buildRegisterOnlyStructured(reg, 1);
  assertEquals(merged.registration.label_reference, expectedUrl);
  assertEquals(merged.field_provenance.label_reference, "manufacturer_label");
  assert(!merged.verification.unresolved_fields.includes("label_reference"));

  // Transient failure is retried exactly once, then fails soft.
  assertEquals(countHost(log, ELABELS_HOST), 2, "one attempt + one retry");
});

// ===========================================================================
// LD-C — definitive 404: no reference served, nothing else damaged
// ===========================================================================

Deno.test("LD-C: portal-confirmed URL that 404s serves NO label_reference — and the register result is untouched", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const deps = makeDeps({
    register: sprayRegister(),
    portal: () =>
      new Response(stubHtml("https://elabels.apvma.gov.au/80160ELBL.pdf"), { status: 200 }),
    elabels: () => new Response("not here", { status: 404 }),
  }, log);

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps);
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration!;
  assertEquals(reg.label_document, null, "a document that is not there is never referenced");
  assert(reg.unresolved_fields.includes("label_reference"), "gap stays honestly listed");
  assert(
    !reg.sources.some((s) => s.name.includes("label document")),
    "no document provenance without a document",
  );
  assertEquals(countHost(log, ELABELS_HOST), 1, "404 is definitive — never retried");

  // Register identity, chemistry and Stage 4 evidence stand exactly as before.
  assertEquals(reg.registration_identity_key, "AU:apvma:80160");
  assertEquals(reg.active_ingredients.length, 1);
  const merged = buildRegisterOnlyStructured(reg, 1);
  assertEquals(merged.registration.label_reference, null);
  assertEquals(merged.field_provenance.label_reference, "unresolved");
  assert(merged.verification.unresolved_fields.includes("label_reference"));
  assertEquals(
    // deno-lint-ignore no-explicit-any
    merged.registered_uses.find((u: any) => u.crop === "GRAPEVINE")?.withholding_period_days,
    28,
    "label evidence unaffected by the document 404",
  );
});

// ===========================================================================
// LD-D — portal down: the deterministic URL counts only with verified bytes
// ===========================================================================

Deno.test("LD-D: portal stub unavailable — the constructed eLabels URL is served ONLY after its PDF bytes are fetched and verified", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const deps = makeDeps({
    register: sprayRegister(),
    portal: () => "reject",
    elabels: () => pdfResponse(),
  }, log);

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps);
  const reg = discovery.registration!;
  assertEquals(reg.label_document?.url, "https://elabels.apvma.gov.au/80160ELBL.pdf");
  assertEquals(
    reg.label_document?.confirmation,
    "document_fetch",
    "fallback confirmation is the verified fetch itself",
  );
  assertEquals(reg.label_document?.document?.sha256, await sha256Hex(PDF_BYTES));
  assert(!reg.unresolved_fields.includes("label_reference"));
});

// ===========================================================================
// LD-E — total document outage: fail soft, register result byte-identical
// ===========================================================================

Deno.test("LD-E: portal AND eLabels down — discovery returns nothing; identity, chemistry, claims and WHP stand", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const deps = makeDeps({ register: sprayRegister() }, log); // both hosts reject

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps);
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration!;
  assertEquals(reg.label_document, null);
  assert(reg.unresolved_fields.includes("label_reference"));
  assertEquals(reg.registered_product_name, "Sprayseal Pruning Wound Treatment");
  assertEquals(reg.active_ingredients[0]?.concentration, 430);
  assertEquals(reg.label_version, "APVMA label approval 113355 (1/07/2025 0:00)");

  const merged = buildRegisterOnlyStructured(reg, 1);
  assertEquals(
    // deno-lint-ignore no-explicit-any
    merged.registered_uses.find((u: any) => u.crop === "GRAPEVINE")?.withholding_period_days,
    28,
  );
  assertEquals(countHost(log, "portal.apvma.gov.au"), 1, "stub tried once");
  assertEquals(countHost(log, ELABELS_HOST), 2, "fallback tried with one retry");
});

// ===========================================================================
// LD-F — a redirect off the official host is rejected and NEVER fetched
// ===========================================================================

Deno.test("LD-F: a portal redirect to a foreign host is discarded — the foreign URL is never requested; the verified fallback takes over", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const deps = makeDeps({
    register: sprayRegister(),
    portal: () =>
      new Response(stubHtml("https://evil.example.com/80160ELBL.pdf"), { status: 200 }),
    elabels: () => pdfResponse(),
  }, log);

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps);
  const reg = discovery.registration!;
  assert(log.every((u) => !u.includes("evil.example.com")), "foreign host never contacted");
  assertEquals(reg.label_document?.url, "https://elabels.apvma.gov.au/80160ELBL.pdf");
  assertEquals(reg.label_document?.confirmation, "document_fetch");
});

// ===========================================================================
// LD-G — unresolved/ambiguous identities never attempt document discovery
// ===========================================================================

Deno.test("LD-G: unresolved and ambiguous register outcomes never touch the portal or eLabels hosts", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const empty: RegisterData = {
    products: [],
    prodcon: {},
    constit: {},
    labelreg: {},
    produse: {},
    hosts: {},
    pests: {},
    prodcom: {},
  };
  const deps = makeDeps({
    register: empty,
    portal: () => pdfResponse(), // would "succeed" if ever (wrongly) consulted
    elabels: () => pdfResponse(),
  }, log);
  const unresolved = await discoverAuthoritative("AU", "Nonexistent Product", null, deps);
  assertEquals(unresolved.outcome, "unresolved");

  clearApvmaCache();
  const ambiguous: RegisterData = {
    ...empty,
    products: [
      { ...CUSTODIA_FORTE_ROW, pcode: "91636" },
      { ...CUSTODIA_FORTE_ROW, pcode: "91637" },
    ],
  };
  const deps2 = makeDeps({ register: ambiguous }, log);
  const tied = await discoverAuthoritative("AU", "CUSTODIA FORTE FUNGICIDE", null, deps2);
  assertEquals(tied.outcome, "ambiguous");

  assertEquals(countHost(log, "portal.apvma.gov.au"), 0, "no document lookup without identity");
  assertEquals(countHost(log, ELABELS_HOST), 0, "no document lookup without identity");
});

// ===========================================================================
// LD-H — cache-fronted discovery (transport load shedding only)
// ===========================================================================

Deno.test("LD-H: discovery result is cached — repeat calls fetch nothing new; clearing the adapter cache clears it", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const deps = makeDeps({
    register: sprayRegister(),
    portal: () =>
      new Response(stubHtml("https://elabels.apvma.gov.au/80160ELBL.pdf"), { status: 200 }),
    elabels: () => pdfResponse(),
  }, log);

  const first = await discoverLabelDocument(deps, "80160");
  assert(first?.document, "full discovery");
  const requestsAfterFirst = log.length;

  const second = await discoverLabelDocument(deps, "80160");
  assertEquals(second?.url, first!.url);
  assertEquals(log.length, requestsAfterFirst, "cache hit — no new requests");

  clearApvmaCache();
  await discoverLabelDocument(deps, "80160");
  assert(log.length > requestsAfterFirst, "cache cleared — discovery re-fetches");
});

// ===========================================================================
// LD-I — a 200 that is not a PDF proves nothing about the document
// ===========================================================================

Deno.test("LD-I: eLabels serving an HTML page instead of the PDF → URL-only provenance, no hash, nothing invented", async () => {
  clearApvmaCache();
  const log: string[] = [];
  const expectedUrl = "https://elabels.apvma.gov.au/80160ELBL.pdf";
  const deps = makeDeps({
    register: sprayRegister(),
    portal: () => new Response(stubHtml(expectedUrl), { status: 200 }),
    elabels: () => new Response("<html>scheduled maintenance</html>", { status: 200 }),
  }, log);

  const doc = await discoverLabelDocument(deps, "80160");
  assertEquals(doc?.url, expectedUrl, "portal confirmation stands");
  assertEquals(doc?.document, null, "non-PDF bytes are never hashed as the document");

  const source = labelDocumentSource("80160", doc!);
  assertEquals(source.kind, "manufacturer_label");
  assert(source.name.includes("PDF not retrieved"));
  assertEquals(source.reference, expectedUrl);
});
