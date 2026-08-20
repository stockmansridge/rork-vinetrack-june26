// Stage 5F audit tests — the auditor must re-derive everything it can,
// fail closed on every drift/lapse/collision, and never write anywhere.

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  auditDeterministicMatches,
  crossCheckNamesAgainstActiveNames,
  explainActives,
  formatAuditReport,
  hasTypographySplit,
  parseExpdateIso,
  reverifyTierStructure,
  variantTokensOf,
  type AuditInput,
} from "./seed_awri_audit.ts";
import type { RegisterActive, Stage5EResolution } from "./seed_awri_match.ts";
import type { RegisterProductRow } from "./seed_awri.ts";

// ---------------------------------------------------------------------------
// Fixture: ACME Alpha Cyper 300 SC — a clean registrant_prefix deterministic
// ---------------------------------------------------------------------------

function detItem(overrides: Partial<Stage5EResolution> = {}): Stage5EResolution {
  return {
    awri_product_name: "Alpha Cyper 300 SC",
    expansion: "plain",
    sections: ["insecticide"],
    match_class: "deterministic_match",
    tier: "registrant_prefix",
    corroboration: "pass",
    tie_broken_by_register_facts: false,
    matched: {
      registration_number: "70001",
      registration_identity_key: "AU:apvma:70001",
      registered_product_name: "ACME Alpha Cyper 300 SC Insecticide",
      registrant: "ACME CHEMICALS PTY LTD",
      register_status: "R, expires 30/06/2026 0:00",
    },
    ambiguous_rows: [],
    identity_already_in_master: false,
    ...overrides,
  };
}

function liveRow(overrides: Partial<RegisterProductRow> = {}): RegisterProductRow {
  return {
    pcode: "70001",
    fpname: "ACME Alpha Cyper 300 SC Insecticide",
    sname: "ACME CHEMICALS PTY LTD",
    hlevel1: "INSECTICIDE",
    fdesc: "SUSPENSION CONCENTRATE",
    regcode: "R",
    expdate: "30/06/2026 0:00",
    ...overrides,
  };
}

const ACTIVES: RegisterActive[] = [{ name: "ALPHA-CYPERMETHRIN", amount: 300 }];

function baseInput(overrides: Partial<AuditInput> = {}): AuditInput {
  return {
    deterministic: [detItem()],
    manifestActivesByName: new Map([["Alpha Cyper 300 SC", ["alpha-cypermethrin"]]]),
    liveRowsByPcode: new Map([["70001", liveRow()]]),
    liveActivesByPcode: new Map([["70001", ACTIVES]]),
    existingIdentities: new Set<string>(),
    extractDate: "2026-06-25",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------

Deno.test("F01: clean deterministic match approves with full evidence — camount-verified strength, reproduced tier, current registration", () => {
  const result = auditDeterministicMatches(baseInput());
  assertEquals(result.items.length, 1);
  const item = result.items[0];
  assertEquals(item.decision, "approve_for_seed");
  assertEquals(item.reject_reasons, []);
  assertEquals(Object.values(item.checks).every(Boolean), true);
  assertEquals(item.registration_status.classification, "current_in_extract");
  assertEquals(item.registrant_prefix_words, 1);
  assertEquals(item.active_strength_corroboration.verdict, "pass");
  assertEquals(item.active_strength_corroboration.awri_numeric_evidence, [
    { token: "300", evidence: "camount:300" },
  ]);
  assertEquals(item.active_strength_corroboration.matched_constituents, [
    {
      manifest_active: "alpha-cypermethrin",
      register_constituents: [{ name: "ALPHA-CYPERMETHRIN", camount: 300 }],
    },
  ]);
  assertEquals(result.counts.approve_for_seed, 1);
  assertEquals(result.counts.archived_or_lapsed, 0);
});

Deno.test("F02: expiry 30/06/2026 against the 2026-06-25 extract is CURRENT — the mass pre-rollover case is never misread as lapsed", () => {
  const result = auditDeterministicMatches(baseInput());
  const status = result.items[0].registration_status;
  assertEquals(status.expdate, "30/06/2026 0:00");
  assertEquals(status.classification, "current_in_extract");
  assertEquals(result.items[0].checks.registration_current, true);
});

Deno.test("F03: expiry BEFORE the extract date is lapsed — rejected and counted archived/lapsed", () => {
  const result = auditDeterministicMatches(baseInput({
    liveRowsByPcode: new Map([["70001", liveRow({ expdate: "17/11/2025 0:00" })]]),
  }));
  const item = result.items[0];
  assertEquals(item.registration_status.classification, "lapsed_before_extract");
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.some((r) => r.startsWith("registration_lapsed_before_extract")));
  assertEquals(result.counts.archived_or_lapsed, 1);
});

Deno.test("F04: registration missing from the live register is removed/archived — rejected", () => {
  const result = auditDeterministicMatches(baseInput({ liveRowsByPcode: new Map() }));
  const item = result.items[0];
  assertEquals(item.registration_status.classification, "removed_from_current_register");
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("registration_removed_from_current_register"));
  assertEquals(result.counts.archived_or_lapsed, 1);
});

