// Stage LD-2 tests — authoritative label PDF extraction + deterministic
// rate binding.
//
// Scope pinned by these tests (docs/chemical-label-document-extraction-design.md
// §3 "Stage LD-2", §5):
//   LD2-A  Sprayseal 80160 (REAL captured text-layer fixture): one DFU row
//          binds to BOTH register claims as per_100_litres 30 mL with the
//          verbatim wording; the product-level "NOT REQUIRED" withholding
//          statement parses to an authoritative 0 days; every touched gap
//          clears; provenance reads manufacturer_label end to end.
//   LD2-B  Custodia Forte 91636 (REAL captured fixture): per-crop tables —
//          grape rows bind dilute + concentrate bases per target, the
//          rate-less Botrytis row serves nothing, almond/macadamia rows
//          fail closed into unbound_rows, and the register-stated 28-day
//          grape WHP stands undisturbed (document corroborates).
//   LD2-C  A document rate vs AI rate disagreement → the document is
//          served, a structured conflict is recorded; AI never establishes
//          a label value. Equal readings produce no conflict.
//   LD2-D  Two rows binding one claim with different same-basis rates →
//          fail closed: no rate served, both rows in unbound_rows.
//   LD2-E  Unparseable rate wording → verbatim raw_text only (basis
//          "other"), numeric fields absent, structured-rate gap stays.
//   LD2-F  PDF timeout / 404 / extraction failure → response byte-
//          equivalent to LD-1 behaviour (no rates, no envelope, gaps stay).
//   LD2-G  unresolved/ambiguous identities never reach the extractor.
//   LD2-H  Document WHP disagreeing with register statements → conflict
//          recorded, register value served.
//   LD2-I  Extraction is cache-fronted alongside discovery.
//   LD2-J  Refresh signatures: stored document rates are compared only
//          against a fresh extraction (an outage is never drift).

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  LABEL_PARSER_VERSION,
  parseDirectionsForUse,
  parseRateCell,
} from "./label_extract.ts";
import { labelClaimsSignature, storedUsesSignature } from "./label.ts";
import { ELABELS_HOST } from "./label_document.ts";
import { APVMA_RESOURCES, clearApvmaCache } from "./apvma.ts";
import {
  buildCandidatePayload,
  buildRegisterOnlyStructured,
  discoverAuthoritative,
  mergeDiscoveryIntoStructured,
} from "./ingest.ts";
import type {
  AdapterDeps,
  LabelEvidence,
  PdfTextItem,
  WireLabelRate,
} from "./contract.ts";

// ---------------------------------------------------------------------------
// REAL captured text-layer fixtures (unpdf items from the live eLabels PDFs,
// verbatim: page / x / y / width / text). Comment paragraphs are trimmed —
// they are carried verbatim, never parsed.
// ---------------------------------------------------------------------------

function T(page: number, x: number, y: number, width: number, str: string): PdfTextItem {
  return { page, x, y, width, str };
}

/** Sprayseal 80160 — 80160ELBL.pdf (single DFU table WITH a CROP column). */
const SPRAYSEAL_ITEMS: PdfTextItem[] = [
  // Page 1 — product-level withholding statement.
  T(1, 46.8, 145.4, 91.7, "Withholding Periods:"),
  T(1, 138.4, 145.4, 19.2, " "),
  T(1, 157.7, 145.4, 331.4, "WITHHOLDING PERIOD - NOT REQUIRED WHEN USED AS DIRECTED"),
  // Page 3 — the DFU table.
  T(3, 93.7, 712.9, 133.1, "DIRECTIONS FOR USE"),
  T(3, 115.3, 701, 27.3, "CROP"),
  T(3, 142.5, 701, 2.3, " "),
  T(3, 163.9, 701, 41.4, "DISEASE"),
  T(3, 205.3, 701, 4.6, " "),
  T(3, 249, 701, 25.6, "RATE"),
  T(3, 274.7, 701, 4.8, " "),
  T(3, 320, 701, 101.4, "CRITICAL COMMENTS"),
  T(3, 104.1, 689.6, 48.1, "Grapevines"),
  T(3, 152.2, 689.6, 1.2, " "),
  T(3, 163.9, 689.6, 29.3, "Eutypa"),
  T(3, 193.2, 689.6, 0.3, " "),
  T(3, 195.8, 689.6, 32.5, "dieback"),
  T(3, 163.9, 678.8, 63.3, "Botryosphaeria"),
  T(3, 163.9, 668, 32.4, "dieback"),
  T(3, 249, 689.6, 53.9, "Mix 30 mL of"),
  T(3, 249, 678.8, 59.7, "SpraySeal per"),
  T(3, 249, 668, 48.6, "100 litres of"),
  T(3, 249, 657.2, 23, "water"),
  T(3, 319.9, 689.6, 192.4, "Shake or stir container well before use. Spray"),
  T(3, 319.9, 678.8, 178.9, "grapevines to runoff. Apply only during the"),
  T(3, 319.9, 668, 161.6, "dormant winter period on fresh pruning"),
  T(3, 319.9, 657.2, 32.4, "wounds"),
  T(3, 352.3, 657.2, 0.3, " "),
  T(3, 354.8, 657.2, 67.1, "within six days"),
  T(3, 421.9, 657.2, 0.3, " "),
  T(3, 424.4, 657.2, 82.6, "of when the pruning"),
  T(3, 319.9, 646.4, 177.9, "cut is made. Only one spray per season is"),
  T(3, 319.9, 635.6, 39.8, "sufficient."),
  T(3, 93.7, 623.3, 406.5, "NOT TO BE USED FOR ANY PURPOSE, OR IN ANY MANNER, CONTRARY TO THIS"),
  T(3, 93.7, 611.5, 340.4, "LABEL UNLESS AUTHORISED UNDER APPROPRIATE LEGISLATION"),
];

export const SPRAYSEAL_RATE_TEXT = "Mix 30 mL of SpraySeal per 100 litres of water";

/** Custodia Forte 91636 — 91636ELBL.pdf (per-crop "Table N." DFU tables;
 * Table 1's CRITICAL COMMENTS header is indented 95pt right of its column's
 * content edge — the measured geometry the column learner exists for). */
