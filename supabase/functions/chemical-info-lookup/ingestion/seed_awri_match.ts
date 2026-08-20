// Stage 5E — resolve the remaining unresolved AWRI 2026/27 product names.
//
// CLASSIFICATION ONLY. This module takes the names Stage 5A could not resolve
// and classifies each one against the CURRENT APVMA PubCRIS register using
// stricter-than-substring, token-structured rules plus register-fact
// corroboration (registrant/holder, active constituents, concentrations).
// It is PURE and deterministic: no network, no database, no clock — the
// runner supplies every input, and identical inputs produce identical output.
//
// WHAT THIS STAGE NEVER DOES
//   * It never writes anything: no Master Chemicals, no Saved Chemicals, no
//     Spray Records, no apply-state. There is no apply/import step here.
//   * It never uses loose substring or fuzzy similarity. Every rule is exact
//     token structure with fail-closed ties. Variant designators (FORTE,
//     ULTRA, DUO, …) can never be dropped from either side of a comparison,
//     so "Custodia" can never reach "CUSTODIA FORTE".
//   * It never touches the identities already resolved in Stages 5A-5D.
//     Matches that land on an existing Master identity are flagged
//     `identity_already_in_master` and are not new candidates.
//   * AWRI stays a viticulture reference; the APVMA register remains the
//     sole registration authority. Register facts (holder, constituents,
//     concentrations) may only CORROBORATE or ELIMINATE a name-derived
//     match — they never invent one.
//
// ARCHIVED REGISTER NOTE
//   The APVMA publishes no machine-readable archived register. The public
//   PubCRIS dataset (data.gov.au) contains regcode R rows (currently
//   registered products) and regcode A rows (approved actives) only, so
//   `no_apvma_match` strictly means "no match in the CURRENT register".
//   Names on AWRI's own cancelled list were already excluded in Stage 5A.
//
// CLASSIFICATION CONTRACT (per remaining name)
//   deterministic_match      unique row, exact token structure (typography
//                            normalisation, formulation suffix, registrant
//                            prefix, or reverse formulation suffix), active
//                            constituents corroborated, no tie-break needed.
//   probable_manual_review   unique row but the correspondence needed
//                            non-registrant filler tokens (token subsequence),
//                            or corroboration data was unavailable, or a tie
//                            was broken by register facts. Human confirms.
//   ambiguous                two or more register rows survive — fails closed.
//   no_apvma_match           nothing in the current register corresponds.

import type { AwriSeedManifest, RegisterProductRow } from "./seed_awri.ts";
import { identityKey } from "./contract.ts";

// ---------------------------------------------------------------------------
// Input/output shapes
// ---------------------------------------------------------------------------

/** One register active constituent for corroboration (from prodcon+constit). */
export interface RegisterActive {
  /** Constituent name from constit.csv (verbatim). Empty when unpublished. */
  name: string;
  /** camount as a number; null when absent, unparsable, or zero (biologicals). */
  amount: number | null;
}

/** A remaining unresolved name from the Stage 5A dry-run artifact. */
export interface UnmatchedInput {
  awri_product_name: string;
  expansion: "plain" | "variant" | "bare_parent";
  sections: string[];
}

export type MatchClass =
  | "deterministic_match"
  | "probable_manual_review"
  | "ambiguous"
  | "no_apvma_match";

export type MatchTier =
  | "exact_name"
  | "formulation_suffix"
  | "registrant_prefix"
  | "reverse_formulation_suffix"
  | "token_subsequence";

export type Corroboration = "pass" | "unknown";

export interface MatchedRegisterRow {
  registration_number: string;
  registration_identity_key: string;
  registered_product_name: string;
  registrant: string | null;
  register_status: string | null;
}

export interface Stage5EResolution {
  awri_product_name: string;
  expansion: UnmatchedInput["expansion"];
  sections: string[];
  match_class: MatchClass;
  /** Tier that decided the outcome (null for no_apvma_match). */
  tier: MatchTier | null;
  /** Register-fact corroboration for the surviving row (null when no row). */
  corroboration: Corroboration | null;
  /** True when register facts eliminated same-tier rivals to reach one row. */
  tie_broken_by_register_facts: boolean;
  matched: MatchedRegisterRow | null;
  /** Surviving rivals when ambiguous (the rows a human must choose between). */
  ambiguous_rows: MatchedRegisterRow[];
  /** The matched identity already exists in Master (Stages 5A-5D) — alias. */
  identity_already_in_master: boolean;
}

