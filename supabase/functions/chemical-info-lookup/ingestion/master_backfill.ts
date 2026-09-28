import type { MasterRow, Jsonish } from "./contract.ts";
import { authoritativeGroup, groupsAreEquivalent } from "./activity_groups.ts";
import { classifyUrl, manufacturerHostEligible } from "../research/classify.ts";
import { manufacturerUrlsFromMaster, type WebIdentity } from "../web_identity.ts";
import { identityBearingRateLabel, normaliseIdentityText } from "../rate_identity.ts";
import { validateResolverPatch } from "./review_preview.ts";

export interface BackfillDetail {
  product_category?: string | null;
  form_type?: string | null;
  active_ingredients?: Array<Record<string, unknown>>;
  activity_group_scheme?: string | null;
  resistance_classification_state?: string;
  registered_uses?: Array<Record<string, unknown>>;
  registration?: { registration_number?: string | null; manufacturer_label_url?: string | null; manufacturer_package_label_url?: string | null; manufacturer_label_verified?: boolean; manufacturer_label_retrieval_method?: "web_search_index"; registrant?: string | null;
    manufacturer_label_identifiers?: { numbers: string[]; printed_values: string[] } } | null;
  verification?: { conflicts?: Array<Record<string, unknown>> };
}

const grape = (use: Record<string, unknown>): boolean => /grape|vineyard|vine/i.test(String(use.crop ?? ""));
const grapeScope = (text: string): boolean => /^(?:grape(?:vine)?s?|vine(?:yard)?s?)\b/i.test(text.trim());
const scopedGap = (field: string): boolean => {
  const [kind, ...scope] = field.split(":");
  if (!scope.length) return ["active_ingredients", "activity_group", "activity_groups", "label_reference", "manufacturer_label", "re_entry_period_hours"].includes(kind.toLowerCase());
  return /^(rates|withholding_period|re_entry_period|restrictions|statements|conditions)$/i.test(kind) && grapeScope(scope.join(":")) ||
    /^(activity_group|concentration|active_ingredients):/i.test(field);
};
const hasLabel = (row: MasterRow): boolean => (row.verification_sources ?? []).some((s) => s.kind === "manufacturer_label" &&
  typeof s.reference === "string" && manufacturerHostEligible(s.reference, row.registration_country, row.registrant) &&
  (classifyUrl(s.reference, row.registration_country).kind === "label_document" ||
    new URL(s.reference).pathname.toLowerCase().endsWith(".pdf")));

export function isIncompleteMaster(row: MasterRow): boolean {
  const actives = row.active_ingredients ?? [];
  const protection = /fungicide|herbicide|insecticide|miticide/i.test(row.product_category ?? "");
  const grapes = (row.registered_uses ?? []).some(grape);
  const gaps = (row.verification_unresolved_fields ?? []).some(scopedGap);
  const rates = row.viticulture_rates;
  return (protection && (row.resistance_classification_state === "unresolved" || !row.activity_groups?.length ||
    actives.some((a) => !a.activity_group || a.concentration == null || !a.concentration_unit))) ||
    (grapes && (!(rates?.per_hectare?.length || rates?.per_100_litres?.length) ||
      row.registered_uses.some((use) => grape(use) && (!Array.isArray(use.rates) || !use.rates.length)))) ||
    !hasLabel(row) || gaps;
}

/** Backfill dry runs cannot store server previews, even if a caller reaches this boundary. */
export async function storeBackfillPreview<T>(dryRun: boolean, insertPreview: () => Promise<T>): Promise<T | null> {
  return dryRun ? null : await insertPreview();
}

/** V2 name-cache writes are never permitted for Master-anchored research. */
export async function writeLookupCache(backfill: boolean, dryRun: boolean, writeWebV2Cache: () => Promise<void>): Promise<void> {
  if (!backfill && !dryRun) await writeWebV2Cache();
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

/** Compare JSON-shaped backfill values without depending on JSONB object key order. Array order and key presence remain significant. */
export function equalBackfillValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) || Array.isArray(b)) return Array.isArray(a) && Array.isArray(b) &&
    a.length === b.length && a.every((value, index) => equalBackfillValue(value, b[index]));
  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length && keys.every((key) =>
    Object.hasOwn(right, key) && equalBackfillValue(left[key], right[key]));
}
const equal = equalBackfillValue;
const present = (value: unknown): boolean => value !== null && value !== undefined &&
  (typeof value !== "string" || value.trim().length > 0) && (!Array.isArray(value) || value.length > 0);
