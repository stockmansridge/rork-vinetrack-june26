// Master Catalogue review preview (Stage 2 R2-B) — the edge half of the
// amended stored-preview trust boundary (sql/203).
//
// FLOW (single edge action, `master_review_preview`):
//   1. System admin runs the EXISTING authoritative refresh (refreshMasterRow
//      — read-only; a preview NEVER writes master_chemicals).
//   2. The registration-identity guard is preserved: a register-resolved
//      registration number that differs from the row's is a DIFFERENT
//      registered product — surfaced for display, but NO writable preview is
//      stored (re-keying has its own gated RPC, master_review_rekey).
//   3. The exact resolver-owned patch is built by the ONE reviewed builder
//      (buildRefreshPatch — the same code the candidate refresh path uses).
//   4. The patch is validated against the sql/203 resolver patch contract AT
//      STORE TIME (the apply RPC re-validates — defense in depth).
//   5. The patch is stored server-side in master_review_previews (service
//      role INSERT — the one service-role write in the review flow), bound to
//      the requesting admin, with the row's catalogue_version as the CAS
//      base_revision and a DB-defaulted 30-minute expiry.
//   6. The response carries preview_id + display copies (proposed_patch,
//      changes, current values). Display copies are informational ONLY:
//      master_review_apply loads the patch by opaque preview_id and never
//      accepts one from any client.
//
// NO PREVIEW ROW is stored when there is nothing an apply could write:
//   * outcome no_material_change  → nothing to apply;
//   * outcome source_unavailable  → the register said NOTHING;
//   * identity guard refused      → rekey is a separate, explicit decision;
//   * no register identity        → e.g. a delisting: material to REPORT,
//                                   nothing writable (never fabricated).
//
// A preview failure (validation or storage) returns an error envelope and
// changes NOTHING: this module has no master_chemicals write capability at
// all — its only side effects are PreviewStore.insertPreview/purgeExpired.
//
// APPLY PATH (deliberately NOT here): the portal calls the sql/203
// master_review_apply RPC directly via PostgREST with the ADMIN'S OWN JWT.
// The service role never applies; reviewer attribution (auth.uid()) and the
// mandatory change reason stay real. This module stores; the RPC applies.

// deno-lint-ignore-file no-explicit-any

import type { Jsonish, MasterRow } from "./contract.ts";
import {
  buildRefreshPatch,
  type RefreshChange,
  type RefreshResult,
} from "./refresh.ts";

// ---------------------------------------------------------------------------
// Resolver patch contract — mirrors sql/203 master_review_apply byte-for-byte
// ---------------------------------------------------------------------------

const STRING_KEYS: ReadonlySet<string> = new Set([
  "registered_product_name",
  "verification_status",
  "source_kind",
]);

const STRING_OR_NULL_KEYS: ReadonlySet<string> = new Set([
  "registrant",
  "product_category",
  "form_type",
  "label_version",
  "label_reference",
  "source_reference",
  "retrieved_at",
]);

const ARRAY_KEYS: ReadonlySet<string> = new Set([
  "registered_uses",
  "label_rate_bases",
]);

const ARRAY_OR_NULL_KEYS: ReadonlySet<string> = new Set([
  "verification_sources",
  "verification_conflicts",
  "verification_unresolved_fields",
]);

/** The 15 keys a stored resolver patch may write — and nothing else, ever. */
export const RESOLVER_PATCH_CONTRACT_KEYS: readonly string[] = [
  ...STRING_KEYS,
  ...STRING_OR_NULL_KEYS,
  ...ARRAY_KEYS,
  ...ARRAY_OR_NULL_KEYS,
];

/**
 * Validate a resolver-built patch against the sql/203 resolver patch
 * contract (same per-key type rules the apply RPC enforces). Returns the
 * violation detail, or null when the patch conforms. Identity fields,
 * review_status, catalogue_version — anything outside the 15 contract keys —
 * is a violation: fail closed, store nothing.
 */
