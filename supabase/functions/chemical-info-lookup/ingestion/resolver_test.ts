// Resolver upgrade tests — the general Chemical Lookup identity pipeline.
//
// Sprayseal is the REGRESSION FIXTURE here, not a special case: nothing in
// the implementation knows the name. The register facts are the LIVE APVMA
// PubCRIS values for product 80160 (retrieved 2026-08-20): "Sprayseal
// Pruning Wound Treatment", OMNIA SPECIALITIES (AUSTRALIA) PTY LTD,
// Tebuconazole 430 g/L, FUNGICIDE, SUSPENSION CONCENTRATE, regcode R
// (expires 30/06/2030), grapevine label claims. The mock datastore emulates
// the live CKAN behaviour that caused the original miss: full-text q matches
// whole WORDS, so q="Spray Seal" returns ZERO rows for a register name whose
// word is "Sprayseal".
//
// Required scenario coverage:
//   R01 exact Master match             R02 alias/spacing normalisation
//   R03 safe formulation normalisation R04 dangerous product variants
//   R05 authoritative-register match   R06 weak/ambiguous fails closed
//   R07 authoritative label enrichment R08 AI disagreement with authority
//   R09 missing vineyard country       R10 Sprayseal regression (end to end)
//   R11 AWRI variant protections stay in sync
//   R12 unresolved_fields ↔ field_provenance coherence (contract invariant)
//   R13 fail-closed: unresolved identity + plausible AI chemistry →
//       canonical fields stay unresolved (AI quarantined to ai_suggestion)
//   R14 fail-closed: ambiguous identity + plausible AI chemistry →
//       canonical fields stay unresolved
//   R15 resolved + AI disagreement → authoritative wins, conflict recorded,
//       the gate never strips a resolved result
//   R16 register unavailable / never consulted → degraded mode stays explicit
//   R17 Custodia 320SC production regression (fail closed, Forte never borrowed)
//   R18 Ridomil Gold production regression (ambiguous family fails closed)

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  compactProductName,
  nameCorresponds,
  nameMatchTier,
  retrievalQueryVariants,
  selectProductRow,
  VARIANT_TOKENS,
} from "./matching.ts";
import { VARIANT_TOKENS as AWRI_VARIANT_TOKENS } from "./seed_awri_match.ts";
import {
  jurisdictionEnvelope,
  registrationSchemeForCode,
  resolveLookupCountry,
} from "./jurisdiction.ts";
import {
  buildMasterStructuredResponse,
  fetchApprovedMaster,
  masterNameVariants,
  type MasterSelect,
} from "./master_lookup.ts";
import {
  buildCandidatePayload,
  buildFieldProvenance,
  discardUnverifiedAiIdentity,
  discoverAuthoritative,
  mergeDiscoveryIntoStructured,
  pruneAuthoritativelyResolvedFields,
  quarantineUnverifiedAiFacts,
} from "./ingest.ts";
import { APVMA_RESOURCES, clearApvmaCache } from "./apvma.ts";
import type { AdapterDeps } from "./contract.ts";

// ---------------------------------------------------------------------------
// Register fixture — live PubCRIS values for APVMA 80160
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

const SPRAYSEAL = {
  pcode: "80160",
  fpname: "Sprayseal Pruning Wound Treatment",
  sname: "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2030 0:00",
};

interface Fixture {
  products: Row[];
  prodcon: Record<string, Row[]>;
  constit: Record<string, string>;
  labelreg: Record<string, Row[]>;
  produse: Record<string, Row[]>;
  hosts: Record<string, string>;
  pests: Record<string, string>;
  prodcom: Record<string, Row[]>;
  requestLog: string[];
}

function sprayFixture(): Fixture {
  return {
    products: [SPRAYSEAL],
    prodcon: {
      "80160": [
        { pcode: "80160", ccode: "TZTB", ctype: "A", camount: "430.000000", cucode: "g/L" },
      ],
    },
    constit: { TZTB: "TEBUCONAZOLE" },
    labelreg: {
      "80160": [{ pcode: "80160", regno: "113355", regdate: "1/07/2025 0:00" }],
    },
    produse: {
      "80160": [
        { pcode: "80160", hostcode: "FRVG", pestcode: "YDIEB" },
        { pcode: "80160", hostcode: "FRVG", pestcode: "YROTB3" },
      ],
    },
    hosts: { FRVG: "GRAPEVINE" },
    pests: { YDIEB: "EUTYPA DIEBACK", YROTB3: "WOOD ROT" },
    prodcom: {
      "80160": [{
        pcode: "80160",
        seq: 1,
        applic:
          "WITHHOLDING PERIODS\nHarvest\nGRAPEVINES: DO NOT HARVEST FOR 4 WEEKS AFTER APPLICATION.",
      }],
    },
    requestLog: [],
  };
}

/**
 * Live-faithful CKAN emulation: full-text q matches when EVERY whitespace
 * token of q appears as a whole WORD of the product name (tsvector
 * behaviour). This reproduces the real failure: q="Spray Seal" → 0 rows for
 * "Sprayseal Pruning Wound Treatment"; q="sprayseal" → 1 row.
 */
function wordsMatch(q: string, fpname: string): boolean {
  const words = new Set(fpname.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean));
  return q.toLowerCase().split(/\s+/).filter(Boolean).every((t) => words.has(t));
}

