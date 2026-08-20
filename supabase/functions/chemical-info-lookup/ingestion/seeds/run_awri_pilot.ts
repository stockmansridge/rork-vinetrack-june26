// Stage 5G pilot runner — apply the 10 operator-approved Stage 5F matches as
// Master CANDIDATES through the DEPLOYED chemical-info-lookup pipeline.
//
// SAFETY MODEL
//   * PLAN mode is the default: reads the Stage 5F audit artifact + the
//     Stage 5G state file, prints exactly what a real run would send,
//     performs ZERO network calls and ZERO writes (not even state).
//   * --execute performs the pilot: one seed_apply call per identity against
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
//     seeds/awri_dogbook_2026_27.stage5g-pilot.state.json, tagged
//     cohort=stage5g_pilot_10_strongest. The Stage 5B/5D batch state file is
//     refused by path AND by shape. State is written after EVERY item:
//     stop (Ctrl-C) and rerun to resume. Terminal outcomes are never
//     re-sent; only "failed" items retry.
//   * HARD CAP: the batch must be exactly the 10 allowlisted identities.
//     Anything else refuses before any network call.
//
// USAGE (from supabase/functions/chemical-info-lookup/ingestion)
//   # 1. Preview (no network, no writes of any kind):
//   deno run --allow-read seeds/run_awri_pilot.ts
//
//   # 2. Execute (PRODUCTION writes — requires explicit operator approval):
//   SEED_APPLY_JWT=<system-admin session JWT> \
//   deno run --allow-read --allow-write --allow-net --allow-env \
//     seeds/run_awri_pilot.ts --execute
//
//   # 3. Idempotence rerun check (AFTER SQL verification passes) — a
//   #    THROWAWAY state file forces every item to be re-sent; the server
//   #    must answer already_exists for all 10 with zero new writes:
//   SEED_APPLY_JWT=<system-admin session JWT> \
//   deno run --allow-read --allow-write --allow-net --allow-env \
//     seeds/run_awri_pilot.ts --execute \
//     --state seeds/awri_dogbook_2026_27.stage5g-pilot.rerun-check.state.json
//
// Verification SQL: sql/stage5g_pilot_verify.sql (read-only).

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
  buildPilotBatch,
  initialPilotState,
  parsePilotState,
  type PilotItem,
  pilotRequestBody,
  STAGE5G_COHORT_ID,
  STAGE5G_PILOT_ALLOWLIST,
} from "../seed_awri_pilot.ts";

const DEFAULT_ARTIFACT = "seeds/awri_dogbook_2026_27.audit.json";
const DEFAULT_STATE = "seeds/awri_dogbook_2026_27.stage5g-pilot.state.json";
/** The Stage 5B/5D batch state — never reused for this cohort. */
const FORBIDDEN_STATE_FILE = "awri_dogbook_2026_27.apply-state.json";
const DEFAULT_ENDPOINT =
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/chemical-info-lookup";
const DEFAULT_DELAY_MS = 400;
const PILOT_SIZE = 10;

function argValue(name: string): string | null {
  const idx = Deno.args.indexOf(name);
  if (idx >= 0 && idx + 1 < Deno.args.length) return Deno.args[idx + 1];
  return null;
}

async function loadPilotState(path: string) {
  try {
    return parsePilotState(await Deno.readTextFile(path));
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) {
      return initialPilotState(new Date().toISOString());
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

  if (statePath.endsWith(FORBIDDEN_STATE_FILE)) {
    console.error(
      `refusing --state ${statePath}: that is the Stage 5B/5D batch state, not this cohort's.`,
    );
    Deno.exit(1);
  }

  const artifact = JSON.parse(await Deno.readTextFile(artifactPath)) as AuditArtifact;
  const items = buildPilotBatch(artifact);
  if (items.length !== PILOT_SIZE) {
    console.error(`pilot batch is ${items.length} items, expected exactly ${PILOT_SIZE} — refusing.`);
    Deno.exit(1);
  }

  const state = await loadPilotState(statePath);
  const byIdentity = new Map<string, PilotItem>(
    items.map((i) => [i.registration_identity_key, i]),
  );
  const pendingIds = new Set(
    planPending(items, state).map((i) => i.registration_identity_key),
  );
  const pending = items.filter((i) => pendingIds.has(i.registration_identity_key));
  const summary = summariseApply(items, state);

  console.log(`Stage 5G — AWRI pilot (cohort ${STAGE5G_COHORT_ID})`);
  console.log(`artifact: ${artifactPath}`);
  console.log(`state:    ${statePath}`);
  console.log(`batch:    ${items.length} audited identities (allowlist ${STAGE5G_PILOT_ALLOWLIST.length})`);
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
    console.log("Run with --execute (and SEED_APPLY_JWT) to perform the pilot.");
    return;
  }

  if (pending.length > PILOT_SIZE) {
    console.error(`pending ${pending.length} exceeds the pilot cap of ${PILOT_SIZE} — refusing.`);
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
    const pilot = byIdentity.get(item.registration_identity_key);
    if (!pilot) {
      return {
        outcome: "failed",
        detail: "item is not in the pilot allowlist — never sent",
      };
    }
    const res = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${jwt}`,
        ...(anonKey ? { "apikey": anonKey } : {}),
      },
      body: JSON.stringify(pilotRequestBody(pilot)),
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
  console.log("Verify (read-only) with sql/stage5g_pilot_verify.sql before going further.");
}

if (import.meta.main) {
  await main();
}