function forteItems(grapeWhpLine =
  "GRAPEVINES: DO NOT HARVEST FOR 4 WEEKS AFTER APPLICATION."): PdfTextItem[] {
  return [
    // Page 1/2 — withholding statements.
    T(1, 46.8, 57.4, 91.7, "Withholding Periods:"),
    T(1, 138.4, 57.4, 19.2, " "),
    T(1, 157.7, 57.4, 118.8, "WITHHOLDING PERIODS"),
    T(2, 157.7, 784.9, 34.4, "Harvest"),
    T(2, 157.7, 772.9, 268.1, "ALMONDS: NOT REQUIRED WHEN USED AS DIRECTED."),
    T(2, 157.7, 760.9, 337.4, grapeWhpLine),
    T(2, 157.7, 748.9, 336.3, "MACADAMIAS: DO NOT HARVEST FOR 15 DAYS AFTER APPLICATION."),
    // Page 5 — Table 1. Almonds (no register claims → must fail closed).
    T(5, 72, 772.9, 108.9, "DIRECTIONS FOR USE"),
    T(5, 72, 756.4, 74.5, "Table 1. Almonds"),
    T(5, 75.5, 740.5, 39.5, "DISEASE"),
    T(5, 115, 740.5, 45.8, " "),
    T(5, 160.8, 740.5, 24.5, "RATE"),
    T(5, 185.3, 740.5, 140.3, " "),
    T(5, 325.6, 740.5, 97.1, "CRITICAL COMMENTS"),
    T(5, 75.5, 727.7, 43.6, "Brown rot /"),
    T(5, 75.5, 717.3, 58.6, "Blossom blight"),
    T(5, 75.5, 707, 3, "("),
    T(5, 78.5, 707, 54.5, "Monilinia laxa"),
    T(5, 133.1, 707, 5.5, "),"),
    T(5, 75.5, 690.6, 38.6, "Shot-hole"),
    T(5, 75.5, 680.3, 3, "("),
    T(5, 78.5, 680.3, 58, "Wilsonomyces"),
    T(5, 75.5, 669.9, 46.1, "carpophilus"),
    T(5, 121.7, 669.9, 5.4, "),"),
    T(5, 75.5, 653.6, 24.1, "Rust ("),
    T(5, 99.6, 653.6, 50.9, "Tranzschelia"),
    T(5, 75.5, 643.2, 31, "discolor"),
    T(5, 106.6, 643.2, 5.5, "),"),
    T(5, 75.5, 626.9, 28.6, "Hull rot"),
    T(5, 75.5, 616.5, 3, "("),
    T(5, 78.5, 616.5, 37.6, "Rhizopus"),
    T(5, 116.1, 616.5, 2.5, " "),
    T(5, 118.6, 616.5, 15.1, "and"),
    T(5, 75.5, 606.2, 35.6, "Monilinia"),
    T(5, 111.1, 606.2, 2.5, " "),
    T(5, 113.5, 606.2, 20.1, "spp.)"),
    T(5, 75.5, 595.8, 73.6, "(suppression only)"),
    T(5, 160.8, 727.7, 25, "Dilute"),
    T(5, 160.8, 717.3, 40.6, "spraying:"),
    T(5, 160.8, 707, 50.1, "32 mL/100 L"),
    T(5, 160.8, 686.3, 52.6, "Concentrate"),
    T(5, 160.8, 675.9, 40.6, "spraying:"),
    T(5, 160.8, 665.6, 42.6, "540 mL/ha"),
    T(5, 230.5, 727.7, 150.1, "Application rate and spray volume:"),
    T(5, 230.5, 717.3, 287.1, "Use the 32 mL/100 L rate in up to 1600 litres/ha water. If using higher"),
    // Page 6 — Table 2. Grapevines.
    T(6, 72, 773.9, 85.1, "Table 2. Grapevines"),
    T(6, 75.5, 758, 39.5, "DISEASE"),
    T(6, 115, 758, 45.8, " "),
    T(6, 160.8, 758, 24.5, "RATE"),
    T(6, 185.3, 758, 45, " "),
    T(6, 230.3, 758, 97.1, "CRITICAL COMMENTS"),
    T(6, 75.5, 745.2, 65.6, "Powdery Mildew"),
    T(6, 75.5, 734.9, 3, "("),
    T(6, 78.5, 734.9, 38.1, "Uncinular"),
    T(6, 75.5, 724.4, 30.1, "necator"),
    T(6, 105.6, 724.4, 3, ")"),
    T(6, 160.8, 745.2, 25, "Dilute"),
    T(6, 160.8, 734.9, 40.6, "spraying:"),
    T(6, 160.8, 724.4, 50.6, "35 or 54 mL/"),
    T(6, 160.8, 714.1, 21.1, "100 L"),
    T(6, 160.8, 693.5, 52.6, "Concentrate"),
    T(6, 160.8, 683.1, 40.6, "spraying:"),
    T(6, 160.8, 672.7, 42.6, "540 mL/ha"),
    T(6, 230.3, 745.2, 71.5, "Apply CUSTODIA"),
    T(6, 301.9, 748.2, 4.4, "®"),
    T(6, 306.3, 748.2, 2.5, " "),
    T(6, 308.8, 745.2, 190.1, "FORTE as part of a season-long spray program"),
    T(6, 230.3, 734.9, 148.6, "targeting the following growth stages:"),
    T(6, 75.5, 528.6, 58.1, "Downy Mildew"),
    T(6, 75.5, 518.1, 3, "("),
    T(6, 78.5, 518.1, 48, "Plasmopara"),
    T(6, 75.5, 507.8, 27.5, "viticola"),
    T(6, 103.1, 507.8, 3, ")"),
    T(6, 160.8, 528.6, 25, "Dilute"),
    T(6, 160.8, 518.1, 40.6, "spraying:"),
    T(6, 160.8, 507.8, 50.1, "54 mL/100 L"),
    T(6, 160.8, 487.2, 52.6, "Concentrate"),
    T(6, 160.8, 476.7, 40.6, "spraying:"),
    T(6, 160.8, 466.4, 42.6, "540 mL/ha"),
    T(6, 230.3, 528.6, 73.4, "Apply CUSTODIA"),
    T(6, 312.5, 528.6, 205.1, "FORTE as part of a seasonal preventative spray"),
    T(6, 75.5, 454, 58.1, "Botrytis Bunch"),
    T(6, 75.5, 443.7, 14, "Rot"),
    T(6, 75.5, 433.4, 3, "("),
    T(6, 78.5, 433.4, 62.1, "Botrytis cinerea"),
    T(6, 140.7, 433.4, 3, ")"),
    T(6, 230.3, 454, 72.2, "When CUSTODIA"),
    T(6, 309.2, 454, 208.4, "FORTE is used in a seasonal spray programme it will"),
    // Page 6 — Table 3. Macadamias (no register claims → must fail closed).
    T(6, 72, 281.8, 89.5, "Table 3. Macadamias"),
    T(6, 75.5, 266, 39.5, "DISEASE"),
    T(6, 115, 266, 45.8, " "),
    T(6, 160.8, 266, 24.5, "RATE"),
    T(6, 185.3, 266, 45, " "),
    T(6, 230.5, 266, 97.1, "CRITICAL COMMENTS"),
    T(6, 75.5, 253.1, 39.9, "Husk spot"),
    T(6, 75.5, 242.8, 3, "("),
    T(6, 78.5, 242.8, 70.2, "Pseudocercospor"),
    T(6, 75.5, 232.4, 55.3, "a macadamiae"),
    T(6, 134.7, 232.4, 3, ")"),
    T(6, 160.8, 253.1, 50.1, "32 mL/100 L"),
    T(6, 230.5, 253.1, 37.9, "Apply up"),
  ];
}

