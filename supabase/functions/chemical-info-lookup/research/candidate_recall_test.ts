// Stage A — candidate-discovery RECALL regression (§6, §7).
//
// # The production defect, stated once
//
// Live cache key `AU::hortitrol winter oil` contained exactly one candidate:
// SYNERTROL HORTI BOTANICAL OIL CONCENTRATE, APVMA 50067. VICOL WINTER OIL
// INSECTICIDE / APVMA 33182 never reached the candidate list, on any client.
//
// This was never a Portal filtering problem. Discovery itself stopped: Terra
// returned one plausible product, the APVMA adapter confirmed that
// registration genuinely exists, and candidate discovery was categorically
// barred from escalating. So the system concluded
//
//   "50067 is a real registered product"     (true, and proven)
//   "50067 is the only product they meant"   (never established)
//
// The server's ranking is perfectly capable of presenting a choice — it was
// simply never handed a second candidate to rank. No downstream ranking,
// filtering or UI work can recover a candidate that was never discovered.
//
// # What these tests deliberately do NOT do
//
// They never teach the algorithm that "Hortitrol Winter Oil" is APVMA 33182.
// The stubs make Sol RETURN a second product; what is asserted is that the
// pipeline escalates, merges, validates and dedupes it — the mechanism, not
// the answer. A test that hard-coded the answer would pass against a system
// that had learned one product and still failed every other approximate name.

import { assert, assertEquals } from "jsr:@std/assert@1";

import { readResearchConfig, researchLog, runChemicalResearch } from "./research.ts";
import {
  decideCandidateDiscoveryEscalation,
  MIN_DISCOVERY_CANDIDATES,
} from "./escalation.ts";
import { candidateIdentity, mergeCandidateResearch } from "./candidate_merge.ts";
import { projectResearchToSearchResults } from "./authority.ts";
import { rankCandidates } from "../ranking.ts";
import {
  CANDIDATE_DISCOVERY_CACHE_VERSION,
  suggestionCacheKey,
  validateResearchSuggestions,
} from "../research_suggestions.ts";
import type { RegisterCandidate } from "../ingestion/contract.ts";
import type { ChemicalResearchResult } from "./schema.ts";
import {
  cloneResearch,
  fakeFetch,
  jsonResponse,
  responsesEnvelope,
} from "./test_fixtures.ts";

// ---------------------------------------------------------------------------
// Fixtures — the production shapes, reconstructed
// ---------------------------------------------------------------------------

const QUERY = "Hortitrol Winter Oil";

const SYNERTROL = {
  name: "SYNERTROL HORTI BOTANICAL OIL CONCENTRATE",
  number: "50067",
  registrant: "DuluxGroup (Australia) Pty Ltd",
};
const VICOL = {
  name: "VICOL WINTER OIL INSECTICIDE",
  number: "33182",
  registrant: "Victorian Chemical Company Pty Ltd",
};

/** A discovery payload naming an arbitrary set of registered products. */
function discoveryPayload(
  canonical: string,
  products: { name: string; number: string }[],
): ChemicalResearchResult {
  const research = cloneResearch();
  research.product.searched_name = QUERY;
  research.product.canonical_name = canonical;
  research.registered_uses = [];
  research.registration_candidates = products.map((p) => ({
    scheme: "apvma",
    number: p.number,
    registered_product_name: p.name,
    country: "AU",
    source_url: `https://portal.apvma.gov.au/pubcris?p_id=${p.number}`,
    source_domain: "portal.apvma.gov.au",
    confidence: "medium" as const,
    reason: "PubCRIS entry plausibly matches the approximate search name",
  }));
  return research;
}

/** Terra's live behaviour: one plausible product, and it stopped there. */
const terraOnly = () => discoveryPayload(SYNERTROL.name, [SYNERTROL]);

/** Sol asked "what else?" — finds another, and repeats Terra's (dedupe bait). */
const solWithAlternative = () =>
  discoveryPayload(SYNERTROL.name, [SYNERTROL, VICOL]);

/** Terra already produced a genuine choice. */
const terraWithTwo = () => discoveryPayload(SYNERTROL.name, [SYNERTROL, VICOL]);

const config = readResearchConfig(() => undefined);

const discovery = {
  query: QUERY,
  countryCode: "AU",
  countryLabel: "Australia",
  mode: "candidate_discovery" as const,
  apiKey: "sk-test",
  config,
  registerResolved: false,
  useCache: false,
};