function makeFetch(fixture: Fixture): typeof fetch {
  const respond = (records: Row[]): Response =>
    new Response(JSON.stringify({ success: true, result: { records } }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  return ((input: Request | URL | string): Promise<Response> => {
    const url = new URL(String(input));
    fixture.requestLog.push(url.toString());
    if (url.hostname !== "data.gov.au") {
      return Promise.reject(new Error(`forbidden host: ${url.hostname}`));
    }
    const resource = url.searchParams.get("resource_id") ?? "";
    const q = url.searchParams.get("q");
    const filtersRaw = url.searchParams.get("filters");
    // deno-lint-ignore no-explicit-any
    const filters: any = filtersRaw ? JSON.parse(filtersRaw) : null;

    let records: Row[] = [];
    if (resource === APVMA_RESOURCES.product) {
      records = fixture.products;
      if (filters?.pcode) records = records.filter((r) => r.pcode === filters.pcode);
      if (q) records = records.filter((r) => wordsMatch(q, String(r.fpname)));
    } else if (resource === APVMA_RESOURCES.productConstituents) {
      records = fixture.prodcon[filters?.pcode] ?? [];
    } else if (resource === APVMA_RESOURCES.constituentNames) {
      const codes: string[] = Array.isArray(filters?.ccode) ? filters.ccode : [];
      records = codes.map((c) => ({ ccode: c, cname: fixture.constit[c] })).filter((r) => r.cname);
    } else if (resource === APVMA_RESOURCES.labelRegistrations) {
      records = fixture.labelreg[filters?.pcode] ?? [];
    } else if (resource === APVMA_RESOURCES.productUses) {
      records = fixture.produse[filters?.pcode] ?? [];
    } else if (resource === APVMA_RESOURCES.hosts) {
      const codes: string[] = Array.isArray(filters?.hostcode) ? filters.hostcode : [];
      records = codes.map((c) => ({ hostcode: c, hostdesc: fixture.hosts[c] })).filter((r) => r.hostdesc);
    } else if (resource === APVMA_RESOURCES.pests) {
      const codes: string[] = Array.isArray(filters?.pestcode) ? filters.pestcode : [];
      records = codes.map((c) => ({ pestcode: c, pestdesc: fixture.pests[c] })).filter((r) => r.pestdesc);
    } else if (resource === APVMA_RESOURCES.productComments) {
      records = fixture.prodcom[filters?.pcode] ?? [];
    }
    return Promise.resolve(respond(records));
  }) as typeof fetch;
}

function deps(fixture: Fixture): AdapterDeps {
  return { fetchFn: makeFetch(fixture), now: () => new Date("2026-08-20T00:00:00Z") };
}

/** The fabricated AI extraction the OLD pipeline served for "Spray Seal". */
// deno-lint-ignore no-explicit-any
function fabricatedAiStructured(): any {
  return {
    product_name: "Spray Seal",
    product_category: "other",
    form_type: "liquid",
    registration: {
      country_code: "AU",
      scheme: null,
      registration_number: null,
      registrant: "Horticultural Alliance",
      registered_product_name: null,
      label_reference: null,
      label_version: null,
    },
    active_ingredients: [{
      name: "Polymeric Terpenes",
      concentration: 600,
      concentration_unit: "g/L",
      activity_group: null,
      group_source: "unresolved",
      identity_source: "ai_interpretation",
    }],
    activity_groups: [],
    activity_group_scheme: null,
    registered_uses: [{
      crop: "Apples",
      target_raw: "Collar rot",
      rates: [],
      withholding_period_days: null,
      re_entry_period_hours: null,
      restrictions: null,
    }],
    label_rate_bases: [],
    verification: {
      status: "unverified",
      sources: [{ kind: "ai_interpretation", name: "Model extraction (test)", reference: null, retrieved_at: null }],
      conflicts: [],
      unresolved_fields: ["registration_number"],
      verified_at: null,
    },
    activity_group_table_version: 1,
    schema_version: 1,
  };
}

// ---------------------------------------------------------------------------
// Master catalogue fakes
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
function masterRow(partial: Row = {}): any {
  return {
    id: "master-1",
    registration_country: "AU",
    registration_scheme: "apvma",
    registration_number: "80160",
    registration_identity_key: "AU:apvma:80160",
    registrant: "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
    registered_product_name: "Sprayseal Pruning Wound Treatment",
    common_names: ["sprayseal"],
    product_category: "fungicide",
    form_type: "liquid",
    active_ingredients: [{
      name: "Tebuconazole",
      concentration: 430,
      concentration_unit: "g/L",
      activity_group: { scheme: "frac", code: "3", common_name: "DMI" },
      group_source: "authoritative_classification",
      identity_source: "official_register",
    }],
    activity_groups: ["3"],
    activity_group_scheme: "frac",
    registered_uses: [],
    label_rate_bases: [],
    label_reference: null,
    label_version: "APVMA label approval 113355 (1/07/2025)",
    verification_status: "partially_verified",
    verification_sources: [],
    verification_conflicts: [],
    verification_unresolved_fields: [],
    verified_at: null,
    source_kind: "official_register",
    source_reference: null,
    retrieved_at: "2026-08-01T00:00:00Z",
    review_status: "approved",
    catalogue_version: 3,
    activity_group_table_version: 1,
    intelligence_schema_version: 1,
    ...partial,
  };
}

/** Fake PostgREST select that answers exact-equality variant queries. */
function fakeSelect(
  rowsByNeedle: Record<string, Row[]>,
  log: string[],
): MasterSelect {
  return (query: string) => {
    log.push(decodeURIComponent(query));
    const decoded = decodeURIComponent(query).toLowerCase();
    for (const [needle, rows] of Object.entries(rowsByNeedle)) {
      if (decoded.includes(needle.toLowerCase())) return Promise.resolve(rows);
    }
    return Promise.resolve([]);
  };
}

// ===========================================================================
// R01 — exact Master match
// ===========================================================================

Deno.test("R01: exact Master match — approved, country-scoped, unique-or-nothing; identity hint outranks the name", async () => {
  // Exact registered name resolves the single approved row.
  const log: string[] = [];
  const row = masterRow();
  const byName = await fetchApprovedMaster(
    fakeSelect({ '"sprayseal pruning wound treatment"': [row] }, log),
    "Sprayseal Pruning Wound Treatment",
    "AU",
    "",
    null,
  );
  assert(byName, "exact approved name must resolve");
  assertEquals(byName.registration_identity_key, "AU:apvma:80160");
  assert(log[0].includes("review_status=eq.approved"), "only approved rows are served");
  assert(log[0].includes("registration_country=eq.AU"), "always country-scoped");
  assert(!log[0].includes("%25"), "master name matching is whole-string — never a wildcard");

  // The registration identity hint is deterministic and wins first.
  const log2: string[] = [];
  const byIdentity = await fetchApprovedMaster(
    fakeSelect({ "registration_identity_key=eq.au:apvma:80160": [row] }, log2),
    "some stale display name",
    "AU",
    "80160",
    "apvma",
  );
  assert(byIdentity, "identity hint must resolve directly");
  assert(log2[0].includes("registration_identity_key"), "identity query fires first");

  // Two approved rows answering one name = not unique = nothing (fail closed).
  const dupes = await fetchApprovedMaster(
    fakeSelect({ '"sprayseal"': [row, masterRow({ id: "master-2" })] }, []),
    "Sprayseal",
    "AU",
    "",
    null,
  );
  assertEquals(dupes, null, "a non-unique name match must fail closed");

  // Cross-country rows are never served, whatever the query matched.
  const wrongCountry = await fetchApprovedMaster(
    fakeSelect({ '"sprayseal"': [masterRow({ registration_country: "NZ" })] }, []),
    "Sprayseal",
    "AU",
    "",
    null,
  );
  assertEquals(wrongCountry, null, "jurisdiction assertion holds");

  // The served master response keeps the full contract + provenance.
  const served = buildMasterStructuredResponse(row);
  assertEquals(served.match_source, "master");
  assertEquals(served.registration.registration_number, "80160");
  assertEquals(served.field_provenance.registration, "master_catalogue");
  assertEquals(served.field_provenance.registered_uses, "unresolved");
});

// ===========================================================================
// R02 — alias/spacing normalisation
// ===========================================================================

Deno.test("R02: alias/spacing normalisation — 'Spray Seal' reaches the Master row named 'Sprayseal' via exact-equality typography variants", async () => {
  assertEquals(masterNameVariants("Spray Seal"), ["Spray Seal", "sprayseal"]);

  const log: string[] = [];
  const row = masterRow({ registered_product_name: "Sprayseal" });
  const hit = await fetchApprovedMaster(
    fakeSelect({ '"sprayseal"': [row] }, log),
    "Spray Seal",
    "AU",
    "",
    null,
  );
  assert(hit, "compact variant must resolve the master row");
  assertEquals(hit.registered_product_name, "Sprayseal");
  assertEquals(log.length, 2, "verbatim query first, compact variant second");
  assert(log[1].includes('"sprayseal"'), "second query carries the compact form");

  // Alias matching stays exact whole-string: lower-cased alias equality.
  assertEquals(nameMatchTier("Spray Seal", "Sprayseal"), "compact_name");
  assertEquals(nameMatchTier("SPRAYSEAL", "Sprayseal"), "exact_name");
});

// ===========================================================================
// R03 — safe formulation normalisation
// ===========================================================================

Deno.test("R03: safe formulation normalisation — 250SC ↔ 250 SC typography and droppable category/use words, in both directions", () => {
  assertEquals(nameMatchTier("Custodia 320SC", "CUSTODIA 320 SC FUNGICIDE"), "formulation_suffix");
  assertEquals(nameMatchTier("CUSTODIA 320 SC", "Custodia 320SC"), "compact_name");
  assertEquals(nameMatchTier("Prosaro 420SC", "PROSARO 420 SC FOLIAR FUNGICIDE"), "formulation_suffix");
  assertEquals(
    nameMatchTier("Prosaro 420 SC Foliar Fungicide", "PROSARO 420 SC"),
    "reverse_formulation_suffix",
  );
  assertEquals(nameMatchTier("Sprayseal", "Sprayseal Pruning Wound Treatment"), "formulation_suffix");
  assertEquals(compactProductName("Custodia 320SC"), "custodia320sc");
  assertEquals(retrievalQueryVariants("Spray Seal"), ["Spray Seal", "sprayseal", "spray seal"]);

  // Selection prefers the strongest tier: an exact register name outranks a
  // formulation-suffix correspondence — identity beats similarity.
  const exact = { pcode: "1", fpname: "CUSTODIA 320 SC" };
  const suffixed = { pcode: "2", fpname: "CUSTODIA 320 SC FUNGICIDE" };
  const picked = selectProductRow(["Custodia 320 SC"], [suffixed, exact]);
  assert(picked !== null && picked !== "ambiguous");
  assertEquals(picked.row.pcode, "1");
  assertEquals(picked.mode, "exact_name");
});

// ===========================================================================
// R04 — dangerous product variants
// ===========================================================================

Deno.test("R04: dangerous product variants — variant designators are identity on BOTH sides; substrings are structurally impossible", () => {
  assertEquals(nameCorresponds("Custodia", "CUSTODIA FORTE FUNGICIDE"), false);
  assertEquals(nameCorresponds("Weedmaster", "WEEDMASTER DUO"), false);
  assertEquals(nameCorresponds("Revus", "REVUS TOP"), false);
  assertEquals(nameCorresponds("Sprayseal Ultra", "Sprayseal Pruning Wound Treatment"), false);
  // Reverse direction: a variant request can never fall back to the base product.
  assertEquals(nameCorresponds("Custodia Forte", "CUSTODIA"), false);
  assertEquals(nameCorresponds("Custodia Forte", "CUSTODIA 320 SC FUNGICIDE"), false);
  // Substring/containment never matches.
  assertEquals(nameCorresponds("Custodia", "MY CUSTODIA"), false);
  assertEquals(nameCorresponds("Spray", "Sprayseal Pruning Wound Treatment"), false);

  // Variant sibling present: the base name still resolves the base product
  // uniquely — the variant row is structurally excluded, not out-scored.
  const base = { pcode: "66541", fpname: "CUSTODIA 320 SC FUNGICIDE" };
  const forte = { pcode: "91636", fpname: "CUSTODIA FORTE FUNGICIDE" };
  const picked = selectProductRow(["Custodia"], [base, forte]);
  assert(picked !== null && picked !== "ambiguous");
  assertEquals(picked.row.pcode, "66541");
});

// ===========================================================================
// R05 — authoritative-register match
// ===========================================================================

Deno.test("R05: authoritative-register match — 'Spray Seal' resolves APVMA 80160 with register-backed chemistry despite zero-row raw retrieval", async () => {
  clearApvmaCache();
  const fixture = sprayFixture();
  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps(fixture));

  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration;
  assert(reg, "registration must be present");
  assertEquals(reg.registration_identity_key, "AU:apvma:80160");
  assertEquals(reg.registered_product_name, "Sprayseal Pruning Wound Treatment");
  assertEquals(reg.registrant, "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD");
  assertEquals(reg.product_category, "fungicide");
  assertEquals(reg.form_type, "liquid");
  assertEquals(reg.match_mode, "formulation_suffix");
  assertEquals(reg.active_ingredients.length, 1);
  assertEquals(reg.active_ingredients[0].name, "Tebuconazole");
  assertEquals(reg.active_ingredients[0].concentration, 430);
  assertEquals(reg.active_ingredients[0].concentration_unit, "g/L");
  assertEquals(reg.active_ingredients[0].activity_group?.code, "3");
  assertEquals(reg.active_ingredients[0].activity_group?.scheme, "frac");
  assertEquals(reg.active_ingredients[0].identity_source, "official_register");

  // Retrieval provably needed the typography variant: the raw spaced query
  // ran first (live behaviour: zero rows), then the compact form found it.
  const productQueries = fixture.requestLog.filter((u) =>
    u.includes(APVMA_RESOURCES.product) && u.includes("q=")
  );
  assert(productQueries[0].includes("q=Spray+Seal") || productQueries[0].includes("q=Spray%20Seal"));
  assert(productQueries.some((u) => u.includes("q=sprayseal")), "compact retrieval variant fired");
});

// ===========================================================================
// R06 — weak/ambiguous match fails closed
// ===========================================================================

Deno.test("R06: weak or ambiguous matches fail closed — two candidates bind nothing, and a meaningful word never drops", async () => {
  // Two register rows both corresponding at the same tier → ambiguous.
  clearApvmaCache();
  const twin = sprayFixture();
  twin.products = [
    { ...SPRAYSEAL, fpname: "SPRAYSEAL FUNGICIDE" },
    { pcode: "99999", fpname: "SPRAYSEAL LIQUID", sname: "OTHER PTY LTD", hlevel1: "FUNGICIDE", fdesc: "SUSPENSION CONCENTRATE", regcode: "R", expdate: null },
  ];
  const ambiguous = await discoverAuthoritative("AU", "Spray Seal", null, deps(twin));
  assertEquals(ambiguous.outcome, "ambiguous");
  assertEquals(ambiguous.registration, undefined);

  // A similarly named but MEANINGFULLY different product never binds: the
  // lookup stays unresolved rather than borrowing the closest name.
  clearApvmaCache();
  const fixture = sprayFixture();
  const weak = await discoverAuthoritative("AU", "Sprayseal Blue", null, deps(fixture));
  assertEquals(weak.outcome, "unresolved");
  assertEquals(weak.registration, undefined);
});

// ===========================================================================
// R07 — authoritative label enrichment
// ===========================================================================

Deno.test("R07: authoritative label enrichment — registered uses, WHP and restrictions come from the approved label's published claim data", async () => {
  clearApvmaCache();
  const fixture = sprayFixture();
  const discovery = await discoverAuthoritative("AU", "Sprayseal", null, deps(fixture));
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration;
  assert(reg && reg.label_evidence, "label evidence must resolve from the register's claim data");

  const merged = mergeDiscoveryIntoStructured(fabricatedAiStructured(), reg);
  assertEquals(merged.registered_uses.length, 2, "the label's claim set IS the served uses");
  const crops = new Set(merged.registered_uses.map((u: Row) => u.crop));
  assertEquals(crops.size, 1);
  assert(crops.has("GRAPEVINE"));
  for (const use of merged.registered_uses) {
    assertEquals(use.withholding_period_days, 28, "grape WHP '4 WEEKS' = 28 days from the label statement");
    assertEquals(use.provenance.claim, "manufacturer_label");
    assertEquals(use.provenance.withholding_period, "manufacturer_label");
    assert(String(use.restrictions).includes("DO NOT HARVEST FOR 4 WEEKS"));
  }
  assertEquals(merged.field_provenance.registered_uses, "manufacturer_label");
  assertEquals(merged.field_provenance.withholding_periods, "manufacturer_label");
  // The register publishes no machine-readable rate table: rates stay honest gaps.
  assertEquals(merged.field_provenance.label_rates, "unresolved");
  assert(merged.verification.unresolved_fields.includes("rates:GRAPEVINE"));
  assert(
    merged.verification.sources.some((s: Row) => s.kind === "manufacturer_label"),
    "label evidence cited as manufacturer_label",
  );
  // The AI's fabricated use (Apples × Collar rot) is NOT served — it is a conflict.
  assert(
    merged.verification.conflicts.some((c: Row) => c.field === "registered_uses"),
    "AI-only use recorded as a conflict, not served",
  );
});

// ===========================================================================
// R08 — AI disagreement with authoritative evidence
// ===========================================================================

Deno.test("R08: AI disagreement with authoritative evidence — the register wins, the disagreement is a recorded conflict, never a silent overwrite", async () => {
  clearApvmaCache();
  const fixture = sprayFixture();
  const discovery = await discoverAuthoritative("AU", "Sprayseal", null, deps(fixture));
  const reg = discovery.registration;
  assert(reg);

  const ai = fabricatedAiStructured();
  ai.registration.registration_number = "89999"; // fabricated identity claim
  const merged = mergeDiscoveryIntoStructured(ai, reg);

  // Register identity served; the AI's number recorded as a conflict.
  assertEquals(merged.registration.registration_number, "80160");
  assert(
    merged.verification.conflicts.some(
      (c: Row) => c.field === "registration_number" && c.extracted_value === "89999",
    ),
    "fabricated registration number is a structured conflict",
  );
  // Register chemistry served; the fabricated active recorded as a conflict.
  assertEquals(merged.active_ingredients.length, 1);
  assertEquals(merged.active_ingredients[0].name, "Tebuconazole");
  assert(
    merged.verification.conflicts.some(
      (c: Row) =>
        c.field === "active_ingredients" && c.active_ingredient_name === "Polymeric Terpenes",
    ),
    "fabricated active ingredient is a structured conflict",
  );
  assertEquals(merged.registration.registrant, "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD");
  assertEquals(merged.verification.status, "conflict", "disagreement forces the conflict state");
  assertEquals(merged.field_provenance.registration, "official_register");
  assertEquals(merged.field_provenance.active_ingredients, "official_register");

  // And when the register was consulted but did NOT verify: unverified AI
  // identity claims are DISCARDED, never served as facts.
  const unverified = fabricatedAiStructured();
  unverified.registration.registration_number = "89999";
  unverified.registration.scheme = "apvma";
  unverified.registration.registered_product_name = "Spray Seal";
  const discarded = discardUnverifiedAiIdentity(unverified, "unresolved");
  assertEquals(discarded, "89999");
  assertEquals(unverified.registration.registration_number, null);
  assertEquals(unverified.registration.scheme, null);
  assertEquals(unverified.registration.registered_product_name, null);
  assert(unverified.verification.unresolved_fields.includes("registration_number"));
  // An outage is NOT "checked and wrong": claims stay attributed, not discarded.
  const outage = fabricatedAiStructured();
  outage.registration.registration_number = "89999";
  assertEquals(discardUnverifiedAiIdentity(outage, "source_unavailable"), null);
  assertEquals(outage.registration.registration_number, "89999");
});

// ===========================================================================
// R09 — missing vineyard country
// ===========================================================================

Deno.test("R09: vineyard country contract — one resolved jurisdiction, display names and aliases resolve, nothing falls back", async () => {
  // Missing country: no jurisdiction, no register, explicit envelope.
  const missing = resolveLookupCountry("");
  assertEquals(missing.code, null);
  assertEquals(jurisdictionEnvelope(missing).register_support, "missing");
  assertEquals(jurisdictionEnvelope(missing).requested_country, null);
  const none = await discoverAuthoritative("", "Sprayseal", null, {
    fetchFn: (() => Promise.reject(new Error("must not be called"))) as typeof fetch,
    now: () => new Date(),
  });
  assertEquals(none.outcome, "no_country");

  // Unrecognised country: surfaced as unrecognised — never coerced.
  const odd = resolveLookupCountry("Straya");
  assertEquals(odd.code, null);
  assertEquals(jurisdictionEnvelope(odd).register_support, "unrecognised");
  assertEquals(jurisdictionEnvelope(odd).requested_country, "Straya");

  // The contract's storage format (display names) resolves server-side now.
  assertEquals(resolveLookupCountry("Australia").code, "AU");
  assertEquals(resolveLookupCountry("australia").code, "AU");
  assertEquals(resolveLookupCountry("AU").code, "AU");
  assertEquals(resolveLookupCountry("New Zealand").code, "NZ");
  assertEquals(resolveLookupCountry("united states of america").code, "US");
  assertEquals(resolveLookupCountry("uk").code, "GB", "contract alias beats bare-code passthrough");
  assertEquals(resolveLookupCountry("France").code, "FR");

  // Register support states are explicit per jurisdiction.
  assertEquals(jurisdictionEnvelope(resolveLookupCountry("Australia")).register_support, "supported");
  assertEquals(jurisdictionEnvelope(resolveLookupCountry("Australia")).register_adapter, "apvma");
  assertEquals(jurisdictionEnvelope(resolveLookupCountry("New Zealand")).register_support, "declared");
  assertEquals(jurisdictionEnvelope(resolveLookupCountry("France")).register_support, "none");

  // Scheme mapping follows the resolved code — nothing else.
  assertEquals(registrationSchemeForCode("AU"), "apvma");
  assertEquals(registrationSchemeForCode("NZ"), "acvm");
  assertEquals(registrationSchemeForCode(null), null);

  // A supported jurisdiction never leaks into an unsupported request.
  const fr = await discoverAuthoritative("FR", "Sprayseal", null, {
    fetchFn: (() => Promise.reject(new Error("must not be called"))) as typeof fetch,
    now: () => new Date(),
  });
  assertEquals(fr.outcome, "not_supported");
});

// ===========================================================================
// R10 — Sprayseal regression (end to end)
// ===========================================================================

Deno.test("R10: Sprayseal regression — 'Spray Seal' for an AU vineyard serves APVMA 80160 / Omnia / Tebuconazole 430 g/L / Group 3, not the fabricated AI result", async () => {
  // BEFORE (documented failure mode): raw-query-only retrieval finds nothing,
  // so the old pipeline fell through to the fabricated AI answer.
  const rawOnlyRows: { pcode: string; fpname: string }[] = [];
  assertEquals(wordsMatch("Spray Seal", SPRAYSEAL.fpname), false, "live CKAN: spaced q misses the compact register name");
  assertEquals(selectProductRow(["Spray Seal"], rawOnlyRows), null);

  // AFTER: the upgraded general resolver.
  clearApvmaCache();
  const fixture = sprayFixture();
  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps(fixture));
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration;
  assert(reg);

  const merged = mergeDiscoveryIntoStructured(fabricatedAiStructured(), reg);

  // Identity: the authoritative Sprayseal, nothing else.
  assertEquals(merged.product_name, "Sprayseal Pruning Wound Treatment");
  assertEquals(merged.registration.country_code, "AU");
  assertEquals(merged.registration.scheme, "apvma");
  assertEquals(merged.registration.registration_number, "80160");
  assertEquals(merged.registration.registrant, "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD");
  assertEquals(merged.registration.registered_product_name, "Sprayseal Pruning Wound Treatment");
  assertEquals(merged.product_category, "fungicide");

  // Chemistry: register-backed Tebuconazole 430 g/L, FRAC Group 3.
  assertEquals(merged.active_ingredients.length, 1);
  assertEquals(merged.active_ingredients[0].name, "Tebuconazole");
  assertEquals(merged.active_ingredients[0].concentration, 430);
  assertEquals(merged.active_ingredients[0].concentration_unit, "g/L");
  assertEquals(merged.activity_groups, ["3"]);
  assertEquals(merged.activity_group_scheme, "frac");

  // The fabricated result is gone from every served fact — and recorded.
  assert(!JSON.stringify(merged.active_ingredients).includes("Polymeric Terpenes"));
  assert(!JSON.stringify(merged.registration).includes("Horticultural Alliance"));
  assert(merged.verification.conflicts.length > 0, "the disagreement is on the record");
  assertEquals(merged.match_source, "authoritative_candidate");

  // Uses/WHP/restrictions only from label evidence; rates honestly unresolved.
  assertEquals(merged.registered_uses.length, 2);
  assertEquals(merged.field_provenance.registered_uses, "manufacturer_label");
  assert(merged.verification.unresolved_fields.includes("rates:GRAPEVINE"));

  // The catalogue candidate this enqueues is register-provenance, candidate-only,
  // with the requested spelling captured as a search alias.
  const payload = buildCandidatePayload(merged, "Spray Seal", reg, "2026-08-20T00:00:00Z", 1);
  assert(payload);
  assertEquals(payload.review_status, "candidate");
  assertEquals(payload.source_kind, "official_register");
  assertEquals(payload.registration_number, "80160");
  assert(payload.common_names.includes("spray seal"));
});

