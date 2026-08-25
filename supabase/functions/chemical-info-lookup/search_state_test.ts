// Search state contract (Chemical Search Stage 2 §1, §3).
//
// The defect these tests lock down: a summary that said
//
//   { ambiguous: false, strong_candidate_count: 0, exact_registration_number: null }
//
// for "Hortitrol Winter Oil" / AU. `ambiguous: false` reads as confidence, and
// a client is entitled to continue on it. Here it meant "no answer at all" —
// the least certain outcome search has, reported in the words of the most
// certain one.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { candidateClass, rankCandidates } from "./ranking.ts";

const registerRow = (name: string, registration: string) => ({
  name,
  brand: "Registrant",
  registration_number: registration,
  source: "official_register",
});

/** A raw research row, exactly as `projectResearchToSearchResults` emits it. */
const researchRow = (name: string, registration?: string) => ({
  name,
  brand: "",
  source: "research",
  ...(registration ? { registration_number: registration } : {}),
});

/** A research row the register CONFIRMED (post-validation shape). */
const validatedRow = (name: string, registration: string) => ({
  name,
  brand: "Registrant",
  source: "research_validated",
  registration_number: registration,
  registration_validated: true,
});

// ---------------------------------------------------------------------------
// §1 — zero strong candidates may never read as "unambiguous"
// ---------------------------------------------------------------------------

Deno.test("THE Hortitrol case: no register match is never reported as unambiguous", () => {
  // The exact production reproduction. The APVMA register matches nothing, so
  // the only rows are research associations.
  const { summary } = rankCandidates(
    [
      researchRow("VICOL WINTER OIL INSECTICIDE", "33182"),
      researchRow("SYNERTROL HORTI BOTANICAL OIL CONCENTRATE", "50067"),
    ],
    "Hortitrol Winter Oil",
    "AU",
  );

  assertEquals(summary.search_state, "no_official_match");
  // The invalid state is now unrepresentable.
  assertEquals(summary.ambiguous, true);
  assertEquals(summary.auto_select_allowed, false);
  assertEquals(summary.exact_registration_number, null);
});

Deno.test("zero strong candidates can never license auto-selection", () => {
  // Property-style: whatever the shape of the input, strong_official == 0
  // must never permit continuation.
  const inputs = [
    [],
    [researchRow("SOMETHING UNRELATED")],
    [researchRow("A", "1"), researchRow("B", "2"), researchRow("C", "3")],
    [registerRow("COMPLETELY DIFFERENT PRODUCT", "999")],
  ];
  for (const rows of inputs) {
    const { summary } = rankCandidates(rows, "Hortitrol Winter Oil", "AU");
    if (summary.strong_official_candidate_count !== 0) continue;
    assertEquals(summary.search_state, "no_official_match");
    assertEquals(summary.auto_select_allowed, false);
    assertEquals(summary.exact_registration_number, null);
    assert(summary.ambiguous, "no official match must never read as unambiguous");
  }
});

Deno.test("an empty result set is no_official_match, not an unambiguous nothing", () => {
  const { results, summary } = rankCandidates([], "Hortitrol Winter Oil", "AU");
  assertEquals(results.length, 0);
  assertEquals(summary.search_state, "no_official_match");
  assertEquals(summary.ambiguous, true);
  assertEquals(summary.auto_select_allowed, false);
});

Deno.test("ambiguous is exactly 'not a proven exact identity'", () => {
  // One rule, so the flag can never drift away from the state again.
  const cases: { rows: Record<string, unknown>[]; query: string }[] = [
    { rows: [registerRow("HORTITROL WINTER OIL", "50067")], query: "Hortitrol winter oil" },
    { rows: [registerRow("WINTER OIL", "1"), registerRow("WINTER OIL CONCENTRATE", "2")], query: "Winter Oil" },
    { rows: [researchRow("VICOL WINTER OIL INSECTICIDE", "33182")], query: "Hortitrol Winter Oil" },
    { rows: [], query: "Hortitrol Winter Oil" },
  ];
  for (const c of cases) {
    const { summary } = rankCandidates(c.rows, c.query, "AU");
    assertEquals(summary.ambiguous, summary.search_state !== "exact");
    assertEquals(summary.auto_select_allowed, summary.search_state === "exact");
  }
});

