// §17/§18/§19 — the research → strict-resolver identity handoff, use-context
// integrity, and product-page URL delivery.
//
// These tests exist because of a REAL production failure. Live AU research for
// "Dithane Rainshield" discovered APVMA 59688 alongside the register name
// "Dithane Rainshield Neo Tec Fungicide" — and the final response was still
// match_source=unresolved with ai_registration_hint_discarded=59688. The
// projection had flattened the candidate to the bare string "59688", so the
// re-resolution asked the register "is 59688 called 'Dithane Rainshield'?".
// The register says it is called "Dithane Rainshield Neo Tec Fungicide", NEO
// and TEC are meaningful tokens, and the strict matcher correctly said no.
//
// The matcher was right. The handoff was wrong. Every test below pins the fix
// in the handoff and pins the matcher AS IT IS — if someone ever "fixes"
// Dithane by making NEO or TEC globally droppable, tests here fail.

import { assert, assertEquals } from "jsr:@std/assert@1";

import {
  buildResolverAttempts,
  groupResearchUseContexts,
  projectResearch,
  projectResearchToSearchResults,
  resolverHintsFor,
  splitUseByTargetSpecificRates,
} from "./authority.ts";
import { cloneResearch } from "./test_fixtures.ts";
import {
  mergeDiscoveryIntoStructured,
  quarantineUnverifiedAiFacts,
} from "../ingestion/ingest.ts";
import { nameCorresponds } from "../ingestion/matching.ts";
import type { ResolvedRegistration } from "../ingestion/contract.ts";
import type { ChemicalResearchResult, ResearchRegisteredUse } from "./schema.ts";

const REGISTER_NAME_59688 = "DITHANE RAINSHIELD NEO TEC FUNGICIDE";

/** The live register row, as PubCRIS publishes it. */
function apvmaResolved(overrides: Partial<ResolvedRegistration> = {}): ResolvedRegistration {
  return {
    country_code: "AU",
    scheme: "apvma",
    registration_number: "59688",
    registration_identity_key: "AU:apvma:59688",
    registered_product_name: REGISTER_NAME_59688,
    registrant: "UPL Australia Pty Ltd",
    product_category: "fungicide",
    form_type: "solid",
    label_version: null,
    register_status: "R",
    active_ingredients: [
      {
        name: "Mancozeb",
        concentration: 750,
        concentration_unit: "g/kg",
        activity_group: { scheme: "frac", code: "M3", common_name: "Dithiocarbamate" },
        group_source: "authoritative_classification",
        identity_source: "official_register",
      },
    ],
    unresolved_fields: [],
    sources: [{
      kind: "official_register",
      name: "APVMA PubCRIS",
      reference: "https://portal.apvma.gov.au/pubcris?p_id=1",
      retrieved_at: new Date().toISOString(),
    }],
    match_mode: "register_number_verified",
    label_evidence: null,
    label_document: null,
    ...overrides,
  };
}

/**
 * A stand-in for the APVMA adapter that uses the REAL strict matcher.
 *
 * Deliberately not a mock that "resolves when asked nicely": it reproduces
 * the adapter's actual contract — the number must exist in the register AND
 * `nameCorresponds` must accept the supplied name against the register's own
 * name — so a test can never pass by weakening verification.
 */
function strictRegister(rows: Record<string, string>) {
  const calls: { number: string; name: string }[] = [];
  const discover = (name: string, number: string) => {
    calls.push({ number, name });
    const registerName = rows[number];
    if (!registerName) return { outcome: "unresolved" as const };
    if (!nameCorresponds(name, registerName)) return { outcome: "unresolved" as const };
    return { outcome: "resolved" as const, registerName };
  };
  return { calls, discover };
}

