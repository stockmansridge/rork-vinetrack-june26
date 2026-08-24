// Stage LD-3 — the label's own target wording is the registered use's target.
//
// THE PRODUCTION DEFECT (TestFlight, DITHANE RAINSHIELD NEO TEC FUNGICIDE,
// APVMA 59688 / 129475). Edit Chemical listed the grapevine uses as:
//
//     BLACK SPOT - COLLETOTRICHUM ACUTATUM
//     LEAF SPOT - ALTERNARIA CERCOSPORA
//
// Neither string appears anywhere on the approved label. They are the
// REGISTER's pest vocabulary (PubCRIS pest.csv `pestdesc`), which the Stage 4
// adapter copies verbatim into `LabelUseClaim.target_raw` and every layer
// downstream then displays as though the label had stated it. The label's
// grapevine block prints three disease entries and no scientific names:
//
//     Grapevines | Blackspot            |            | 30 days (H)
//                | Downy mildew         |            |
//                | Phomopsis Cane and   | 150 to 200 |
//                | Leaf spot            | g          |
//
// This file pins the whole shape, including the blank grapevine rate cell
// sitting immediately below Custard apples' printed 200 g — the adjacency
// that produced the original "200 g/100 L on Blackspot and Downy mildew"
// regression, and which must stay empty forever.

import { assert, assertEquals, assertFalse } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { applyLabelDocumentExtraction, parseDirectionsForUse } from "./label_extract.ts";
import { deriveLabelTargetWordings, registerTargetHead } from "./label_target_wording.ts";
import { mergeLabelEvidenceIntoUses } from "./label.ts";
import type {
  LabelDocumentDiscovery,
  LabelEvidence,
  LabelUseClaim,
  PdfTextItem,
} from "./contract.ts";

const DOC: LabelDocumentDiscovery = {
  url: "https://elabels.apvma.gov.au/59688ELBL.pdf",
  confirmation: "pubcris_view_label",
  retrieved_at: "2026-08-24T00:00:00.000Z",
  document: { sha256: "c".repeat(64), byte_size: 234_237 },
};

function T(page: number, x: number, y: number, width: number, str: string): PdfTextItem {
  return { page, x, y, width, str };
}

/**
 * The 59688 TREE AND VINE CROPS table, at the real page-12 column geometry:
 * CROP x=77.78, DISEASE x=141.14, RATE PER 100 L x≈206-216, WHP x≈266-278,
 * CRITICAL COMMENTS x=318.41.
 *
 * Custard apples prints 200 g. The grapevine Blackspot / Downy mildew row
 * that follows prints NOTHING in the rate column.
 */
const TABLE: PdfTextItem[] = [
  // The label's WITHHOLDING PERIODS section — crop-scoped, as 59688 prints it.
  T(1, 46.77, 800.0, 91.65, "Withholding Periods:"),
  T(1, 153.22, 790.0, 151.52, "WITHHOLDING PERIODS (WHP)"),
  T(1, 153.22, 780.0, 51.12, "Grapevines"),
  T(1, 204.38, 780.0, 2.28, ":"),
  T(1, 209.43, 780.0, 260.85, "DO NOT HARVEST FOR 30 DAYS AFTER APPLICATION"),
  T(1, 72.02, 730.0, 115.45, "DIRECTIONS FOR USE"),
  T(1, 72.02, 720.0, 115.45, "TREE AND VINE CROPS"),
  // Header, with the stacked "RATE PER" / "100 L" basis wording.
  T(1, 77.78, 700.0, 25.92, "CROP"),
  T(1, 141.14, 700.0, 39.48, "DISEASE"),
  T(1, 205.22, 700.0, 45.5, "RATE PER"),
  T(1, 274.13, 700.0, 21.0, "WHP"),
  T(1, 318.41, 700.0, 100.05, "CRITICAL COMMENTS"),
  T(1, 216.41, 690.0, 23.09, "100 L"),
  // Custard apples — prints 200 g in the rate column.
  T(1, 77.78, 670.0, 31.63, "Custard"),
  T(1, 141.14, 670.0, 52.59, "Pseudocercospora"),
  T(1, 216.65, 670.0, 22.6, "200 g"),
  T(1, 266.09, 670.0, 37.05, "1 day (H)"),
  T(1, 318.41, 670.0, 229.13, "Do not apply during flowering."),
  T(1, 77.78, 660.0, 26.55, "apples"),
  T(1, 141.14, 660.0, 40.01, "fruit spot"),
  // Grapevines — Blackspot / Downy mildew. THE RATE CELL IS EMPTY.
  T(1, 77.78, 630.0, 46.08, "Grapevines"),
  T(1, 141.14, 630.0, 39.06, "Blackspot"),
  T(1, 320.09, 630.0, 221.52, "Apply at budburst and then repeat 10 to 14 days later."),
  T(1, 141.14, 620.0, 27.53, "Downy"),
  T(1, 320.09, 620.0, 238.04, "If Downy mildew is expected, continue the spray programme."),
  T(1, 141.14, 610.0, 28.07, "mildew"),
  T(1, 268.73, 610.0, 31.59, "30 days"),
  T(1, 278.33, 600.0, 12.49, "(H)"),
  // Grapevines — the ONE cell "Phomopsis Cane and Leaf spot", 150 to 200 g.
  T(1, 141.14, 580.0, 44.54, "Phomopsis"),
  T(1, 206.66, 580.0, 42.63, "150 to 200"),
  T(1, 318.41, 580.0, 209.53, "Apply at budburst and then repeat 7 to 10 days later."),
  T(1, 141.14, 570.0, 39.07, "Cane and"),
  T(1, 225.41, 570.0, 5.0, "g"),
  T(1, 141.14, 560.0, 37.13, "Leaf spot"),
  T(1, 72.02, 520.0, 200.0, "NOT TO BE USED FOR ANY PURPOSE"),
];

