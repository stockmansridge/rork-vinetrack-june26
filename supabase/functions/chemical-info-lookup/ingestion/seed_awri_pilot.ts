// Stage 5G — 10-product PILOT apply batch for Stage 5F-approved AWRI matches.
//
// PURE module (no network, no filesystem, no database): the CLI runner
// (seeds/run_awri_pilot.ts) supplies I/O. The batch's safety properties are
// structural and unit-tested:
//
//   * ONLY the operator-approved 10-pair allowlist below can enter the batch.
//     Rows come EXCLUSIVELY from the reviewed Stage 5F audit artifact
//     (seeds/awri_dogbook_2026_27.audit.json) and only where the audited
//     decision is approve_for_seed. The artifact contains only the 181
//     deterministic Stage 5E matches, so the 162 probable_manual_review,
//     87 ambiguous and 38 no_match names are STRUCTURALLY absent — they can
//     never be selected here. The 2 rejected duplicate aliases are excluded
//     by the decision check (and a batch that names one refuses to build).
//   * The audit's counts are pinned (181 audited / 179 approved / 2 rejected /
//     0 Master collisions): a regenerated, truncated or tampered artifact
//     refuses to build a batch — this pilot is bound to the audit the
//     operator signed off, not to "whatever file is on disk".
//   * WIRE FORMAT: the pilot sends the AUDITED REGISTERED product name as
//     productName, NOT the AWRI booklet name. The deployed seed_apply
//     mechanism re-verifies name↔number on the LIVE register with
//     exact-or-ignorable-suffix correspondence (apvma.ts nameCorresponds).
//     The AWRI booklet names in this cohort deliberately do NOT satisfy that
//     rule — glued formulation tokens ("720SC" vs register "720 SC") and one
//     registrant-prefixed register name ("CONQUEST Clash Storm Guard …") are
//     exactly why they needed the Stage 5E tier ladder (test G10 documents
//     this). Sending the audited registered name turns live re-verification
//     into an EXACT normalised name match against the register row the pcode
//     names: any register rename since the audit fails closed ("unresolved",
//     zero writes). The AWRI-name↔registration binding itself is carried by
//     the approved Stage 5F audit artifact; the AWRI name travels in the
//     batch as state/report metadata only.
//   * AWRI provenance is attached SERVER-SIDE from the seed-source whitelist
//     (seed_apply.ts SEED_SOURCES) — one viticulture_reference entry per row.
//     The row's facts stay register-only; source_kind stays official_register;
//     review_status is pinned "candidate" (never auto-approved).
//   * SEPARATE STATE: pilot state is cohort-tagged. parsePilotState refuses
//     the Stage 5B/5D batch state file (no cohort field) and any other
//     cohort's file, so this pilot can never resume — or contaminate — the
//     earlier 198-row batch bookkeeping.
//   * No Saved Chemicals writes, no Spray Records writes: the deployed
//     seed_apply path holds a SeedOps surface with select+insertCandidate
//     only; nothing here changes that.

import type { ApplyItem, ApplyState } from "./seed_awri_apply.ts";
import { initialApplyState } from "./seed_awri_apply.ts";

/** Cohort tag persisted into (and demanded from) the Stage 5G state file. */
export const STAGE5G_COHORT_ID = "stage5g_pilot_10_strongest";

/** Seed source sent to the deployed function — must stay on its whitelist. */
export const STAGE5G_SEED_SOURCE_ID = "awri_dogbook_2026_27";

export interface PilotPair {
  awri_product_name: string;
  registration_number: string;
}

/**
 * The operator-approved Stage 5G pilot cohort: the 10 strongest Stage 5F
 * audited matches, byte-for-byte as approved. Nothing outside this list can
 * be sent by the pilot runner.
 */
export const STAGE5G_PILOT_ALLOWLIST: readonly PilotPair[] = [
  { awri_product_name: "Conan Sticks 720SC", registration_number: "68458" },
  { awri_product_name: "Fortuna Globe 750WG", registration_number: "67494" },
  { awri_product_name: "Cavalier 500SC", registration_number: "81077" },
  { awri_product_name: "Fascinate 280SL", registration_number: "83459" },
  { awri_product_name: "Glister 680 SG", registration_number: "60560" },
  { awri_product_name: "Hammer 400 EC", registration_number: "63228" },
  { awri_product_name: "Kobus 480SC", registration_number: "92506" },
  { awri_product_name: "Penncozeb 750DF", registration_number: "53987" },
  { awri_product_name: "Spraytop 250SL", registration_number: "54522" },
  { awri_product_name: "Clash Storm Guard 720 SC", registration_number: "58831" },
];

