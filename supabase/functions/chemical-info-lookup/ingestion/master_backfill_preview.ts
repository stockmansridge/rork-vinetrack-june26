import type { MasterRow, Jsonish } from "./contract.ts";
import { readManufacturerLabelViaWebIndex, type IndexedLabelInput, type IndexFailureReason } from "./manufacturer_label_index.ts";
import type { IndexedLabelSnapshot } from "./manufacturer_label_snapshot.ts";
import { buildCurrentSnapshot, type PreviewStore } from "./review_preview.ts";
import { authoritativeBackfillDetail, buildMasterBackfillPatch, lockedWebIdentity, storeBackfillPreview, type BackfillDetail } from "./master_backfill.ts";
import { classifyUrl, manufacturerHostEligible } from "../research/classify.ts";

/** Only the Master UUID selects an identity. Legacy country is ignored, never used to redirect research. */
export function parseBackfillRequest(body: Record<string, unknown>): { masterId: string; dryRun: boolean; capture: boolean } | { error: string } {
  const allowed = new Set(["action", "master_chemical_id", "masterChemicalId", "dryRun", "country", "capture_indexed_response"]);
  if (Object.keys(body).some((key) => !allowed.has(key))) return { error: "Backfill accepts only a Master id and dryRun" };
  if (body.master_chemical_id !== undefined && body.masterChemicalId !== undefined && body.master_chemical_id !== body.masterChemicalId)
    return { error: "Conflicting Master ids" };
  const masterId = body.master_chemical_id ?? body.masterChemicalId;
  if (typeof masterId !== "string" || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(masterId))
    return { error: "Invalid Master id" };
  if (body.dryRun !== undefined && typeof body.dryRun !== "boolean") return { error: "Invalid dryRun" };
  if (body.capture_indexed_response !== undefined && body.capture_indexed_response !== true)
    return { error: "Invalid capture mode" };
  if (body.capture_indexed_response === true && body.master_chemical_id !== undefined && body.masterChemicalId !== undefined)
    return { error: "Capture requires exactly one Master id" };
  return { masterId, dryRun: body.dryRun === true, capture: body.capture_indexed_response === true };
}

/** Both the JWT-backed admin RPC and authenticated user id must succeed before any Master lookup. */
export function authorizeBackfillRequest(body: Record<string, unknown>, isAdmin: boolean, userId: string | null) {
  const parsed = parseBackfillRequest(body);
  return "error" in parsed ? parsed : !isAdmin || !userId ? { error: "Not authorised" } : parsed;
}

/** Locked registration jurisdiction is the sole authority, regardless of any legacy request country. */
export function backfillCountry(row: MasterRow): string {
  return row.registration_country;
}

export interface BackfillPreviewResponse {
  status: string;
  master_chemical_id: string;
  registration_identity_key: string;
  base_revision: number;
  review_status: string;
  current: Record<string, Jsonish>;
  proposed_patch: Record<string, Jsonish> | null;
  preview_id: string | null;
  expires_at: string | null;
  evidence: Record<string, unknown>;
  findings: { classified: boolean; not_applicable: boolean; vineyard_rates_added: boolean; no_vineyard_use: boolean };
  dry_run?: true;
  indexed_diagnostic?: { snapshot: IndexedLabelSnapshot | null; outcome: "captured" | "no_indexed_response" };
  private_fetch_diagnostic?: Record<string, unknown>;
  error?: string;
}

export interface BackfillResearchPayload {
  detail?: BackfillDetail | null;
  identity_conflict?: { printed?: string | null; manufacturer_label_url?: string | null; reason?: string };
  discovery_reason?: "search_no_candidate" | "search_timeout" | "host_not_verified" | "product_page_fetch_failed" |
    "product_name_mismatch" | "label_link_not_found" | "label_fetch_failed" | `label_fetch_failed_${string}` |
    `label_fetch_http_${number}` | "label_unreadable" | "label_table_binding_unresolved" | "label_index_unavailable" |
    `label_index_unavailable: ${IndexFailureReason}`;
}

/** Keep conditional grape harvest intervals unresolved after the structured-response normaliser. */
export function markConditionalGrapeWithholding(detail: {
  registered_uses: Array<Record<string, unknown>>;
  verification: { unresolved_fields: string[] };
}, pairedDirections: boolean): void {
  if (!pairedDirections || !detail.registered_uses.some((use) => /grape/i.test(String(use.crop ?? "")) &&
    use.withholding_statement && use.withholding_period_days == null)) return;
  detail.verification.unresolved_fields = [...new Set([
    ...(detail.verification.unresolved_fields ?? []), "withholding_period:GRAPEVINE",
  ])];
}

/** Same indexed read and validator as the ordinary Master dry run; capture is local to this invocation. */
export async function readBackfillIndexedLabel(input: IndexedLabelInput, master: { id: string; revision: number },
  capture: boolean) {
  let snapshot: IndexedLabelSnapshot | null = null;
  const result = await readManufacturerLabelViaWebIndex({ ...input,
    onDiagnosticSnapshot: capture ? (value) => {
      value.master = master;
      snapshot = value;
    } : undefined });
  return { result, snapshot };
}