// ---------------------------------------------------------------------------
// Register + document host harness (mirrors label_document_test.ts)
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

/** Sprayseal 80160 with BOTH register claims and the REAL product-level
 * "NOT REQUIRED" withholding statement (the register publishes no
 * crop-prefixed WHP for this product — Stage 4 leaves the gap open). */
function sprayRegisterLd2(): RegisterData {
  return {
    products: [{
      pcode: "80160",
      fpname: "Sprayseal Pruning Wound Treatment",
      sname: "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
      hlevel1: "FUNGICIDE",
      fdesc: "SUSPENSION CONCENTRATE",
      regcode: "R",
      expdate: "30/06/2030 0:00",
    }],
    prodcon: {
      "80160": [
        { pcode: "80160", ccode: "TZTB", ctype: "A", camount: "430.000000", cucode: "g/L" },
      ],
    },
    constit: { TZTB: "TEBUCONAZOLE" },
    labelreg: { "80160": [{ pcode: "80160", regno: "113355", regdate: "1/07/2025 0:00" }] },
    produse: {
      "80160": [
        { pcode: "80160", hostcode: "FRVG", pestcode: "YDIEB" },
        { pcode: "80160", hostcode: "FRVG", pestcode: "YBOTD" },
      ],
    },
    hosts: { FRVG: "GRAPEVINE" },
    pests: { YDIEB: "EUTYPA DIEBACK", YBOTD: "BOTRYOSPHAERIA DIEBACK" },
    prodcom: {
      "80160": [{
        pcode: "80160",
        seq: 1,
        applic: "WITHHOLDING PERIOD\nWITHHOLDING PERIOD - NOT REQUIRED WHEN USED AS DIRECTED",
      }],
    },
  };
}

/** Custodia Forte 91636 with three grape claims and the register-published
 * 28-day grape WHP statement. */
function forteRegisterLd2(): RegisterData {
  return {
    products: [{
      pcode: "91636",
      fpname: "CUSTODIA FORTE FUNGICIDE",
      sname: "ADAMA AUSTRALIA PTY LIMITED",
      hlevel1: "FUNGICIDE",
      fdesc: "SUSPENSION CONCENTRATE",
      regcode: "R",
      expdate: "30/06/2029 0:00",
    }],
    prodcon: {
      "91636": [
        { pcode: "91636", ccode: "PMAZ", ctype: "A", camount: "222.000000", cucode: "g/L" },
        { pcode: "91636", ccode: "TZTB", ctype: "A", camount: "370.000000", cucode: "g/L" },
      ],
    },
    constit: { PMAZ: "AZOXYSTROBIN", TZTB: "TEBUCONAZOLE" },
    labelreg: { "91636": [{ pcode: "91636", regno: "132920", regdate: "2/03/2022 9:50:13 AM" }] },
    produse: {
      "91636": [
        { pcode: "91636", hostcode: "FRVG", pestcode: "YMIP" },
        { pcode: "91636", hostcode: "FRVG", pestcode: "YMID" },
        { pcode: "91636", hostcode: "FRVG", pestcode: "YBOT" },
      ],
    },
    hosts: { FRVG: "GRAPEVINE" },
    pests: { YMIP: "POWDERY MILDEW", YMID: "DOWNY MILDEW", YBOT: "BOTRYTIS" },
    prodcom: {
      "91636": [{
        pcode: "91636",
        seq: 1,
        applic:
          "WITHHOLDING PERIODS\nHarvest\nGRAPES: DO NOT HARVEST FOR 4 WEEKS AFTER APPLICATION.",
      }],
    },
  };
}