// ---------------------------------------------------------------------------
// Stage 5F audit artifact (narrowed to the fields Stage 5G consumes)
// ---------------------------------------------------------------------------

export interface AuditItem {
  awri_product_name: string;
  apvma_registration_number: string;
  apvma_registered_product_name: string;
  registrant: string | null;
  registration_identity_key: string;
  matching_tier: string;
  registration_status: { classification: string; expdate?: string | null };
  checks: Record<string, boolean>;
  decision: string;
  reject_reasons: string[];
}

export interface AuditArtifact {
  stage: string;
  counts: {
    total_audited: number;
    approve_for_seed: number;
    rejected: number;
    master_collisions: number;
  };
  items: AuditItem[];
}

/** The exact Stage 5F numbers the operator approved. Anything else refuses. */
const PINNED_AUDIT_COUNTS = {
  total_audited: 181,
  approve_for_seed: 179,
  rejected: 2,
  master_collisions: 0,
} as const;

const DETERMINISTIC_TIERS = new Set(["registrant_prefix", "formulation_suffix"]);

export interface PilotItem extends ApplyItem {
  /** Audited registered product name — the string sent for live exact re-verification. */
  send_product_name: string;
}

function guard(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(`Stage 5G refuses to build a batch: ${message}`);
}

/**
 * Build the pilot batch from the REVIEWED Stage 5F audit artifact. Throws on
 * ANY structural violation — a pilot that cannot prove its provenance must
 * not run. Output is deterministic: sorted by registration number.
 */
export function buildPilotBatch(
  artifact: AuditArtifact,
  allowlist: readonly PilotPair[] = STAGE5G_PILOT_ALLOWLIST,
): PilotItem[] {
  // ---- Artifact identity: must be THE approved Stage 5F audit -------------
  guard(typeof artifact?.stage === "string" && artifact.stage.startsWith("5F"), "artifact is not a Stage 5F audit artifact");
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

  // ---- Allowlist hygiene ----------------------------------------------------
  guard(allowlist.length > 0, "empty allowlist");
  const listNames = new Set<string>();
  const listNumbers = new Set<string>();
  for (const pair of allowlist) {
    const name = String(pair?.awri_product_name ?? "").trim();
    const number = String(pair?.registration_number ?? "").trim();
    guard(name.length > 0, "allowlist entry has an empty AWRI product name");
    guard(/^\d{3,8}$/.test(number), `allowlist number "${number}" is not 3-8 digits`);
    guard(!listNames.has(name), `duplicate AWRI name in allowlist: ${name}`);
    guard(!listNumbers.has(number), `duplicate registration number in allowlist: ${number}`);
    listNames.add(name);
    listNumbers.add(number);
  }

  // ---- Index audited items by AWRI name (names are unique in the det set) --
  const byName = new Map<string, AuditItem>();
  for (const item of artifact.items) {
    const name = String(item?.awri_product_name ?? "");
    guard(!byName.has(name), `audit artifact has two items named "${name}"`);
    byName.set(name, item);
  }

  // ---- Per-pair verification against the audited decision ------------------
  const items: PilotItem[] = [];
  for (const pair of allowlist) {
    const item = byName.get(pair.awri_product_name);
    guard(
      item !== undefined,
      `"${pair.awri_product_name}" is not in the Stage 5F audit (probable/ambiguous/no-match names are structurally absent)`,
    );
    const number = String(item.apvma_registration_number ?? "").trim();
    guard(
      number === pair.registration_number,
      `"${pair.awri_product_name}" was audited as APVMA ${number}, allowlist says ${pair.registration_number}`,
    );
    guard(
      item.decision === "approve_for_seed",
      `"${pair.awri_product_name}" → ${number} was NOT approved (decision ${item.decision}${
        item.reject_reasons?.length ? `; ${item.reject_reasons.join(", ")}` : ""
      })`,
    );
    guard(
      (item.reject_reasons ?? []).length === 0,
      `"${pair.awri_product_name}" carries reject reasons despite its decision — artifact inconsistent`,
    );
    guard(
      item.registration_status?.classification === "current_in_extract",
      `"${pair.awri_product_name}" → ${number} is not current_in_extract (${item.registration_status?.classification})`,
    );
    const checkEntries = Object.entries(item.checks ?? {});
    guard(checkEntries.length > 0, `"${pair.awri_product_name}" has no audit checks recorded`);
    for (const [check, passed] of checkEntries) {
      guard(passed === true, `"${pair.awri_product_name}" failed audit check "${check}"`);
    }
    guard(
      DETERMINISTIC_TIERS.has(item.matching_tier),
      `"${pair.awri_product_name}" has non-deterministic tier "${item.matching_tier}"`,
    );
    const identity = `AU:apvma:${number}`;
    guard(
      item.registration_identity_key === identity,
      `"${pair.awri_product_name}" identity key ${item.registration_identity_key} is not canonical ${identity}`,
    );
    const registeredName = String(item.apvma_registered_product_name ?? "").trim();
    guard(registeredName.length > 0, `"${pair.awri_product_name}" has no audited registered product name to verify against`);

    items.push({
      registration_identity_key: identity,
      registration_number: number,
      awri_product_name: pair.awri_product_name,
      registered_product_name: registeredName,
      pre_verified_review_status: null,
      send_product_name: registeredName,
    });
  }

  // ---- Post-conditions: the batch is the allowlist, nothing more ----------
  guard(items.length === allowlist.length, "batch size does not equal the allowlist size");
  const identities = new Set(items.map((i) => i.registration_identity_key));
  guard(identities.size === items.length, "duplicate registration identity inside the pilot batch");
  for (const item of items) {
    guard(listNumbers.has(item.registration_number), `batch leaked an identity outside the allowlist: ${item.registration_identity_key}`);
  }

  const numeric = (i: PilotItem): number => Number.parseInt(i.registration_number, 10) || 0;
  items.sort((a, b) => numeric(a) - numeric(b));
  return items;
}

