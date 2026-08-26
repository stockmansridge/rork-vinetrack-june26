// Chemical identity repair — regression suite (task Phase 17 A–G, I).
//
// The defect, stated once:
//
//   An operator searched "Hortitrol winter oil". VineTrack answered with a
//   registered product — a DIFFERENT one on each platform — without ever
//   asking which one they meant, and without either answer being a register
//   match for what they typed.
//
// Every test below locks one link of the chain that made that possible.
// Nothing here asserts that a particular registration is the "right" answer:
// the repair's whole point is that an ambiguous query has no right answer
// until a human picks one.

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  candidateClass,
  discoveryDecision,
  looksLikeProductCode,
  rankCandidates,
} from "./ranking.ts";
import {
  readSelectedRegistration,
  registrationViolation,
  servedIdentity,
  unresolvedForSelection,
} from "./identity_lock.ts";
import {
  buildMasterStructuredResponse,
  masterHasCompleteVineyardData,
} from "./ingestion/master_lookup.ts";
import { buildCandidatePayload } from "./ingestion/ingest.ts";

// ---------------------------------------------------------------------------
// Fixtures — shaped exactly as the pipeline produces them
// ---------------------------------------------------------------------------

/** An APPROVED master catalogue row for the vineyard's country. */
const masterRow = (over: Record<string, unknown> = {}) => ({
  name: "SYNERTROL HORTI BOTANICAL OIL CONCENTRATE",
  source: "master",
  review_status: "approved",
  registration_country: "AU",
  registration_scheme: "apvma",
  registration_number: "50067",
  ...over,
});

/** An official-register discovery candidate, post-mapping. */
const registerRow = (name: string, number: string, over: Record<string, unknown> = {}) => ({
  name,
  source: "official_register",
  registration_country: "AU",
  registration_scheme: "apvma",
  registration_number: number,
  ...over,
});

const HORTITROL = "Hortitrol winter oil";

// ===========================================================================
// A. SEARCH AMBIGUITY
//
// A weak deterministic hit must not suppress discovery, and an ambiguous
// query must end in a human choice — not a hidden automatic decision.
// ===========================================================================

Deno.test("A1: ONE weak master hit does not stop candidate discovery", () => {
  // The production shape. A contaminated alias made 50067 an exact-alias hit
  // for a phrase that shares NO word with its registered name, so the old
  // `authoritative.length === 0` gate reported the search answered.
  const decision = discoveryDecision({
    authoritative: [masterRow()],
    query: HORTITROL,
    countryCode: "AU",
    broaden: false,
    researchEnabled: true,
  });

  assertEquals(decision.research, true, "discovery must continue");
  assertEquals(decision.reason, "identity_not_settled");
  // The row exists; the IDENTITY does not.
  assertEquals(decision.summary.search_state, "no_official_match");
  assertEquals(decision.summary.auto_select_allowed, false);
});

Deno.test("A2: 50067 is never silently bound just for being the only match", () => {
  const { results, summary } = rankCandidates([masterRow()], HORTITROL, "AU");

  assertEquals(results.length, 1, "nothing is ever removed");
  // The one thing a client may act on without asking.
  assertEquals(summary.auto_select_allowed, false);
  assertEquals(summary.exact_registration_number, null);
  assertEquals(summary.ambiguous, true);
});

Deno.test("A3: an ambiguous answer returns several plausible options, each with EXACT identity", () => {
  const { results, summary } = rankCandidates(
    [
      registerRow("VICOL WINTER OIL INSECTICIDE", "33182"),
      registerRow("WINTER OIL SPRAYING OIL", "44551"),
      masterRow(),
    ],
    HORTITROL,
    "AU",
  );

  assert(results.length >= 2 && results.length <= 5, "2-5 plausible candidates");
  assertEquals(summary.auto_select_allowed, false, "a human decides");

  // Every candidate can be selected UNAMBIGUOUSLY. A row that cannot say
  // which registration it is forces the next stage back into name matching,
  // which is the defect this repair exists to end.
  for (const row of results) {
    assertEquals(typeof row.registration_number, "string");
    assert((row.registration_number as string).length > 0);
    assertEquals(row.registration_country, "AU");
    assertEquals(row.registration_scheme, "apvma");
  }
});