const PDF_BYTES = new Uint8Array(new TextEncoder().encode(
  "%PDF-1.6\n1 0 obj\n<< /Producer (VineTrack LD-2 fixture) >>\nendobj\ntrailer\n%%EOF\n",
));

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function stubHtml(redirectUrl: string): string {
  return `<html><body><button onclick="javascript:window.location.replace('${redirectUrl}');">View label</button></body></html>`;
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

type HostHandler = (url: URL) => Response | "reject";

interface Harness {
  register: RegisterData;
  portal?: HostHandler;
  elabels?: HostHandler;
  /** Injected text extractor; counts invocations. */
  items?: PdfTextItem[];
  extractorError?: boolean;
}

interface HarnessState {
  log: string[];
  extractorCalls: number;
  deps: AdapterDeps;
}

function makeHarness(h: Harness): HarnessState {
  const state: HarnessState = { log: [], extractorCalls: 0, deps: undefined as unknown as AdapterDeps };
  const fetchFn = ((input: Request | URL | string): Promise<Response> => {
    const url = new URL(String(input));
    state.log.push(url.toString());
    if (url.hostname === "data.gov.au") {
      return Promise.resolve(ckanRespond(h.register, url));
    }
    if (url.hostname === "portal.apvma.gov.au") {
      const out = h.portal?.(url) ?? "reject";
      return out === "reject"
        ? Promise.reject(new Error("connection dropped"))
        : Promise.resolve(out);
    }
    if (url.hostname === ELABELS_HOST) {
      const out = h.elabels?.(url) ?? "reject";
      return out === "reject"
        ? Promise.reject(new Error("connection dropped"))
        : Promise.resolve(out);
    }
    return Promise.reject(new Error(`forbidden host: ${url.hostname}`));
  }) as typeof fetch;
  state.deps = {
    fetchFn,
    now: () => new Date("2026-08-20T00:00:00Z"),
    extractPdfText: (_bytes: Uint8Array): Promise<PdfTextItem[]> => {
      state.extractorCalls++;
      if (h.extractorError) return Promise.reject(new Error("parser exploded"));
      return Promise.resolve(h.items ?? []);
    },
  };
  return state;
}

function fullDocumentHarness(register: RegisterData, pcode: string, items: PdfTextItem[]): HarnessState {
  return makeHarness({
    register,
    items,
    portal: () =>
      new Response(stubHtml(`https://elabels.apvma.gov.au/${pcode}ELBL.pdf`), { status: 200 }),
    elabels: () =>
      new Response(PDF_BYTES, { status: 200, headers: { "Content-Type": "application/pdf" } }),
  });
}

// deno-lint-ignore no-explicit-any
function squashTarget(text: unknown): string {
  return String(text ?? "").toUpperCase().replace(/[^A-Z0-9]+/g, "");
}

/**
 * The use the REGISTER calls `targetRaw`.
 *
 * Stage LD-3 serves the label DOCUMENT's own printed wording as `target_raw`
 * ("Eutypa dieback" where the register publishes "EUTYPA DIEBACK"), keeping
 * the register wording beside it in `register_target_raw`/`target_synonyms`.
 * These tests are about which use owns which printed RATE cell, so they find
 * the use by either wording — the wording itself is pinned, separately and
 * exactly, in label_target_wording_test.ts.
 */
// deno-lint-ignore no-explicit-any
function matchesTarget(entry: any, targetRaw: string): boolean {
  const want = squashTarget(targetRaw);
  if (squashTarget(entry?.target_raw) === want) return true;
  if (squashTarget(entry?.register_target_raw) === want) return true;
  return (entry?.target_synonyms ?? []).some((s: string) => squashTarget(s) === want);
}

// deno-lint-ignore no-explicit-any
function useFor(merged: any, targetRaw: string): any {
  // deno-lint-ignore no-explicit-any
  return merged.registered_uses.find((u: any) => matchesTarget(u, targetRaw));
}

// ===========================================================================
// Rate grammar units (bounded, deterministic)
// ===========================================================================

Deno.test("LD2 grammar: measured label wordings parse exactly; unparseable wording stays verbatim; multiple same-basis rates are kept independently", () => {
  // The Sprayseal regression statement.
  assertEquals(parseRateCell(SPRAYSEAL_RATE_TEXT), [{
    label: "",
    raw_text: SPRAYSEAL_RATE_TEXT,
    basis: "per_100_litres",
    value: 30,
    unit: "mL",
  }]);

  // Custodia Forte grape powdery cell: an "or" pair + a concentrate rate.
  const powdery = "Dilute spraying: 35 or 54 mL/ 100 L Concentrate spraying: 540 mL/ha";
  assertEquals(parseRateCell(powdery), [
    {
      label: "Dilute spraying",
      raw_text: powdery,
      basis: "range_per_100_litres",
      min_value: 35,
      max_value: 54,
      unit: "mL",
    },
    { label: "Concentrate spraying", raw_text: powdery, basis: "per_hectare", value: 540, unit: "mL" },
  ]);

  // Simple slash forms.
  assertEquals(parseRateCell("54 mL/100 L")[0], {
    label: "",
    raw_text: "54 mL/100 L",
    basis: "per_100_litres",
    value: 54,
    unit: "mL",
  });
  assertEquals(parseRateCell("1.5 kg/ha")[0], {
    label: "",
    raw_text: "1.5 kg/ha",
    basis: "per_hectare",
    value: 1.5,
    unit: "kg",
  });
  assertEquals(parseRateCell("200 to 400 mL/ha")[0].basis, "range_per_hectare");

  // Unparseable wording → verbatim only, no numbers ever guessed.
  assertEquals(parseRateCell("Apply as directed by an agronomist"), [{
    label: "",
    basis: "other",
    unit: "",
    raw_text: "Apply as directed by an agronomist",
  }]);

  // Two different numbers on the SAME basis in one cell.
  //
  // This USED to collapse the whole cell into one unusable `basis:"other"`
  // entry — the defect that produced "2 L / 100 L 3 L / 100 L 3 L / 100 L…".
  // Both readings are now kept as independent structured rates. The trailing
  // "early season" / "late season" wording is NOT a qualifier the grammar can
  // attribute (it follows the rate rather than introducing it), so the
  // association is declared unproven instead of being guessed.
  const conflicted = "30 mL/100 L early season 60 mL/100 L late season";
  assertEquals(parseRateCell(conflicted), [
    {
      label: "",
      raw_text: conflicted,
      basis: "per_100_litres",
      value: 30,
      unit: "mL",
      condition_ambiguous: true,
    },
    {
      label: "",
      raw_text: conflicted,
      basis: "per_100_litres",
      value: 60,
      unit: "mL",
      condition_ambiguous: true,
    },
  ]);

  // The same shape WITH attributable qualifiers: two rates, each owning its
  // condition, and nothing ambiguous.
  const qualified = "Dilute spraying: 2 L/100 L Concentrate spraying: 3 L/100 L";
  assertEquals(parseRateCell(qualified), [
    {
      label: "Dilute spraying",
      raw_text: qualified,
      basis: "per_100_litres",
      value: 2,
      unit: "L",
    },
    {
      label: "Concentrate spraying",
      raw_text: qualified,
      basis: "per_100_litres",
      value: 3,
      unit: "L",
    },
  ]);

  // Empty cell → no rates at all (a rate the label does not give is absent).
  assertEquals(parseRateCell("   "), []);
});

Deno.test("LD2 DFU parse: Sprayseal's crop-column table and Custodia Forte's per-crop titled tables both reconstruct verbatim rows", () => {
  const spray = parseDirectionsForUse(SPRAYSEAL_ITEMS);
  assert(spray.found);
  assertEquals(spray.rows.length, 1, "the footer never becomes a row");
  assertEquals(spray.rows[0].crop_text, "Grapevines");
  assertEquals(spray.rows[0].target_lines, ["Eutypa dieback", "Botryosphaeria", "dieback"]);
  assertEquals(spray.rows[0].rate_text, SPRAYSEAL_RATE_TEXT);
  assert(spray.rows[0].comments_text.startsWith("Shake or stir container well before use."));

  const forte = parseDirectionsForUse(forteItems());
  assertEquals(forte.rows.map((r) => r.crop_text), [
    "Almonds",
    "Grapevines",
    "Grapevines",
    "Grapevines",
    "Macadamias",
  ]);
  const [almond, powdery, downy, botrytis, macadamia] = forte.rows;
  assertEquals(
    powdery.rate_text,
    "Dilute spraying: 35 or 54 mL/ 100 L Concentrate spraying: 540 mL/ha",
  );
  assertEquals(downy.rate_text, "Dilute spraying: 54 mL/100 L Concentrate spraying: 540 mL/ha");
  assertEquals(botrytis.rate_text, "", "the Botrytis row prints no rate cell");
  assertEquals(macadamia.rate_text, "32 mL/100 L");
  // The measured indented-header hazard: Table 1's comments must NOT leak
  // into its rate cell (the column learner reads content edges).
  assertEquals(almond.rate_text, "Dilute spraying: 32 mL/100 L Concentrate spraying: 540 mL/ha");
  assert(almond.comments_text.startsWith("Application rate and spray volume:"));
});

// ===========================================================================
// LD2-A — Sprayseal 80160: exact single-rate binding (primary regression)
// ===========================================================================

Deno.test("LD2-A: Sprayseal 80160 — the label statement binds to BOTH register claims as per_100_litres 30 mL; WHP 'NOT REQUIRED' parses to authoritative 0 days; provenance is manufacturer_label end to end", async () => {
  clearApvmaCache();
  const h = fullDocumentHarness(sprayRegisterLd2(), "80160", SPRAYSEAL_ITEMS);

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, h.deps);
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration!;
  assertEquals(h.extractorCalls, 1, "the fetched document is extracted once");

  const expectedRate: WireLabelRate = {
    label: "",
    raw_text: SPRAYSEAL_RATE_TEXT,
    basis: "per_100_litres",
    value: 30,
    unit: "mL",
  };
  const evidence = reg.label_evidence!;
  for (const target of ["EUTYPA DIEBACK", "BOTRYOSPHAERIA DIEBACK"]) {
    const claim = evidence.claims.find((c) => matchesTarget(c, target))!;
    assertEquals(claim.rates, [expectedRate], `${target} carries the document rate`);
    assertEquals(claim.withholding_period_days, 0, "NOT REQUIRED → authoritative 0 days");
  }
  assert(!reg.unresolved_fields.includes("rates:GRAPEVINE"), "structured rate clears the gap");
  assert(
    !reg.unresolved_fields.includes("withholding_period:GRAPEVINE"),
    "document WHP clears the gap",
  );
  assertEquals(evidence.unbound_rows, [], "every row bound");
  assertEquals(evidence.document_conflicts, []);
  assertEquals(evidence.document?.sha256, await sha256Hex(PDF_BYTES));
  assertEquals(evidence.document?.parser_version, LABEL_PARSER_VERSION);

  // Serving path.
  const merged = buildRegisterOnlyStructured(reg, 1);
  const use = useFor(merged, "EUTYPA DIEBACK");
  assertEquals(use.rates, [expectedRate]);
  assertEquals(use.provenance.rates, "manufacturer_label");
  assertEquals(use.withholding_period_days, 0);
  assertEquals(merged.field_provenance.label_rates, "manufacturer_label");
  assertEquals(merged.label_rate_bases, ["per_100_litres"]);
  assertEquals(merged.verification.status, "partially_verified", "no conflicts anywhere");
  assert(!merged.verification.unresolved_fields.includes("rates:GRAPEVINE"));
  assertEquals(merged.label_extraction.document_url, "https://elabels.apvma.gov.au/80160ELBL.pdf");
  assertEquals(merged.label_extraction.parser_version, LABEL_PARSER_VERSION);
  assertEquals(merged.label_extraction.unbound_rows, []);
  assert(
    use.restrictions.includes("Shake or stir container well before use."),
    "critical comments append verbatim",
  );

  // Candidate rows carry the document rates.
  const payload = buildCandidatePayload(merged, "Spray Seal", reg, "2026-08-20T00:00:00Z", 1);
  // deno-lint-ignore no-explicit-any
  const payloadUse = payload!.registered_uses.find((u: any) => matchesTarget(u, "EUTYPA DIEBACK"));
  assertEquals(payloadUse.rates, [expectedRate]);
  assertEquals(payload!.label_rate_bases, ["per_100_litres"]);
});

