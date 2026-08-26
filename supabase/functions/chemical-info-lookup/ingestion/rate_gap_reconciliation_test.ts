// Gate D4A.3.1 — final verification metadata must describe the FINAL evidence.
//
// TWO METADATA DEFECTS on a lookup whose chemistry was already correct. The
// live response for VICOL WINTER OIL (APVMA 33182) served four calculable
// grapevine directions and, in the same body, said:
//
//   verification.unresolved_fields:  ["rates:GRAPEVINE", …]
//   field_provenance.label_rates:    "ai_interpretation"
//
// Both statements were false, and both came from the same cause: the metadata
// was computed against an EARLIER parser stage than the rows finally served.
// The gap was minted by the label-evidence pass (correctly — the register
// publishes no rate table) and then re-added after the state-aware re-read had
// already resolved it; the provenance arbiter reads a per-use `provenance` key
// that document-re-extracted rows do not carry, so deterministic label rates
// were attributed to a model that never saw them.
//
// Nothing here changes a rate, an identity, an option or a period.

// deno-lint-ignore-file no-explicit-any

import { assert, assertEquals, assertFalse } from "https://deno.land/std@0.224.0/assert/mod.ts";

import {
  buildFieldProvenance,
  mergeDiscoveryIntoStructured,
  reconcileFinalRateGaps,
} from "./ingest.ts";
import { applyPanelLayoutFallback } from "./label_panel_fallback.ts";
import { VICOL_33182_APVMA_LABEL_ITEMS } from "./seeds/label_fixture_33182_apvma.ts";
import { buildDefaultRateOptions } from "../default_rate_options.ts";
import type {
  LabelDocumentDiscovery,
  LabelEvidence,
  LabelUseClaim,
  ResolvedRegistration,
} from "./contract.ts";

// ---------------------------------------------------------------------------
// Row builders — the shapes the reconciliation actually meets in production
// ---------------------------------------------------------------------------

const per100 = (value: number) => ({
  label: "Tas",
  basis: "per_100_litres",
  value,
  unit: "L",
  raw_text: `${value} L / 100 L`,
});

const verbatimOnly = () => ({
  label: "",
  basis: "other",
  unit: "",
  raw_text: "See directions for use",
});

// ---------------------------------------------------------------------------
// 1. The rule itself — what clears, and what must never clear
// ---------------------------------------------------------------------------

Deno.test("D4A.3.1 — a crop-level gap clears when every final row for that crop is calculable", () => {
  const uses = [
    { crop: "Grapes", target: "Grapevine Scale", rates: [per100(2)] },
    { crop: "Grapes", target: "European Red Mites", rates: [per100(3)] },
  ];
  assertEquals(reconcileFinalRateGaps(["rates:GRAPEVINE"], uses), []);
});

Deno.test("D4A.3.1 — crop wording reconciles across register and label vocabularies", () => {
  // The gap is minted from the REGISTER's host wording; the final rows carry
  // the LABEL's. Same crop, different vocabularies — and the existing helper
  // already knows that, for any crop, which is why there is no grape rule here.
  for (const crop of ["Grapes", "GRAPEVINES", "Grapevine", "Winegrapes"]) {
    assertEquals(
      reconcileFinalRateGaps(["rates:GRAPEVINE"], [
        { crop, target: "Grapevine Scale", rates: [per100(2)] },
      ]),
      [],
      crop,
    );
  }
  // A different crop entirely never reconciles.
  assertEquals(
    reconcileFinalRateGaps(["rates:ALMOND"], [
      { crop: "Grapes", target: "Grapevine Scale", rates: [per100(2)] },
    ]),
    ["rates:ALMOND"],
  );
});

Deno.test("D4A.3.1 — entries that are not rate gaps are never touched", () => {
  const uses = [{ crop: "Grapes", target: "Scale", rates: [per100(2)] }];
  const untouched = [
    "withholding_period:GRAPEVINE",
    "re_entry_period_hours",
    "label_reference",
    "concentration:Paraffinic Oil",
    "registered_uses",
    "rates",
    "rates:",
  ];
  assertEquals(reconcileFinalRateGaps(untouched, uses), untouched);
});

Deno.test("D4A.3.1 — reconciliation is pure and order-preserving", () => {
  const uses = [{ crop: "Grapes", target: "Scale", rates: [per100(2)] }];
  const entries = ["a:b", "rates:GRAPEVINE", "withholding_period:GRAPEVINE", "z"];
  const before = JSON.stringify({ entries, uses });
  const kept = reconcileFinalRateGaps(entries, uses);
  assertEquals(kept, ["a:b", "withholding_period:GRAPEVINE", "z"]);
  assertEquals(JSON.stringify({ entries, uses }), before, "inputs are untouched");
});

