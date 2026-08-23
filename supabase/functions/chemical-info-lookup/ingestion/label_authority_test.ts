// Document authority for rates, and what a "conflict" is allowed to mean.
//
// TWO PRODUCTION DEFECTS, both on a lookup that was otherwise correct.
//
//   1. An approved label document had been fetched and parsed, and the
//      canonical registered use for GRAPEVINE / DOWNY MILDEW still carried
//      `200 g/100 L` with `provenance.rates = ai_interpretation`, quoting the
//      model's prose. The document bound no rate to that use. The old merge
//      rule let an AI rate ride along wherever the document was silent —
//      reasonable before document extraction existed, wrong once it does.
//      Absence of a rate in a successfully parsed authoritative source is a
//      FACT ABOUT THE LABEL, not a vacancy for the model to fill.
//
//   2. The one printed rate cell in the grapevine block bound to TWO register
//      claims. "Leaf spot" — merely the third wrapped line of the cell
//      "Phomopsis Cane and Leaf spot" — prefix-matched the unrelated register
//      target "LEAF SPOT - ALTERNARIA CERCOSPORA", minting a second
//      authoritative rate the label never granted.
//
// And one honesty problem: a settled AI reading was being reported as a
// verification CONFLICT, so a fully resolved product asked the grower to
// adjudicate between the approved label and a language model.

import { assert, assertEquals, assertFalse } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { applyLabelDocumentExtraction, LABEL_PARSER_VERSION } from "./label_extract.ts";
import { mergeDiscoveryIntoStructured } from "./ingest.ts";
import { mergeLabelEvidenceIntoUses } from "./label.ts";
import type {
  LabelDocumentDiscovery,
  LabelEvidence,
  LabelUseClaim,
  ResolvedRegistration,
} from "./contract.ts";
import { DITHANE_59688_ITEMS } from "./label_fixture_59688.ts";

// ---------------------------------------------------------------------------
// Harness — the real 59688 document over the real register claim set
// ---------------------------------------------------------------------------

const DOC: LabelDocumentDiscovery = {
  url: "https://elabels.apvma.gov.au/59688ELBL.pdf",
  confirmation: "pubcris_view_label",
  retrieved_at: "2026-08-23T00:00:00.000Z",
  document: { sha256: "b".repeat(64), byte_size: 234_237 },
};

/** The grapevine claims PubCRIS publishes for 59688, verbatim. */
const GRAPE_CLAIMS: LabelUseClaim[] = [
  { crop: "GRAPEVINE", target_raw: "BLACKSPOT", statements: [] },
  { crop: "GRAPEVINE", target_raw: "DOWNY MILDEW", statements: [] },
  { crop: "GRAPEVINE", target_raw: "PHOMOPSIS CANE", statements: [] },
  { crop: "GRAPEVINE", target_raw: "LEAF SPOT - ALTERNARIA CERCOSPORA", statements: [] },
];

function baseEvidence(claims: LabelUseClaim[]): LabelEvidence {
  const unresolved = new Set<string>();
  for (const c of claims) {
    unresolved.add(`rates:${c.crop}`);
    unresolved.add(`withholding_period:${c.crop}`);
  }
  return { claims, statements: [], sources: [], unresolved: Array.from(unresolved).sort() };
}

/** Evidence AFTER the real 59688 document was parsed. */
function parsedEvidence(): LabelEvidence {
  return applyLabelDocumentExtraction(baseEvidence(GRAPE_CLAIMS), DITHANE_59688_ITEMS, DOC);
}

function registration(evidence: LabelEvidence | null): ResolvedRegistration {
  return {
    country_code: "AU",
    scheme: "apvma",
    registration_number: "59688",
    registration_identity_key: "AU:apvma:59688",
    registered_product_name: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
    registrant: "UPL AUSTRALIA PTY LTD",
    product_category: "fungicide",
    form_type: "solid",
    label_version: null,
    register_status: "R",
    active_ingredients: [{
      name: "Mancozeb",
      concentration: 750,
      concentration_unit: "g/kg",
      activity_group: { code: "M3", scheme: "frac", source: "authoritative_classification" },
      identity_source: "official_register",
    // deno-lint-ignore no-explicit-any
    } as any],
    unresolved_fields: [],
    sources: [{
      kind: "official_register",
      name: "APVMA PubCRIS",
      reference: "https://portal.apvma.gov.au/pubcris?p=59688",
      retrieved_at: DOC.retrieved_at,
    }],
    match_mode: "exact_name",
    label_evidence: evidence,
    label_document: DOC,
  };
}