// ===========================================================================
// R11 — AWRI variant protections stay in sync
// ===========================================================================

Deno.test("R11: the live matcher's variant guard is the AWRI Stage 5E set, verbatim — and no variant token is ever ignorable", () => {
  assertEquals(
    Array.from(VARIANT_TOKENS).sort(),
    Array.from(AWRI_VARIANT_TOKENS).sort(),
    "matching.ts VARIANT_TOKENS must mirror seed_awri_match.ts exactly",
  );
  for (const token of VARIANT_TOKENS) {
    assertEquals(
      nameCorresponds("Product", `PRODUCT ${token.toUpperCase()}`),
      false,
      `variant token '${token}' must always block a suffix match`,
    );
  }
});

// ===========================================================================
// Fail-closed fixtures — plausible AI extractions + register families
// ===========================================================================

function frac(code: string, commonName: string): Row {
  return { scheme: "frac", code, common_name: commonName };
}

function aiActive(name: string, concentration: number, group: Row | null): Row {
  return {
    name,
    concentration,
    concentration_unit: "g/L",
    activity_group: group,
    group_source: group ? "authoritative_classification" : "unresolved",
    identity_source: "ai_interpretation",
  };
}

function grapeUse(target: string, whpDays: number): Row {
  return {
    crop: "Grapes (winegrapes)",
    target_raw: target,
    rates: [{
      label: "Standard rate",
      basis: "per_hectare",
      value: 1.5,
      min_value: null,
      max_value: null,
      unit: "L",
      raw_text: null,
    }],
    withholding_period_days: whpDays,
    re_entry_period_hours: null,
    restrictions: null,
  };
}