/** Run the real attempt sequence against the strict stand-in register. */
function resolveWithResearch(
  research: ChemicalResearchResult,
  operatorQuery: string,
  register: ReturnType<typeof strictRegister>,
) {
  const projection = projectResearch(research, "AU", "apvma");
  const attempts = buildResolverAttempts(projection.resolverHints, operatorQuery);
  for (const attempt of attempts) {
    const result = register.discover(attempt.name, attempt.number);
    if (result.outcome === "resolved") {
      return { outcome: "resolved" as const, number: attempt.number, name: result.registerName };
    }
  }
  return { outcome: "unresolved" as const };
}

// ===========================================================================
// §17 — identity handoff
// ===========================================================================

Deno.test("§17.1 a registration number and the name it was found with stay paired", () => {
  const hints = resolverHintsFor(cloneResearch(), "AU", "apvma");
  assertEquals(hints.length, 1);
  assertEquals(hints[0].registrationNumber, "59688");
  assertEquals(hints[0].registeredProductName, "Dithane Rainshield Neo Tec Fungicide");
  assertEquals(hints[0].verificationName, "Dithane Rainshield Neo Tec Fungicide");
  assertEquals(hints[0].verificationNameSource, "candidate_registered_name");
  assertEquals(hints[0].scheme, "apvma");
  assertEquals(hints[0].country, "AU");
  assertEquals(hints[0].sourceDomain, "portal.apvma.gov.au");
});

Deno.test("§17.2 a number is never paired with a DIFFERENT candidate's name", () => {
  const research = cloneResearch();
  research.registration_candidates = [
    {
      scheme: "apvma",
      number: "59688",
      registered_product_name: "Dithane Rainshield Neo Tec Fungicide",
      country: "AU",
      source_url: "https://portal.apvma.gov.au/pubcris?p_id=1",
      source_domain: "portal.apvma.gov.au",
      confidence: "high",
      reason: "PubCRIS entry",
    },
    {
      scheme: "apvma",
      number: "34567",
      registered_product_name: "Penncozeb 750 DF Fungicide",
      country: "AU",
      source_url: "https://portal.apvma.gov.au/pubcris?p_id=2",
      source_domain: "portal.apvma.gov.au",
      confidence: "medium",
      reason: "same active, different brand",
    },
  ];
  const hints = resolverHintsFor(research, "AU", "apvma");
  const byNumber = new Map(hints.map((h) => [h.registrationNumber, h.verificationName]));
  assertEquals(byNumber.get("59688"), "Dithane Rainshield Neo Tec Fungicide");
  assertEquals(byNumber.get("34567"), "Penncozeb 750 DF Fungicide");

  // With two candidates in play the canonical product name may NOT stand in
  // for a nameless candidate — that is exactly how A's number would acquire
  // B's name.
  research.registration_candidates[1].registered_product_name = null;
  const mixed = resolverHintsFor(research, "AU", "apvma");
  const nameless = mixed.find((h) => h.registrationNumber === "34567");
  assertEquals(nameless?.verificationName, "Dithane Rainshield");
  assertEquals(nameless?.verificationNameSource, "operator_query");
  assert(
    nameless?.verificationName !== "Dithane Rainshield Neo Tec Fungicide",
    "the canonical name of candidate A must never be attached to candidate B",
  );
});

Deno.test("§17.3 a short operator query still discovers the full registered candidate", () => {
  const research = cloneResearch();
  assertEquals(research.product.searched_name, "Dithane Rainshield");
  const projection = projectResearch(research, "AU", "apvma");
  // Discovery widened the identity from the shorthand to the register name…
  assertEquals(projection.extraction.product_name, "Dithane Rainshield Neo Tec Fungicide");
  // …and the lead travels with it.
  assertEquals(projection.resolverHints[0].registrationNumber, "59688");
});