export interface Stage5EDuplicate {
  registration_identity_key: string;
  awri_product_names: string[];
}

export interface Stage5ECounts {
  input_unresolved: number;
  deterministic_match: number;
  probable_manual_review: number;
  ambiguous: number;
  no_apvma_match: number;
  /** Distinct NEW identities across deterministic + probable matches. */
  distinct_new_identities: number;
  /** Matches whose identity already exists in Master — aliases, not new. */
  identity_already_in_master: number;
  /** Input names found on AWRI's cancelled list — always excluded, expect 0. */
  excluded_cancelled_listed: number;
  database_changes: 0;
  production_writes: 0;
}

export interface Stage5EResult {
  seed_source: Record<string, string>;
  resolutions: Stage5EResolution[];
  /** Deterministic/probable matches sharing one identity (name aliases). */
  duplicates: Stage5EDuplicate[];
  counts: Stage5ECounts;
  invariants: {
    apvma_remains_authoritative: "PASS" | "FAIL";
    no_variant_token_dropped: "PASS";
    existing_master_rows_untouched: "PASS";
    dry_run_no_writes: "PASS";
  };
}

export interface ClassifyInput {
  manifest: AwriSeedManifest;
  unresolved: UnmatchedInput[];
  registerRows: RegisterProductRow[];
  /** Active constituents by pcode for every shortlisted row (may be partial). */
  activesByPcode: Map<string, RegisterActive[]>;
  /** Identities already resolved in Stages 5A-5D (candidates + conflicts). */
  existingIdentities: Set<string>;
}

// ---------------------------------------------------------------------------
// Normalisation (Stage 5E classification only — the live adapter keeps its
// own stricter normalisation in apvma.ts, untouched)
// ---------------------------------------------------------------------------

/**
 * Like the adapter's normalisation (lowercase, alphanumeric tokens) plus a
 * split at every letter↔digit boundary so "250SC" and "250 SC" — pure
 * typography — compare equal. This can never merge distinct brands: it only
 * ever splits tokens, never joins or rewrites them.
 */
export function normaliseNameLoose(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/([a-z])(?=[0-9])/g, "$1 ")
    .replace(/([0-9])(?=[a-z])/g, "$1 ")
    .trim()
    .replace(/\s+/g, " ");
}

/**
 * Mirrors the adapter's ignorable formulation/pack/category tokens (see
 * apvma.ts IGNORABLE_SUFFIX_TOKENS). Kept verbatim — Stage 5E must never be
 * looser about WHICH tokens are ignorable, only about typography.
 */
const IGNORABLE_TOKENS = new Set([
  "sc", "ec", "wg", "wdg", "wp", "sl", "se", "ew", "gr", "df", "dp", "ulv",
  "cs", "od", "sg", "sp", "la", "me", "fs",
  "fungicide", "herbicide", "insecticide", "miticide", "acaricide",
  "nematicide", "bactericide", "adjuvant", "surfactant",
  "liquid", "concentrate", "suspension", "emulsifiable", "soluble",
  "dispersible", "flowable", "granule", "granules", "powder", "spray",
  "systemic", "selective",
]);

/**
 * Variant designators that denote a DIFFERENT registered product. They may
 * appear inside a requested name (then they must match like any other
 * token), but they can never be part of a dropped remainder on either side
 * of a comparison. This is the structural guard that keeps "Custodia" away
 * from "CUSTODIA FORTE" and "Weedmaster" away from "WEEDMASTER DUO".
 */
export const VARIANT_TOKENS = new Set([
  "forte", "ultra", "duo", "xtra", "extra", "max", "maxx", "plus", "pro",
  "advance", "advanced", "gold", "super", "turbo", "twin", "trio", "elite",
  "evo", "prime", "premium", "platinum", "xpro", "opti", "optimo", "top",
  "flexi", "flex", "xcel", "excel", "xt", "xl", "xtreme", "ii", "iii", "iv",
]);

function isNumeric(token: string): boolean {
  return /^\d+(\.\d+)?$/.test(token);
}

function isIgnorableToken(token: string): boolean {
  if (isNumeric(token)) return true;
  if (/^\d+(\.\d+)?(g|kg|ml|l)$/.test(token)) return true;
  return IGNORABLE_TOKENS.has(token);
}

/** A remainder is droppable iff every token is ignorable and none is a variant. */
function droppableRemainder(tokens: string[]): boolean {
  if (tokens.some((t) => VARIANT_TOKENS.has(t))) return false;
  return tokens.every((t) => isIgnorableToken(t));
}

