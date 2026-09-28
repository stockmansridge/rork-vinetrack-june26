import type { MasterRow, Jsonish } from "./contract.ts";
import { buildCurrentSnapshot, type PreviewStore } from "./review_preview.ts";
import { authoritativeBackfillDetail, buildMasterBackfillPatch, lockedWebIdentity, storeBackfillPreview, type BackfillDetail } from "./master_backfill.ts";
import { classifyUrl } from "../research/classify.ts";

/** Only the Master UUID selects an identity. Legacy country is ignored, never used to redirect research. */
export function parseBackfillRequest(body: Record<string, unknown>): { masterId: string; dryRun: boolean } | { error: string } {
  const allowed = new Set(["action", "master_chemical_id", "masterChemicalId", "dryRun", "country"]);
  if (Object.keys(body).some((key) => !allowed.has(key))) return { error: "Backfill accepts only a Master id and dryRun" };
  if (body.master_chemical_id !== undefined && body.masterChemicalId !== undefined && body.master_chemical_id !== body.masterChemicalId)
    return { error: "Conflicting Master ids" };
  const masterId = body.master_chemical_id ?? body.masterChemicalId;
  if (typeof masterId !== "string" || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(masterId))
    return { error: "Invalid Master id" };
  if (body.dryRun !== undefined && typeof body.dryRun !== "boolean") return { error: "Invalid dryRun" };
  return { masterId, dryRun: body.dryRun === true };
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
  error?: string;
}

export interface BackfillResearchPayload {
  detail?: BackfillDetail | null;
  identity_conflict?: { printed?: string | null; manufacturer_label_url?: string | null; reason?: string };
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
  if (!lockedWebIdentity(row)) return { ...base, status: "identity_conflict" };
  if (payload?.identity_conflict) return { ...base, status: "identity_conflict", evidence: {
    ...base.evidence, reported_registration_number: payload.identity_conflict.printed ?? null,
    manufacturer_label_url: payload.identity_conflict.manufacturer_label_url ?? null,
    conflicts: [payload.identity_conflict.reason ?? "manufacturer_product_identity_mismatch"] } };
  const detail = payload?.detail ?? authoritativeBackfillDetail(row);
  const proposed = buildMasterBackfillPatch(row, detail);
  const findings = { classified: proposed.patch?.resistance_classification_state === "classified",
    not_applicable: proposed.patch?.resistance_classification_state === "not_applicable",
    vineyard_rates_added: Boolean(proposed.patch?.viticulture_rates),
    no_vineyard_use: !(detail.registered_uses ?? row.registered_uses ?? []).some((use) =>
      /grape|vineyard|vine/i.test(String(use.crop ?? ""))) };
  const response = { ...base, status: proposed.status, evidence: proposed.evidence, findings };
  if (proposed.status === "identity_conflict" || proposed.status === "evidence_conflict") return response;
  // A failed label search is not a reviewable manufacturer-label preview. A wholly
  // deterministic classification-only result may still be reviewed separately.
  const label = detail.registration?.manufacturer_label_url;
  if (!classificationOnly && (!label || classifyUrl(label, backfillCountry(row)).trust !== "registrant" ||
    classifyUrl(label, backfillCountry(row)).kind !== "label_document")) return {
    ...response, status: "manufacturer_label_not_found" };
  if (!proposed.patch) return response;
  if (dryRun) return { ...response, status: "preview_ready", proposed_patch: proposed.patch, dry_run: true };
  const stored = await storeBackfillPreview(false, () => store.insertPreview({ master_chemical_id: row.id,
    base_revision: row.catalogue_version ?? 1, outcome: "material_change", proposed_patch: proposed.patch!,
    changes: [], requested_by: adminId }));
  if (!stored?.id) return { ...response, error: "preview_store_failed" };
  return { ...response, status: "preview_ready", proposed_patch: proposed.patch,
    preview_id: stored.id, expires_at: stored.expires_at ?? null };
}