/** Terra's reading: the 200 g/100 L it recalled for blackspot and downy. */
// deno-lint-ignore no-explicit-any
function terraStructured(): any {
  return {
    product_name: "Dithane Rainshield Neo Tec Fungicide",
    product_category: "fungicide",
    form_type: "solid",
    registration: { country_code: "AU" },
    active_ingredients: [{ name: "Mancozeb", concentration: 750, concentration_unit: "g/kg" }],
    activity_groups: ["M3"],
    activity_group_scheme: "frac",
    registered_uses: [
      {
        crop: "Grapevines",
        target_raw: "Downy mildew",
        rates: [{
          label: "",
          basis: "per_100_litres",
          value: 200,
          unit: "g",
          raw_text: "Grapevines — Blackspot; Downy mildew — 200 g per 100 L.",
        }],
      },
      {
        crop: "Grapevines",
        target_raw: "Blackspot",
        rates: [{
          label: "",
          basis: "per_100_litres",
          value: 200,
          unit: "g",
          raw_text: "Grapevines — Blackspot; Downy mildew — 200 g per 100 L.",
        }],
      },
    ],
    label_rate_bases: [],
    verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
    schema_version: 1,
  };
}

// deno-lint-ignore no-explicit-any
function useFor(merged: any, targetRaw: string): any {
  // deno-lint-ignore no-explicit-any
  const found = merged.registered_uses.find((u: any) => u.target_raw === targetRaw);
  assert(found, `no served use for ${targetRaw}`);
  return found;
}

// ---------------------------------------------------------------------------
// §12.5 / §12.6 — one printed rate context, one owner
// ---------------------------------------------------------------------------

Deno.test("§12.5: a wrapped target fragment cannot mint a second authoritative rate claim", () => {
  const evidence = parsedEvidence();
  const phomopsis = evidence.claims.find((c) => c.target_raw === "PHOMOPSIS CANE");
  const leafSpot = evidence.claims.find((c) =>
    c.target_raw === "LEAF SPOT - ALTERNARIA CERCOSPORA"
  );

  // The label prints "Phomopsis Cane and Leaf spot" as ONE target cell. It
  // corresponds to the register's "PHOMOPSIS CANE"…
  assertEquals(phomopsis?.rates?.length, 1);
  assertEquals(phomopsis?.rates?.[0].min_value, 150);
  assertEquals(phomopsis?.rates?.[0].max_value, 200);

  // …and NOT to a different register target that merely shares the tail
  // words of that cell.
  assertEquals(leafSpot?.rates ?? [], []);
});

Deno.test("§12.5: prefix correspondence still works for a genuinely complete target wording", () => {
  // BOTRYTIS ↔ BOTRYTIS CINEREA must survive — the guard is about fragments,
  // not about tightening target equivalence.
  const claims: LabelUseClaim[] = [
    { crop: "Grapevines", target_raw: "BOTRYTIS CINEREA", statements: [] },
  ];
  const items = [
    { page: 1, x: 90, y: 720, width: 120, str: "DIRECTIONS FOR USE" },
    { page: 1, x: 90, y: 700, width: 30, str: "CROP" },
    { page: 1, x: 160, y: 700, width: 45, str: "DISEASE" },
    { page: 1, x: 260, y: 700, width: 25, str: "RATE" },
    { page: 1, x: 360, y: 700, width: 100, str: "CRITICAL COMMENTS" },
    { page: 1, x: 90, y: 680, width: 50, str: "Grapevines" },
    { page: 1, x: 160, y: 680, width: 40, str: "Botrytis" },
    { page: 1, x: 260, y: 680, width: 60, str: "80 mL/100 L" },
    { page: 1, x: 360, y: 680, width: 90, str: "Apply at capfall." },
  ];
  const applied = applyLabelDocumentExtraction(baseEvidence(claims), items, DOC);
  assertEquals(applied.claims[0].rates?.length, 1);
  assertEquals(applied.claims[0].rates?.[0].value, 80);
  assertEquals(applied.claims[0].rates?.[0].basis, "per_100_litres");
});

