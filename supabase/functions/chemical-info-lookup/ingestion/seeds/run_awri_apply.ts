// Stage 5B batch runner — apply the reviewed AWRI 2026/27 seed as Master
// CANDIDATES through the DEPLOYED chemical-info-lookup pipeline.
//
// SAFETY MODEL
//   * PLAN mode is the default: reads the reviewed artifact + state file,
//     prints exactly what a real run would send, performs ZERO network calls
//     and ZERO writes.
//   * --execute performs the batch: one seed_apply call per identity against
//     the deployed edge function, using the OPERATOR'S OWN admin JWT
//     (env SEED_APPLY_JWT). No service-role key exists in this repo or
//     this runner; the function's own admin gate (is_system_admin) decides.
//   * State (seeds/awri_dogbook_2026_27.apply-state.json) is written after
//     EVERY item: stop (Ctrl-C) and rerun to resume. Terminal outcomes are
//     never re-sent; only "failed" items retry.
//   * Operator-verified existing rows (AU:apvma:91636) are pre-marked
//     already_exists and never sent — skipped unchanged, literally.
//
// USAGE
//   cd supabase/functions/chemical-info-lookup/ingestion
//   # Plan (no network, no writes):
//   deno run --allow-read --allow-write seeds/run_awri_apply.ts
//   # Execute (production writes — requires explicit operator approval):
//   SEED_APPLY_JWT=<system-admin session JWT> \
//   deno run --allow-read --allow-write --allow-net --allow-env \
//     seeds/run_awri_apply.ts --execute [--endpoint <functions-url>] [--limit N]

import {
  type ApplyArtifact,
  type ApplyItem,
  type ApplyState,
  buildApplyBatch,
  classifyApplyResponse,
  initialApplyState,
  planPending,
  preMarkVerified,
  processPending,
  summariseApply,
} from "../seed_awri_apply.ts";

const DEFAULT_ARTIFACT = "seeds/awri_dogbook_2026_27.dryrun.json";
const DEFAULT_STATE = "seeds/awri_dogbook_2026_27.apply-state.json";
const DEFAULT_ENDPOINT =
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/chemical-info-lookup";
const DEFAULT_DELAY_MS = 400;

function argValue(name: string): string | null {
  const idx = Deno.args.indexOf(name);
  if (idx >= 0 && idx + 1 < Deno.args.length) return Deno.args[idx + 1];
  return null;
}

async function loadState(path: string, seedSourceId: string): Promise<ApplyState> {
  try {
    const raw = await Deno.readTextFile(path);
    const parsed = JSON.parse(raw) as ApplyState;
    if (parsed?.seed_source_id !== seedSourceId) {
      throw new Error(
        `state file ${path} belongs to seed source ${parsed?.seed_source_id}, expected ${seedSourceId}`,
      );
    }
    return parsed;
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) {
      return initialApplyState(seedSourceId, new Date().toISOString());
    }
    throw err;
  }
}

async function main(): Promise<void> {
  const artifactPath = argValue("--artifact") ?? DEFAULT_ARTIFACT;
  const statePath = argValue("--state") ?? DEFAULT_STATE;
  const endpoint = argValue("--endpoint") ?? DEFAULT_ENDPOINT;
  const execute = Deno.args.includes("--execute");
  const limitArg = argValue("--limit");
  const limit = limitArg ? Math.max(0, Number.parseInt(limitArg, 10) || 0) : Infinity;
  const delayMs = Number.parseInt(argValue("--delay-ms") ?? "", 10) || DEFAULT_DELAY_MS;

  const artifact = JSON.parse(await Deno.readTextFile(artifactPath)) as ApplyArtifact;
  const seedSourceId = String(artifact?.seed_source?.id ?? "awri_dogbook_2026_27");
  const items = buildApplyBatch(artifact);

  let state = await loadState(statePath, seedSourceId);
  state = preMarkVerified(state, items, new Date().toISOString());

  const pendingAll = planPending(items, state);
  const pending = pendingAll.slice(0, limit === Infinity ? undefined : limit);
  const summary = summariseApply(items, state);

  console.log(`Stage 5B — AWRI ${artifact?.seed_source?.edition ?? "2026/27"} seed apply`);
  console.log(`artifact: ${artifactPath}`);
  console.log(`state:    ${statePath}`);
  console.log(
    `batch:    ${summary.total} reviewed identities ` +
      `(${summary.pre_verified} pre-verified existing, never sent)`,
  );
  console.log(
    `state so far: created ${summary.created} | already_exists ${summary.already_exists} | ` +
      `unresolved ${summary.unresolved} | conflict ${summary.conflict} | failed ${summary.failed}`,
  );
  console.log(`pending this run: ${pending.length}${limit !== Infinity ? ` (limit ${limit})` : ""}`);

  if (!execute) {
    console.log("\nPLAN ONLY — no network calls made, no state written, no database writes.");
    for (const item of pending.slice(0, 10)) {
      console.log(
        `  would send: ${item.registration_identity_key}  ${item.awri_product_name}`,
      );
    }
    if (pending.length > 10) console.log(`  … and ${pending.length - 10} more`);
    console.log("\nRun with --execute (and SEED_APPLY_JWT) to perform the batch.");
    return;
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
  await persist(state); // pre-verified marks land before the first send

  const send = async (item: ApplyItem) => {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${jwt}`,
        ...(anonKey ? { "apikey": anonKey } : {}),
      },
      body: JSON.stringify({
        action: "seed_apply",
        registrationNumber: item.registration_number,
        productName: item.awri_product_name,
        seedSource: seedSourceId,
      }),
    });
    const body = await res.json().catch(() => null);
    const classified = classifyApplyResponse(res.status, body);
    if (delayMs > 0) await new Promise((r) => setTimeout(r, delayMs));
    return classified;
  };

  state = await processPending(
    pending,
    send,
    state,
    () => new Date().toISOString(),
    persist,
    (line) => console.log(line),
  );

  const final = summariseApply(items, state);
  console.log(
    `\nDone. created ${final.created} | already_exists ${final.already_exists} | ` +
      `unresolved ${final.unresolved} | conflict ${final.conflict} | ` +
      `failed ${final.failed} | still pending ${final.pending}`,
  );
  if (final.failed > 0) {
    console.log("Failed items stay in the state file and will retry on the next run.");
  }
}

if (import.meta.main) {
  await main();
}
