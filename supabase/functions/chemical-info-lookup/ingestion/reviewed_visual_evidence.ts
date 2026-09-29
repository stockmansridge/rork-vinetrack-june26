import type { WireActiveIngredient } from "./contract.ts";

/** A transcription is only evidence after an authenticated admin explicitly attests to the image. */
export interface ReviewedVisualDeclaration {
  document_sha256: string;
  source_url: string;
  physical_page: number;
  location: string;
  verbatim: string;
  active: { name: string; salt_form: string; concentration: number; unit: string };
  formulation: string;
  method: "human_visual_transcription";
  reviewed_by: string;
  reviewed_at: string;
  document_version: string | null;
}

/** The request carries the transcription, never a client-supplied reviewer identity. */
export function attestVisualDeclaration(raw: unknown, adminId: string, now: Date): ReviewedVisualDeclaration | null {
  if (!raw || typeof raw !== "object" || !adminId) return null;
  const value = raw as Record<string, unknown>;
  const active = value.active as Record<string, unknown> | null;
  if (value.confirm_review !== true || value.method !== "human_visual_transcription" ||
    typeof value.document_sha256 !== "string" || !/^[a-f0-9]{64}$/.test(value.document_sha256) ||
    typeof value.source_url !== "string" || !value.source_url.startsWith("https://") ||
    !Number.isInteger(value.physical_page) || Number(value.physical_page) < 1 ||
    typeof value.location !== "string" || value.location.trim().length < 8 || value.location.length > 240 ||
    typeof value.verbatim !== "string" || value.verbatim.length < 25 || value.verbatim.length > 600 ||
    !active || typeof active.name !== "string" || typeof active.salt_form !== "string" ||
    typeof active.concentration !== "number" || !Number.isFinite(active.concentration) ||
    typeof active.unit !== "string" || typeof value.formulation !== "string" ||
    !(value.document_version === null || typeof value.document_version === "string")) return null;
  return { document_sha256: value.document_sha256, source_url: value.source_url,
    physical_page: Number(value.physical_page), location: value.location.trim(), verbatim: value.verbatim.trim(),
    active: { name: active.name.trim(), salt_form: active.salt_form.trim(),
      concentration: active.concentration, unit: active.unit.trim() },
    formulation: value.formulation.trim(),
    method: "human_visual_transcription", reviewed_by: adminId, reviewed_at: now.toISOString(),
    document_version: value.document_version as string | null };
}

const norm = (text: string): string => text.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");

/** Strictly compare the complete reviewed declaration, salt form and strength to the locked Master actives. */
export function verifyReviewedVisualDeclaration(input: {
  evidence: ReviewedVisualDeclaration | null | undefined;
  fetchedSha256: string;
  fetchedUrl: string;
  lockedActives: WireActiveIngredient[];
  printedApprovalNumbers: string[];
  lockedRegistrationNumber: string;
  lockedFormType: string | null;
  printedDocumentVersion: string | null;
}): { ok: boolean; reason: string } {
  const { evidence: e } = input;
  if (!e?.reviewed_by || !e.reviewed_at || e.method !== "human_visual_transcription") return { ok: false, reason: "visual_review_missing" };
  if (e.document_sha256 !== input.fetchedSha256 || e.source_url !== input.fetchedUrl)
    return { ok: false, reason: "visual_document_changed" };
  if (e.document_version !== input.printedDocumentVersion) return { ok: false, reason: "visual_document_version_conflict" };
  if (e.physical_page < 1 || !e.location || !input.printedApprovalNumbers.includes(input.lockedRegistrationNumber))
    return { ok: false, reason: "visual_document_identity_unconfirmed" };
  const declaration = e.verbatim.match(/^ACTIVE CONSTITUENT:\s*(\d+(?:\.\d+)?)\s*(g\/L|g\/kg)\s+([A-Za-z][A-Za-z -]+?)\s+present as the ([A-Za-z][A-Za-z -]+?)\.?$/i);
  if (!declaration || input.lockedActives.length !== 1 ||
    norm(e.active.name) !== norm(declaration[3]) || norm(e.active.salt_form) !== norm(declaration[4]) ||
    e.active.concentration !== Number(declaration[1]) || norm(e.active.unit) !== norm(declaration[2]))
    return { ok: false, reason: "visual_declaration_inconsistent" };
  // The cover prints its physical formulation separately from the active.
  // SL is a liquid concentrate, never silently compatible with a solid Master.
  if (norm(e.formulation) !== "sl soluble concentrate" || norm(input.lockedFormType ?? "") !== "liquid")
    return { ok: false, reason: "visual_formulation_conflict" };
  const locked = input.lockedActives[0];
  // The legacy register text ends mid-word. This ONE explicit completion is a
  // chemistry comparison, not a product verification or a fuzzy substring match.
  const completedLegacyName = norm(locked.name) === "glyphosate present as the isopropylamine and mono ammoni"
    ? "glyphosate present as the isopropylamine and mono ammonium salts" : norm(locked.name);
  if (completedLegacyName !== norm(`${e.active.name} present as the ${e.active.salt_form}`) ||
    locked.concentration !== e.active.concentration || norm(locked.concentration_unit ?? "") !== norm(e.active.unit))
    return { ok: false, reason: "visual_chemistry_conflict" };
  return { ok: true, reason: "reviewed_visual_declaration_matches_locked_chemistry" };
}
