// APVMA 80647 (CHATEAU HERBICIDE) — real-document extraction, pinned against
// the REAL captured PDF text-layer geometry (`label_fixture_80647.ts`, taken
// from https://elabels.apvma.gov.au/80647ELBL.pdf with this project's own
// production extractor).
//
// WHAT WENT WRONG IN PRODUCTION
//   Run against the real document the parser produced NO DFU rows whatsoever,
//   so the grapevine rate of 560-700 g/ha never existed as structured data.
//   A downstream fixture that already CONTAINED "560 – 700 g/ha" proved only
//   that later stages handle a rate once someone hands them one; it could not
//   and did not prove the label was ever read. These tests start from measured
//   glyph positions and end at the wire rate, so they fail if the real
//   document stops parsing.
//
//   Three independent faults, each sufficient on its own — see the fixture
//   header for the measured geometry of each.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyLabelDocumentExtraction,
  type DfuRow,
  parseDirectionsForUse,
  parseRateCell,
} from "./label_extract.ts";
import {
  parseLabelStatements,
  statementCanStateHarvestWhp,
  whpDaysFromStatement,
} from "./label.ts";
import type {
  LabelDocumentDiscovery,
  LabelEvidence,
  LabelUseClaim,
  WireLabelRate,
} from "./contract.ts";
import { CHATEAU_80647_ITEMS } from "./label_fixture_80647.ts";
import { DITHANE_59688_ITEMS } from "./label_fixture_59688.ts";

const DOC: LabelDocumentDiscovery = {
  url: "https://elabels.apvma.gov.au/80647ELBL.pdf",
  confirmation: "pubcris_view_label",
  retrieved_at: "2026-08-30T00:00:00.000Z",
  document: {
    sha256: "18afa5958435ef413f6165a66ee093a06004b9011cad2b71e32abadd78acbdec",
    byte_size: 244_005,
  },
};

function rows(): DfuRow[] {
  return parseDirectionsForUse(CHATEAU_80647_ITEMS).rows;
}

function grapevineRow(): DfuRow {
  const found = rows().find((r) => /grapevine/i.test(r.crop_text));
  assert(found, "no DFU row naming grapevines");
  return found;
}

function claim(crop: string, targetRaw: string): LabelUseClaim {
  return { crop, target_raw: targetRaw, statements: [] };
}

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

// ---------------------------------------------------------------------------
// §1 — the page-1 footer must not abandon the document
// ---------------------------------------------------------------------------

Deno.test("80647 §1: the page-1 'Other Limitations: NOT TO BE USED FOR ANY PURPOSE' line closes a SECTION, not the document", () => {
  const parsed = parseDirectionsForUse(CHATEAU_80647_ITEMS);
  assert(parsed.found, "the directions section is found");

  // The regression in one number: this was 0.
  assert(
    parsed.rows.length > 0,
    "directions rows survive a footer sentence printed seven pages earlier",
  );

  // And the rows that survive are the real tables on pages 8 and 9.
  assert(
    parsed.rows.some((r) => /grapevine/i.test(r.crop_text)),
    "the page-8 vineyard table (Table A) is reached",
  );
});

// ---------------------------------------------------------------------------
// §2 — the three-baseline column heading builds a real column map
// ---------------------------------------------------------------------------

Deno.test("80647 §2: Table A's heading, printed across THREE interleaved baselines, resolves to crop/target/rate/comments columns", () => {
  const grape = grapevineRow();

  // "CROP" over "SITUATION" stayed ONE column, and the crop cell is the
  // merged group cell the label actually prints — grapevines named first.
  assert(
    /^Grapevines\b/.test(grape.crop_text),
    `crop cell should start at Grapevines, got: ${grape.crop_text}`,
  );

  // "WEEDS CONTROLLED" seeded the target column: without it the header was
  // rejected outright and the whole table produced nothing.
  assert(grape.target_lines.length > 0, "the target column produced cells");
  assert(
    grape.target_lines.some((t) => /Annual ryegrass/i.test(t)),
    "the first printed weed is present verbatim",
  );

  // "RATE" over "g/ha" is one rate column that states its own basis AND unit.
  assertEquals(grape.rate_basis, "per_hectare");
  assertEquals(grape.rate_unit_hint, "g");

  // The critical comments did not leak into the rate column.
  assert(
    grape.comments_text.startsWith("CHATEAU Herbicide needs at least 15 mm of"),
    "critical comments stay in their own column",
  );
});

