// Shared deterministic product-name matching — the ONE matcher every
// register-facing resolution path uses (live APVMA adapter, seed apply hint
// verification, register retrieval variants).
//
// This module generalises the protections developed in the AWRI matching work
// (seed_awri_match.ts, Stage 5E) into the live pipeline:
//
//   * TYPOGRAPHY IS NEVER IDENTITY. Case, punctuation, spacing and pack-code
//     spacing ("250SC" ↔ "250 SC", "Spray Seal" ↔ "Sprayseal") normalise
//     away. Splitting can never merge two distinct brands: tokens are only
//     ever split, never joined or rewritten — and every tie still fails
//     closed.
//   * VARIANT DESIGNATORS ARE ALWAYS IDENTITY. "FORTE", "ULTRA", "DUO",
//     "MAX", "PLUS", … denote a DIFFERENT registered product. They can never
//     be part of a dropped remainder on either side of a comparison, so
//     "Custodia" can never reach "CUSTODIA FORTE" and "Custodia Forte" can
//     never fall back to "CUSTODIA".
//   * SUBSTRING/FUZZY MATCHING IS STRUCTURALLY IMPOSSIBLE. A register name
//     corresponds only when it is the requested name plus a droppable
//     remainder of formulation/category/use-descriptor tokens (or vice
//     versa), compared at token boundaries.
//   * AT MOST ONE ROW. Selection runs tier by tier; two survivors at the
//     deciding tier are AMBIGUOUS and fail closed — never "pick the best".

// ---------------------------------------------------------------------------
// Normalisation
// ---------------------------------------------------------------------------

/** Strict: lowercase, alphanumeric-only tokens, single spaces. */
export function normaliseProductName(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/**
 * Loose: strict normalisation plus a split at every letter↔digit boundary so
 * "250SC" and "250 SC" — pure typography — compare equal. Mirrors the AWRI
 * Stage 5E `normaliseNameLoose` exactly.
 */
export function normaliseProductNameLoose(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/([a-z])(?=[0-9])/g, "$1 ")
    .replace(/([0-9])(?=[a-z])/g, "$1 ")
    .trim()
    .replace(/\s+/g, " ");
}

/** Compact: loose normalisation with spaces removed ("Spray Seal" → "sprayseal"). */
export function compactProductName(raw: string): string {
  return normaliseProductNameLoose(raw).replaceAll(" ", "");
}

// ---------------------------------------------------------------------------
// Token classes
// ---------------------------------------------------------------------------

/**
 * Tokens a register name may append to a brand without changing WHICH product
 * it is: pack strength numbers, formulation codes, category words, and
 * use-descriptor words ("PRUNING WOUND TREATMENT"). Meaningful variant words
 * ("FORTE", "ULTRA", "DUO", …) are deliberately NOT here — see VARIANT_TOKENS.
 */
export const IGNORABLE_SUFFIX_TOKENS: ReadonlySet<string> = new Set([
  // Formulation codes
  "sc", "ec", "wg", "wdg", "wp", "sl", "se", "ew", "gr", "df", "dp", "ulv",
  "cs", "od", "sg", "sp", "la", "me", "fs",
  // Bare units (loose splitting turns "500g" into "500 g")
  "g", "kg", "ml", "l",
  // Category words
  "fungicide", "herbicide", "insecticide", "miticide", "acaricide",
  "nematicide", "bactericide", "adjuvant", "surfactant",
  // Formulation words
  "liquid", "concentrate", "suspension", "emulsifiable", "soluble",
  "dispersible", "flowable", "granule", "granules", "powder", "spray",
  "systemic", "selective", "wettable",
  // Use-descriptor words (a use context, never a product variant)
  "foliar", "pruning", "wound", "treatment", "dressing", "seed",
]);

/**
 * Variant designators that denote a DIFFERENT registered product. Verbatim
 * from the AWRI Stage 5E matching work (seed_awri_match.ts VARIANT_TOKENS) —
 * a sync test keeps the two sets identical.
 */
export const VARIANT_TOKENS: ReadonlySet<string> = new Set([
  "forte", "ultra", "duo", "xtra", "extra", "max", "maxx", "plus", "pro",
  "advance", "advanced", "gold", "super", "turbo", "twin", "trio", "elite",
  "evo", "prime", "premium", "platinum", "xpro", "opti", "optimo", "top",
  "flexi", "flex", "xcel", "excel", "xt", "xl", "xtreme", "ii", "iii", "iv",
]);

function isNumericToken(token: string): boolean {
  return /^\d+(\.\d+)?$/.test(token);
}

function isIgnorableToken(token: string): boolean {
  if (isNumericToken(token)) return true; // "320", "430"
  if (/^\d+(\.\d+)?(g|kg|ml|l)$/.test(token)) return true; // "500g" (strict tokens)
  return IGNORABLE_SUFFIX_TOKENS.has(token);
}

/** A remainder is droppable iff every token is ignorable and none is a variant. */
export function droppableRemainder(tokens: string[]): boolean {
  if (!tokens.length) return false;
  if (tokens.some((t) => VARIANT_TOKENS.has(t))) return false;
  return tokens.every((t) => isIgnorableToken(t));
}

// ---------------------------------------------------------------------------
// Correspondence
// ---------------------------------------------------------------------------