Deno.test("F05: live regcode other than R never passes — an active-constituent row can never stand in for a product", () => {
  const result = auditDeterministicMatches(baseInput({
    liveRowsByPcode: new Map([["70001", liveRow({ regcode: "A" })]]),
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("live_regcode_not_R:A"));
  assertEquals(item.registration_status.classification, "removed_from_current_register");
});

Deno.test("F06: live product-name drift rejects — the audited row must be exactly the matched row", () => {
  const result = auditDeterministicMatches(baseInput({
    liveRowsByPcode: new Map([
      ["70001", liveRow({ fpname: "ACME Alpha Cyper 300 SC Insecticide NEW FORMULA" })],
    ]),
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("live_register_drift:product_name"));
});

Deno.test("F07: live registrant drift rejects — holder transfer means re-verification, not silent approval", () => {
  const result = auditDeterministicMatches(baseInput({
    liveRowsByPcode: new Map([["70001", liveRow({ sname: "OTHERCORP PTY LTD" })]]),
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("live_register_drift:registrant"));
  // Structure is re-verified against the live holder too, so it also fails.
  assertEquals(item.checks.tier_structure_reproduced, false);
});

Deno.test("F08: variant guard is independent — a fabricated 'Custodia' → 'CUSTODIA FORTE' artifact row is rejected on variant AND structure", () => {
  const result = auditDeterministicMatches(baseInput({
    deterministic: [detItem({
      awri_product_name: "Custodia",
      matched: {
        registration_number: "70001",
        registration_identity_key: "AU:apvma:70001",
        registered_product_name: "ACME Custodia Forte Fungicide",
        registrant: "ACME CHEMICALS PTY LTD",
        register_status: "R, expires 30/06/2026 0:00",
      },
    })],
    manifestActivesByName: new Map([["Custodia", []]]),
    liveRowsByPcode: new Map([
      ["70001", liveRow({ fpname: "ACME Custodia Forte Fungicide" })],
    ]),
    liveActivesByPcode: new Map(),
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("variant_token_mismatch"));
  assert(item.reject_reasons.includes("tier_structure_not_reproducible"));
  assertEquals(item.variant_token_check.awri_variant_tokens, []);
  assertEquals(item.variant_token_check.register_variant_tokens, ["forte"]);
});

Deno.test("F09: recomputed corroboration mismatch on live data rejects — wrong active means wrong product", () => {
  const result = auditDeterministicMatches(baseInput({
    liveActivesByPcode: new Map([["70001", [{ name: "DIFENOCONAZOLE", amount: 250 }]]]),
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("active_constituent_mismatch"));
  assertEquals(item.active_strength_corroboration.verdict, "mismatch");
});

Deno.test("F10: missing live constituent data downgrades to reject — a deterministic approval requires recomputed corroboration", () => {
  const result = auditDeterministicMatches(baseInput({
    liveActivesByPcode: new Map(),
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("corroboration_unknown_on_live_data"));
});

Deno.test("F11: register-side extra strength is surfaced — camount-verified extras keep approval with a penalty; unverifiable extras penalise harder", () => {
  const make = (amount: number): AuditInput =>
    baseInput({
      deterministic: [detItem({
        awri_product_name: "Top Sulphur",
        matched: {
          registration_number: "70001",
          registration_identity_key: "AU:apvma:70001",
          registered_product_name: "ACME Top Sulphur 800 WG Fungicide",
          registrant: "ACME CHEMICALS PTY LTD",
          register_status: "R, expires 30/06/2026 0:00",
        },
      })],
      manifestActivesByName: new Map([["Top Sulphur", ["sulphur"]]]),
      liveRowsByPcode: new Map([
        ["70001", liveRow({ fpname: "ACME Top Sulphur 800 WG Fungicide" })],
      ]),
      liveActivesByPcode: new Map([["70001", [{ name: "SULFUR", amount }]]]),
    });

  const verified = auditDeterministicMatches(make(800)).items[0];
  assertEquals(verified.decision, "approve_for_seed");
  assertEquals(verified.active_strength_corroboration.register_extra_numerics, [
    { token: "800", evidence: "camount_verified" },
  ]);
  assertEquals(verified.strength_breakdown.register_extra_numeric_penalty, -2);
  assert(verified.notes.some((n) => n.includes("register name states strength")));

  const unverified = auditDeterministicMatches(make(500)).items[0];
  assertEquals(unverified.decision, "approve_for_seed"); // actives still corroborate via alias
  assertEquals(unverified.active_strength_corroboration.register_extra_numerics, [
    { token: "800", evidence: "not_in_awri_name_or_camount" },
  ]);
  assertEquals(unverified.strength_breakdown.register_extra_numeric_penalty, -4);
  assert(unverified.strength_score < verified.strength_score);
});

Deno.test("F12: identity already in Master Chemicals rejects — aliases never become new seed rows", () => {
  const result = auditDeterministicMatches(baseInput({
    existingIdentities: new Set(["AU:apvma:70001"]),
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.includes("identity_already_in_master_chemicals"));
  assertEquals(result.counts.master_collisions, 1);
});

Deno.test("F13: two AWRI names on one registration keep only the strongest — the other is rejected as a duplicate alias, counts stay consistent", () => {
  const shared = {
    registration_number: "87040",
    registration_identity_key: "AU:apvma:87040",
    registered_product_name: "Four Seasons Agribusiness Dry GLY 680 WG Herbicide",
    registrant: "FOUR SEASONS AGRIBUSINESS PTY LTD",
    register_status: "R, expires 30/06/2026 0:00",
  };
  const glyActives: RegisterActive[] = [{ name: "GLYPHOSATE", amount: 680 }];
  const result = auditDeterministicMatches(baseInput({
    deterministic: [
      detItem({ awri_product_name: "Dry GLY 680", matched: { ...shared } }),
      detItem({ awri_product_name: "Dry GLY 680 WG", matched: { ...shared } }),
    ],
    manifestActivesByName: new Map([
      ["Dry GLY 680", ["glyphosate"]],
      ["Dry GLY 680 WG", ["glyphosate"]],
    ]),
    liveRowsByPcode: new Map([[
      "87040",
      liveRow({
        pcode: "87040",
        fpname: "Four Seasons Agribusiness Dry GLY 680 WG Herbicide",
        sname: "FOUR SEASONS AGRIBUSINESS PTY LTD",
      }),
    ]]),
    liveActivesByPcode: new Map([["87040", glyActives]]),
  }));

  assertEquals(result.counts.total_audited, 2);
  assertEquals(result.counts.approve_for_seed, 1);
  assertEquals(result.counts.rejected, 1);
  assertEquals(result.counts.duplicate_identities, 1);
  assertEquals(result.counts.distinct_identities_approved, 1);
  const kept = result.items.find((i) => i.decision === "approve_for_seed");
  const dropped = result.items.find((i) => i.decision === "reject");
  assertEquals(kept?.awri_product_name, "Dry GLY 680 WG"); // more specific name wins
  assert(dropped?.reject_reasons.some((r) => r === "duplicate_alias_of:Dry GLY 680 WG"));
  assertEquals(dropped?.checks.not_duplicate_alias, false);
});

Deno.test("F14: a non-deterministic item slipping into the input fails integrity and flips the invariant", () => {
  const result = auditDeterministicMatches(baseInput({
    deterministic: [detItem({ match_class: "probable_manual_review", tier: "token_subsequence" })],
  }));
  const item = result.items[0];
  assertEquals(item.decision, "reject");
  assert(item.reject_reasons.some((r) => r.startsWith("artifact_integrity")));
  assertEquals(result.invariants.deterministic_input_only, "FAIL");
});

Deno.test("F15: the audit is pure — identical inputs produce identical output, and it declares zero writes", () => {
  const a = auditDeterministicMatches(baseInput());
  const b = auditDeterministicMatches(baseInput());
  assertEquals(a, b);
  assertEquals(a.counts.database_changes, 0);
  assertEquals(a.counts.production_writes, 0);
  assertEquals(a.invariants.no_database_writes, "PASS");
  assertEquals(a.invariants.probable_batch_untouched, "PASS");
  assertEquals(a.invariants.decisions_only_approve_or_reject, "PASS");
  assert(a.items.every((i) => i.decision === "approve_for_seed" || i.decision === "reject"));
});

Deno.test("F16: strength ranking orders exact-name evidence above deep registrant prefixes — strongest/weakest lists reflect it", () => {
  const exact = detItem({
    awri_product_name: "Glister 680 SG",
    tier: "exact_name",
    matched: {
      registration_number: "60560",
      registration_identity_key: "AU:apvma:60560",
      registered_product_name: "Glister 680 SG",
      registrant: "SOMECO PTY LTD",
      register_status: "R, expires 30/06/2026 0:00",
    },
  });
  const deepPrefix = detItem({
    awri_product_name: "Cyper 300",
    matched: {
      registration_number: "70002",
      registration_identity_key: "AU:apvma:70002",
      registered_product_name: "Very Long Holder Cyper 300 Insecticide",
      registrant: "VERY LONG HOLDER PTY LTD",
      register_status: "R, expires 30/06/2026 0:00",
    },
  });
  const result = auditDeterministicMatches(baseInput({
    deterministic: [exact, deepPrefix],
    manifestActivesByName: new Map([
      ["Glister 680 SG", ["glyphosate"]],
      ["Cyper 300", ["alpha-cypermethrin"]],
    ]),
    liveRowsByPcode: new Map([
      ["60560", liveRow({ pcode: "60560", fpname: "Glister 680 SG", sname: "SOMECO PTY LTD" })],
      ["70002", liveRow({
        pcode: "70002",
        fpname: "Very Long Holder Cyper 300 Insecticide",
        sname: "VERY LONG HOLDER PTY LTD",
      })],
    ]),
    liveActivesByPcode: new Map([
      ["60560", [{ name: "GLYPHOSATE", amount: 680 }]],
      ["70002", [{ name: "ALPHA-CYPERMETHRIN", amount: 300 }]],
    ]),
  }));
  const exactItem = result.items.find((i) => i.awri_product_name === "Glister 680 SG");
  const prefixItem = result.items.find((i) => i.awri_product_name === "Cyper 300");
  assert(exactItem && prefixItem);
  assertEquals(prefixItem.registrant_prefix_words, 3);
  assertEquals(prefixItem.strength_breakdown.registrant_prefix_penalty, -4);
  assert(exactItem.strength_score > prefixItem.strength_score);
  assertEquals(result.strongest[0].awri_product_name, "Glister 680 SG");
  assertEquals(result.weakest[0].awri_product_name, "Cyper 300");
});

Deno.test("F17: cross-check against approved-active names — exact and contained relations only, never a product match", () => {
  const checked = crossCheckNamesAgainstActiveNames(
    ["Amitrole 47T", "Fosetyl-Aluminium", "Boonta"],
    ["AMITROLE", "FOSETYL-ALUMINIUM"],
  );
  assertEquals(checked[0].hits, [{ active_name: "AMITROLE", relation: "contained_in_name" }]);
  assertEquals(checked[1].hits, [{ active_name: "FOSETYL-ALUMINIUM", relation: "exact" }]);
  assertEquals(checked[2].hits, []);
});

Deno.test("F18: report carries every required Stage 5F field", () => {
  const report = formatAuditReport(auditDeterministicMatches(baseInput()), "75 passed");
  for (
    const line of [
      "Total audited: 1",
      "Approve for seed: 1",
      "Rejected: 0",
      "Archived/lapsed discovered: 0",
      "Master Chemical collisions: 0",
      "Duplicate identities (aliases): 0",
      "Distinct identities approved: 1",
      "Deterministic input only: PASS",
      "Probable batch untouched: PASS",
      "APVMA remains authoritative: PASS",
      "Tests: 75 passed",
      "Database changes: NONE",
      "Apply step: NONE",
    ]
  ) assertStringIncludes(report, line);
});

Deno.test("F19: expiry parsing is exact — d/m/yyyy with time, single digits, garbage, null", () => {
  assertEquals(parseExpdateIso("30/06/2026 0:00"), "2026-06-30");
  assertEquals(parseExpdateIso("3/06/2026 0:00"), "2026-06-03");
  assertEquals(parseExpdateIso("17/11/2025 0:00"), "2025-11-17");
  assertEquals(parseExpdateIso(null), null);
  assertEquals(parseExpdateIso("June 2026"), null);
});

Deno.test("F20: tier structure re-derivation — prefixes, suffixes, and variant-poisoned remainders", () => {
  const t = (s: string): string[] => s.split(" ");
  assertEquals(
    reverifyTierStructure("exact_name", t("glister 680 sg"), t("glister 680 sg"), []).reproduced,
    true,
  );
  const fwd = reverifyTierStructure(
    "formulation_suffix",
    t("cavalier 500 sc"),
    t("cavalier 500 sc herbicide"),
    [],
  );
  assertEquals(fwd.reproduced, true);
  assertEquals(fwd.leftoverRegisterTokens, ["herbicide"]);
  const pre = reverifyTierStructure(
    "registrant_prefix",
    t("weedmaster duo"),
    t("nufarm weedmaster duo herbicide"),
    t("nufarm australia limited"),
  );
  assertEquals(pre.reproduced, true);
  assertEquals(pre.prefixWords, 1);
  // A variant token in the remainder can never be dropped.
  assertEquals(
    reverifyTierStructure(
      "registrant_prefix",
      t("weedmaster"),
      t("nufarm weedmaster duo herbicide"),
      t("nufarm australia limited"),
    ).reproduced,
    false,
  );
  const rev = reverifyTierStructure(
    "reverse_formulation_suffix",
    t("avior 250 sc fungicide"),
    t("avior 250 sc"),
    [],
  );
  assertEquals(rev.reproduced, true);
  assertEquals(rev.leftoverAwriTokens, ["fungicide"]);
});

Deno.test("F21: helper coverage — variant multisets, typography detection, active evidence extraction", () => {
  assertEquals(variantTokensOf("Custodia Forte Duo"), ["duo", "forte"]);
  assertEquals(variantTokensOf("Plain Product 500"), []);
  assertEquals(hasTypographySplit("Agristar 250SC"), true);
  assertEquals(hasTypographySplit("Agristar 250 SC"), false);
  const evidence = explainActives(
    ["copper (present as cupric hydroxide)"],
    [{ name: "COPPER PRESENT AS CUPRIC HYDROXIDE", amount: 375 }],
  );
  assertEquals(evidence, [{
    manifest_active: "copper (present as cupric hydroxide)",
    register_constituents: [{ name: "COPPER PRESENT AS CUPRIC HYDROXIDE", camount: 375 }],
  }]);
});
