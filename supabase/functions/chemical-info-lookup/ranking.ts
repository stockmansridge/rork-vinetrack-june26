// Server-authoritative candidate ranking (task §1, §2).
//
// # Why this moved off the device
//
// Ranking used to live in the iOS client (`ChemicalSearchRanking.swift`).
// Android had no ranking at all, and the Portal had a third behaviour. Three
// clients asking one server the same question therefore got three different
// orders — which is precisely the "Hortitrol winter oil resolves to 50067 on
// Portal and 33182 on iOS" defect. Ordering is a property of the ANSWER, so
// it belongs to whoever knows the register: the server.
//
// # What was preserved, and why it must not be simplified away
//
// The iOS scorer was not decoration. The APVMA register is a legal list —
// household insecticides, veterinary medicines and technical-grade actives sit
// beside SWITCH FUNGICIDE — and its full-text search matches whole words in ANY
// column. A query of "Switch" legitimately returns both `SWITCH FUNGICIDE` and
// `MORTEIN PEACEFUL NIGHTS … WITH AUTO SWITCH OFF TECHNOLOGY`. The register is
// not wrong; presenting the two as equal candidates is. Every rule below exists
// for a measured case of that shape.
//
// Two invariants carried over verbatim:
//
//   * NOTHING IS EVER REMOVED. Demotion moves a row into a labelled section.
//     A vineyard searching for a regional adjuvant by a generic word still
//     finds it, just below the product whose name they typed.
//   * DEMOTION IS CONDITIONAL. With no strong candidate on screen the
//     operator's only lead may be a weak one, and hiding it would show an
//     empty list for a product that IS in the register.
//
// This is deliberately a STRING RULE and not a classifier. Nothing here asks a
// model what a product is for: search must give the same answer for the same
// query every time, and a rule that decided which products were "mainstream
// enough" would quietly bury the regional adjuvants, biostimulants and
// fertilisers a vineyard actually buys.

// deno-lint-ignore-file no-explicit-any

/**
 * How well a candidate's NAME answers the query. Lower is better.
 *
 * Ported 1:1 from `ChemicalNameRelevance`; the wire strings are the enum's
 * own names so a diagnostics line reads as English.
 */
export type NameRelevance =
  /** The registered name IS the query. */
  | "exact_name"
  /** The query is the leading run of the name and the remainder is only
   *  formulation words: `Chateau` → `CHATEAU HERBICIDE`. */
  | "leading_product_name"
  /** The query starts the name, remainder is not formulation words:
   *  `Kocide` → `KOCIDE BLUE XTRA`. */
  | "leading_token"
  /** The query's words appear as whole words, contiguously, but not at the
   *  start: `Copper` → `TRI-BASE BLUE COPPER FUNGICIDE`. */
  | "contained_phrase"
  /** The words appear, but scattered, or only as a fragment. This is where
   *  `…AUTO SWITCH OFF TECHNOLOGY` lands. */
  | "incidental"
  /** No name connection — matched on holder, active or formulation text. */
  | "unrelated";

const RELEVANCE_ORDER: NameRelevance[] = [
  "exact_name",
  "leading_product_name",
  "leading_token",
  "contained_phrase",
  "incidental",
  "unrelated",
];

export function relevanceRank(r: NameRelevance): number {
  const i = RELEVANCE_ORDER.indexOf(r);
  return i < 0 ? RELEVANCE_ORDER.length : i;
}

/**
 * Whether a row at this relevance may stand as a PRIMARY candidate.
 *
 * `contained_phrase` counts as strong on purpose: "copper" genuinely describes
 * `TRI-BASE BLUE COPPER FUNGICIDE`, and demoting it would hide the products an
 * operator searching by chemistry is looking for.
 */
export function isStrong(r: NameRelevance): boolean {
  return relevanceRank(r) <= relevanceRank("contained_phrase");
}

