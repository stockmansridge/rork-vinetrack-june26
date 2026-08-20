// Stage 5H — the REMAINING 169 Stage 5F-approved AWRI matches (Stage 5G is
// production-verified and closed; its 10 identities are excluded here).
//
// PURE module (no network, no filesystem, no database): the CLI runner
// (seeds/run_awri_stage5h.ts) supplies I/O. Safety properties are structural
// and unit-tested, mirroring the Stage 5G pilot:
//
//   * The batch is DERIVED, never hand-listed: all 179 approve_for_seed items
//     from the reviewed Stage 5F audit artifact
//     (seeds/awri_dogbook_2026_27.audit.json) MINUS the 10 identities the
//     Stage 5G pilot already applied (imported from seed_awri_pilot.ts —
//     one source of truth, byte-for-byte). 179 − 10 = 169, and the batch
//     size is pinned to exactly 169.
//   * The artifact contains only the 181 deterministic Stage 5E matches, so
//     the 162 probable_manual_review, 87 ambiguous and 38 no_match names are
//     STRUCTURALLY absent. The 2 rejected duplicate aliases are excluded by
//     the decision check; their identities enter exactly once, under the
//     stronger AWRI names the audit kept.
//   * The audit's counts are pinned (181 audited / 179 approved / 2 rejected /
//     0 Master collisions): a regenerated, truncated or tampered artifact
//     refuses to build. Every item is re-demanded: approve_for_seed, no
//     reject reasons, current_in_extract, ALL audit checks true, deterministic
//     tier only, canonical AU:apvma:<n> identity, non-empty registered name.
//   * WIRE FORMAT (same Stage 5G decision): send the AUDITED REGISTERED
//     product name as productName, so the deployed seed_apply live
//     re-verification (apvma.ts nameCorresponds) is an exact normalised match
//     against the register row the pcode names. Any register rename since the
//     audit fails closed ("unresolved", zero writes). The AWRI booklet name
//     travels as state/report metadata only; the AWRI↔registration binding is
//     carried by the approved audit artifact.
//   * AWRI provenance is attached SERVER-SIDE from the seed-source whitelist
//     (seed_apply.ts SEED_SOURCES) — one viticulture_reference entry per row.
//     source_kind stays official_register; review_status is pinned
//     "candidate" (never auto-approved); existing Master rows in ANY review
//     state answer already_exists and are skipped unchanged.
//   * SEPARATE STATE: Stage 5H state is cohort-tagged. parseStage5hState
//     refuses the Stage 5B/5D batch state (no cohort field), the Stage 5G
//     pilot state (different cohort tag), any other cohort, any other seed
//     source, and malformed records maps.
//   * No Saved Chemicals writes, no Spray Records writes: the deployed
//     seed_apply path holds a SeedOps surface with select+insertCandidate
//     only; nothing here changes that.

import type { ApplyState } from "./seed_awri_apply.ts";
import { initialApplyState } from "./seed_awri_apply.ts";
import {
  type AuditArtifact,
  type AuditItem,
  type PilotItem,
  type PilotPair,
  STAGE5G_COHORT_ID,
  STAGE5G_PILOT_ALLOWLIST,
} from "./seed_awri_pilot.ts";

/** Cohort tag persisted into (and demanded from) the Stage 5H state file. */
export const STAGE5H_COHORT_ID = "stage5h_remaining_169";

/** Seed source sent to the deployed function — must stay on its whitelist. */
export const STAGE5H_SEED_SOURCE_ID = "awri_dogbook_2026_27";

/** 179 approved in the Stage 5F audit − 10 completed in the Stage 5G pilot. */
export const STAGE5H_BATCH_SIZE = 169;

/** Stage 5H items carry the same shape as pilot items (send_product_name = audited registered name). */
export type Stage5hItem = PilotItem;

/** The exact Stage 5F numbers the operator approved. Anything else refuses. */
const PINNED_AUDIT_COUNTS = {
  total_audited: 181,
  approve_for_seed: 179,
  rejected: 2,
  master_collisions: 0,
} as const;

const DETERMINISTIC_TIERS = new Set(["registrant_prefix", "formulation_suffix"]);

function guard(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(`Stage 5H refuses to build a batch: ${message}`);
}

/**
 * Build the Stage 5H batch: every approve_for_seed item in the REVIEWED
 * Stage 5F audit artifact except the 10 the Stage 5G pilot already applied.
 * Throws on ANY structural violation. Output is deterministic: sorted by
 * registration number ascending.
 */