// ---------------------------------------------------------------------------
// §3 — the required structured result
// ---------------------------------------------------------------------------

Deno.test("80647 §3: the grapevine use carries range_per_hectare 560-700 g, read from the real document", () => {
  const grape = grapevineRow();

  // The cell is a bare range; its unit lives in the column heading.
  assertEquals(grape.rate_ha_text, "560 – 700");

  const rates = parseRateCell(grape.rate_ha_text, "per_hectare", grape.rate_unit_hint);
  assertEquals(rates.length, 1, "one rate, not two, and never a converted pair");

  const rate = rates[0];
  assertEquals(rate.basis, "range_per_hectare");
  assertEquals(rate.min_value, 560);
  assertEquals(rate.max_value, 700);
  assertEquals(rate.unit, "g");

  // Both bounds are preserved and the printed text is kept verbatim — the
  // range is never collapsed to a single "representative" number.
  assertEquals(rate.raw_text, "560 – 700");
  assertEquals(rate.value, undefined, "a range never acquires a single value");
});

Deno.test("80647 §3b: the rate reaches the registered grapevine uses through the full document pipeline", () => {
  const claims = [
    claim("Grapevines", "Annual ryegrass"),
    claim("Grapevines", "Capeweed"),
  ];
  const merged = applyLabelDocumentExtraction(evidence(claims), CHATEAU_80647_ITEMS, DOC);

  const expected: WireLabelRate = {
    label: "",
    basis: "range_per_hectare",
    min_value: 560,
    max_value: 700,
    unit: "g",
    raw_text: "560 – 700",
  };

  for (const c of merged.claims) {
    assertEquals(c.rates, [expected], `grapevine claim ${c.target_raw} carries the label rate`);
  }

  // The rate gap is closed because a STRUCTURED rate bound, not merely because
  // some text was found.
  assert(
    !merged.unresolved.includes("rates:Grapevines"),
    "the grapevine rate gap is closed",
  );
});

// ---------------------------------------------------------------------------
// §4 — safety: no other crop's withholding period may reach grapevines
// ---------------------------------------------------------------------------

Deno.test("80647 §4: the grapevine harvest withholding period is 98 days, with the label's verbatim wording", () => {
  const claims = [claim("Grapevines", "Annual ryegrass")];
  const merged = applyLabelDocumentExtraction(evidence(claims), CHATEAU_80647_ITEMS, DOC);
  const grape = merged.claims[0];

  // The label scopes this with a crop-list heading that WRAPS across two lines,
  // above a "HARVEST:" sub-label. Reading "HARVEST" as the crop is what made a
  // plainly printed 14-week period reach the app as "not stated".
  assertEquals(grape.withholding_period_days, 98, "14 weeks is 98 days");

  // The number is only the scheduling projection. The legal instruction is the
  // wording, so the wording is preserved whole — scope, sub-label and sentence.
  assertEquals(
    grape.withholding_statement,
    "WINE AND TABLE GRAPES, POME FRUIT, STONE FRUIT, CITRUS FRUIT, NUT TREE CROPS " +
      "(EXCEPT MACADAMIA NUTS), OLIVES, AVOCADOS AND BERRIES: HARVEST: " +
      "DO NOT HARVEST FOR 14 WEEKS AFTER APPLICATION",
  );

  assert(
    !merged.unresolved.includes("withholding_period:Grapevines"),
    "the withholding gap is closed",
  );
});