Deno.test("A4: the ranking does not depend on 33182 winning", () => {
  // Deliberately ordered with 50067 first. The requirement is that the user
  // CHOOSES -- not that a particular product sorts top. If evidence changes
  // and another product ranks first, this test must still pass.
  const { summary } = rankCandidates(
    [masterRow(), registerRow("VICOL WINTER OIL INSECTICIDE", "33182")],
    HORTITROL,
    "AU",
  );
  assertEquals(summary.auto_select_allowed, false);
});

Deno.test("A5: an EXACT registered name still resolves without a round trip", () => {
  // The repair must not turn every search into a questionnaire. An exact,
  // unrivalled register match is the one case a client may continue from.
  const decision = discoveryDecision({
    authoritative: [registerRow("CHATEAU HERBICIDE", "80647")],
    query: "Chateau Herbicide",
    countryCode: "AU",
    broaden: false,
    researchEnabled: true,
  });

  assertEquals(decision.research, false);
  assertEquals(decision.reason, "exact_identity_resolved");
  assertEquals(decision.summary.search_state, "exact");
  assertEquals(decision.summary.exact_registration_number, "80647");
});

Deno.test("A6: a bare registration NUMBER is answered by the register alone", () => {
  assertEquals(looksLikeProductCode("33182"), true);
  assertEquals(looksLikeProductCode("APVMA 33182"), false, "words hide names");
  assertEquals(looksLikeProductCode("Hortitrol winter oil"), false);

  const decision = discoveryDecision({
    authoritative: [registerRow("VICOL WINTER OIL INSECTICIDE", "33182")],
    query: "33182",
    countryCode: "AU",
    broaden: false,
    researchEnabled: true,
  });
  assertEquals(decision.research, false);
  assertEquals(decision.reason, "registration_number_query");
});

Deno.test("A7: an explicit broaden request always continues discovery", () => {
  const decision = discoveryDecision({
    authoritative: [registerRow("CHATEAU HERBICIDE", "80647")],
    query: "Chateau Herbicide",
    countryCode: "AU",
    broaden: true,
    researchEnabled: true,
  });
  assertEquals(decision.research, true);
  assertEquals(decision.reason, "client_requested_broaden");
});

Deno.test("A8: an exact name beside a rival is STILL a human decision", () => {
  const { summary } = rankCandidates(
    [
      registerRow("WINTER OIL", "11111"),
      registerRow("WINTER OIL CONCENTRATE", "22222"),
    ],
    "Winter Oil",
    "AU",
  );
  assertEquals(summary.auto_select_allowed, false, "a rival is a reason to ask");
});

// ===========================================================================
// B. EXACT SELECTION IMMUTABILITY
//
// Once a human selects a registration, no later stage may answer with a
// different one.
// ===========================================================================

const SELECTED_33182 = { country: "AU", scheme: "apvma", number: "33182" };

Deno.test("B1: a structured response for the selected registration is served unchanged", () => {
  const payload = {
    registration: {
      country_code: "AU",
      scheme: "apvma",
      registration_number: "33182",
    },
  };
  assertEquals(registrationViolation(SELECTED_33182, payload), null);
  assertEquals(servedIdentity(payload).number, "33182");
});

Deno.test("B2: THE substitution — selecting 33182 and being served 50067 is refused", () => {
  const substituted = {
    registration: {
      country_code: "AU",
      scheme: "apvma",
      registration_number: "50067",
    },
  };
  const violation = registrationViolation(SELECTED_33182, substituted);
  assert(violation, "the substitution must be detected");
  assert(violation.includes("33182") && violation.includes("50067"));

  // And what the operator gets instead names the product they chose.
  const refusal = unresolvedForSelection(SELECTED_33182, violation);
  assertEquals(refusal.registration.registration_number, "33182");
  assert(refusal.registration.registration_number !== "50067");
  assertEquals(refusal.match_source, "unresolved");
  assertEquals(refusal.identity_guard.outcome, "selection_not_resolved");

  // Nothing about the substitute survives as PRODUCT DATA. The refusal names
  // both numbers in `identity_guard.reason` on purpose -- that is the
  // diagnostic record of what was refused, and it is the one place 50067 may
  // appear. Everything a client would read as facts about a chemical is
  // either the selected registration or empty.
  assertEquals(refusal.registration.country_code, "AU");
  assertEquals(refusal.product_name, null);
  assertEquals(refusal.active_ingredients.length, 0);
  assertEquals(refusal.registered_uses.length, 0);
  assertEquals(refusal.grapevine_uses.length, 0);
  assertEquals(refusal.label_urls.regulator_label_url, null);
  assertEquals(refusal.registration.registered_product_name, null);
  const { identity_guard: _diagnostic, ...servedFacts } = refusal;
  assert(
    !JSON.stringify(servedFacts).includes("50067"),
    "the substitute reaches no served field",
  );
});

