// Single-Master stored review handoff. Preparation stores ONLY a pending preview;
// inspect is read-only; apply alone invokes the audited Master-writing RPC.
// deno run --allow-env --allow-net --allow-read --allow-write scripts/master-stored-review.ts prepare --master-id UUID --manifest review.json --report report.json [--diagnostic failure.json] [--evidence-file unsigned.json --document label.pdf --expected-identity AU:apvma:53576]
// deno run --allow-env --allow-net --allow-read scripts/master-stored-review.ts inspect --manifest review.json
// deno run --allow-env --allow-net --allow-read scripts/master-stored-review.ts apply --manifest review.json --reason "Reviewed label and directions"
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";
import type { BackfillPreviewResponse } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill_preview.ts";
import { patchFingerprint, safeDiagnosticReason, saveIndexedDiagnostic } from "./master-chemical-backfill-v2.ts";

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const sha256 = /^[a-f0-9]{64}$/;

export interface StoredReviewManifest {
  preview_id: string;
  master_chemical_id: string;
  registration_identity_key: string;
  base_revision: number;
  expires_at: string;
  review_status: string;
  proposed_patch_sha256: string;
}

export interface StoredReviewPreview {
  id: string;
  master_chemical_id: string;
  base_revision: number;
  requested_by: string;
  expires_at: string;
  consumed_at: string | null;
  proposed_patch: Record<string, unknown>;
}

/** Only the preview endpoint receives the confirmed cover; no apply or dry-run flags are accepted here. */
export function preparationRequest(id: string, diagnostic: boolean,
  visualDeclaration?: Record<string, unknown>): Record<string, unknown> {
  return { action: "master_backfill_preview_v2", master_chemical_id: id,
    ...(diagnostic ? { capture_indexed_response: true } : {}),
    ...(visualDeclaration ? { reviewed_visual_declaration: visualDeclaration } : {}) };
}

export interface ReviewApi {
  currentUser(): Promise<string>;
  master(id: string): Promise<MasterRow>;
  prepare(id: string, diagnostic: boolean, visualDeclaration?: Record<string, unknown>): Promise<BackfillPreviewResponse>;
  stored(id: string): Promise<StoredReviewPreview>;
  apply(id: string, masterId: string, reason: string): Promise<{ status: string; result_revision: number }>;
}

function validManifest(value: unknown): asserts value is StoredReviewManifest {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid review manifest");
  const v = value as Record<string, unknown>;
  if (!uuid.test(String(v.preview_id ?? "")) || !uuid.test(String(v.master_chemical_id ?? "")) ||
    typeof v.registration_identity_key !== "string" || !v.registration_identity_key ||
    !Number.isSafeInteger(v.base_revision) || (v.base_revision as number) < 1 ||
    typeof v.expires_at !== "string" || !Number.isFinite(Date.parse(v.expires_at)) ||
    typeof v.review_status !== "string" || !v.review_status ||
    !sha256.test(String(v.proposed_patch_sha256 ?? ""))) throw new Error("Invalid review manifest");
}

/** Read the actual server-stored patch; neither report nor manifest contains writable evidence. */
export async function inspectStoredReview(api: ReviewApi, manifest: StoredReviewManifest,
  now: () => number = Date.now): Promise<{ manifest: StoredReviewManifest; patch: Record<string, unknown>;
    current: Record<string, unknown>; proposed_effective: Record<string, unknown>; pending: boolean }> {
  validManifest(manifest);
  const [owner, master, stored] = await Promise.all([
    api.currentUser(), api.master(manifest.master_chemical_id), api.stored(manifest.preview_id),
  ]);
  if (!owner || stored.requested_by !== owner || stored.id !== manifest.preview_id ||
    stored.master_chemical_id !== manifest.master_chemical_id || master.id !== manifest.master_chemical_id ||
    master.registration_identity_key !== manifest.registration_identity_key ||
    stored.base_revision !== manifest.base_revision || stored.expires_at !== manifest.expires_at ||
    master.review_status !== manifest.review_status || !stored.proposed_patch ||
    await patchFingerprint(stored.proposed_patch) !== manifest.proposed_patch_sha256)
    throw new Error("Stored proposal, owner, identity or reviewed hash differs; explicit re-review required");
  const pending = stored.consumed_at === null && Date.parse(stored.expires_at) > now() &&
    (master.catalogue_version ?? 1) === stored.base_revision;
  const fields = ["registered_uses", "viticulture_rates", "verification_sources", "active_ingredients",
    "activity_groups", "resistance_classification_state", "label_rate_bases", "verification_unresolved_fields"] as const;
  const current = Object.fromEntries(fields.map((key) => [key, master[key] ?? null]));
  const proposed_effective = Object.fromEntries(fields.map((key) => [key, stored.proposed_patch[key] ?? current[key]]));
  return { manifest, patch: stored.proposed_patch, current, proposed_effective, pending };
}