/**
 * A PLAUSIBLE post-extraction structured result — the shape
 * buildStructuredResponse serves when the model answers confidently. This is
 * exactly the payload that must never survive a checked-but-unverified
 * register consult as canonical facts.
 */
// deno-lint-ignore no-explicit-any
function plausibleAi(
  productName: string,
  registrant: string,
  registrationNumber: string | null,
  actives: Row[],
  uses: Row[],
): any {
  return {
    product_name: productName,
    product_category: "fungicide",
    form_type: "liquid",
    registration: {
      country_code: "AU",
      scheme: registrationNumber ? "apvma" : null,
      registration_number: registrationNumber,
      registrant,
      registered_product_name: productName,
      label_reference: null,
      label_version: null,
    },
    active_ingredients: actives,
    activity_groups: actives
      .map((a) => a.activity_group?.code)
      .filter((c: string | undefined): c is string => Boolean(c)),
    activity_group_scheme: "frac",
    registered_uses: uses,
    label_rate_bases: ["per_hectare"],
    verification: {
      status: "partially_verified",
      sources: [
        {
          kind: "ai_interpretation",
          name: "Model extraction (test)",
          reference: null,
          retrieved_at: null,
        },
        {
          kind: "authoritative_classification",
          name: "VineTrack activity group reference v1 (FRAC/HRAC/IRAC)",
          reference: null,
          retrieved_at: null,
        },
      ],
      conflicts: [],
      unresolved_fields: ["label_reference"],
      verified_at: null,
    },
    activity_group_table_version: 1,
    schema_version: 1,
  };
}