Deno.test("B3: a cross-COUNTRY answer is a violation even at the same number", () => {
  const nzRow = {
    registration: { country_code: "NZ", scheme: "acvm", registration_number: "33182" },
  };
  assert(registrationViolation(SELECTED_33182, nzRow), "another country is another law");
});

Deno.test("B4: an unresolved answer is honest, not a violation", () => {
  // Failing to load the selected product is allowed. Substituting is not.
  const empty = { registration: { country_code: "AU", scheme: "apvma", registration_number: null } };
  assertEquals(registrationViolation(SELECTED_33182, empty), null);
});

Deno.test("B5: an UNSELECTED lookup is unlocked", () => {
  // A first-time name resolution has no human decision to hold, so the lock
  // must not fire and turn ordinary discovery into a refusal.
  assertEquals(readSelectedRegistration({ productName: "Sprayseal" }, "AU"), null);
  assertEquals(registrationViolation(null, { registration: { registration_number: "80160" } }), null);
});

Deno.test("B6: the selected identity is read from the request verbatim", () => {
  const selected = readSelectedRegistration(
    { registrationNumber: " 33182 ", registrationScheme: "APVMA" },
    "au",
  );
  assertEquals(selected?.number, "33182");
  assertEquals(selected?.scheme, "apvma");
  assertEquals(selected?.country, "AU");
});

// ===========================================================================
// C. MASTER ALIAS SAFETY
//
// The typed phrase must never become a permanent product alias.
// ===========================================================================

const structuredFor = (name: string, number: string) => ({
  product_name: name,
  registration: {
    country_code: "AU",
    scheme: "apvma",
    registration_number: number,
    registered_product_name: name,
  },
  active_ingredients: [],
  activity_groups: [],
  registered_uses: [],
  label_rate_bases: [],
  verification: { status: "unverified", sources: [], conflicts: [], unresolved_fields: [] },
});

Deno.test("C1: THE contamination — a typed phrase never enters common_names", () => {
  const payload = buildCandidatePayload(
    structuredFor("SYNERTROL HORTI BOTANICAL OIL CONCENTRATE", "50067"),
    HORTITROL,
    null,
    "2026-08-26T00:00:00Z",
    1,
  );
  assert(payload);
  assert(
    !payload.common_names.includes("hortitrol winter oil"),
    "the exact production defect",
  );
  assert(
    !payload.common_names.some((n) => n.includes("hortitrol")),
    "not in any form",
  );
  // The REGISTERED name is still there, because the register said it.
  assert(payload.common_names.includes("synertrol horti botanical oil concentrate"));
});

Deno.test("C2: an alias an authoritative source establishes IS kept", () => {
  // The narrow door: a validated reference (the AWRI seed path) may attach a
  // name to a register-confirmed registration. Nothing reaches this list by
  // default, and a search box cannot put anything in it.
  const payload = buildCandidatePayload(
    structuredFor("FIXTURE SHIELD 250 SC FUNGICIDE", "58340"),
    "Fixture Shield",
    null,
    "2026-08-26T00:00:00Z",
    1,
    ["Fixture Shield"],
  );
  assert(payload);
  assert(payload.common_names.includes("fixture shield"));
});

Deno.test("C3: the search phrase is not smuggled in by another key", () => {
  const payload = buildCandidatePayload(
    structuredFor("SYNERTROL HORTI BOTANICAL OIL CONCENTRATE", "50067"),
    HORTITROL,
    null,
    "2026-08-26T00:00:00Z",
    1,
  );
  assert(payload);
  assert(
    !JSON.stringify(payload).toLowerCase().includes("hortitrol"),
    "the phrase reaches no catalogue column at all",
  );
});