/** Accept only an unsigned transcription of the locally hash-matched document after a separate human confirmation. */
export async function confirmCoverEvidence(raw: unknown, document: Uint8Array, answer: string | null): Promise<Record<string, unknown>> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("Invalid unsigned cover evidence");
  const v = raw as Record<string, unknown>;
  if (v.status !== "awaiting_authenticated_admin_review" || v.confirm_review !== false ||
    v.reviewed_by !== null || v.reviewed_at !== null || v.method !== "human_visual_transcription" ||
    typeof v.document_sha256 !== "string" || !sha256.test(v.document_sha256) ||
    typeof v.source_url !== "string" || !v.source_url.startsWith("https://") ||
    !Number.isInteger(v.physical_page) || (v.physical_page as number) < 1 ||
    typeof v.location !== "string" || typeof v.verbatim !== "string" ||
    !v.active || typeof v.active !== "object" || Array.isArray(v.active) ||
    typeof v.formulation !== "string" || !(v.document_version === null || typeof v.document_version === "string"))
    throw new Error("Evidence must be the unsigned cover candidate, not a pre-approved or synthetic reviewer");
  const bytes = new Uint8Array(document.byteLength);
  bytes.set(document);
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes.buffer)),
    (byte) => byte.toString(16).padStart(2, "0")).join("");
  if (hash !== v.document_sha256) throw new Error("Local label PDF hash differs from unsigned cover evidence");
  if (answer !== `CONFIRM COVER ${v.document_sha256}`) throw new Error("Cover transcription not confirmed; no preparation request sent");
  const active = v.active as Record<string, unknown>;
  return { confirm_review: true, document_sha256: v.document_sha256, source_url: v.source_url,
    physical_page: v.physical_page, location: v.location, verbatim: v.verbatim,
    active: { name: active.name, salt_form: active.salt_form, concentration: active.concentration, unit: active.unit },
    formulation: v.formulation, method: v.method, document_version: v.document_version };
}

/** One lookup, then read back and hash the stored proposal (not the response display copy). */
export async function prepareStoredReview(api: ReviewApi, id: string, diagnostic = false,
  visualDeclaration?: Record<string, unknown>, expectedIdentity?: string): Promise<{
  manifest: StoredReviewManifest | null; report: Record<string, unknown>; response: BackfillPreviewResponse;
}> {
  if (!uuid.test(id)) throw new Error("Exactly one valid Master ID is required");
  const owner = await api.currentUser();
  if (!owner) throw new Error("System Admin session required");
  const row = await api.master(id);
  if (expectedIdentity && row.registration_identity_key !== expectedIdentity)
    throw new Error("Live Master registration identity differs from requested chemical; no preparation request sent");
  const response = await api.prepare(id, diagnostic, visualDeclaration);
  const report: Record<string, unknown> = { status: response.status, master_chemical_id: id,
    registration_identity_key: row.registration_identity_key, base_revision: row.catalogue_version ?? 1,
    review_status: row.review_status, evidence: response.evidence, findings: response.findings,
    reason: safeDiagnosticReason(response), preview_pending_only: true, master_changed: false,
    ...(diagnostic && response.private_fetch_diagnostic ? { private_fetch_diagnostic: response.private_fetch_diagnostic } : {}) };
  if (response.master_chemical_id !== id || response.registration_identity_key !== row.registration_identity_key ||
    response.base_revision !== (row.catalogue_version ?? 1) || response.review_status !== row.review_status)
    throw new Error("Preparation identity/revision mismatch; explicit re-review required");
  if (response.status !== "preview_ready" || !response.preview_id || !uuid.test(response.preview_id) ||
    !response.proposed_patch || !response.expires_at) {
    if (response.preview_id) throw new Error("Failed validation unexpectedly returned writable preview");
    return { manifest: null, report, response };
  }
  const stored = await api.stored(response.preview_id);
  const manifest: StoredReviewManifest = { preview_id: stored.id, master_chemical_id: id,
    registration_identity_key: row.registration_identity_key, base_revision: row.catalogue_version ?? 1,
    expires_at: stored.expires_at, review_status: row.review_status,
    proposed_patch_sha256: await patchFingerprint(stored.proposed_patch) };
  if (await patchFingerprint(response.proposed_patch) !== manifest.proposed_patch_sha256)
    throw new Error("Stored proposal differs from prepared display copy; explicit re-review required");
  const inspected = await inspectStoredReview(api, manifest);
  if (!inspected.pending) throw new Error("New preview is not pending; explicit re-review required");
  return { manifest, report: { ...report, manifest, proposed_patch: inspected.patch }, response };
}