Deno.test("§17.4 strict re-resolution verifies the PAIRED register name, not the query", () => {
  const register = strictRegister({ "59688": REGISTER_NAME_59688 });
  const result = resolveWithResearch(cloneResearch(), "Dithane Rainshield", register);

  assertEquals(result.outcome, "resolved");
  assertEquals(register.calls[0].number, "59688");
  assertEquals(
    register.calls[0].name,
    "Dithane Rainshield Neo Tec Fungicide",
    "the FULL discovered register name is what gets verified",
  );

  // The precise production regression: the old code sent the operator query.
  const legacy = strictRegister({ "59688": REGISTER_NAME_59688 });
  assertEquals(
    legacy.discover("Dithane Rainshield", "59688").outcome,
    "unresolved",
    "the old bare-number handoff genuinely could not resolve — this is the bug",
  );
});

Deno.test("§17.5 the strict matcher itself is unchanged", () => {
  // Shorthand still does not reach the fuller register name.
  assertEquals(nameCorresponds("Dithane Rainshield", REGISTER_NAME_59688), false);
  // The full name matches, case and spacing being pure typography.
  assertEquals(nameCorresponds("Dithane Rainshield Neo Tec Fungicide", REGISTER_NAME_59688), true);
  // The variant guard is intact.
  assertEquals(nameCorresponds("Custodia", "CUSTODIA FORTE FUNGICIDE"), false);
  assertEquals(nameCorresponds("Custodia 320SC", "CUSTODIA 320 SC"), true);
  // Formulation/category suffixes remain droppable.
  assertEquals(nameCorresponds("Spray Seal", "SPRAY SEAL LIQUID"), true);
  assertEquals(nameCorresponds("Custodia", "CUSTODIA 320 SC FUNGICIDE"), true);
});

Deno.test("§17.6 NEO and TEC were NOT added to the ignorable suffix list", () => {
  // If either token had been made globally droppable to force Dithane
  // through, these would start matching — and every other product carrying
  // those words would silently lose its identity protection.
  assertEquals(nameCorresponds("Dithane Rainshield", "DITHANE RAINSHIELD NEO"), false);
  assertEquals(nameCorresponds("Dithane Rainshield", "DITHANE RAINSHIELD TEC"), false);
  assertEquals(nameCorresponds("Dithane Rainshield", "DITHANE RAINSHIELD NEO TEC"), false);
  // And an unrelated product with the same tokens is equally protected.
  assertEquals(nameCorresponds("Barrier", "BARRIER NEO TEC"), false);
});

Deno.test("§17.7 once the register verifies the identity, APVMA wins over research", () => {
  const research = cloneResearch();
  // Research believed FRAC M5 and a shorter name; the register says M3.
  const projection = projectResearch(research, "AU", "apvma");
  const structured = {
    product_name: projection.extraction.product_name,
    product_category: "fungicide",
    form_type: "solid",
    registration: {
      country_code: "AU",
      scheme: "apvma",
      registration_number: "59688",
      registrant: "BASF",
      registered_product_name: "Dithane Rainshield",
      label_reference: projection.extraction.label_reference,
      label_version: null,
    },
    active_ingredients: [{
      name: "Mancozeb",
      concentration: 750,
      concentration_unit: "g/kg",
      activity_group: { scheme: "frac", code: "M5", common_name: null },
      group_source: "ai_interpretation",
      identity_source: "ai_interpretation",
    }],
    registered_uses: projection.extraction.registered_uses,
    verification: { unresolved_fields: [], sources: [], status: "unverified", conflicts: [] },
  };

  const merged = mergeDiscoveryIntoStructured(structured, apvmaResolved());
  assertEquals(merged.registration.registered_product_name, REGISTER_NAME_59688);
  assertEquals(merged.product_name, REGISTER_NAME_59688);
  assertEquals(merged.registration.registrant, "UPL Australia Pty Ltd");
  assertEquals(merged.active_ingredients[0].activity_group.code, "M3");
  assertEquals(merged.active_ingredients[0].identity_source, "official_register");
});