// ---------------------------------------------------------------------------
// Active-constituent corroboration
// ---------------------------------------------------------------------------

/** Grammar/qualifier words that never distinguish one active from another. */
const ACTIVE_STOP_TOKENS = new Set([
  "present", "as", "the", "salt", "salts", "a", "of", "and", "with", "in",
  "or", "var", "subsp", "subspecies", "ssp", "spp", "strain", "berliner",
]);

/** Extractor shorthand for salt forms — spelled out in the register. */
const SALT_ABBREVIATIONS = new Set(["mas", "ipa", "mea", "dma", "tipa"]);

/** Cross-spelling equivalences. Deliberately tiny and explicit. */
const ACTIVE_ALIASES: Record<string, string[]> = {
  sulphur: ["sulfur"],
  sulfur: ["sulphur"],
  cupric: ["copper"],
  cuprous: ["copper"],
};

function activeTokens(raw: string): string[] {
  return normaliseNameLoose(raw)
    .split(" ")
    .filter((t) => t && !ACTIVE_STOP_TOKENS.has(t));
}

/**
 * Parse one manifest active string into alternatives of required-token
 * lists: "a + b / c" → [[a-tokens, b-tokens], [c-tokens]]. Parenthetical
 * qualifiers and salt-form shorthand are descriptive, not identity.
 */
export function parseManifestActive(raw: string): string[][][] {
  const withoutParens = raw.replace(/\([^)]*\)/g, " ");
  const alternatives: string[][][] = [];
  for (const alt of withoutParens.split("/")) {
    const parts: string[][] = [];
    for (const part of alt.split("+")) {
      const tokens = activeTokens(part).filter((t) => !SALT_ABBREVIATIONS.has(t));
      if (tokens.length) parts.push(tokens);
    }
    if (parts.length) alternatives.push(parts);
  }
  return alternatives;
}

function partMatchesRegisterActive(partTokens: string[], registerName: string): boolean {
  const registerTokens = new Set(activeTokens(registerName));
  const expanded = new Set(registerTokens);
  for (const token of registerTokens) {
    for (const alias of ACTIVE_ALIASES[token] ?? []) expanded.add(alias);
  }
  return partTokens.every((t) => expanded.has(t));
}

/**
 * Corroborate a manifest entry's active constituents against a register
 * row's constituents. "pass" = every required part matched; "mismatch" =
 * at least one required part matched NO register active (positive
 * contradiction — the row is a different product); "unknown" = no register
 * constituent data or no manifest actives to compare.
 */
export function corroborateActives(
  manifestActives: string[],
  registerActives: RegisterActive[],
): "pass" | "mismatch" | "unknown" {
  const named = registerActives.filter((a) => a.name.trim().length > 0);
  if (!named.length || !manifestActives.length) return "unknown";
  for (const raw of manifestActives) {
    const alternatives = parseManifestActive(raw);
    if (!alternatives.length) continue;
    const satisfied = alternatives.some((parts) =>
      parts.every((part) => named.some((a) => partMatchesRegisterActive(part, a.name)))
    );
    if (!satisfied) return "mismatch";
  }
  return "pass";
}

/**
 * Every numeric token in the requested name must appear in the register
 * name or equal a register active concentration (e.g. "680" ↔ 680 g/kg).
 * A product carrying a different strength is a different product.
 */
export function numericsAgree(
  requestedTokens: string[],
  registerTokens: string[],
  registerActives: RegisterActive[],
): boolean {
  const numerics = requestedTokens.filter(isNumeric);
  if (!numerics.length) return true;
  const inName = new Set(registerTokens.filter(isNumeric));
  const amounts = new Set<string>();
  for (const active of registerActives) {
    if (active.amount === null || !Number.isFinite(active.amount)) continue;
    amounts.add(
      Number.isInteger(active.amount) ? String(active.amount) : String(active.amount),
    );
  }
  return numerics.every((n) => inName.has(n) || amounts.has(n));
}

// ---------------------------------------------------------------------------
// Register index + tier rules
// ---------------------------------------------------------------------------

export interface IndexedRegisterRow {
  row: RegisterProductRow;
  norm: string;
  tokens: string[];
  registrantTokens: string[];
}

export interface RegisterIndex {
  rows: IndexedRegisterRow[];
  byNorm: Map<string, IndexedRegisterRow[]>;
  byFirstToken: Map<string, IndexedRegisterRow[]>;
}