// ---------------------------------------------------------------------------
// §2 — authoritative candidates are distinguishable from suggestions
// ---------------------------------------------------------------------------

Deno.test("every row states what KIND of candidate it is", () => {
  const { results } = rankCandidates(
    [
      registerRow("HORTITROL WINTER OIL", "50067"),
      validatedRow("VICOL WINTER OIL INSECTICIDE", "33182"),
      researchRow("SOME MODEL ASSOCIATION"),
    ],
    "Hortitrol winter oil",
    "AU",
  );
  const byName = new Map(results.map((r) => [r.name, r.candidate_class]));
  assertEquals(byName.get("HORTITROL WINTER OIL"), "authoritative");
  assertEquals(byName.get("VICOL WINTER OIL INSECTICIDE"), "validated_suggestion");
  assertEquals(byName.get("SOME MODEL ASSOCIATION"), "unverified_suggestion");
});

Deno.test("a row cannot promote itself by claiming a source", () => {
  // `registration_validated` is set only by the validator, which re-reads the
  // register. Research output arrives without it.
  assertEquals(candidateClass({ source: "research" }), "unverified_suggestion");
  assertEquals(
    candidateClass({ source: "research", registration_validated: true }),
    "validated_suggestion",
  );
  // Truthy-but-not-true must not pass.
  assertEquals(
    candidateClass({ source: "research", registration_validated: "yes" }),
    "unverified_suggestion",
  );
});

Deno.test("the summary counts official rows and suggestions separately", () => {
  const { summary } = rankCandidates(
    [
      registerRow("HORTITROL WINTER OIL", "50067"),
      validatedRow("VICOL WINTER OIL INSECTICIDE", "33182"),
      researchRow("A GUESS"),
      researchRow("ANOTHER GUESS"),
    ],
    "Hortitrol winter oil",
    "AU",
  );
  assertEquals(summary.official_candidate_count, 1);
  assertEquals(summary.suggestion_count, 3);
  assertEquals(summary.validated_suggestion_count, 1);
});

// ---------------------------------------------------------------------------
// §3 — suggestions can never auto-continue
// ---------------------------------------------------------------------------

Deno.test("a research suggestion cannot set exact_registration_number", () => {
  // The name is a perfect match, and it is the ONLY row. Under the old rule
  // that was enough to auto-select — from a model's output.
  const { summary } = rankCandidates(
    [researchRow("HORTITROL WINTER OIL", "50067")],
    "Hortitrol Winter Oil",
    "AU",
  );
  assertEquals(summary.exact_registration_number, null);
  assertEquals(summary.search_state, "no_official_match");
  assertEquals(summary.auto_select_allowed, false);
});

Deno.test("a VALIDATED suggestion still cannot auto-continue", () => {
  // The register confirmed the registration exists. That proves the product is
  // real — not that it is the product the operator meant. "Hortitrol" is
  // nowhere in this name.
  const { summary } = rankCandidates(
    [validatedRow("VICOL WINTER OIL INSECTICIDE", "33182")],
    "Hortitrol Winter Oil",
    "AU",
  );
  assertEquals(summary.exact_registration_number, null);
  assertEquals(summary.auto_select_allowed, false);
  assertEquals(summary.validated_suggestion_count, 1);
});

Deno.test("ONE research suggestion is still a choice, not an answer", () => {
  // Explicitly required by §3: "even if research happens to return only one
  // suggestion". A single row is the most tempting case to auto-open.
  const { results, summary } = rankCandidates(
    [validatedRow("VICOL WINTER OIL INSECTICIDE", "33182")],
    "Hortitrol Winter Oil",
    "AU",
  );
  assertEquals(results.length, 1);
  assertEquals(summary.auto_select_allowed, false);
  assertEquals(summary.search_state, "no_official_match");
});

