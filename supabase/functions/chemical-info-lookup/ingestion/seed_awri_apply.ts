// Stage 5B — batch orchestration for applying the reviewed AWRI seed.
//
// PURE module (no network, no filesystem): the CLI runner
// (seeds/run_awri_apply.ts) supplies I/O. Everything here is deterministic
// and unit-tested so the batch's safety properties hold structurally:
//
//   * ONLY identities from the reviewed dry-run artifact can enter the batch
//     (exactly its candidate_identities — nothing else, ever).
//   * Conflict/cancelled identities and unresolved names are structurally
//     excluded: the batch is built from candidate_identities and every item
//     must map to a resolved_current, non-cancel-listed resolution row.
//   * Operator-verified existing rows (manual comparison SQL — AU:apvma:91636)
//     are pre-marked "already_exists" and NEVER sent: skipped unchanged.
//   * Stop/resume safe: state is persisted after EVERY item; terminal
//     outcomes (created / already_exists / unresolved / conflict) are never
//     re-sent on a rerun; only "failed" items are retried.
//   * One failed product never aborts the batch: the per-item send is
//     try/caught and recorded, and the loop continues.

// deno-lint-ignore-file no-explicit-any

// ---------------------------------------------------------------------------
// Reviewed dry-run artifact (seeds/awri_dogbook_2026_27.dryrun.json)
// ---------------------------------------------------------------------------

export interface ApplyArtifactResolution {
  awri_product_name: string;
  kind: string;
  awri_cancelled_listed: boolean;
  registration_number: string | null;
  registration_identity_key: string | null;
  registered_product_name: string | null;
  register_status: string | null;
}

export interface ApplyArtifact {
  seed_source: Record<string, string>;
  resolutions: ApplyArtifactResolution[];
  candidate_identities: string[];
  conflict_identities: string[];
  manual_comparison?: {
    existing_rows?: Array<{
      registration_identity_key: string;
      review_status: string;
      registered_product_name?: string | null;
    }>;
  };
}

export interface ApplyItem {
  registration_identity_key: string;
  registration_number: string;
  /** AWRI name sent for live name↔number re-verification. */
  awri_product_name: string;
  /** Dry-run register name (operator display only). */
  registered_product_name: string | null;
  /** Non-null → operator-verified existing row: pre-marked, never sent. */
  pre_verified_review_status: string | null;
}

/**
 * Build the batch from the REVIEWED artifact. Throws on any structural
 * violation — a batch that cannot prove its own provenance must not run.
 */
export function buildApplyBatch(artifact: ApplyArtifact): ApplyItem[] {
  const candidates = artifact?.candidate_identities;
  if (!Array.isArray(candidates) || !candidates.length) {
    throw new Error("artifact has no candidate_identities — refusing to build a batch");
  }
  const conflicts = new Set(artifact?.conflict_identities ?? []);
  for (const identity of candidates) {
    if (conflicts.has(identity)) {
      throw new Error(`identity ${identity} is in BOTH candidate and conflict buckets — refusing`);
    }
  }
  const seen = new Set<string>();
  const preVerified = new Map<string, string>();
  for (const row of artifact?.manual_comparison?.existing_rows ?? []) {
    if (row?.registration_identity_key && row?.review_status) {
      preVerified.set(row.registration_identity_key, row.review_status);
    }
  }

  // Eligible resolution rows, keyed by identity. ONLY resolved_current and
  // not on AWRI's cancelled list — the same rule the dry run applied.
  const eligible = new Map<string, ApplyArtifactResolution[]>();
  for (const r of artifact?.resolutions ?? []) {
    if (!r?.registration_identity_key) continue;
    if (r.kind !== "resolved_current" || r.awri_cancelled_listed) continue;
    const bucket = eligible.get(r.registration_identity_key);
    if (bucket) bucket.push(r);
    else eligible.set(r.registration_identity_key, [r]);
  }

  const items: ApplyItem[] = [];
  for (const identity of candidates) {
    if (seen.has(identity)) {
      throw new Error(`duplicate identity ${identity} in candidate_identities — refusing`);
    }
    seen.add(identity);
    const number = identity.split(":")[2] ?? "";
    if (!/^\d{3,8}$/.test(number) || identity !== `AU:apvma:${number}`) {
      throw new Error(`identity ${identity} is not a canonical AU:apvma:<number> key — refusing`);
    }
    const rows = eligible.get(identity);
    if (!rows || !rows.length) {
      throw new Error(
        `identity ${identity} has no resolved_current, non-cancelled resolution in the artifact — refusing`,
      );
    }
    const chosen = [...rows].sort((a, b) =>
      a.awri_product_name < b.awri_product_name ? -1 : 1
    )[0];
    if (String(chosen.registration_number ?? "").trim() !== number) {
      throw new Error(`identity ${identity} disagrees with its resolution's register number — refusing`);
    }
    items.push({
      registration_identity_key: identity,
      registration_number: number,
      awri_product_name: chosen.awri_product_name,
      registered_product_name: chosen.registered_product_name,
      pre_verified_review_status: preVerified.get(identity) ?? null,
    });
  }
  const numeric = (k: string): number => Number.parseInt(k.split(":")[2] ?? "", 10) || 0;
  items.sort((a, b) =>
    numeric(a.registration_identity_key) - numeric(b.registration_identity_key)
  );
  return items;
}

