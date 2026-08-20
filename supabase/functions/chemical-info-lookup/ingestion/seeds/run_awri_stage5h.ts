// Stage 5H runner — apply the REMAINING 169 Stage 5F-approved AWRI matches as
// Master CANDIDATES through the DEPLOYED chemical-info-lookup pipeline.
// (Stage 5G is production-verified and closed; its 10 identities are excluded
// structurally — see seed_awri_stage5h.ts.)
//
// SAFETY MODEL (identical to the verified Stage 5G pilot)
//   * PLAN mode is the default: reads the Stage 5F audit artifact + the
//     Stage 5H state file, prints exactly what a real run would send,
//     performs ZERO network calls and ZERO writes (not even state).
//   * --execute performs the batch: one seed_apply call per identity against
//     the deployed edge function, using the OPERATOR'S OWN admin JWT
//     (env SEED_APPLY_JWT). No service-role key exists in this repo or this
//     runner; the function's own admin gate (is_system_admin) decides.
//   * The server re-verifies each registration LIVE immediately before
//     insert: pcode row must exist, its live name must correspond exactly to
//     the audited registered product name we send, the resolved identity
//     must equal AU:apvma:<number> byte-for-byte, and the row must be
//     current (regcode R) — otherwise NOTHING is written for that item.
//   * Inserts are candidate-only (review_status pinned "candidate"), rows
//     that already exist in ANY review state are skipped unchanged, and the
//     server's seed surface has no update capability at the type level.
//     No Saved Chemicals writes, no Spray Records writes, ever.
//   * SEPARATE STATE for this cohort:
//     seeds/awri_dogbook_2026_27.stage5h.state.json, tagged
//     cohort=stage5h_remaining_169. The Stage 5B/5D batch state AND the
//     Stage 5G pilot state are refused by path AND by shape. State is
//     written after EVERY item: stop (Ctrl-C) and rerun to resume. Terminal
//     outcomes are never re-sent; only "failed" items retry.
//   * HARD CAP: the batch must be exactly the 169 derived identities.
//     Anything else refuses before any network call.
//
// EXPECTED DURATION: 169 items × (live APVMA re-verification + 400 ms delay)
// ≈ 4–7 minutes. Safe to interrupt at any point and rerun to resume.
//
// USAGE (from supabase/functions/chemical-info-lookup/ingestion)
//   # 1. Preview (no network, no writes of any kind) — must show 169 pending:
//   deno run --allow-read seeds/run_awri_stage5h.ts
//
//   # 2. Execute (PRODUCTION writes — requires explicit operator approval):
//   SEED_APPLY_JWT=<system-admin session JWT> \
//   deno run --allow-read --allow-write --allow-net --allow-env \
//     seeds/run_awri_stage5h.ts --execute
//
//   # 3. Idempotence rerun check (AFTER SQL verification passes) — a
//   #    THROWAWAY state file forces every item to be re-sent; the server
//   #    must answer already_exists for all 169 with zero new writes:
//   SEED_APPLY_JWT=<system-admin session JWT> \
//   deno run --allow-read --allow-write --allow-net --allow-env \
//     seeds/run_awri_stage5h.ts --execute \
//     --state seeds/awri_dogbook_2026_27.stage5h.rerun-check.state.json
//
// Verification SQL: sql/stage5h_verify.sql (read-only, run unchanged
// before the batch, after the batch, and after the rerun check).

import {
  type ApplyItem,
  type ApplyState,
  classifyApplyResponse,
  planPending,
  processPending,
  summariseApply,
} from "../seed_awri_apply.ts";
import {
  type AuditArtifact,
  buildStage5hBatch,
  initialStage5hState,
  parseStage5hState,
  STAGE5H_BATCH_SIZE,
  STAGE5H_COHORT_ID,
  type Stage5hItem,
  stage5hRequestBody,
} from "../seed_awri_stage5h.ts";

const DEFAULT_ARTIFACT = "seeds/awri_dogbook_2026_27.audit.json";
const DEFAULT_STATE = "seeds/awri_dogbook_2026_27.stage5h.state.json";
/** The Stage 5B/5D batch state — never reused for this cohort. */
const FORBIDDEN_BATCH_STATE = "awri_dogbook_2026_27.apply-state.json";
/** The completed Stage 5G pilot's state files — never reused for this cohort. */
const FORBIDDEN_PILOT_STATE_MARKER = "stage5g-pilot";
const DEFAULT_ENDPOINT =
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/chemical-info-lookup";
const DEFAULT_DELAY_MS = 400;

function argValue(name: string): string | null {
  const idx = Deno.args.indexOf(name);
  if (idx >= 0 && idx + 1 < Deno.args.length) return Deno.args[idx + 1];
  return null;
}

async function loadStage5hState(path: string) {
  try {
    return parseStage5hState(await Deno.readTextFile(path));
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) {
      return initialStage5hState(new Date().toISOString());
    }
    throw err;
  }
}

