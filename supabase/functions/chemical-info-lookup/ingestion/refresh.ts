// Master refresh service (Stage 3 §G) — re-check an EXISTING master row
// against its jurisdiction's authoritative sources.
//
// Outcomes:
//   no_material_change — register agrees with the stored canonical content
//                        and the stored evidence is still fresh.
//   evidence_refreshed — content identical; the stored evidence was stale and
//                        has been re-confirmed (apply updates evidence only).
//   material_change    — register asserts different non-chemistry facts
//                        (name, registrant, label approval, status, label
//                        use claims / WHP / re-entry — Stage 4).
//   conflict           — register disagrees about the CHEMISTRY (actives /
//                        concentrations). Never auto-resolved.
//   source_unavailable — register unreachable; says NOTHING about the product.
//
// Stage 4: refresh re-checks LABEL EVIDENCE too. Fresh label claims are
// compared against the stored uses; drift is a material change. When a
// candidate patch is applied, stored AI-attributed rates are carried onto
// the matching fresh claims — label refresh never silently discards them,
// and never touches the row's UUID, its version history (sql/199 triggers
// version every content change), saved_chemicals, or spray snapshots.
//
// Write policy:
//   * CANDIDATE rows may be patched by the caller using the patch builders
//     here (the sql/199 triggers version every content change).
//   * APPROVED rows are NEVER written by this service. The result is the
//     admin-reviewable update: the portal shows the diff, a human applies it
//     through the existing admin write path, and the trigger mints the next
//     catalogue revision. Linked Saved Chemicals then see the drift through
//     Re-verify. This module does not touch saved_chemicals at all.

// deno-lint-ignore-file no-explicit-any

import type {
  AdapterDeps,
  MasterRow,
  ResolvedRegistration,
  WireConflict,
  WireDataSource,
} from "./contract.ts";
import {
  labelClaimsSignature,
  mergeLabelEvidenceIntoUses,
  storedUsesSignature,
  usesSummary,
} from "./label.ts";
import { adapterFor } from "./registry.ts";

/** Candidate evidence older than this is re-stamped on the next lookup. */
export const CANDIDATE_EVIDENCE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export type RefreshOutcome =
  | "no_material_change"
  | "material_change"
  | "evidence_refreshed"
  | "conflict"
  | "source_unavailable";

export interface RefreshChange {
  field: string;
  current: string;
  authoritative: string;
}

export interface RefreshResult {
  outcome: RefreshOutcome;
  changes: RefreshChange[];
  error_category?: string;
  registration?: ResolvedRegistration;
}

/** Canonical, order-independent chemistry signature for comparison. */
export function activesSignature(actives: any[]): string {
  return (Array.isArray(actives) ? actives : [])
    .map((a) =>
      [
        String(a?.name ?? "").trim().toLowerCase(),
        a?.concentration != null ? String(a.concentration) : "",
        String(a?.concentration_unit ?? "").toLowerCase(),
      ].join("|")
    )
    .sort()
    .join(" + ");
}

function display(actives: any[]): string {
  return (Array.isArray(actives) ? actives : [])
    .map((a) => {
      const conc = a?.concentration != null
        ? ` ${a.concentration}${a?.concentration_unit ? ` ${a.concentration_unit}` : ""}`
        : "";
      return `${String(a?.name ?? "").trim()}${conc}`.trim();
    })
    .filter(Boolean)
    .join(" + ") || "(none)";
}

interface RegisterFacts {
  registered_product_name: string;
  registrant: string | null;
  product_category: string | null;
  form_type: string | null;
  label_version: string | null;
  active_ingredients: any[];
}

/**
 * Field-by-field diff of a master row against register-asserted facts.
 * A fact the register does NOT provide is skipped — absence of data is never
 * read as a change.
 */