// ---------------------------------------------------------------------------
// Wire format — locked to the DEPLOYED seed_apply action's request shape
// ---------------------------------------------------------------------------

export interface PilotRequestBody {
  action: "seed_apply";
  registrationNumber: string;
  productName: string;
  seedSource: string;
}

/**
 * The exact request body one pilot item sends to the deployed edge function.
 * productName is the AUDITED registered product name (see module header):
 * live re-verification must be an exact normalised match or nothing writes.
 */
export function pilotRequestBody(
  item: PilotItem,
  seedSourceId: string = STAGE5G_SEED_SOURCE_ID,
): PilotRequestBody {
  guard(/^\d{3,8}$/.test(item.registration_number), `invalid registration number "${item.registration_number}"`);
  guard(item.send_product_name.trim().length > 0, "pilot item has no send_product_name");
  return {
    action: "seed_apply",
    registrationNumber: item.registration_number,
    productName: item.send_product_name,
    seedSource: seedSourceId,
  };
}

// ---------------------------------------------------------------------------
// Cohort-separated state (stop/resume + rerun idempotence, Stage 5G only)
// ---------------------------------------------------------------------------

export interface PilotState extends ApplyState {
  cohort: string;
}

export function initialPilotState(nowIso: string): PilotState {
  return { cohort: STAGE5G_COHORT_ID, ...initialApplyState(STAGE5G_SEED_SOURCE_ID, nowIso) };
}

/**
 * Parse a persisted pilot state file. REFUSES anything that is not this
 * cohort's state: the Stage 5B/5D batch state (no cohort field), another
 * cohort's file, another seed source, or a malformed records map.
 */
export function parsePilotState(raw: string): PilotState {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("Stage 5G state file is not valid JSON — refusing");
  }
  const state = parsed as Partial<PilotState> | null;
  if (!state || typeof state !== "object") {
    throw new Error("Stage 5G state file is not an object — refusing");
  }
  if (state.cohort !== STAGE5G_COHORT_ID) {
    throw new Error(
      `state file cohort is ${JSON.stringify(state.cohort ?? null)}, expected "${STAGE5G_COHORT_ID}" — ` +
        "refusing to reuse another cohort's state (Stage 5B/5D state files have no cohort tag)",
    );
  }
  if (state.seed_source_id !== STAGE5G_SEED_SOURCE_ID) {
    throw new Error(
      `state file seed source is ${JSON.stringify(state.seed_source_id ?? null)}, expected "${STAGE5G_SEED_SOURCE_ID}" — refusing`,
    );
  }
  if (!state.records || typeof state.records !== "object" || Array.isArray(state.records)) {
    throw new Error("Stage 5G state file has no records map — refusing");
  }
  return state as PilotState;
}