// ---------------------------------------------------------------------------
// 2. Negative cases — a legitimate gap must survive (gate §6)
// ---------------------------------------------------------------------------

Deno.test("D4A.3.1 negative A — one rated row beside one UNRATED row keeps the crop gap", () => {
  // The crop is not resolved just because part of it is. Erasing the gap here
  // would tell the operator every grapevine use has a rate when one does not.
  const uses = [
    { crop: "Grapes", target: "Grapevine Scale", rates: [per100(2)] },
    { crop: "Grapes", target: "Powdery Mildew", rates: [] },
  ];
  assertEquals(reconcileFinalRateGaps(["rates:GRAPEVINE"], uses), ["rates:GRAPEVINE"]);
});

Deno.test("D4A.3.1 negative B — a qualified gap survives when only ANOTHER target has a rate", () => {
  const uses = [
    { crop: "Grapes", target: "Grapevine Scale", rates: [per100(2)] },
    { crop: "Grapes", target: "Powdery Mildew", rates: [] },
  ];
  assertEquals(
    reconcileFinalRateGaps(["rates:GRAPEVINE:POWDERY MILDEW"], uses),
    ["rates:GRAPEVINE:POWDERY MILDEW"],
  );
  // And when the qualified target has no final row at all, nothing is proven.
  assertEquals(
    reconcileFinalRateGaps(["rates:GRAPEVINE:BOTRYTIS"], uses),
    ["rates:GRAPEVINE:BOTRYTIS"],
  );
});

Deno.test("D4A.3.1 negative C — only the qualified gap whose own target is rated may clear", () => {
  const uses = [
    { crop: "Grapes", target: "Grapevine Scale", rates: [per100(2)] },
    { crop: "Grapes", target: "Powdery Mildew", rates: [] },
  ];
  const kept = reconcileFinalRateGaps([
    "rates:GRAPEVINE",
    "rates:GRAPEVINE:GRAPEVINE SCALE",
    "rates:GRAPEVINE:POWDERY MILDEW",
  ], uses);
  assertEquals(kept, ["rates:GRAPEVINE", "rates:GRAPEVINE:POWDERY MILDEW"]);
});

Deno.test("D4A.3.1 negative D — a verbatim-only basis:\"other\" rate does NOT resolve a gap", () => {
  const uses = [{ crop: "Grapes", target: "Grapevine Scale", rates: [verbatimOnly()] }];
  assertEquals(reconcileFinalRateGaps(["rates:GRAPEVINE"], uses), ["rates:GRAPEVINE"]);
  // Nor does a basis with no number behind it.
  assertEquals(
    reconcileFinalRateGaps(["rates:GRAPEVINE"], [{
      crop: "Grapes",
      target: "Grapevine Scale",
      rates: [{ label: "", basis: "per_100_litres", unit: "L", raw_text: "as required" }],
    }]),
    ["rates:GRAPEVINE"],
  );
});

Deno.test("D4A.3.1 negative E — an empty rates array does NOT resolve a gap", () => {
  assertEquals(
    reconcileFinalRateGaps(["rates:GRAPEVINE"], [
      { crop: "Grapes", target: "Grapevine Scale", rates: [] },
    ]),
    ["rates:GRAPEVINE"],
  );
  assertEquals(
    reconcileFinalRateGaps(["rates:GRAPEVINE"], [
      { crop: "Grapes", target: "Grapevine Scale" },
    ]),
    ["rates:GRAPEVINE"],
  );
});

Deno.test("D4A.3.1 negative F — no matching final crop leaves the gap in place", () => {
  assertEquals(
    reconcileFinalRateGaps(["rates:GRAPEVINE"], [
      { crop: "Almonds", target: "Bryobia Mites", rates: [per100(2)] },
    ]),
    ["rates:GRAPEVINE"],
  );
  // An empty final projection proves nothing at all.
  assertEquals(reconcileFinalRateGaps(["rates:GRAPEVINE"], []), ["rates:GRAPEVINE"]);
});

// ---------------------------------------------------------------------------
// 3. Provenance — authoritative only when the rates really are
// ---------------------------------------------------------------------------

function structuredWithRates(uses: any[]): any {
  return {
    product_name: "VICOL WINTER OIL INSECTICIDE",
    registration: { registration_number: "33182" },
    active_ingredients: [],
    registered_uses: uses,
  };
}

Deno.test("D4A.3.1 — panel-fallback rates read manufacturer_label, not ai_interpretation", () => {
  // Rows re-extracted from the approved document carry NO per-use provenance
  // key, which is exactly why the old arbiter fell through to the AI tier.
  const uses = [{ crop: "Grapes", target: "Grapevine Scale", rates: [per100(2)] }];
  const structured = structuredWithRates(uses);

  assertEquals(
    buildFieldProvenance(structured, null, true, false).label_rates,
    "ai_interpretation",
    "the defect, reproduced: no provenance key and no flag",
  );
  assertEquals(
    buildFieldProvenance(structured, null, true, true).label_rates,
    "manufacturer_label",
  );
});