Deno.test("§17.8 a WRONG number with the right name still fails closed", () => {
  const research = cloneResearch();
  research.registration_candidates[0].number = "11111";
  const register = strictRegister({ "59688": REGISTER_NAME_59688 });
  const result = resolveWithResearch(research, "Dithane Rainshield", register);

  assertEquals(result.outcome, "unresolved");
  assert(register.calls.every((c) => c.number === "11111"));
});

Deno.test("§17.9 the right number with a WRONG candidate name fails closed", () => {
  const research = cloneResearch();
  // Research kept the number but mis-transcribed the identity as a rival brand.
  research.registration_candidates[0].registered_product_name = "Penncozeb 750 DF Fungicide";
  research.product.canonical_name = "Penncozeb 750 DF Fungicide";
  const register = strictRegister({ "59688": REGISTER_NAME_59688 });
  const result = resolveWithResearch(research, "Penncozeb", register);

  assertEquals(
    result.outcome,
    "unresolved",
    "a number must never bind to a register row whose name does not correspond",
  );
});

Deno.test("§17.10 ambiguous candidates still fail closed, and nothing is served", () => {
  const research = cloneResearch();
  research.registration_candidates = [
    {
      scheme: "apvma",
      number: "59688",
      registered_product_name: "Dithane Rainshield Neo Tec Fungicide",
      country: "AU",
      source_url: null,
      source_domain: null,
      confidence: "medium",
      reason: "candidate A",
    },
    {
      scheme: "apvma",
      number: "34567",
      registered_product_name: "Dithane M45 Fungicide",
      country: "AU",
      source_url: null,
      source_domain: null,
      confidence: "medium",
      reason: "candidate B",
    },
  ];
  // The register knows neither name under the number offered.
  const register = strictRegister({ "59688": "SOMETHING ELSE ENTIRELY" });
  const result = resolveWithResearch(research, "Dithane", register);
  assertEquals(result.outcome, "unresolved");

  // And the fail-closed gate empties the canonical response.
  const structured: Record<string, unknown> = {
    product_name: "Dithane Rainshield Neo Tec Fungicide",
    product_url: "https://crop-solutions.basf.com.au/products/dithane-rainshield",
    registration: { country_code: "AU", registration_number: "59688", registrant: "BASF" },
    active_ingredients: [{ name: "Mancozeb", concentration: 750 }],
    registered_uses: [{ crop: "Grapevines", target: "Downy Mildew", rates: [] }],
    verification: { unresolved_fields: [], sources: [], status: "unverified" },
  };
  assert(quarantineUnverifiedAiFacts(structured, "ambiguous", "Australia"));
  assertEquals(structured.match_source, "unresolved");
  assertEquals((structured.registration as Record<string, unknown>).registration_number, null);
});

Deno.test("§17 bounded: at most two leads plus one operator-query retry", () => {
  const hints = ["1", "2", "3", "4"].map((n, i) => ({
    registrationNumber: `1000${n}`,
    registeredProductName: `Product ${i}`,
    verificationName: `Product ${i}`,
    verificationNameSource: "candidate_registered_name" as const,
    country: "AU",
    scheme: "apvma",
    sourceUrl: null,
    sourceDomain: null,
    confidence: "high" as const,
  }));
  const attempts = buildResolverAttempts(hints, "Some Query");
  assertEquals(attempts.length, 3);
  assertEquals(attempts.map((a) => a.number), ["10001", "10002", "10001"]);
  assertEquals(attempts[2].name, "Some Query");
  assertEquals(attempts[2].source, "operator_query");
});

Deno.test("§17 with no research leads the legacy AI number still gets one attempt", () => {
  const attempts = buildResolverAttempts([], "Dithane Rainshield", "59688");
  assertEquals(attempts.length, 1);
  assertEquals(attempts[0].number, "59688");
  assertEquals(attempts[0].name, "Dithane Rainshield");
  assertEquals(attempts[0].source, "legacy_ai_number");
});

// ===========================================================================
// §18 — target / rate context
// ===========================================================================

