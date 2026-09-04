import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  baseTier,
  isStrong,
  isUsableMaster,
  rankCandidates,
  rankScore,
  scoreNameRelevance,
  tokens,
} from "./ranking.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const registerRow = (name: string, registration = "80647", brand = "Registrant") => ({
  name,
  brand,
  registration_number: registration,
  source: "official_register",
});

const masterRow = (
  name: string,
  opts: { review_status?: string; country_code?: string } = {},
) => ({
  name,
  brand: "Catalogue",
  registration_number: "11111",
  source: "master",
  ...opts,
});

const aiRow = (name: string) => ({ name, brand: "", source: "ai" });

// ---------------------------------------------------------------------------
// Tokenising
// ---------------------------------------------------------------------------

Deno.test("tokens splits on punctuation and lowercases", () => {
  assertEquals(tokens("TRI-BASE BLUE COPPER"), ["tri", "base", "blue", "copper"]);
  assertEquals(tokens("MORTEIN … & FLY"), ["mortein", "fly"]);
  assertEquals(tokens(""), []);
});

// ---------------------------------------------------------------------------
// Name relevance — ported 1:1 from ChemicalSearchRelevanceTests.swift
// ---------------------------------------------------------------------------

Deno.test("'Chateau' → CHATEAU HERBICIDE is a leading product name", () => {
  // The remainder is a pure formulation word, so the name still reads as the
  // product "Chateau".
  assertEquals(
    scoreNameRelevance("Chateau", "CHATEAU HERBICIDE"),
    "leading_product_name",
  );
});

Deno.test("'Chateau Herbicide' matches the registered name exactly", () => {
  assertEquals(scoreNameRelevance("Chateau Herbicide", "CHATEAU HERBICIDE"), "exact_name");
});

Deno.test("registers shout, operators do not — case is irrelevant", () => {
  assertEquals(scoreNameRelevance("chateau", "CHATEAU HERBICIDE"), "leading_product_name");
});

Deno.test("'Kocide' → KOCIDE BLUE XTRA is a leading token, not a product name", () => {
  // "blue"/"xtra" are not formulation words, so this is a weaker match than
  // CHATEAU HERBICIDE — but still strong.
  assertEquals(scoreNameRelevance("Kocide", "KOCIDE BLUE XTRA"), "leading_token");
});

Deno.test("'Copper' inside TRI-BASE BLUE COPPER FUNGICIDE is a contained phrase", () => {
  assertEquals(
    scoreNameRelevance("Copper", "TRI-BASE BLUE COPPER FUNGICIDE"),
    "contained_phrase",
  );
});

Deno.test("the Mortein case: an incidental word buried in a long name", () => {
  // The measured APVMA row that motivated the whole scorer.
  assertEquals(
    scoreNameRelevance(
      "Switch",
      "MORTEIN PEACEFUL NIGHTS MOSQUITO & FLY CONTROL WITH AUTO SWITCH OFF TECHNOLOGY",
    ),
    "incidental",
  );
});

Deno.test("a row matched on its holder, never its name, is unrelated", () => {
  assertEquals(scoreNameRelevance("Syngenta", "SWITCH FUNGICIDE"), "unrelated");
});

Deno.test("contained_phrase is strong; incidental and unrelated are not", () => {
  // The rule that stops relevance becoming a "mainstream chemicals only"
  // filter — an operator searching a chemistry word wants those products.
  assert(isStrong("exact_name"));
  assert(isStrong("leading_product_name"));
  assert(isStrong("leading_token"));
  assert(isStrong("contained_phrase"));
  assert(!isStrong("incidental"));
  assert(!isStrong("unrelated"));
});

// ---------------------------------------------------------------------------
// Ordering — the SWITCH / MORTEIN protection
// ---------------------------------------------------------------------------

Deno.test("SWITCH FUNGICIDE outranks an incidental 'switch off' product", () => {
  // The register is asked to put Mortein FIRST here on purpose: relevance has
  // to BEAT arrival order, not merely agree with it.
  const { results } = rankCandidates(
    [
      registerRow("MORTEIN PEACEFUL NIGHTS MOSQUITO & FLY CONTROL WITH AUTO SWITCH OFF TECHNOLOGY", "1"),
      registerRow("SWITCH FUNGICIDE", "2"),
    ],
    "Switch",
    "AU",
  );
  assertEquals(results[0].name, "SWITCH FUNGICIDE");
  assertEquals(results[0].rank_relevance, "leading_product_name");
  assertEquals(results[1].rank_tier, "weak_match");
});

