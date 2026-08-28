// P2C-B1 Fixture B — THIOVIT JET (APVMA 53904) golden label evidence.
//
// This suite freezes the AUTHORITATIVE label structure for 53904 and pins,
// as known defects, the places where the current implementation diverges from
// it. It changes no implementation and fixes nothing.
//
// Read `seeds/thiovit_53904_evidence.ts` first: it explains why the evidence
// is frozen as facts rather than as a PDF text layer.
//
// # The suite is GREEN on purpose
//
// Every divergence below is asserted as CURRENT BEHAVIOUR, in the repository's
// existing "documents the defect" style (cf. `research/linked_documents_test.ts`
// ROOT CAUSE). Nothing here is left red. The protection comes from the pairing:
// each defect assertion sits beside the expected-truth assertion it violates,
// so a Phase 3 change that keeps the collapsed output will fail the expected
// half, and a change that fixes it will fail the pinned half and must be
// updated deliberately rather than silently.

import {
  assert,
  assertEquals,
  assertFalse,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

import { mintDirectionId } from "../rate_identity.ts";
import {
  type ManufacturerLabelUse,
  manufacturerUsesToRegisteredUses,
} from "./manufacturer_label.ts";
import {
  ordinaryHasDirectionIdentityLoss,
  selectDirectionSource,
} from "./label_panel_fallback.ts";
import { THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS } from "./seeds/thiovit_53904_evidence.ts";
import {
  THIOVIT_53904_ACTUAL_GRAPE_PROJECTION,
  THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS,
  THIOVIT_53904_HISTORICAL_LABEL_EVIDENCE,
  THIOVIT_53904_IDENTITY,
  THIOVIT_53904_LABEL_DOCUMENT_EVIDENCE,
  THIOVIT_53904_MASTER_RECORD_EVIDENCE,
  THIOVIT_53904_PRODUCT_MEASUREMENT,
  THIOVIT_53904_REGISTRATION_STATUS,
  THIOVIT_53904_REI,
  THIOVIT_53904_WHP,
} from "./seeds/thiovit_53904_evidence.ts";

const PRODUCT = {
  country: THIOVIT_53904_IDENTITY.registration_country,
  scheme: THIOVIT_53904_IDENTITY.registration_scheme,
  registration_number: THIOVIT_53904_IDENTITY.registration_number,
};

const expectedPowderyMildew = () =>
  THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS.filter((d) =>
    d.targets.some((t) => /powdery mildew/i.test(t))
  );

// ---------------------------------------------------------------------------
// Evidence provenance
// ---------------------------------------------------------------------------

Deno.test("§B1 the label document is identified by content hash, not by URL", () => {
  // The sandbox cannot re-fetch the PDF, so the hash IS the fixture's anchor.
  assertEquals(
    THIOVIT_53904_LABEL_DOCUMENT_EVIDENCE.sha256,
    "91baafb160706a46497ef517968f707153d7b8cea1b37c9fcce3f240381c7ce0",
  );
  assertEquals(THIOVIT_53904_LABEL_DOCUMENT_EVIDENCE.byte_size, 289840);
});

Deno.test("§B2 the historical mirror is marked corroborating, never current", () => {
  // A 2006 revision must never be able to masquerade as the current label.
  assertEquals(THIOVIT_53904_HISTORICAL_LABEL_EVIDENCE.authority, "corroborating_only");
});

Deno.test("§B3 identity is stable and independent of legal status", () => {
  assertEquals(THIOVIT_53904_IDENTITY.registration_identity_key, "AU:apvma:53904");
  assertEquals(
    THIOVIT_53904_IDENTITY.registered_product_name,
    "THIOVIT JET MICROGRANULE FUNGICIDE/MITICIDE",
  );
});

// ---------------------------------------------------------------------------
// Physical form, formulation and units are FIVE separate facts
// ---------------------------------------------------------------------------

Deno.test("§B4 physical form is solid, from the OFFICIAL REGISTER", () => {
  // CORRECTED in Phase 3A. This previously recorded manufacturer-primary
  // provenance, which was wrong: the APVMA adapter maps the register's own
  // `fdesc` field (mapFormType), and the live PubCRIS row for 53904 publishes
  // fdesc = "MICROGRANULE". `thiovit_53904_phase3a_audit_test.ts` §3A-2 proves
  // it by executing the real adapter with no label document, no manufacturer
  // page and no AI reachable at all.
  assertEquals(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form, "solid");
  assertEquals(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form_provenance, "official_register");
  // The manufacturer label agrees, but agreement is corroboration.
  assert(/manufacturer_label/.test(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form_corroboration));
  // The live master row already holds it — so a downstream "Liquid" is a loss
  // occurring BELOW an authoritative register value, not an absence of one.
  assertEquals(THIOVIT_53904_MASTER_RECORD_EVIDENCE.form_type, "solid");
});

Deno.test("§B5 a g/100 L rate never implies a liquid product", () => {
  const m = THIOVIT_53904_PRODUCT_MEASUREMENT;
  // Rate unit, inventory unit, concentration unit and physical form are four
  // independent answers. Deriving any from another is the bug this pins.
  assertEquals(m.rate_unit, "g");
  assertEquals(m.rate_basis, "per_100_litres");
  assertEquals(m.inventory_unit, "kg");
  assertEquals(m.active_concentration_unit, "g/kg");
  assertEquals(m.physical_form, "solid");
  assertNotEquals(m.rate_unit as string, m.inventory_unit as string);
});

Deno.test("§B6 formulation wording is preserved beside the canonical form", () => {
  assert(/microgranule/i.test(THIOVIT_53904_PRODUCT_MEASUREMENT.formulation_text));
  assert(/water-dispersible granule/i.test(THIOVIT_53904_PRODUCT_MEASUREMENT.formulation_text));
  assertEquals(THIOVIT_53904_PRODUCT_MEASUREMENT.active_concentration, 800);
});

Deno.test("§B7 DEFECT: product category is unresolved and is NOT invented", () => {
  // EXPECTED: a deterministic category from PubCRIS.
  // ACTUAL:   null. Recorded as null rather than guessed.
  //
  // Phase 3A CORRECTED the cause: `hlevel1` IS consumed by mapCategory(). The
  // register's own value is "MIXED FUNCTION PESTICIDE", which matches none of
  // the mapper's category words, so it correctly declines. A vocabulary gap
  // over a combined classification — not an unconsumed field. See §3A-5/§3A-7.
  assertEquals(THIOVIT_53904_MASTER_RECORD_EVIDENCE.product_category, null);
});

// ---------------------------------------------------------------------------
// The two Powdery Mildew directions are DISTINCT registered uses
// ---------------------------------------------------------------------------

Deno.test("§B8 the label states two grape crop contexts, not one", () => {
  const contexts = new Set(THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS.map((d) => d.crop_context));
  assertEquals(contexts.size, 2);
  assert(contexts.has("Grapes table grapes, fruit destined for drying"));
  assert(contexts.has("Grapes Vines wine grapes only"));
});

Deno.test("§B9 table/drying grapes and wine grapes carry DIFFERENT PM ranges", () => {
  const pm = expectedPowderyMildew();
  assertEquals(pm.length, 2);

  const table = pm.find((d) => /table grapes/i.test(d.crop_context));
  const wine = pm.find((d) => /wine grapes only/i.test(d.crop_context));
  assert(table && wine);

  assertEquals([table.min_value, table.max_value], [100, 200]);
  assertEquals([wine.min_value, wine.max_value], [200, 600]);
  assertEquals(table.unit, "g");
  assertEquals(wine.unit, "g");
  assertEquals(table.basis, "range_per_100_litres");
  assertEquals(wine.basis, "range_per_100_litres");
});

Deno.test("§B10 the two PM directions must NEVER merge into 100-600 g/100 L", () => {
  const pm = expectedPowderyMildew();
  const mins = pm.map((d) => d.min_value);
  const maxes = pm.map((d) => d.max_value);
  // A union range would read 100-600. No direction may span it.
  for (const d of pm) {
    assert(
      !(d.min_value === 100 && d.max_value === 600),
      "the union range 100-600 is not a registered direction",
    );
  }
  assertEquals(new Set(mins).size, 2);
  assertEquals(new Set(maxes).size, 2);
});

Deno.test("§B11 each PM direction keeps ONLY its own critical comments", () => {
  const pm = expectedPowderyMildew();
  const table = pm.find((d) => /table grapes/i.test(d.crop_context))!;
  const wine = pm.find((d) => /wine grapes only/i.test(d.crop_context))!;

  // The table-grape interval is 2-3 weeks; the wine-grape interval is 14-21
  // days. Neither direction may carry the other's wording.
  assert(/every 2 to 3 weeks/i.test(table.critical_comments));
  assert(!/14 to 21 days/i.test(table.critical_comments));

  assert(/every 14 to 21 days/i.test(wine.critical_comments));
  assert(/upper end of the rate range/i.test(wine.critical_comments));
  assert(!/every 2 to 3 weeks/i.test(wine.critical_comments));
});

Deno.test("§B12 with crop context preserved, the two PM directions mint DIFFERENT identities", () => {
  const pm = expectedPowderyMildew();
  const ids = pm.map((d) =>
    mintDirectionId(PRODUCT, {
      crop: d.crop_context,
      targets: d.targets,
      condition: d.state_applicability,
    })
  );
  assertEquals(new Set(ids).size, 2, "two printed directions are two identities");
});

// ---------------------------------------------------------------------------
// REPAIRED BEHAVIOUR — converted from the Phase 2B defect pins (Gate D4A.3.2)
//
// §B13–§B17 previously asserted the COLLAPSED output as current behaviour, so
// that a fix could not land silently. Phase 3B implemented the repair, so each
// has been converted — deliberately, not deleted — into the positive assertion
// it was protecting. `THIOVIT_53904_ACTUAL_GRAPE_PROJECTION` is retained as
// the historical record of the defect and is now used as the ANTI-PATTERN each
// test asserts we no longer produce, which is what makes these permanent
// recurrence protection rather than one-off acceptance checks.
// ---------------------------------------------------------------------------

/** The two authoritative PM directions in the parser's own vocabulary. */
function repairedDirections(): ManufacturerLabelUse[] {
  return expectedPowderyMildew().map((d) => ({
    crop: d.crop_context,
    targets: [...d.targets],
    condition: d.state_applicability,
    rates: [{
      label: "",
      basis: "range_per_100_litres" as const,
      min_value: d.min_value,
      max_value: d.max_value,
      unit: d.unit,
      raw_text: `${d.min_value}-${d.max_value} ${d.unit}/100 L`,
    }],
    restrictions: d.critical_comments,
  }));
}

const repairedRows = (): Record<string, unknown>[] =>
  manufacturerUsesToRegisteredUses(repairedDirections(), { product: PRODUCT });

Deno.test("§B13 REPAIRED: the two crop contexts stay distinct instead of collapsing", () => {
  const rows = repairedRows();
  const contexts = new Set(rows.map((r) => String(r.crop)));
  assertEquals(contexts.size, 2);
  assert(contexts.has("Grapes table grapes, fruit destined for drying"));
  assert(contexts.has("Grapes Vines wine grapes only"));

  // The anti-pattern: never again ONE "GRAPE" use carrying BOTH printed rates.
  assertFalse(contexts.has(THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.crop));
  for (const row of rows) assertEquals((row.rates as unknown[]).length, 1);
});

Deno.test("§B14 REPAIRED: the two directions mint DIFFERENT identities", () => {
  const ids = new Set(repairedRows().map((r) => String(r.direction_id)));
  assertEquals(ids.size, 2, "two printed directions are two identities");

  // The collapsed identity is what the defect produced, and it matched NEITHER
  // authoritative direction. It must never be minted again.
  const collapsed = mintDirectionId(PRODUCT, {
    crop: "GRAPE",
    targets: ["Powdery Mildew"],
    condition: null,
  });
  for (const id of ids) assertNotEquals(id, collapsed);

  // Each equals the identity minted from the authoritative direction itself.
  const authoritative = new Set(
    expectedPowderyMildew().map((d) =>
      mintDirectionId(PRODUCT, {
        crop: d.crop_context,
        targets: d.targets,
        condition: d.state_applicability,
      })
    ),
  );
  assertEquals(ids, authoritative);
});

Deno.test("§B15 REPAIRED: condition_ambiguous is ABSENT once the association is proven", () => {
  // The flag was never a statement about the numbers; it recorded that the
  // binding was unproven. With each rate bound to its own printed direction
  // there is nothing left to be ambiguous about, so the flag must not appear.
  for (const row of repairedRows()) {
    for (const r of row.rates as { condition_ambiguous?: boolean }[]) {
      assertFalse(r.condition_ambiguous === true);
    }
  }

  // And the collapsed rows production used to serve still declare the loss,
  // which is exactly the signal the routing gate now acts on.
  assert(ordinaryHasDirectionIdentityLoss(THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS));
});

Deno.test("§B16 REPAIRED: critical comments stay scoped to their own direction", () => {
  const rows = repairedRows();
  const table = rows.filter((r) => /table grapes/i.test(String(r.crop)));
  const wine = rows.filter((r) => /wine grapes only/i.test(String(r.crop)));
  assert(table.length > 0 && wine.length > 0);

  for (const row of table) {
    assert(/every 2 to 3 weeks/i.test(String(row.restrictions)));
    assertFalse(/14 to 21 days/i.test(String(row.restrictions)));
  }
  for (const row of wine) {
    assert(/every 14 to 21 days/i.test(String(row.restrictions)));
    assertFalse(/every 2 to 3 weeks/i.test(String(row.restrictions)));
  }
});

Deno.test("§B17 REPAIRED: state applicability survives on the direction row", () => {
  for (const d of THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS) {
    assertEquals(d.state_applicability, "NSW, Vic, Tas, SA, WA only");
  }

  // Phase 2B flagged the contract-level gap: the wire rate shape had NO field
  // for a state, so the projection was not discarding data it could carry.
  // Phase 3B added the field at the DIRECTION level, where the fact belongs.
  for (const row of repairedRows()) {
    assertEquals(row.condition, "NSW, Vic, Tas, SA, WA only");
    // ...and it remains in rate.label too, so shipping clients keep working
    // until they migrate to the direction-level field.
    for (const r of row.rates as { label?: string }[]) {
      assertEquals(r.label, "NSW, Vic, Tas, SA, WA only");
    }
  }

  // The historical projection carried no state anywhere — retained as the
  // anti-pattern this test exists to prevent recurring.
  assertEquals(THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.state_applicability_present, false);
});

Deno.test("§B17b REPAIRED: the routing gate actually selects the repaired reading", () => {
  // End-to-end over the real decision function, from the exact collapsed rows
  // production serves today to the repaired candidate.
  const decision = selectDirectionSource({
    ordinaryUses: THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS,
    panelUses: repairedRows(),
    product: PRODUCT,
  });
  assertEquals(decision.replace, true);
  assertEquals(decision.outcome, "identity_repair");
  assertEquals(decision.comparison?.ordinaryDirectionCount, 1);
  assertEquals(decision.comparison?.panelDirectionCount, 2);
  assertEquals(decision.comparison?.lostRateSignatures, []);
});

// ---------------------------------------------------------------------------
// WHP, REI and registration status
// ---------------------------------------------------------------------------

Deno.test("§B18 WHP keeps its legal wording, not just the number", () => {
  assertEquals(THIOVIT_53904_WHP.display_wording, "Not required when used as directed");
  assert(/NOT REQUIRED WHEN USED AS DIRECTED/i.test(THIOVIT_53904_WHP.statement));
  // 0 is the conservative projection of "not required" and must not be the
  // only surviving representation: it loses "when used as directed".
  assertEquals(THIOVIT_53904_WHP.projected_days, 0);
  assert(THIOVIT_53904_WHP.display_wording.length > 0);
});

Deno.test("§B19 REI is unresolved — never inferred as zero", () => {
  assertEquals(THIOVIT_53904_REI.hours, null);
  assertEquals(THIOVIT_53904_REI.statement, null);
  assertEquals(THIOVIT_53904_REI.resolution, "unresolved_not_stated");
  // AWRI publishes code "a"; no authoritative code->hours mapping exists here,
  // so the code is recorded and deliberately NOT resolved.
  assertEquals(THIOVIT_53904_REI.awri_re_entry_code, "a");
  assertNotEquals(THIOVIT_53904_REI.hours as number | null, 0);
});

Deno.test("§B20 registration status keeps raw facts apart from any conclusion", () => {
  assertEquals(THIOVIT_53904_REGISTRATION_STATUS.registration_code_raw, "R");
  assertEquals(THIOVIT_53904_REGISTRATION_STATUS.registration_expiry_raw, "30/06/2026");
  // "Expired" is NOT derived from the clock, and "R" is not overwritten.
  assertEquals(THIOVIT_53904_REGISTRATION_STATUS.semantic_status, "UNRESOLVED_CURRENT_STATUS");
});

Deno.test("§B21 label evidence is not blocked by the status ambiguity", () => {
  // Legal status and label content are independent dimensions: the directions
  // above stand regardless of how the renewal question resolves.
  assertEquals(THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS.length, 4);
  assertEquals(THIOVIT_53904_REGISTRATION_STATUS.semantic_status, "UNRESOLVED_CURRENT_STATUS");
});