/** Production-shaped Custodia 320SC AI payload (baseline regression run). */
// deno-lint-ignore no-explicit-any
function custodia320Ai(): any {
  return plausibleAi(
    "Custodia 320SC",
    "BASF Australia Ltd",
    "80000",
    [aiActive("Fluopyram", 320, frac("7", "SDHI"))],
    [grapeUse("Powdery mildew", 14)],
  );
}

/** Production-shaped Ridomil Gold AI payload (baseline regression run). */
// deno-lint-ignore no-explicit-any
function ridomilGoldAi(): any {
  return plausibleAi(
    "Ridomil Gold",
    "Syngenta Australia Pty Ltd",
    "55180",
    [
      aiActive("Metalaxyl", 200, frac("4", "Phenylamide")),
      aiActive("Mancozeb", 600, frac("M3", "Multi-site / Dithiocarbamate")),
    ],
    [grapeUse("Downy mildew", 14)],
  );
}

const CUSTODIA_FORTE: Row = {
  pcode: "91636",
  fpname: "CUSTODIA FORTE FUNGICIDE",
  sname: "ADAMA AUSTRALIA PTY LIMITED",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2029 0:00",
};

/** A register fixture holding only product identity rows (no detail data). */
function registerFixture(products: Row[]): Fixture {
  return {
    products,
    prodcon: {},
    constit: {},
    labelreg: {},
    produse: {},
    hosts: {},
    pests: {},
    prodcom: {},
    requestLog: [],
  };
}