async function main(): Promise<void> {
  const artifactPath = argValue("--artifact") ?? DEFAULT_ARTIFACT;
  const statePath = argValue("--state") ?? DEFAULT_STATE;
  const endpoint = argValue("--endpoint") ?? DEFAULT_ENDPOINT;
  const execute = Deno.args.includes("--execute");
  const delayMs = Number.parseInt(argValue("--delay-ms") ?? "", 10) || DEFAULT_DELAY_MS;

  if (statePath.endsWith(FORBIDDEN_BATCH_STATE)) {
    console.error(
      `refusing --state ${statePath}: that is the Stage 5B/5D batch state, not this cohort's.`,
    );
    Deno.exit(1);
  }
  if (statePath.includes(FORBIDDEN_PILOT_STATE_MARKER)) {
    console.error(
      `refusing --state ${statePath}: that is the completed Stage 5G pilot's state, not this cohort's.`,
    );
    Deno.exit(1);
  }

  const artifact = JSON.parse(await Deno.readTextFile(artifactPath)) as AuditArtifact;
  const items = buildStage5hBatch(artifact);
  if (items.length !== STAGE5H_BATCH_SIZE) {
    console.error(
      `Stage 5H batch is ${items.length} items, expected exactly ${STAGE5H_BATCH_SIZE} — refusing.`,
    );
    Deno.exit(1);
  }

  const state = await loadStage5hState(statePath);
  const byIdentity = new Map<string, Stage5hItem>(
    items.map((i) => [i.registration_identity_key, i]),
  );
  const pendingIds = new Set(
    planPending(items, state).map((i) => i.registration_identity_key),
  );
  const pending = items.filter((i) => pendingIds.has(i.registration_identity_key));
  const summary = summariseApply(items, state);

  console.log(`Stage 5H — remaining AWRI deterministic matches (cohort ${STAGE5H_COHORT_ID})`);
  console.log(`artifact: ${artifactPath}`);
  console.log(`state:    ${statePath}`);
  console.log(
    `batch:    ${items.length} audited identities ` +
      `(179 approved − ${179 - STAGE5H_BATCH_SIZE} completed in Stage 5G)`,
  );
  console.log(
    `state so far: created ${summary.created} | already_exists ${summary.already_exists} | ` +
      `unresolved ${summary.unresolved} | conflict ${summary.conflict} | failed ${summary.failed}`,
  );
  console.log(`pending this run: ${pending.length}\n`);
  for (const item of items) {
    const record = state.records[item.registration_identity_key];
    const status = record ? record.outcome : "pending";
    console.log(
      `  ${item.registration_identity_key.padEnd(16)} ${status.padEnd(14)} ` +
        `${item.awri_product_name}  →  sends "${item.send_product_name}"`,
    );
  }

  if (!execute) {
    console.log("\nPLAN ONLY — no network calls made, no state written, no database writes.");
    console.log("Run with --execute (and SEED_APPLY_JWT) to perform the Stage 5H batch.");
    return;
  }

  if (pending.length > STAGE5H_BATCH_SIZE) {
    console.error(
      `pending ${pending.length} exceeds the Stage 5H cap of ${STAGE5H_BATCH_SIZE} — refusing.`,
    );
    Deno.exit(1);
  }
  const jwt = Deno.env.get("SEED_APPLY_JWT") ?? "";
  if (!jwt) {
    console.error("SEED_APPLY_JWT is required for --execute (a system admin's session JWT).");
    Deno.exit(1);
  }
  const anonKey = Deno.env.get("SEED_APPLY_ANON_KEY") ?? "";

  const persist = async (s: ApplyState): Promise<void> => {
    await Deno.writeTextFile(statePath, JSON.stringify(s, null, 1));
  };
  await persist(state); // cohort tag lands on disk before the first send

  const send = async (item: ApplyItem) => {
    const batchItem = byIdentity.get(item.registration_identity_key);
    if (!batchItem) {
      return {
        outcome: "failed",
        detail: "item is not in the Stage 5H batch — never sent",
      };
    }
    const res = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${jwt}`,
        ...(anonKey ? { "apikey": anonKey } : {}),
      },
      body: JSON.stringify(stage5hRequestBody(batchItem)),
    });
    const body = await res.json().catch(() => null);
    const classified = classifyApplyResponse(res.status, body);
    if (delayMs > 0) await new Promise((r) => setTimeout(r, delayMs));
    return classified;
  };

  const finalState = await processPending(
    pending,
    send,
    state,
    () => new Date().toISOString(),
    persist,
    (line) => console.log(line),
  );

  const final = summariseApply(items, finalState);
  console.log(
    `\nDone. created ${final.created} | already_exists ${final.already_exists} | ` +
      `unresolved ${final.unresolved} | conflict ${final.conflict} | ` +
      `failed ${final.failed} | still pending ${final.pending}`,
  );
  if (final.failed > 0) {
    console.log("Failed items stay in the state file and will retry on the next run.");
  }
  console.log("Verify (read-only) with sql/stage5h_verify.sql before going further.");
}

if (import.meta.main) {
  await main();
}
