// deno-lint-ignore-file no-explicit-any
import type { MasterRow } from "./contract.ts";
import { applyDefaultRateOptions } from "../default_rate_options.ts";
import { buildMasterStructuredResponse, masterHasExactHydrationReadiness } from "./master_lookup.ts";
import { manufacturerEvidenceInvalidated, refreshSourceRole, trustedRetainedManufacturerDocument } from "./retained_manufacturer_evidence.ts";
import { verifyReviewedVisualDeclaration } from "./reviewed_visual_evidence.ts";
import { validateResolverPatch, type PreviewStore } from "./review_preview.ts";

export const WEEDMASTER_ID = "03dfb9e8-6592-4746-a3bc-295890d32cd1";
export const WEEDMASTER_LABEL = "https://cdn.nufarm.com/wp-content/uploads/sites/22/2018/05/13085258/0533-Nufarm-Weedmaster-DUO-Herbicide.pdf";
export const WEEDMASTER_SHA256 = "69213c077e191e99682e515884d7667156367ea7ab927ecdac2882f4d0ec39b8";
const VERSION = "08-09-2022";
const PHALARIS = "rate_v1_4efec198ead373a3286939ced245fadf";

/** Evidence-only repair derived from database history, not a client declaration or a re-extraction. */
export function buildWeedmasterEvidenceRestorePatch(current: MasterRow, history: any[], sourceRevision: number): Record<string, any> {
  if (current.id !== WEEDMASTER_ID || current.review_status !== "candidate" ||
    current.registration_identity_key !== "AU:apvma:53576" || current.registration_country !== "AU" ||
    current.registration_scheme !== "apvma" || current.registration_number !== "53576") throw new Error("repair_identity_refused");
  if (!Number.isInteger(sourceRevision) || sourceRevision < 1 || sourceRevision >= current.catalogue_version ||
    history.length !== current.catalogue_version - sourceRevision + 1) throw new Error("repair_history_incomplete");
  for (let index = 0; index < history.length; index++) {
    const version = history[index];
    if (version.master_chemical_id !== current.id || version.catalogue_version !== sourceRevision + index ||
      version.snapshot?.id !== current.id || version.snapshot?.registration_identity_key !== current.registration_identity_key)
      throw new Error("repair_history_identity_refused");
    if ((version.snapshot.verification_sources ?? []).some((source: any) =>
      source.reference === WEEDMASTER_LABEL && manufacturerEvidenceInvalidated(source))) throw new Error("repair_evidence_invalidated");
  }
  if ((current.verification_sources ?? []).some((source: any) => source.reference === WEEDMASTER_LABEL))
    throw new Error("repair_source_already_present_or_adjudicated");
  const prior = history[0].snapshot;
  const matching = (prior.verification_sources ?? []).filter((source: any) => source.reference === WEEDMASTER_LABEL &&
    trustedRetainedManufacturerDocument(prior, source) && trustedRetainedManufacturerDocument(current, source));
  if (matching.length !== 1) throw new Error("repair_reviewed_source_not_unique");
  const source = matching[0];
  const visual = source.reviewed_visual_declaration;
  if (!visual || visual.document_sha256 !== WEEDMASTER_SHA256 || visual.document_version !== VERSION ||
    !verifyReviewedVisualDeclaration({ evidence: visual, fetchedSha256: WEEDMASTER_SHA256,
      fetchedUrl: WEEDMASTER_LABEL, lockedActives: current.active_ingredients,
      printedApprovalNumbers: (source.registration_numbers ?? []).filter((n: any) => n.canonical && n.scheme === "apvma").map((n: any) => n.number),
      lockedRegistrationNumber: "53576", lockedFormType: current.form_type, printedDocumentVersion: VERSION }).ok)
    throw new Error("repair_reviewed_document_identity_refused");
  // Exactly one column. Preserve every current evidence payload; correct regulator-as-manufacturer roles only.
  const retainedSources = (current.verification_sources ?? []).map((existing) => {
    const normalized = refreshSourceRole(current, existing);
    if (!normalized) throw new Error("repair_current_source_requires_adjudication");
    return normalized;
  });
  const patch = { verification_sources: [...retainedSources, structuredClone(source)] };
  if (validateResolverPatch(patch)) throw new Error("repair_patch_contract_refused");
  const repaired = { ...current, ...patch };
  if (!masterHasExactHydrationReadiness(repaired)) throw new Error("repair_readiness_refused");
  const served = buildMasterStructuredResponse(repaired);
  if (applyDefaultRateOptions(served).length) throw new Error("repair_options_refused");
  const options = served.default_rate_options;
  const phalaris = options.per_100_litres.find((option: any) => option.rate_ids.includes(PHALARIS));
  if (options.per_hectare.length !== 9 || options.per_100_litres.length !== 8 || !phalaris ||
    phalaris.min_value !== 500 || phalaris.max_value !== 1000 || phalaris.unit !== "mL" ||
    !phalaris.targets.includes("Phalaris") || !phalaris.conditions.includes("Handgun")) throw new Error("repair_acceptance_refused");
  return patch;
}

/** Store only a CAS/admin-bound preview; applying is exclusively the existing authenticated review RPC. */
export async function storeWeedmasterEvidenceRestorePreview(current: MasterRow, history: any[], sourceRevision: number,
  adminId: string, store: PreviewStore): Promise<Record<string, any>> {
  const patch = buildWeedmasterEvidenceRestorePatch(current, history, sourceRevision);
  if (!adminId) throw new Error("repair_admin_required");
  const changes = [{ field: "verification_sources", current: "Reviewed Nufarm document absent",
    authoritative: `Restore unchanged reviewed Nufarm document from Master revision ${sourceRevision}; retain all current evidence` }];
  const stored = await store.insertPreview({ master_chemical_id: current.id, base_revision: current.catalogue_version,
    outcome: "evidence_refreshed", proposed_patch: patch, changes, requested_by: adminId });
  if (!stored?.id) throw new Error("repair_preview_store_failed");
  return { preview_id: stored.id, expires_at: stored.expires_at ?? null, base_revision: current.catalogue_version,
    source_revision: sourceRevision, proposed_patch: patch, changes, preview_stored: true, master_mutated: false };
}