// ===========================================================================
// D. INCOMPLETE MASTER ENRICHMENT
//
// An approved row that admits it is missing grapevine rates must not end the
// lookup.
// ===========================================================================

/** The production shape of APVMA 33182: approved, correct, and incomplete. */
const incomplete33182 = () => ({
  id: "11111111-1111-1111-1111-111111111111",
  registration_country: "AU",
  registration_scheme: "apvma",
  registration_number: "33182",
  registered_product_name: "VICOL WINTER OIL INSECTICIDE",
  review_status: "approved",
  registered_uses: [
    { crop: "GRAPEVINE", target_raw: "GRAPEVINE SCALE", rates: [] },
  ],
  label_rate_bases: [],
  label_reference: null,
  verification_status: "partially_verified",
  verification_unresolved_fields: ["rates:GRAPEVINE"],
});

Deno.test("D1: APVMA 33182's production row is NOT complete enough to answer with", () => {
  assertEquals(masterHasCompleteVineyardData(incomplete33182()), false);
});

Deno.test("D2: each missing piece independently blocks the fast path", () => {
  // No label -> nothing established the rates.
  assertEquals(
    masterHasCompleteVineyardData({
      ...incomplete33182(),
      verification_unresolved_fields: [],
      label_reference: null,
    }),
    false,
  );
  // No registration -> no identity to enrich.
  assertEquals(
    masterHasCompleteVineyardData({
      ...incomplete33182(),
      verification_unresolved_fields: [],
      registration_number: null,
      label_reference: "https://elabels.apvma.gov.au/33182ELBL.pdf",
    }),
    false,
  );
  // A qualified grapevine rate gap is still a gap.
  assertEquals(
    masterHasCompleteVineyardData({
      ...incomplete33182(),
      label_reference: "https://elabels.apvma.gov.au/33182ELBL.pdf",
      verification_unresolved_fields: ["RATES:GRAPEVINE:POWDERY MILDEW"],
    }),
    false,
  );
});

Deno.test("D3: a COMPLETE row still short-circuits — the cache still works", () => {
  assertEquals(
    masterHasCompleteVineyardData({
      ...incomplete33182(),
      label_reference: "https://elabels.apvma.gov.au/33182ELBL.pdf",
      verification_unresolved_fields: [],
      registered_uses: [{
        crop: "GRAPEVINE",
        target_raw: "GRAPEVINE SCALE",
        rates: [{ value: 2, unit: "L", basis: "per_100_litres" }],
      }],
    }),
    true,
  );
});

Deno.test("D4: an unresolved rate for ANOTHER crop does not block the fast path", () => {
  // Vineyard completeness is about grapevines. A missing citrus rate is not a
  // reason to re-run enrichment for a vineyard.
  assertEquals(
    masterHasCompleteVineyardData({
      ...incomplete33182(),
      label_reference: "https://elabels.apvma.gov.au/33182ELBL.pdf",
      verification_unresolved_fields: ["rates:CITRUS"],
    }),
    true,
  );
});

// ===========================================================================
// E. RATE STRUCTURE
//
// Multiple registered rates stay multiple structured rates, in the label's
// own basis.
// ===========================================================================

const multiRateRow = () => ({
  registration_country: "AU",
  registration_scheme: "apvma",
  registration_number: "33182",
  registered_product_name: "VICOL WINTER OIL INSECTICIDE",
  review_status: "approved",
  label_reference: "https://elabels.apvma.gov.au/33182ELBL.pdf",
  registered_uses: [
    {
      crop: "GRAPEVINE",
      target_raw: "GRAPEVINE SCALE",
      rates: [
        { value: 2, unit: "L", basis: "per_100_litres", raw_text: "2 L/100 L" },
        { value: 3, unit: "L", basis: "per_100_litres", raw_text: "3 L/100 L" },
      ],
      withholding_period_days: null,
      re_entry_period_hours: null,
    },
  ],
  verification_unresolved_fields: [],
});

