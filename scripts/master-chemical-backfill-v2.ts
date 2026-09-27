// Deno admin runner. No service-role credential; only the signed-in System Admin's
// short-lived access token. --dry-run never calls preview INSERT, cache INSERT or apply.
import { isIncompleteMaster } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";

export interface Checkpoint {
  ids: string[];
  completed: Record<string, string>;
  failed: Record<string, string>;
}
export function pendingIds(checkpoint: Checkpoint, retryFailed: boolean): string[] {
  return checkpoint.ids.filter((id) => retryFailed ? id in checkpoint.failed : !(id in checkpoint.completed) && !(id in checkpoint.failed));
}
export async function containRowFailure<T>(work: () => Promise<T>): Promise<{ value: T | null; error: boolean }> {
  try { return { value: await work(), error: false }; }
  catch { return { value: null, error: true }; }
}
/** The signed-in admin apply RPC is inaccessible to the runner's dry-run branch. */
export async function applyPreviewIfExecuting<T>(execute: boolean, previewId: string | null,
  apply: () => Promise<T>): Promise<T | null> {
  return execute && previewId ? await apply() : null;
}
export function selectBackfillRows(rows: MasterRow[], masterId: string | null, limit: number): MasterRow[] {
  return rows.filter((r) => masterId ? r.id === masterId : isIncompleteMaster(r))
    .sort((a, b) => a.id.localeCompare(b.id)).slice(0, limit);
}