const ratesOf = (use: Record<string, unknown>): Array<Record<string, unknown>> =>
  Array.isArray(use.rates) ? use.rates as Array<Record<string, unknown>> : [];
const rateIdentity = (rate: Record<string, unknown>): string | null =>
  typeof rate.rate_id === "string" && rate.rate_id.startsWith("rate_v1_") ? rate.rate_id : null;
// Display/provenance text can differ without changing the printed dose. Never compare only display text.
const rateValue = (rate: Record<string, unknown>): unknown =>
  [rate.basis ?? null, rate.min_value ?? null, rate.max_value ?? null, rate.value ?? null,
    rate.unit ?? null, rate.condition_ambiguous ?? false];
function equivalentPrintedDose(old: Record<string, unknown>, next: Record<string, unknown>): boolean {
  const amount = (rate: Record<string, unknown>): [unknown, unknown] => {
    const value = rate.value ?? null;
    return [rate.min_value ?? value, rate.max_value ?? value];
  };
  const unit = (rate: Record<string, unknown>): string => {
    const text = normaliseIdentityText(String(rate.unit ?? ""));
    return String(rate.basis).includes("100_litres") ? text.replace(/ 100 l$/, "") :
      String(rate.basis).includes("hectare") ? text.replace(/ ha$/, "") : text;
  };
  return rateIdentity(old) !== null && rateIdentity(next) !== null && old.basis === next.basis &&
    equal(amount(old), amount(next)) && unit(old) === unit(next) &&
    identityBearingRateLabel(String(old.label ?? "")) === identityBearingRateLabel(String(next.label ?? "")) &&
    (old.condition_ambiguous ?? false) === (next.condition_ambiguous ?? false);
}

