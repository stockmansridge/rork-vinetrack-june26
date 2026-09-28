// Deno admin runner. No service-role credential; only the signed-in System Admin's
// short-lived access token. --dry-run never calls preview INSERT, cache INSERT or apply.
import { isIncompleteMaster } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";
import type { BackfillPreviewResponse } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill_preview.ts";
import type { IndexFailureReason } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_label_index.ts";

/** Versioned, reviewed dry-run record. A hash covers the entire proposed patch, not just rates. */
const reviewableStatuses = new Set(["preview_ready", "manufacturer_label_not_found", "identity_conflict",
  "evidence_conflict", "no_material_change", "already_complete", "lookup_unavailable"]);

export interface ReviewedRow {
  id: string;
  registration_identity_key: string;
  base_revision: number;
  reviewed_status: string;
  proposed_patch_sha256: string | null;
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number" && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") return `{${Object.keys(value as Record<string, unknown>).sort().map((key) =>
    `${JSON.stringify(key)}:${canonicalJson((value as Record<string, unknown>)[key])}`).join(",")}}`;
  throw new Error("Non-JSON value in reviewed patch");
}

/** SHA-256 of recursively sorted JSON object keys; arrays retain their original order. */
export async function patchFingerprint(patch: unknown): Promise<string> {
  if (!patch || Array.isArray(patch) || typeof patch !== "object") throw new Error("Invalid proposed patch");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalJson(patch)));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function reviewedRow(row: MasterRow, response: BackfillPreviewResponse): Promise<ReviewedRow> {
  const status = response.status;
  const consistent = response.master_chemical_id === row.id && response.registration_identity_key === row.registration_identity_key &&
    response.base_revision === (row.catalogue_version ?? 1);
  if (!consistent) throw new Error(`Dry-run response identity/revision mismatch: ${row.id}`);
  if (!reviewableStatuses.has(status)) throw new Error(`Unrecognized dry-run status: ${row.id}`);
  if (status === "preview_ready" && !response.proposed_patch) throw new Error(`Dry-run missing proposed patch: ${row.id}`);
  return { id: row.id, registration_identity_key: row.registration_identity_key,
    base_revision: row.catalogue_version ?? 1, reviewed_status: status,
    proposed_patch_sha256: status === "preview_ready" ? await patchFingerprint(response.proposed_patch) : null };
}

/** Invalid or old ID-only plans are rejected, never upgraded to writable plans. */
export function parseReviewedPlan(value: unknown): ReviewedRow[] {
  if (!Array.isArray(value) || !value.length) throw new Error("The reviewed dry-run plan is empty or invalid");
  const seen = new Set<string>();
  return value.map((entry: unknown) => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new Error("Invalid reviewed plan row");
    const record = entry as Record<string, unknown>;
    const { id, registration_identity_key: identity, base_revision: revision, reviewed_status: status,
      proposed_patch_sha256: hash } = record;
    if (typeof id !== "string" || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id) || seen.has(id) ||
      typeof identity !== "string" || !identity || !Number.isSafeInteger(revision) || (revision as number) < 1 ||
      typeof status !== "string" || !reviewableStatuses.has(status) ||
      (status === "preview_ready" ? typeof hash !== "string" || !/^[a-f0-9]{64}$/.test(hash) : hash !== null))
      throw new Error(`Invalid reviewed plan row: ${String(id)}`);
    seen.add(id);
    return { id, registration_identity_key: identity, base_revision: revision as number,
      reviewed_status: status, proposed_patch_sha256: hash as string | null };
  });
}

export async function executeReviewedPreview<T>(plan: ReviewedRow, row: MasterRow,
  response: BackfillPreviewResponse, apply: () => Promise<T>): Promise<{ status: string; reason: string | null; result: T | null }> {
  if (plan.reviewed_status !== "preview_ready") return { status: "plan_drift", reason: `not_approved:${plan.reviewed_status}`, result: null };
  const drift = (reason: string) => ({ status: "preview_drift", reason, result: null });
  if (plan.id !== row.id || response.master_chemical_id !== plan.id) return drift("master_id");
  if (plan.registration_identity_key !== row.registration_identity_key || response.registration_identity_key !== plan.registration_identity_key)
    return drift("registration_identity_key");
  if (plan.base_revision !== (row.catalogue_version ?? 1) || response.base_revision !== plan.base_revision) return drift("base_revision");
  if (response.status !== "preview_ready") return drift(`status:${response.status}`);
  if (!response.preview_id || !response.proposed_patch) return drift("missing_preview_or_patch");
  let fingerprint: string;
  try { fingerprint = await patchFingerprint(response.proposed_patch); }
  catch { return drift("invalid_proposed_patch"); }
  if (fingerprint !== plan.proposed_patch_sha256) return drift("proposed_patch_sha256");
  return { status: "preview_ready", reason: null, result: await apply() };
}