export function validateResolverPatch(patch: unknown): string | null {
  if (
    patch === null || typeof patch !== "object" || Array.isArray(patch)
  ) {
    return "proposed_patch must be a non-empty object";
  }
  const entries = Object.entries(patch as Record<string, unknown>);
  if (!entries.length) return "proposed_patch must be a non-empty object";
  for (const [key, value] of entries) {
    if (STRING_KEYS.has(key)) {
      if (typeof value !== "string") return `key ${key} must be a string`;
    } else if (STRING_OR_NULL_KEYS.has(key)) {
      if (value !== null && typeof value !== "string") {
        return `key ${key} must be a string or null`;
      }
    } else if (ARRAY_KEYS.has(key)) {
      if (!Array.isArray(value)) return `key ${key} must be an array`;
    } else if (ARRAY_OR_NULL_KEYS.has(key)) {
      if (value !== null && !Array.isArray(value)) {
        return `key ${key} must be an array or null`;
      }
    } else {
      return `forbidden_key=${key}`;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Registration-identity guard
// ---------------------------------------------------------------------------

export type IdentityGuard =
  | { status: "passed" }
  | {
    status: "refused";
    reason: "registration_number_mismatch";
    current_registration_number: string;
    register_registration_number: string;
  }
  | { status: "not_evaluated" };

/**
 * The preserved refreshMasterRow identity guard, evaluated for the review
 * flow: a register-resolved number that differs from the row's means a
 * DIFFERENT registered product — refused (no writable preview; re-keying is
 * the explicit master_review_rekey decision, never a refresh side effect).
 * "not_evaluated" = the register said nothing usable about identity (outage,
 * or no current register listing resolved).
 */
export function evaluateIdentityGuard(result: RefreshResult): IdentityGuard {
  if (result.outcome === "source_unavailable") return { status: "not_evaluated" };
  const mismatch = result.changes.find((c) => c.field === "registration_number");
  if (mismatch) {
    return {
      status: "refused",
      reason: "registration_number_mismatch",
      current_registration_number: mismatch.current,
      register_registration_number: mismatch.authoritative,
    };
  }
  if (!result.registration) return { status: "not_evaluated" };
  return { status: "passed" };
}

// ---------------------------------------------------------------------------
// Current-values snapshot (display support for the portal diff)
// ---------------------------------------------------------------------------

/**
 * The row's CURRENT values for exactly the resolver-contract surface, so the
 * portal renders current vs proposed without a second fetch. Display only.
 */
export function buildCurrentSnapshot(row: MasterRow): Record<string, Jsonish> {
  return {
    registered_product_name: row.registered_product_name,
    registrant: row.registrant ?? null,
    product_category: row.product_category ?? null,
    form_type: row.form_type ?? null,
    label_version: row.label_version ?? null,
    label_reference: row.label_reference ?? null,
    registered_uses: row.registered_uses ?? [],
    label_rate_bases: row.label_rate_bases ?? [],
    verification_status: row.verification_status,
    verification_sources: row.verification_sources ?? [],
    verification_conflicts: row.verification_conflicts ?? [],
    verification_unresolved_fields: row.verification_unresolved_fields ?? [],
    retrieved_at: row.retrieved_at ?? null,
    source_kind: row.source_kind,
    source_reference: row.source_reference ?? null,
  };
}

// ---------------------------------------------------------------------------
// Preview storage (injected — index.ts wires service-role PostgREST)
// ---------------------------------------------------------------------------

/** Insert payload for master_review_previews. Expiry/consumption columns are
 * DELIBERATELY absent: expires_at is the DB default (now() + 30 minutes) and
 * consumption happens only inside master_review_apply. */
export interface PreviewInsertPayload {
  master_chemical_id: string;
  base_revision: number;
  outcome: string;
  proposed_patch: Record<string, Jsonish>;
  changes: RefreshChange[];
  requested_by: string;
}

export interface StoredPreview {
  id: string;
  expires_at?: string | null;
  [key: string]: Jsonish;
}

export interface PreviewStore {
  /** Service-role INSERT; returns the stored row or null on failure. */
  insertPreview(payload: PreviewInsertPayload): Promise<StoredPreview | null>;
  /** Opportunistic fail-soft DELETE of expired, unconsumed previews. */
  purgeExpired(nowIso: string): Promise<void>;
}

// ---------------------------------------------------------------------------
// Orchestrator
// ---------------------------------------------------------------------------

export type NoPreviewReason =
  | "source_unavailable"
  | "identity_mismatch"
  | "no_material_change"
  | "no_writable_patch";

export interface ReviewPreviewResponse {
  outcome: string;
  changes: RefreshChange[];
  identity_guard: IdentityGuard;
  preview_stored: boolean;
  no_preview_reason?: NoPreviewReason;
  preview_id: string | null;
  expires_at: string | null;
  base_revision: number;
  /** Display only. Apply loads the SERVER-stored patch by preview_id. */
  proposed_patch: Record<string, Jsonish> | null;
  current: Record<string, Jsonish>;
  master: {
    master_chemical_id: string;
    catalogue_status: string;
    master_revision: number;
    registration_identity_key: string | null;
  };
  error_category?: string;
  error?: "patch_contract_violation" | "preview_store_failed";
  error_detail?: string;
}

export interface ReviewPreviewDeps {
  store: PreviewStore;
  nowIso: () => string;
  /**
   * Test seam ONLY — production always uses the reviewed refresh builder
   * (buildRefreshPatch). Injected in tests to prove the store-time contract
   * validation blocks a non-conforming patch before it reaches storage.
   */
  buildPatchFn?: (
    row: MasterRow,
    result: RefreshResult,
    nowIso: string,
  ) => Record<string, Jsonish> | null;
}

/**
 * Turn one refresh result into a stored, single-use, admin-bound review
 * preview — or an honest explanation of why nothing is storable. Pure
 * orchestration: the ONLY side effects are PreviewStore calls; there is no
 * code path that writes master_chemicals (the deps don't even carry one).
 */
export async function runMasterReviewPreview(
  row: MasterRow,
  result: RefreshResult,
  adminUserId: string,
  deps: ReviewPreviewDeps,
): Promise<ReviewPreviewResponse> {
  const buildPatch = deps.buildPatchFn ?? buildRefreshPatch;
  const baseRevision = typeof row.catalogue_version === "number"
    ? row.catalogue_version
    : 1;
  const identityGuard = evaluateIdentityGuard(result);

  const base: ReviewPreviewResponse = {
    outcome: result.outcome,
    changes: result.changes,
    identity_guard: identityGuard,
    preview_stored: false,
    preview_id: null,
    expires_at: null,
    base_revision: baseRevision,
    proposed_patch: null,
    current: buildCurrentSnapshot(row),
    master: {
      master_chemical_id: row.id,
      catalogue_status: row.review_status,
      master_revision: baseRevision,
      registration_identity_key: row.registration_identity_key ?? null,
    },
    ...(result.error_category ? { error_category: result.error_category } : {}),
  };

  // The register said NOTHING — nothing may be previewed, nothing inferred.
  if (result.outcome === "source_unavailable") {
    return { ...base, no_preview_reason: "source_unavailable" };
  }

  // Identity guard: a different registration number is a DIFFERENT product.
  // The mismatch is returned for display; NO writable preview exists.
  if (identityGuard.status === "refused") {
    return { ...base, no_preview_reason: "identity_mismatch" };
  }

  if (result.outcome === "no_material_change") {
    return { ...base, no_preview_reason: "no_material_change" };
  }

  const patch = buildPatch(row, result, deps.nowIso());
  if (!patch) {
    // Material to REPORT but nothing writable — e.g. the register no longer
    // lists this identity. Retire/adjudicate are explicit decisions; a
    // refresh preview never fabricates a patch for them.
    return { ...base, no_preview_reason: "no_writable_patch" };
  }

  // Store-time contract validation (sql/203 re-validates at apply time). A
  // violation here means the builder or the store path is compromised —
  // fail closed, store nothing, mutate nothing.
  const violation = validateResolverPatch(patch);
  if (violation) {
    return {
      ...base,
      error: "patch_contract_violation",
      error_detail: violation,
    };
  }

  // Housekeeping first (fail-soft): expired unconsumed previews are dead
  // weight — consumed ones are kept for already_applied idempotent replay.
  try {
    await deps.store.purgeExpired(deps.nowIso());
  } catch {
    /* purge is never allowed to block a preview */
  }

  let stored: StoredPreview | null = null;
  try {
    stored = await deps.store.insertPreview({
      master_chemical_id: row.id,
      base_revision: baseRevision,
      outcome: result.outcome,
      proposed_patch: patch,
      changes: result.changes,
      requested_by: adminUserId,
    });
  } catch {
    stored = null;
  }
  if (!stored || typeof stored.id !== "string" || !stored.id) {
    return {
      ...base,
      error: "preview_store_failed",
      error_detail:
        "preview row could not be stored; master_chemicals was not modified",
    };
  }

  return {
    ...base,
    preview_stored: true,
    preview_id: stored.id,
    expires_at: stored.expires_at ?? null,
    proposed_patch: patch,
  };
}