/** Where a row sits in the order, and why. Lower is better. */
export type RankTier =
  /** An APPROVED master catalogue product for this vineyard's country. */
  | "approved_master"
  /** A candidate from the jurisdiction's official register. */
  | "official_register"
  /** Model suggestions, and any master row that failed approval/country. */
  | "suggestion"
  /** An incidental word match, shown BELOW everything because a strong
   *  candidate also exists. */
  | "weak_match";

const TIER_ORDER: RankTier[] = [
  "approved_master",
  "official_register",
  "suggestion",
  "weak_match",
];

export function tierRank(t: RankTier): number {
  const i = TIER_ORDER.indexOf(t);
  return i < 0 ? TIER_ORDER.length : i;
}

/**
 * Words describing a product's FORM rather than its identity, so
 * `CHATEAU HERBICIDE` still reads as the product "Chateau".
 *
 * Ported verbatim from the iOS `formulationTokens` set. Changing this set
 * changes search ordering, so it is covered by tests naming real products.
 */
const FORMULATION_TOKENS = new Set<string>([
  "herbicide", "fungicide", "insecticide", "miticide", "acaricide",
  "nematicide", "bactericide", "molluscicide", "rodenticide",
  "adjuvant", "surfactant", "wetter", "spreader", "sticker", "penetrant",
  "fertiliser", "fertilizer", "biostimulant", "inoculant",
  "concentrate", "solution", "suspension", "emulsion",
  "wg", "wp", "sc", "ec", "sl", "df", "wdg", "ew", "od", "me", "cs", "gr",
  "granules", "granule", "liquid", "dust", "powder", "spray", "plus",
  "product", "technical", "grade",
]);

/** Splits a name into lowercased alphanumeric word tokens. */
export function tokens(value: string): string[] {
  return (value ?? "")
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => t.length > 0);
}

/**
 * Classify a contiguous whole-word occurrence of the query inside the name.
 *
 * # The defect this repairs
 *
 * The iOS original returned `containedPhrase` for ANY contiguous run, which
 * made these two indistinguishable:
 *
 * ```text
 *   "Copper" → TRI-BASE BLUE COPPER FUNGICIDE                     (wanted)
 *   "Switch" → MORTEIN … WITH AUTO SWITCH OFF TECHNOLOGY          (noise)
 * ```
 *
 * Both scored `containedPhrase`, and `containedPhrase` is STRONG — so the
 * Mortein row was never demoted. The scorer's own tests assert it should be
 * (`incidentalMatchIsDemoted`, `inStoreIsNeverDemoted`), so the intent was
 * always this; the code simply never implemented it, and because the iOS test
 * suite is not run by the build, the contradiction went unnoticed.
 *
 * # The rule
 *
 * What FOLLOWS the match decides. A query that lands at the end of the
 * product's identity — with only formulation words after it, or nothing — is
 * describing the product. A query buried mid-phrase with substantive words
 * after it is incidental:
 *
 * ```text
 *   … BLUE COPPER | FUNGICIDE          tail = [fungicide]      → contained
 *   … AUTO SWITCH | OFF TECHNOLOGY     tail = [off, technology] → incidental
 * ```
 *
 * Every occurrence is tried, and the BEST verdict wins — one incidental
 * mention must not bury a name that also uses the word properly.
 *
 * Returns `null` when the query does not appear contiguously at all.
 */
function classifyContainedRun(
  haystack: string[],
  needle: string[],
): "contained_phrase" | "incidental" | null {
  if (needle.length > haystack.length) return null;
  let found = false;
  for (let start = 0; start <= haystack.length - needle.length; start++) {
    let all = true;
    for (let i = 0; i < needle.length; i++) {
      if (haystack[start + i] !== needle[i]) {
        all = false;
        break;
      }
    }
    if (!all) continue;
    found = true;
    const tail = haystack.slice(start + needle.length);
    if (tail.every((t) => FORMULATION_TOKENS.has(t))) return "contained_phrase";
  }
  return found ? "incidental" : null;
}

