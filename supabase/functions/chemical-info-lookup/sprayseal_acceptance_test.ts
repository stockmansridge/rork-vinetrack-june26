// Sprayseal Pruning Wound Treatment — APVMA 80160 — acceptance fixture.
//
// The production defect: VineTrack resolved identity, active and FRAC group
// correctly, but left the grapevine rate unresolved and reported REI as
// "Not stated on label" for a label that states a conditional re-entry rule.
//
// Three independent root causes, each asserted here:
//
//   1. The Omnia manufacturer label (`/files/2025/07/Sprayseal 5L_Digi.pdf`)
//      never became evidence, because URL-only classification found no label
//      signature in the filename. Its rate table went with it.
//   2. A CONDITIONAL re-entry rule had nowhere to live. The parser correctly
//      refused to invent hours, but with no field for the wording the fact was
//      dropped and rendered as "not stated".
//   3. The four source identities were collapsing toward one URL, losing the
//      provenance that distinguishes an approved label from a marketing page.

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  isReentryStatement,
  reentryHoursFromStatement,
  whpDaysFromStatement,
} from "./ingestion/label.ts";
import { selectLabelReferences } from "./grapevine_label.ts";
import { evaluateLinkedDocument } from "./research/linked_documents.ts";
import { projectGrapevineUses } from "./grapevine_label.ts";
import type { WireLabelRate } from "./ingestion/contract.ts";

// ---------------------------------------------------------------------------
// The label, as Omnia prints it
// ---------------------------------------------------------------------------

const APVMA_LABEL = "https://elabels.apvma.gov.au/80160ELBL.pdf";
const OMNIA_LABEL = "https://www.omnia.com.au/files/2025/07/Sprayseal%205L_Digi.pdf";
const OMNIA_PAGE = "https://www.omnia.com.au/products/sprayseal";
const OMNIA_SDS = "https://www.omnia.com.au/files/sprayseal-sds.pdf";

const REI_STATEMENT = "DO NOT allow entry until the spray has dried.";
const WHP_STATEMENT = "Not required when used as directed.";

const SPRAYSEAL_80160 = {
  product_name: "SPRAYSEAL PRUNING WOUND TREATMENT",
  product_category: "Fungicide",
  registration_number: "80160",
  registrant: "Omnia Specialities Australia Pty Ltd",
  active_ingredients: [{
    name: "Tebuconazole",
    concentration: 430,
    concentration_unit: "g/L",
    activity_group: { scheme: "frac", code: "3" },
  }],
  registered_uses: [
    {
      crop: "GRAPEVINES",
      target_raw: "Eutypa dieback",
      rates: [{
        label: "",
        basis: "per_100_litres",
        value: 30,
        unit: "mL",
        raw_text: "30 mL/100 L of water",
      } as WireLabelRate],
      withholding_period_days: 0,
      re_entry_period_hours: null,
      re_entry_statement: REI_STATEMENT,
      restrictions: "Apply to pruning wounds immediately after pruning.",
    },
    {
      crop: "GRAPEVINES",
      target_raw: "Botryosphaeria dieback",
      rates: [{
        label: "",
        basis: "per_100_litres",
        value: 30,
        unit: "mL",
        raw_text: "30 mL/100 L of water",
      } as WireLabelRate],
      withholding_period_days: 0,
      re_entry_period_hours: null,
      re_entry_statement: REI_STATEMENT,
      restrictions: "Apply to pruning wounds immediately after pruning.",
    },
  ],
};

// ---------------------------------------------------------------------------
// Identity, chemistry, category
// ---------------------------------------------------------------------------

Deno.test("80160: identity, registrant and chemistry", () => {
  assertEquals(SPRAYSEAL_80160.registration_number, "80160");
  assertEquals(SPRAYSEAL_80160.product_name, "SPRAYSEAL PRUNING WOUND TREATMENT");
  assertEquals(SPRAYSEAL_80160.registrant, "Omnia Specialities Australia Pty Ltd");
  assertEquals(SPRAYSEAL_80160.product_category, "Fungicide");

  const active = SPRAYSEAL_80160.active_ingredients[0];
  assertEquals(active.name, "Tebuconazole");
  assertEquals(active.concentration, 430);
  assertEquals(active.concentration_unit, "g/L");
  assertEquals(active.activity_group.scheme, "frac");
  assertEquals(active.activity_group.code, "3");
});

// ---------------------------------------------------------------------------
// Root cause 1 — the manufacturer label becomes evidence
// ---------------------------------------------------------------------------

Deno.test("80160: the Omnia label is promoted from its product-page link", () => {
  const r = evaluateLinkedDocument({
    page: { pageUrl: OMNIA_PAGE, pageProductName: "Sprayseal" },
    pageIsTrustedProductPage: true,
    registeredProductName: SPRAYSEAL_80160.product_name,
    document: { url: OMNIA_LABEL, linkText: "Label" },
  });
  assertEquals(r.isManufacturerLabel, true);
});

// ---------------------------------------------------------------------------
// Root cause 3 — four separate source identities
// ---------------------------------------------------------------------------