/** What PubCRIS publishes for 59688 — the taxonomy TestFlight was showing. */
const REGISTER_CLAIMS: LabelUseClaim[] = [
  { crop: "GRAPEVINE", target_raw: "BLACK SPOT - COLLETOTRICHUM ACUTATUM", statements: [] },
  { crop: "GRAPEVINE", target_raw: "DOWNY MILDEW", statements: [] },
  { crop: "GRAPEVINE", target_raw: "PHOMOPSIS CANE", statements: [] },
  { crop: "GRAPEVINE", target_raw: "LEAF SPOT - ALTERNARIA CERCOSPORA", statements: [] },
  { crop: "CUSTARD APPLE", target_raw: "PSEUDOCERCOSPORA FRUIT SPOT", statements: [] },
];

function baseEvidence(claims: LabelUseClaim[]): LabelEvidence {
  const unresolved = new Set<string>();
  for (const c of claims) {
    unresolved.add(`rates:${c.crop}`);
    unresolved.add(`withholding_period:${c.crop}`);
  }
  return { claims, statements: [], sources: [], unresolved: Array.from(unresolved).sort() };
}

function applied(claims: LabelUseClaim[] = REGISTER_CLAIMS): LabelEvidence {
  return applyLabelDocumentExtraction(baseEvidence(claims), TABLE, DOC);
}

function claimFor(evidence: LabelEvidence, targetRaw: string): LabelUseClaim {
  const found = evidence.claims.find((c) => c.target_raw === targetRaw);
  assert(found, `no claim worded "${targetRaw}" (got: ${evidence.claims.map((c) => c.target_raw).join(" | ")})`);
  return found;
}

// ---------------------------------------------------------------------------
// §LD-3.1 — the label's wording wins, verbatim
// ---------------------------------------------------------------------------

Deno.test("§LD-3.1: the grapevine uses are worded exactly as the label prints them", () => {
  const evidence = applied();
  const grapevine = evidence.claims
    .filter((c) => c.crop === "GRAPEVINE")
    .map((c) => c.target_raw)
    .sort();

  assertEquals(grapevine, ["Blackspot", "Downy mildew", "Phomopsis Cane and Leaf spot"]);
});

Deno.test("§LD-3.1: no register taxonomy survives on an authoritative grapevine use", () => {
  const evidence = applied();
  for (const claim of evidence.claims.filter((c) => c.crop === "GRAPEVINE")) {
    assertFalse(
      /COLLETOTRICHUM|ALTERNARIA|CERCOSPORA/i.test(claim.target_raw),
      `taxonomy leaked into an authoritative target: ${claim.target_raw}`,
    );
    // The register's "<common> - <scientific>" shape itself must be gone.
    assertFalse(
      /\s-\s/.test(claim.target_raw),
      `register taxonomy wording survived: ${claim.target_raw}`,
    );
  }

  // A scientific name the LABEL itself prints is the label's own wording and
  // is kept verbatim — this rule is about not inventing one, not about
  // scrubbing the label.
  assertEquals(claimFor(evidence, "Pseudocercospora fruit spot").crop, "CUSTARD APPLE");
});