const indexedFailureReasons: ReadonlySet<string> = new Set<IndexFailureReason>([
  "candidate_not_approved", "index_request_failed", "no_web_search_evidence",
  "exact_url_not_consulted", "malformed_index_result", "product_identity_mismatch",
  "registration_missing", "active_identity_mismatch", "rate_condition_incomplete", "simanex_completeness_failed",
]);

/** Only reason codes, never free-form evidence or URLs, reach runner logs. */
export function safeDiagnosticReason(response: BackfillPreviewResponse): string | null {
  if (!["evidence_conflict", "identity_conflict", "manufacturer_label_not_found"].includes(response.status)) return null;
  const reason = response.evidence?.reason ?? (Array.isArray(response.evidence?.conflicts) ? response.evidence.conflicts[0] : null);
  if (typeof reason !== "string") return null;
  if (/^[a-z][a-z0-9_]{0,79}$/.test(reason)) return reason;
  if (response.status !== "manufacturer_label_not_found") return null;
  const indexed = /^label_index_unavailable: ([a-z][a-z0-9_]{0,79})$/.exec(reason);
  return indexed?.[0] === reason && indexedFailureReasons.has(indexed[1]) ? reason : null;
}

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
      (execute && (dryRun || !planFile)) ||
      (resume && !execute) || (retryFailed && !resume) || (has("--use-plan") && !planFile)) {
    throw new Error("Invalid mode. Execute needs a reviewed --plan FILE; --resume requires --execute; --retry-failed requires --resume.");
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
  const plan = planFile && (execute || has("--use-plan")) ?
    parseReviewedPlan(JSON.parse(await Deno.readTextFile(planFile))) : null;
  let selected: MasterRow[];
  let checkpoint: Checkpoint;
  if (resume) {
    checkpoint = JSON.parse(await Deno.readTextFile(checkpointFile)) as Checkpoint;
    if (!plan || JSON.stringify(checkpoint.ids) !== JSON.stringify(plan.map((entry) => entry.id)))
      throw new Error("Checkpoint and reviewed plan IDs differ");
    selected = plan.map(({ id }) => rows.find((r) => r.id === id)).filter((r): r is MasterRow => !!r);
    if (selected.length !== plan.length) throw new Error("Plan references a missing Master row");
  } else if (plan) {
    selected = plan.map(({ id }) => rows.find((r) => r.id === id)).filter((r): r is MasterRow => !!r);
    if (selected.length !== plan.length) throw new Error("Plan references a missing Master row");
    checkpoint = { ids: selected.map((r) => r.id), completed: {}, failed: {} };
  } else {
    selected = selectBackfillRows(rows, masterId, limit);
    if (masterId && !selected.length) throw new Error("Master id not found");
    checkpoint = { ids: selected.map((r) => r.id), completed: {}, failed: {} };
  }
  const reviewed: ReviewedRow[] = [];
  // Invalidate an earlier plan before any new extraction; a partial run must not leave stale approval behind.
  if (dryRun && planFile && !has("--use-plan")) await Deno.writeTextFile(planFile, "[]");
  const queue = resume ? pendingIds(checkpoint, retryFailed) : checkpoint.ids;
  console.log(`${execute ? "APPLY" : "DRY RUN"}: ${queue.length} selected of ${rows.length} Master rows (concurrency 1)`);
  const started = Date.now();
  const counts: Record<string, number> = {};
  for (let i = 0; i < queue.length; i++) {
    const id = queue[i];
    const row = selected.find((r) => r.id === id)!;
    let status = "lookup_unavailable";
    let finalResistanceState = row.resistance_classification_state;
    let diagnostic: string | null = null;
    const approved = plan?.find((entry) => entry.id === id);
    try {
      if (execute && approved?.reviewed_status !== "preview_ready") {
        status = "plan_drift";
        diagnostic = approved ? `not_approved:${approved.reviewed_status}` : "missing_plan_row";
      } else if (execute && approved && (approved.registration_identity_key !== row.registration_identity_key ||
        approved.base_revision !== (row.catalogue_version ?? 1))) {
        status = "preview_drift";
        diagnostic = approved.registration_identity_key !== row.registration_identity_key ? "registration_identity_key" : "base_revision";
      } else {
        const attempt = await containRowFailure(() => request("/functions/v1/chemical-info-lookup", {
          action: "master_backfill_preview_v2", master_chemical_id: id, dryRun,
        }));
        if (attempt.error || !attempt.value) throw new Error("Lookup unavailable");
        const response = attempt.value as BackfillPreviewResponse;
        status = String(response.status ?? "lookup_unavailable");
        if (response.findings?.no_vineyard_use) counts.no_vineyard_registration = (counts.no_vineyard_registration ?? 0) + 1;
        if (dryRun && response.findings?.classified) { counts.classified = (counts.classified ?? 0) + 1; finalResistanceState = "classified"; }
        if (dryRun && response.findings?.not_applicable) { counts.not_applicable = (counts.not_applicable ?? 0) + 1; finalResistanceState = "not_applicable"; }
        if (dryRun && response.findings?.vineyard_rates_added) counts.vineyard_rates_added = (counts.vineyard_rates_added ?? 0) + 1;
        if (dryRun && planFile && !has("--use-plan")) reviewed.push(await reviewedRow(row, response));
        diagnostic = safeDiagnosticReason(response);
        if (execute && approved) {
          const checked = await executeReviewedPreview(approved, row, response, () => request("/rest/v1/rpc/master_review_apply", {
            p_preview_id: response.preview_id, p_master_id: id,
            p_reason: "Controlled manufacturer-label Master catalogue refill V2",
          }));
          status = checked.status;
          diagnostic = checked.reason ? `${checked.reason}${diagnostic ? ` (${diagnostic})` : ""}` : diagnostic;
          const result = checked.result;
          if (status === "preview_ready" && !result) throw new Error("Apply did not return a result");
          if (result) {
            if (result.status !== "applied" && result.status !== "already_applied") throw new Error("Apply did not confirm success");
            const latest = await request(`/rest/v1/master_chemicals?select=*&id=eq.${encodeURIComponent(id)}&limit=1`) as MasterRow[];
            if (latest.length !== 1 || latest[0].id !== id || latest[0].registration_identity_key !== row.registration_identity_key ||
              latest[0].review_status !== row.review_status || latest[0].catalogue_version !== result.result_revision)
              throw new Error("Post-apply identity/revision/status verification failed");
            status = "updated";
            finalResistanceState = latest[0].resistance_classification_state;
            if (latest[0].resistance_classification_state === "classified" && row.resistance_classification_state !== "classified") counts.classified = (counts.classified ?? 0) + 1;
            if (latest[0].resistance_classification_state === "not_applicable" && row.resistance_classification_state !== "not_applicable") counts.not_applicable = (counts.not_applicable ?? 0) + 1;
            if (!(row.viticulture_rates?.per_hectare?.length || row.viticulture_rates?.per_100_litres?.length) &&
              (latest[0].viticulture_rates?.per_hectare?.length || latest[0].viticulture_rates?.per_100_litres?.length)) counts.vineyard_rates_added = (counts.vineyard_rates_added ?? 0) + 1;
          }
        }
        if (dryRun && response.proposed_patch) console.log("  Proposed:", JSON.stringify(response.proposed_patch));
      }
    } catch (error) {
      status = execute && status === "preview_ready" ? "apply_failed" : "lookup_unavailable";
      console.error(`${i + 1}/${queue.length} ${row.registered_product_name}: ${error instanceof Error ? error.message : "request failed"}`);
    }
    if (finalResistanceState === "unresolved")
      counts.unresolved_resistance = (counts.unresolved_resistance ?? 0) + 1;
    console.log(`${i + 1}/${queue.length} ${row.registered_product_name} ${status}${diagnostic ? `: ${diagnostic}` : ""}`);
    counts[status] = (counts[status] ?? 0) + 1;
    if (execute) {
      if (["lookup_unavailable", "apply_failed", "preview_drift", "plan_drift"].includes(status)) checkpoint.failed[id] = status;
      else { checkpoint.completed[id] = status; delete checkpoint.failed[id]; }
      await Deno.writeTextFile(checkpointFile, JSON.stringify(checkpoint, null, 2));
    }
  }
  if (dryRun && planFile && !has("--use-plan")) {
    if (reviewed.length !== selected.length) throw new Error("Incomplete dry-run: reviewed plan not written");
    await Deno.writeTextFile(planFile, JSON.stringify(reviewed, null, 2));
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
    preview_drift: counts.preview_drift ?? 0, plan_drift: counts.plan_drift ?? 0,
    elapsed_seconds: Math.round((Date.now() - started) / 1000) }));
  console.log("Catalogue totals:", JSON.stringify(after));
  if (execute) console.log(`Checkpoint: ${checkpointFile}`);
}

if (import.meta.main) main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : "Backfill failed");
  Deno.exitCode = 1;
});
