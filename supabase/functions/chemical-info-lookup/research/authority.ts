// Research → existing contract projection, and the authority rules that
// decide what survives the trip.
//
// THE CENTRAL RULE (task §6): web research is DISCOVERY. Nothing here grants
// authority. This module deliberately projects research into the SAME
// intermediate shape the legacy AI prompt produced, so every downstream
// authority mechanism that already exists — `mergeDiscoveryIntoStructured`,
// `discardUnverifiedAiIdentity`, `quarantineUnverifiedAiFacts`,
// `reconcileGroup`, `buildFieldProvenance` — keeps applying unchanged.
//
// That is a design decision, not laziness. Building a second merge path for
// research would create a second provenance system (§17 forbids it) and a
// second place for "APVMA wins" to be got wrong. Instead: research enters
// through the existing AI door, wearing the existing AI provenance, and the
// register still overrules it exactly as before.
//
// What this module DOES enforce on the way in:
//   * a registration number is a LEAD (kept only as a resolver hint),
//   * an Official Label must be a classified label document on a trusted
//     host — SDS, reseller and marketing pages can never occupy the field,
//   * a product page must be registrant-owned,
//   * activity groups are passed as SUGGESTIONS for the authoritative table
//     to overrule.

import type {
  ChemicalResearchResult,
  ResearchRegistrationCandidate,
} from "./schema.ts";
import { classifyUrl, type ClassifiedUrl } from "./classify.ts";

/** Rate bases the existing structured contract accepts (index.ts RATE_BASES). */
const CONTRACT_RATE_BASES = new Set([
  "per_100_litres",
  "per_hectare",
  "range_per_100_litres",
  "range_per_hectare",
  "other",
]);

export interface ResearchProjection {
  /**
   * The legacy-shaped extraction object. Fed to the EXISTING
   * `buildStructuredResponse`, so the client wire contract is byte-identical
   * to what it was before this upgrade.
   */
  extraction: Record<string, unknown>;
  /** Register numbers worth handing to the strict resolver, best first. */
  resolverHints: string[];
  /** Every URL the research produced, server-classified. */
  classified: ClassifiedUrl[];
  /** The label document candidate that passed classification, if any. */
  officialLabelCandidate: ClassifiedUrl | null;
  /** The registrant product page that passed classification, if any. */
  productPageCandidate: ClassifiedUrl | null;
  /** SDS URLs — retained for debugging, NEVER offered as a label. */
  sdsCandidates: ClassifiedUrl[];
  /** URLs rejected as evidence, with the reason. Debug/admin only. */
  rejected: { url: string; reason: string }[];
}

/** Convert a WHP string ("7 days") to the contract's numeric day field. */
function whpDays(raw: string | null): number | null {
  if (!raw) return null;
  const m = /(\d+(?:\.\d+)?)\s*(day|d\b)/i.exec(raw) ?? /^\s*(\d+(?:\.\d+)?)\s*$/.exec(raw);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isFinite(n) ? n : null;
}

/** Convert an REI string ("12 hours", "2 days") to contract hours. */
function reiHours(raw: string | null): number | null {
  if (!raw) return null;
  const hours = /(\d+(?:\.\d+)?)\s*(hour|hr|h\b)/i.exec(raw);
  if (hours) {
    const n = Number(hours[1]);
    return Number.isFinite(n) ? n : null;
  }
  const days = /(\d+(?:\.\d+)?)\s*(day|d\b)/i.exec(raw);
  if (days) {
    const n = Number(days[1]);
    return Number.isFinite(n) ? n * 24 : null;
  }
  return null;
}

/**
 * Score a registration candidate as a RESOLVER HINT. Ordering only: the
 * strict adapter re-verifies whichever number it is handed, so a wrong
 * guess costs one register call, never a wrong answer.
 */
function hintScore(c: ResearchRegistrationCandidate, expectedScheme: string | null): number {
  let score = 0;
  if (c.confidence === "high") score += 3;
  else if (c.confidence === "medium") score += 2;
  else score += 1;
  if (expectedScheme && c.scheme === expectedScheme) score += 2;
  if (c.registered_product_name) score += 1;
  // A candidate read off the register's own site is the best kind of lead.
  const domain = (c.source_domain ?? "").toLowerCase();
  if (/\bapvma\.gov\.au$|\bmpi\.govt\.nz$|\bepa\.govt\.nz$/.test(domain)) score += 3;
  return score;
}

