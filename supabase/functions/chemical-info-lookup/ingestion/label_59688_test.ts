// APVMA 59688 (Dithane Rainshield Neo Tec Fungicide) — the production defect,
// pinned against the REAL captured PDF text-layer geometry.
//
// WHAT WENT WRONG IN PRODUCTION
//   Identity resolved perfectly and the approved label was found and parsed,
//   and then the grapevine rows came back as:
//
//     PHOMOPSIS CANE  rate: basis "other", raw_text "30 days (H) 150 to 200 g"
//     DOWNY MILDEW    rate: basis "other", raw_text "30 days (H) 150 to 200 g"
//     withholding_period_days: 0
//     restrictions:   "Bananas: NOT REQUIRED WHEN USED AS DIRECTED"
//
//   Three independent faults, all visible in that one row:
//
//     1. The TREE AND VINE table stacks its rate heading across two printed
//        lines ("RATE PER" / "100 L"). The single-line matcher saw only
//        "RATE PER", matched no rate pattern, refused the header — and the
//        table silently inherited the PREVIOUS page's six-column map.
//     2. Under that stale map, two different columns both meant "rate", so a
//        withholding period and a rate were concatenated into one cell.
//     3. The label prints its withholding periods in Title Case
//        ("Bananas:", "Grapevines:"), which the crop-prefix matcher required
//        to be upper case. Every one of them therefore read as PRODUCT-WIDE,
//        and the first that parsed — a banana's "NOT REQUIRED" — became the
//        withholding period of every crop on the label, grapevines included.
//
// Every fixture below is verbatim captured geometry (label_fixture_59688.ts),
// so these tests fail if the live document stops parsing, not merely if a
// hand-written mock does.

import { assert, assertEquals, assertFalse } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyLabelDocumentExtraction,
  bindDfuRows,
  type DfuRow,
  parseDirectionsForUse,
  parseRateCell,
  rateCellCrossesColumns,
} from "./label_extract.ts";
import { parseLabelStatements, whpDaysFromStatement } from "./label.ts";
import { classifyUrl } from "../research/classify.ts";
import type {
  LabelDocumentDiscovery,
  LabelEvidence,
  LabelUseClaim,
} from "./contract.ts";
import { DITHANE_59688_ITEMS } from "./label_fixture_59688.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const DOC: LabelDocumentDiscovery = {
  url: "https://elabels.apvma.gov.au/59688ELBL.pdf",
  confirmation: "pubcris_view_label",
  retrieved_at: "2026-08-23T00:00:00.000Z",
  document: { sha256: "a".repeat(64), byte_size: 234_237 },
};

function rows(): DfuRow[] {
  return parseDirectionsForUse(DITHANE_59688_ITEMS).rows;
}

function rowFor(crop: RegExp, target: RegExp): DfuRow {
  const found = rows().find(
    (r) => crop.test(r.crop_text) && r.target_lines.some((t) => target.test(t)),
  );
  assert(found, `no DFU row for ${crop} / ${target}`);
  return found;
}

function claim(crop: string, targetRaw: string): LabelUseClaim {
  return { crop, target_raw: targetRaw, statements: [] };
}

/** Stage 4 evidence as the register produces it: claims, no rates, no WHP. */
function evidence(claims: LabelUseClaim[]): LabelEvidence {
  const unresolved = new Set<string>();
  for (const c of claims) {
    unresolved.add(`rates:${c.crop}`);
    unresolved.add(`withholding_period:${c.crop}`);
  }
  return {
    claims,
    statements: [],
    sources: [],
    unresolved: Array.from(unresolved).sort(),
  };
}

const GRAPE_CLAIMS: LabelUseClaim[] = [
  claim("Grapevines", "Blackspot"),
  claim("Grapevines", "Downy mildew"),
  claim("Grapevines", "Phomopsis Cane and Leaf spot"),
];

// ---------------------------------------------------------------------------
// §15.1 — the stacked heading becomes two distinct columns
// ---------------------------------------------------------------------------