Deno.test("E1: two registered rates stay TWO structured rates", () => {
  const served = buildMasterStructuredResponse(multiRateRow());
  const use = served.grapevine_uses[0];
  assertEquals(use.rates.length, 2);
  assertEquals(use.rates[0].value, 2);
  assertEquals(use.rates[1].value, 3);
});

Deno.test("E2: rates are never concatenated into one string", () => {
  const served = buildMasterStructuredResponse(multiRateRow());
  const use = served.grapevine_uses[0];
  assertEquals(typeof use.rates, "object");
  assert(Array.isArray(use.rates));
  for (const rate of use.rates) {
    assertEquals(typeof rate.value, "number", "a rate is a NUMBER, not prose");
  }
  assert(
    !JSON.stringify(served).includes("2 L/100 L 3 L/100 L"),
    "the flattened form must not appear anywhere",
  );
});

Deno.test("E3: /100 L stays /100 L — no hectare conversion in lookup", () => {
  const served = buildMasterStructuredResponse(multiRateRow());
  for (const rate of served.grapevine_uses[0].rates) {
    assertEquals(rate.basis, "per_100_litres");
    assertEquals(rate.unit, "L");
  }
  assert(
    !JSON.stringify(served).includes("per_hectare"),
    "chemical lookup never derives a hectare rate",
  );
});

Deno.test("E4: the label's raw wording survives beside the parsed numbers", () => {
  const served = buildMasterStructuredResponse(multiRateRow());
  const raws = served.grapevine_uses[0].rates.map((r: any) => r.raw_text);
  assertEquals(raws, ["2 L/100 L", "3 L/100 L"]);
});

// ===========================================================================
// F. WHP / REI NULL SAFETY
//
// Missing is not zero. (The iOS rendering half lives in
// ChemicalWhpReiDisplayTests.swift.)
// ===========================================================================

Deno.test("F1: a missing WHP and REI stay NULL through the serving envelope", () => {
  const served = buildMasterStructuredResponse(multiRateRow());
  const use = served.grapevine_uses[0];
  assertEquals(use.withholding_period_days, null);
  assertEquals(use.re_entry_period_hours, null);
  assert(use.withholding_period_days !== 0, "null must never become zero");
  assert(use.re_entry_period_hours !== 0, "null must never become zero");
});

Deno.test("F2: an explicit ZERO is preserved as a fact", () => {
  const row = multiRateRow();
  row.registered_uses[0].withholding_period_days = 0 as any;
  const served = buildMasterStructuredResponse(row);
  assertEquals(served.grapevine_uses[0].withholding_period_days, 0);
});

// ===========================================================================
// G. RESISTANCE STATE
//
// classified / not_applicable / unresolved stay three different answers.
// ===========================================================================

const rowWithActives = (actives: unknown[]) => ({
  ...multiRateRow(),
  active_ingredients: actives,
  activity_groups: [],
});

Deno.test("G1: the three resistance states are semantically distinct", () => {
  const served = buildMasterStructuredResponse(rowWithActives([
    { name: "Tebuconazole", activity_group: { code: "3", scheme: "frac" } },
    { name: "Paraffinic oil", activity_group: { code: null, scheme: "not_applicable" } },
    { name: "Unknown active" },
  ]));

  const [classified, notApplicable, unresolved] = served.active_ingredients;

  assertEquals(classified.activity_group.code, "3");
  assertEquals(classified.activity_group.scheme, "frac");

  // An adjuvant HAS no group by design. That is an answer, not a gap.
  assertEquals(notApplicable.activity_group.scheme, "not_applicable");
  assertEquals(notApplicable.activity_group.code, null);

  // Nobody has established this one. Distinct from both above.
  assertEquals(unresolved.activity_group, undefined);
});

Deno.test("G2: unresolved is never silently promoted to not_applicable", () => {
  const served = buildMasterStructuredResponse(rowWithActives([{ name: "Unknown active" }]));
  const active = served.active_ingredients[0];
  assert(
    active.activity_group?.scheme !== "not_applicable",
    "an unestablished group must never be reported as having none",
  );
});

// ===========================================================================
// I. CLIENT PARITY
//
// One request, one ordered answer, for every client.
// ===========================================================================