/**
 * The strict fail-closed canonical contract, asserted whole: no AI-derived
 * product fact survives outside `ai_suggestion`, provenance reads unresolved
 * everywhere, no per-context unresolved entry leaks AI chemistry, and no
 * Master candidate can be minted.
 */
// deno-lint-ignore no-explicit-any
function assertFailClosedCanonical(structured: any, forbidden: string[]): void {
  assertEquals(structured.match_source, "unresolved");
  assertEquals(structured.product_name, null);
  assertEquals(structured.product_category, "");
  assertEquals(structured.form_type, null);
  assertEquals(structured.registration.registration_number, null);
  assertEquals(structured.registration.scheme, null);
  assertEquals(structured.registration.registrant, null);
  assertEquals(structured.registration.registered_product_name, null);
  assertEquals(structured.registration.label_reference, null);
  assertEquals(structured.registration.label_version, null);
  assertEquals(structured.active_ingredients, []);
  assertEquals(structured.activity_groups, []);
  assertEquals(structured.activity_group_scheme, null);
  assertEquals(structured.registered_uses, []);
  assertEquals(structured.label_rate_bases, []);
  assertEquals(structured.verification.status, "unverified");
  assertEquals(structured.verification.conflicts, []);
  assert(
    structured.verification.sources.every((s: Row) => s.kind === "ai_interpretation"),
    "only the model consult stays cited on a fail-closed response",
  );
  for (const entry of structured.verification.unresolved_fields) {
    assert(
      !String(entry).includes(":"),
      `per-context entry '${entry}' would leak unverified AI chemistry`,
    );
  }
  for (
    const field of [
      "registration_number",
      "registrant",
      "active_ingredients",
      "activity_groups",
      "registered_uses",
      "product_name",
      "form_type",
      "product_category",
      "label_reference",
    ]
  ) {
    assert(
      structured.verification.unresolved_fields.includes(field),
      `${field} must be listed unresolved`,
    );
  }
  for (const [field, prov] of Object.entries(structured.field_provenance)) {
    assertEquals(prov, "unresolved", `field_provenance.${field}`);
  }
  assert(
    String(structured.guidance).includes("could not uniquely verify"),
    "operator guidance present",
  );

  const canonical: Record<string, unknown> = { ...structured };
  delete canonical.ai_suggestion;
  const json = JSON.stringify(canonical);
  for (const needle of forbidden) {
    assert(!json.includes(needle), `canonical envelope must not contain "${needle}"`);
  }

  // No Master candidate may be created from a fail-closed response.
  assertEquals(
    buildCandidatePayload(structured, "requested name", null, "2026-08-20T00:00:00Z", 1),
    null,
  );
}

// ===========================================================================
// R12 — unresolved_fields ↔ field_provenance coherence (contract invariant)
// ===========================================================================

