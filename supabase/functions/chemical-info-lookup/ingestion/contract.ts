// Canonical authoritative-ingestion contract (Master Chemical Catalogue Stage 3).
//
// ONE ingestion result shape, mapping DIRECTLY onto the sql/199
// master_chemicals columns and the sql/194 wire vocabulary
// (docs/chemical-intelligence-json-contract.md). There is deliberately no
// second Chemical Intelligence model here: active ingredients, registered
// uses, sources and conflicts reuse the exact snake_case wire field names the
// apps and portal already persist and parse.
//
// Trust model (docs/master-chemical-ingestion.md):
//   official_register  > manufacturer_label > supporting references > AI.
// AI may LOCATE a product (a name, a possible registration number); it can
// never elevate itself into authoritative evidence, and a fact an
// authoritative source does not provide stays unresolved — never invented.
//
// Stage 4 note — "official label evidence" travels as the contract's
// `manufacturer_label` kind: the APVMA-approved label IS the registrant's
// approved label (§5.3 of the JSON contract), already ranked authoritative
// and second only to the register itself. The four tiers stay structurally
// distinguishable on every stored fact: official_register (identity,
// chemistry), manufacturer_label (label claims/statements),
// authoritative_classification (FRAC/HRAC/IRAC), ai_interpretation.

import type { ActivityGroup } from "./activity_groups.ts";

// ---------------------------------------------------------------------------
// sql/194 wire fragments (exact field names — see JSON contract §4)
// ---------------------------------------------------------------------------

export interface WireActiveIngredient {
  name: string;
  concentration?: number | null;
  concentration_unit?: string | null;
  activity_group?: ActivityGroup | null;
  group_source?: string | null;
  identity_source?: string | null;
}

export interface WireDataSource {
  kind: string;
  name: string;
  reference?: string | null;
  retrieved_at?: string | null;
}

export interface WireConflict {
  field: string;
  active_ingredient_name?: string;
  extracted_value: string;
  authoritative_value: string;
  extracted_source: string;
  authoritative_source: string;
}

// ---------------------------------------------------------------------------
// Discovery (adapter output)
// ---------------------------------------------------------------------------

export type DiscoveryOutcome =
  | "resolved" // canonical registration identity established from the register
  | "unresolved" // no deterministic register match (fail closed — NOT "not registered")
  | "ambiguous" // more than one register row matched deterministically
  | "source_unavailable" // register source unreachable/unparseable
  | "not_supported" // jurisdiction has no adapter yet (NZ/GB/US… future)
  | "no_country"; // request carried no resolved vineyard country

/**
 * A registered product identity resolved from the jurisdiction's official
 * register, plus every register-backed fact the source actually provided.
 * Anything the register does NOT provide is absent here and listed in
 * `unresolved_fields` — the adapter never invents WHP, re-entry, rates,
 * uses, or concentrations to make a record look complete.
 */
export interface ResolvedRegistration {
  country_code: string; // "AU"
  scheme: string; // "apvma"
  registration_number: string; // "66541"
  registration_identity_key: string; // "AU:apvma:66541"
  registered_product_name: string; // verbatim register product name
  registrant: string | null;
  product_category: string | null; // mapped register category, or null
  form_type: string | null; // "liquid" | "solid" | null
  /** Current approved-label register record (approval no. + date), if any. */
  label_version: string | null;
  /** Register lifecycle detail, e.g. "R, expires 30/06/2029". */
  register_status: string | null;
  /** Register-backed actives (identity_source: official_register). */
  active_ingredients: WireActiveIngredient[];
  /** Fields the register could not supply (never fabricated). */
  unresolved_fields: string[];
  /** official_register evidence entries with reproducible references. */
  sources: WireDataSource[];
  /** How the deterministic match was made (audit trail, never fuzzy). */
  match_mode:
    | "exact_name"
    | "compact_name"
    | "formulation_suffix"
    | "reverse_formulation_suffix"
    | "register_number_verified";
  /**
   * Stage 4 — official label evidence resolved from the register's published
   * label claim data, or null when it could not be fetched/parsed (fail
   * soft: identity and chemistry stand; label facts stay unresolved or
   * AI-attributed, never invented).
   */
  label_evidence?: LabelEvidence | null;
}

// ---------------------------------------------------------------------------
// Official label evidence (Stage 4)
// ---------------------------------------------------------------------------

/**
 * One registered use claim from the official label evidence: the crop and
 * target verbatim as the register publishes them, plus ONLY the label facts
 * the evidence actually states. A claim never carries a rate — the register
 * publishes no machine-readable rate table, so rates stay unresolved for the
 * admin to confirm against the label document (or AI-attributed, never
 * promoted).
 */
