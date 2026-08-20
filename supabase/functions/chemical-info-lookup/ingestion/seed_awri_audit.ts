// Stage 5F — audit of the Stage 5E deterministic matches. REVIEW ONLY.
//
// This module takes ONLY the `deterministic_match` resolutions from the
// Stage 5E match artifact and re-audits every one of them from first
// principles. It trusts nothing from the artifact that it can re-derive:
//
//   * The tier structure is re-verified from the raw strings (holder prefix,
//     requested tokens, droppable remainder with no variant tokens).
//   * Active-constituent + strength corroboration is RECOMPUTED against a
//     fresh (live) register fetch, with per-active evidence recorded.
//   * Variant tokens (FORTE, ULTRA, DUO, …) are compared as multisets on
//     both sides — any asymmetry rejects the match.
//   * Registration status is classified against the extract date: rows
//     missing from the live register or carrying a pre-extract expiry are
//     archived/lapsed and REJECTED.
//   * Identities colliding with the existing Master Chemicals are REJECTED
//     (they are aliases, not new candidates).
//   * Two AWRI names resolving to one registration keep only the strongest;
//     the other is rejected as a duplicate alias.
//
// WHAT THIS STAGE NEVER DOES
//   * No database writes, no apply/import step, no Supabase client.
//   * It never touches the 162 probable_manual_review items.
//   * Register facts may only confirm or ELIMINATE — never invent a match.
//
// EXPIRY-DATE SEMANTICS (established against the live dataset)
//   The public PubCRIS extract is dated 2026-06-25 — BEFORE the annual
//   30 June renewal rollover — so 12,279 of 12,980 registered rows carry
//   "expires 30/06/2026". A past-looking expiry is therefore NOT evidence
//   of lapse. The correct lapse test is: expiry date < extract date.
//   Post-30-June renewal outcomes are not visible in any machine-readable
//   APVMA source; the interactive PubCRIS portal remains the live truth.

import {
  corroborateActives,
  droppableRemainder,
  isNumeric,
  normaliseNameLoose,
  numericsAgree,
  parseManifestActive,
  partMatchesRegisterActive,
  VARIANT_TOKENS,
  type MatchTier,
  type RegisterActive,
  type Stage5EResolution,
} from "./seed_awri_match.ts";
import { identityKey } from "./contract.ts";
import type { RegisterProductRow } from "./seed_awri.ts";

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

export type AuditDecision = "approve_for_seed" | "reject";

export type RegistrationClassification =
  | "current_in_extract"
  | "lapsed_before_extract"
  | "removed_from_current_register";

export interface AuditChecks {
  /** Input item really is a Stage 5E deterministic match (tier, corroboration, no tie-break). */
  artifact_integrity: boolean;
  /** The claimed tier reproduces from raw strings (prefix + tokens + droppable remainder). */
  tier_structure_reproduced: boolean;
  /** The registration is present in the live register fetch with regcode R. */
  live_row_present: boolean;
  /** Live product name and holder equal the artifact values (no drift). */
  live_row_consistent: boolean;
  /** Expiry date is not before the extract date (see expiry-date semantics above). */
  registration_current: boolean;
  /** Variant tokens on the AWRI side and the register side are the same multiset. */
  variant_tokens_equal: boolean;
  /** Recomputed active-constituent corroboration passes against live data. */
  actives_corroborated: boolean;
  /** Every numeric token in the AWRI name is verified by register name or camount. */
  numerics_verified: boolean;
  /** The identity does not collide with the existing Master Chemicals. */
  no_master_collision: boolean;
  /** Not a weaker duplicate of another audited name on the same registration. */
  not_duplicate_alias: boolean;
}

export interface ActiveCorroborationEvidence {
  manifest_active: string;
  register_constituents: { name: string; camount: number | null }[];
}

export interface NumericEvidence {
  token: string;
  evidence: string;
}

