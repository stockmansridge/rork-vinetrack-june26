// Task §40 — authority tests. The single most important file here.
//
// Every test asserts the same principle from a different angle: web
// research DISCOVERS, the official register DECIDES. A finding that has not
// been through the register is a lead, and a lead never outranks a fact.

import { assert, assertEquals } from "jsr:@std/assert@1";

import { projectResearch, resolverHintsFor } from "./authority.ts";
import { classifyUrl } from "./classify.ts";
import { cloneResearch } from "./test_fixtures.ts";
import { mergeDiscoveryIntoStructured } from "../ingestion/ingest.ts";
import { discardUnverifiedAiIdentity } from "../ingestion/ingest.ts";
import type { ResolvedRegistration } from "../ingestion/contract.ts";

/** A register-resolved identity, as the APVMA adapter would return it. */
function apvmaResolved(overrides: Partial<ResolvedRegistration> = {}): ResolvedRegistration {
  return {
    country_code: "AU",
    scheme: "apvma",
    registration_number: "59688",
    registration_identity_key: "AU:apvma:59688",
    registered_product_name: "Dithane Rainshield Neo Tec Fungicide",
    registrant: "BASF Australia Ltd",
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

Deno.test("§40.1 a web-found registration number is only ever a resolver hint", () => {
  const research = cloneResearch();
  const projection = projectResearch(research, "AU", "apvma");

  // It is offered to the resolver… paired with the register name it was
  // discovered with, never as a bare number.
  assertEquals(projection.resolverHints.map((h) => h.registrationNumber), ["59688"]);
  // …and it sits in the extraction only as an AI-tier claim, which the
  // existing fail-closed gate strips when the register did not confirm it.
  assertEquals(projection.extraction.registration_number, "59688");

  const structured = {
    registration: { registration_number: "59688", scheme: "apvma", registrant: "BASF" },
    active_ingredients: [],
    verification: { unresolved_fields: [], sources: [], status: "unverified" },
  };
  const discarded = discardUnverifiedAiIdentity(structured, "unresolved");
  assert(discarded, "an unconfirmed number must be discarded, not served");
  assertEquals(structured.registration?.registration_number ?? null, null);
});

Deno.test("§40.2/§19 a web concentration conflicting with the register loses", () => {
  const research = cloneResearch();
  research.active_ingredients[0].concentration = 640; // wrong, from a blog
  const projection = projectResearch(research, "AU", "apvma");

  const structured = {
    product_name: "Dithane Rainshield",
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
      concentration: 640,
      concentration_unit: "g/kg",
      activity_group: { scheme: "frac", code: "M5", common_name: null },
      group_source: "ai_interpretation",
      identity_source: "ai_interpretation",
    }],
    registered_uses: [],
    verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
  };

  const merged = mergeDiscoveryIntoStructured(structured, apvmaResolved());

  const mancozeb = merged.active_ingredients.find((a: { name: string }) =>
    a.name.toLowerCase() === "mancozeb"
  );
  assertEquals(mancozeb.concentration, 750, "the register's strength must win");
  assertEquals(mancozeb.identity_source, "official_register");
  assert(
    merged.verification.conflicts.length > 0,
    "the disagreement must be recorded, not silently dropped",
  );
});

Deno.test("§40.3/§40.4 neither Terra nor Sol can overwrite a register value", () => {
  // Same assertion for both models: the merge does not know or care which
  // model produced the extraction — AI tier is AI tier.
  for (const model of ["gpt-5.6-terra", "gpt-5.6-sol"]) {
    const structured = {
      product_name: `from ${model}`,
      registration: {
        country_code: "AU",
        scheme: "apvma",
        registration_number: "11111",
        registrant: "Someone Else Pty Ltd",
        registered_product_name: "Dithane Rainshield (guessed)",
        label_reference: null,
        label_version: null,
      },
      active_ingredients: [{
        name: "Mancozeb",
        concentration: 800,
        concentration_unit: "g/kg",
        activity_group: null,
        group_source: "ai_interpretation",
        identity_source: "ai_interpretation",
      }],
      registered_uses: [],
      product_category: "fungicide",
      form_type: "solid",
      verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
    };

    const merged = mergeDiscoveryIntoStructured(structured, apvmaResolved());

    assertEquals(merged.registration.registration_number, "59688");
    assertEquals(merged.registration.registered_product_name, "Dithane Rainshield Neo Tec Fungicide");
    assertEquals(merged.registration.registrant, "BASF Australia Ltd");
    assertEquals(merged.product_name, "Dithane Rainshield Neo Tec Fungicide");
  }
});