Deno.test("demotion is presentation, never deletion", () => {
  const { results } = rankCandidates(
    [
      registerRow("MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY", "1"),
      registerRow("SWITCH FUNGICIDE", "2"),
    ],
    "Switch",
    "AU",
  );
  // Both rows survive. The weak one is labelled, not hidden.
  assertEquals(results.length, 2);
  assert(results.some((r) => r.name.startsWith("MORTEIN")));
});

Deno.test("with NO strong candidate, weak matches stay primary", () => {
  // The safety valve. Burying the only lead would show an empty list for a
  // product that IS in the register.
  const { results, summary } = rankCandidates(
    [registerRow("MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY")],
    "Switch",
    "AU",
  );
  assertEquals(results[0].rank_tier, "official_register");
  assertEquals(results[0].rank_relevance, "incidental");
  assertEquals(summary.demoted_count, 0);
});

Deno.test("equal relevance preserves the register's own order (stable sort)", () => {
  const { results } = rankCandidates(
    [registerRow("COPPER A", "1"), registerRow("COPPER B", "2")],
    "Copper",
    "AU",
  );
  assertEquals(results.map((r) => r.name), ["COPPER A", "COPPER B"]);
  assertEquals(results.map((r) => r.register_order), [0, 1]);
});

Deno.test("a chemistry-word search keeps every match primary", () => {
  const { results } = rankCandidates(
    [
      registerRow("TRI-BASE BLUE COPPER FUNGICIDE", "1"),
      registerRow("COPPER OXYCHLORIDE FUNGICIDE", "2"),
    ],
    "Copper",
    "AU",
  );
  // COPPER OXYCHLORIDE leads: leading_product_name beats contained_phrase.
  assertEquals(results[0].name, "COPPER OXYCHLORIDE FUNGICIDE");
  assert(results.every((r) => r.rank_tier === "official_register"));
});

// ---------------------------------------------------------------------------
// Tiers
// ---------------------------------------------------------------------------

Deno.test("an approved same-country master leads the official register", () => {
  const { results } = rankCandidates(
    [
      registerRow("SWITCH FUNGICIDE", "2"),
      masterRow("SWITCH FUNGICIDE", { review_status: "approved", country_code: "AU" }),
    ],
    "Switch Fungicide",
    "AU",
  );
  assertEquals(results[0].source, "master");
  assertEquals(results[0].rank_tier, "approved_master");
});

Deno.test("a non-approved master row loses its catalogue authority", () => {
  // sql/199 seeds CANDIDATE rows deliberately; presenting one as verified
  // would mean the word "verified" had been earned by nothing.
  assert(!isUsableMaster(masterRow("X", { review_status: "candidate" }), "AU"));
  assert(!isUsableMaster(masterRow("X", { review_status: "retired" }), "AU"));
  assertEquals(
    baseTier(masterRow("X", { review_status: "candidate" }), "AU"),
    "suggestion",
  );
});

Deno.test("a foreign master row loses its catalogue authority", () => {
  // An AU registration shown to an NZ vineyard is different label law.
  assert(isUsableMaster(masterRow("X", { country_code: "AU" }), "AU"));
  assert(!isUsableMaster(masterRow("X", { country_code: "AU" }), "NZ"));
});

Deno.test("absent master metadata reads as approved (server already filtered)", () => {
  assert(isUsableMaster(masterRow("X"), "AU"));
});

Deno.test("an AI suggestion ranks below a register candidate", () => {
  const { results } = rankCandidates(
    [aiRow("SWITCH FUNGICIDE"), registerRow("SWITCH FUNGICIDE", "2")],
    "Switch Fungicide",
    "AU",
  );
  assertEquals(results[0].source, "official_register");
  assertEquals(results[1].source, "ai");
});

// ---------------------------------------------------------------------------
// Scores and reasons
// ---------------------------------------------------------------------------

