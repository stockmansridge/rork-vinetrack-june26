// Gate D4A.3.2 — direction-identity repair: routing, projection and binding.
//
// # What this suite is defending
//
// D4A.3 asked ONE question before re-reading a label: are the grapevine rates
// calculable? THIOVIT JET (APVMA 53904) proved that insufficient. Its two
// printed Powdery Mildew directions — table/drying grapes at 100–200 g/100 L
// and wine grapes at 200–600 g/100 L — arrive as a single `GRAPE` use holding
// two unexplained rates, each flagged `condition_ambiguous` by the parser that
// lost their binding. Every number is correct. The MEANING is destroyed:
//
//   CALCULABLE != CORRECTLY BOUND.
//
// So the gate now also asks whether the rates are bound, and a candidate
// re-read must prove itself strictly better before it may displace a working
// parse. The tests below are split accordingly:
//
//   §A–§G   the routing rule, including the cases that must NOT route;
//   §H–§I   the additive direction-level condition and its compatibility;
//   §J      identity stability under reorder and target fan-out;
//   §K      comment scoping, at projection AND parser level;
//   §L–§M   period preservation across a replacement.
//
// §C is the most important test in the file. VineTrack legitimately serves
// labels printing several rates on one basis for one direction, and a gate
// that treated "several numbers" as damage would break working products to
// fix a broken one.