// ===========================================================================
// LD2-B — Custodia Forte 91636: multi crop/target binding (secondary)
// ===========================================================================

Deno.test("LD2-B: Custodia Forte 91636 — grape rows bind dilute+concentrate rates per target; Botrytis row serves no rate; almond/macadamia rows fail closed; the 28-day grape WHP stands undisturbed", async () => {
  clearApvmaCache();
  const h = fullDocumentHarness(forteRegisterLd2(), "91636", forteItems());

  const discovery = await discoverAuthoritative("AU", "CUSTODIA FORTE FUNGICIDE", null, h.deps);
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration!;
  const merged = buildRegisterOnlyStructured(reg, 1);

  const powdery = useFor(merged, "POWDERY MILDEW");
  assertEquals(powdery.rates.length, 2);
  assertEquals(powdery.rates[0].basis, "range_per_100_litres");
  assertEquals(powdery.rates[0].min_value, 35);
  assertEquals(powdery.rates[0].max_value, 54);
  assertEquals(powdery.rates[0].unit, "mL");
  assertEquals(powdery.rates[0].label, "Dilute spraying");
  assertEquals(powdery.rates[1].basis, "per_hectare");
  assertEquals(powdery.rates[1].value, 540);
  assertEquals(powdery.rates[1].label, "Concentrate spraying");
  assertEquals(powdery.withholding_period_days, 28, "register WHP undisturbed");
  assert(powdery.restrictions.includes("season-long spray program"));

  const downy = useFor(merged, "DOWNY MILDEW");
  assertEquals(downy.rates.length, 2);
  assertEquals(downy.rates[0].basis, "per_100_litres");
  assertEquals(downy.rates[0].value, 54);
  assertEquals(downy.rates[1].basis, "per_hectare");
  assertEquals(downy.rates[1].value, 540);
  assertEquals(downy.withholding_period_days, 28);

  const botrytis = useFor(merged, "BOTRYTIS");
  assertEquals(botrytis.rates, [], "a row printing no rate serves no rate");
  assertEquals(botrytis.withholding_period_days, 28);
  assertEquals(botrytis.provenance.rates, null);

  // The document agrees with the register's 28-day statement → no conflict.
  assertEquals(merged.verification.conflicts, []);
  assertEquals(merged.verification.status, "partially_verified");

  // Almond + macadamia rows correspond to NO register claim → unbound.
  // deno-lint-ignore no-explicit-any
  const unboundCrops = merged.label_extraction.unbound_rows.map((r: any) => r.crop_text);
  assertEquals(unboundCrops, ["Almonds", "Macadamias"]);
  assertEquals(
    // deno-lint-ignore no-explicit-any
    merged.label_extraction.unbound_rows.every((r: any) => r.reason === "no_corresponding_claim"),
    true,
  );
  assert(
    // deno-lint-ignore no-explicit-any
    merged.label_extraction.unbound_rows[0].rate_texts[0].includes("32 mL/100 L"),
    "unbound rows preserve their verbatim rate text",
  );

  assert(!merged.verification.unresolved_fields.includes("rates:GRAPEVINE"));
  assertEquals(
    merged.label_rate_bases.sort(),
    ["per_100_litres", "per_hectare", "range_per_100_litres"],
  );
  assertEquals(merged.field_provenance.label_rates, "manufacturer_label");
});

