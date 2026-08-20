// Stage 5B — apply ONE reviewed seed identity as a Master CANDIDATE through
// the verified APVMA ingestion pipeline (docs/master-chemical-ingestion.md §17).
//
// Invariants enforced STRUCTURALLY here:
//   * INSERT-ONLY. This module receives a narrowed ops surface (SeedOps) that
//     has no update capability at the type level. An existing row in ANY
//     review state is returned untouched as "already_exists" — the Stage 4
//     pilot candidate (AU:apvma:91636) can never be modified by seeding.
//   * CANDIDATES ONLY. The payload comes from buildCandidatePayload, whose
//     review_status is the literal type "candidate"; sql/199's CHECK and the
//     approved-provenance gate back that up at the database.
//   * APVMA RE-VERIFIES LIVE. The reviewed registration number is only a
//     pointer: the adapter's register_number_verified path must re-establish
//     on the LIVE register that the row exists AND its name corresponds
//     deterministically to the AWRI product name. The resolved identity must
//     equal the requested identity byte-for-byte or nothing is written.
//   * AWRI IS EVIDENCE METADATA ONLY. Exactly one viticulture_reference
//     entry is appended to verification_sources. Facts — identity, registrant,
//     chemistry, label evidence, WHP/re-entry wording — come exclusively from
//     the register adapter. The row's source_kind stays official_register.
//   * REGISTER DRIFT FAILS SAFE. A row that resolved current at dry-run time
//     but is no longer current on the live register classifies as "conflict"
//     and is never inserted. Unresolved/ambiguous re-verification stays
//     visible as "unresolved" — never silently substituted.
//   * NO AI. Seeding never calls the model: register + label evidence only.
//     No Saved Chemicals writes, no Spray Record writes, no approval.

// deno-lint-ignore-file no-explicit-any

import type { DiscoveryResult, MasterOps } from "./contract.ts";
import { identityKey } from "./contract.ts";
import { buildCandidatePayload, buildRegisterOnlyStructured } from "./ingest.ts";

/**
 * The only catalogue operations seeding is allowed to hold. updateCandidate
 * is structurally absent: a seed run cannot patch, refresh, or merge aliases
 * into ANY existing row, whatever its review state.
 */
export type SeedOps = Pick<MasterOps, "selectByIdentityKey" | "insertCandidate">;

/** Live re-verification hook (index.ts wires the real AU adapter). */
export type SeedDiscoverFn = (
  query: string,
  hintRegistrationNumber: string,
) => Promise<DiscoveryResult>;

export interface SeedSourceMeta {
  id: string;
  name: string;
  reference: string;
  edition: string;
}

/**
 * Server-side whitelist of seed sources. A seed request can only ever attach
 * evidence metadata this table defines — arbitrary evidence injection through
 * the API is impossible.
 */
export const SEED_SOURCES: Record<string, SeedSourceMeta> = {
  awri_dogbook_2026_27: {
    id: "awri_dogbook_2026_27",
    name:
      "AWRI 'Dog Book' — Agrochemicals registered for use in Australian viticulture 2026/27 (viticulture coverage reference only; never a registration authority)",
    reference: "https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf",
    edition: "2026/27",
  },
};

export interface SeedApplyInput {
  /** Reviewed register number, digits only (e.g. "91636"). */
  registration_number: string;
  /** The AWRI product name the dry run resolved — re-verified live. */
  product_name: string;
  /** Must name a SEED_SOURCES entry. */
  seed_source_id: string;
}

export type SeedApplyOutcomeKind =
  | "created" // one new candidate row inserted
  | "already_exists" // row exists in some review state — untouched
  | "unresolved" // live register no longer verifies name↔number — no write
  | "conflict" // live register row is no longer current — no write
  | "failed"; // validation/transport/unexpected — no write

export interface SeedApplyOutcome {
  outcome: SeedApplyOutcomeKind;
  registration_identity_key: string | null;
  review_status?: string;
  registered_product_name?: string;
  register_status?: string | null;
  detail: string;
  /** Batch-runner hint: retry "failed" outcomes on a later pass. */
  retryable: boolean;
  /** Audit: rows written by this call — always 0 or 1. */
  writes: 0 | 1;
}

function currentRegcode(registerStatus: string | null | undefined): boolean {
  const first = String(registerStatus ?? "").split(",")[0]?.trim().toUpperCase();
  return first === "R";
}

function fail(
  identity: string | null,
  detail: string,
  retryable: boolean,
): SeedApplyOutcome {
  return {
    outcome: "failed",
    registration_identity_key: identity,
    detail,
    retryable,
    writes: 0,
  };
}

/**
 * Apply one reviewed identity. Never throws: every path — including an
 * unexpected exception — returns a structured outcome so one product can
 * never abort a batch.
 */