Deno.test("R12: a populated field with authoritative provenance is never listed unresolved — stale AI-era entries are pruned on merge and at master serve time", async () => {
  // Register merge: the AI extraction (like production) marked register-
  // answerable fields unresolved; the register populates them, so the
  // entries must go — while genuine gaps stay.
  clearApvmaCache();
  const fixture = sprayFixture();
  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps(fixture));
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration;
  assert(reg);

  const ai = fabricatedAiStructured();
  ai.verification.unresolved_fields = [
    "product_name",
    "product_category",
    "form_type",
    "registrant",
    "registration_number",
  ];
  const merged = mergeDiscoveryIntoStructured(ai, reg);

  for (const field of ["product_name", "product_category", "form_type", "registrant"]) {
    assertEquals(merged.field_provenance[field], "official_register");
    assert(
      !merged.verification.unresolved_fields.includes(field),
      `${field} is register-populated — must not be listed unresolved`,
    );
  }
  // Genuine gaps survive: per-context label gaps and truly-empty fields.
  assert(merged.verification.unresolved_fields.includes("rates:GRAPEVINE"));
  assert(merged.verification.unresolved_fields.includes("label_reference"));

  // AI-populated is NOT authoritative: with no register behind them, the
  // displayed values stay honestly listed as unresolved.
  const aiOnly = fabricatedAiStructured();
  aiOnly.verification.unresolved_fields = ["registrant", "product_category"];
  aiOnly.field_provenance = buildFieldProvenance(aiOnly, null, false);
  pruneAuthoritativelyResolvedFields(aiOnly);
  assertEquals(aiOnly.field_provenance.registrant, "ai_interpretation");
  assert(
    aiOnly.verification.unresolved_fields.includes("registrant"),
    "an AI-supplied registrant is present but unverified — stays unresolved",
  );
  assert(aiOnly.verification.unresolved_fields.includes("product_category"));

  // Master serve time: rows stored before the invariant serve clean without
  // any data rewrite — catalogue-held fields are pruned, real gaps stay.
  const staleRow = masterRow({
    verification_unresolved_fields: [
      "product_name",
      "registrant",
      "rates:GRAPEVINE",
      "label_reference",
    ],
  });
  const served = buildMasterStructuredResponse(staleRow);
  assertEquals(served.field_provenance.product_name, "master_catalogue");
  assert(!served.verification.unresolved_fields.includes("product_name"));
  assert(!served.verification.unresolved_fields.includes("registrant"));
  assert(served.verification.unresolved_fields.includes("rates:GRAPEVINE"));
  assert(
    served.verification.unresolved_fields.includes("label_reference"),
    "label_reference is null on the row — genuinely unresolved, stays listed",
  );
});

// ===========================================================================
// R13 — fail-closed: unresolved identity + plausible AI chemistry
// ===========================================================================

Deno.test("R13: unresolved identity + plausible AI chemistry — canonical fields stay unresolved; the AI reading is quarantined to ai_suggestion", async () => {
  // The register was successfully consulted (no outage) and holds no such
  // product — identity is checked-but-unverified.
  clearApvmaCache();
  const discovery = await discoverAuthoritative(
    "AU",
    "Custodia 320SC",
    null,
    deps(sprayFixture()),
  );
  assertEquals(discovery.outcome, "unresolved");
  assertEquals(discovery.registration, undefined);

  // The model still answered confidently. Identity is discarded first (as in
  // the serving path), then EVERY remaining AI product fact is quarantined.
  const structured = custodia320Ai();
  assertEquals(discardUnverifiedAiIdentity(structured, discovery.outcome), "80000");
  assertEquals(quarantineUnverifiedAiFacts(structured, discovery.outcome, "Australia"), true);

  assertFailClosedCanonical(structured, ["Fluopyram", "BASF", "Powdery mildew"]);

  // The advisory — clearly separated — keeps the AI reading for the operator.
  assertEquals(structured.ai_suggestion.product_name, "Custodia 320SC");
  assertEquals(structured.ai_suggestion.registrant, "BASF Australia Ltd");
  assertEquals(structured.ai_suggestion.active_ingredients[0].name, "Fluopyram");
  assertEquals(structured.ai_suggestion.registered_uses[0].withholding_period_days, 14);
  assert(String(structured.ai_suggestion.note).toLowerCase().includes("unverified"));
});

// ===========================================================================
// R14 — fail-closed: ambiguous identity + plausible AI chemistry
// ===========================================================================

Deno.test("R14: ambiguous identity + plausible AI chemistry — canonical fields stay unresolved; ambiguity is never resolved by the AI", async () => {
  // Two register rows correspond at the same tier — checked, ambiguous.
  clearApvmaCache();
  const twin = sprayFixture();
  twin.products = [
    { ...SPRAYSEAL, fpname: "SPRAYSEAL FUNGICIDE" },
    {
      pcode: "99999",
      fpname: "SPRAYSEAL LIQUID",
      sname: "OTHER PTY LTD",
      hlevel1: "FUNGICIDE",
      fdesc: "SUSPENSION CONCENTRATE",
      regcode: "R",
      expdate: null,
    },
  ];
  const discovery = await discoverAuthoritative("AU", "Spray Seal", null, deps(twin));
  assertEquals(discovery.outcome, "ambiguous");
  assertEquals(discovery.registration, undefined);

  const structured = plausibleAi(
    "Spray Seal",
    "Omnia Specialities (Australia) Pty Ltd",
    null,
    [aiActive("Tebuconazole", 430, frac("3", "DMI / Triazole"))],
    [grapeUse("Eutypa dieback", 28)],
  );
  // No AI number to discard — but the name claim still goes.
  assertEquals(discardUnverifiedAiIdentity(structured, discovery.outcome), null);
  assertEquals(quarantineUnverifiedAiFacts(structured, discovery.outcome, "Australia"), true);

  assertFailClosedCanonical(structured, ["Tebuconazole", "Omnia", "Eutypa"]);
  assertEquals(structured.ai_suggestion.active_ingredients[0].name, "Tebuconazole");
});

// ===========================================================================
// R15 — resolved + AI disagreement: authority wins, conflict recorded
// ===========================================================================