Deno.test("§12.6: real 59688 — exactly one grapevine use owns 150–200 g/100 L", () => {
  const merged = mergeDiscoveryIntoStructured(terraStructured(), registration(parsedEvidence()));

  // deno-lint-ignore no-explicit-any
  const owners = merged.registered_uses.filter((u: any) => (u.rates ?? []).length > 0);
  assertEquals(owners.length, 1, "one printed rate cell, one owning use");
  assertEquals(owners[0].target_raw, "PHOMOPSIS CANE");
  assertEquals(owners[0].rates[0].basis, "range_per_100_litres");
  assertEquals(owners[0].rates[0].min_value, 150);
  assertEquals(owners[0].rates[0].max_value, 200);
  assertEquals(owners[0].rates[0].unit, "g");
  assertEquals(owners[0].provenance.rates, "manufacturer_label");
});

// ---------------------------------------------------------------------------
// §12.1 / §12.2 / §12.3 — the document decides, and silence is an answer
// ---------------------------------------------------------------------------

Deno.test("§12.1 + §12.2: a parsed document that bound no rate leaves canonical rates EMPTY, and the AI rate cannot fill it", () => {
  const merged = mergeDiscoveryIntoStructured(terraStructured(), registration(parsedEvidence()));

  for (const target of ["DOWNY MILDEW", "BLACKSPOT"]) {
    const use = useFor(merged, target);
    assertEquals(use.rates, [], `${target} must carry no canonical rate`);
    assertEquals(use.provenance.rates, null, `${target} claims no rate provenance`);
    // The exact production regression: the model's 200 g and its prose.
    assertFalse(
      JSON.stringify(use).includes("200 g per 100 L"),
      `${target} must not quote the model's prose as a registered rate`,
    );
  }
  // And the claim itself is still authoritative — only the rate is absent.
  assertEquals(useFor(merged, "DOWNY MILDEW").provenance.claim, "manufacturer_label");
});

Deno.test("§12.3: the AI reading survives separately, as ai_suggested_uses, still ai_interpretation", () => {
  const merged = mergeDiscoveryIntoStructured(terraStructured(), registration(parsedEvidence()));

  assert(Array.isArray(merged.ai_suggested_uses), "the research reading is not thrown away");
  assertEquals(merged.ai_suggested_uses.length, 2);
  // deno-lint-ignore no-explicit-any
  const downy = merged.ai_suggested_uses.find((u: any) => u.target_raw === "Downy mildew");
  assertEquals(downy.rates[0].value, 200);

  // It lives OUTSIDE the authoritative field, and it is recorded as settled.
  // deno-lint-ignore no-explicit-any
  const notes = merged.verification.superseded_ai_interpretations ?? [];
  assert(
    // deno-lint-ignore no-explicit-any
    notes.some((n: any) =>
      n.field === "label_rates" && n.extracted_source === "ai_interpretation"
    ),
    "the superseded reading is attributed to AI, never to the label",
  );
});

Deno.test("§12.4: where the document DID bind a rate, it wins over a differing AI rate", () => {
  const ai = terraStructured();
  ai.registered_uses.push({
    crop: "Grapevines",
    target_raw: "Phomopsis Cane",
    rates: [{ label: "", basis: "per_100_litres", value: 999, unit: "g", raw_text: "999 g/100 L" }],
  });
  const merged = mergeDiscoveryIntoStructured(ai, registration(parsedEvidence()));

  const phomopsis = useFor(merged, "PHOMOPSIS CANE");
  assertEquals(phomopsis.rates[0].min_value, 150, "the document rate is served");
  assertEquals(phomopsis.rates[0].max_value, 200);
  assertEquals(phomopsis.provenance.rates, "manufacturer_label");
  assertFalse(JSON.stringify(phomopsis.rates).includes("999"));
});

Deno.test("Rule A: with NO document parsed, a clearly-attributed AI rate may still ride along", () => {
  // The pre-LD-2 behaviour is deliberately preserved: when nobody has read an
  // approved label, the model's reading is the only reading there is, and it
  // stays honestly labelled ai_interpretation.
  const evidence = baseEvidence([
    { crop: "GRAPEVINE", target_raw: "DOWNY MILDEW", statements: [] },
  ]);
  assertEquals(evidence.document, undefined, "no document extraction happened");

  const merge = mergeLabelEvidenceIntoUses(terraStructured().registered_uses, evidence);
  assertEquals(merge.uses[0].rates[0].value, 200);
  assertEquals(merge.uses[0].provenance.rates, "ai_interpretation");
});