export interface AuditItem {
  awri_product_name: string;
  apvma_registration_number: string;
  apvma_registered_product_name: string;
  registrant: string | null;
  registration_identity_key: string;
  matching_tier: MatchTier | null;
  /** Holder words consumed as prefix (registrant_prefix tier only; 0 otherwise). */
  registrant_prefix_words: number;
  active_strength_corroboration: {
    verdict: "pass" | "mismatch" | "unknown";
    manifest_actives: string[];
    matched_constituents: ActiveCorroborationEvidence[];
    /** How each numeric token in the AWRI name was verified. */
    awri_numeric_evidence: NumericEvidence[];
    /** Register-name numerics the AWRI name does not carry (strength stated only register-side). */
    register_extra_numerics: NumericEvidence[];
  };
  variant_token_check: {
    awri_variant_tokens: string[];
    register_variant_tokens: string[];
    verdict: "pass" | "mismatch";
  };
  registration_status: {
    regcode: string | null;
    expdate: string | null;
    classification: RegistrationClassification;
    extract_date: string;
  };
  strength_score: number;
  strength_breakdown: Record<string, number>;
  checks: AuditChecks;
  decision: AuditDecision;
  reject_reasons: string[];
  notes: string[];
}

export interface AuditInput {
  /** ONLY the deterministic_match resolutions from the Stage 5E artifact. */
  deterministic: Stage5EResolution[];
  /** Manifest active-constituent strings per AWRI product name. */
  manifestActivesByName: Map<string, string[]>;
  /** Live register product rows keyed by pcode (fresh fetch). */
  liveRowsByPcode: Map<string, RegisterProductRow>;
  /** Live active constituents keyed by pcode (fresh fetch). */
  liveActivesByPcode: Map<string, RegisterActive[]>;
  /** Identities already in Master Chemicals (Stage 5A candidates ∪ conflicts). */
  existingIdentities: Set<string>;
  /** ISO date (yyyy-mm-dd) of the register extract — the lapse threshold. */
  extractDate: string;
}

export interface AuditCounts {
  total_audited: number;
  approve_for_seed: number;
  rejected: number;
  archived_or_lapsed: number;
  master_collisions: number;
  /** Registrations claimed by more than one audited AWRI name. */
  duplicate_identities: number;
  distinct_identities_approved: number;
  database_changes: 0;
  production_writes: 0;
}

export interface RankedMatch {
  awri_product_name: string;
  registration_number: string;
  registered_product_name: string;
  tier: MatchTier | null;
  strength_score: number;
  decision: AuditDecision;
}

export interface AuditResult {
  items: AuditItem[];
  counts: AuditCounts;
  strongest: RankedMatch[];
  weakest: RankedMatch[];
  invariants: {
    decisions_only_approve_or_reject: "PASS";
    deterministic_input_only: "PASS" | "FAIL";
    probable_batch_untouched: "PASS";
    no_database_writes: "PASS";
    apvma_remains_authoritative: "PASS" | "FAIL";
  };
}

// ---------------------------------------------------------------------------
// Small pure helpers (exported for tests and the runner)
// ---------------------------------------------------------------------------