Deno.test("R15: authoritative identity resolved + AI disagreement — authoritative data wins, the disagreement is a recorded conflict, and the gate never strips a resolved result", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Sprayseal", null, deps(sprayFixture()));
  assertEquals(discovery.outcome, "resolved");
  const reg = discovery.registration;
  assert(reg);

  // Plausible-but-wrong AI identity AND chemistry for the same product.
  const ai = plausibleAi(
    "Sprayseal",
    "Wrong Registrant Pty Ltd",
    "89999",
    [aiActive("Tebuconazole", 200, frac("3", "DMI / Triazole"))],
    [grapeUse("Eutypa dieback", 21)],
  );
  const merged = mergeDiscoveryIntoStructured(ai, reg);

  assertEquals(merged.match_source, "authoritative_candidate");
  assertEquals(merged.registration.registration_number, "80160");
  assertEquals(merged.registration.registrant, "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD");
  assertEquals(merged.active_ingredients.length, 1);
  assertEquals(merged.active_ingredients[0].concentration, 430, "register concentration served");
  assertEquals(merged.verification.status, "conflict");
  assert(
    merged.verification.conflicts.some(
      (c: Row) => c.field === "registration_number" && c.extracted_value === "89999",
    ),
    "fabricated number recorded as a conflict",
  );
  assert(
    merged.verification.conflicts.some(
      (c: Row) => c.field === "concentration" && c.active_ingredient_name === "Tebuconazole",
    ),
    "wrong concentration recorded as a conflict",
  );

  // The gate is a structural no-op on ANY resolved result.
  assertEquals(quarantineUnverifiedAiFacts(merged, "resolved"), false);
  assertEquals(merged.registration.registration_number, "80160");
  assertEquals(merged.active_ingredients.length, 1);
  assertEquals(merged.ai_suggestion, undefined);
  assertEquals(merged.guidance, undefined);
});

// ===========================================================================
// R16 — register unavailable / never consulted: degraded mode stays explicit
// ===========================================================================

Deno.test("R16: register unavailable or never consulted — the gate is a no-op and the existing clearly-attributed degraded mode remains", () => {
  for (const outcome of ["source_unavailable", "not_supported", "no_country"] as const) {
    const structured = custodia320Ai();
    assertEquals(discardUnverifiedAiIdentity(structured, outcome), null, outcome);
    assertEquals(quarantineUnverifiedAiFacts(structured, outcome, "Australia"), false, outcome);

    // "Could not check" is not "checked and unverified": the AI extraction
    // stays served exactly as before, attributed — never silently dropped.
    assertEquals(structured.product_name, "Custodia 320SC");
    assertEquals(structured.registration.registration_number, "80000");
    assertEquals(structured.registration.registrant, "BASF Australia Ltd");
    assertEquals(structured.active_ingredients.length, 1);
    assertEquals(structured.registered_uses.length, 1);
    assertEquals(structured.field_provenance, undefined, "serving path computes provenance");
    assertEquals(structured.ai_suggestion, undefined);
    assertEquals(structured.guidance, undefined);
    assertEquals(structured.match_source, undefined, "serving path computes ai_candidate");
  }
});

// ===========================================================================
// R17 — Custodia 320SC production regression (fail closed)
// ===========================================================================

Deno.test("R17: Custodia 320SC — not on the register, Forte never borrowed (search OR hint), response fails closed with the AI reading quarantined", async () => {
  // Name path: the register holds only CUSTODIA FORTE — 320SC does not exist.
  clearApvmaCache();
  const byName = await discoverAuthoritative(
    "AU",
    "Custodia 320SC",
    null,
    deps(registerFixture([CUSTODIA_FORTE])),
  );
  assertEquals(byName.outcome, "unresolved");
  assertEquals(byName.registration, undefined);

  // An AI number pointing AT Forte still cannot bind: name↔number
  // verification fails on the variant token, and the name path stays
  // unresolved. The variant guard holds under a hint, not just a search.
  clearApvmaCache();
  const byHint = await discoverAuthoritative(
    "AU",
    "Custodia 320SC",
    "91636",
    deps(registerFixture([CUSTODIA_FORTE])),
  );
  assertEquals(byHint.outcome, "unresolved");
  assertEquals(byHint.registration, undefined);

  // Production-shaped AI payload: registrant, Fluopyram 320 g/L, grape use,
  // 1.5 L/ha, WHP 14 — none of it may survive as canonical facts.
  const structured = custodia320Ai();
  assertEquals(discardUnverifiedAiIdentity(structured, byHint.outcome), "80000");
  assertEquals(quarantineUnverifiedAiFacts(structured, byHint.outcome, "Australia"), true);

  assertFailClosedCanonical(structured, [
    "Fluopyram",
    "BASF",
    "Powdery mildew",
    "CUSTODIA FORTE",
  ]);
  assertEquals(structured.ai_suggestion.active_ingredients[0].concentration, 320);
  assertEquals(structured.ai_suggestion.registered_uses[0].rates[0].value, 1.5);
});

// ===========================================================================
// R18 — Ridomil Gold production regression (ambiguous family, fail closed)
// ===========================================================================

Deno.test("R18: Ridomil Gold — deliberately ambiguous register family fails closed; no AI chemistry served, no candidate minted", async () => {
  const family: Row[] = [
    {
      pcode: "55180",
      fpname: "RIDOMIL GOLD MZ WG FUNGICIDE",
      sname: "SYNGENTA AUSTRALIA PTY LTD",
      hlevel1: "FUNGICIDE",
      fdesc: "WATER DISPERSIBLE GRANULE",
      regcode: "R",
      expdate: null,
    },
    {
      pcode: "81102",
      fpname: "RIDOMIL GOLD 480 SL FUNGICIDE",
      sname: "SYNGENTA AUSTRALIA PTY LTD",
      hlevel1: "FUNGICIDE",
      fdesc: "SOLUBLE CONCENTRATE",
      regcode: "R",
      expdate: null,
    },
    {
      pcode: "62740",
      fpname: "RIDOMIL GOLD 25 G FUNGICIDE",
      sname: "SYNGENTA AUSTRALIA PTY LTD",
      hlevel1: "FUNGICIDE",
      fdesc: "GRANULE",
      regcode: "R",
      expdate: null,
    },
  ];

  // Two family members correspond at the same tier — ambiguous, fail closed.
  clearApvmaCache();
  const discovery = await discoverAuthoritative(
    "AU",
    "Ridomil Gold",
    null,
    deps(registerFixture(family)),
  );
  assertEquals(discovery.outcome, "ambiguous");
  assertEquals(discovery.registration, undefined);

  // The AI's hint (55180 = the MZ WG variant) cannot un-tie it: the hinted
  // row's name does not correspond to the requested product.
  clearApvmaCache();
  const byHint = await discoverAuthoritative(
    "AU",
    "Ridomil Gold",
    "55180",
    deps(registerFixture(family)),
  );
  assertEquals(byHint.outcome, "ambiguous");
  assertEquals(byHint.registration, undefined);

  const structured = ridomilGoldAi();
  assertEquals(discardUnverifiedAiIdentity(structured, byHint.outcome), "55180");
  assertEquals(quarantineUnverifiedAiFacts(structured, byHint.outcome, "Australia"), true);

  assertFailClosedCanonical(structured, ["Metalaxyl", "Mancozeb", "Syngenta", "Downy mildew"]);
  assertEquals(structured.ai_suggestion.active_ingredients.length, 2);
});