Deno.test("§LD-3.1: the register wording is kept, non-authoritatively, beside the label's", () => {
  const evidence = applied();

  assertEquals(
    claimFor(evidence, "Blackspot").register_target_raw,
    "BLACK SPOT - COLLETOTRICHUM ACUTATUM",
  );
  // The register split one printed row in two; the second wording is a
  // synonym of the printed use, not a use of its own.
  assertEquals(
    claimFor(evidence, "Phomopsis Cane and Leaf spot").target_synonyms,
    ["LEAF SPOT - ALTERNARIA CERCOSPORA"],
  );
});

// ---------------------------------------------------------------------------
// §LD-3.2 — one printed row, one registered use
// ---------------------------------------------------------------------------

Deno.test("§LD-3.2: 'Phomopsis Cane and Leaf spot' is ONE use, not two", () => {
  const evidence = applied();
  assertEquals(evidence.claims.filter((c) => c.crop === "GRAPEVINE").length, 3);
  assertFalse(
    evidence.claims.some((c) => c.target_raw === "LEAF SPOT - ALTERNARIA CERCOSPORA"),
    "the register's second pest code must not be served as a separate use",
  );
});

// ---------------------------------------------------------------------------
// §LD-3.3 — RATE CELL OWNERSHIP is untouched by any of this
// ---------------------------------------------------------------------------

Deno.test("§LD-3.3: the blank grapevine rate cell stays blank, below Custard apples' 200 g", () => {
  const evidence = applied();

  for (const target of ["Blackspot", "Downy mildew"]) {
    const claim = claimFor(evidence, target);
    assertEquals(claim.rates ?? [], [], `${target} must carry no canonical rate`);
    assertFalse(
      JSON.stringify(claim).includes("200 g"),
      `${target} must not inherit the preceding crop's printed 200 g`,
    );
  }
});

Deno.test("§LD-3.3: the printed 150–200 g/100 L belongs to the Phomopsis row alone", () => {
  const evidence = applied();
  const owners = evidence.claims.filter((c) => (c.rates ?? []).length > 0);

  assertEquals(owners.length, 2, "one grapevine rate cell and one custard apple rate cell");
  const phomopsis = claimFor(evidence, "Phomopsis Cane and Leaf spot");
  assertEquals(phomopsis.rates?.length, 1);
  assertEquals(phomopsis.rates?.[0].basis, "range_per_100_litres");
  assertEquals(phomopsis.rates?.[0].min_value, 150);
  assertEquals(phomopsis.rates?.[0].max_value, 200);
  assertEquals(phomopsis.rates?.[0].unit, "g");
});

Deno.test("§LD-3.3: the grapevine group keeps the label's own 30-day withholding period", () => {
  const evidence = applied();
  for (const claim of evidence.claims.filter((c) => c.crop === "GRAPEVINE")) {
    assertEquals(claim.withholding_period_days, 30, `${claim.target_raw} WHP`);
  }
});

// ---------------------------------------------------------------------------
// §LD-3.4 — CROP-SCOPED: no wording crosses a crop boundary
// ---------------------------------------------------------------------------

Deno.test("§LD-3.4: another crop's row cannot re-word a grapevine use", () => {
  const evidence = applied();

  // Custard apples takes its own printed wording and its own printed rate…
  const custard = claimFor(evidence, "Pseudocercospora fruit spot");
  assertEquals(custard.crop, "CUSTARD APPLE");
  assertEquals(custard.rates?.[0].value, 200);

  // …and nothing of it reaches the grapevine uses.
  for (const claim of evidence.claims.filter((c) => c.crop === "GRAPEVINE")) {
    assertFalse(/pseudocerco/i.test(claim.target_raw), claim.target_raw);
    assertFalse(/pseudocerco/i.test((claim.target_synonyms ?? []).join(" ")), claim.target_raw);
  }
});