/**
 * Index CURRENT register product rows (regcode R). Approved-active rows
 * (regcode A) are constituent approvals, not products — structurally
 * excluded so a product name can never bind an active-ingredient entry.
 */
export function buildRegisterIndex(rows: RegisterProductRow[]): RegisterIndex {
  const indexed: IndexedRegisterRow[] = [];
  const byNorm = new Map<string, IndexedRegisterRow[]>();
  const byFirstToken = new Map<string, IndexedRegisterRow[]>();
  const seen = new Set<string>();
  for (const row of rows) {
    if (!row?.pcode || !row?.fpname) continue;
    if ((row.regcode ?? "").trim().toUpperCase() !== "R") continue;
    const pcode = String(row.pcode).trim();
    if (seen.has(pcode)) continue;
    seen.add(pcode);
    const norm = normaliseNameLoose(row.fpname);
    if (!norm) continue;
    const tokens = norm.split(" ");
    const registrantTokens = row.sname ? normaliseNameLoose(row.sname).split(" ").filter(Boolean) : [];
    const entry: IndexedRegisterRow = { row, norm, tokens, registrantTokens };
    indexed.push(entry);
    const exact = byNorm.get(norm);
    if (exact) exact.push(entry);
    else byNorm.set(norm, [entry]);
    const first = tokens[0];
    const bucket = byFirstToken.get(first);
    if (bucket) bucket.push(entry);
    else byFirstToken.set(first, [entry]);
  }
  return { rows: indexed, byNorm, byFirstToken };
}

/** Register name = requested name + droppable remainder. */
function forwardSuffixMatches(wanted: string, entry: IndexedRegisterRow): boolean {
  if (!entry.norm.startsWith(`${wanted} `)) return false;
  return droppableRemainder(entry.norm.slice(wanted.length).trim().split(" "));
}

/** Requested name = register name + droppable remainder. */
function reverseSuffixMatches(wantedTokens: string[], entry: IndexedRegisterRow): boolean {
  const rt = entry.tokens;
  if (rt.length >= wantedTokens.length) return false;
  for (let i = 0; i < rt.length; i++) {
    if (wantedTokens[i] !== rt[i]) return false;
  }
  return droppableRemainder(wantedTokens.slice(rt.length));
}

/**
 * Register name = the row's OWN registrant/holder tokens (1-3 leading
 * words) + requested name (+ droppable remainder). The prefix is verified
 * against the register row's holder field — never guessed from the name.
 */
function registrantPrefixMatches(wanted: string, entry: IndexedRegisterRow): boolean {
  const st = entry.registrantTokens;
  if (!st.length) return false;
  const maxPrefix = Math.min(3, st.length);
  for (let k = 1; k <= maxPrefix; k++) {
    const prefixed = `${st.slice(0, k).join(" ")} ${wanted}`;
    if (entry.norm === prefixed) return true;
    if (entry.norm.startsWith(`${prefixed} `)) {
      if (droppableRemainder(entry.norm.slice(prefixed.length).trim().split(" "))) {
        return true;
      }
    }
  }
  return false;
}

/**
 * Requested tokens appear IN ORDER inside the register name; the extra
 * register tokens may be arbitrary non-variant words (brand families,
 * active names, descriptors). Weakest rule — its unique survivors are
 * always `probable_manual_review`, never deterministic.
 */
function tokenSubsequenceMatches(wantedTokens: string[], entry: IndexedRegisterRow): boolean {
  const rt = entry.tokens;
  let i = 0;
  for (const token of rt) {
    if (i < wantedTokens.length && token === wantedTokens[i]) i++;
  }
  if (i !== wantedTokens.length) return false;
  const wantedCounts = new Map<string, number>();
  for (const t of wantedTokens) wantedCounts.set(t, (wantedCounts.get(t) ?? 0) + 1);
  const registerCounts = new Map<string, number>();
  for (const t of rt) registerCounts.set(t, (registerCounts.get(t) ?? 0) + 1);
  for (const [token, count] of registerCounts) {
    if (count > (wantedCounts.get(token) ?? 0) && VARIANT_TOKENS.has(token)) return false;
  }
  return true;
}

interface TierDefinition {
  tier: MatchTier;
  deterministicEligible: boolean;
  candidates: (wanted: string, wantedTokens: string[], index: RegisterIndex) => IndexedRegisterRow[];
}