export function materialChanges(row: {
  registered_product_name: string;
  registrant: string | null;
  product_category: string | null;
  form_type: string | null;
  label_version: string | null;
  active_ingredients: any[];
}, reg: RegisterFacts): RefreshChange[] {
  const changes: RefreshChange[] = [];
  const trimmedEq = (a: string | null, b: string | null): boolean =>
    String(a ?? "").trim() === String(b ?? "").trim();

  if (
    reg.registered_product_name &&
    !trimmedEq(row.registered_product_name, reg.registered_product_name)
  ) {
    changes.push({
      field: "registered_product_name",
      current: String(row.registered_product_name ?? ""),
      authoritative: reg.registered_product_name,
    });
  }
  if (reg.registrant && !trimmedEq(row.registrant, reg.registrant)) {
    changes.push({
      field: "registrant",
      current: String(row.registrant ?? "(none)"),
      authoritative: reg.registrant,
    });
  }
  if (reg.product_category && !trimmedEq(row.product_category, reg.product_category)) {
    changes.push({
      field: "product_category",
      current: String(row.product_category ?? "(none)"),
      authoritative: reg.product_category,
    });
  }
  if (reg.form_type && !trimmedEq(row.form_type, reg.form_type)) {
    changes.push({
      field: "form_type",
      current: String(row.form_type ?? "(none)"),
      authoritative: reg.form_type,
    });
  }
  if (reg.label_version && !trimmedEq(row.label_version, reg.label_version)) {
    changes.push({
      field: "label_version",
      current: String(row.label_version ?? "(none)"),
      authoritative: reg.label_version,
    });
  }
  if (
    reg.active_ingredients.length &&
    activesSignature(row.active_ingredients) !== activesSignature(reg.active_ingredients)
  ) {
    changes.push({
      field: "active_ingredients",
      current: display(row.active_ingredients),
      authoritative: display(reg.active_ingredients),
    });
  }
  return changes;
}

/**
 * Re-check one master row against its jurisdiction's authoritative sources.
 * Reads only; the caller decides (per the write policy above) what may be
 * applied and to which review states.
 */
export async function refreshMasterRow(
  row: MasterRow,
  deps: AdapterDeps,
): Promise<RefreshResult> {
  const adapter = adapterFor(row.registration_country);
  if (!adapter) {
    return {
      outcome: "source_unavailable",
      error_category: "no_adapter_for_country",
      changes: [],
    };
  }
  const discovery = await adapter.discover(
    row.registered_product_name,
    row.registration_number,
    deps,
  );
  if (discovery.outcome === "source_unavailable") {
    // Source down ≠ product gone. Nothing may be inferred.
    return {
      outcome: "source_unavailable",
      error_category: discovery.error_category,
      changes: [],
    };
  }
  if (discovery.outcome !== "resolved" || !discovery.registration) {
    return {
      outcome: "material_change",
      changes: [{
        field: "registration_status",
        current: "listed in the master catalogue",
        authoritative: "no current register listing found for this identity",
      }],
    };
  }
  const reg = discovery.registration;
  if (
    reg.registration_number.toUpperCase() !==
      String(row.registration_number ?? "").trim().toUpperCase()
  ) {
    // A different registration number is a DIFFERENT registered product —
    // surfaced, never re-keyed.
    return {
      outcome: "material_change",
      changes: [{
        field: "registration_number",
        current: String(row.registration_number ?? ""),
        authoritative: reg.registration_number,
      }],
      registration: reg,
    };
  }

  const changes = materialChanges(row, reg);

  // ---- Label evidence re-check (Stage 4) ----------------------------------
  // Only when fresh evidence actually resolved: an unavailable label source
  // says NOTHING about the stored uses (fail soft, mirrors the register
  // outage rule above).
  const evidence = reg.label_evidence ?? null;
  if (evidence && evidence.claims.length) {
    // Stage LD-2: stored DOCUMENT-backed rates join the comparison only when
    // THIS pass extracted the document too — an extraction outage says
    // nothing about them (absence is never drift, stored rates never churn).
    const storedSig = storedUsesSignature(
      row.registered_uses ?? [],
      Boolean(evidence.document),
    );
    const freshSig = labelClaimsSignature(evidence);
    if (storedSig !== freshSig) {
      changes.push({
        field: "registered_uses",
        current: usesSummary(
          Array.isArray(row.registered_uses) ? row.registered_uses : [],
        ),
        authoritative: usesSummary(evidence.claims),
      });
    }
  }

  const chemistryChanged = changes.some((c) => c.field === "active_ingredients");
  if (chemistryChanged) return { outcome: "conflict", changes, registration: reg };
  if (changes.length) return { outcome: "material_change", changes, registration: reg };

  const ageMs = deps.now().getTime() - (Date.parse(row.retrieved_at ?? "") || 0);
  if (ageMs > CANDIDATE_EVIDENCE_MAX_AGE_MS) {
    return { outcome: "evidence_refreshed", changes: [], registration: reg };
  }
  return { outcome: "no_material_change", changes: [], registration: reg };
}