Deno.test("I1: identical requests produce an identical ordered registration sequence", () => {
  const rows = [
    registerRow("WINTER OIL SPRAYING OIL", "44551"),
    masterRow(),
    registerRow("VICOL WINTER OIL INSECTICIDE", "33182"),
  ];

  // Two clients. Same server, same request, separate calls.
  const portal = rankCandidates([...rows], HORTITROL, "AU");
  const ios = rankCandidates([...rows], HORTITROL, "AU");

  const order = (r: typeof portal) => r.results.map((x: any) => x.registration_number);
  assertEquals(order(portal), order(ios));
  assertEquals(portal.summary.search_state, ios.summary.search_state);
  assertEquals(portal.summary.auto_select_allowed, ios.summary.auto_select_allowed);
});

Deno.test("I2: ordering does not depend on the order rows arrived in", () => {
  // Two isolates can assemble the deterministic tiers in different orders.
  // Tier and relevance must decide, so both land on the same sequence.
  const a = rankCandidates(
    [registerRow("VICOL WINTER OIL INSECTICIDE", "33182"), masterRow()],
    HORTITROL,
    "AU",
  );
  const b = rankCandidates(
    [masterRow(), registerRow("VICOL WINTER OIL INSECTICIDE", "33182")],
    HORTITROL,
    "AU",
  );
  assertEquals(a.summary.search_state, b.summary.search_state);
  assertEquals(a.summary.auto_select_allowed, b.summary.auto_select_allowed);
  // Both rows are `unrelated` to this query, so the APPROVED master leads on
  // tier in both. The point is that the answer is a FUNCTION of the inputs.
  assertEquals(
    a.results.map((r: any) => r.registration_number),
    b.results.map((r: any) => r.registration_number),
  );
});

Deno.test("I3: every served row carries the class a client must not recompute", () => {
  const { results } = rankCandidates(
    [masterRow(), registerRow("VICOL WINTER OIL INSECTICIDE", "33182")],
    HORTITROL,
    "AU",
  );
  for (const row of results) {
    assertEquals(row.candidate_class, candidateClass(row, "AU"));
    assert(typeof row.rank_reason === "string" && row.rank_reason.length > 0);
  }
});

// ===========================================================================
// Phase 12 — the official label URL must reach the client
// ===========================================================================

Deno.test("L1: a production row carrying only label_reference still serves a label URL", () => {
  const served = buildMasterStructuredResponse({
    ...multiRateRow(),
    label_reference: "https://elabels.apvma.gov.au/33182ELBL.pdf",
  });
  assertEquals(
    served.label_urls.regulator_label_url,
    "https://elabels.apvma.gov.au/33182ELBL.pdf",
  );
  assertEquals(
    served.registration.label_reference,
    "https://elabels.apvma.gov.au/33182ELBL.pdf",
  );
});

Deno.test("L2: the newer column wins, and the manufacturer document stays separate", () => {
  const served = buildMasterStructuredResponse({
    ...multiRateRow(),
    label_reference: "https://elabels.apvma.gov.au/OLD.pdf",
    regulator_label_url: "https://elabels.apvma.gov.au/33182ELBL.pdf",
    manufacturer_label_url: "https://vicchem.com/vicol-label.pdf",
    product_url: "https://vicchem.com/products/vicol",
  });
  assertEquals(
    served.label_urls.regulator_label_url,
    "https://elabels.apvma.gov.au/33182ELBL.pdf",
  );
  assertEquals(served.label_urls.manufacturer_label_url, "https://vicchem.com/vicol-label.pdf");
  assertEquals(served.label_urls.product_url, "https://vicchem.com/products/vicol");
  // The authoritative document still leads for legacy readers.
  assertEquals(
    served.registration.label_reference,
    "https://elabels.apvma.gov.au/33182ELBL.pdf",
  );
});

Deno.test("L3: no label is null — never a guessed APVMA URL", () => {
  const served = buildMasterStructuredResponse({ ...multiRateRow(), label_reference: null });
  assertEquals(served.label_urls.regulator_label_url, null);
  assert(
    !JSON.stringify(served.label_urls).includes("33182ELBL"),
    "a URL is never synthesised from a registration number",
  );
});