function mergeRates(old: Array<Record<string, unknown>>, incoming: Array<Record<string, unknown>>,
  sameDirection = false): Array<Record<string, unknown>> | null {
  const merged = [...old];
  for (const next of incoming) {
    const id = rateIdentity(next);
    if (!id) return null;
    const previous = merged.find((rate) => rateIdentity(rate) === id);
    if (previous) {
      if (!equal(rateValue(previous), rateValue(next))) return null;
    } else {
      // Historical rate_v1 IDs are immutable. Within the SAME printed
      // direction a parser may describe a fixed dose as value=400 or
      // min=max=400 and render its unit as mL or mL/100 L. Reuse the stored
      // identity; never make this equivalence across distinct directions.
      if (sameDirection && merged.some((rate) => equivalentPrintedDose(rate, next))) continue;
      // A legacy rate with no identity cannot be proven distinct from a new
      // rate on the same basis. Never create a plausible duplicate.
      if (merged.some((rate) => !rateIdentity(rate) && rate.basis === next.basis)) return null;
      merged.push(next);
    }
  }
  return merged;
}
const matchWords = (value: unknown): string => String(value ?? "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim().replace(/\s+/g, " ");
const grapeAliases = new Set(["grape", "grapes", "grapevine", "grapevines", "vineyard", "vineyards"]);
const scientificSuffix = /\s*\(([A-Z][a-z]+\s+[a-z]+)\)\s*$/;
const useTarget = (use: Record<string, unknown>): string => String(use.target ?? use.target_raw ?? "").trim();
const useKey = (use: Record<string, unknown>): string => {
  const crop = matchWords(use.crop);
  // Drop only a final binomial scientific name, never arbitrary parenthetical qualifiers.
  const commonName = useTarget(use).replace(scientificSuffix, "");
  return `${grapeAliases.has(crop) ? "grapevine" : crop}|${matchWords(commonName)}`;
};
const sameUse = (old: Record<string, unknown>, next: Record<string, unknown>): boolean => {
  if (useKey(old) !== useKey(next)) return false;
  // State/soil-scoped label directions are distinct even when crop and target match.
  if (/^State:.*; Soil: (?:light|heavy)$/i.test(String(old.conditions ?? "")) &&
    /^State:.*; Soil: (?:light|heavy)$/i.test(String(next.conditions ?? "")) &&
    matchWords(old.conditions) !== matchWords(next.conditions)) return false;
  const oldScientific = useTarget(old).match(scientificSuffix)?.[1];
  const nextScientific = useTarget(next).match(scientificSuffix)?.[1];
  // Two explicit, different species must not be conflated just because their common name matches.
  return !oldScientific || !nextScientific || matchWords(oldScientific) === matchWords(nextScientific);
};
const structuredUseFields = ["withholding_period_days", "re_entry_period_hours"];
const narrativeUseFields = ["withholding_period_text", "re_entry_period_text", "restrictions", "statements", "conditions"];
function mergeUse(old: Record<string, unknown>, next: Record<string, unknown>, sameLabel: boolean): Record<string, unknown> | null {
  const result: Record<string, unknown> = { ...old };
  for (const key of structuredUseFields) {
    if (typeof next[key] !== "number" || (next[key] as number) <= 0) continue;
    if (present(old[key]) && !equal(old[key], next[key])) return null;
    if (!present(old[key])) result[key] = next[key];
  }
  for (const key of narrativeUseFields) {
    if (!present(next[key])) continue;
    // Existing label prose is stable; extraction wording is not. Never rewrite it.
    if (present(old[key]) && !sameLabel && !equal(old[key], next[key])) return null;
    if (!present(old[key])) result[key] = next[key];
  }
  const rates = mergeRates(ratesOf(old), ratesOf(next), true);
  if (!rates) return null;
  if (rates.length && !equal(ratesOf(old), rates)) result.rates = rates;
  return result;
}

/** Groups from an existing official identity can be classified without a label or AI. */
export function authoritativeBackfillDetail(row: MasterRow): BackfillDetail {
  const actives = (row.active_ingredients ?? []).map((active) => {
    const group = authoritativeGroup(active.name);
    return { name: active.name, ...(group ? { activity_group: group, group_source: "authoritative_classification",
      classification_state: "classified" } : {}) };
  });
  return { active_ingredients: actives, resistance_classification_state: "unresolved" };
}

export function buildMasterBackfillPatch(row: MasterRow, detail: BackfillDetail = {}): {
  status: string; patch: Record<string, Jsonish> | null; evidence: Record<string, unknown>;
} {
  const label = detail.registration?.manufacturer_label_url;
  const labelReady = !!label && manufacturerHostEligible(label, row.registration_country, row.registrant) &&
    (classifyUrl(label, row.registration_country).trust === "registrant" &&
      classifyUrl(label, row.registration_country).kind === "label_document" ||
      detail.registration?.manufacturer_label_verified === true && new URL(label).pathname.toLowerCase().endsWith(".pdf"));
  const identifiers = detail.registration?.manufacturer_label_identifiers;
  const evidence = { locked_identity: row.registration_identity_key, reported_registration_number: detail.registration?.registration_number ?? null,
    manufacturer_label_url: label ?? null, manufacturer_label_identifiers: identifiers ?? null,
    conflicts: detail.verification?.conflicts ?? [] };
  const conflict = (reason: string) => ({ status: "evidence_conflict", patch: null, evidence: { ...evidence, reason } });
  if (detail.verification?.conflicts?.length) return conflict("label_conflicts");
  const patch: Record<string, Jsonish> = {};
  const put = (key: string, before: unknown, after: unknown) => {
    if (after !== undefined && !equal(before, after)) patch[key] = after as Jsonish;
  };
  const oldActives = row.active_ingredients ?? [];
  const supplied = labelReady ? detail.active_ingredients ?? [] : [];
  if (supplied.length && oldActives.length && !equal(oldActives.map((a) => a.name.toLowerCase()).sort(),
    supplied.map((a) => String(a.name ?? "").toLowerCase()).sort())) return conflict("active_identity");
  const mergedActives = oldActives.length ? oldActives.map((old) => {
    const next = supplied.find((a) => String(a.name ?? "").toLowerCase() === old.name.toLowerCase());
    const group = authoritativeGroup(old.name);
    const proposedGroup = group ?? (labelReady && next?.group_source === "manufacturer_label" ? next.activity_group as typeof old.activity_group : null);
    if (old.activity_group && proposedGroup && !groupsAreEquivalent(old.name, old.activity_group, proposedGroup)) return null;
    if (next?.identity_source === "manufacturer_label" &&
      ((present(old.concentration) && present(next.concentration) && old.concentration !== next.concentration) ||
        (present(old.concentration_unit) && present(next.concentration_unit) && old.concentration_unit !== next.concentration_unit))) return null;
    return { ...old, concentration: old.concentration ?? (next?.identity_source === "manufacturer_label" ? next.concentration : null) ?? null,
      concentration_unit: old.concentration_unit ?? (next?.identity_source === "manufacturer_label" ? next.concentration_unit : null) ?? null,
      activity_group: old.activity_group ?? proposedGroup ?? null,
      group_source: old.group_source ?? (proposedGroup ? group ? "authoritative_classification" : "manufacturer_label" : null),
      ...(proposedGroup && !old.activity_group ? { classification_state: "classified" } : {}) };
  }) : supplied.filter((a) => a.identity_source === "manufacturer_label");
  if (mergedActives.some((a) => a === null)) return conflict("active_chemistry_or_group");
  if (mergedActives.length) put("active_ingredients", oldActives, mergedActives);
  const trusted = mergedActives as Array<Record<string, unknown>>;
  const codes = [...new Set(trusted.map((a) => (a.activity_group as Record<string, unknown> | null)?.code)
    .filter((code): code is string => typeof code === "string" && code.length > 0))];
  if (codes.length) put("activity_groups", row.activity_groups, [...new Set([...(row.activity_groups ?? []), ...codes])]);
  const schemes = [...new Set(trusted.map((a) => (a.activity_group as Record<string, unknown> | null)?.scheme)
    .filter((scheme): scheme is string => typeof scheme === "string" && scheme !== "not_applicable"))];
  if (schemes.length === 1 && !row.activity_group_scheme) put("activity_group_scheme", row.activity_group_scheme, schemes[0]);
  if (schemes.length === 1 && row.activity_group_scheme && row.activity_group_scheme !== schemes[0]) return conflict("activity_group_scheme");
  if (row.resistance_classification_state === "unresolved" && trusted.length &&
    trusted.every((a) => present((a.activity_group as Record<string, unknown> | null)?.code)) && schemes.length === 1)
    put("resistance_classification_state", row.resistance_classification_state, "classified");
  if (labelReady && row.resistance_classification_state === "unresolved" &&
    detail.resistance_classification_state === "not_applicable" && detail.activity_group_scheme === "not_applicable" &&
    trusted.length && trusted.every((a) => (a.activity_group as Record<string, unknown> | null)?.scheme === "not_applicable")) {
    put("resistance_classification_state", row.resistance_classification_state, "not_applicable");
    if (!row.activity_group_scheme) put("activity_group_scheme", row.activity_group_scheme, "not_applicable");
  }

  // A per-vine total SPRAY VOLUME is carrier/application guidance, not a
  // product dose. Keep the wording only when a direction has no restriction.
  const incoming = labelReady ? (detail.registered_uses ?? []).filter(grape).map((use) => {
    const guidance = ratesOf(use).filter((rate) => rate.basis === "other" &&
      /\b(?:total\s+)?spray\s+volume\b/i.test(`${rate.raw_text ?? ""} ${rate.label ?? ""} ${use.restrictions ?? ""}`) &&
      /\b(?:mL|L)\s*\/\s*(?:vine|plant|tree)\b/i.test(String(rate.raw_text ?? "")));
    if (!guidance.length) return use;
    return { ...use, rates: ratesOf(use).filter((rate) => !guidance.includes(rate)),
      restrictions: present(use.restrictions) ? use.restrictions : guidance.map((rate) => rate.raw_text).join("; ") };
  }) : [];
  if (labelReady) {
    if (!row.registrant && detail.registration?.registrant) put("registrant", row.registrant, detail.registration.registrant);
    if (!row.product_category && detail.product_category) put("product_category", row.product_category, detail.product_category);
    if (!row.form_type && detail.form_type) put("form_type", row.form_type, detail.form_type);
    const uses = detail.registered_uses ?? [];
    const oldUses = (row.registered_uses ?? []) as Array<Record<string, unknown>>;
    const mergedUses = [...oldUses];
    for (const next of incoming) {
      // Canonical spelling is a matching aid only: never replace stored crop/target display text.
      const matches = mergedUses.map((old, i) => grape(old) && sameUse(old, next) ? i : -1)
        .filter((i) => i >= 0);
      if (matches.length > 1) return conflict("ambiguous_vineyard_direction");
      if (matches.length && present(mergedUses[matches[0]].direction_id) && present(next.direction_id) &&
        mergedUses[matches[0]].direction_id !== next.direction_id) return conflict("vineyard_direction_identity");
      if (!matches.length) {
        if (ratesOf(next).some((r) => !rateIdentity(r))) return conflict("missing_authoritative_rate_identity");
        mergedUses.push(next);
      } else {
        const sameLabel = (row.verification_sources ?? []).some((source) =>
          source.kind === "manufacturer_label" && source.reference === label);
        const merged = mergeUse(mergedUses[matches[0]], next, sameLabel);
        if (!merged) return conflict("vineyard_use_or_rate");
        mergedUses[matches[0]] = merged;
      }
    }
    if (incoming.length) put("registered_uses", row.registered_uses, mergedUses);
    else if (uses.length && !oldUses.length) put("registered_uses", row.registered_uses, uses);
    // Only use extracted, identity-bearing label rates. Never remint old fanned-out projections.
    const oldRates = row.viticulture_rates;
    const projected: Record<"per_hectare" | "per_100_litres", Array<Record<string, unknown>>> = {
      per_hectare: (oldRates?.per_hectare ?? []).map((rate) => ({ ...rate })),
      per_100_litres: (oldRates?.per_100_litres ?? []).map((rate) => ({ ...rate })) };
    const extracted = incoming.flatMap((use) => {
      const stored = oldUses.find((old) => grape(old) && sameUse(old, use) &&
        (!present(old.direction_id) || !present(use.direction_id) || old.direction_id === use.direction_id));
      return ratesOf(use).map((rate) => {
        const previous = ratesOf(stored ?? {}).find((old) => rateIdentity(old) === rateIdentity(rate) ||
          equivalentPrintedDose(old, rate));
        return previous && equivalentPrintedDose(previous, rate) ? previous : rate;
      });
    });
    const basisGroups: Array<["per_hectare" | "per_100_litres", string[]]> = [
      ["per_hectare", ["per_hectare", "range_per_hectare"]],
      ["per_100_litres", ["per_100_litres", "range_per_100_litres"]] ];
    for (const [key, bases] of basisGroups) {
      const merged = mergeRates(projected[key], extracted.filter((r) => bases.includes(String(r.basis))));
      if (!merged) return conflict("viticulture_rate_identity_or_value");
      projected[key] = merged;
    }
    if (extracted.length) {
      put("viticulture_rates", oldRates, projected);
      put("label_rate_bases", row.label_rate_bases, [...new Set([...(row.label_rate_bases ?? []),
        ...extracted.map((r) => String(r.basis))])]);
    }
    const sources = row.verification_sources ?? [];
    const numbers = [...new Set((identifiers?.numbers ?? []).filter((n) => /^\d{4,7}$/.test(n)))];
    const printed = [...new Set((identifiers?.printed_values ?? []).filter((value) =>
      /^\d{4,7}(?:\/\d{4,7})*$/.test(value) && value.split("/").every((n) => numbers.includes(n))))];
    const labelSource = { kind: "manufacturer_label", name: "Manufacturer commercial label", reference: label,
      ...(detail.registration?.manufacturer_label_retrieval_method === "web_search_index" ? { retrieval_method: "web_search_index" as const } : {}),
      ...(numbers.length ? { registration_numbers: numbers.map((number) => ({ scheme: "apvma" as const, number,
        source: "manufacturer_label" as const, canonical: number === row.registration_number })),
        printed_registration_values: printed } : {}) };
    const existing = sources.findIndex((s) => s.kind === "manufacturer_label" && s.reference === label);
    const packageUrl = detail.registration?.manufacturer_package_label_url;
    const packageSource = packageUrl && manufacturerHostEligible(packageUrl, row.registration_country, row.registrant) &&
      new URL(packageUrl).host === new URL(label!).host && new URL(packageUrl).pathname.toLowerCase().endsWith(".pdf")
      ? { kind: "manufacturer_label" as const, name: "Manufacturer container label", reference: packageUrl } : null;
    const updated = [...sources];
    if (existing < 0) updated.push(labelSource);
    else if (numbers.length || labelSource.retrieval_method) updated[existing] = { ...sources[existing],
      ...(numbers.length ? { registration_numbers: labelSource.registration_numbers,
        printed_registration_values: labelSource.printed_registration_values } : {}),
      ...(labelSource.retrieval_method ? { retrieval_method: labelSource.retrieval_method } : {}) };
    if (packageSource && !updated.some((source) => source.kind === "manufacturer_label" && source.reference === packageUrl))
      updated.push(packageSource);
    put("verification_sources", sources, updated);
    // label_reference remains regulator-only for older consumers.
  }
  const unresolved = row.verification_unresolved_fields ?? [];
  const resolved = (field: string): boolean => {
    const [kind, ...scope] = field.split(":");
    if (kind.toLowerCase() === "activity_group" && scope.length) {
      const a = trusted.find((item) => String(item.name).toLowerCase() === scope.join(":").toLowerCase());
      return present((a?.activity_group as Record<string, unknown> | null)?.code);
    }
    if (["concentration", "active_ingredients"].includes(kind.toLowerCase()) && scope.length) {
      const a = trusted.find((item) => String(item.name).toLowerCase() === scope.join(":").toLowerCase());
      return present(a?.concentration) && present(a?.concentration_unit) && !!patch.active_ingredients;
    }
    if (["activity_group", "activity_groups"].includes(field.toLowerCase())) return !!codes.length && trusted.every((a) => present((a.activity_group as Record<string, unknown> | null)?.code));
    if (field.toLowerCase() === "active_ingredients") return trusted.length > 0 && !!patch.active_ingredients &&
      trusted.every((a) => present(a.name) && present(a.concentration) && present(a.concentration_unit));
    if (["label_reference", "manufacturer_label"].includes(field.toLowerCase())) return labelReady; // stored as manufacturer_label source, not regulator label_reference
    if (field.toLowerCase() === "re_entry_period_hours" && labelReady) {
      const vines = ((patch.registered_uses ?? row.registered_uses ?? []) as Array<Record<string, unknown>>).filter(grape);
      return vines.length > 0 && vines.every((use) => incoming.some((next) => sameUse(next, use) &&
        (!present(use.direction_id) || !present(next.direction_id) || use.direction_id === next.direction_id) &&
        typeof next.re_entry_period_hours === "number" && next.re_entry_period_hours > 0));
    }
    if (!scope.length || !grapeScope(scope.join(":")) || !labelReady) return false;
    const matching = ((patch.registered_uses ?? row.registered_uses ?? []) as Array<Record<string, unknown>>)
      .filter((u) => grape(u) && (!scope[1] || String(u.target ?? u.target_raw ?? "").toLowerCase() === scope.slice(1).join(":").toLowerCase()));
    if (!matching.length) return false;
    // A stored value alone is not proof that this label pass resolved its marker.
    // Require matching, positively extracted label facts for EVERY scoped use.
    const evidenced = matching.map((use) => incoming.find((next) => sameUse(next, use) &&
      (!present(use.direction_id) || !present(next.direction_id) || use.direction_id === next.direction_id)));
    if (evidenced.some((use) => !use)) return false;
    if (kind.toLowerCase() === "rates") return evidenced.every((u) => ratesOf(u!).some((r) => rateIdentity(r)));
    const keys: Record<string, string[]> = { withholding_period: ["withholding_period_days", "withholding_period_text"],
      re_entry_period: ["re_entry_period_hours", "re_entry_period_text"], restrictions: ["restrictions"],
      statements: ["statements"], conditions: ["conditions"] };
    return !!keys[kind.toLowerCase()] && evidenced.every((u) => keys[kind.toLowerCase()].some((key) =>
      present(u?.[key]) && (typeof u?.[key] !== "number" || (u[key] as number) > 0)));
  };
  const pruned = unresolved.filter((field) => !resolved(field));
  put("verification_unresolved_fields", unresolved, pruned);
  const violation = Object.keys(patch).length ? validateResolverPatch(patch) : null;
  if (violation) throw new Error(`patch_contract_violation: ${violation}`);
  return { status: Object.keys(patch).length ? "preview_ready" : labelReady ? "no_material_change" : "manufacturer_label_not_found",
    patch: Object.keys(patch).length ? patch : null, evidence };
}