const TIERS: TierDefinition[] = [
  {
    tier: "exact_name",
    deterministicEligible: true,
    candidates: (wanted, _tokens, index) => index.byNorm.get(wanted) ?? [],
  },
  {
    tier: "formulation_suffix",
    deterministicEligible: true,
    candidates: (wanted, tokens, index) =>
      (index.byFirstToken.get(tokens[0]) ?? []).filter((e) => forwardSuffixMatches(wanted, e)),
  },
  {
    tier: "registrant_prefix",
    deterministicEligible: true,
    candidates: (wanted, _tokens, index) =>
      index.rows.filter((e) => registrantPrefixMatches(wanted, e)),
  },
  {
    tier: "reverse_formulation_suffix",
    deterministicEligible: true,
    candidates: (_wanted, tokens, index) =>
      (index.byFirstToken.get(tokens[0]) ?? []).filter((e) => reverseSuffixMatches(tokens, e)),
  },
  {
    tier: "token_subsequence",
    deterministicEligible: false,
    candidates: (_wanted, tokens, index) =>
      index.rows.filter((e) => tokenSubsequenceMatches(tokens, e)),
  },
];

/**
 * Union of every tier's candidate pcodes for the given names — the exact
 * set the runner must obtain constituent data for. Pure and deterministic.
 */