Deno.test("rank_score is a readable projection of tier and relevance", () => {
  assertEquals(rankScore("approved_master", "exact_name"), 100);
  assertEquals(rankScore("official_register", "exact_name"), 100);
  assertEquals(rankScore("official_register", "contained_phrase"), 59);
  assertEquals(rankScore("weak_match", "incidental"), 5);
  // Clamped, never negative and never above 100.
  assert(rankScore("weak_match", "unrelated") >= 0);
});

Deno.test("sorting by rank_score alone still yields a defensible order", () => {
  // A client that ignores our order and sorts by score must not end up with
  // something absurd. Scores are a projection of the real key, not a rival.
  const { results } = rankCandidates(
    [
      registerRow("MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY", "1"),
      registerRow("SWITCH FUNGICIDE", "2"),
    ],
    "Switch",
    "AU",
  );
  const byScore = [...results].sort((a, b) => b.rank_score - a.rank_score);
  assertEquals(byScore[0].name, results[0].name);
});

Deno.test("rank_reason names both halves of the decision", () => {
  const { results } = rankCandidates([registerRow("SWITCH FUNGICIDE")], "Switch", "AU");
  assertEquals(results[0].rank_reason, "leading_product_name/official_register");
});

Deno.test("register_order preserves the pre-ranking position for debugging", () => {
  const { results } = rankCandidates(
    [
      registerRow("MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY", "1"),
      registerRow("SWITCH FUNGICIDE", "2"),
    ],
    "Switch",
    "AU",
  );
  // Ranking CHANGED the order; that fact must be visible.
  assertEquals(results[0].register_order, 1);
  assertEquals(results[1].register_order, 0);
});

// ---------------------------------------------------------------------------
// Ambiguity (task §1) — the Hortitrol reproduction
// ---------------------------------------------------------------------------

Deno.test("Hortitrol: the exact product beats generic 'winter'/'oil' noise", () => {
  // The register ORs whole words across columns, so a query containing two
  // generic words drags in unrelated oils. The exact product must lead, and
  // the noise must be demoted — this is the reproduction from the task.
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
  assertEquals(results[0].rank_relevance, "exact_name");
  // The generic oils are still SELECTABLE, just below.
  assertEquals(results.length, 3);
  assertEquals(summary.exact_registration_number, "50067");
  assertEquals(summary.ambiguous, false);
});

Deno.test("final ranking deduplicates one canonical identity and prefers authority", () => {
  const validatedSuggestion = {
    name: "EXAMPLE RIDGESHIELD 750 WG FUNGICIDE",
    registration_number: "90-279",
    registration_country: "AU",
    registration_scheme: "APVMA",
    source: "research_validated",
    registration_validated: true,
  };
  const authoritative = {
    ...registerRow("EXAMPLE RIDGESHIELD 750 WG FUNGICIDE", "90279"),
    registration_country: "AU",
    registration_scheme: "apvma",
  };
  const { results, summary } = rankCandidates(
    [validatedSuggestion, authoritative],
    "Example Ridgeshield",
    "AU",
  );
  assertEquals(results.length, 1);
  assertEquals(results[0].source, "official_register");
  assertEquals(summary.official_candidate_count, 1);
  assertEquals(summary.suggestion_count, 0);
  assertEquals(summary.search_state, "exact");
  assertEquals(summary.ambiguous, false);
  assertEquals(summary.exact_registration_number, "90279");
});

Deno.test("CropSure live shape: one strong official APVMA candidate is not ambiguous", () => {
  const { results, summary } = rankCandidates(
    [{
      name: "REGISTERED CROPSURE GREENSHIELD FUNGICIDE",
      brand: "CROPSURE PTY LTD",
      registration_country: "AU",
      registration_scheme: "apvma",
      registration_number: "90279",
      source: "official_register",
      activeIngredient: "Mancozeb 750 g/kg",
    }],
    "cropsure greenshield",
    "AU",
  );

  assertEquals(results.length, 1);
  assertEquals(results[0].registration_number, "90279");
  assertEquals(results[0].activeIngredient, "Mancozeb 750 g/kg");
  assertEquals(summary.strong_candidate_count, 1);
  assertEquals(summary.strong_official_candidate_count, 1);
  assertEquals(summary.search_state, "exact");
  assertEquals(summary.ambiguous, false);
  assertEquals(summary.auto_select_allowed, true);
  assertEquals(summary.exact_registration_number, "90279");
});