export function buildStage5hBatch(
  artifact: AuditArtifact,
  completedPilot: readonly PilotPair[] = STAGE5G_PILOT_ALLOWLIST,
): Stage5hItem[] {
  // ---- Artifact identity: must be THE approved Stage 5F audit -------------
  guard(
    typeof artifact?.stage === "string" && artifact.stage.startsWith("5F"),
    "artifact is not a Stage 5F audit artifact",
  );
  guard(Array.isArray(artifact.items), "artifact has no items array");
  const counts = artifact.counts;
  for (const key of Object.keys(PINNED_AUDIT_COUNTS) as Array<keyof typeof PINNED_AUDIT_COUNTS>) {
    guard(
      counts?.[key] === PINNED_AUDIT_COUNTS[key],
      `audit counts.${key} is ${String(counts?.[key])}, approved audit has ${PINNED_AUDIT_COUNTS[key]}`,
    );
  }
  guard(
    artifact.items.length === PINNED_AUDIT_COUNTS.total_audited,
    `artifact has ${artifact.items.length} items, approved audit has ${PINNED_AUDIT_COUNTS.total_audited}`,
  );

  // ---- Exclusion-list hygiene: exactly the completed Stage 5G cohort ------
  guard(
    completedPilot.length === STAGE5G_PILOT_ALLOWLIST.length,
    `expected exactly ${STAGE5G_PILOT_ALLOWLIST.length} Stage 5G exclusions, got ${completedPilot.length}`,
  );
  const pilotByName = new Map<string, PilotPair>();
  const pilotIdentities = new Set<string>();
  for (const pair of completedPilot) {
    const name = String(pair?.awri_product_name ?? "").trim();
    const number = String(pair?.registration_number ?? "").trim();
    guard(name.length > 0, "exclusion entry has an empty AWRI product name");
    guard(/^\d{3,8}$/.test(number), `exclusion number "${number}" is not 3-8 digits`);
    guard(!pilotByName.has(name), `duplicate AWRI name in exclusions: ${name}`);
    const identity = `AU:apvma:${number}`;
    guard(!pilotIdentities.has(identity), `duplicate registration number in exclusions: ${number}`);
    pilotByName.set(name, pair);
    pilotIdentities.add(identity);
  }

  // ---- Walk the audit: skip the 2 rejected + the 10 completed, keep 169 ---
  const seenNames = new Set<string>();
  const excludedNames = new Set<string>();
  let rejectedSeen = 0;
  const items: Stage5hItem[] = [];

  for (const item of artifact.items) {
    const name = String(item?.awri_product_name ?? "");
    guard(!seenNames.has(name), `audit artifact has two items named "${name}"`);
    seenNames.add(name);

    const pilotPair = pilotByName.get(name);

    if (item.decision !== "approve_for_seed") {
      rejectedSeen += 1;
      guard(
        pilotPair === undefined,
        `rejected item "${name}" is in the completed Stage 5G exclusion list — artifact/exclusion mismatch`,
      );
      continue; // the 2 rejected duplicate aliases never enter any batch
    }

    const number = String(item.apvma_registration_number ?? "").trim();

    if (pilotPair) {
      guard(
        number === pilotPair.registration_number,
        `"${name}" was audited as APVMA ${number}, Stage 5G completed it as ${pilotPair.registration_number} — refusing`,
      );
      excludedNames.add(name);
      continue; // already applied and production-verified in Stage 5G
    }

    // ---- Per-item verification against the audited decision ---------------
    guard(
      (item.reject_reasons ?? []).length === 0,
      `"${name}" carries reject reasons despite its decision — artifact inconsistent`,
    );
    guard(
      item.registration_status?.classification === "current_in_extract",
      `"${name}" → ${number} is not current_in_extract (${item.registration_status?.classification})`,
    );
    const checkEntries = Object.entries(item.checks ?? {});
    guard(checkEntries.length > 0, `"${name}" has no audit checks recorded`);
    for (const [check, passed] of checkEntries) {
      guard(passed === true, `"${name}" failed audit check "${check}"`);
    }
    guard(
      DETERMINISTIC_TIERS.has(item.matching_tier),
      `"${name}" has non-deterministic tier "${item.matching_tier}"`,
    );
    guard(/^\d{3,8}$/.test(number), `"${name}" has malformed registration number "${number}"`);
    const identity = `AU:apvma:${number}`;
    guard(
      item.registration_identity_key === identity,
      `"${name}" identity key ${item.registration_identity_key} is not canonical ${identity}`,
    );
    guard(
      !pilotIdentities.has(identity),
      `identity ${identity} belongs to the completed Stage 5G pilot but appears under AWRI name "${name}" — refusing`,
    );
    const registeredName = String(item.apvma_registered_product_name ?? "").trim();
    guard(registeredName.length > 0, `"${name}" has no audited registered product name to verify against`);

    items.push({
      registration_identity_key: identity,
      registration_number: number,
      awri_product_name: name,
      registered_product_name: registeredName,
      pre_verified_review_status: null,
      send_product_name: registeredName,
    });
  }

  // ---- Post-conditions: 2 rejected skipped, 10 excluded, exactly 169 kept -
  guard(
    rejectedSeen === PINNED_AUDIT_COUNTS.rejected,
    `expected exactly ${PINNED_AUDIT_COUNTS.rejected} rejected items in the audit, found ${rejectedSeen}`,
  );
  guard(
    excludedNames.size === completedPilot.length,
    `Stage 5G pilot exclusions matched ${excludedNames.size} of ${completedPilot.length} — refusing`,
  );
  guard(
    items.length === STAGE5H_BATCH_SIZE,
    `batch is ${items.length} items, expected exactly ${STAGE5H_BATCH_SIZE}`,
  );
  const identities = new Set(items.map((i) => i.registration_identity_key));
  guard(identities.size === items.length, "duplicate registration identity inside the Stage 5H batch");

  const numeric = (i: Stage5hItem): number => Number.parseInt(i.registration_number, 10) || 0;
  items.sort((a, b) => numeric(a) - numeric(b));
  return items;
}