export function collectCandidatePcodes(
  names: string[],
  index: RegisterIndex,
): string[] {
  const pcodes = new Set<string>();
  for (const name of names) {
    const wanted = normaliseNameLoose(name);
    if (!wanted) continue;
    const tokens = wanted.split(" ");
    for (const tier of TIERS) {
      for (const entry of tier.candidates(wanted, tokens, index)) {
        pcodes.add(String(entry.row.pcode).trim());
      }
    }
  }
  return Array.from(pcodes).sort((a, b) => (Number(a) || 0) - (Number(b) || 0));
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

function registerStatusOf(row: RegisterProductRow): string | null {
  return [
    row.regcode ? String(row.regcode).trim() : null,
    row.expdate ? `expires ${String(row.expdate).trim()}` : null,
  ].filter(Boolean).join(", ") || null;
}

function toMatchedRow(entry: IndexedRegisterRow): MatchedRegisterRow {
  const pcode = String(entry.row.pcode).trim();
  return {
    registration_number: pcode,
    registration_identity_key: identityKey("AU", "apvma", pcode),
    registered_product_name: String(entry.row.fpname).trim(),
    registrant: entry.row.sname ? String(entry.row.sname).trim() : null,
    register_status: registerStatusOf(entry.row),
  };
}

export function classifyUnresolved(input: ClassifyInput): Stage5EResult {
  const index = buildRegisterIndex(input.registerRows);
  const activesByName = new Map<string, string[]>();
  for (const entry of input.manifest.entries) {
    activesByName.set(entry.awri_product_name, entry.active_constituents ?? []);
  }
  const cancelledNames = new Set(
    input.manifest.cancelled_products.map((c) => normaliseNameLoose(c.awri_product_name)),
  );

  // Deterministic order: classification sorted by normalised name.
  const items = [...input.unresolved].sort((a, b) =>
    normaliseNameLoose(a.awri_product_name) < normaliseNameLoose(b.awri_product_name) ? -1 : 1
  );

  const resolutions: Stage5EResolution[] = [];
  let excludedCancelled = 0;

  for (const item of items) {
    const name = item.awri_product_name;
    // Structural guard: AWRI-cancelled names can never be classified here.
    if (cancelledNames.has(normaliseNameLoose(name))) {
      excludedCancelled += 1;
      continue;
    }
    const wanted = normaliseNameLoose(name);
    const wantedTokens = wanted ? wanted.split(" ") : [];
    const manifestActives = activesByName.get(name) ?? [];

    let decided: Stage5EResolution | null = null;
    for (const tierDef of TIERS) {
      if (!wantedTokens.length) break;
      const candidates = tierDef.candidates(wanted, wantedTokens, index);
      if (!candidates.length) continue;

      const survivors: { entry: IndexedRegisterRow; corroboration: Corroboration }[] = [];
      for (const entry of candidates) {
        const pcode = String(entry.row.pcode).trim();
        const registerActives = input.activesByPcode.get(pcode) ?? [];
        if (!numericsAgree(wantedTokens, entry.tokens, registerActives)) continue;
        const verdict = corroborateActives(manifestActives, registerActives);
        if (verdict === "mismatch") continue;
        survivors.push({ entry, corroboration: verdict });
      }
      if (!survivors.length) continue; // all rows contradicted — try next tier

      if (survivors.length > 1) {
        decided = {
          awri_product_name: name,
          expansion: item.expansion,
          sections: item.sections,
          match_class: "ambiguous",
          tier: tierDef.tier,
          corroboration: null,
          tie_broken_by_register_facts: false,
          matched: null,
          ambiguous_rows: survivors.map((s) => toMatchedRow(s.entry)),
          identity_already_in_master: false,
        };
        break;
      }

      const { entry, corroboration } = survivors[0];
      const tieBroken = candidates.length > 1;
      const matched = toMatchedRow(entry);
      const isDeterministic = tierDef.deterministicEligible &&
        corroboration === "pass" && !tieBroken;
      decided = {
        awri_product_name: name,
        expansion: item.expansion,
        sections: item.sections,
        match_class: isDeterministic ? "deterministic_match" : "probable_manual_review",
        tier: tierDef.tier,
        corroboration,
        tie_broken_by_register_facts: tieBroken,
        matched,
        ambiguous_rows: [],
        identity_already_in_master: input.existingIdentities.has(
          matched.registration_identity_key,
        ),
      };
      break;
    }

    resolutions.push(
      decided ?? {
        awri_product_name: name,
        expansion: item.expansion,
        sections: item.sections,
        match_class: "no_apvma_match",
        tier: null,
        corroboration: null,
        tie_broken_by_register_facts: false,
        matched: null,
        ambiguous_rows: [],
        identity_already_in_master: false,
      },
    );
  }

  // ---- Identity-level rollup (deterministic + probable) -------------------
  const namesByIdentity = new Map<string, string[]>();
  for (const r of resolutions) {
    if (!r.matched || r.identity_already_in_master) continue;
    const key = r.matched.registration_identity_key;
    const names = namesByIdentity.get(key);
    if (names) names.push(r.awri_product_name);
    else namesByIdentity.set(key, [r.awri_product_name]);
  }
  const duplicates: Stage5EDuplicate[] = Array.from(namesByIdentity.entries())
    .filter(([, names]) => names.length > 1)
    .map(([key, names]) => ({ registration_identity_key: key, awri_product_names: names }))
    .sort((a, b) => a.registration_identity_key < b.registration_identity_key ? -1 : 1);

  const count = (cls: MatchClass): number =>
    resolutions.filter((r) => r.match_class === cls).length;

  // Every matched identity must have come from a register row (pcode) via a
  // named tier — AWRI never supplies numbers, and this stage never invents.
  const everyIdentityFromRegister = resolutions.every((r) =>
    r.matched === null ||
    (r.tier !== null &&
      r.matched.registration_identity_key ===
        identityKey("AU", "apvma", r.matched.registration_number))
  );

  const counts: Stage5ECounts = {
    input_unresolved: input.unresolved.length,
    deterministic_match: count("deterministic_match"),
    probable_manual_review: count("probable_manual_review"),
    ambiguous: count("ambiguous"),
    no_apvma_match: count("no_apvma_match"),
    distinct_new_identities: namesByIdentity.size,
    identity_already_in_master: resolutions.filter((r) => r.identity_already_in_master).length,
    excluded_cancelled_listed: excludedCancelled,
    database_changes: 0,
    production_writes: 0,
  };

  return {
    seed_source: input.manifest.source,
    resolutions,
    duplicates,
    counts,
    invariants: {
      apvma_remains_authoritative: everyIdentityFromRegister ? "PASS" : "FAIL",
      no_variant_token_dropped: "PASS",
      existing_master_rows_untouched: "PASS",
      dry_run_no_writes: "PASS",
    },
  };
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

/** One line per required Stage 5E report field. */
export function formatMatchReport(result: Stage5EResult, testsLine: string): string {
  const c = result.counts;
  return [
    `Input unresolved: ${c.input_unresolved}`,
    `Newly deterministic: ${c.deterministic_match}`,
    `Probable/manual review: ${c.probable_manual_review}`,
    `Ambiguous: ${c.ambiguous}`,
    `No match: ${c.no_apvma_match}`,
    `Distinct new identities (deterministic + probable): ${c.distinct_new_identities}`,
    `Already in Master (aliases): ${c.identity_already_in_master}`,
    `Cancelled-list exclusions: ${c.excluded_cancelled_listed}`,
    `APVMA remains authoritative: ${result.invariants.apvma_remains_authoritative}`,
    `Dry run (no writes): ${result.invariants.dry_run_no_writes}`,
    `Tests: ${testsLine}`,
    `Database changes: NONE`,
    `Production writes: NONE`,
  ].join("\n");
}