/** The live production shape: one use, three targets, two different rates. */
function flattenedDithaneUse(): ResearchRegisteredUse {
  return {
    crop: "Grapevines",
    targets: ["Black Spot", "Downy Mildew", "Phomopsis Cane and Leaf Spot"],
    rates: [
      {
        label: "Black spot and downy mildew",
        basis: "per_100_litres",
        value: 200,
        min_value: null,
        max_value: null,
        unit: "g",
        raw_text: "Black spot and downy mildew: 200 g/100 L",
        source_refs: ["https://elabels.apvma.gov.au/59688.pdf"],
      },
      {
        label: "Phomopsis cane and leaf spot",
        basis: "range_per_100_litres",
        value: null,
        min_value: 150,
        max_value: 200,
        unit: "g",
        raw_text: "Phomopsis cane and leaf spot: 150-200 g/100 L",
        source_refs: ["https://elabels.apvma.gov.au/59688.pdf"],
      },
    ],
    whp: "Not required when used as directed",
    rei: "24 hours",
    restrictions: [],
    source_refs: ["https://elabels.apvma.gov.au/59688.pdf"],
  };
}

Deno.test("§18.1/§18.3 targets that genuinely share a rate share one context", () => {
  const contexts = groupResearchUseContexts([flattenedDithaneUse()]);
  const shared = contexts.find((c) => c.targets.includes("Black Spot"));
  assert(shared, "black spot must be present");
  assertEquals(shared.targets.sort(), ["Black Spot", "Downy Mildew"]);
  assertEquals(shared.rates.length, 1);
  assertEquals(shared.rates[0].value, 200);
  assertEquals(shared.rates[0].basis, "per_100_litres");
});

Deno.test("§18.2/§18.4 a target with a different rate becomes its own context", () => {
  const contexts = groupResearchUseContexts([flattenedDithaneUse()]);
  assertEquals(contexts.length, 2);
  const phomopsis = contexts.find((c) => c.targets.includes("Phomopsis Cane and Leaf Spot"));
  assert(phomopsis);
  assertEquals(phomopsis.targets, ["Phomopsis Cane and Leaf Spot"]);
  assertEquals(phomopsis.rates.length, 1);
  assertEquals(phomopsis.rates[0].min_value, 150);
  assertEquals(phomopsis.rates[0].max_value, 200);
});

Deno.test("§18.5 no rate is ever copied onto an unrelated target", () => {
  const contexts = groupResearchUseContexts([flattenedDithaneUse()]);
  for (const c of contexts) {
    const isPhomopsis = c.targets.some((t) => t.toLowerCase().includes("phomopsis"));
    for (const r of c.rates) {
      const rateIsPhomopsis = (r.raw_text ?? "").toLowerCase().includes("phomopsis");
      assertEquals(
        rateIsPhomopsis,
        isPhomopsis,
        `rate "${r.raw_text}" landed on targets ${JSON.stringify(c.targets)}`,
      );
    }
  }
  // And the flattened three-rows-two-rates-each shape is gone from the wire.
  const research = cloneResearch();
  research.registered_uses = [flattenedDithaneUse()];
  const projection = projectResearch(research, "AU", "apvma");
  const rows = projection.extraction.registered_uses as Record<string, unknown>[];
  assertEquals(rows.length, 3, "one row per target, as the contract requires");
  for (const row of rows) {
    assertEquals((row.rates as unknown[]).length, 1, "each target carries only its own rate");
  }
});