Deno.test("an exact register row beside a suggestion still auto-selects", () => {
  // The suggestion must not POISON a genuine register answer — the register
  // row is exact and the suggestion is unrelated noise.
  const { summary } = rankCandidates(
    [
      registerRow("HORTITROL WINTER OIL", "50067"),
      researchRow("SOMETHING QUITE DIFFERENT"),
    ],
    "Hortitrol winter oil",
    "AU",
  );
  assertEquals(summary.search_state, "exact");
  assertEquals(summary.exact_registration_number, "50067");
  assertEquals(summary.auto_select_allowed, true);
});

Deno.test("a CREDIBLE suggestion beside an exact register row forces a choice", () => {
  // Here the suggestion is a strong name match too, so it is a genuine rival.
  const { summary } = rankCandidates(
    [
      registerRow("WINTER OIL", "1"),
      validatedRow("WINTER OIL CONCENTRATE", "2"),
    ],
    "Winter Oil",
    "AU",
  );
  assertEquals(summary.exact_registration_number, null);
  assertEquals(summary.auto_select_allowed, false);
});

// ---------------------------------------------------------------------------
// §7 — the normal register path is unchanged
// ---------------------------------------------------------------------------

Deno.test("a normal exact register match bypasses all of this", () => {
  const { results, summary } = rankCandidates(
    [
      registerRow("SUMMER AND WINTER SPRAYING OIL", "33182"),
      registerRow("WHITE OIL INSECTICIDE", "12345"),
      registerRow("HORTITROL WINTER OIL", "50067"),
    ],
    "Hortitrol winter oil",
    "AU",
  );
  assertEquals(results[0].registration_number, "50067");
  assertEquals(summary.search_state, "exact");
  assertEquals(summary.exact_registration_number, "50067");
  assertEquals(summary.auto_select_allowed, true);
  assertEquals(summary.suggestion_count, 0);
});

Deno.test("several register candidates stay ambiguous, exactly as before", () => {
  const { summary } = rankCandidates(
    [
      registerRow("COPPER OXYCHLORIDE FUNGICIDE", "1"),
      registerRow("COPPER HYDROXIDE FUNGICIDE", "2"),
      registerRow("TRI-BASE BLUE COPPER FUNGICIDE", "3"),
    ],
    "Copper",
    "AU",
  );
  assertEquals(summary.search_state, "ambiguous");
  assertEquals(summary.strong_candidate_count, 3);
  assertEquals(summary.strong_official_candidate_count, 3);
  assertEquals(summary.exact_registration_number, null);
  assertEquals(summary.auto_select_allowed, false);
});

Deno.test("an approved master hit is authoritative and can auto-select", () => {
  const { summary } = rankCandidates(
    [{
      name: "HORTITROL WINTER OIL",
      source: "master",
      registration_number: "50067",
      review_status: "approved",
      country_code: "AU",
    }],
    "Hortitrol winter oil",
    "AU",
  );
  assertEquals(summary.search_state, "exact");
  assertEquals(summary.official_candidate_count, 1);
  assertEquals(summary.auto_select_allowed, true);
});

Deno.test("an UNAPPROVED master row is not authoritative and cannot auto-select", () => {
  // It falls to `suggestion` tier, so it must also fall out of the official
  // count — otherwise an unapproved catalogue row could carry a search state.
  const { summary } = rankCandidates(
    [{
      name: "HORTITROL WINTER OIL",
      source: "master",
      registration_number: "50067",
      review_status: "candidate",
      country_code: "AU",
    }],
    "Hortitrol winter oil",
    "AU",
  );
  assertEquals(summary.search_state, "no_official_match");
  assertEquals(summary.auto_select_allowed, false);
  assertEquals(summary.exact_registration_number, null);
});

Deno.test("register rows that only match incidentally are not an official match", () => {
  // The register OR-matches whole words across columns, so a query can drag in
  // rows connected by one generic word. Those are not a finding.
  const { summary } = rankCandidates(
    [registerRow("MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY", "1")],
    "Switch",
    "AU",
  );
  assertEquals(summary.strong_official_candidate_count, 0);
  assertEquals(summary.search_state, "no_official_match");
  assertEquals(summary.auto_select_allowed, false);
});
