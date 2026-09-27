import type { MasterRow, Jsonish } from "./contract.ts";
import { classifyUrl } from "../research/classify.ts";
import { manufacturerUrlsFromMaster, type WebIdentity } from "../web_identity.ts";
import { validateResolverPatch } from "./review_preview.ts";

export interface BackfillDetail {
  product_name?: string;
  product_category?: string | null;
  form_type?: string | null;
  active_ingredients?: Array<Record<string, unknown>>;
  activity_groups?: string[];
  activity_group_scheme?: string | null;
  resistance_classification_state?: string;
  registered_uses?: Array<Record<string, unknown>>;
  registration?: { registration_number?: string | null; manufacturer_label_url?: string | null; registrant?: string | null } | null;
  verification?: { sources?: Array<Record<string, unknown>>; conflicts?: Array<Record<string, unknown>>; unresolved_fields?: string[] };
}

export function isIncompleteMaster(row: MasterRow): boolean {
  const actives = row.active_ingredients ?? [];
  const protection = /fungicide|herbicide|insecticide|miticide/i.test(row.product_category ?? "");
  const rates = row.viticulture_rates;
  const grapes = (row.registered_uses ?? []).some((use) => /grape|vineyard|vine/i.test(String(use.crop ?? "")));
  const urls = manufacturerUrlsFromMaster(row as unknown as Record<string, unknown>, row.registration_country);
  return row.resistance_classification_state === "unresolved" ||
    (protection && (!row.activity_groups?.length || actives.some((a) => !a.activity_group || a.concentration == null || !a.concentration_unit))) ||
    (grapes && (!(rates?.per_hectare?.length || rates?.per_100_litres?.length) ||
      row.registered_uses.some((use) => /grape|vineyard|vine/i.test(String(use.crop ?? "")) &&
        (!Array.isArray(use.rates) || use.rates.length === 0)))) ||
    !urls.labels.length || Boolean(row.verification_unresolved_fields?.length) ||
    (row.verification_sources ?? []).some((s) => s.kind === "manufacturer_label" &&
      typeof s.reference === "string" && classifyUrl(s.reference, row.registration_country).trust !== "registrant");
}

/** Construct a research identity only from the selected, locked Master row. */
export function lockedWebIdentity(row: MasterRow): WebIdentity | null {
  if (row.registration_country !== "AU" || row.registration_scheme !== "apvma" ||
    row.registration_identity_key !== `AU:apvma:${row.registration_number.trim().toUpperCase()}`) return null;
  const urls = manufacturerUrlsFromMaster(row as unknown as Record<string, unknown>, row.registration_country);
  return { name: row.registered_product_name, registrant: row.registrant ?? "",
    registrationNumber: row.registration_number, category: row.product_category ?? null,
    activeNames: row.active_ingredients.map((a) => a.name).join(", "),
    pageUrls: urls.pages, labelUrls: urls.labels };
}

const equal = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);
const grape = (use: Record<string, unknown>): boolean => /grape|vineyard|vine/i.test(String(use.crop ?? ""));
const ratesFromUses = (uses: Array<Record<string, unknown>>) => {
  const rates = uses.filter(grape).flatMap((u) => Array.isArray(u.rates) ? u.rates as Array<Record<string, unknown>> : []);
  return { per_hectare: rates.filter((r) => ["per_hectare", "range_per_hectare"].includes(String(r.basis))),
    per_100_litres: rates.filter((r) => ["per_100_litres", "range_per_100_litres"].includes(String(r.basis))) };
};