Deno.test("§18.6 differing WHP, REI or restrictions prevent grouping", () => {
  const base = flattenedDithaneUse();
  const rate = base.rates[0];
  const mk = (
    target: string,
    over: Partial<ResearchRegisteredUse>,
  ): ResearchRegisteredUse => ({
    crop: "Grapevines",
    targets: [target],
    rates: [rate],
    whp: "14 days",
    rei: "24 hours",
    restrictions: [],
    source_refs: [],
    ...over,
  });

  assertEquals(groupResearchUseContexts([mk("A", {}), mk("B", {})]).length, 1);
  assertEquals(
    groupResearchUseContexts([mk("A", {}), mk("B", { whp: "28 days" })]).length,
    2,
    "a different withholding period is a different context",
  );
  assertEquals(
    groupResearchUseContexts([mk("A", {}), mk("B", { rei: "48 hours" })]).length,
    2,
    "a different re-entry interval is a different context",
  );
  assertEquals(
    groupResearchUseContexts([mk("A", {}), mk("B", { restrictions: ["Do not graze"] })]).length,
    2,
    "different restrictions are a different context",
  );
  assertEquals(
    groupResearchUseContexts([mk("A", {}), mk("B", { crop: "Apples" })]).length,
    2,
    "a different crop is a different context",
  );
});

Deno.test("§18.7 authoritative label data overrides the research grouping", () => {
  const research = cloneResearch();
  research.registered_uses = [flattenedDithaneUse()];
  const projection = projectResearch(research, "AU", "apvma");
  const structured = {
    product_name: "Dithane Rainshield Neo Tec Fungicide",
    registration: { country_code: "AU", registration_number: "59688" },
    active_ingredients: [],
    registered_uses: projection.extraction.registered_uses,
    verification: { unresolved_fields: [], sources: [], status: "unverified", conflicts: [] },
  };

  const withLabel = mergeDiscoveryIntoStructured(
    structured,
    apvmaResolved({
      label_evidence: {
        claims: [{
          crop: "GRAPEVINES",
          target_raw: "DOWNY MILDEW",
          target: "Downy Mildew",
          withholding_period_days: 14,
          re_entry_period_hours: 24,
          statements: ["Withholding period: 14 days"],
          rates: [{
            basis: "per_100_litres",
            value: 250,
            unit: "g",
            raw_text: "250 g/100 L",
            source: "manufacturer_label",
          }],
        }],
        statements: ["Withholding period: 14 days"],
        sources: [],
        unresolved: [],
        unbound_rows: [],
        document_conflicts: [],
      } as never,
    }),
  );
  // The label's claim set IS the served set — research grouping does not survive it.
  assertEquals(withLabel.registered_uses.length, 1);
  assertEquals(withLabel.registered_uses[0].target, "Downy Mildew");
  assertEquals(withLabel.registered_uses[0].rates[0].value, 250);
});

Deno.test("§18.8 every target survives as its own tag-able row", () => {
  const research = cloneResearch();
  research.registered_uses = [flattenedDithaneUse()];
  const projection = projectResearch(research, "AU", "apvma");
  const rows = projection.extraction.registered_uses as Record<string, unknown>[];
  assertEquals(
    rows.map((r) => r.target).sort(),
    ["Black Spot", "Downy Mildew", "Phomopsis Cane and Leaf Spot"],
  );
});

Deno.test("§18 a use whose rates name no target is left exactly as the model grouped it", () => {
  const use = flattenedDithaneUse();
  use.rates = use.rates.map((r) => ({ ...r, label: "Standard", raw_text: "see label" }));
  const split = splitUseByTargetSpecificRates(use);
  assertEquals(split.length, 1, "no text evidence means no inferred split");
  assertEquals(split[0].targets.length, 3);
});

// ===========================================================================
// §19 — URL delivery
// ===========================================================================

Deno.test("§19.1 a classified registrant product page survives the projection", () => {
  const projection = projectResearch(cloneResearch(), "AU", "apvma");
  assertEquals(
    projection.extraction.productURL,
    "https://crop-solutions.basf.com.au/products/dithane-rainshield",
  );
  assertEquals(projection.productPageCandidate?.trust, "registrant");
});

