// deno-lint-ignore-file no-explicit-any
import { classifyUrl, manufacturerHostEligible } from "../research/classify.ts";
import type { WireDataSource } from "./contract.ts";

/** Explicit rejection is never undone by a register refresh or historical restoration. */
export function manufacturerEvidenceInvalidated(source: any): boolean {
  return source?.invalidated === true || Boolean(source?.invalidated_at) ||
    ["invalidated", "revoked", "rejected"].includes(String(source?.status ?? "").toLowerCase()) ||
    ["invalidated", "revoked", "rejected"].includes(String(source?.review_status ?? "").toLowerCase());
}

/** The existing catalogue manufacturer-document rules, shared by serving and retention. No fetching/attesting. */
export function trustedRetainedManufacturerDocument(row: any, source: any): boolean {
  if (source?.kind !== "manufacturer_label" || typeof source.reference !== "string" ||
    manufacturerEvidenceInvalidated(source)) return false;
  const url = source.reference;
  const country = String(row?.registration_country ?? "").toUpperCase();
  const classified = classifyUrl(url, country);
  if (!manufacturerHostEligible(url, country, String(row?.registrant ?? "")) ||
    classified.kind === "safety_data_sheet" ||
    !(classified.kind === "label_document" || new URL(url).pathname.toLowerCase().endsWith(".pdf"))) return false;
  const visual = source.reviewed_visual_declaration;
  return !visual || (visual.source_url === url &&
    typeof visual.document_sha256 === "string" && /^[a-f0-9]{64}$/.test(visual.document_sha256) &&
    visual.method === "human_visual_transcription" && Boolean(visual.reviewed_by) &&
    typeof visual.reviewed_at === "string" && Number.isFinite(Date.parse(visual.reviewed_at)));
}

/** Correct historical regulator-as-manufacturer roles without changing the evidence payload. */
export function refreshSourceRole(row: any, source: WireDataSource): WireDataSource | null {
  if (!["manufacturer_label", "manufacturer_product"].includes(source?.kind)) return source;
  const url = source.reference;
  const classified = classifyUrl(String(url ?? ""), String(row.registration_country ?? ""));
  if (["official_register", "regulator"].includes(classified.trust)) {
    const isDocument = classified.kind === "label_document" || /\.pdf(?:\?|$)/i.test(String(url));
    return { ...source, kind: isDocument ? "regulator_label" : "official_register" };
  }
  if (manufacturerEvidenceInvalidated(source)) return source; // keep the rejection tombstone, not usable evidence
  if (source.kind === "manufacturer_label") return trustedRetainedManufacturerDocument(row, source) ? source : null;
  return url && manufacturerHostEligible(url, String(row.registration_country ?? ""), row.registrant) &&
    classified.kind === "product_page" ? source : null;
}

/** Additive for trusted manufacturer documents; regulator refresh can replace only its own roles. */
export function mergeRefreshEvidence(row: any, fresh: WireDataSource[]): WireDataSource[] {
  const oldSources: WireDataSource[] = (Array.isArray(row.verification_sources) ? row.verification_sources : [])
    .map((source: WireDataSource) => refreshSourceRole(row, source)).filter(Boolean);
  const incoming = fresh.map((source) => refreshSourceRole(row, source)).filter((source): source is WireDataSource => Boolean(source));
  const protectedSources = oldSources.filter((source) => ["manufacturer_label", "manufacturer_product"].includes(source.kind));
  const acceptedFresh = incoming.filter((source) => {
    const old = protectedSources.find((old) => old.reference === source.reference && old.kind === source.kind);
    if (!old) return true;
    if (manufacturerEvidenceInvalidated(old)) return false;
    if (manufacturerEvidenceInvalidated(source)) return true;
    return source.kind === "manufacturer_label" && !(old as any).reviewed_visual_declaration &&
      Boolean((source as any).reviewed_visual_declaration);
  });
  const replacedKinds = new Set(acceptedFresh.map((source) => source.kind));
  return [...acceptedFresh, ...oldSources.filter((source) => {
    if (["manufacturer_label", "manufacturer_product"].includes(source.kind))
      return !acceptedFresh.some((fresh) => fresh.kind === source.kind && fresh.reference === source.reference);
    return !replacedKinds.has(source.kind);
  })];
}