export function buildMasterBackfillPatch(row: MasterRow, detail: BackfillDetail): {
  status: string; patch: Record<string, Jsonish> | null; evidence: Record<string, unknown>;
} {
  const label = detail.registration?.manufacturer_label_url;
  const evidence = { locked_identity: row.registration_identity_key, reported_registration_number: detail.registration?.registration_number ?? null,
    manufacturer_label_url: label ?? null, conflicts: detail.verification?.conflicts ?? [] };
  if (detail.registration?.registration_number &&
    detail.registration.registration_number.trim().toUpperCase() !== row.registration_number.trim().toUpperCase()) {
    return { status: "identity_conflict", patch: null, evidence };
  }
  if (!label || classifyUrl(label, row.registration_country).trust !== "registrant" ||
    classifyUrl(label, row.registration_country).kind !== "label_document") {
    return { status: "manufacturer_label_not_found", patch: null, evidence };
  }
  if (detail.verification?.conflicts?.length) return { status: "evidence_conflict", patch: null, evidence };
  const patch: Record<string, Jsonish> = {};
  const put = (key: string, before: unknown, after: unknown) => {
    if (after !== undefined && !equal(before, after)) patch[key] = after as Jsonish;
  };
  // Official-register identity and stronger facts are never replaced by a label.
  if (!row.registrant && detail.registration?.registrant) put("registrant", row.registrant, detail.registration.registrant);
  if (!row.product_category && detail.product_category) put("product_category", row.product_category, detail.product_category);
  if (!row.form_type && detail.form_type) put("form_type", row.form_type, detail.form_type);
  const oldActives = row.active_ingredients ?? [];
  const newActives = detail.active_ingredients ?? [];
  const oldNames = oldActives.map((a) => a.name.toLowerCase()).sort();
  const newNames = newActives.map((a) => String(a.name ?? "").toLowerCase()).sort();
  if (newActives.length && oldActives.length && !equal(oldNames, newNames)) {
    return { status: "evidence_conflict", patch: null, evidence: { ...evidence, existing_actives: oldNames, proposed_actives: newNames } };
  }
  if (newActives.some((next) => {
    const old = oldActives.find((a) => a.name.toLowerCase() === String(next.name ?? "").toLowerCase());
    return old && ((old.concentration != null && next.identity_source === "manufacturer_label" && next.concentration != null && old.concentration !== next.concentration) ||
      (old.activity_group && next.activity_group &&
        (old.activity_group.scheme !== (next.activity_group as Record<string, unknown>).scheme ||
         old.activity_group.code !== (next.activity_group as Record<string, unknown>).code)));
  })) return { status: "evidence_conflict", patch: null, evidence };
  if (newActives.length && (!oldActives.length || oldActives.some((a) => !a.activity_group || a.concentration == null))) {
    const merged = newActives.map((a) => {
      const old = oldActives.find((o) => o.name.toLowerCase() === String(a.name ?? "").toLowerCase());
      const labelConfirmed = a.identity_source === "manufacturer_label";
      const groupConfirmed = a.group_source === "authoritative_classification" || a.group_source === "manufacturer_label" || labelConfirmed;
      return old ? { ...old, concentration: old.concentration ?? (labelConfirmed ? a.concentration : null) ?? null,
        concentration_unit: old.concentration_unit ?? (labelConfirmed ? a.concentration_unit : null) ?? null,
        activity_group: old.activity_group ?? (groupConfirmed ? a.activity_group : null) ?? null,
        group_source: old.group_source ?? (groupConfirmed ? a.group_source : null) ?? null,
        identity_source: old.identity_source ?? (labelConfirmed ? "manufacturer_label" : null),
        classification_state: (old as unknown as Record<string, unknown>).classification_state ?? (groupConfirmed ? a.classification_state : "unresolved") } :
        labelConfirmed ? a : null;
    });
    if (merged.every((a) => a !== null)) put("active_ingredients", oldActives, merged);
  }
  const trustedActives = (patch.active_ingredients ?? oldActives) as Array<Record<string, unknown>>;
  const trustedCodes = [...new Set(trustedActives.map((a) => (a.activity_group as Record<string, unknown> | null)?.code)
    .filter((code): code is string => typeof code === "string" && code.length > 0))];
  if (!(row.activity_groups ?? []).length && trustedCodes.length)
    put("activity_groups", row.activity_groups, trustedCodes);
  if ((!row.activity_group_scheme || (row.resistance_classification_state === "unresolved" && detail.resistance_classification_state === "not_applicable")) && detail.activity_group_scheme &&
    (trustedCodes.length || detail.activity_group_scheme === "not_applicable"))
    put("activity_group_scheme", row.activity_group_scheme, detail.activity_group_scheme);
  const states = ["classified", "not_applicable", "unresolved"];
  if (!states.includes(String(detail.resistance_classification_state ?? ""))) {
    return { status: "evidence_conflict", patch: null, evidence };
  }
  if (row.resistance_classification_state === "unresolved" && detail.resistance_classification_state !== "unresolved") {
    const mergedActives = trustedActives;
    const hasCompleteGroups = detail.resistance_classification_state === "classified" && mergedActives.length > 0 &&
      mergedActives.every((a) => !!a.activity_group && typeof a.activity_group === "object" &&
        !!(a.activity_group as Record<string, unknown>).code);
    const groupFree = detail.resistance_classification_state === "not_applicable" &&
      detail.activity_group_scheme === "not_applicable" && mergedActives.length > 0 &&
      mergedActives.every((a) => (a.activity_group as Record<string, unknown> | null)?.scheme === "not_applicable");
    if (hasCompleteGroups || groupFree) put("resistance_classification_state", row.resistance_classification_state, detail.resistance_classification_state);
  }
  const uses = detail.registered_uses ?? [];
  const newRates = ratesFromUses(uses);
  const oldRates = row.viticulture_rates;
  if ([...newRates.per_hectare, ...newRates.per_100_litres].some((r) =>
    typeof r.rate_id !== "string" || !r.rate_id.startsWith("rate_v1_")))
    return { status: "evidence_conflict", patch: null, evidence: { ...evidence, reason: "missing_authoritative_rate_identity" } };
  if (uses.length && !(row.registered_uses ?? []).length) put("registered_uses", row.registered_uses, uses);
  else if (uses.some(grape)) {
    const existing = (row.registered_uses ?? []) as Array<Record<string, unknown>>;
    const incoming = uses.filter(grape);
    const matched = new Set<number>();
    const merged = existing.map((old) => {
      if (!grape(old) || (Array.isArray(old.rates) && old.rates.length)) return old;
      const index = incoming.findIndex((next) =>
        String(next.crop ?? "").toLowerCase() === String(old.crop ?? "").toLowerCase() &&
        String(next.target ?? next.target_raw ?? "").toLowerCase() === String(old.target ?? old.target_raw ?? "").toLowerCase());
      if (index < 0) return old;
      matched.add(index);
      return { ...incoming[index], ...old, rates: incoming[index].rates };
    });
    put("registered_uses", row.registered_uses, [...merged, ...incoming.filter((_, index) => !matched.has(index) &&
      !existing.some((old) => grape(old) && String(old.crop ?? "").toLowerCase() === String(incoming[index].crop ?? "").toLowerCase() &&
        String(old.target ?? old.target_raw ?? "").toLowerCase() === String(incoming[index].target ?? incoming[index].target_raw ?? "")))]);
  }
  // No fanning out an already-stored projection: only rates from THIS label extraction.
  if ((newRates.per_hectare.length || newRates.per_100_litres.length) &&
    !(oldRates?.per_hectare?.length || oldRates?.per_100_litres?.length)) {
    put("viticulture_rates", oldRates, newRates);
    if (!(row.label_rate_bases ?? []).length) put("label_rate_bases", row.label_rate_bases, [...new Set([...newRates.per_hectare, ...newRates.per_100_litres].map((r) => String(r.basis)))]);
  }
  const sources = row.verification_sources ?? [];
  if (!sources.some((s) => s.kind === "manufacturer_label" && s.reference === label)) {
    put("verification_sources", sources, [...sources, { kind: "manufacturer_label", name: "Manufacturer commercial label", reference: label }]);
  }
  // Master label_reference is consumed by older readers as a regulator URL;
  // a commercial PDF belongs only in manufacturer_label verification_sources.
  const violation = validateResolverPatch(patch);
  if (Object.keys(patch).length && violation) throw new Error(`patch_contract_violation: ${violation}`);
  return { status: Object.keys(patch).length ? "preview_ready" : "no_material_change", patch: Object.keys(patch).length ? patch : null, evidence };
}