Deno.test("§20 the authoritative FRAC group overrules the model's suggestion", () => {
  const research = cloneResearch();
  // The fixture deliberately suggests M5 for Mancozeb.
  assertEquals(research.active_ingredients[0].suggested_group, "M5");
  const projection = projectResearch(research, "AU", "apvma");
  const active = (projection.extraction.active_ingredients as Record<string, unknown>[])[0];
  // It is passed through as a SUGGESTION only, for reconcileGroup to judge.
  assertEquals(active.activity_group_code, "M5");
  assertEquals(active.activity_group_scheme, "frac");

  const merged = mergeDiscoveryIntoStructured(
    {
      product_name: "x",
      registration: null,
      active_ingredients: [{
        name: "Mancozeb",
        concentration: 750,
        concentration_unit: "g/kg",
        activity_group: { scheme: "frac", code: "M5", common_name: null },
        group_source: "ai_interpretation",
        identity_source: "ai_interpretation",
      }],
      registered_uses: [],
      product_category: "fungicide",
      form_type: "solid",
      verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
    },
    apvmaResolved(),
  );
  const group = merged.active_ingredients[0].activity_group;
  assertEquals(group.code, "M3", "the authoritative table decides the FRAC code");
  assertEquals(group.scheme, "frac");
});

Deno.test("§40.5 a manufacturer page cannot become register authority", () => {
  const c = classifyUrl("https://crop-solutions.basf.com.au/products/dithane", "AU");
  assertEquals(c.trust, "registrant");
  assertEquals(c.isOfficialLabelCandidate, false);
  assert(c.trust !== "official_register");
});

Deno.test("§40.6 a search-results page is never evidence", () => {
  for (
    const url of [
      "https://www.google.com/search?q=dithane+rainshield+label",
      "https://www.bing.com/search?q=apvma+59688",
      "https://apvma.gov.au/search?q=dithane",
    ]
  ) {
    const c = classifyUrl(url, "AU");
    assertEquals(c.isOfficialLabelCandidate, false, url);
    assertEquals(c.isProductPageCandidate, false, url);
  }
  assertEquals(classifyUrl("https://www.google.com/search?q=x", "AU").trust, "search_engine");
});

Deno.test("§40.7/§15 an SDS can never become the Official Label", () => {
  const sds = classifyUrl(
    "https://crop-solutions.basf.com.au/sds/dithane-rainshield-sds.pdf",
    "AU",
  );
  assertEquals(sds.kind, "safety_data_sheet");
  assertEquals(sds.isOfficialLabelCandidate, false);

  // Even hosted on the regulator's own domain.
  const regulatorSds = classifyUrl("https://apvma.gov.au/docs/product-msds.pdf", "AU");
  assertEquals(regulatorSds.kind, "safety_data_sheet");
  assertEquals(regulatorSds.isOfficialLabelCandidate, false);

  // And when the ONLY thing the model offers as a label is an SDS, the
  // projection must leave the label field empty rather than take it.
  const research = cloneResearch();
  research.documents.official_label_candidates = [{
    url: "https://crop-solutions.basf.com.au/sds/dithane-sds.pdf",
    title: "SDS mislabelled by the model",
    domain: "crop-solutions.basf.com.au",
    reason: "model claimed this was the label",
  }];
  // Remove the genuine approved label so the SDS is the only candidate left.
  research.sources = research.sources.filter((s) => !s.url.includes("elabels"));
  research.registered_uses = [];
  const projection = projectResearch(research, "AU", "apvma");
  assertEquals(projection.extraction.label_reference, null);
  assert(projection.rejected.some((r) => r.url.includes("sds")));
  assert((projection.extraction.unresolved as string[]).includes("label_reference"));
});