/** No discovery or preview creation: only the existing audited RPC can mutate Master. */
export async function applyStoredReview(api: ReviewApi, manifest: StoredReviewManifest, reason: string): Promise<{
  status: string; result_revision: number;
}> {
  if (!reason.trim()) throw new Error("A review reason is required");
  const inspected = await inspectStoredReview(api, manifest);
  if (!inspected.pending) throw new Error("Preview consumed, expired or stale; explicit re-review required");
  const result = await api.apply(manifest.preview_id, manifest.master_chemical_id, reason);
  if (result.status !== "applied" && result.status !== "already_applied")
    throw new Error("Apply did not confirm success; inspect audited state before retrying");
  return result;
}

export function parseStoredReviewArgs(args: string[]): { mode: "prepare" | "inspect" | "apply";
  id?: string; manifest: string; report?: string; diagnostic?: string; reason?: string;
  evidenceFile?: string; document?: string; expectedIdentity?: string } {
  const [mode, ...rest] = args;
  if (mode !== "prepare" && mode !== "inspect" && mode !== "apply") throw new Error("Expected prepare, inspect or apply");
  const allowed = mode === "prepare" ? ["--master-id", "--manifest", "--report", "--diagnostic", "--evidence-file", "--document", "--expected-identity"] :
    mode === "inspect" ? ["--manifest"] : ["--manifest", "--reason"];
  const options = new Map<string, string>();
  for (let i = 0; i < rest.length; i += 2) {
    if (!allowed.includes(rest[i]) || options.has(rest[i]) || !rest[i + 1] || rest[i + 1].startsWith("--"))
      throw new Error("Invalid or incompatible review option");
    options.set(rest[i], rest[i + 1]);
  }
  const manifest = options.get("--manifest");
  const id = options.get("--master-id");
  const report = options.get("--report");
  const reason = options.get("--reason");
  if (!manifest || mode === "prepare" && (!id || !uuid.test(id) || !report || report === manifest ||
    options.get("--diagnostic") === manifest || options.get("--diagnostic") === report) ||
    Boolean(options.get("--evidence-file")) !== Boolean(options.get("--document")) ||
    mode === "apply" && !reason?.trim()) throw new Error("Missing required review option");
  return { mode, manifest, ...(id ? { id } : {}), ...(report ? { report } : {}),
    ...(options.get("--diagnostic") ? { diagnostic: options.get("--diagnostic") } : {}), ...(reason ? { reason } : {}),
    ...(options.get("--evidence-file") ? { evidenceFile: options.get("--evidence-file") } : {}),
    ...(options.get("--document") ? { document: options.get("--document") } : {}),
    ...(options.get("--expected-identity") ? { expectedIdentity: options.get("--expected-identity") } : {}) };
}