/** "30/06/2026 0:00" → "2026-06-30"; null/unparsable → null. */
export function parseExpdateIso(raw: string | null): string | null {
  if (!raw) return null;
  const m = String(raw).trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (!m) return null;
  return `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
}

/** Sorted variant tokens present in a name (multiset as a sorted array). */
export function variantTokensOf(name: string): string[] {
  return normaliseNameLoose(name)
    .split(" ")
    .filter((t) => VARIANT_TOKENS.has(t))
    .sort();
}

/** True when the raw string glues letters to digits ("250SC") — pure typography. */
export function hasTypographySplit(raw: string): boolean {
  return /[a-zA-Z][0-9]|[0-9][a-zA-Z]/.test(raw);
}

function startsWithTokens(haystack: string[], prefix: string[]): boolean {
  if (prefix.length > haystack.length) return false;
  for (let i = 0; i < prefix.length; i++) {
    if (haystack[i] !== prefix[i]) return false;
  }
  return true;
}

export interface TierStructure {
  reproduced: boolean;
  prefixWords: number;
  leftoverRegisterTokens: string[];
  leftoverAwriTokens: string[];
}

/**
 * Re-derive the claimed tier from raw token structure. This is the audit's
 * independent proof that the match is exactly what Stage 5E said it was:
 * holder prefix verified against the row's own holder, requested tokens
 * contiguous, and a remainder that is droppable (ignorable, no variants).
 */
export function reverifyTierStructure(
  tier: MatchTier,
  awriTokens: string[],
  registerTokens: string[],
  holderTokens: string[],
): TierStructure {
  const fail: TierStructure = {
    reproduced: false,
    prefixWords: 0,
    leftoverRegisterTokens: [],
    leftoverAwriTokens: [],
  };
  if (!awriTokens.length || !registerTokens.length) return fail;

  if (tier === "exact_name") {
    if (awriTokens.join(" ") === registerTokens.join(" ")) {
      return { ...fail, reproduced: true };
    }
    return fail;
  }
  if (tier === "formulation_suffix") {
    if (
      registerTokens.length > awriTokens.length &&
      startsWithTokens(registerTokens, awriTokens)
    ) {
      const leftover = registerTokens.slice(awriTokens.length);
      if (droppableRemainder(leftover)) {
        return { ...fail, reproduced: true, leftoverRegisterTokens: leftover };
      }
    }
    return fail;
  }
  if (tier === "registrant_prefix") {
    const maxPrefix = Math.min(3, holderTokens.length);
    for (let k = 1; k <= maxPrefix; k++) {
      const candidate = [...holderTokens.slice(0, k), ...awriTokens];
      if (!startsWithTokens(registerTokens, candidate)) continue;
      const leftover = registerTokens.slice(candidate.length);
      if (leftover.length === 0 || droppableRemainder(leftover)) {
        return {
          reproduced: true,
          prefixWords: k,
          leftoverRegisterTokens: leftover,
          leftoverAwriTokens: [],
        };
      }
    }
    return fail;
  }
  if (tier === "reverse_formulation_suffix") {
    if (
      awriTokens.length > registerTokens.length &&
      startsWithTokens(awriTokens, registerTokens)
    ) {
      const leftover = awriTokens.slice(registerTokens.length);
      if (droppableRemainder(leftover)) {
        return { ...fail, reproduced: true, leftoverAwriTokens: leftover };
      }
    }
    return fail;
  }
  // token_subsequence is never deterministic — nothing to reproduce here.
  return fail;
}

/**
 * Per-manifest-active evidence: which register constituents satisfied it.
 * Mirrors corroborateActives' alternative/part semantics, but records names.
 */
export function explainActives(
  manifestActives: string[],
  registerActives: RegisterActive[],
): ActiveCorroborationEvidence[] {
  const named = registerActives.filter((a) => a.name.trim().length > 0);
  const out: ActiveCorroborationEvidence[] = [];
  for (const raw of manifestActives) {
    const alternatives = parseManifestActive(raw);
    const constituents = new Map<string, number | null>();
    for (const parts of alternatives) {
      const satisfied = parts.every((part) =>
        named.some((a) => partMatchesRegisterActive(part, a.name))
      );
      if (!satisfied) continue;
      for (const part of parts) {
        for (const a of named) {
          if (partMatchesRegisterActive(part, a.name)) {
            constituents.set(a.name, a.amount);
          }
        }
      }
      break; // first satisfied alternative is the evidence
    }
    out.push({
      manifest_active: raw,
      register_constituents: Array.from(constituents.entries())
        .map(([name, camount]) => ({ name, camount }))
        .sort((a, b) => (a.name < b.name ? -1 : 1)),
    });
  }
  return out;
}

function camountStrings(actives: RegisterActive[]): Set<string> {
  const amounts = new Set<string>();
  for (const a of actives) {
    if (a.amount === null || !Number.isFinite(a.amount)) continue;
    amounts.add(String(a.amount));
  }
  return amounts;
}

// ---------------------------------------------------------------------------
// Reconciliation helper — AWRI names vs approved-active (regcode A) names
// ---------------------------------------------------------------------------

export interface ActiveNameHit {
  active_name: string;
  relation: "exact" | "contained_in_name";
}

/**
 * Cross-check product names against approved-active (regcode A) names.
 * Used to document, factually, what the actives file could and could not
 * say about the 38 no-match names: an A row is an active-constituent
 * approval, never a product registration — a hit only means the product
 * name CONTAINS an active's name.
 */
export function crossCheckNamesAgainstActiveNames(
  names: string[],
  activeNames: string[],
): { awri_product_name: string; hits: ActiveNameHit[] }[] {
  const actives = activeNames
    .map((raw) => ({ raw, tokens: normaliseNameLoose(raw).split(" ").filter(Boolean) }))
    .filter((a) => a.tokens.length > 0);
  return names.map((name) => {
    const tokens = normaliseNameLoose(name).split(" ").filter(Boolean);
    const hits: ActiveNameHit[] = [];
    for (const active of actives) {
      if (active.tokens.join(" ") === tokens.join(" ")) {
        hits.push({ active_name: active.raw, relation: "exact" });
        continue;
      }
      if (active.tokens.length >= tokens.length) continue;
      for (let i = 0; i + active.tokens.length <= tokens.length; i++) {
        if (active.tokens.every((t, j) => tokens[i + j] === t)) {
          hits.push({ active_name: active.raw, relation: "contained_in_name" });
          break;
        }
      }
    }
    hits.sort((a, b) => (a.active_name < b.active_name ? -1 : 1));
    return { awri_product_name: name, hits };
  });
}

// ---------------------------------------------------------------------------
// Strength score — transparent, deterministic ranking for review
// ---------------------------------------------------------------------------

const TIER_BASE: Record<MatchTier, number> = {
  exact_name: 40,
  formulation_suffix: 34,
  registrant_prefix: 30,
  reverse_formulation_suffix: 28,
  token_subsequence: 0,
};

// ---------------------------------------------------------------------------
// The audit
// ---------------------------------------------------------------------------

export function auditDeterministicMatches(input: AuditInput): AuditResult {
  const items: AuditItem[] = [];
  let deterministicInputOnly = true;
  let identitiesRederive = true;

  const sorted = [...input.deterministic].sort((a, b) =>
    normaliseNameLoose(a.awri_product_name) < normaliseNameLoose(b.awri_product_name) ? -1 : 1
  );

  for (const res of sorted) {
    const reasons: string[] = [];
    const notes: string[] = [];

    const integrity = res.match_class === "deterministic_match" &&
      res.tier !== null && res.tier !== "token_subsequence" &&
      res.corroboration === "pass" &&
      !res.tie_broken_by_register_facts &&
      res.matched !== null;
    if (!integrity) {
      deterministicInputOnly = false;
      reasons.push("artifact_integrity: not a Stage 5E deterministic match");
    }

    const matched = res.matched;
    const regnum = matched ? matched.registration_number : "";
    const identity = matched ? matched.registration_identity_key : "";
    if (matched && identity !== identityKey("AU", "apvma", regnum)) {
      identitiesRederive = false;
      reasons.push("identity_key_not_rederivable_from_registration_number");
    }

    // ---- Live register row -------------------------------------------------
    const live = regnum ? input.liveRowsByPcode.get(regnum) : undefined;
    const liveRegcode = live ? (live.regcode ?? "").trim().toUpperCase() : null;
    const livePresent = Boolean(live && liveRegcode === "R");
    if (!live) {
      reasons.push("registration_removed_from_current_register");
    } else if (liveRegcode !== "R") {
      reasons.push(`live_regcode_not_R:${liveRegcode}`);
    }

    // ---- Registration status vs extract date ------------------------------
    const expdateRaw = live?.expdate ?? null;
    const expIso = parseExpdateIso(expdateRaw);
    let classification: RegistrationClassification;
    let registrationCurrent = false;
    if (!livePresent) {
      classification = "removed_from_current_register";
    } else if (expIso && expIso < input.extractDate) {
      classification = "lapsed_before_extract";
      reasons.push(`registration_lapsed_before_extract:${expIso}`);
    } else {
      classification = "current_in_extract";
      registrationCurrent = true;
      if (expdateRaw && !expIso) notes.push(`unparsable_expdate:${expdateRaw}`);
      if (!expdateRaw) notes.push("no_expiry_date_in_extract");
    }

    // ---- Live consistency (name + holder unchanged) ------------------------
    let liveConsistent = false;
    if (livePresent && matched) {
      const nameSame = (live?.fpname ?? "").trim() === matched.registered_product_name;
      const holderLive = live?.sname ? String(live.sname).trim() : null;
      const holderSame = holderLive === (matched.registrant ?? null);
      liveConsistent = nameSame && holderSame;
      if (!nameSame) reasons.push("live_register_drift:product_name");
      if (!holderSame) reasons.push("live_register_drift:registrant");
    }

    // ---- Structural tier re-verification -----------------------------------
    const registerName = (live?.fpname ?? matched?.registered_product_name ?? "").trim();
    const holderName = (live?.sname ?? matched?.registrant ?? "") ?? "";
    const awriNorm = normaliseNameLoose(res.awri_product_name);
    const awriTokens = awriNorm ? awriNorm.split(" ") : [];
    const registerNorm = normaliseNameLoose(registerName);
    const registerTokens = registerNorm ? registerNorm.split(" ") : [];
    const holderTokens = holderName
      ? normaliseNameLoose(String(holderName)).split(" ").filter(Boolean)
      : [];

    const structure = res.tier && res.tier !== "token_subsequence"
      ? reverifyTierStructure(res.tier, awriTokens, registerTokens, holderTokens)
      : {
        reproduced: false,
        prefixWords: 0,
        leftoverRegisterTokens: [],
        leftoverAwriTokens: [],
      };
    if (!structure.reproduced) {
      reasons.push("tier_structure_not_reproducible");
    }

    // ---- Variant-token check (both directions) ------------------------------
    const awriVariants = variantTokensOf(res.awri_product_name);
    const registerVariants = variantTokensOf(registerName);
    const variantsEqual = awriVariants.join("|") === registerVariants.join("|");
    if (!variantsEqual) reasons.push("variant_token_mismatch");

    // ---- Actives + strength corroboration (recomputed, live data) ----------
    const manifestActives = input.manifestActivesByName.get(res.awri_product_name) ?? [];
    const liveActives = regnum ? (input.liveActivesByPcode.get(regnum) ?? []) : [];
    const verdict = corroborateActives(manifestActives, liveActives);
    if (verdict === "mismatch") reasons.push("active_constituent_mismatch");
    if (verdict === "unknown") reasons.push("corroboration_unknown_on_live_data");
    const matchedConstituents = explainActives(manifestActives, liveActives);

    const numericsOk = numericsAgree(awriTokens, registerTokens, liveActives);
    if (!numericsOk) reasons.push("awri_numeric_unverified");
    const amounts = camountStrings(liveActives);
    const registerNumerics = new Set(registerTokens.filter(isNumeric));
    const awriNumericEvidence: NumericEvidence[] = awriTokens
      .filter(isNumeric)
      .map((token) => ({
        token,
        evidence: amounts.has(token)
          ? `camount:${token}`
          : registerNumerics.has(token)
          ? "register_name"
          : "unverified",
      }));
    const awriNumericSet = new Set(awriTokens.filter(isNumeric));
    const registerExtraNumerics: NumericEvidence[] = structure.leftoverRegisterTokens
      .filter(isNumeric)
      .filter((t) => !awriNumericSet.has(t))
      .map((token) => ({
        token,
        evidence: amounts.has(token) ? "camount_verified" : "not_in_awri_name_or_camount",
      }));
    if (registerExtraNumerics.length) {
      notes.push(
        "register name states strength the AWRI name omits — uniqueness plus " +
          "constituent corroboration carried this match",
      );
    }

    // ---- Master Chemical collision ------------------------------------------
    const collision = Boolean(identity && input.existingIdentities.has(identity));
    if (collision) reasons.push("identity_already_in_master_chemicals");

    // ---- Strength score ------------------------------------------------------
    const breakdown: Record<string, number> = {};
    breakdown.tier_base = res.tier ? TIER_BASE[res.tier] : 0;
    breakdown.registrant_prefix_penalty = res.tier === "registrant_prefix"
      ? -2 * Math.max(0, structure.prefixWords - 1)
      : 0;
    let activeEvidence = 0;
    for (const evidence of matchedConstituents) {
      if (!evidence.register_constituents.length) continue;
      activeEvidence += evidence.register_constituents.some((c) => c.camount !== null) ? 4 : 2;
    }
    breakdown.active_evidence = Math.min(8, activeEvidence);
    let numericEvidence = 0;
    for (const e of awriNumericEvidence) {
      if (e.evidence.startsWith("camount:")) numericEvidence += 4;
      else if (e.evidence === "register_name") numericEvidence += 2;
    }
    breakdown.awri_numeric_evidence = Math.min(8, numericEvidence);
    let extraPenalty = 0;
    for (const e of registerExtraNumerics) {
      extraPenalty -= e.evidence === "camount_verified" ? 2 : 4;
    }
    breakdown.register_extra_numeric_penalty = Math.max(-8, extraPenalty);
    breakdown.typography_penalty =
      hasTypographySplit(res.awri_product_name) || hasTypographySplit(registerName) ? -1 : 0;
    breakdown.specificity = Math.min(awriTokens.length, 5);
    const score = Object.values(breakdown).reduce((a, b) => a + b, 0);

    const checks: AuditChecks = {
      artifact_integrity: integrity,
      tier_structure_reproduced: structure.reproduced,
      live_row_present: livePresent,
      live_row_consistent: liveConsistent,
      registration_current: registrationCurrent,
      variant_tokens_equal: variantsEqual,
      actives_corroborated: verdict === "pass",
      numerics_verified: numericsOk,
      no_master_collision: !collision,
      not_duplicate_alias: true, // pass 2 may flip this
    };

    items.push({
      awri_product_name: res.awri_product_name,
      apvma_registration_number: regnum,
      apvma_registered_product_name: registerName,
      registrant: (live?.sname ?? matched?.registrant ?? null)
        ? String(live?.sname ?? matched?.registrant).trim()
        : null,
      registration_identity_key: identity,
      matching_tier: res.tier,
      registrant_prefix_words: structure.prefixWords,
      active_strength_corroboration: {
        verdict,
        manifest_actives: manifestActives,
        matched_constituents: matchedConstituents,
        awri_numeric_evidence: awriNumericEvidence,
        register_extra_numerics: registerExtraNumerics,
      },
      variant_token_check: {
        awri_variant_tokens: awriVariants,
        register_variant_tokens: registerVariants,
        verdict: variantsEqual ? "pass" : "mismatch",
      },
      registration_status: {
        regcode: live?.regcode ? String(live.regcode).trim() : null,
        expdate: expdateRaw,
        classification,
        extract_date: input.extractDate,
      },
      strength_score: score,
      strength_breakdown: breakdown,
      checks,
      decision: reasons.length ? "reject" : "approve_for_seed",
      reject_reasons: reasons,
      notes,
    });
  }

  // ---- Pass 2: duplicate identities keep only the strongest name ----------
  const byIdentity = new Map<string, AuditItem[]>();
  for (const item of items) {
    if (!item.registration_identity_key) continue;
    const bucket = byIdentity.get(item.registration_identity_key);
    if (bucket) bucket.push(item);
    else byIdentity.set(item.registration_identity_key, [item]);
  }
  let duplicateIdentities = 0;
  for (const [, group] of byIdentity) {
    if (group.length < 2) continue;
    duplicateIdentities += 1;
    const approved = group.filter((i) => i.decision === "approve_for_seed");
    if (approved.length < 2) continue;
    const keep = [...approved].sort((a, b) =>
      b.strength_score - a.strength_score ||
      (a.awri_product_name < b.awri_product_name ? -1 : 1)
    )[0];
    for (const item of approved) {
      if (item === keep) continue;
      item.decision = "reject";
      item.checks.not_duplicate_alias = false;
      item.reject_reasons.push(`duplicate_alias_of:${keep.awri_product_name}`);
      item.notes.push(
        "same registration as a stronger audited name — one identity, one seed row",
      );
    }
  }

  // ---- Counts, rankings, invariants ----------------------------------------
  const approved = items.filter((i) => i.decision === "approve_for_seed");
  const counts: AuditCounts = {
    total_audited: items.length,
    approve_for_seed: approved.length,
    rejected: items.length - approved.length,
    archived_or_lapsed: items.filter(
      (i) => i.registration_status.classification !== "current_in_extract",
    ).length,
    master_collisions: items.filter((i) => !i.checks.no_master_collision).length,
    duplicate_identities: duplicateIdentities,
    distinct_identities_approved: new Set(
      approved.map((i) => i.registration_identity_key).filter(Boolean),
    ).size,
    database_changes: 0,
    production_writes: 0,
  };

  const ranked = [...items].sort((a, b) =>
    b.strength_score - a.strength_score ||
    (a.awri_product_name < b.awri_product_name ? -1 : 1)
  );
  const toRanked = (i: AuditItem): RankedMatch => ({
    awri_product_name: i.awri_product_name,
    registration_number: i.apvma_registration_number,
    registered_product_name: i.apvma_registered_product_name,
    tier: i.matching_tier,
    strength_score: i.strength_score,
    decision: i.decision,
  });

  return {
    items,
    counts,
    strongest: ranked.slice(0, 10).map(toRanked),
    weakest: ranked.slice(-10).reverse().map(toRanked),
    invariants: {
      decisions_only_approve_or_reject: "PASS",
      deterministic_input_only: deterministicInputOnly ? "PASS" : "FAIL",
      probable_batch_untouched: "PASS",
      no_database_writes: "PASS",
      apvma_remains_authoritative: identitiesRederive ? "PASS" : "FAIL",
    },
  };
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

export function formatAuditReport(result: AuditResult, testsLine: string): string {
  const c = result.counts;
  return [
    `Total audited: ${c.total_audited}`,
    `Approve for seed: ${c.approve_for_seed}`,
    `Rejected: ${c.rejected}`,
    `Archived/lapsed discovered: ${c.archived_or_lapsed}`,
    `Master Chemical collisions: ${c.master_collisions}`,
    `Duplicate identities (aliases): ${c.duplicate_identities}`,
    `Distinct identities approved: ${c.distinct_identities_approved}`,
    `Deterministic input only: ${result.invariants.deterministic_input_only}`,
    `Probable batch untouched: ${result.invariants.probable_batch_untouched}`,
    `APVMA remains authoritative: ${result.invariants.apvma_remains_authoritative}`,
    `Tests: ${testsLine}`,
    `Database changes: NONE`,
    `Apply step: NONE`,
  ].join("\n");
}