// ---------------------------------------------------------------------------
// §12.11 — a settled disagreement is not an operator conflict
// ---------------------------------------------------------------------------

Deno.test("§12.11: a superseded AI reading does not make a correctly resolved product look conflicted", () => {
  const merged = mergeDiscoveryIntoStructured(terraStructured(), registration(parsedEvidence()));

  assertEquals(merged.verification.status, "partially_verified");
  assertEquals(merged.verification.conflicts, []);
  // Nothing was swept away — it is on the record, in the audit envelope.
  assert((merged.verification.superseded_ai_interpretations ?? []).length > 0);
});

Deno.test("a REAL disagreement still blocks: register chemistry vs an AI active", () => {
  const ai = terraStructured();
  ai.active_ingredients = [{ name: "Copper hydroxide", concentration: 500, concentration_unit: "g/kg" }];
  const merged = mergeDiscoveryIntoStructured(ai, registration(parsedEvidence()));

  assertEquals(merged.verification.status, "conflict", "chemistry disagreements still surface");
  assert(
    // deno-lint-ignore no-explicit-any
    merged.verification.conflicts.some((c: any) => c.field === "active_ingredients"),
  );
  // The register's chemistry is what is served.
  assertEquals(merged.active_ingredients[0].name, "Mancozeb");
});

// ---------------------------------------------------------------------------
// §12.9 / §12.10 — stale research narrative
// ---------------------------------------------------------------------------

Deno.test("§12.9 + §12.10: research prose contradicted by the final answer is removed from unresolved_fields", () => {
  const ai = terraStructured();
  ai.verification.unresolved_fields = [
    "A current regulator-hosted PubCRIS label PDF for this product could not be retrieved from the APVMA site.",
    "The current legal APVMA registrant of record was not independently confirmed.",
    "rates:GRAPEVINE",
  ];
  const merged = mergeDiscoveryIntoStructured(ai, registration(parsedEvidence()));

  // The same response carries the eLabel and the registrant, so the prose
  // saying otherwise cannot survive as verification state.
  assertEquals(merged.registration.label_reference, "https://elabels.apvma.gov.au/59688ELBL.pdf");
  assertEquals(merged.registration.registrant, "UPL AUSTRALIA PTY LTD");
  for (const entry of merged.verification.unresolved_fields) {
    assertFalse(/could not be retrieved/i.test(entry), `stale label narrative survived: ${entry}`);
    assertFalse(/not independently confirmed/i.test(entry), `stale registrant narrative survived: ${entry}`);
  }

  // What remains is machine-stable, and the prose is kept for debugging.
  for (const entry of merged.verification.unresolved_fields) {
    assertFalse(/\s/.test(entry), `unresolved_fields must be machine keys, got: ${entry}`);
  }
  assertEquals(merged.verification.research_notes.length, 2);
});

// ---------------------------------------------------------------------------
// §12.7 / §12.12 / §12.13 — the verified-good items must not move
// ---------------------------------------------------------------------------

Deno.test("§12.7 + §12.13: identity, chemistry, label, WHP and parser version all stand unchanged", () => {
  const merged = mergeDiscoveryIntoStructured(terraStructured(), registration(parsedEvidence()));

  assertEquals(merged.registration.registration_number, "59688");
  assertEquals(merged.registration.scheme, "apvma");
  assertEquals(merged.product_name, "DITHANE RAINSHIELD NEO TEC FUNGICIDE");
  assertEquals(merged.registration.registrant, "UPL AUSTRALIA PTY LTD");
  assertEquals(merged.active_ingredients[0].name, "Mancozeb");
  assertEquals(merged.active_ingredients[0].concentration, 750);
  assertEquals(merged.activity_groups, ["M3"]);
  assertEquals(merged.registration.label_reference, "https://elabels.apvma.gov.au/59688ELBL.pdf");
  assertEquals(merged.label_extraction.parser_version, LABEL_PARSER_VERSION);
  assertEquals(LABEL_PARSER_VERSION, 2);

  // Every grapevine use keeps the label's own 30-day withholding period,
  // rate or no rate.
  // deno-lint-ignore no-explicit-any
  for (const use of merged.registered_uses as any[]) {
    assertEquals(use.withholding_period_days, 30, `${use.target_raw} WHP`);
    assertEquals(use.provenance.withholding_period, "manufacturer_label");
  }
});