/** The APVMA adapter, stubbed: both numbers are genuinely registered. */
function fakeRegister(): {
  lookup: (n: string) => Promise<RegisterCandidate | null>;
  looked: string[];
} {
  const looked: string[] = [];
  const rows: Record<string, RegisterCandidate> = {
    [SYNERTROL.number]: {
      registration_number: SYNERTROL.number,
      registered_product_name: SYNERTROL.name,
      registrant: SYNERTROL.registrant,
      product_category: "Adjuvant",
      register_status: "Registered",
      actives_summary: "Emulsifiable Botanical Oil 850 g/L",
      activity_groups: [],
      match_rank: 0,
    },
    [VICOL.number]: {
      registration_number: VICOL.number,
      registered_product_name: VICOL.name,
      registrant: VICOL.registrant,
      product_category: "Insecticide",
      register_status: "Registered",
      actives_summary: "Petroleum Oil 861 g/L",
      activity_groups: [],
      match_rank: 0,
    },
  };
  return {
    looked,
    lookup: (n: string) => {
      looked.push(n);
      return Promise.resolve(rows[n] ?? null);
    },
  };
}

// ===========================================================================
// §6 — THE regression: one Terra candidate must not end discovery
// ===========================================================================

Deno.test("A1: an approximate name buys ONE capable pass, not two serial ones", async () => {
  // Stage C. The recall guarantee is unchanged -- an approximate name still
  // gets the capable model -- but it is bought UP FRONT instead of being
  // discovered by spending a whole Terra pass first. Two serial frontier
  // requests before the first row could be drawn is what turned a product
  // search into a multi-minute operation that ended in a gateway timeout.
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(solWithAlternative())),
  ]);

  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });

  assertEquals(calls.length, 1, "exactly one model request for a fuzzy search");
  assertEquals(calls[0].body.model, "gpt-5.6-sol", "and it is the capable model");
  assertEquals(outcome.telemetry.discovery_pass, "single_capable_pass");

  // Nothing left to escalate TO: the strongest model already answered.
  assertEquals(outcome.telemetry.escalated, false);
  assertEquals(outcome.escalation?.terminal, true);
});

Deno.test("A2: the discovered set carries BOTH products, each exactly once", async () => {
  const { fn } = fakeFetch([
    jsonResponse(responsesEnvelope(solWithAlternative())),
  ]);

  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });
  const numbers = outcome.research?.registration_candidates
    .map((c) => c.number) ?? [];

  // Both present, neither doubled.
  assertEquals(numbers.sort(), [VICOL.number, SYNERTROL.number].sort());
  assertEquals(
    numbers.filter((n) => n === SYNERTROL.number).length,
    1,
    "a repeated product must not double",
  );
  assertEquals(outcome.telemetry.merged_candidate_numbers.length, 2);
});

Deno.test("A3: the capable pass reaches a product no obvious name match would", async () => {
  // The recall property that actually matters, stated without reference to
  // which model ran: a query whose words appear in NEITHER registered name
  // still reaches the registered product the operator meant. Nothing teaches
  // the algorithm that answer -- the stub returns it, and what is asserted is
  // that the pipeline carries it through intact.
  const { fn } = fakeFetch([
    jsonResponse(responsesEnvelope(discoveryPayload(VICOL.name, [VICOL]))),
  ]);

  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });
  const numbers = outcome.research?.registration_candidates.map((c) => c.number) ?? [];

  assert(numbers.includes(VICOL.number));
  assertEquals(outcome.telemetry.merged_candidate_numbers, [VICOL.number]);
});

Deno.test("A4: validation still runs, and the answer stays a USER choice", async () => {
  const { fn } = fakeFetch([
    jsonResponse(responsesEnvelope(solWithAlternative())),
  ]);

  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });
  assert(outcome.research);

  // The real search path: project -> validate against the register -> rank.
  const projected = projectResearchToSearchResults(outcome.research, "AU", "apvma");
  const register = fakeRegister();
  const validated = await validateResearchSuggestions(projected, {
    countryCode: "AU",
    lookup: register.lookup,
  });

  // 4. Every research-suggested number was re-read from the register.
  assert(register.looked.includes(SYNERTROL.number));
  assert(register.looked.includes(VICOL.number));

  const numbers = validated.rows
    .map((r) => String(r.registration_number ?? ""))
    .filter((n) => n.length > 0);
  assertEquals(numbers.sort(), [VICOL.number, SYNERTROL.number].sort());

  // Confirmed suggestions are still SUGGESTIONS, not register findings.
  for (const row of validated.rows) {
    assertEquals(row.source, "research_validated");
    assertEquals(row.registration_validated, true);
  }

  const ranked = rankCandidates(validated.rows, QUERY, "AU");

  // 6. and 7. Two plausible products, so the operator decides. Nothing is
  // auto-selected merely because research surfaced it.
  assertEquals(ranked.summary.auto_select_allowed, false);
  assertEquals(ranked.summary.exact_registration_number, null);
  assertEquals(ranked.summary.search_state, "no_official_match");
  assertEquals(ranked.summary.validated_suggestion_count, 2);
  assertEquals(ranked.results.length, 2, "the operator sees both options");
});