/**
 * Pick the resolver hints for this jurisdiction.
 *
 * COUNTRY IS A HARD BOUNDARY (§12): a candidate whose country differs from
 * the lookup's is dropped outright, so an AU registration can never be fed
 * to an NZ resolution attempt (or vice versa).
 */
export function resolverHintsFor(
  research: ChemicalResearchResult,
  countryCode: string,
  expectedScheme: string | null,
): string[] {
  const code = countryCode.trim().toUpperCase();
  const eligible = research.registration_candidates.filter((c) => {
    const number = (c.number ?? "").trim();
    if (!/^\d{3,8}$/.test(number)) return false;
    if (c.country && c.country.toUpperCase() !== code) return false;
    // A scheme that belongs to a different country is a category error.
    if (c.scheme && expectedScheme && c.scheme !== expectedScheme) return false;
    return true;
  });
  const ranked = [...eligible].sort(
    (a, b) => hintScore(b, expectedScheme) - hintScore(a, expectedScheme),
  );
  const seen = new Set<string>();
  const out: string[] = [];
  for (const c of ranked) {
    const n = (c.number ?? "").trim();
    if (seen.has(n)) continue;
    seen.add(n);
    out.push(n);
  }
  return out;
}

/**
 * Project a research result into the existing extraction shape.
 *
 * Everything produced here is AI-tier by construction. It populates the
 * editable Review draft (§18 — useful values are never thrown away) and is
 * overruled by the register wherever the register speaks (§19).
 */