Deno.test("D4A.3.1 negative G — an AI-only final rate is never marked authoritative", () => {
  const structured = structuredWithRates([{
    crop: "Grapevines",
    target_raw: "Downy Mildew",
    rates: [per100(2)],
    provenance: { claim: "manufacturer_label", rates: "ai_interpretation" },
  }]);
  // The flag is false because no fallback supplied these rows.
  assertEquals(
    buildFieldProvenance(structured, null, true).label_rates,
    "ai_interpretation",
  );
  assertEquals(
    buildFieldProvenance(structured, null, true, false).label_rates,
    "ai_interpretation",
  );
});

Deno.test("D4A.3.1 negative H — an ordinary document-bound parse keeps its existing provenance", () => {
  const structured = structuredWithRates([{
    crop: "Grapevines",
    target_raw: "Downy Mildew",
    rates: [per100(2)],
    provenance: { claim: "manufacturer_label", rates: "manufacturer_label" },
  }]);
  // Unchanged with the default argument — the ordinary path never learns a
  // new behaviour from this gate.
  assertEquals(
    buildFieldProvenance(structured, null, true).label_rates,
    "manufacturer_label",
  );
});

Deno.test("D4A.3.1 — no rates at all still reads unresolved, flag or no flag", () => {
  const structured = structuredWithRates([{ crop: "Grapes", target: "Scale", rates: [] }]);
  assertEquals(buildFieldProvenance(structured, null, true, true).label_rates, "unresolved");
  assertEquals(buildFieldProvenance(structured, null, true, false).label_rates, "unresolved");
});

// ---------------------------------------------------------------------------
// 4. VICOL 33182 acceptance — through the real merge, on the real document
// ---------------------------------------------------------------------------

const DOC: LabelDocumentDiscovery = {
  url: "https://elabels.apvma.gov.au/33182ELBL.pdf",
  confirmation: "pubcris_view_label",
  retrieved_at: "2026-08-25T00:00:00.000Z",
  document: {
    sha256: "b55905a2612b0c938b44a656c6fa419715eb80468aabc842e667a4fa62c17111",
    byte_size: 258_920,
  },
};

const PRODUCT = { country: "AU", scheme: "apvma", registration_number: "33182" } as const;

/** The grapevine claims the register publishes, with no rate table. */
const CLAIMS: LabelUseClaim[] = [
  { crop: "GRAPEVINE", target_raw: "GRAPEVINE SCALE", statements: [] },
  { crop: "GRAPEVINE", target_raw: "EUROPEAN RED MITE", statements: [] },
  { crop: "GRAPEVINE", target_raw: "TWO SPOTTED MITE", statements: [] },
  { crop: "GRAPEVINE", target_raw: "GRAPELEAF BLISTER MITE", statements: [] },
];

function evidence(): LabelEvidence {
  return {
    claims: CLAIMS,
    statements: [],
    sources: [{
      kind: "manufacturer_label",
      name: "APVMA PubCRIS label claims",
      reference: "https://portal.apvma.gov.au/pubcris?p=33182",
      retrieved_at: DOC.retrieved_at,
    }],
    // Exactly what the live response carried, including the WHP gap this gate
    // must NOT touch.
    unresolved: ["rates:GRAPEVINE", "withholding_period:GRAPEVINE"],
  };
}

function vicolPanelUses(): Record<string, unknown>[] {
  const fallback = applyPanelLayoutFallback({
    items: VICOL_33182_APVMA_LABEL_ITEMS,
    regulatorUses: [],
    product: PRODUCT,
  });
  assertEquals(fallback.outcome, "applied");
  return fallback.uses;
}

function registration(): ResolvedRegistration {
  return {
    country_code: "AU",
    scheme: "apvma",
    registration_number: "33182",
    registration_identity_key: "AU:apvma:33182",
    registered_product_name: "VICOL WINTER OIL INSECTICIDE",
    registrant: "VICHEM PTY LTD",
    product_category: "insecticide",
    form_type: "liquid",
    label_version: null,
    register_status: "R",
    active_ingredients: [],
    unresolved_fields: ["rates:GRAPEVINE", "withholding_period:GRAPEVINE"],
    sources: [],
    match_mode: "exact_name",
    label_evidence: evidence(),
    label_document: DOC,
    label_panel_uses: vicolPanelUses(),
  } as ResolvedRegistration;
}

/** A structured lookup with no AI rate to muddy the provenance question. */
function aiStructured(): any {
  return {
    product_name: "Vicol Winter Oil",
    product_category: "insecticide",
    form_type: "liquid",
    registration: { country_code: "AU" },
    active_ingredients: [],
    registered_uses: [],
    label_rate_bases: [],
    verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
    schema_version: 1,
  };
}