import {
  assert,
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

import {
  carryForwardStatedPeriods,
  ordinaryHasDirectionIdentityLoss,
  panelStrictlyImprovesDirectionIdentity,
  selectDirectionSource,
} from "./label_panel_fallback.ts";
import {
  extractManufacturerLabelUses,
  type ManufacturerLabelUse,
  manufacturerUsesToRegisteredUses,
} from "./manufacturer_label.ts";
import { mintDirectionId } from "../rate_identity.ts";
import { isGrapevineCrop } from "../grapevine_label.ts";
import type { PdfTextItem, WireLabelRate } from "./contract.ts";
import { THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS } from "./seeds/thiovit_53904_evidence.ts";

const PRODUCT = {
  country: "AU",
  scheme: "apvma",
  registration_number: "53904",
} as const;

const TABLE_GRAPES = "Grapes table grapes, fruit destined for drying";
const WINE_GRAPES = "Grapes Vines wine grapes only";
const STATES = "NSW, Vic, Tas, SA, WA only";

function rate(partial: Partial<WireLabelRate>): WireLabelRate {
  return {
    label: "",
    basis: "range_per_100_litres",
    unit: "g",
    raw_text: "",
    ...partial,
  } as WireLabelRate;
}

/** The two authoritative Thiovit PM directions, as the label prints them. */
function thiovitPanelUses(): ManufacturerLabelUse[] {
  return [
    {
      crop: TABLE_GRAPES,
      targets: ["Powdery Mildew", "Mites"],
      condition: STATES,
      rates: [rate({ min_value: 100, max_value: 200, raw_text: "100-200 g/100 L" })],
      restrictions: "Apply every 2 to 3 weeks.",
    },
    {
      crop: WINE_GRAPES,
      targets: ["Powdery Mildew", "Mites"],
      condition: STATES,
      rates: [rate({ min_value: 200, max_value: 600, raw_text: "200-600 g/100 L" })],
      restrictions: "Apply every 14 to 21 days. Use the upper end of the rate range.",
    },
  ];
}

function project(uses: ManufacturerLabelUse[]): Record<string, unknown>[] {
  return manufacturerUsesToRegisteredUses(uses, { product: PRODUCT });
}

/** The collapsed rows production serves today. */
function ordinaryThiovit(): Record<string, unknown>[] {
  return THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS;
}

Deno.test("§0 the fixtures are grapevine crops, so every gate below is non-vacuous", () => {
  for (const crop of ["GRAPE", TABLE_GRAPES, WINE_GRAPES]) {
    assertEquals(isGrapevineCrop(crop), true, crop);
  }
});

// ---------------------------------------------------------------------------
// §A–§G — the routing rule
// ---------------------------------------------------------------------------

Deno.test("§A ordinary non-calculable + valid candidate — the D4A.3 fallback still applies", () => {
  // The VICOL 33182 repair. Unchanged by this phase, and asserted here so a
  // future edit to the new branch cannot quietly cost us the original one.
  const ordinary = [{
    crop: "GRAPEVINE",
    target: "Scale",
    rates: [rate({ basis: "other", unit: "", raw_text: "2 L / 1OO L 3 L / 1OO L" })],
  }];
  const decision = selectDirectionSource({
    ordinaryUses: ordinary,
    panelUses: project(thiovitPanelUses()),
    product: PRODUCT,
  });
  assertEquals(decision.replace, true);
  assertEquals(decision.outcome, "ordinary_not_calculable");
});

Deno.test("§A2 no candidate at all — the ordinary result stands untouched", () => {
  const decision = selectDirectionSource({
    ordinaryUses: ordinaryThiovit(),
    panelUses: null,
    product: PRODUCT,
  });
  assertEquals(decision.replace, false);
  assertEquals(decision.outcome, "no_candidate");
});

Deno.test("§B ordinary calculable + no ambiguity — a candidate does NOT displace it", () => {
  const ordinary = [{
    crop: "GRAPEVINE",
    target: "Powdery Mildew",
    rates: [rate({ min_value: 100, max_value: 200, raw_text: "100-200 g/100 L" })],
  }];
  assertFalse(ordinaryHasDirectionIdentityLoss(ordinary));

  const decision = selectDirectionSource({
    ordinaryUses: ordinary,
    panelUses: project(thiovitPanelUses()),
    product: PRODUCT,
  });
  assertEquals(decision.replace, false);
  assertEquals(decision.outcome, "ordinary_retained");
  assertEquals(decision.comparison?.check, "no_identity_loss");
});

Deno.test("§C CRITICAL: legitimate multiple same-basis rates are NOT treated as damage", () => {
  // Low/high disease pressure on one direction, each rate explicitly labelled.
  // This is a HEALTHY label. If "several rates on one basis" were the collapse
  // signal, this product would be rerouted through a fallback and broken in
  // order to fix Thiovit — so the signal is the parser's own ambiguity
  // admission, never the shape.
  const ordinary = [{
    crop: "GRAPEVINE",
    target: "Powdery Mildew",
    rates: [
      rate({
        label: "Low disease pressure",
        basis: "per_100_litres",
        value: 100,
        raw_text: "100 g/100 L",
      }),
      rate({
        label: "High disease pressure",
        basis: "per_100_litres",
        value: 200,
        raw_text: "200 g/100 L",
      }),
      rate({
        label: "Early season",
        basis: "per_hectare",
        value: 1.5,
        unit: "kg",
        raw_text: "1.5 kg/ha",
      }),
    ],
  }];

  // Several rates, several on ONE basis, a second basis, several numbers —
  // and no identity loss, because nothing declares its binding unproven.
  assertFalse(ordinaryHasDirectionIdentityLoss(ordinary));

  const decision = selectDirectionSource({
    ordinaryUses: ordinary,
    panelUses: project(thiovitPanelUses()),
    product: PRODUCT,
  });
  assertEquals(decision.replace, false);
  assertEquals(decision.comparison?.check, "no_identity_loss");
});

Deno.test("§C2 several targets, or a range, are likewise not evidence of collapse", () => {
  const ordinary = [{
    crop: "GRAPEVINE",
    target: "Powdery Mildew",
    rates: [rate({ min_value: 100, max_value: 200, raw_text: "100-200 g/100 L" })],
  }, {
    crop: "GRAPEVINE",
    target: "Botrytis",
    rates: [rate({ min_value: 100, max_value: 200, raw_text: "100-200 g/100 L" })],
  }];
  assertFalse(ordinaryHasDirectionIdentityLoss(ordinary));
});

Deno.test("§D ordinary ambiguous + candidate itself ambiguous — ordinary remains", () => {
  // Never exchange one unproven association for another.
  const ambiguousPanel = project(thiovitPanelUses()).map((row) => ({
    ...row,
    rates: (row.rates as Record<string, unknown>[]).map((r) => ({
      ...r,
      condition_ambiguous: true,
    })),
  }));
  const decision = selectDirectionSource({
    ordinaryUses: ordinaryThiovit(),
    panelUses: ambiguousPanel,
    product: PRODUCT,
  });
  assertEquals(decision.replace, false);
  assertEquals(decision.comparison?.check, "panel_still_ambiguous");
});

Deno.test("§D2 ordinary ambiguous + candidate states no calculable rate — ordinary remains", () => {
  const unusable = project([{
    ...thiovitPanelUses()[0],
    rates: [rate({ basis: "other", unit: "", raw_text: "see label" })],
  }]);
  const decision = selectDirectionSource({
    ordinaryUses: ordinaryThiovit(),
    panelUses: unusable,
    product: PRODUCT,
  });
  assertEquals(decision.replace, false);
  assertEquals(decision.comparison?.check, "panel_not_calculable");
});

Deno.test("§E ordinary ambiguous + candidate LOSES a rate — ordinary remains", () => {
  // A cleaner structure with fewer numbers is not a better result.
  //
  // Deliberately constructed so the candidate PASSES the direction-count
  // check — it distinguishes two directions against the ordinary parse's one
  // — and is rejected purely on lost rate evidence. It resolves the
  // table-grape direction perfectly, adds a Botrytis direction, and simply
  // never mentions 200–600 g/100 L. Structurally better, factually poorer.
  const partial = project([
    thiovitPanelUses()[0],
    {
      crop: WINE_GRAPES,
      targets: ["Botrytis"],
      condition: STATES,
      rates: [rate({ basis: "per_100_litres", value: 300, raw_text: "300 g/100 L" })],
      restrictions: null,
    },
  ]);
  const comparison = panelStrictlyImprovesDirectionIdentity({
    ordinaryUses: ordinaryThiovit(),
    panelUses: partial,
    product: PRODUCT,
  });
  assertEquals(comparison.improves, false);
  assertEquals(comparison.check, "rate_evidence_lost");
  // It cleared the count bar, so the rejection is genuinely about evidence.
  assertEquals(comparison.ordinaryDirectionCount, 1);
  assertEquals(comparison.panelDirectionCount, 2);
  // The lost evidence is named, by MEANING rather than by position.
  assertEquals(comparison.lostRateSignatures, ["range_per_100_litres|g|-|200|600"]);

  assertEquals(
    selectDirectionSource({
      ordinaryUses: ordinaryThiovit(),
      panelUses: partial,
      product: PRODUCT,
    }).replace,
    false,
  );
});

Deno.test("§F ordinary ambiguous + candidate has the SAME direction count — ordinary remains", () => {
  // Both rates preserved, no ambiguity — but still only one direction, so
  // nothing was actually repaired and a merely different reading must lose.
  const oneDirection = project([{
    crop: TABLE_GRAPES,
    targets: ["Powdery Mildew"],
    condition: STATES,
    rates: [
      rate({ min_value: 100, max_value: 200, raw_text: "100-200 g/100 L" }),
      rate({ min_value: 200, max_value: 600, raw_text: "200-600 g/100 L" }),
    ],
    restrictions: null,
  }]);
  const comparison = panelStrictlyImprovesDirectionIdentity({
    ordinaryUses: ordinaryThiovit(),
    panelUses: oneDirection,
    product: PRODUCT,
  });
  assertEquals(comparison.improves, false);
  assertEquals(comparison.check, "not_more_directions");
  assertEquals(comparison.ordinaryDirectionCount, 1);
  assertEquals(comparison.panelDirectionCount, 1);
});

Deno.test("§G ordinary ambiguous + candidate keeps every rate and adds directions — REPLACE", () => {
  const panel = project(thiovitPanelUses());

  assert(ordinaryHasDirectionIdentityLoss(ordinaryThiovit()));
  const comparison = panelStrictlyImprovesDirectionIdentity({
    ordinaryUses: ordinaryThiovit(),
    panelUses: panel,
    product: PRODUCT,
  });
  assertEquals(comparison.improves, true);
  assertEquals(comparison.check, "strictly_better");
  assertEquals(comparison.ordinaryDirectionCount, 1);
  assertEquals(comparison.panelDirectionCount, 2);
  assertEquals(comparison.lostRateSignatures, []);

  const decision = selectDirectionSource({
    ordinaryUses: ordinaryThiovit(),
    panelUses: panel,
    product: PRODUCT,
  });
  assertEquals(decision.replace, true);
  assertEquals(decision.outcome, "identity_repair");
});

Deno.test("§G2 the repaired result never merges the two ranges into 100-600", () => {
  const panel = project(thiovitPanelUses());
  const ranges = panel.flatMap((row) =>
    (row.rates as { min_value?: number; max_value?: number }[]).map(
      (r) => [r.min_value, r.max_value] as const,
    )
  );
  for (const [min, max] of ranges) {
    assertFalse(min === 100 && max === 600, "the union range is not a registered direction");
  }
  assertEquals(new Set(ranges.map((r) => r.join("-"))), new Set(["100-200", "200-600"]));

  // And no direction carries both ranges as two unexplained rates.
  for (const row of panel) assertEquals((row.rates as unknown[]).length, 1);
});

// ---------------------------------------------------------------------------
// §H–§I — the condition reaches clients on contract v1 ONLY
// ---------------------------------------------------------------------------

Deno.test("§H the candidate's condition survives on rate.label (contract v1)", () => {
  // `label` is the single normative home of the state wording in v1, and the
  // key shipping iOS and Android builds already read.
  for (const row of project(thiovitPanelUses())) {
    const rates = row.rates as { label?: string }[];
    assert(rates.length > 0);
    for (const r of rates) {
      assertEquals(r.label, STATES);
    }
  }
});

Deno.test("§I NO unversioned direction-level `condition` key reaches the wire", () => {
  // The direction-level field is a FUTURE v2 change (contract section 11:
  // both app models + schema-version bump + doc, in one coordinated change).
  // Emitting it under v1 would put a key on the wire that no client is
  // allowed to trust, so the projection must not carry it — even though the
  // condition is known and used internally for identity and scoping.
  for (const row of project(thiovitPanelUses())) {
    assertFalse("condition" in row);
  }
});

Deno.test("§H2 a direction with no condition still carries its historical shape", () => {
  const rows = project([{
    crop: "GRAPEVINE",
    targets: ["Powdery Mildew"],
    condition: null,
    rates: [rate({ min_value: 100, max_value: 200 })],
    restrictions: null,
  }]);
  assertFalse("condition" in rows[0]);
});

Deno.test("§I2 the condition still does its INTERNAL work despite not being emitted", () => {
  // Withholding the key from the wire must not weaken the repair: identity is
  // still minted from the condition, so the two PM directions stay distinct.
  const rows = project(thiovitPanelUses());
  const ids = new Set(rows.map((r) => String(r.direction_id)));
  assertEquals(ids.size, 2);
});

// ---------------------------------------------------------------------------
// §J — identity stability
// ---------------------------------------------------------------------------

Deno.test("§J direction ids survive array reorder, fan-out and result ordering", () => {
  const forward = project(thiovitPanelUses());
  const reversed = project([...thiovitPanelUses()].reverse());

  const idsOf = (rows: Record<string, unknown>[]) =>
    new Set(rows.map((r) => String(r.direction_id)));
  assertEquals(idsOf(forward), idsOf(reversed));
  assertEquals(idsOf(forward).size, 2);

  // Fan-out: two targets per direction produce four rows, and the two rows of
  // ONE printed direction share ONE identity — identity is minted before the
  // fan-out destroys the complete target set, never re-derived after it.
  assertEquals(forward.length, 4);
  for (const crop of [TABLE_GRAPES, WINE_GRAPES]) {
    const rows = forward.filter((r) => r.crop === crop);
    assertEquals(rows.length, 2);
    assertEquals(new Set(rows.map((r) => String(r.direction_id))).size, 1);
  }

  // And the ids equal what the existing algorithm mints from the direction —
  // no new identity system, and no dependence on target order.
  const expected = mintDirectionId(PRODUCT, {
    crop: TABLE_GRAPES,
    targets: ["Mites", "Powdery Mildew"],
    condition: STATES,
  });
  assertEquals(String(forward.find((r) => r.crop === TABLE_GRAPES)!.direction_id), expected);
});

Deno.test("§J2 the two repaired PM directions differ from the collapsed identity", () => {
  const panel = project(thiovitPanelUses());
  const collapsed = mintDirectionId(PRODUCT, {
    crop: "GRAPE",
    target_raw: "Powdery Mildew",
    condition: null,
  });
  for (const row of panel) assert(String(row.direction_id) !== collapsed);
});

// ---------------------------------------------------------------------------
// §K — comment binding
// ---------------------------------------------------------------------------

Deno.test("§K comments A never bleed into direction B through the projection", () => {
  const rows = project(thiovitPanelUses());
  const table = rows.filter((r) => r.crop === TABLE_GRAPES);
  const wine = rows.filter((r) => r.crop === WINE_GRAPES);

  for (const row of table) {
    assert(/every 2 to 3 weeks/i.test(String(row.restrictions)));
    assertFalse(/14 to 21 days/i.test(String(row.restrictions)));
  }
  for (const row of wine) {
    assert(/every 14 to 21 days/i.test(String(row.restrictions)));
    assert(/upper end of the rate range/i.test(String(row.restrictions)));
    assertFalse(/every 2 to 3 weeks/i.test(String(row.restrictions)));
  }
});

// --- parser level -----------------------------------------------------------
//
// The projection above can only preserve what the parser hands it, and the
// parser collects comments per CROP BLOCK. Two directions inside ONE block is
// therefore the case that could still concatenate, so it is measured here on
// positioned text rather than assumed away.

const COL = { crop: 50, target: 150, state: 250, rate: 330, comments: 430 };

function item(page: number, x: number, y: number, str: string): PdfTextItem {
  return { page, x, y, width: str.length * 4.5, str };
}

/** A minimal state-aware DFU table: one crop block, two rate lines. */
function dfuItems(
  rows: { target?: string; state: string; rate: string; comments?: string }[],
): PdfTextItem[] {
  const items: PdfTextItem[] = [
    item(1, COL.crop, 700, "DIRECTIONS FOR USE"),
    item(1, COL.crop, 680, "Crop"),
    item(1, COL.target, 680, "Pests"),
    item(1, COL.state, 680, "State"),
    item(1, COL.rate, 680, "Rate"),
    item(1, COL.comments, 680, "Critical Comments"),
  ];
  rows.forEach((row, i) => {
    const y = 660 - i * 20;
    if (i === 0) items.push(item(1, COL.crop, y, "Grapes"));
    if (row.target) items.push(item(1, COL.target, y, row.target));
    items.push(item(1, COL.state, y, row.state));
    items.push(item(1, COL.rate, y, row.rate));
    if (row.comments) items.push(item(1, COL.comments, y, row.comments));
  });
  return items;
}

Deno.test("§K2 one crop block, two directions, each with its OWN comments — scoped per direction", () => {
  const parse = extractManufacturerLabelUses(dfuItems([
    {
      target: "Powdery Mildew",
      state: "NSW, Vic",
      rate: "100-200 g/100 L",
      comments: "Apply every 2 to 3 weeks.",
    },
    {
      state: "Qld",
      rate: "200-600 g/100 L",
      comments: "Apply every 14 to 21 days.",
    },
  ]));

  assertEquals(parse.found, true);
  assertEquals(parse.uses.length, 2);
  // Two spans carry comment text of their own, so the label is demonstrably
  // writing comments per direction and each keeps only its own.
  assert(/2 to 3 weeks/.test(parse.uses[0].restrictions ?? ""));
  assertFalse(/14 to 21 days/.test(parse.uses[0].restrictions ?? ""));
  assert(/14 to 21 days/.test(parse.uses[1].restrictions ?? ""));
  assertFalse(/2 to 3 weeks/.test(parse.uses[1].restrictions ?? ""));
  // The conditions stay distinct too.
  assertEquals(parse.uses[0].condition, "NSW, Vic");
  assertEquals(parse.uses[1].condition, "Qld");
});

Deno.test("§K3 a SINGLE block-level comment stays block-scoped — never narrowed by guess", () => {
  // Only one span carries comments. Whether that comment governs the block or
  // just its first direction is genuinely unprovable from the geometry, so the
  // conservative block-level reading stands rather than a clean-looking guess.
  const parse = extractManufacturerLabelUses(dfuItems([
    {
      target: "Powdery Mildew",
      state: "NSW, Vic",
      rate: "100-200 g/100 L",
      comments: "DO NOT apply to wet foliage.",
    },
    { state: "Qld", rate: "200-600 g/100 L" },
  ]));

  assertEquals(parse.uses.length, 2);
  for (const use of parse.uses) {
    assert(/DO NOT apply to wet foliage/.test(use.restrictions ?? ""));
  }
});

// ---------------------------------------------------------------------------
// §L–§M — periods survive the replacement
// ---------------------------------------------------------------------------

Deno.test("§L WHP: a unanimous 'not required' projection survives the repair", () => {
  // The register states 0 ("Not required when used as directed") on the
  // collapsed rows. Replacing them must not cost the operator that fact —
  // even though the two readings word the crop differently ("GRAPE" against
  // "Grapes table grapes, fruit destined for drying").
  const carried = carryForwardStatedPeriods(
    project(thiovitPanelUses()),
    ordinaryThiovit(),
  );
  for (const row of carried) assertEquals(row.withholding_period_days, 0);
});

Deno.test("§L2 WHP: 0 is a PROJECTION and never the whole legal fact", () => {
  // Guarding the wording rule at the layer that owns it: the number carried
  // above is the conservative projection of "NOT REQUIRED WHEN USED AS
  // DIRECTED", and nothing here may present a bare "0 days" as the answer.
  const carried = carryForwardStatedPeriods(
    project(thiovitPanelUses()),
    ordinaryThiovit(),
  );
  assertEquals(carried[0].withholding_period_days, 0);
  // The repair adds no wording of its own and invents no "0 days" string.
  assertFalse("withholding_period_text" in carried[0]);
});

Deno.test("§L3 WHP: genuinely DISAGREEING periods carry nothing", () => {
  // The widened crop correspondence must not become a licence to guess: if
  // two grapevine directions state different periods, unanimity fails and the
  // gap stays visible rather than inheriting one direction's period.
  const carried = carryForwardStatedPeriods(
    project(thiovitPanelUses()),
    [
      { crop: "GRAPE", withholding_period_days: 0 },
      { crop: "GRAPEVINE", withholding_period_days: 7 },
    ],
  );
  for (const row of carried) assertEquals(row.withholding_period_days, null);
});

Deno.test("§L4 a period the re-read genuinely states is never overwritten", () => {
  const stated = project(thiovitPanelUses()).map((r) => ({
    ...r,
    withholding_period_days: 14,
  }));
  const carried = carryForwardStatedPeriods(stated, ordinaryThiovit());
  for (const row of carried) assertEquals(row.withholding_period_days, 14);
});

Deno.test("§M REI stays unresolved — never inferred as 0", () => {
  const carried = carryForwardStatedPeriods(
    project(thiovitPanelUses()),
    ordinaryThiovit(),
  );
  for (const row of carried) {
    assertEquals(row.re_entry_period_hours, null);
    assertFalse(row.re_entry_period_hours === 0);
  }
});

Deno.test("§M2 a stated REI still carries independently of a contested WHP", () => {
  // The two fields are separate facts; one being contested says nothing about
  // the other. Preserved behaviour, re-asserted through the repair path.
  const carried = carryForwardStatedPeriods(
    project(thiovitPanelUses()),
    [
      { crop: "GRAPE", withholding_period_days: 0, re_entry_period_hours: 12 },
      { crop: "GRAPEVINE", withholding_period_days: 7, re_entry_period_hours: 12 },
    ],
  );
  for (const row of carried) {
    assertEquals(row.withholding_period_days, null);
    assertEquals(row.re_entry_period_hours, 12);
  }
});