Deno.test("80647 §4b: macadamia's 63 days stays on macadamia and NEVER reaches grapevines", () => {
  // The label prints TWO harvest withholding periods. Serving the wrong one is
  // the exact shape of the Dithane defect, where a banana's "NOT REQUIRED"
  // became the grapevine WHP of zero days.
  const read = (crop: string) =>
    applyLabelDocumentExtraction(
      evidence([claim(crop, "Annual ryegrass")]),
      CHATEAU_80647_ITEMS,
      DOC,
    ).claims[0];

  const grape = read("Grapevines");
  const macadamia = read("Macadamia nuts");

  assertEquals(grape.withholding_period_days, 98);
  assertEquals(macadamia.withholding_period_days, 63);

  // Macadamia is named INSIDE the grape scope, as an exclusion: "NUT TREE CROPS
  // (EXCEPT MACADAMIA NUTS)". Tokenised naively that heading CONTAINS the word
  // MACADAMIA, so a scope reader that ignores exclusions hands macadamia the
  // 98-day grape period. It must not.
  assert(
    !/EXCEPT MACADAMIA/i.test(macadamia.withholding_statement ?? ""),
    "macadamia does not inherit the grape scope it is excluded from",
  );
  assert(
    /MACADAMIA NUTS: HARVEST:/i.test(macadamia.withholding_statement ?? ""),
    "macadamia reads its own heading",
  );

  // Crops this label does not name get nothing — not the nearest number, not a
  // product-wide default.
  for (const absent of ["Almonds", "Bananas"]) {
    assertEquals(
      read(absent).withholding_period_days ?? null,
      null,
      `${absent} is not named by this label and must receive no period`,
    );
  }
});

Deno.test("80647 §4c: a HARVEST sub-label is never a crop, and an unscoped one fails closed", () => {
  const statements = parseLabelStatements(
    [
      "Withholding Periods: WINE AND TABLE GRAPES, POME FRUIT, STONE FRUIT, CITRUS FRUIT, NUT TREE",
      "CROPS (EXCEPT MACADAMIA NUTS), OLIVES, AVOCADOS AND BERRIES:",
      "HARVEST: DO NOT HARVEST FOR 14 WEEKS AFTER APPLICATION",
      "MACADAMIA NUTS:",
      "HARVEST: DO NOT HARVEST FOR 9 WEEKS AFTER APPLICATION",
    ].join("\n"),
  );

  assert(
    !statements.some((s) => s.crop !== null && /^HARVEST$/i.test(s.crop)),
    "HARVEST is a sub-label, never a crop",
  );

  const scoped = statements.find((s) =>
    s.sub_label === "HARVEST" && /14 WEEKS/.test(s.statement)
  );
  assert(scoped, "the 14-week statement is scoped");
  assert(scoped.crop?.startsWith("WINE AND TABLE GRAPES"));
  assertEquals(whpDaysFromStatement(scoped.statement, scoped.section), 98);

  // A sub-label with NO resolvable scope must not become product-wide: an
  // unreadable scope is a parser gap, and answering "applies to everything"
  // turns that gap into a wrong period on every crop.
  const orphan = parseLabelStatements("HARVEST: DO NOT HARVEST FOR 21 DAYS")
    .find((s) => s.sub_label === "HARVEST");
  assert(orphan, "the orphan statement is still recorded verbatim");
  assertEquals(orphan.crop, null);
  assertEquals(orphan.scope_unresolved, true);
  assertEquals(orphan.statement, "DO NOT HARVEST FOR 21 DAYS");
});