// ---------------------------------------------------------------------------
// Wire format — locked to the DEPLOYED seed_apply action's request shape
// ---------------------------------------------------------------------------

export interface Stage5hRequestBody {
  action: "seed_apply";
  registrationNumber: string;
  productName: string;
  seedSource: string;
}

/**
 * The exact request body one Stage 5H item sends to the deployed edge
 * function. productName is the AUDITED registered product name (see module
 * header): live re-verification must be an exact normalised match or nothing
 * writes.
 */
export function stage5hRequestBody(
  item: Stage5hItem,
  seedSourceId: string = STAGE5H_SEED_SOURCE_ID,
): Stage5hRequestBody {
  guard(/^\d{3,8}$/.test(item.registration_number), `invalid registration number "${item.registration_number}"`);
  guard(item.send_product_name.trim().length > 0, "Stage 5H item has no send_product_name");
  return {
    action: "seed_apply",
    registrationNumber: item.registration_number,
    productName: item.send_product_name,
    seedSource: seedSourceId,
  };
}

// ---------------------------------------------------------------------------
// Cohort-separated state (stop/resume + rerun idempotence, Stage 5H only)
// ---------------------------------------------------------------------------

export interface Stage5hState extends ApplyState {
  cohort: string;
}

export function initialStage5hState(nowIso: string): Stage5hState {
  return { cohort: STAGE5H_COHORT_ID, ...initialApplyState(STAGE5H_SEED_SOURCE_ID, nowIso) };
}

/**
 * Parse a persisted Stage 5H state file. REFUSES anything that is not this
 * cohort's state: the Stage 5B/5D batch state (no cohort field), the
 * Stage 5G pilot state (cohort "stage5g_pilot_10_strongest"), any other
 * cohort's file, another seed source, or a malformed records map.
 */
export function parseStage5hState(raw: string): Stage5hState {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("Stage 5H state file is not valid JSON — refusing");
  }
  const state = parsed as Partial<Stage5hState> | null;
  if (!state || typeof state !== "object") {
    throw new Error("Stage 5H state file is not an object — refusing");
  }
  if (state.cohort !== STAGE5H_COHORT_ID) {
    throw new Error(
      `state file cohort is ${JSON.stringify(state.cohort ?? null)}, expected "${STAGE5H_COHORT_ID}" — ` +
        "refusing to reuse another cohort's state (Stage 5B/5D state files have no cohort tag; " +
        `the completed Stage 5G pilot is cohort "${STAGE5G_COHORT_ID}")`,
    );
  }
  if (state.seed_source_id !== STAGE5H_SEED_SOURCE_ID) {
    throw new Error(
      `state file seed source is ${JSON.stringify(state.seed_source_id ?? null)}, expected "${STAGE5H_SEED_SOURCE_ID}" — refusing`,
    );
  }
  if (!state.records || typeof state.records !== "object" || Array.isArray(state.records)) {
    throw new Error("Stage 5H state file has no records map — refusing");
  }
  return state as Stage5hState;
}

// Re-exported so the runner and tests bind to ONE definition of the audit types.
export type { AuditArtifact, AuditItem };