async function main(): Promise<void> {
  const options = parseStoredReviewArgs(Deno.args);
  const url = (Deno.env.get("V2_SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anon = Deno.env.get("EXPO_PUBLIC_SUPABASE_ANON_KEY") ?? "";
  const token = Deno.env.get("VINETRACK_ADMIN_ACCESS_TOKEN") ?? "";
  if (!url || !anon || !token) throw new Error("Set V2_SUPABASE_URL, EXPO_PUBLIC_SUPABASE_ANON_KEY and VINETRACK_ADMIN_ACCESS_TOKEN (admin JWT)");
  const headers = { apikey: anon, Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  async function request(path: string, body?: Record<string, unknown>): Promise<unknown> {
    const response = await fetch(`${url}${path}`, { method: body ? "POST" : "GET", headers,
      ...(body ? { body: JSON.stringify(body) } : {}) });
    if (!response.ok) throw new Error(`HTTP ${response.status} from ${path.split("?")[0]}; explicit re-review required`);
    return await response.json();
  }
  if (await request("/rest/v1/rpc/is_system_admin", {}) !== true) throw new Error("System Admin session required");
  const api: ReviewApi = {
    currentUser: async () => {
      const user = await request("/auth/v1/user") as { id?: string };
      return user.id ?? "";
    },
    master: async (id) => {
      const rows = await request(`/rest/v1/master_chemicals?select=*&id=eq.${encodeURIComponent(id)}&limit=1`) as MasterRow[];
      if (rows.length !== 1 || rows[0].id !== id) throw new Error("Master row not found");
      return rows[0];
    },
    prepare: (id, diagnostic, visualDeclaration) => request("/functions/v1/chemical-info-lookup",
      preparationRequest(id, diagnostic, visualDeclaration)) as Promise<BackfillPreviewResponse>,
    stored: async (id) => {
      const rows = await request(`/rest/v1/master_review_previews?select=id,master_chemical_id,base_revision,requested_by,expires_at,consumed_at,proposed_patch&id=eq.${encodeURIComponent(id)}&limit=1`) as StoredReviewPreview[];
      if (rows.length !== 1) throw new Error("Stored preview unavailable; explicit re-review required");
      return rows[0];
    },
    apply: (id, masterId, reason) => request("/rest/v1/rpc/master_review_apply", {
      p_preview_id: id, p_master_id: masterId, p_reason: reason,
    }) as Promise<{ status: string; result_revision: number }>,
  };
  if (options.mode === "prepare") {
    let declaration: Record<string, unknown> | undefined;
    if (options.evidenceFile && options.document) {
      const raw: unknown = JSON.parse(await Deno.readTextFile(options.evidenceFile));
      const candidate = raw as Record<string, unknown>;
      const document = await Deno.readFile(options.document);
      // Validate the hash and unsigned state before showing the cover or prompting.
      await confirmCoverEvidence(raw, document, null).catch((error: unknown) => {
        if (!(error instanceof Error) || !error.message.startsWith("Cover transcription not confirmed")) throw error;
      });
      if (!Deno.stdin.isTerminal()) throw new Error("Interactive admin cover review required; no preparation request sent");
      console.log(JSON.stringify({ cover_image: candidate.cover_attachment ?? null, document: options.document,
        source_url: candidate.source_url, document_sha256: candidate.document_sha256,
        physical_page: candidate.physical_page, location: candidate.location, verbatim: candidate.verbatim,
        active: candidate.active, formulation: candidate.formulation, document_version: candidate.document_version }, null, 2));
      console.log("Open the cover image and compare the displayed transcription to the PDF. This confirms ONLY cover evidence, not the Master proposal.");
      declaration = await confirmCoverEvidence(raw, document, prompt(`Type CONFIRM COVER ${candidate.document_sha256} to attest, or cancel:`));
    }
    const { manifest, report, response } = await prepareStoredReview(api, options.id!, !!options.diagnostic,
      declaration, options.expectedIdentity);
    // Never overwrite an earlier approval or report. Keep evidence in the private report, not stdout.
    const reportHandle = await Deno.open(options.report!, { createNew: true, write: true, mode: 0o600 });
    try { await reportHandle.write(new TextEncoder().encode(JSON.stringify(report, null, 2))); }
    finally { reportHandle.close(); }
    if (options.diagnostic && response.indexed_diagnostic?.snapshot) {
      const saved = await saveIndexedDiagnostic(response, options.id!, response.base_revision, options.diagnostic);
      console.log(`Diagnostic saved: ${saved.file} complete=${saved.complete} validation=${saved.validation}`);
    }
    if (!manifest) {
      console.log(`No writable preview: ${response.status}${safeDiagnosticReason(response) ? ` (${safeDiagnosticReason(response)})` : ""}. Report: ${options.report}`);
      Deno.exitCode = 1;
      return;
    }
    const manifestHandle = await Deno.open(options.manifest, { createNew: true, write: true, mode: 0o600 });
    try { await manifestHandle.write(new TextEncoder().encode(JSON.stringify(manifest, null, 2))); }
    finally { manifestHandle.close(); }
    console.log(`Pending preview only; Master unchanged. Manifest: ${options.manifest}; report: ${options.report}`);
  } else {
    const manifest: unknown = JSON.parse(await Deno.readTextFile(options.manifest));
    validManifest(manifest);
    if (options.mode === "inspect") console.log(JSON.stringify(await inspectStoredReview(api, manifest), null, 2));
    else console.log(JSON.stringify(await applyStoredReview(api, manifest, options.reason!), null, 2));
  }
}

if (import.meta.main) main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : "Review failed");
  Deno.exitCode = 1;
});