Deno.test("§40.8/§13 a real approved label populates registration.labelReference", () => {
  const research = cloneResearch();
  const projection = projectResearch(research, "AU", "apvma");
  assertEquals(projection.extraction.label_reference, "https://elabels.apvma.gov.au/59688.pdf");
  assertEquals(projection.officialLabelCandidate?.trust, "official_register");
  // And there is exactly ONE label field — no second one was invented.
  assert(!("label_url" in projection.extraction));
  assert(!("sds_url" in projection.extraction));
});

Deno.test("§40.9/§14 a registrant product page fills productURL without becoming label authority", () => {
  const research = cloneResearch();
  const projection = projectResearch(research, "AU", "apvma");
  assertEquals(
    projection.extraction.productURL,
    "https://crop-solutions.basf.com.au/products/dithane-rainshield",
  );
  assert(projection.extraction.productURL !== projection.extraction.label_reference);
  assertEquals(projection.productPageCandidate?.isOfficialLabelCandidate, false);
});

Deno.test("§14 a reseller page is never accepted as the product page", () => {
  const research = cloneResearch();
  research.documents.product_page_candidates = [{
    url: "https://www.elders.com.au/products/dithane-rainshield-20kg",
    title: "Buy Dithane",
    domain: "elders.com.au",
    reason: "model thought this was the product page",
  }];
  const projection = projectResearch(research, "AU", "apvma");
  assertEquals(projection.extraction.productURL, null);
});

Deno.test("§12 country is a hard boundary — an AU registration is not an NZ hint", () => {
  const research = cloneResearch();
  // Same AU-registered finding, but the vineyard is in New Zealand.
  const hints = resolverHintsFor(research, "NZ", "acvm");
  assertEquals(hints, [], "an APVMA number must never be resolved as an ACVM identity");

  const auHints = resolverHintsFor(research, "AU", "apvma");
  assertEquals(auHints.map((h) => h.registrationNumber), ["59688"]);
});

Deno.test("§12 an APVMA host carries no label authority for an NZ lookup", () => {
  const forNz = classifyUrl("https://elabels.apvma.gov.au/59688.pdf", "NZ");
  assertEquals(forNz.isOfficialLabelCandidate, false);
  assertEquals(forNz.trust, "unknown");

  const forAu = classifyUrl("https://elabels.apvma.gov.au/59688.pdf", "AU");
  assertEquals(forAu.isOfficialLabelCandidate, true);
});

Deno.test("§12 NZ regulator hosts are trusted for NZ lookups", () => {
  const mpi = classifyUrl("https://www.mpi.govt.nz/dmsdocument/1234-approved-label", "NZ");
  assertEquals(mpi.trust, "official_register");
  assertEquals(mpi.isOfficialLabelCandidate, true);
});

Deno.test("§18 useful AI-only values still populate the review draft", () => {
  const research = cloneResearch();
  research.registration_candidates = []; // nothing registrable was found
  const projection = projectResearch(research, "AU", "apvma");

  // The genuinely useful facts survive for the operator to review…
  assertEquals(projection.extraction.product_name, "Dithane Rainshield Neo Tec Fungicide");
  assertEquals(projection.extraction.product_category, "fungicide");
  assertEquals((projection.extraction.active_ingredients as unknown[]).length, 1);
  // …and no registration identity is claimed.
  assertEquals(projection.extraction.registration_number, null);
});