Deno.test("59688 §15.1: the stacked 'RATE PER' / '100 L' heading is read as ONE rate column, and WHP stays a separate column", () => {
  const grape = rowFor(/Grapevines/i, /Phomopsis/i);

  // The rate column identified itself, so bare quantities in it have a basis.
  assertEquals(grape.rate_basis, "per_100_litres");

  // And the withholding column landed in its own cell, on its own row.
  const blackspot = rowFor(/Grapevines/i, /Blackspot/i);
  assertEquals(blackspot.whp_text, "30 days (H)");

  // The five-column TREE AND VINE table has no per-hectare column at all;
  // the six-column FIELD CROPS table earlier in the same document does, and
  // the two are never confused.
  assertEquals(grape.rate_ha_text, "");
  const cotton = rows().find((r) => /Bananas/i.test(r.crop_text));
  assert(cotton, "the six-column FRUIT table should still parse");
  assert(
    cotton.rate_ha_text.length > 0,
    "the per-hectare column must still be read where the table prints one",
  );
});

// ---------------------------------------------------------------------------
// §15.2 / §15.9 — no withholding text may reach a rate cell
// ---------------------------------------------------------------------------

Deno.test("59688 §15.2: '30 days (H)' never appears in ANY rate cell of the document", () => {
  for (const row of rows()) {
    assertFalse(
      /\(H\)|\(G\)|\bdays\b/i.test(row.rate_text),
      `withholding wording leaked into a rate cell: ${JSON.stringify(row)}`,
    );
    assertFalse(
      /\(H\)|\(G\)|\bdays\b/i.test(row.rate_ha_text),
      `withholding wording leaked into a per-hectare cell: ${JSON.stringify(row)}`,
    );
  }
});

Deno.test("59688 §15.9: the exact corrupt production string is recognised as a crossed column and is never served as a rate", () => {
  const corrupt = "30 days (H) 150 to 200 g";
  assert(rateCellCrossesColumns(corrupt));

  const row: DfuRow = {
    crop_text: "Grapevines",
    target_lines: ["Phomopsis Cane and Leaf spot"],
    rate_text: corrupt,
    rate_basis: "per_100_litres",
    rate_ha_text: "",
    whp_text: "",
    comments_text: "",
    rate_unit_hint: null,
  };
  const binding = bindDfuRows([row], [claim("Grapevines", "Phomopsis Cane and Leaf spot")]);

  // Nothing served — not even verbatim. A rate that crossed a column
  // boundary is corrupt evidence, not an unparsed wording.
  assertEquals(binding.ratesByClaim.size, 0);
  assertEquals(binding.unbound.length, 1);
  assertEquals(binding.unbound[0].reason, "column_geometry_uncertain");
  assertEquals(binding.unbound[0].rate_texts, [corrupt]);
});

Deno.test("59688 §15.8: a rate cell holding only a rate is unaffected by the crossed-column guard", () => {
  assertFalse(rateCellCrossesColumns("150 to 200 g"));
  assertFalse(rateCellCrossesColumns("35 or 54 mL/100 L"));
  assertFalse(rateCellCrossesColumns(""));
  // A qualifier that merely mentions an interval is wording, not a column
  // crossing — but it also states no bare quantity of its own to confuse.
  assertFalse(rateCellCrossesColumns("Apply every 14 days"));
});

// ---------------------------------------------------------------------------
// §15.3 / §15.4 — the column's basis gives bare quantities their meaning
// ---------------------------------------------------------------------------

Deno.test("59688 §15.3: a bare '200 g' in a RATE PER 100 L column parses as per_100_litres, never per hectare", () => {
  const custard = rowFor(/Custard/i, /Pseudocerco/i);
  assertEquals(custard.rate_text, "200 g");

  const parsed = parseRateCell(custard.rate_text, custard.rate_basis);
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].basis, "per_100_litres");
  assertEquals(parsed[0].value, 200);
  assertEquals(parsed[0].unit, "g");
  assertEquals(parsed[0].raw_text, "200 g");
});

Deno.test("59688 §15.4: '150 to 200 g' in a RATE PER 100 L column parses as range_per_100_litres", () => {
  const phomopsis = rowFor(/Grapevines/i, /Phomopsis/i);
  assertEquals(phomopsis.rate_text, "150 to 200 g");

  const parsed = parseRateCell(phomopsis.rate_text, phomopsis.rate_basis);
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].basis, "range_per_100_litres");
  assertEquals(parsed[0].min_value, 150);
  assertEquals(parsed[0].max_value, 200);
  assertEquals(parsed[0].unit, "g");
});