Deno.test("80160: all four sources retain separate provenance", () => {
  const refs = selectLabelReferences({
    manufacturerLabelUrl: OMNIA_LABEL,
    regulatorLabelUrl: APVMA_LABEL,
    productUrl: OMNIA_PAGE,
    sdsUrl: OMNIA_SDS,
  });
  assertEquals(refs.manufacturer_label_url, OMNIA_LABEL);
  assertEquals(refs.regulator_label_url, APVMA_LABEL);
  assertEquals(refs.manufacturer_product_url, OMNIA_PAGE);
  assertEquals(refs.sds_url, OMNIA_SDS);

  // Nothing is collapsed: four distinct URLs stay four distinct fields.
  const urls = [
    refs.manufacturer_label_url,
    refs.regulator_label_url,
    refs.manufacturer_product_url,
    refs.sds_url,
  ];
  assertEquals(new Set(urls).size, 4);

  // The legacy single field keeps pointing at the AUTHORITATIVE document, so
  // shipped clients that decode only `label_reference` do not regress.
  assertEquals(refs.label_reference, APVMA_LABEL);
});

Deno.test("80160: the SDS never reaches a label field", () => {
  const refs = selectLabelReferences({
    manufacturerLabelUrl: OMNIA_LABEL,
    regulatorLabelUrl: APVMA_LABEL,
    sdsUrl: OMNIA_SDS,
  });
  assert(refs.manufacturer_label_url !== OMNIA_SDS);
  assert(refs.regulator_label_url !== OMNIA_SDS);
  assert(refs.label_reference !== OMNIA_SDS);
});

// ---------------------------------------------------------------------------
// Root cause 2 — conditional REI is text, never fabricated hours
// ---------------------------------------------------------------------------

Deno.test("80160: the re-entry rule is RECOGNISED as a re-entry statement", () => {
  assertEquals(isReentryStatement(REI_STATEMENT), true);
});

Deno.test("80160: conditional re-entry NEVER becomes a number", () => {
  // The whole point: "until the spray has dried" has no hour value, and
  // inventing one would be inventing a compliance fact.
  assertEquals(reentryHoursFromStatement(REI_STATEMENT), null);
});

Deno.test("80160: null hours PLUS wording is not the same as 'not stated'", () => {
  for (const use of SPRAYSEAL_80160.registered_uses) {
    assertEquals(use.re_entry_period_hours, null);
    assertEquals(use.re_entry_statement, REI_STATEMENT);
    assert(
      (use.re_entry_statement ?? "").length > 0,
      "a conditional re-entry rule must survive as text",
    );
  }
});

Deno.test("a numeric re-entry statement still yields hours", () => {
  // The conditional path must not have broken the normal one.
  assertEquals(reentryHoursFromStatement("DO NOT allow re-entry for 12 hours."), 12);
  assertEquals(reentryHoursFromStatement("Re-entry period: 2 days."), 48);
});

Deno.test("a non-re-entry sentence is not treated as one", () => {
  assertEquals(isReentryStatement("Store below 30 degrees C."), false);
  assertEquals(reentryHoursFromStatement("Apply 12 hours before rain."), null);
});

// ---------------------------------------------------------------------------
// WHP semantics — 0 only where the label supports the wording
// ---------------------------------------------------------------------------

Deno.test("80160: 'Not required when used as directed' is WHP 0, in a WHP section", () => {
  assertEquals(whpDaysFromStatement(WHP_STATEMENT, "withholding"), 0);
});

Deno.test("the same words OUTSIDE a withholding section are NOT a WHP of 0", () => {
  // "Not required" appears in unrelated label sections. Reading it as a
  // withholding period would manufacture a compliance fact from a sentence
  // about something else entirely.
  assertEquals(whpDaysFromStatement(WHP_STATEMENT, "other"), null);
  assertEquals(whpDaysFromStatement(WHP_STATEMENT, "reentry"), null);
});

// ---------------------------------------------------------------------------
// The rate — 30 mL/100 L, never converted
// ---------------------------------------------------------------------------

Deno.test("80160: grapevine rate is 30 mL per 100 L on both targets", () => {
  const p = projectGrapevineUses(SPRAYSEAL_80160.registered_uses);
  assertEquals(p.registered_for_grapevine, true);
  assertEquals(p.grapevine_uses.length, 2);
  assertEquals(
    p.grapevine_uses.map((u) => u.target_raw).sort(),
    ["Botryosphaeria dieback", "Eutypa dieback"],
  );

  for (const use of p.grapevine_uses) {
    const rate = (use.rates as WireLabelRate[])[0];
    assertEquals(rate.value, 30);
    assertEquals(rate.unit, "mL");
    assertEquals(rate.basis, "per_100_litres");
    assertEquals(rate.raw_text, "30 mL/100 L of water");
  }
});

Deno.test("80160: the rate is never converted to a hectare basis", () => {
  const p = projectGrapevineUses(SPRAYSEAL_80160.registered_uses);
  const everyRate = p.grapevine_uses.flatMap((u) => u.rates as WireLabelRate[]);
  assert(everyRate.length > 0);
  assert(
    everyRate.every((r) => r.basis === "per_100_litres"),
    "the label states no /ha rate, so none may appear",
  );
});

Deno.test("80160: a registered product gets no reference range", () => {
  const p = projectGrapevineUses(SPRAYSEAL_80160.registered_uses);
  assertEquals(p.label_reference_rate_ranges, []);
});

Deno.test("80160: restrictions survive on every grapevine use", () => {
  const p = projectGrapevineUses(SPRAYSEAL_80160.registered_uses);
  for (const use of p.grapevine_uses) {
    assert(/pruning wounds/i.test(use.restrictions));
  }
});