/**
 * How a register name corresponds to a requested name, or null.
 * Tier order (each deterministic, none fuzzy):
 *   exact_name                  strict normalised equality
 *   compact_name                equal after typography normalisation only
 *                               (loose split and/or spacing: "Spray Seal" ↔
 *                               "Sprayseal", "250SC" ↔ "250 SC")
 *   formulation_suffix          register name = requested name + droppable
 *                               remainder ("Sprayseal" ↔ "SPRAYSEAL PRUNING
 *                               WOUND TREATMENT")
 *   reverse_formulation_suffix  requested name = register name + droppable
 *                               remainder ("Prosaro 420 SC Foliar Fungicide"
 *                               ↔ "PROSARO 420 SC")
 */
export type NameMatchTier =
  | "exact_name"
  | "compact_name"
  | "formulation_suffix"
  | "reverse_formulation_suffix";

/**
 * Compact-prefix scan at TOKEN boundaries: does `tokens` begin with a token
 * prefix whose compact form equals `wantedCompact`? Returns the remainder
 * tokens, "" (empty remainder = pure typography equality), or null.
 * Substrings can never match: the prefix must land exactly on the compact
 * form ("custodia" never matches inside "mycustodia").
 */
function compactPrefixRemainder(
  wantedCompact: string,
  tokens: string[],
): string[] | null {
  if (!wantedCompact) return null;
  let compact = "";
  for (let i = 0; i < tokens.length; i++) {
    compact += tokens[i];
    if (compact.length > wantedCompact.length) return null;
    if (compact === wantedCompact) return tokens.slice(i + 1);
  }
  return null;
}

/** The tier at which the register name corresponds to the requested name, or null. */
export function nameMatchTier(
  requested: string,
  registerName: string,
): NameMatchTier | null {
  const wantedStrict = normaliseProductName(requested);
  const actualStrict = normaliseProductName(registerName);
  if (!wantedStrict || !actualStrict) return null;
  if (wantedStrict === actualStrict) return "exact_name";

  const wantedCompact = compactProductName(requested);
  const actualTokens = normaliseProductNameLoose(registerName).split(" ");
  const forward = compactPrefixRemainder(wantedCompact, actualTokens);
  if (forward !== null) {
    if (forward.length === 0) return "compact_name";
    if (droppableRemainder(forward)) return "formulation_suffix";
    return null; // remainder contains a variant/meaningful token — different product
  }

  const actualCompact = compactProductName(registerName);
  const wantedTokens = normaliseProductNameLoose(requested).split(" ");
  const reverse = compactPrefixRemainder(actualCompact, wantedTokens);
  if (reverse !== null && reverse.length > 0 && droppableRemainder(reverse)) {
    return "reverse_formulation_suffix";
  }
  return null;
}

/**
 * Whether a register product name corresponds to a requested name under the
 * deterministic rules. Same guarantees as ever: substring matching is
 * structurally impossible, and a variant word on either side blocks the match.
 */
export function nameCorresponds(requested: string, registerName: string): boolean {
  return nameMatchTier(requested, registerName) !== null;
}

// ---------------------------------------------------------------------------
// Row selection (fail-closed, tier by tier)
// ---------------------------------------------------------------------------

interface NamedRow {
  pcode: string;
  fpname: string;
}

export type SelectionMode = NameMatchTier;

const TIER_ORDER: NameMatchTier[] = [
  "exact_name",
  "compact_name",
  "formulation_suffix",
  "reverse_formulation_suffix",
];

/**
 * Deterministically select AT MOST one register row for the requested names.
 * Rows are ranked by the strongest tier at which they correspond; the best
 * tier must contain EXACTLY ONE row or the selection is ambiguous and fails
 * closed. A weaker-tier row can never outrank a stronger one, so an exact
 * register name always beats a suffix correspondence.
 */
export function selectProductRow<T extends NamedRow>(
  requestedNames: string[],
  rows: T[],
): { row: T; mode: SelectionMode } | "ambiguous" | null {
  const names = requestedNames.map((n) => n.trim()).filter((n) => n.length > 0);
  if (!names.length || !rows.length) return null;

  const byPcode = new Map<string, T>();
  for (const row of rows) {
    if (row?.pcode && row?.fpname) byPcode.set(String(row.pcode), row);
  }
  const unique = Array.from(byPcode.values());

  const tierOf = (row: T): NameMatchTier | null => {
    let best: NameMatchTier | null = null;
    for (const name of names) {
      const tier = nameMatchTier(name, row.fpname);
      if (!tier) continue;
      if (best === null || TIER_ORDER.indexOf(tier) < TIER_ORDER.indexOf(best)) {
        best = tier;
      }
    }
    return best;
  };

  for (const tier of TIER_ORDER) {
    const at = unique.filter((r) => tierOf(r) === tier);
    if (at.length === 1) return { row: at[0], mode: tier };
    if (at.length > 1) return "ambiguous";
  }
  return null;
}

// ---------------------------------------------------------------------------
// Retrieval variants
// ---------------------------------------------------------------------------

/**
 * Full-text query variants for register RETRIEVAL only (matching stays
 * deterministic against the original requested name). The live APVMA CKAN
 * datastore tokenises on whitespace, so "Spray Seal" retrieves ZERO rows for
 * the registered name "Sprayseal Pruning Wound Treatment" — the compact
 * variant finds it, and the loose variant finds spaced register names from a
 * compact request. Bounded (≤3), deduplicated, order = most-specific first.
 */
export function retrievalQueryVariants(raw: string): string[] {
  const out: string[] = [];
  const push = (v: string) => {
    const t = v.trim();
    if (t && !out.includes(t)) out.push(t);
  };
  push(raw);
  push(compactProductName(raw));
  push(normaliseProductNameLoose(raw));
  return out;
}