async function main(): Promise<void> {
  const args = Deno.args;
  const has = (flag: string) => args.includes(flag);
  const option = (flag: string): string | null => {
    const index = args.indexOf(flag);
    return index < 0 ? null : args[index + 1] ?? null;
  };
  const execute = has("--execute");
  const dryRun = has("--dry-run") || !execute;
  const resume = has("--resume");
  const retryFailed = has("--retry-failed");
  const planFile = option("--plan");
  const checkpointFile = option("--checkpoint") ?? "master-backfill-checkpoint.json";
  const masterId = option("--master-id");
  const limit = Number(option("--limit") ?? "1000");
  if (!Number.isInteger(limit) || limit < 1 || limit > 10000 ||
      (execute && (dryRun || (!planFile && !(has("--all-incomplete") && has("--confirm-all")))) ||
      (resume && !execute) || (retryFailed && !resume) || (has("--use-plan") && !planFile))) {
    throw new Error("Invalid mode. Execute needs --plan FILE or --all-incomplete --confirm-all; --resume requires --execute; --retry-failed requires --resume.");
  }
  const url = (Deno.env.get("V2_SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anon = Deno.env.get("EXPO_PUBLIC_SUPABASE_ANON_KEY") ?? "";
  const token = Deno.env.get("VINETRACK_ADMIN_ACCESS_TOKEN") ?? "";
  if (!url || !anon || !token) throw new Error("Set V2_SUPABASE_URL, EXPO_PUBLIC_SUPABASE_ANON_KEY and VINETRACK_ADMIN_ACCESS_TOKEN (admin user JWT, never service role).");
  const headers = { apikey: anon, Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  // deno-lint-ignore no-explicit-any
  async function request(path: string, payload?: Record<string, unknown>): Promise<any> {
    const res = await fetch(`${url}${path}`, { method: payload ? "POST" : "GET", headers,
      ...(payload ? { body: JSON.stringify(payload) } : {}) });
    if (!res.ok) throw new Error(`HTTP ${res.status} from ${path.split("?")[0]}`);
    return await res.json();
  }
  const admin = await request("/rest/v1/rpc/is_system_admin", {});
  if (admin !== true) throw new Error("The session is not a System Admin; no rows processed.");
  const before = await request("/rest/v1/rpc/master_backfill_catalogue_stats_v2", {});
  console.log("Baseline:", JSON.stringify(before));
  const rows: MasterRow[] = [];
  for (let offset = 0; ; offset += 200) {
    const page = await request(`/rest/v1/master_chemicals?select=*&order=id.asc&limit=200&offset=${offset}`) as MasterRow[];
    rows.push(...page);
    if (page.length < 200) break;
  }
  let selected: MasterRow[];
  let checkpoint: Checkpoint;
  if (resume) {
    checkpoint = JSON.parse(await Deno.readTextFile(checkpointFile)) as Checkpoint;
    selected = checkpoint.ids.map((id) => rows.find((r) => r.id === id)).filter((r): r is MasterRow => !!r);
    if (selected.length !== checkpoint.ids.length) throw new Error("Checkpoint references a missing Master row");
  } else if ((execute || has("--use-plan")) && planFile) {
    const plan = JSON.parse(await Deno.readTextFile(planFile)) as Array<{ id: string; identity: string }>;
    if (!Array.isArray(plan) || !plan.length) throw new Error("The dry-run plan is empty");
    selected = plan.map(({ id, identity }) => {
      const row = rows.find((r) => r.id === id && r.registration_identity_key === identity);
      if (!row) throw new Error(`Planned identity changed or missing: ${id}`);
      return row;
    });
    checkpoint = { ids: selected.map((r) => r.id), completed: {}, failed: {} };
  } else {
    selected = selectBackfillRows(rows, masterId, limit);
    if (masterId && !selected.length) throw new Error("Master id not found");
    checkpoint = { ids: selected.map((r) => r.id), completed: {}, failed: {} };
  }
  if (dryRun && planFile && !has("--use-plan")) {
    // Save the exact ID + identity list so the canary applies the SAME rows.
    await Deno.writeTextFile(planFile, JSON.stringify(selected.map((r) => ({ id: r.id, identity: r.registration_identity_key })), null, 2));
  }
  const queue = resume ? pendingIds(checkpoint, retryFailed) : checkpoint.ids;
  console.log(`${execute ? "APPLY" : "DRY RUN"}: ${queue.length} selected of ${rows.length} Master rows (concurrency 1)`);
  const started = Date.now();
  const counts: Record<string, number> = {};
  for (let i = 0; i < queue.length; i++) {
    const id = queue[i];
    const row = selected.find((r) => r.id === id)!;
    let status = "lookup_unavailable";
    let finalResistanceState = row.resistance_classification_state;
    try {
      const attempt = await containRowFailure(() => request("/functions/v1/chemical-info-lookup", {
        action: "master_backfill_preview_v2", masterChemicalId: id,
        country: row.registration_country, dryRun,
      }));
      if (attempt.error) throw new Error("Lookup unavailable");
      const response = attempt.value;
      status = String(response.status ?? "lookup_unavailable");
      if (response.findings?.no_vineyard_use) counts.no_vineyard_registration = (counts.no_vineyard_registration ?? 0) + 1;
      if (dryRun && response.findings?.classified) { counts.classified = (counts.classified ?? 0) + 1; finalResistanceState = "classified"; }
      if (dryRun && response.findings?.not_applicable) { counts.not_applicable = (counts.not_applicable ?? 0) + 1; finalResistanceState = "not_applicable"; }
      if (dryRun && response.findings?.vineyard_rates_added) counts.vineyard_rates_added = (counts.vineyard_rates_added ?? 0) + 1;
      if (execute && response.preview_id) {
        const result = await applyPreviewIfExecuting(execute, response.preview_id, () => request("/rest/v1/rpc/master_review_apply", {
          p_preview_id: response.preview_id, p_master_id: id,
          p_reason: "Controlled manufacturer-label Master catalogue refill V2",
        }));
        if (!result) throw new Error("Apply did not return a result");
        if (result.status !== "applied" && result.status !== "already_applied") throw new Error("Apply did not confirm success");
        const latest = await request(`/rest/v1/master_chemicals?select=*&id=eq.${encodeURIComponent(id)}&limit=1`) as MasterRow[];
        if (latest.length !== 1 || latest[0].id !== id || latest[0].registration_identity_key !== row.registration_identity_key ||
          latest[0].review_status !== row.review_status || latest[0].catalogue_version !== result.result_revision) throw new Error("Post-apply identity/revision/status verification failed");
        status = "updated";
        finalResistanceState = latest[0].resistance_classification_state;
        if (latest[0].resistance_classification_state === "classified" && row.resistance_classification_state !== "classified") counts.classified = (counts.classified ?? 0) + 1;
        if (latest[0].resistance_classification_state === "not_applicable" && row.resistance_classification_state !== "not_applicable") counts.not_applicable = (counts.not_applicable ?? 0) + 1;
        if (!(row.viticulture_rates?.per_hectare?.length || row.viticulture_rates?.per_100_litres?.length) &&
          (latest[0].viticulture_rates?.per_hectare?.length || latest[0].viticulture_rates?.per_100_litres?.length)) counts.vineyard_rates_added = (counts.vineyard_rates_added ?? 0) + 1;
      }
      if (dryRun && response.proposed_patch) console.log("  Proposed:", JSON.stringify(response.proposed_patch));
    } catch (error) {
      status = execute && status === "preview_ready" ? "apply_failed" : "lookup_unavailable";
      console.error(`${i + 1}/${queue.length} ${row.registered_product_name}: ${error instanceof Error ? error.message : "request failed"}`);
    }
    if (finalResistanceState === "unresolved")
      counts.unresolved_resistance = (counts.unresolved_resistance ?? 0) + 1;
    console.log(`${i + 1}/${queue.length} ${row.registered_product_name} ${status}`);
    counts[status] = (counts[status] ?? 0) + 1;
    if (execute) {
      if (["lookup_unavailable", "apply_failed"].includes(status)) checkpoint.failed[id] = status;
      else { checkpoint.completed[id] = status; delete checkpoint.failed[id]; }
      await Deno.writeTextFile(checkpointFile, JSON.stringify(checkpoint, null, 2));
    }
  }
  const after = await request("/rest/v1/rpc/master_backfill_catalogue_stats_v2", {});
  console.log("Summary:", JSON.stringify({ total_inspected: queue.length,
    already_complete: counts.already_complete ?? 0, updated: counts.updated ?? 0,
    no_material_change: counts.no_material_change ?? 0, preview_ready: counts.preview_ready ?? 0,
    classified: counts.classified ?? 0, not_applicable: counts.not_applicable ?? 0,
    unresolved_resistance: counts.unresolved_resistance ?? 0,
    vineyard_rates_added: counts.vineyard_rates_added ?? 0,
    no_vineyard_registration: counts.no_vineyard_registration ?? 0,
    manufacturer_label_not_found: counts.manufacturer_label_not_found ?? 0,
    identity_conflicts: counts.identity_conflict ?? 0, evidence_conflicts: counts.evidence_conflict ?? 0,
    lookup_failures: counts.lookup_unavailable ?? 0, apply_failures: counts.apply_failed ?? 0,
    elapsed_seconds: Math.round((Date.now() - started) / 1000) }));
  console.log("Catalogue totals:", JSON.stringify(after));
  if (execute) console.log(`Checkpoint: ${checkpointFile}`);
}

if (import.meta.main) main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : "Backfill failed");
  Deno.exitCode = 1;
});