export interface LabelUseClaim {
  crop: string; // verbatim register host wording, e.g. "GRAPEVINE"
  target_raw: string; // verbatim register pest wording
  target?: string; // VineTrack target enum, only when it maps cleanly
  withholding_period_days?: number; // only when a label statement states it (0 = "not required")
  re_entry_period_hours?: number; // only when a label statement states it
  /** Verbatim crop-scoped label statements backing the fields above. */
  statements: string[];
}

/** Official label evidence for one registered product. */
export interface LabelEvidence {
  claims: LabelUseClaim[];
  /** Every reassembled label statement, verbatim (audit trail). */
  statements: string[];
  /** manufacturer_label evidence entries with reproducible references. */
  sources: WireDataSource[];
  /** Label facts the evidence could not supply (never fabricated). */
  unresolved: string[];
}

export interface DiscoveryResult {
  outcome: DiscoveryOutcome;
  adapter: string | null;
  registration?: ResolvedRegistration;
  error_category?: string;
  cache: "hit" | "miss" | "none";
}

export interface AdapterDeps {
  fetchFn: typeof fetch;
  now: () => Date;
}

/**
 * A jurisdiction's authoritative source adapter. Selected by the vineyard's
 * resolved country through the registry — source selection is NEVER an AI
 * decision. An adapter only ever consults its own jurisdiction's sources; a
 * foreign register or label can never be used as local authority.
 */
export interface SourceAdapter {
  id: string; // "apvma"
  country: string; // "AU"
  scheme: string; // sql/194 registration_scheme value
  discover(
    query: string,
    hintRegistrationNumber: string | null,
    deps: AdapterDeps,
  ): Promise<DiscoveryResult>;
}

// ---------------------------------------------------------------------------
// Master catalogue rows / candidate payloads (sql/199 columns, verbatim)
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
export type Jsonish = any;

export interface MasterRow {
  id: string;
  registration_country: string;
  registration_scheme: string;
  registration_number: string;
  registration_identity_key: string;
  registrant: string | null;
  registered_product_name: string;
  common_names: string[];
  product_category: string | null;
  form_type: string | null;
  active_ingredients: WireActiveIngredient[];
  activity_groups: string[];
  activity_group_scheme: string | null;
  registered_uses: Jsonish[];
  label_rate_bases: string[];
  label_reference: string | null;
  label_version: string | null;
  verification_status: string;
  verification_sources: WireDataSource[] | null;
  verification_conflicts: WireConflict[] | null;
  verification_unresolved_fields: string[] | null;
  verified_at: string | null;
  source_kind: string;
  source_reference: string | null;
  retrieved_at: string | null;
  review_status: string;
  catalogue_version: number;
  activity_group_table_version: number | null;
  intelligence_schema_version: number;
}

/** Insert payload for a sql/199 CANDIDATE row (never anything else). */
export interface CandidateRowPayload {
  registration_country: string;
  registration_scheme: string;
  registration_number: string;
  registrant: string | null;
  registered_product_name: string;
  common_names: string[];
  product_category: string | null;
  form_type: string | null;
  active_ingredients: WireActiveIngredient[];
  activity_groups: string[];
  activity_group_scheme: string | null;
  registered_uses: Jsonish[];
  label_rate_bases: string[];
  label_reference: string | null;
  label_version: string | null;
  verification_status: string;
  verification_sources: WireDataSource[];
  verification_conflicts: WireConflict[];
  verification_unresolved_fields: string[];
  source_kind: string;
  source_reference: string | null;
  retrieved_at: string;
  /** Structurally pinned: automated ingestion can only ever enqueue candidates. */
  review_status: "candidate";
  activity_group_table_version: number;
  intelligence_schema_version: number;
}

/**
 * Catalogue persistence operations, injected so the orchestrator and tests
 * never hard-wire PostgREST. Implementations use the service role; RLS keeps
 * candidates invisible to every normal lookup path regardless.
 */
export interface MasterOps {
  /** Exact registration-identity lookup across ALL review states. */
  selectByIdentityKey(identityKey: string): Promise<MasterRow | null>;
  /**
   * Insert a candidate. Must be duplicate-safe on the identity key
   * (existing rows always win); returns the stored row, or null when the
   * insert was skipped by the uniqueness guard.
   */
  insertCandidate(payload: CandidateRowPayload): Promise<MasterRow | null>;
  /** Patch a CANDIDATE row. Callers must never target approved rows. */
  updateCandidate(id: string, patch: Record<string, Jsonish>): Promise<boolean>;
}

/** Mirrors the sql/199 generated identity column byte-for-byte. */
export function identityKey(
  country: string,
  scheme: string,
  registrationNumber: string,
): string {
  return `${country}:${scheme}:${registrationNumber.trim().toUpperCase()}`;
}
