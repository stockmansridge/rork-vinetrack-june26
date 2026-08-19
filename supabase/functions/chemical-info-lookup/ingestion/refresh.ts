// Master refresh service (Stage 3 §G) — re-check an EXISTING master row
// against its jurisdiction's authoritative sources.
//
// Outcomes:
//   no_material_change — register agrees with the stored canonical content
//                        and the stored evidence is still fresh.
//   evidence_refreshed — content identical; the stored evidence was stale and
//                        has been re-confirmed (apply updates evidence only).
//   material_change    — register asserts different non-chemistry facts
//                        (name, registrant, label approval, status…).
//   conflict           — register disagrees about the CHEMISTRY (actives /
//                        concentrations). Never auto-resolved.
//   source_unavailable — register unreachable; says NOTHING about the product.
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
  const kept = (row.verification_sources ?? []).filter((s) => s?.kind !== "official_register");
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
    return {
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