Deno.test("§19 a blank stronger source does not erase a populated weaker one", () => {
  const structured = {
    product_name: "Dithane Rainshield",
    product_category: "fungicide",
    form_type: "solid",
    registration: {
      country_code: "AU",
      scheme: "apvma",
      registration_number: "59688",
      registrant: "BASF",
      registered_product_name: "Dithane",
      label_reference: "https://elabels.apvma.gov.au/59688.pdf",
      label_version: null,
    },
    active_ingredients: [],
    registered_uses: [{
      crop: "Grapevines",
      target_raw: "Downy Mildew",
      rates: [{
        label: "",
        basis: "per_100_litres",
        value: 200,
        min_value: null,
        max_value: null,
        unit: "g",
        raw_text: "200 g/100 L",
      }],
      withholding_period_days: null,
      re_entry_period_hours: 24,
      restrictions: null,
    }],
    verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
  };

  // A register result that supplies NO category and NO form type.
  const sparse = apvmaResolved({
    product_category: null,
    form_type: null,
    unresolved_fields: ["product_category", "form_type"],
  });
  const merged = mergeDiscoveryIntoStructured(structured, sparse);

  assertEquals(merged.product_category, "fungicide", "a blank register field must not erase this");
  assertEquals(merged.form_type, "solid");

  // Registered uses are the one field with a stricter rule, and it is an
  // EXISTING one this upgrade must not weaken: on a register-resolved
  // product only official label evidence may populate the authoritative
  // `registered_uses`. With no label evidence the research-read uses are not
  // deleted — they are retained, clearly tiered, in `ai_suggested_uses`, so
  // the operator still sees them in the editable draft (§18) while the
  // authoritative field honestly reads unresolved (§21).
  assertEquals(merged.registered_uses.length, 0);
  assertEquals(merged.ai_suggested_uses.length, 1, "the weaker value is retained, not erased");
  assertEquals(merged.ai_suggested_uses[0].rates[0].basis, "per_100_litres");
  assertEquals(merged.ai_suggested_uses[0].rates[0].value, 200);
});

Deno.test("§21/§22 every target and every rate basis survives projection", () => {
  const research = cloneResearch();
  research.registered_uses[0].targets = ["Powdery Mildew", "Downy Mildew", "Botrytis"];
  const projection = projectResearch(research, "AU", "apvma");
  const uses = projection.extraction.registered_uses as Record<string, unknown>[];

  assertEquals(uses.length, 3, "three targets must not collapse into one primary target");
  assertEquals(
    uses.map((u) => u.target),
    ["Powdery Mildew", "Downy Mildew", "Botrytis"],
  );

  // Both bases the label states are preserved, on every row, unconverted.
  for (const use of uses) {
    const rates = use.rates as Record<string, unknown>[];
    assertEquals(rates.length, 2);
    assertEquals(rates.map((r) => r.basis).sort(), ["per_100_litres", "per_hectare"]);
    assertEquals(rates.find((r) => r.basis === "per_100_litres")?.value, 200);
    assertEquals(rates.find((r) => r.basis === "per_hectare")?.value, 2);
  }
});

Deno.test("§21 a basis the contract cannot carry keeps its verbatim label text", () => {
  const research = cloneResearch();
  research.registered_uses[0].rates = [{
    label: "Row application",
    basis: "per_100_metres",
    value: 50,
    min_value: null,
    max_value: null,
    unit: "mL",
    raw_text: "50 mL per 100 m of row",
    source_refs: [],
  }];
  const projection = projectResearch(research, "AU", "apvma");
  const use = (projection.extraction.registered_uses as Record<string, unknown>[])[0];
  const rate = (use.rates as Record<string, unknown>[])[0];
  assertEquals(rate.basis, "other", "never restated as a basis it is not");
  assertEquals(rate.raw_text, "50 mL per 100 m of row", "the label's own words survive");
});

Deno.test("§28 unknown model fields cannot reach the extraction", () => {
  const research = cloneResearch() as unknown as Record<string, unknown>;
  research.injected_admin_flag = true;
  (research.product as Record<string, unknown>).is_approved_master = true;
  const projection = projectResearch(
    research as never,
    "AU",
    "apvma",
  );
  assert(!("injected_admin_flag" in projection.extraction));
  assert(!("is_approved_master" in projection.extraction));
  assertEquals(
    Object.keys(projection.extraction).sort(),
    [
      "active_ingredients",
      "form_type",
      "label_reference",
      "label_version",
      "product_category",
      "product_name",
      "productURL",
      "registered_uses",
      "registrant",
      "registration_number",
      "unresolved",
    ].sort(),
  );
});