export async function runSeedApply(
  input: SeedApplyInput,
  ops: SeedOps,
  discover: SeedDiscoverFn,
  nowIso: string,
  tableVersion: number,
): Promise<SeedApplyOutcome> {
  // ---- Validation (no I/O yet) -------------------------------------------
  const source = SEED_SOURCES[String(input?.seed_source_id ?? "").trim()];
  if (!source) {
    return fail(null, "unknown seed source — refused (server whitelist)", false);
  }
  const number = String(input?.registration_number ?? "").trim();
  if (!/^\d{3,8}$/.test(number)) {
    return fail(null, "registration number must be 3-8 digits", false);
  }
  const requestedName = String(input?.product_name ?? "").trim();
  if (!requestedName) {
    return fail(null, "product name required for live name↔number re-verification", false);
  }
  const key = identityKey("AU", "apvma", number);

  try {
    // ---- 1) Skip-existing-unchanged (any review state; zero writes) -------
    const existing = await ops.selectByIdentityKey(key);
    if (existing) {
      return {
        outcome: "already_exists",
        registration_identity_key: key,
        review_status: existing.review_status,
        registered_product_name: existing.registered_product_name,
        detail: `row already in Master (${existing.review_status}) — skipped unchanged`,
        retryable: false,
        writes: 0,
      };
    }

    // ---- 2) Live register re-verification ---------------------------------
    const discovery = await discover(requestedName, number);
    if (discovery.outcome === "source_unavailable") {
      return fail(
        key,
        `register source unavailable (${discovery.error_category ?? "unknown"}) — retry later; NOT "not registered"`,
        true,
      );
    }
    if (discovery.outcome !== "resolved" || !discovery.registration) {
      return {
        outcome: "unresolved",
        registration_identity_key: key,
        detail:
          `live register did not deterministically verify name↔number (${discovery.outcome}) — no write, fail closed`,
        retryable: false,
        writes: 0,
      };
    }
    const reg = discovery.registration;
    if (reg.registration_identity_key !== key) {
      return fail(
        key,
        `identity mismatch: register resolved ${reg.registration_identity_key}, reviewed ${key} — refused`,
        false,
      );
    }
    if (!currentRegcode(reg.register_status)) {
      return {
        outcome: "conflict",
        registration_identity_key: key,
        register_status: reg.register_status ?? null,
        registered_product_name: reg.registered_product_name,
        detail:
          `register row is no longer current (${reg.register_status ?? "status unknown"}) — no write, fail safe`,
        retryable: false,
        writes: 0,
      };
    }

    // ---- 3) Register-only structured + AWRI evidence metadata -------------
    // No AI call: identity, chemistry and label evidence come from the
    // register adapter alone. The AWRI entry is supporting reference
    // metadata — it contributes no catalogue fact.
    const structured = buildRegisterOnlyStructured(reg, tableVersion);
    structured.verification.sources = [
      ...(structured.verification.sources ?? []),
      {
        kind: "viticulture_reference",
        name: source.name,
        reference: source.reference,
        retrieved_at: nowIso,
      },
    ];

    // ---- 4) Candidate payload (review_status pinned "candidate") ----------
    const payload = buildCandidatePayload(structured, requestedName, reg, nowIso, tableVersion);
    if (!payload) {
      return fail(key, "candidate payload incomplete — refused", false);
    }
    if (payload.review_status !== "candidate" || payload.source_kind !== "official_register") {
      // Structurally unreachable; kept as a hard gate.
      return fail(key, "payload failed candidate-only/provenance gate — refused", false);
    }

    // ---- 5) Duplicate-safe insert (never an update) ------------------------
    const inserted = await ops.insertCandidate(payload);
    if (inserted) {
      return {
        outcome: "created",
        registration_identity_key: key,
        review_status: inserted.review_status,
        registered_product_name: inserted.registered_product_name,
        register_status: reg.register_status ?? null,
        detail: `candidate created (${reg.match_mode})`,
        retryable: false,
        writes: 1,
      };
    }
    // Insert skipped by the uniqueness guard (row appeared mid-request) or
    // transient failure: re-select decides which, still zero updates.
    const raced = await ops.selectByIdentityKey(key);
    if (raced) {
      return {
        outcome: "already_exists",
        registration_identity_key: key,
        review_status: raced.review_status,
        registered_product_name: raced.registered_product_name,
        detail: `row appeared concurrently (${raced.review_status}) — skipped unchanged`,
        retryable: false,
        writes: 0,
      };
    }
    return fail(key, "insert did not persist — retry later", true);
  } catch (err) {
    return fail(
      key,
      `unexpected error: ${err instanceof Error ? err.message : String(err)}`,
      true,
    );
  }
}