/**
 * Score how well a registered NAME answers a query.
 *
 * Ported 1:1 from `ChemicalNameRelevanceScorer.score`, including the ordering
 * of the tests — the branches are not independent and reordering them changes
 * the answer.
 */
export function scoreNameRelevance(query: string, name: string): NameRelevance {
  const queryTokens = tokens(query);
  const nameTokens = tokens(name);
  if (!queryTokens.length || !nameTokens.length) return "unrelated";

  if (
    queryTokens.length === nameTokens.length &&
    queryTokens.every((t, i) => t === nameTokens[i])
  ) {
    return "exact_name";
  }

  if (nameTokens.length > queryTokens.length) {
    const prefixMatches = queryTokens.every((t, i) => t === nameTokens[i]);
    if (prefixMatches) {
      const remainder = nameTokens.slice(queryTokens.length);
      return remainder.every((t) => FORMULATION_TOKENS.has(t))
        ? "leading_product_name"
        : "leading_token";
    }
  }

  const contained = classifyContainedRun(nameTokens, queryTokens);
  if (contained) return contained;

  // Every query word present as a whole word, but not contiguously.
  if (queryTokens.every((t) => nameTokens.includes(t))) return "incidental";

  // A fragment: the query is a prefix of some token (`chat` → `chateau`).
  if (queryTokens.length === 1) {
    const first = queryTokens[0];
    if (nameTokens.some((t) => t.startsWith(first) || first.startsWith(t))) {
      return "incidental";
    }
  }

  return "unrelated";
}

/**
 * Whether a master row may be presented with catalogue authority.
 *
 * Both tests must pass. Absent metadata reads as "the server already applied
 * its own rule": sql/199's RLS only returns approved rows to ordinary users,
 * and search is country-scoped at the request. This is a re-check, so that a
 * future relaxation of either rule cannot quietly promote a row here.
 */
export function isUsableMaster(row: any, countryCode: string): boolean {
  const status = String(row?.review_status ?? "").trim().toLowerCase();
  if (status && status !== "approved") return false;
  const rowCountry = String(row?.country_code ?? row?.registration_country ?? "")
    .trim().toUpperCase();
  const wanted = String(countryCode ?? "").trim().toUpperCase();
  if (rowCountry && wanted && rowCountry !== wanted) return false;
  return true;
}

/** The base tier a row earns before conditional demotion. */
export function baseTier(row: any, countryCode: string): RankTier {
  const source = String(row?.source ?? "").trim();
  if (source === "master") {
    return isUsableMaster(row, countryCode) ? "approved_master" : "suggestion";
  }
  if (source === "official_register") return "official_register";
  return "suggestion";
}

/**
 * A 0–100 score, derived DETERMINISTICALLY from tier and relevance.
 *
 * Presented for diagnostics and for the Portal to display; it is not an
 * independent signal. Ordering is decided by (tier, relevance, register
 * order) exactly as on iOS — the score is a readable projection of the first
 * two, never a tiebreaker of its own, so a client that sorted by score alone
 * would still get a defensible order.
 */
export function rankScore(tier: RankTier, relevance: NameRelevance): number {
  const relevanceBase: Record<NameRelevance, number> = {
    exact_name: 100,
    leading_product_name: 85,
    leading_token: 70,
    contained_phrase: 55,
    incidental: 25,
    unrelated: 10,
  };
  const tierBonus: Record<RankTier, number> = {
    approved_master: 8,
    official_register: 4,
    suggestion: 0,
    weak_match: -20,
  };
  const raw = relevanceBase[relevance] + tierBonus[tier];
  return Math.max(0, Math.min(100, raw));
}

export interface RankedRow {
  /** Position in the list the upstream tiers produced, before ranking.
   *  Kept for debugging: it is the only way to see that ranking CHANGED
   *  something, which is exactly what a parity investigation needs. */
  register_order: number;
  rank_tier: RankTier;
  rank_relevance: NameRelevance;
  rank_score: number;
  rank_reason: string;
}

