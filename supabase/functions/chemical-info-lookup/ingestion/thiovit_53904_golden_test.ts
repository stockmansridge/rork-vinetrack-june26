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

import { assert, assertEquals, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

import { mintDirectionId } from "../rate_identity.ts";
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
// KNOWN DEFECTS — current behaviour, pinned so Phase 3 cannot pass by accident
// ---------------------------------------------------------------------------

Deno.test("§B13 DEFECT: the projection collapses both contexts into one GRAPE use", () => {
  // EXPECTED: two Powdery Mildew uses, one per crop context.
  // ACTUAL:   one `GRAPE` / `Powdery Mildew` use carrying BOTH rates.
  // LAYER:    label extraction / registered-use projection.
  const pmUse = THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.uses.find(
    (u) => u.target_raw === "Powdery Mildew",
  );
  assert(pmUse);
  assertEquals(THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.crop, "GRAPE");
  assertEquals(pmUse.rates.length, 2, "both printed rates land on ONE use");
});

Deno.test("§B14 DEFECT: collapsed, the two directions mint the SAME identity", () => {
  // This is why the collapse is not merely cosmetic: once crop context and
  // state applicability are gone, the two registered directions are no longer
  // distinguishable by identity at all.
  const collapsed = { crop: "GRAPE", targets: ["Powdery Mildew"], condition: null };
  const a = mintDirectionId(PRODUCT, collapsed);
  const b = mintDirectionId(PRODUCT, collapsed);
  assertEquals(a, b);

  // And it differs from BOTH authoritative identities.
  const authoritative = expectedPowderyMildew().map((d) =>
    mintDirectionId(PRODUCT, {
      crop: d.crop_context,
      targets: d.targets,
      condition: d.state_applicability,
    })
  );
  for (const id of authoritative) assertNotEquals(a, id);
});

Deno.test("§B15 DEFECT: both rates are flagged condition_ambiguous", () => {
  // EXPECTED: each rate's condition is its crop context + state set, which the
  //           label states plainly, so nothing is ambiguous.
  // ACTUAL:   both flagged ambiguous because the binding was lost upstream.
  const pmUse = THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.uses.find(
    (u) => u.target_raw === "Powdery Mildew",
  )!;
  for (const r of pmUse.rates) {
    assertEquals((r as { condition_ambiguous?: boolean }).condition_ambiguous, true);
  }
});

Deno.test("§B16 DEFECT: critical comments are concatenated across both contexts", () => {
  const pmUse = THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.uses.find(
    (u) => u.target_raw === "Powdery Mildew",
  )!;
  assertEquals(
    (pmUse as { restrictions_are_concatenated_from_both_contexts?: boolean })
      .restrictions_are_concatenated_from_both_contexts,
    true,
  );
});

Deno.test("§B17 DEFECT: state applicability is dropped entirely", () => {
  // EXPECTED: every grape direction states "NSW, Vic, Tas, SA, WA only", and
  //           the same table prints Qld-only and NSW/WA-only rows elsewhere.
  // ACTUAL:   nothing in the projection carries a state at all.
  for (const d of THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS) {
    assertEquals(d.state_applicability, "NSW, Vic, Tas, SA, WA only");
  }
  assertEquals(THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.state_applicability_present, false);

  // The wire rate shape has no field to put it in — the projection is not
  // discarding data it could have carried.
  const wireRateKeys = Object.keys(
    THIOVIT_53904_ACTUAL_GRAPE_PROJECTION.uses[0].rates[0],
  );
  assert(!wireRateKeys.includes("state_applicability"));
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