Deno.test("A5: the discovery prompt never names the wanted product", async () => {
  // What keeps every recall assertion honest: the pipeline is never handed the
  // answer it is meant to find. It searches on the operator's words alone.
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(solWithAlternative())),
  ]);

  await runChemicalResearch({ ...discovery, fetchFn: fn });
  const input = String(calls[0].body.input);

  assert(input.includes(QUERY), "the operator's own words are the search");
  assert(!input.includes(VICOL.name), "the expected product is never named");
  assert(!input.includes(VICOL.number), "nor its registration number");
  assert(!input.includes(SYNERTROL.number), "nor any other answer");
});

// ===========================================================================
// §6 control — escalation stays bounded
// ===========================================================================

Deno.test("B1: CONTROL — a sufficient Terra candidate set does not buy Sol", async () => {
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(terraWithTwo())),
    jsonResponse(responsesEnvelope(solWithAlternative())),
  ]);

  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });

  assertEquals(calls.length, 1, "the operator already has a choice");
  assertEquals(outcome.telemetry.escalated, false);
  assertEquals(outcome.telemetry.merged_candidate_numbers.length, 2);
});

Deno.test("B2: CONTROL — a bare registration number never escalates", async () => {
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(terraOnly())),
    jsonResponse(responsesEnvelope(solWithAlternative())),
  ]);

  const outcome = await runChemicalResearch({
    ...discovery,
    query: "33182",
    fetchFn: fn,
  });

  assertEquals(calls.length, 1, "the register holds it or it does not exist");
  assertEquals(outcome.telemetry.escalated, false);
});

Deno.test("B3: the escalation rule is exactly 'fewer than two, approximate name'", () => {
  const one = decideCandidateDiscoveryEscalation({
    research: terraOnly(),
    registerResolved: false,
    isProductCodeQuery: false,
  });
  assertEquals(one.escalate, true);
  assertEquals(one.reasons, ["insufficient_candidate_recall"]);

  assertEquals(
    decideCandidateDiscoveryEscalation({
      research: terraWithTwo(),
      registerResolved: false,
      isProductCodeQuery: false,
    }).escalate,
    false,
  );
  assertEquals(
    decideCandidateDiscoveryEscalation({
      research: terraOnly(),
      registerResolved: true,
      isProductCodeQuery: false,
    }).escalate,
    false,
    "the register already answered",
  );
  assertEquals(
    decideCandidateDiscoveryEscalation({
      research: terraOnly(),
      registerResolved: false,
      isProductCodeQuery: true,
    }).escalate,
    false,
  );
  assertEquals(
    decideCandidateDiscoveryEscalation({
      research: null,
      registerResolved: false,
      isProductCodeQuery: false,
    }).reasons,
    ["research_returned_nothing"],
  );
  assertEquals(MIN_DISCOVERY_CANDIDATES, 2);
});

Deno.test("B4: a failed discovery pass degrades, and never throws", async () => {
  // Discovery is ONE STAGE of search, not search itself. A provider outage
  // must return "no research" so the register candidates already in hand are
  // still served -- an exception escaping here reached the outer handler as a
  // 502 and destroyed the part of the answer that was already correct.
  const { fn } = fakeFetch([
    jsonResponse({ error: { message: "upstream exploded" } }, 500),
    jsonResponse({ error: { message: "upstream exploded" } }, 500),
  ]);

  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });

  assertEquals(outcome.research, null);
  assert(outcome.error, "the failure is reported, not swallowed silently");
});

// ===========================================================================
// Merge unit rules
// ===========================================================================