function vicolMerged(): any {
  return mergeDiscoveryIntoStructured(aiStructured(), registration());
}

function grapevineRows(merged: any): any[] {
  return merged.registered_uses.filter((u: any) => /grape/i.test(String(u?.crop ?? "")));
}

Deno.test("D4A.3.1 VICOL — the served projection is unchanged: 6 rows, 4 directions, 4 rates", () => {
  const merged = vicolMerged();
  const rows = grapevineRows(merged);
  assertEquals(rows.length, 6);
  assertEquals(new Set(rows.map((r) => r.direction_id)).size, 4);
  assertEquals(
    new Set(rows.flatMap((r) => (r.rates ?? []).map((x: any) => x.rate_id))).size,
    4,
  );
  for (const row of rows) {
    assert(String(row.direction_id).startsWith("direction_v1_"));
    for (const rate of row.rates) assert(String(rate.rate_id).startsWith("rate_v1_"));
  }
});

Deno.test("D4A.3.1 VICOL — the stale rates:GRAPEVINE gap is gone from final verification", () => {
  const fields: string[] = vicolMerged().verification.unresolved_fields;
  for (const entry of fields) {
    const norm = entry.trim().toLowerCase();
    assertFalse(norm === "rates:grapevine", `bare gap survived: ${entry}`);
    assertFalse(norm.startsWith("rates:grapevine:"), `qualified gap survived: ${entry}`);
  }
});

Deno.test("D4A.3.1 VICOL — final rate provenance is manufacturer_label", () => {
  const merged = vicolMerged();
  assertEquals(merged.field_provenance.label_rates, "manufacturer_label");
  // The trust model is untouched: these are approved-LABEL facts, which this
  // contract classifies as manufacturer_label, never official_register.
  assertEquals(merged.field_provenance.registered_uses, "manufacturer_label");
});

Deno.test("D4A.3.1 VICOL — the withholding gap is NOT bundled into this gate", () => {
  const merged = vicolMerged();
  assert(
    merged.verification.unresolved_fields.includes("withholding_period:GRAPEVINE"),
    "the WHP gap is a separate evidence audit and must survive untouched",
  );
  for (const row of grapevineRows(merged)) {
    assertEquals(row.withholding_period_days, null, "no period is invented here");
  }
});

Deno.test("D4A.3.1 VICOL — the two default options are byte-identical through the merge", () => {
  const beforeMerge = buildDefaultRateOptions(vicolPanelUses());
  const afterMerge = buildDefaultRateOptions(vicolMerged().registered_uses);

  assertEquals(afterMerge.violations, []);
  assertEquals(
    JSON.stringify(afterMerge.options),
    JSON.stringify(beforeMerge.options),
    "metadata reconciliation must not move a single option byte",
  );

  // And the shape itself, pinned independently of the comparison above.
  assertEquals(afterMerge.options.per_hectare, []);
  assertEquals(afterMerge.options.per_100_litres.length, 2);
  for (const option of afterMerge.options.per_100_litres) {
    assertEquals(option.basis, "per_100_litres");
    assertEquals(option.unit, "L");
    assertEquals(option.rate_ids.length, 2);
    assert(String(option.option_key).startsWith("default_option_v1_"));
  }
  assertEquals(
    afterMerge.options.per_100_litres.map((o) => o.value).sort(),
    [2, 3],
  );
});

Deno.test("D4A.3.1 VICOL — an unrated crop on the SAME label keeps its own gap", () => {
  // Proof the reconciliation is per crop, not a document-wide amnesty: the
  // register also claims a crop the re-read binds no calculable rate to.
  const reg = registration();
  reg.unresolved_fields = [...reg.unresolved_fields, "rates:PEAR"];
  (reg.label_evidence as LabelEvidence).unresolved = [
    ...(reg.label_evidence as LabelEvidence).unresolved,
    "rates:PEAR",
  ];
  const merged = mergeDiscoveryIntoStructured(aiStructured(), reg);

  const pearRated = merged.registered_uses
    .filter((u: any) => /pear/i.test(String(u?.crop ?? "")))
    .every((u: any) =>
      (u.rates ?? []).some((r: any) =>
        r.basis !== "other" && typeof r.value === "number"
      )
    );
  const pearRows = merged.registered_uses.filter((u: any) =>
    /pear/i.test(String(u?.crop ?? ""))
  );
  // Whichever the document says, verification must agree with it.
  assertEquals(
    merged.verification.unresolved_fields.includes("rates:PEAR"),
    !(pearRows.length > 0 && pearRated),
    "the PEAR gap must match what the final PEAR rows actually state",
  );
});