// ===========================================================================
// LD2-C — document rate vs AI rate: conflict, never AI-established
// ===========================================================================

Deno.test("LD2-C: an AI rate disagreeing with the document rate → document served, disagreement recorded as superseded (not an operator conflict); an agreeing AI rate records nothing", async () => {
  clearApvmaCache();
  const h = fullDocumentHarness(sprayRegisterLd2(), "80160", SPRAYSEAL_ITEMS);
  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, h.deps);
  const reg = discovery.registration!;

  const aiStructured = (value: number) => ({
    product_name: "Sprayseal",
    product_category: "fungicide",
    form_type: "liquid",
    registration: { country_code: "AU" },
    active_ingredients: [],
    activity_groups: [],
    activity_group_scheme: null,
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Eutypa dieback",
      rates: [{ label: "", basis: "per_100_litres", value, unit: "mL" }],
    }],
    label_rate_bases: [],
    verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
    schema_version: 1,
  });

  const disagreeing = mergeDiscoveryIntoStructured(aiStructured(50), reg);
  const use = useFor(disagreeing, "EUTYPA DIEBACK");
  assertEquals(use.rates[0].value, 30, "the document rate is served");
  assertEquals(use.provenance.rates, "manufacturer_label");
  // deno-lint-ignore no-explicit-any
  const note = disagreeing.verification.superseded_ai_interpretations.find((c: any) =>
    c.field === "label_rates"
  );
  assert(note, "the AI disagreement is recorded");
  assertEquals(note.extracted_source, "ai_interpretation");
  assertEquals(note.authoritative_source, "manufacturer_label");
  assert(note.extracted_value.includes("50"));
  assert(note.authoritative_value.includes("30"));
  // The approved document settled it — a grower is not asked to arbitrate
  // between the label and a model.
  assertEquals(
    // deno-lint-ignore no-explicit-any
    disagreeing.verification.conflicts.filter((c: any) => c.field === "label_rates"),
    [],
  );
  assertEquals(disagreeing.verification.status, "partially_verified");

  const agreeing = mergeDiscoveryIntoStructured(aiStructured(30), reg);
  assertEquals(
    // deno-lint-ignore no-explicit-any
    (agreeing.verification.superseded_ai_interpretations ?? []).filter((c: any) =>
      c.field === "label_rates"
    ),
    [],
    "an equal reading is corroboration, not a disagreement",
  );
});

// ===========================================================================
// LD2-D — conditional rates across rows are KEPT, each with its condition
// ===========================================================================

/** Synthetic crop-column table: two rows for the SAME claim, each stating a
 * different same-basis rate under its own critical-comments condition. This
 * is the normal shape of a seasonal label, not a conflict. */
const AMBIGUOUS_ITEMS: PdfTextItem[] = [
  T(1, 90, 720, 120, "DIRECTIONS FOR USE"),
  T(1, 100, 700, 30, "CROP"),
  T(1, 200, 700, 45, "DISEASE"),
  T(1, 300, 700, 26, "RATE"),
  T(1, 400, 700, 100, "CRITICAL COMMENTS"),
  T(1, 100, 680, 48, "Grapevines"),
  T(1, 200, 680, 62, "Eutypa dieback"),
  T(1, 300, 680, 55, "30 mL/100 L"),
  T(1, 400, 680, 80, "Early season"),
  T(1, 100, 600, 48, "Grapevines"),
  T(1, 200, 600, 62, "Eutypa dieback"),
  T(1, 300, 600, 55, "60 mL/100 L"),
  T(1, 400, 600, 80, "Late season"),
];

Deno.test("LD2-D: two rows binding one claim serve BOTH rates, each carrying its own row condition", async () => {
  clearApvmaCache();
  const register = sprayRegisterLd2();
  register.produse["80160"] = [{ pcode: "80160", hostcode: "FRVG", pestcode: "YDIEB" }];
  const h = fullDocumentHarness(register, "80160", AMBIGUOUS_ITEMS);

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, h.deps);
  const reg = discovery.registration!;
  const merged = buildRegisterOnlyStructured(reg, 1);

  const use = useFor(merged, "EUTYPA DIEBACK");

  // Both label rates survive. Discarding them (the old behaviour) threw away
  // two correct readings because the parser could not choose between them —
  // but the label never asked anyone to choose: it states both, seasonally.
  assertEquals(use.rates.length, 2, "both conditional rates are served");
  assertEquals(
    // deno-lint-ignore no-explicit-any
    use.rates.map((r: any) => r.value).sort((a: number, b: number) => a - b),
    [30, 60],
  );
  assert(
    // deno-lint-ignore no-explicit-any
    use.rates.every((r: any) => r.basis === "per_100_litres"),
    "the authoritative basis is preserved exactly on both",
  );

  // Each rate carries the condition its own row printed — which is the whole
  // point of keeping them apart.
  assertEquals(
    // deno-lint-ignore no-explicit-any
    use.rates.map((r: any) => r.label).sort(),
    ["Early season", "Late season"],
  );

  // Conditions are attributable, so nothing is flagged ambiguous.
  assert(
    // deno-lint-ignore no-explicit-any
    use.rates.every((r: any) => r.condition_ambiguous === undefined),
    "distinguishable conditions must not be reported as ambiguous",
  );

  // The rate gap clears: structured rates WERE bound for this crop.
  assert(
    !merged.verification.unresolved_fields.includes("rates:GRAPEVINE"),
    "the rate gap must clear once structured rates are served",
  );

  // Nothing was filed for review: both rows bound successfully.
  assertEquals(merged.label_extraction.unbound_rows.length, 0);
});