Deno.test("C1: dedupe is by exact registration identity, never by name", () => {
  const primary = discoveryPayload(SYNERTROL.name, [SYNERTROL]);
  // Same verbatim registered name, DIFFERENT registration. Two registrations
  // can legitimately share a name (pack sizes, re-registrations); collapsing
  // them would delete a genuinely different registered product.
  const fallback = discoveryPayload(SYNERTROL.name, [
    { name: SYNERTROL.name, number: "99999" },
  ]);

  const merged = mergeCandidateResearch(primary, fallback, "AU");
  assertEquals(merged.mergedNumbers, [SYNERTROL.number, "99999"]);
  assertEquals(merged.addedCount, 1);
});

Deno.test("C2: identity is country + scheme + number", () => {
  const base = {
    scheme: "apvma",
    number: "33182",
    registered_product_name: VICOL.name,
    country: "AU",
    source_url: null,
    source_domain: null,
    confidence: "medium" as const,
    reason: "",
  };
  assertEquals(candidateIdentity(base), "AU:apvma:33182");
  assertEquals(candidateIdentity({ ...base, country: "" }, "AU"), "AU:apvma:33182");
  // No number is no identity — such a row dedupes by name instead.
  assertEquals(candidateIdentity({ ...base, number: null }), null);
});

Deno.test("C3: the merged list is bounded", () => {
  const many = discoveryPayload(
    "A",
    Array.from({ length: 9 }, (_, i) => ({ name: `PRODUCT ${i}`, number: `${1000 + i}` })),
  );
  const merged = mergeCandidateResearch(terraOnly(), many, "AU");
  assertEquals(merged.research.registration_candidates.length, 5);
});

// ===========================================================================
// §7 — the cache must not serve a previous algorithm's answer
// ===========================================================================

Deno.test("D1: the live v1 production key is NOT readable by the new algorithm", () => {
  // The exact key currently holding the Terra-only answer in production.
  const productionV1Key = "AU::hortitrol winter oil";
  const nowKey = suggestionCacheKey("AU", QUERY);

  assert(
    nowKey !== productionV1Key,
    "a deploy must not be masked by the cached result that demonstrates the bug",
  );
  assert(nowKey.includes(CANDIDATE_DISCOVERY_CACHE_VERSION));
  assertEquals(
    nowKey,
    `AU::${CANDIDATE_DISCOVERY_CACHE_VERSION}::hortitrol winter oil`,
  );
  // EVERY superseded generation stays unreadable, not just the first.
  for (const old of ["candidate-discovery-v1", "candidate-discovery-v2"]) {
    assert(!nowKey.includes(old), `${old} must not be addressable`);
  }
});

Deno.test("D2: the versioned key still normalises and still scopes by country", () => {
  // Case and spacing must still collapse, or two clients race two passes.
  assertEquals(
    suggestionCacheKey("AU", "Hortitrol  Winter  Oil"),
    suggestionCacheKey("au", "hortitrol winter oil"),
  );
  // Country is never merged away: AU and NZ are different law.
  assert(suggestionCacheKey("AU", QUERY) !== suggestionCacheKey("NZ", QUERY));
});

// ===========================================================================
// §5 — diagnostics must be able to prove what happened
// ===========================================================================

Deno.test("E1: the telemetry line proves which discovery strategy ran", async () => {
  const { fn } = fakeFetch([
    jsonResponse(responsesEnvelope(solWithAlternative())),
  ]);

  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });
  const line = researchLog(outcome.telemetry);

  assert(line.includes("mode=candidate_discovery"));
  assert(line.includes("discovery_pass=single_capable_pass"));
  assert(line.includes("primary=gpt-5.6-sol"), "the capable model ran first");
  assert(line.includes("primary_candidates=2"));
  assert(line.includes("escalated=false"), "no serial second frontier call");
  assert(line.includes("sol=no"), "there is no separate fallback attempt");
  assert(line.includes(`merged_candidates=[${SYNERTROL.number},${VICOL.number}]`));

  assertEquals(outcome.telemetry.attempts.length, 1, "ONE model request");
  const [primary] = outcome.telemetry.attempts;
  assertEquals(primary.candidate_count, 2);
  assertEquals(primary.role, "primary");
});

Deno.test("E2: a NON-escalated discovery still reports what the operator got", async () => {
  const { fn } = fakeFetch([jsonResponse(responsesEnvelope(terraWithTwo()))]);
  const outcome = await runChemicalResearch({ ...discovery, fetchFn: fn });
  const line = researchLog(outcome.telemetry);

  assert(line.includes("escalated=false"));
  assert(line.includes(`merged_candidates=[${SYNERTROL.number},${VICOL.number}]`));
  assert(line.includes("added_by_sol=0"));
});