Deno.test("59688: the column basis never overrides a cell that states its own", () => {
  // A per-hectare wording sitting in a per-100-L column stays per hectare —
  // the cell is more specific than the heading.
  const parsed = parseRateCell("540 mL/ha", "per_100_litres");
  assertEquals(parsed[0].basis, "per_hectare");
  assertEquals(parsed[0].value, 540);

  // And a bare quantity with NO column basis is still only ever a quote.
  const bare = parseRateCell("200 g", null);
  assertEquals(bare[0].basis, "other");
  assertEquals(bare[0].raw_text, "200 g");
});

// ---------------------------------------------------------------------------
// §15.10 — the ornamentals row, whose cell states its own basis, still parses
// ---------------------------------------------------------------------------

Deno.test("59688 §15.10: the Carnations row ('150 to 200 g /100 L spray') still parses as a per-100-L range", () => {
  const carnations = rowFor(/Carnations/i, /Rust|Alternaria/i);
  const parsed = parseRateCell(carnations.rate_text, carnations.rate_basis);
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].basis, "range_per_100_litres");
  assertEquals(parsed[0].min_value, 150);
  assertEquals(parsed[0].max_value, 200);
});

// ---------------------------------------------------------------------------
// §15.5 / §15.6 / §15.7 — crop-scoped withholding periods
// ---------------------------------------------------------------------------

Deno.test("59688 §15.7: Title-Case crop prefixes in the WITHHOLDING PERIODS section bind to their own crops", () => {
  const text = [
    "WITHHOLDING PERIODS (WHP)",
    "Bananas: NOT REQUIRED WHEN USED AS DIRECTED",
    "Grapevines: DO NOT HARVEST FOR 30 DAYS AFTER APPLICATION",
    "First Aid Instructions: If poisoning occurs, contact a doctor.",
  ].join("\n");
  const statements = parseLabelStatements(text);

  const bananas = statements.find((s) => s.crop === "Bananas");
  assert(bananas, "the banana statement must be scoped to bananas");
  assertEquals(whpDaysFromStatement(bananas.statement, bananas.section), 0);

  const grapes = statements.find((s) => s.crop === "Grapevines");
  assert(grapes, "the grapevine statement must be scoped to grapevines");
  assertEquals(whpDaysFromStatement(grapes.statement, grapes.section), 30);

  // The safety valve: a Title-Case line whose statement is NOT a withholding
  // period is never mistaken for a crop.
  const firstAid = statements.find((s) => /poisoning occurs/i.test(s.statement));
  assert(firstAid);
  assertEquals(firstAid.crop, null);
});

Deno.test("59688 §15.5 + §15.6: grapevine WHP is 30 days, and the banana 'NOT REQUIRED' reaches neither the value nor the restrictions", async (t) => {
  const applied = applyLabelDocumentExtraction(
    evidence(GRAPE_CLAIMS),
    DITHANE_59688_ITEMS,
    DOC,
  );

  await t.step("every grapevine use carries the label's own 30-day WHP", () => {
    for (const c of applied.claims) {
      assertEquals(
        c.withholding_period_days,
        30,
        `${c.target_raw} should carry the grapevine WHP of 30 days`,
      );
    }
    assertFalse(applied.unresolved.includes("withholding_period:Grapevines"));
  });

  await t.step("no grapevine use is served an authoritative zero", () => {
    for (const c of applied.claims) assertFalse(c.withholding_period_days === 0);
  });

  await t.step("no banana statement is attached to a grapevine use", () => {
    for (const c of applied.claims) {
      for (const s of c.statements) {
        assertFalse(
          /banana/i.test(s),
          `a banana statement contaminated a grapevine use: ${s}`,
        );
      }
    }
  });

  await t.step("the statement that IS attached is the grapevine one, verbatim", () => {
    const stated = applied.claims.flatMap((c) => c.statements);
    assert(
      stated.some((s) => /Grapevines: DO NOT HARVEST FOR 30 DAYS/i.test(s)),
      `expected the grapevine withholding statement, got ${JSON.stringify(stated)}`,
    );
  });
});

Deno.test("59688 §15.6: bananas keep their OWN 'not required' — crop scoping cuts both ways", () => {
  const applied = applyLabelDocumentExtraction(
    evidence([claim("Bananas", "Leaf spot")]),
    DITHANE_59688_ITEMS,
    DOC,
  );
  assertEquals(applied.claims[0].withholding_period_days, 0);
  assert(
    applied.claims[0].statements.some((s) => /NOT REQUIRED WHEN USED AS DIRECTED/i.test(s)),
  );
});