/** Diagnostic data is returned only for an explicitly authorised opt-in request, never stored as a preview. */
export function withIndexedDiagnostic(response: BackfillPreviewResponse, capture: boolean,
  snapshot: IndexedLabelSnapshot | null, fetchDiagnostic: Record<string, unknown> | null = null): BackfillPreviewResponse {
  return capture ? { ...response, indexed_diagnostic: { snapshot,
    outcome: snapshot ? "captured" : "no_indexed_response" },
    ...(fetchDiagnostic ? { private_fetch_diagnostic: fetchDiagnostic } : {}) } : response;
}

function baseResponse(row: MasterRow): BackfillPreviewResponse {
  return { status: "no_material_change", master_chemical_id: row.id,
    registration_identity_key: row.registration_identity_key, base_revision: row.catalogue_version ?? 1,
    review_status: row.review_status, current: buildCurrentSnapshot(row), proposed_patch: null,
    preview_id: null, expires_at: null,
    evidence: { locked_identity: row.registration_identity_key, reported_registration_number: null,
      manufacturer_label_url: null, conflicts: [] },
    findings: { classified: false, not_applicable: false, vineyard_rates_added: false,
      no_vineyard_use: !(row.registered_uses ?? []).some((use) => /grape|vineyard|vine/i.test(String(use.crop ?? ""))) } };
}

/** Non-writable complete state, with the same identity/revision envelope as a reviewable preview. */
export function alreadyCompleteBackfill(row: MasterRow): BackfillPreviewResponse {
  return { ...baseResponse(row), status: "already_complete" };
}

/** The only side effect is an admin-bound preview insertion; applying remains a separate audited RPC. */
export async function finishBackfillPreview(row: MasterRow, adminId: string, payload: BackfillResearchPayload | null,
  dryRun: boolean, store: Pick<PreviewStore, "insertPreview">, classificationOnly = false): Promise<BackfillPreviewResponse> {
  const base = baseResponse(row);
  if (!lockedWebIdentity(row)) return { ...base, status: "identity_conflict",
    evidence: { ...base.evidence, reason: "locked_master_identity_invalid" } };
  if (payload?.identity_conflict) return { ...base, status: "identity_conflict", evidence: {
    ...base.evidence, reported_registration_number: payload.identity_conflict.printed ?? null,
    manufacturer_label_url: payload.identity_conflict.manufacturer_label_url ?? null,
    reason: payload.identity_conflict.reason ?? "manufacturer_product_identity_mismatch",
    conflicts: [payload.identity_conflict.reason ?? "manufacturer_product_identity_mismatch"] } };
  const detail = payload?.detail ?? authoritativeBackfillDetail(row);
  const proposed = buildMasterBackfillPatch(row, detail);
  const findings = { classified: proposed.patch?.resistance_classification_state === "classified",
    not_applicable: proposed.patch?.resistance_classification_state === "not_applicable",
    vineyard_rates_added: Boolean(proposed.patch?.viticulture_rates),
    no_vineyard_use: !payload?.discovery_reason && !(detail.registered_uses ?? row.registered_uses ?? []).some((use) =>
      /grape|vineyard|vine/i.test(String(use.crop ?? ""))) };
  const response = { ...base, status: proposed.status, evidence: proposed.evidence, findings };
  if (proposed.status === "identity_conflict" || proposed.status === "evidence_conflict") return response;
  // A failed label search is not a reviewable manufacturer-label preview. A wholly
  // deterministic classification-only result may still be reviewed separately.
  const label = detail.registration?.manufacturer_label_url;
  if (!classificationOnly && (!label || !manufacturerHostEligible(label, backfillCountry(row), row.registrant) ||
    !(classifyUrl(label, backfillCountry(row)).trust === "registrant" &&
      classifyUrl(label, backfillCountry(row)).kind === "label_document" ||
      detail.registration?.manufacturer_label_verified === true && new URL(label).pathname.toLowerCase().endsWith(".pdf")))) return {
    ...response, status: "manufacturer_label_not_found",
    evidence: { ...response.evidence, reason: payload?.discovery_reason ?? "host_not_verified" } };
  if (!proposed.patch) return response;
  if (dryRun) return { ...response, status: "preview_ready", proposed_patch: proposed.patch, dry_run: true };
  const stored = await storeBackfillPreview(false, () => store.insertPreview({ master_chemical_id: row.id,
    base_revision: row.catalogue_version ?? 1, outcome: "material_change", proposed_patch: proposed.patch!,
    changes: [], requested_by: adminId }));
  if (!stored?.id) return { ...response, error: "preview_store_failed" };
  return { ...response, status: "preview_ready", proposed_patch: proposed.patch,
    preview_id: stored.id, expires_at: stored.expires_at ?? null };
}