export function projectResearch(
  research: ChemicalResearchResult,
  countryCode: string,
  expectedScheme: string | null,
): ResearchProjection {
  const classified: ClassifiedUrl[] = [];
  const rejected: { url: string; reason: string }[] = [];
  const seenUrls = new Set<string>();

  const consider = (url: string, declaredKind: ClassifiedUrl["kind"] | null): ClassifiedUrl | null => {
    if (!/^https?:\/\//i.test(url)) return null;
    if (seenUrls.has(url)) {
      return classified.find((c) => c.url === url) ?? null;
    }
    seenUrls.add(url);
    const c = classifyUrl(url, countryCode, { declaredKind });
    classified.push(c);
    return c;
  };

  for (const d of research.documents.official_label_candidates) {
    consider(d.url, "label_document");
  }
  for (const d of research.documents.product_page_candidates) consider(d.url, "product_page");
  for (const d of research.documents.sds_candidates) consider(d.url, "safety_data_sheet");
  for (const s of research.sources) consider(s.url, null);
  for (const c of research.registration_candidates) {
    if (c.source_url) consider(c.source_url, null);
  }

  // Official Label: classification decides, not the model's label. Register-
  // hosted documents outrank registrant-hosted ones.
  const labelCandidates = classified.filter((c) => c.isOfficialLabelCandidate);
  labelCandidates.sort((a, b) => {
    const rank = (t: ClassifiedUrl["trust"]) =>
      t === "official_register" ? 0 : t === "regulator" ? 1 : 2;
    return rank(a.trust) - rank(b.trust);
  });
  const officialLabelCandidate = labelCandidates[0] ?? null;

  for (const d of research.documents.official_label_candidates) {
    const c = classified.find((x) => x.url === d.url);
    if (c && !c.isOfficialLabelCandidate) {
      rejected.push({
        url: d.url,
        reason: `offered as Official Label but classified ${c.kind} on a ${c.trust} host (${c.reason})`,
      });
    }
  }

  const productPageCandidate =
    classified.find((c) => c.isProductPageCandidate && c.kind === "product_page") ??
      classified.find((c) => c.isProductPageCandidate) ?? null;

  const sdsCandidates = classified.filter((c) => c.kind === "safety_data_sheet");

  const active_ingredients = research.active_ingredients.map((a) => ({
    name: a.name,
    concentration: a.concentration,
    concentration_unit: a.concentration_unit,
    // SUGGESTIONS. `reconcileGroup` gets the last word and records conflicts.
    activity_group_code: a.suggested_group,
    activity_group_scheme: a.suggested_scheme,
  }));

  // Multi-target preservation (§22): the contract carries one target per use
  // row, so a use with three targets becomes three rows that share the same
  // crop and rates. Nothing is dropped and no "primary target" is invented.
  const registered_uses: Record<string, unknown>[] = [];
  for (const use of research.registered_uses) {
    const rates = use.rates
      .filter((r) => CONTRACT_RATE_BASES.has(r.basis) || r.raw_text)
      .map((r) => ({
        label: r.label ?? "",
        // A basis the contract does not carry is preserved as "other" WITH
        // its verbatim text, never silently converted to a basis it isn't.
        basis: CONTRACT_RATE_BASES.has(r.basis) ? r.basis : "other",
        value: r.value,
        min_value: r.min_value,
        max_value: r.max_value,
        unit: r.unit ?? "",
        raw_text: r.raw_text ??
          (CONTRACT_RATE_BASES.has(r.basis) ? null : `${r.basis}: ${r.label ?? ""}`.trim()),
      }));
    const targets = use.targets.length > 0 ? use.targets : [""];
    for (const target of targets) {
      registered_uses.push({
        crop: use.crop,
        target,
        rates,
        withholding_period_days: whpDays(use.whp),
        re_entry_period_hours: reiHours(use.rei),
        restrictions: use.restrictions.length ? use.restrictions.join("; ") : null,
      });
    }
  }

  const resolverHints = resolverHintsFor(research, countryCode, expectedScheme);

  const unresolved = [...research.unresolved];
  if (!officialLabelCandidate) unresolved.push("label_reference");

  const extraction: Record<string, unknown> = {
    product_name: research.product.canonical_name ?? research.product.searched_name,
    product_category: research.product.category,
    form_type: research.product.form_type,
    // A LEAD, not a registration. Downstream, `discardUnverifiedAiIdentity`
    // strips this whenever the register was consulted and did not confirm it.
    registration_number: resolverHints[0] ?? null,
    registrant: research.product.registrant ?? research.product.manufacturer,
    label_reference: officialLabelCandidate?.url ?? null,
    label_version: null,
    productURL: productPageCandidate?.url ?? null,
    active_ingredients,
    registered_uses,
    unresolved,
  };

  return {
    extraction,
    resolverHints,
    classified,
    officialLabelCandidate,
    productPageCandidate,
    sdsCandidates,
    rejected,
  };
}

/**
 * Project research into the `search` action's result rows.
 *
 * Search results are DISCOVERY listings. They carry a `source` marker so the
 * client can distinguish store / master / register / research rows (§23) —
 * and a research row is never labelled as a warning: it is simply "another
 * product result".
 */
export function projectResearchToSearchResults(
  research: ChemicalResearchResult,
): Record<string, unknown>[] {
  const groups = research.active_ingredients
    .map((a) => a.suggested_group)
    .filter((g): g is string => Boolean(g));
  const actives = research.active_ingredients
    .map((a) =>
      a.concentration !== null
        ? `${a.name} ${a.concentration}${a.concentration_unit ?? ""}`
        : a.name
    )
    .join(" + ");

  const rows: Record<string, unknown>[] = [];
  const primary = research.product.canonical_name ?? research.product.searched_name;
  if (primary) {
    rows.push({
      name: primary,
      activeIngredient: actives,
      chemicalGroup: groups.join(" + "),
      brand: research.product.manufacturer ?? research.product.registrant ?? "",
      primaryUse: "",
      modeOfAction: groups.join(" + "),
      source: "research",
    });
  }

  // Alternate registered identities the research surfaced are legitimate
  // separate products the operator might have meant.
  for (const c of research.registration_candidates) {
    const name = (c.registered_product_name ?? "").trim();
    if (!name || name.toLowerCase() === (primary ?? "").toLowerCase()) continue;
    rows.push({
      name,
      activeIngredient: actives,
      chemicalGroup: groups.join(" + "),
      brand: research.product.manufacturer ?? research.product.registrant ?? "",
      primaryUse: "",
      modeOfAction: groups.join(" + "),
      source: "research",
      registration_number: c.number ?? undefined,
    });
  }
  return rows;
}