// ---------------------------------------------------------------------------
// §8 — the grapevine acceptance shape, read from the label and nothing else
// ---------------------------------------------------------------------------

Deno.test("59688 §8: the grapevine rows are served exactly as the label prints them", () => {
  const applied = applyLabelDocumentExtraction(
    evidence(GRAPE_CLAIMS),
    DITHANE_59688_ITEMS,
    DOC,
  );
  const use = (target: RegExp): LabelUseClaim => {
    const found = applied.claims.find((c) => target.test(c.target_raw));
    assert(found, `missing grapevine use ${target}`);
    return found;
  };

  // Phomopsis prints its own rate cell, beside its own target lines.
  const phomopsis = use(/Phomopsis/i);
  assertEquals(phomopsis.rates?.length, 1);
  assertEquals(phomopsis.rates?.[0].basis, "range_per_100_litres");
  assertEquals(phomopsis.rates?.[0].min_value, 150);
  assertEquals(phomopsis.rates?.[0].max_value, 200);
  assertEquals(phomopsis.rates?.[0].unit, "g");
  assertEquals(phomopsis.rates?.[0].raw_text, "150 to 200 g");

  // Blackspot and Downy mildew are a SEPARATE printed sub-row, and the label
  // prints no rate cell beside them. The honest answer is no rate — not the
  // neighbouring row's numbers, and not the research model's recollection of
  // "200 g/100 L", which the label's own text layer does not support.
  for (const target of [/Blackspot/i, /Downy/i]) {
    assertEquals(use(target).rates ?? [], []);
  }

  // Whatever else happens, no served rate may carry withholding wording.
  for (const c of applied.claims) {
    for (const r of c.rates ?? []) {
      assertFalse(/\(H\)|\(G\)|\bdays\b/i.test(r.raw_text));
    }
  }
});

Deno.test("59688 §9: targets are only grouped where the label gives them the same rate", () => {
  const blackspot = rowFor(/Grapevines/i, /Blackspot/i);
  const phomopsis = rowFor(/Grapevines/i, /Phomopsis/i);

  // Two printed sub-rows, never collapsed into one.
  assert(blackspot !== phomopsis);
  assert(blackspot.target_lines.some((t) => /Downy/i.test(t)));
  assertFalse(blackspot.target_lines.some((t) => /Phomopsis/i.test(t)));
  assertFalse(phomopsis.target_lines.some((t) => /Blackspot/i.test(t)));

  // Blackspot and Downy mildew DO share one printed cell, so they stay
  // together — grouping follows the label, not convenience.
  assertEquals(blackspot.rate_text, phomopsis.rate_text === "150 to 200 g" ? "" : "");
});

// ---------------------------------------------------------------------------
// §15.12 — the product-page classifier is unchanged and still strict
// ---------------------------------------------------------------------------

Deno.test("59688 §15.12: only a registrant-owned product page can become product_url", () => {
  const accept = classifyUrl(
    "https://www.uplcorp.com/au/product-details/dithane-rainshield-neotec",
    "AU",
  );
  assert(accept.isProductPageCandidate, accept.reason);
  assertEquals(accept.trust, "registrant");
  assertEquals(accept.kind, "product_page");
  // …and it is emphatically NOT a label.
  assertFalse(accept.isOfficialLabelCandidate);

  const rejected: Array<[string, string]> = [
    ["https://www.nutrienhorticulture.com.au/product/dithane-rainshield-neo-tec", "reseller"],
    ["https://www.google.com/search?q=dithane+rainshield", "search engine"],
    ["https://www.uplcorp.com/au/sds/dithane-rainshield.pdf", "SDS"],
    ["https://www.uplcorp.com/au/products/collections/fungicides", "category page"],
    ["https://agrobaseapp.com/australia/pesticide/dithane-rainshield-neo-tec", "unknown host"],
  ];
  for (const [url, why] of rejected) {
    assertFalse(
      classifyUrl(url, "AU").isProductPageCandidate,
      `${why} must never become product_url: ${url}`,
    );
  }

  // The register's own eLabel stays the Official Label and nothing else.
  const label = classifyUrl("https://elabels.apvma.gov.au/59688ELBL.pdf", "AU");
  assert(label.isOfficialLabelCandidate);
  assertFalse(label.isProductPageCandidate);
});