function mergeSources(row: MasterRow, fresh: WireDataSource[]): WireDataSource[] {
  // Fresh evidence replaces the stored entries OF THE SAME KIND (register,
  // label…); other kinds (AI extraction, classification table) are kept.
  const freshKinds = new Set(fresh.map((s) => s?.kind).filter(Boolean));
  const kept = (row.verification_sources ?? []).filter((s) => !freshKinds.has(s?.kind));
  return [...fresh, ...kept];
}

/**
 * Patch a CANDIDATE row from a refresh result. Returns null when nothing may
 * be written (no change, source unavailable, or an approved/retired row).
 *
 *   evidence_refreshed → evidence columns only.
 *   material_change    → register-backed scalar facts + evidence.
 *   conflict           → conflicts recorded + status "conflict"; the stored
 *                        chemistry is NOT replaced (no arbitrary winner).
 */
export function buildCandidateRefreshPatch(
  row: MasterRow,
  result: RefreshResult,
  nowIso: string,
): Record<string, any> | null {
  if (row.review_status !== "candidate") return null;
  const reg = result.registration;

  if (result.outcome === "evidence_refreshed" && reg) {
    return {
      verification_sources: mergeSources(row, reg.sources),
      retrieved_at: nowIso,
      source_kind: "official_register",
      source_reference: reg.sources[0]?.reference ?? row.source_reference,
    };
  }

  if (result.outcome === "material_change" && reg) {
    const patch: Record<string, any> = {
      registered_product_name: reg.registered_product_name,
      registrant: reg.registrant ?? row.registrant,
      product_category: reg.product_category ?? row.product_category,
      form_type: reg.form_type ?? row.form_type,
      label_version: reg.label_version ?? row.label_version,
      verification_sources: mergeSources(row, reg.sources),
      retrieved_at: nowIso,
      source_kind: "official_register",
      source_reference: reg.sources[0]?.reference ?? row.source_reference,
    };
    // Stage LD-1: a freshly-confirmed label document rides along with an
    // applied material change (additive only — discovery failure never
    // blanks a stored reference; absence of the document is not a change).
    if (reg.label_document?.url) patch.label_reference = reg.label_document.url;
    // Stage 4: apply fresh label claims, carrying the stored uses'
    // AI-attributed detail (rates) onto the claims they match — the refresh
    // never invents, never discards silently, never re-keys.
    const evidence = reg.label_evidence ?? null;
    if (
      evidence && evidence.claims.length &&
      result.changes.some((c) => c.field === "registered_uses")
    ) {
      const merged = mergeLabelEvidenceIntoUses(
        Array.isArray(row.registered_uses) ? row.registered_uses : [],
        evidence,
      );
      patch.registered_uses = merged.uses;
      patch.label_rate_bases = Array.from(
        new Set(
          merged.uses.flatMap((u: any) =>
            (u?.rates ?? []).map((r: any) => r?.basis).filter(Boolean)
          ),
        ),
      );
      const keptUnresolved = (row.verification_unresolved_fields ?? []).filter(
        (f) =>
          !/^(rates|withholding_period|registered_use_claim):/.test(f) &&
          f !== "registered_uses" &&
          f !== "re_entry_period_hours",
      );
      patch.verification_unresolved_fields = Array.from(
        new Set([...keptUnresolved, ...evidence.unresolved]),
      ).sort();
    }
    return patch;
  }

  if (result.outcome === "conflict" && reg) {
    const conflicts: WireConflict[] = [
      ...(row.verification_conflicts ?? []),
      ...result.changes
        .filter((c) => c.field === "active_ingredients")
        .map((c) => ({
          field: c.field,
          extracted_value: c.current,
          authoritative_value: c.authoritative,
          extracted_source: row.source_kind,
          authoritative_source: "official_register",
        })),
    ];
    return {
      verification_status: "conflict",
      verification_conflicts: conflicts,
      verification_sources: mergeSources(row, reg.sources),
      retrieved_at: nowIso,
    };
  }

  return null;
}