// ---------------------------------------------------------------------------
// Batch state (stop/resume + rerun idempotence)
// ---------------------------------------------------------------------------

export interface ApplyStateRecord {
  outcome: string;
  detail: string;
  at: string;
  attempts: number;
}

export interface ApplyState {
  seed_source_id: string;
  started_at: string;
  updated_at: string;
  records: Record<string, ApplyStateRecord>;
}

/** Outcomes that are never re-sent on a rerun. "failed" is retried. */
export const TERMINAL_APPLY_OUTCOMES: ReadonlySet<string> = new Set([
  "created",
  "already_exists",
  "unresolved",
  "conflict",
]);

export function initialApplyState(seedSourceId: string, nowIso: string): ApplyState {
  return { seed_source_id: seedSourceId, started_at: nowIso, updated_at: nowIso, records: {} };
}

/** Record one identity's outcome (pure — returns a new state). */
export function recordOutcome(
  state: ApplyState,
  identity: string,
  outcome: string,
  detail: string,
  nowIso: string,
): ApplyState {
  const prior = state.records[identity];
  return {
    ...state,
    updated_at: nowIso,
    records: {
      ...state.records,
      [identity]: {
        outcome,
        detail,
        at: nowIso,
        attempts: (prior?.attempts ?? 0) + 1,
      },
    },
  };
}

/**
 * Pre-mark operator-verified existing rows as already_exists WITHOUT sending
 * anything: "skipped unchanged" is literal — those identities never even go
 * over the wire.
 */
export function preMarkVerified(state: ApplyState, items: ApplyItem[], nowIso: string): ApplyState {
  let next = state;
  for (const item of items) {
    if (!item.pre_verified_review_status) continue;
    if (next.records[item.registration_identity_key]) continue;
    next = recordOutcome(
      next,
      item.registration_identity_key,
      "already_exists",
      `pre-verified by operator comparison SQL (${item.pre_verified_review_status}) — skipped unchanged, never sent`,
      nowIso,
    );
    // preMark is bookkeeping, not an attempt.
    next.records[item.registration_identity_key].attempts = 0;
  }
  return next;
}

/** Items that still need a send on THIS run. */
export function planPending(items: ApplyItem[], state: ApplyState): ApplyItem[] {
  return items.filter((item) => {
    if (item.pre_verified_review_status) return false;
    const record = state.records[item.registration_identity_key];
    if (!record) return true;
    return !TERMINAL_APPLY_OUTCOMES.has(record.outcome);
  });
}

export interface ApplySummary {
  total: number;
  pre_verified: number;
  created: number;
  already_exists: number;
  unresolved: number;
  conflict: number;
  failed: number;
  pending: number;
}

export function summariseApply(items: ApplyItem[], state: ApplyState): ApplySummary {
  const count = (outcome: string): number =>
    items.filter((i) => state.records[i.registration_identity_key]?.outcome === outcome).length;
  return {
    total: items.length,
    pre_verified: items.filter((i) => i.pre_verified_review_status).length,
    created: count("created"),
    already_exists: count("already_exists"),
    unresolved: count("unresolved"),
    conflict: count("conflict"),
    failed: count("failed"),
    pending: planPending(items, state).length,
  };
}

// ---------------------------------------------------------------------------
// Server-response classification + the resumable per-item loop
// ---------------------------------------------------------------------------

export interface ClassifiedOutcome {
  outcome: string;
  detail: string;
}

const KNOWN_OUTCOMES = new Set([
  "created",
  "already_exists",
  "unresolved",
  "conflict",
  "failed",
]);

/** Map one HTTP response onto a state outcome. Anything unknown = failed. */
export function classifyApplyResponse(status: number, body: any): ClassifiedOutcome {
  if (status === 401 || status === 403) {
    return {
      outcome: "failed",
      detail: `not authorised (HTTP ${status}) — check the admin JWT, then rerun`,
    };
  }
  const outcome = String(body?.outcome ?? "");
  if (status === 200 && KNOWN_OUTCOMES.has(outcome)) {
    return { outcome, detail: String(body?.detail ?? "") };
  }
  return {
    outcome: "failed",
    detail: `unexpected response (HTTP ${status}): ${
      String(body?.error ?? body?.detail ?? "no detail").slice(0, 200)
    }`,
  };
}

/**
 * Process pending items sequentially. Per-item failures are contained and
 * recorded; state is persisted after EVERY item so a stop at any point
 * resumes exactly where it left off.
 */
export async function processPending(
  pending: ApplyItem[],
  send: (item: ApplyItem) => Promise<ClassifiedOutcome>,
  state: ApplyState,
  nowIso: () => string,
  persist: (state: ApplyState) => void | Promise<void>,
  log: (line: string) => void = () => {},
): Promise<ApplyState> {
  let current = state;
  for (const item of pending) {
    let result: ClassifiedOutcome;
    try {
      result = await send(item);
    } catch (err) {
      result = {
        outcome: "failed",
        detail: `transport error: ${err instanceof Error ? err.message : String(err)}`,
      };
    }
    current = recordOutcome(
      current,
      item.registration_identity_key,
      result.outcome,
      result.detail,
      nowIso(),
    );
    await persist(current);
    log(
      `${item.registration_identity_key}  ${result.outcome.padEnd(14)} ${item.awri_product_name}` +
        (result.detail ? ` — ${result.detail}` : ""),
    );
  }
  return current;
}