// ===========================================================================
// LD2-E — malformed rate wording: verbatim only, gap stays
// ===========================================================================

const MALFORMED_ITEMS: PdfTextItem[] = [
  T(1, 90, 720, 120, "DIRECTIONS FOR USE"),
  T(1, 100, 700, 30, "CROP"),
  T(1, 200, 700, 45, "DISEASE"),
  T(1, 300, 700, 26, "RATE"),
  T(1, 400, 700, 100, "CRITICAL COMMENTS"),
  T(1, 100, 680, 48, "Grapevines"),
  T(1, 200, 680, 62, "Eutypa dieback"),
  T(1, 300, 680, 90, "Apply as directed"),
  T(1, 400, 680, 80, "Consult your agronomist"),
];

Deno.test("LD2-E: unparseable rate wording → verbatim raw_text only (basis 'other'), no numbers invented, structured-rate gap stays listed", async () => {
  clearApvmaCache();
  const register = sprayRegisterLd2();
  register.produse["80160"] = [{ pcode: "80160", hostcode: "FRVG", pestcode: "YDIEB" }];
  const h = fullDocumentHarness(register, "80160", MALFORMED_ITEMS);

  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, h.deps);
  const merged = buildRegisterOnlyStructured(discovery.registration!, 1);
  const use = useFor(merged, "EUTYPA DIEBACK");
  assertEquals(use.rates, [{
    label: "",
    basis: "other",
    unit: "",
    raw_text: "Apply as directed",
  }]);
  assertEquals(use.provenance.rates, "manufacturer_label", "a verbatim label quote IS label evidence");
  assert(
    merged.verification.unresolved_fields.includes("rates:GRAPEVINE"),
    "a verbatim-only reading never satisfies the structured-rate gap",
  );
  assert(merged.label_rate_bases.includes("other"));
});

// ===========================================================================
// LD2-F — timeout / 404 / extraction failure: byte-equivalent to LD-1
// ===========================================================================

Deno.test("LD2-F: PDF timeout, 404 and extraction failure each leave the response byte-equivalent to LD-1 behaviour — no rates, no envelope, gaps intact", async () => {
  // (a) transient eLabels failure after portal confirmation → URL-only
  //     discovery, zero extraction, gaps stay.
  clearApvmaCache();
  const transient = makeHarness({
    register: sprayRegisterLd2(),
    portal: () =>
      new Response(stubHtml("https://elabels.apvma.gov.au/80160ELBL.pdf"), { status: 200 }),
    elabels: () => "reject",
  });
  const a = await discoverAuthoritative("AU", "Spray Seal", null, transient.deps);
  assertEquals(a.outcome, "resolved");
  assertEquals(transient.extractorCalls, 0, "no bytes → no extraction attempt");
  const mergedA = buildRegisterOnlyStructured(a.registration!, 1);
  assertEquals(mergedA.registration.label_reference, "https://elabels.apvma.gov.au/80160ELBL.pdf");
  assertEquals(mergedA.label_extraction, undefined, "no extraction envelope");
  assertEquals(useFor(mergedA, "EUTYPA DIEBACK").rates, []);
  assert(mergedA.verification.unresolved_fields.includes("rates:GRAPEVINE"));
  assert(mergedA.verification.unresolved_fields.includes("withholding_period:GRAPEVINE"));

  // (b) definitive 404 → no reference, no extraction, register data intact.
  clearApvmaCache();
  const notFound = makeHarness({
    register: sprayRegisterLd2(),
    portal: () =>
      new Response(stubHtml("https://elabels.apvma.gov.au/80160ELBL.pdf"), { status: 200 }),
    elabels: () => new Response("gone", { status: 404 }),
  });
  const b = await discoverAuthoritative("AU", "Spray Seal", null, notFound.deps);
  assertEquals(notFound.extractorCalls, 0);
  const mergedB = buildRegisterOnlyStructured(b.registration!, 1);
  assertEquals(mergedB.registration.label_reference, null);
  assertEquals(mergedB.label_extraction, undefined);
  assert(mergedB.verification.unresolved_fields.includes("label_reference"));
  assert(mergedB.verification.unresolved_fields.includes("rates:GRAPEVINE"));

  // (c) PDF fetched but the extractor itself fails → discovery provenance
  //     stands (URL + sha256), extraction contributes NOTHING.
  clearApvmaCache();
  const exploding = makeHarness({
    register: sprayRegisterLd2(),
    extractorError: true,
    portal: () =>
      new Response(stubHtml("https://elabels.apvma.gov.au/80160ELBL.pdf"), { status: 200 }),
    elabels: () =>
      new Response(PDF_BYTES, { status: 200, headers: { "Content-Type": "application/pdf" } }),
  });
  const c = await discoverAuthoritative("AU", "Spray Seal", null, exploding.deps);
  assertEquals(exploding.extractorCalls, 1, "extraction attempted once and contained");
  const regC = c.registration!;
  assertEquals(regC.label_document?.document?.sha256, await sha256Hex(PDF_BYTES));
  const mergedC = buildRegisterOnlyStructured(regC, 1);
  assertEquals(mergedC.registration.label_reference, "https://elabels.apvma.gov.au/80160ELBL.pdf");
  assertEquals(mergedC.field_provenance.label_reference, "manufacturer_label");
  assertEquals(mergedC.label_extraction, undefined);
  assertEquals(useFor(mergedC, "EUTYPA DIEBACK").rates, []);
  assert(mergedC.verification.unresolved_fields.includes("rates:GRAPEVINE"));
  assertEquals(mergedC.field_provenance.label_rates, "unresolved");
});

// ===========================================================================
// LD2-G — unresolved/ambiguous identities never reach the extractor
// ===========================================================================