Deno.test("80647 §4d: a GRAZING interval is never served as the harvest withholding period", () => {
  // This label states 4-week and 8-week GRAZING intervals in the same block as
  // the harvest periods. They govern stock food, not harvest.
  const grape = applyLabelDocumentExtraction(
    evidence([claim("Grapevines", "Annual ryegrass")]),
    CHATEAU_80647_ITEMS,
    DOC,
  ).claims[0];
  assertEquals(grape.withholding_period_days, 98);
  assert(
    !/GRAZE/i.test(grape.withholding_statement ?? ""),
    "the harvest period is not read from a grazing statement",
  );

  // Directly: a grazing sub-label cannot state a harvest period even when its
  // sentence contains a readable interval.
  const grazing = parseLabelStatements(
    ["WINE AND TABLE GRAPES:", "GRAZING: DO NOT HARVEST FOR 3 WEEKS AFTER APPLICATION"].join("\n"),
  ).find((s) => s.sub_label === "GRAZING");
  assert(grazing, "the grazing statement is recorded");
  assertEquals(statementCanStateHarvestWhp(grazing), false);
});

// ---------------------------------------------------------------------------
// §5 — re-entry is conditional wording, and no number may be invented from it
// ---------------------------------------------------------------------------

Deno.test("80647 §5: the conditional re-entry wording never becomes a numeric re-entry period", () => {
  const claims = [claim("Grapevines", "Annual ryegrass")];
  const merged = applyLabelDocumentExtraction(evidence(claims), CHATEAU_80647_ITEMS, DOC);

  // The label's re-entry rule is conditional on a state ("until the spray has
  // dried") and on protective clothing. It states no number of hours, so no
  // number may appear.
  assertEquals(merged.claims[0].reentry_hours ?? null, null);

  const page4 = CHATEAU_80647_ITEMS.filter((i) => i.page === 4).map((i) => i.str).join("");
  assert(
    /DO NOT enter treated areas until the spray has dried/i.test(page4),
    "the conditional wording is present in the document",
  );
  assert(
    !/\bre-?enter\b[^.]*\b\d+\s*hours?\b/i.test(page4),
    "the label states no re-entry hour count to read",
  );
});

// ---------------------------------------------------------------------------
// §6 — the counterexample: a genuinely blank rate cell must stay blank
// ---------------------------------------------------------------------------

Deno.test("80647 §6: reading a unit from the column heading does NOT fill Dithane 59688's genuinely blank rate cells", () => {
  // The 80647 fix lets a rate cell take its UNIT from the column heading. It
  // must never let an EMPTY cell take a VALUE from anywhere. Dithane 59688 is
  // the standing counterexample: rows whose rate cell the label leaves blank.
  // Rule-based on purpose — it walks every row of the real table rather than
  // naming one, so a new blank row is covered the day it appears.
  const dithane = parseDirectionsForUse(DITHANE_59688_ITEMS).rows;
  assert(dithane.length > 0, "the Dithane table still parses");

  let blankCells = 0;
  for (const row of dithane) {
    for (const cell of [row.rate_text, row.rate_ha_text]) {
      if (cell.trim().length > 0) continue;
      blankCells++;
      assertEquals(
        parseRateCell(cell, row.rate_basis, row.rate_unit_hint),
        [],
        `a blank rate cell must yield no rate (crop: ${row.crop_text})`,
      );
    }
  }
  assert(blankCells > 0, "the counterexample is real: blank rate cells exist");
});

Deno.test("80647 §6b: a bare quantity with NO heading unit still refuses to become a rate", () => {
  // The heading unit is the ONLY thing that makes a bare quantity readable.
  // Without one, "560 – 700" is a number with no basis and must stay
  // unparsed rather than acquire a plausible-looking unit.
  assertEquals(parseRateCell("560 – 700", "per_hectare", null), [{
    label: "",
    basis: "other",
    unit: "",
    raw_text: "560 – 700",
  }]);

  // And a heading unit alone is not enough without a basis either.
  assertEquals(parseRateCell("560 – 700", null, "g"), [{
    label: "",
    basis: "other",
    unit: "",
    raw_text: "560 – 700",
  }]);
});