Deno.test("§19.4/§19.5 the product page never becomes the Official Label", () => {
  const projection = projectResearch(cloneResearch(), "AU", "apvma");
  assertEquals(projection.extraction.label_reference, "https://elabels.apvma.gov.au/59688.pdf");
  assert(projection.extraction.label_reference !== projection.extraction.productURL);

  // And after the register resolves, the register's own label document wins.
  const structured = {
    product_name: "Dithane",
    product_url: projection.extraction.productURL,
    registration: {
      country_code: "AU",
      registration_number: "59688",
      label_reference: projection.extraction.label_reference,
    },
    active_ingredients: [],
    registered_uses: [],
    verification: { unresolved_fields: [], sources: [], status: "unverified", conflicts: [] },
  };
  const merged = mergeDiscoveryIntoStructured(
    structured,
    apvmaResolved({
      label_document: {
        url: "https://elabels.apvma.gov.au/59688ELBL.pdf",
        retrieved_at: new Date().toISOString(),
        sha256: null,
      } as never,
    }),
  );
  assertEquals(merged.registration.label_reference, "https://elabels.apvma.gov.au/59688ELBL.pdf");
  assertEquals(
    merged.product_url,
    "https://crop-solutions.basf.com.au/products/dithane-rainshield",
    "the product page rides along untouched — it is a different field",
  );
});

Deno.test("§19.6 an SDS becomes neither the product page nor the label", () => {
  const research = cloneResearch();
  research.documents.official_label_candidates = [];
  research.documents.product_page_candidates = [];
  research.sources = research.sources.filter((s) => !s.url.includes("elabels"));
  // Only the SDS remains, offered as both.
  research.documents.official_label_candidates = [{
    url: "https://crop-solutions.basf.com.au/sds/dithane-rainshield-sds.pdf",
    title: "SDS",
    domain: "crop-solutions.basf.com.au",
    reason: "model mislabelled it",
  }];
  const projection = projectResearch(research, "AU", "apvma");
  assertEquals(projection.extraction.label_reference, null);
  assertEquals(projection.extraction.productURL, null);
  assert(projection.sdsCandidates.length >= 1);
});

Deno.test("§19 an unverified identity keeps the product page out of the canonical response", () => {
  const structured: Record<string, unknown> = {
    product_name: "Dithane Rainshield Neo Tec Fungicide",
    product_url: "https://crop-solutions.basf.com.au/products/dithane-rainshield",
    registration: { country_code: "AU", registration_number: "59688" },
    active_ingredients: [],
    registered_uses: [],
    verification: { unresolved_fields: [], sources: [], status: "unverified" },
  };
  assert(quarantineUnverifiedAiFacts(structured, "unresolved", "Australia"));
  assertEquals(structured.product_url, null, "not a canonical fact for an unverified identity");
  assertEquals(
    (structured.ai_suggestion as Record<string, unknown>).product_url,
    "https://crop-solutions.basf.com.au/products/dithane-rainshield",
    "but it is retained, clearly weaker, for the operator",
  );
});

// ===========================================================================
// §6 — search rows carry the paired identity forward
// ===========================================================================

Deno.test("§6 the PRIMARY research row carries its own registration identity", () => {
  const rows = projectResearchToSearchResults(cloneResearch(), "AU", "apvma");
  const primary = rows[0];
  assertEquals(primary.name, "Dithane Rainshield Neo Tec Fungicide");
  assertEquals(primary.registration_number, "59688");
  assertEquals(primary.registration_country, "AU");
  assertEquals(primary.registration_scheme, "apvma");
});

Deno.test("§6 a primary row with no matching candidate claims no registration", () => {
  const research = cloneResearch();
  research.product.canonical_name = "Some Unregistered Biostimulant";
  const rows = projectResearchToSearchResults(research, "AU", "apvma");
  assertEquals(rows[0].registration_number, undefined);
  // The real candidate still appears as its own selectable row.
  const other = rows.find((r) => r.name === "Dithane Rainshield Neo Tec Fungicide");
  assertEquals(other?.registration_number, "59688");
});