Deno.test("LD2-G: unresolved and ambiguous register outcomes never fetch a document and never invoke the extractor", async () => {
  clearApvmaCache();
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
  const h1 = makeHarness({ register: empty, items: SPRAYSEAL_ITEMS });
  const unresolved = await discoverAuthoritative("AU", "Nonexistent Product", null, h1.deps);
  assertEquals(unresolved.outcome, "unresolved");

  clearApvmaCache();
  const base = forteRegisterLd2().products[0];
  const ambiguousRegister: RegisterData = {
    ...empty,
    products: [{ ...base, pcode: "91636" }, { ...base, pcode: "91637" }],
  };
  const h2 = makeHarness({ register: ambiguousRegister, items: forteItems() });
  const tied = await discoverAuthoritative("AU", "CUSTODIA FORTE FUNGICIDE", null, h2.deps);
  assertEquals(tied.outcome, "ambiguous");

  for (const h of [h1, h2]) {
    assertEquals(h.extractorCalls, 0, "no extraction without a verified identity");
    assertEquals(h.log.filter((u) => u.includes(ELABELS_HOST)).length, 0);
    assertEquals(h.log.filter((u) => u.includes("portal.apvma.gov.au")).length, 0);
  }
});

// ===========================================================================
// LD2-H — document WHP vs register statements: conflict, register stands
// ===========================================================================

Deno.test("LD2-H: a document WHP disagreeing with the register-published statement → structured conflict for review; the register value is served", async () => {
  clearApvmaCache();
  const h = fullDocumentHarness(
    forteRegisterLd2(),
    "91636",
    forteItems("GRAPEVINES: DO NOT HARVEST FOR 6 WEEKS AFTER APPLICATION."),
  );
  const discovery = await discoverAuthoritative("AU", "CUSTODIA FORTE FUNGICIDE", null, h.deps);
  const merged = buildRegisterOnlyStructured(discovery.registration!, 1);

  assertEquals(
    useFor(merged, "POWDERY MILDEW").withholding_period_days,
    28,
    "the register-published statement stands",
  );
  const conflict = merged.verification.conflicts.find(
    // deno-lint-ignore no-explicit-any
    (c: any) => c.field === "withholding_period_days",
  );
  assert(conflict, "the disagreement is recorded, never silently resolved");
  assert(conflict.extracted_value.includes("42 days"));
  assert(conflict.extracted_source.includes("label document"));
  assert(conflict.authoritative_source.includes("register label statements"));
  assertEquals(merged.verification.status, "conflict");
  // Rates still bind — a WHP disagreement never blocks the rate layer.
  assertEquals(useFor(merged, "DOWNY MILDEW").rates.length, 2);
});

// ===========================================================================
// LD2-I — extraction is cache-fronted alongside discovery
// ===========================================================================

Deno.test("LD2-I: repeat lookups reuse the cached document text — the extractor runs once and rates still serve", async () => {
  clearApvmaCache();
  const h = fullDocumentHarness(sprayRegisterLd2(), "80160", SPRAYSEAL_ITEMS);

  await discoverAuthoritative("AU", "Spray Seal", null, h.deps);
  const requestsAfterFirst = h.log.length;
  assertEquals(h.extractorCalls, 1);

  clearApvmaCache(); // clears the DISCOVERY cache result too — so re-resolve…
  const again = await discoverAuthoritative("AU", "Spray Seal", null, h.deps);
  assert(h.extractorCalls >= 1);
  const reg = again.registration!;
  assertEquals(
    reg.label_evidence?.claims.find((c) => matchesTarget(c, "EUTYPA DIEBACK"))?.rates?.[0].value,
    30,
  );
  assert(h.log.length > requestsAfterFirst, "cache cleared — hosts re-consulted");

  // Within the cache TTL: a second lookup adds NO document-host requests and
  // NO extractor run, yet serves identical rates.
  const before = { requests: h.log.length, extracts: h.extractorCalls };
  const cached = await discoverAuthoritative("AU", "Spray Seal", null, h.deps);
  assertEquals(h.log.length, before.requests, "full-result cache hit");
  assertEquals(h.extractorCalls, before.extracts);
  assertEquals(
    cached.registration!.label_evidence?.claims[0].rates?.[0].value,
    30,
  );
});

// ===========================================================================
// LD2-J — refresh signatures: extraction outage is never drift
// ===========================================================================

Deno.test("LD2-J: stored document rates join the refresh comparison ONLY against a fresh extraction — an outage pass compares equal and can never strip them", () => {
  const claimBase = {
    crop: "GRAPEVINE",
    target_raw: "EUTYPA DIEBACK",
    withholding_period_days: 0,
    statements: [],
  };
  const withRates: LabelEvidence = {
    claims: [{
      ...claimBase,
      rates: [{
        label: "",
        basis: "per_100_litres",
        value: 30,
        unit: "mL",
        raw_text: SPRAYSEAL_RATE_TEXT,
      }],
    }],
    statements: [],
    sources: [],
    unresolved: [],
    document: {
      url: "https://elabels.apvma.gov.au/80160ELBL.pdf",
      sha256: "abc",
      byte_size: 1,
      retrieved_at: "2026-08-20T00:00:00Z",
      extraction: "pdf_text_layer",
      parser_version: LABEL_PARSER_VERSION,
    },
  };
  const withoutRates: LabelEvidence = {
    claims: [{ ...claimBase }],
    statements: [],
    sources: [],
    unresolved: [],
  };
  const storedUses = [{
    crop: "GRAPEVINE",
    target_raw: "EUTYPA DIEBACK",
    withholding_period_days: 0,
    rates: [{
      label: "",
      basis: "per_100_litres",
      value: 30,
      unit: "mL",
      raw_text: SPRAYSEAL_RATE_TEXT,
    }],
    provenance: { claim: "manufacturer_label", rates: "manufacturer_label" },
  }];

  // Fresh extraction present → rates compared (equal here → no drift).
  assertEquals(
    storedUsesSignature(storedUses, true),
    labelClaimsSignature(withRates),
  );
  // Extraction outage → stored document rates EXCLUDED → still no drift.
  assertEquals(
    storedUsesSignature(storedUses, false),
    labelClaimsSignature(withoutRates),
  );
  // A genuinely changed document rate IS drift when freshly extracted.
  const changed: LabelEvidence = {
    ...withRates,
    claims: [{
      ...claimBase,
      rates: [{
        label: "",
        basis: "per_100_litres",
        value: 60,
        unit: "mL",
        raw_text: "Mix 60 mL …",
      }],
    }],
  };
  assert(storedUsesSignature(storedUses, true) !== labelClaimsSignature(changed));
});