Deno.test("a genuinely ambiguous query keeps several credible candidates", () => {
  // Task §1: search should normally return ~2–5 plausible products when the
  // query is ambiguous, and must NOT be forced into one.
  const { results, summary } = rankCandidates(
    [
      registerRow("COPPER OXYCHLORIDE FUNGICIDE", "1"),
      registerRow("COPPER HYDROXIDE FUNGICIDE", "2"),
      registerRow("TRI-BASE BLUE COPPER FUNGICIDE", "3"),
    ],
    "Copper",
    "AU",
  );
  assertEquals(results.length, 3);
  assertEquals(summary.strong_candidate_count, 3);
  assertEquals(summary.ambiguous, true);
  // Nothing may be auto-selected here.
  assertEquals(summary.exact_registration_number, null);
});

Deno.test("an exact name beside another strong candidate is NOT auto-selectable", () => {
  // The core §1 protection: scoring slightly higher is not the same as being
  // unambiguous. A human still chooses.
  const { summary } = rankCandidates(
    [
      registerRow("WINTER OIL", "1"),
      registerRow("WINTER OIL CONCENTRATE", "2"),
    ],
    "Winter Oil",
    "AU",
  );
  assertEquals(summary.exact_registration_number, null);
  assertEquals(summary.ambiguous, true);
});

Deno.test("two rows sharing one exact name are not auto-selectable", () => {
  // Pack registrations share a verbatim name. Picking one silently would be
  // picking a registration nobody chose.
  const { summary } = rankCandidates(
    [registerRow("WINTER OIL", "1"), registerRow("WINTER OIL", "2")],
    "Winter Oil",
    "AU",
  );
  assertEquals(summary.exact_registration_number, null);
});

Deno.test("a lone exact match with only weak company IS auto-selectable", () => {
  const { summary } = rankCandidates(
    [
      registerRow("HORTITROL WINTER OIL", "50067"),
      registerRow("SOMETHING ELSE ENTIRELY", "999"),
    ],
    "Hortitrol winter oil",
    "AU",
  );
  assertEquals(summary.exact_registration_number, "50067");
  assertEquals(summary.ambiguous, false);
});

// ---------------------------------------------------------------------------
// Robustness
// ---------------------------------------------------------------------------

Deno.test("an empty query leaves the upstream order untouched", () => {
  const { results } = rankCandidates(
    [registerRow("B", "1"), registerRow("A", "2")],
    "",
    "AU",
  );
  assertEquals(results.map((r) => r.name), ["B", "A"]);
});

Deno.test("ranking never drops or duplicates a row", () => {
  const rows = [
    registerRow("SWITCH FUNGICIDE", "1"),
    registerRow("MORTEIN AUTO SWITCH OFF", "2"),
    masterRow("SWITCH CATALOGUE"),
    aiRow("SWITCH GUESS"),
  ];
  const { results } = rankCandidates(rows, "Switch", "AU");
  assertEquals(results.length, rows.length);
  assertEquals(
    new Set(results.map((r) => r.name)).size,
    new Set(rows.map((r) => r.name)).size,
  );
});

Deno.test("ranking is deterministic — the same input gives the same order", () => {
  const rows = [
    registerRow("SUMMER AND WINTER SPRAYING OIL", "33182"),
    registerRow("HORTITROL WINTER OIL", "50067"),
    registerRow("WHITE OIL", "12345"),
  ];
  const a = rankCandidates(rows, "Hortitrol winter oil", "AU");
  const b = rankCandidates(rows, "Hortitrol winter oil", "AU");
  assertEquals(
    a.results.map((r) => r.registration_number),
    b.results.map((r) => r.registration_number),
  );
});

Deno.test("a row with no name is scored, not crashed on", () => {
  const { results } = rankCandidates([{ source: "official_register" } as any], "x", "AU");
  assertEquals(results.length, 1);
  assertEquals(results[0].rank_relevance, "unrelated");
});

Deno.test("ranking preserves every original field", () => {
  const { results } = rankCandidates(
    [{ ...registerRow("SWITCH FUNGICIDE"), activeIngredient: "Cyprodinil", custom: 7 }],
    "Switch",
    "AU",
  );
  assertEquals(results[0].activeIngredient, "Cyprodinil");
  assertEquals((results[0] as any).custom, 7);
  assertEquals(results[0].registration_number, "80647");
});