export interface RankingSummary {
  /** True when several credible products answer the query. */
  ambiguous: boolean;
  /** Count of rows that may stand as primary candidates. */
  strong_candidate_count: number;
  /** The registration number of a genuinely unambiguous exact identity, or
   *  null. A client may treat THIS as safe to auto-select; anything else
   *  requires a human choice. */
  exact_registration_number: string | null;
  /** How many rows were demoted for being incidental word matches. */
  demoted_count: number;
}

export interface RankingResult<T> {
  results: (T & RankedRow)[];
  summary: RankingSummary;
}

/**
 * Order candidates authoritatively.
 *
 * ```text
 * A. an APPROVED master catalogue product for this vineyard's country
 * B. official-register candidates, best NAME match first
 * C. everything else
 * D. incidental word matches, only ever below a strong candidate
 * ```
 *
 * The sort is STABLE on the incoming order, so where tier and relevance tie
 * the register's own ranking survives — re-sorting alphabetically would throw
 * away information the register spent a query producing.
 *
 * Note what is NOT here: "already in the vineyard's Chemical Store". That tier
 * existed on iOS because the device knows the vineyard's own stock. The server
 * does not, and must not guess. The client annotates duplicates in place
 * WITHOUT reordering, so the served order stays the order every platform
 * shows.
 */
export function rankCandidates<T extends Record<string, any>>(
  rows: T[],
  query: string,
  countryCode: string,
): RankingResult<T> {
  const trimmedQuery = (query ?? "").trim();

  const scored = (rows ?? []).map((row, index) => {
    const relevance: NameRelevance = trimmedQuery
      ? scoreNameRelevance(trimmedQuery, String(row?.name ?? ""))
      : "exact_name";
    return {
      row,
      index,
      tier: baseTier(row, countryCode),
      relevance,
    };
  });

  // Conditional demotion — the safety valve. Only ever applies when a strong
  // candidate exists to demote something BELOW.
  const hasStrongCandidate = scored.some((s) => isStrong(s.relevance));
  let demotedCount = 0;
  const adjusted = scored.map((s) => {
    const demotable = s.tier === "official_register" || s.tier === "suggestion";
    if (hasStrongCandidate && !isStrong(s.relevance) && demotable) {
      demotedCount++;
      return { ...s, tier: "weak_match" as RankTier };
    }
    return s;
  });

  const ordered = [...adjusted].sort((a, b) => {
    const t = tierRank(a.tier) - tierRank(b.tier);
    if (t !== 0) return t;
    const r = relevanceRank(a.relevance) - relevanceRank(b.relevance);
    if (r !== 0) return r;
    return a.index - b.index;
  });

  const results = ordered.map((s) => ({
    ...s.row,
    register_order: s.index,
    rank_tier: s.tier,
    rank_relevance: s.relevance,
    rank_score: rankScore(s.tier, s.relevance),
    rank_reason: `${s.relevance}/${s.tier}`,
  }));

  const strongRows = adjusted.filter((s) => isStrong(s.relevance));

  // # When ONE result may be treated as an exact identity (task §1)
  //
  // Only when the identity is genuinely unambiguous: exactly one row whose
  // name IS the query, and no OTHER row credible enough to be a rival. An
  // exact name sitting beside a second strong candidate is still a choice for
  // a human — "Hortitrol winter oil" must not silently become one product
  // because it happened to sort first.
  const exactRows = adjusted.filter((s) => s.relevance === "exact_name");
  const rivals = strongRows.filter((s) => s.relevance !== "exact_name");
  const exactRegistration = exactRows.length === 1 && rivals.length === 0
    ? (String(exactRows[0].row?.registration_number ?? "").trim() || null)
    : null;

  return {
    results,
    summary: {
      ambiguous: strongRows.length > 1,
      strong_candidate_count: strongRows.length,
      exact_registration_number: exactRegistration,
      demoted_count: demotedCount,
    },
  };
}