Deno.test("§LD-3.4: a same-named disease on another crop does not absorb a grapevine claim", () => {
  // "Black spot" is printed for Citrus too. The grapevine claim must still be
  // worded by the GRAPEVINE row, and the citrus claim by the citrus row.
  const items: PdfTextItem[] = [
    T(1, 72.02, 730.0, 115.45, "DIRECTIONS FOR USE"),
    T(1, 77.78, 700.0, 25.92, "CROP"),
    T(1, 141.14, 700.0, 39.48, "DISEASE"),
    T(1, 205.22, 700.0, 45.5, "RATE PER"),
    T(1, 318.41, 700.0, 100.05, "CRITICAL COMMENTS"),
    T(1, 216.41, 690.0, 23.09, "100 L"),
    T(1, 77.78, 670.0, 23.56, "Citrus"),
    T(1, 141.14, 670.0, 41.57, "Black spot"),
    T(1, 216.65, 670.0, 22.6, "200 g"),
    T(1, 318.41, 670.0, 58.59, "On heavy soil."),
    T(1, 77.78, 650.0, 46.08, "Grapevines"),
    T(1, 141.14, 650.0, 39.06, "Blackspot"),
    T(1, 318.41, 650.0, 58.59, "Apply at budburst."),
    T(1, 72.02, 620.0, 200.0, "NOT TO BE USED FOR ANY PURPOSE"),
  ];
  const claims: LabelUseClaim[] = [
    { crop: "CITRUS", target_raw: "BLACK SPOT - GUIGNARDIA CITRICARPA", statements: [] },
    { crop: "GRAPEVINE", target_raw: "BLACK SPOT - COLLETOTRICHUM ACUTATUM", statements: [] },
  ];
  const evidence = applyLabelDocumentExtraction(baseEvidence(claims), items, DOC);

  assertEquals(evidence.claims.length, 2, "neither claim absorbed the other");
  const citrus = evidence.claims.find((c) => c.crop === "CITRUS");
  const grape = evidence.claims.find((c) => c.crop === "GRAPEVINE");
  assertEquals(citrus?.target_raw, "Black spot");
  assertEquals(grape?.target_raw, "Blackspot");
  // Only the citrus row printed a rate.
  assertEquals(citrus?.rates?.[0].value, 200);
  assertEquals(grape?.rates ?? [], []);
});

// ---------------------------------------------------------------------------
// §LD-3.5 — AI/taxonomy may never rewrite an authoritative use
// ---------------------------------------------------------------------------

Deno.test("§LD-3.5: an AI use worded with a scientific name cannot overwrite target_raw", () => {
  const evidence = applied();
  const aiUses = [
    {
      crop: "Grapevines",
      target_raw: "Black spot (Elsinoe ampelina)",
      rates: [{ label: "", basis: "per_100_litres", value: 200, unit: "g", raw_text: "200 g/100 L" }],
    },
  ];
  const merged = mergeLabelEvidenceIntoUses(aiUses, evidence);

  const blackspot = merged.uses.find((u: { target_raw: string }) => u.target_raw === "Blackspot");
  assert(blackspot, "the label's wording is what is served");
  assertFalse(
    merged.uses.some((u: { target_raw: string }) => /elsinoe|ampelina/i.test(u.target_raw)),
    "an AI wording must never become the registered use's target",
  );
  // And the document's silence still beats the model's 200 g.
  assertEquals(blackspot.rates, []);
  assertEquals(blackspot.provenance.rates, null);
});

// ---------------------------------------------------------------------------
// Unit level — the derivation itself
// ---------------------------------------------------------------------------

Deno.test("registerTargetHead strips the register's taxonomy suffix only", () => {
  assertEquals(registerTargetHead("BLACK SPOT - COLLETOTRICHUM ACUTATUM"), "BLACK SPOT");
  assertEquals(registerTargetHead("LEAF SPOT - ALTERNARIA CERCOSPORA"), "LEAF SPOT");
  assertEquals(registerTargetHead("DOWNY MILDEW"), "DOWNY MILDEW");
  // A hyphenated disease name is not a taxonomy separator.
  assertEquals(registerTargetHead("PHOMOPSIS CANE"), "PHOMOPSIS CANE");
});

Deno.test("the derivation splits a two-disease cell but never a conjoined one", () => {
  const rows = parseDirectionsForUse(TABLE).rows;
  const wordings = deriveLabelTargetWordings(rows, REGISTER_CLAIMS);

  assertEquals(wordings.wordingByClaim.get(0), "Blackspot");
  assertEquals(wordings.wordingByClaim.get(1), "Downy mildew");
  assertEquals(wordings.wordingByClaim.get(2), "Phomopsis Cane and Leaf spot");
  // The conjoined tail takes no wording of its own; it is absorbed by the
  // printed cell that names it.
  assertFalse(wordings.wordingByClaim.has(3));
  assertEquals(wordings.absorbedInto.get(3), 2);
});
