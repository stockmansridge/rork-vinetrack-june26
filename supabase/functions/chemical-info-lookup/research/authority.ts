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
  ResearchConfidence,
  ResearchRate,
  ResearchRegisteredUse,
  ResearchRegistrationCandidate,
} from "./schema.ts";
import { DIRECTION_SEED_KEY } from "../rate_identity.ts";
import { classifyUrl, type ClassifiedUrl } from "./classify.ts";
import {
  type LinkedDocument,
  selectManufacturerLabel,
  selectManufacturerSds,
} from "./linked_documents.ts";

/**
 * A trusted registrant product page the SERVER fetched and parsed.
 *
 * Structural, not an import of the transport type, so this module stays
 * testable without a network stub — `research/page_inspector.ts`'s
 * `InspectedPage` satisfies it by construction.
 *
 * This is the ONLY admissible source of the page-link relationship that
 * manufacturer-label promotion turns on. Model-supplied `link_text` /
 * `linked_from_url` are discovery hints: they help decide which page is worth
 * fetching, and they never decide what a document IS.
 */
export interface InspectedProductPage {
  /** The URL actually read, after redirects. */
  finalUrl: string;
  /** The product identity the page states about itself (h1/title). */
  pageProductName: string;
  /** Every resolvable anchor found on that page. */
  links: LinkedDocument[];
}

/** Rate bases the existing structured contract accepts (index.ts RATE_BASES). */
const CONTRACT_RATE_BASES = new Set([
  "per_100_litres",
  "per_hectare",
  "range_per_100_litres",
  "range_per_hectare",
  "other",
]);

/**
 * A registration lead, with the registered name it was discovered WITH.
 *
 * THE INVARIANT THIS TYPE EXISTS FOR: a registration number and the register
 * name found alongside it must travel together until the official adapter has
 * verified them. Flattening a candidate to a bare number string was a real
 * production defect — APVMA 59688 was discovered correctly, then re-resolved
 * against the operator's original query ("Dithane Rainshield") instead of the
 * discovered register name ("Dithane Rainshield Neo Tec Fungicide"). The
 * strict matcher rightly refused to call those the same product, because NEO
 * and TEC are meaningful remaining tokens, and the lead was discarded.
 *
 * The fix belongs here, in the handoff — NOT in the matcher. Nothing about
 * this type grants authority: the adapter still independently checks that the
 * number exists and that its register name corresponds to the name supplied.
 */
export interface ResearchResolverHint {
  /** Register number, digits as the register prints them. */
  registrationNumber: string;
  /** The register name discovered WITH this number, if the research had one. */
  registeredProductName: string | null;
  /** The name the strict adapter should verify this number against (§5). */
  verificationName: string;
  /** Where `verificationName` came from — telemetry and tests read this. */
  verificationNameSource:
    | "candidate_registered_name"
    | "canonical_product_name"
    | "operator_query";
  country: string;
  scheme: string | null;
  sourceUrl: string | null;
  sourceDomain: string | null;
  confidence: ResearchConfidence;
}

export interface ResearchProjection {
  /**
   * The legacy-shaped extraction object. Fed to the EXISTING
   * `buildStructuredResponse`, so the client wire contract is byte-identical
   * to what it was before this upgrade.
   */
  extraction: Record<string, unknown>;
  /** Registration leads worth handing to the strict resolver, best first. */
  resolverHints: ResearchResolverHint[];
  /** Every URL the research produced, server-classified. */
  classified: ClassifiedUrl[];
  /** The label document candidate that passed classification, if any. */
  officialLabelCandidate: ClassifiedUrl | null;
  /** The registrant product page that passed classification, if any. */
  productPageCandidate: ClassifiedUrl | null;
  /**
   * The registrant-hosted label, promoted from a trusted product-page link
   * relationship.
   *
   * COMPLEMENTARY evidence. It never touches registration identity — the
   * register remains the authority for the number, the registered name and
   * the registrant. This is the practical label document.
   */
  manufacturerLabelCandidate: ClassifiedUrl | null;
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
): ResearchResolverHint[] {
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

  const canonical = (research.product.canonical_name ?? "").trim();
  const query = (research.product.searched_name ?? "").trim();
  // The canonical name may only stand in for a candidate that has no register
  // name of its own when there is exactly ONE eligible candidate — then the
  // canonical name is demonstrably about that identity. With two or more
  // candidates in play, borrowing it would risk pairing candidate A's number
  // with candidate B's name, which §5 forbids outright.
  const canonicalIsUnambiguous = eligible.length === 1 && canonical.length > 0;

  const seen = new Set<string>();
  const out: ResearchResolverHint[] = [];
  for (const c of ranked) {
    const n = (c.number ?? "").trim();
    if (seen.has(n)) continue;
    seen.add(n);

    const registered = (c.registered_product_name ?? "").trim();
    let verificationName = registered;
    let verificationNameSource: ResearchResolverHint["verificationNameSource"] =
      "candidate_registered_name";
    if (!verificationName && canonicalIsUnambiguous) {
      verificationName = canonical;
      verificationNameSource = "canonical_product_name";
    }
    if (!verificationName) {
      verificationName = query;
      verificationNameSource = "operator_query";
    }
    if (!verificationName) continue;

    out.push({
      registrationNumber: n,
      registeredProductName: registered || null,
      verificationName,
      verificationNameSource,
      country: (c.country || code).toUpperCase(),
      scheme: c.scheme,
      sourceUrl: c.source_url,
      sourceDomain: c.source_domain,
      confidence: c.confidence,
    });
  }
  return out;
}

/** One strict re-resolution attempt: a number and the name to verify it against. */
export interface ResolverAttempt {
  number: string;
  name: string;
  source: ResearchResolverHint["verificationNameSource"] | "legacy_ai_number";
}

/**
 * Build the bounded list of strict re-resolution attempts for a lead set.
 *
 * Each attempt keeps its number with the name that number was discovered
 * with (§3/§4). The operator's own query is appended ONCE, against the best
 * lead, for the case where research mis-transcribed the register name but
 * the number is right — so this can never become a brute-force search.
 */
export function buildResolverAttempts(
  hints: ResearchResolverHint[],
  operatorQuery: string,
  legacyAiNumber?: string | null,
  maxHints = 2,
): ResolverAttempt[] {
  const attempts: ResolverAttempt[] = hints
    .filter((h) => /^\d{3,8}$/.test(h.registrationNumber))
    .slice(0, maxHints)
    .map((h) => ({
      number: h.registrationNumber,
      name: h.verificationName,
      source: h.verificationNameSource,
    }));

  const legacy = (legacyAiNumber ?? "").trim();
  if (!attempts.length && /^\d{3,8}$/.test(legacy)) {
    attempts.push({ number: legacy, name: operatorQuery, source: "legacy_ai_number" });
  }

  const best = attempts[0];
  const query = operatorQuery.trim();
  if (best && query && best.name.trim().toLowerCase() !== query.toLowerCase()) {
    attempts.push({ number: best.number, name: query, source: "operator_query" });
  }
  return attempts;
}

// ---------------------------------------------------------------------------
// Use contexts — a rate belongs to the targets it was written for
// ---------------------------------------------------------------------------

/** Normalised comparison key for a rate row. */
function rateKey(r: ResearchRate): string {
  return [r.basis, r.value, r.min_value, r.max_value, (r.unit ?? "").toLowerCase()].join("|");
}

/** Normalised comparison key for everything that defines a use CONTEXT. */
function useContextKey(u: ResearchRegisteredUse): string {
  const rates = u.rates.map(rateKey).sort().join("~");
  const restrictions = [...u.restrictions].map((r) => r.trim().toLowerCase()).sort().join("~");
  return [
    u.crop.trim().toLowerCase(),
    rates,
    (u.whp ?? "").trim().toLowerCase(),
    (u.rei ?? "").trim().toLowerCase(),
    restrictions,
  ].join("||");
}

function normaliseTargetText(raw: string): string {
  return raw.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

/**
 * Split a multi-target use whose rate rows name the targets they belong to.
 *
 * The live Dithane research returned ONE use carrying three targets and two
 * different rates, which the naive projection then copied onto all three —
 * so Phomopsis appeared to accept 200 g/100 L and Blackspot appeared to
 * accept 150–200 g/100 L. Neither is what the label says.
 *
 * This is deliberately CONSERVATIVE and text-driven, never inferential: a
 * rate is attached to a target only when the rate's own label/verbatim text
 * names that target. If no rate names any target, nothing is split — the
 * grouping stays exactly as the model returned it and the prompt (§11) is
 * what has to do the work. Research-tier data only; label extraction still
 * overrules all of it (§12).
 */
export function splitUseByTargetSpecificRates(
  use: ResearchRegisteredUse,
): ResearchRegisteredUse[] {
  if (use.targets.length < 2 || use.rates.length < 2) return [use];

  const targetTexts = use.targets.map((t) => normaliseTargetText(t)).filter((t) => t.length > 2);
  if (targetTexts.length !== use.targets.length) return [use];

  const mentions = use.rates.map((r) => {
    const hay = normaliseTargetText(`${r.label ?? ""} ${r.raw_text ?? ""}`);
    if (!hay) return new Set<number>();
    const hit = new Set<number>();
    targetTexts.forEach((t, i) => {
      if (hay.includes(t)) hit.add(i);
    });
    return hit;
  });

  const anyTargeted = mentions.some((m) => m.size > 0);
  const allUniversal = mentions.every((m) => m.size === use.targets.length);
  // Nothing to learn from the text, or every rate applies to every target.
  if (!anyTargeted || allUniversal) return [use];

  const perTarget: ResearchRegisteredUse[] = use.targets.map((target, i) => {
    const own = use.rates.filter((_, j) => mentions[j].has(i));
    // A rate that names no target at all is a general rate for this use.
    const general = use.rates.filter((_, j) => mentions[j].size === 0);
    const rates = own.length ? own : general;
    return { ...use, targets: [target], rates };
  });
  // A split that would strip a target's rates entirely is worse than no
  // split — fail back to the model's grouping rather than lose data.
  if (perTarget.some((u) => u.rates.length === 0)) return [use];
  return perTarget;
}

/**
 * Regroup research uses into genuine label CONTEXTS.
 *
 * Targets share one context ONLY when crop, rate set, WHP, REI and
 * restrictions are all equivalent (§10). Targets are never merged merely
 * because they appeared in the same label table, and a rate is never copied
 * onto a target that does not share its context.
 */
export function groupResearchUseContexts(
  uses: ResearchRegisteredUse[],
): ResearchRegisteredUse[] {
  const split = uses.flatMap((u) => splitUseByTargetSpecificRates(u));
  const byContext = new Map<string, ResearchRegisteredUse>();
  for (const use of split) {
    const key = useContextKey(use);
    const existing = byContext.get(key);
    if (!existing) {
      byContext.set(key, { ...use, targets: [...use.targets] });
      continue;
    }
    for (const t of use.targets) {
      const already = existing.targets.some(
        (x) => normaliseTargetText(x) === normaliseTargetText(t),
      );
      if (!already) existing.targets.push(t);
    }
    for (const ref of use.source_refs) {
      if (!existing.source_refs.includes(ref)) existing.source_refs.push(ref);
    }
  }
  return Array.from(byContext.values());
}

/**
 * Promote registrant documents from SERVER-INSPECTED product pages.
 *
 * Split out so the promotion rule is testable on its own and so
 * `projectResearch` reads as a pipeline rather than hiding a security-relevant
 * decision inside a loop.
 *
 * Two hard preconditions, both of which return nothing rather than a guess:
 *
 *   * the register must already have NAMED the product — identity is the
 *     register's, and without it there is nothing to check a page against;
 *   * the page must have been FETCHED AND PARSED by the server. Promotion is
 *     reproducible from bytes or it does not happen.
 */
function promoteFromInspectedPages(input: {
  inspectedPages: InspectedProductPage[];
  countryCode: string;
  registeredProductName?: string | null;
  classified: ClassifiedUrl[];
  rejected: { url: string; reason: string }[];
}): { label: ClassifiedUrl | null; sds: ClassifiedUrl | null } {
  const registeredName = (input.registeredProductName ?? "").trim();
  if (!registeredName) return { label: null, sds: null };

  let label: ClassifiedUrl | null = null;
  let sds: ClassifiedUrl | null = null;

  for (const page of input.inspectedPages) {
    // The inspector only fetches pages that already classify as trusted
    // registrant product pages, and re-classifying the FINAL url here closes
    // the redirect gap: what was read is what gets judged.
    const pageClass = classifyUrl(page.finalUrl, input.countryCode);
    const context = {
      page: { pageUrl: page.finalUrl, pageProductName: page.pageProductName },
      // The page was FETCHED, so the question is no longer "is this domain on
      // a list?" but "did this page prove what it is?". `selectManufacturerLabel`
      // answers that deterministically: the page's own stated product must
      // correspond to the register-resolved name, and the PDF must sit on the
      // page's own host. Requiring allowlist membership on TOP of that proof
      // is what kept real registrant labels — Vicchem's among them — out of
      // the pipeline entirely.
      pageIsTrustedProductPage: pageClass.isInspectableProductPage,
      pageIsVerifiedRegistrantDomain: pageClass.trust === "registrant",
      registeredProductName: registeredName,
      documents: page.links.filter((l) => l.url !== page.finalUrl),
    };

    const selection = selectManufacturerLabel(context);
    if (!label && selection.label) {
      const existing = input.classified.find((c) => c.url === selection.label!.url);
      label = {
        ...(existing ?? classifyUrl(selection.label.url, input.countryCode)),
        kind: "label_document",
        isOfficialLabelCandidate: true,
        reason: selection.reason,
      };
    } else {
      for (const r of selection.rejected) {
        input.rejected.push({ url: r.url, reason: `${r.outcome}: ${r.reason}` });
      }
    }

    // The SDS is collected under its OWN identity from the same inspection.
    // Its URL usually carries no `sds` token either, so URL-only
    // classification misses it for exactly the reason it missed the label.
    const sdsSelection = selectManufacturerSds(context);
    if (!sds && sdsSelection.sds) {
      const existing = input.classified.find((c) => c.url === sdsSelection.sds!.url);
      sds = {
        ...(existing ?? classifyUrl(sdsSelection.sds.url, input.countryCode)),
        kind: "safety_data_sheet",
        isOfficialLabelCandidate: false,
        reason: sdsSelection.reason,
      };
    }
  }

  return { label, sds };
}

/**
 * Record model-supplied relationship metadata as what it now is: a hint.
 *
 * Kept for discovery and debugging — it is how the pipeline learns a page is
 * worth fetching. Writing the refusal down matters because "the model said
 * this was the label" is exactly the claim a future investigation will need to
 * see was considered and declined.
 */
function noteUninspectedModelHints(
  research: ChemicalResearchResult,
  inspectedPages: InspectedProductPage[],
  rejected: { url: string; reason: string }[],
): void {
  const inspected = new Set(inspectedPages.map((p) => p.finalUrl));
  for (
    const d of [
      ...research.documents.official_label_candidates,
      ...research.documents.product_page_candidates,
      ...research.documents.sds_candidates,
    ]
  ) {
    const from = (d.linked_from_url ?? "").trim();
    const text = (d.link_text ?? "").trim();
    if (!from || !text) continue;
    if (inspected.has(from)) continue;
    rejected.push({
      url: d.url,
      reason:
        `model_relationship_hint_only: the model reported this as "${text}" on ` +
        `${from}, but that page was not inspected by the server — manufacturer ` +
        `label promotion requires evidence re-derivable from the fetched page`,
    });
  }
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
  /**
   * The REGISTER-resolved product name, when the register has already spoken.
   *
   * Required before any registrant PDF may be promoted to a label: identity
   * belongs to the register, and a page about a different product cannot
   * confer label status on its documents. Absent means no promotion at all.
   */
  registeredProductName?: string | null,
  /**
   * Trusted registrant product pages the server FETCHED and parsed this pass.
   *
   * Empty means no manufacturer-label promotion, full stop — even when the
   * model volunteered a perfectly plausible relationship. Evidence that cannot
   * be re-derived from bytes is not evidence.
   */
  inspectedPages: InspectedProductPage[] = [],
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

  // A page that EARNED it: an unrecognised host whose fetched page stated the
  // register-resolved product and yielded the manufacturer label is the
  // manufacturer's product page, whatever an allowlist thinks. Computed after
  // promotion below, so it is assigned once the label is known.
  let earnedProductPage: ClassifiedUrl | null = null;

  const sdsCandidates = classified.filter((c) => c.kind === "safety_data_sheet");


  // ---- Manufacturer label via a trusted product-page relationship ---------
  //
  // `classifyUrl` reads the URL alone, so a registrant label whose filename
  // carries no label signature classifies as a generic PDF and never becomes
  // evidence — taking its rate table and its re-entry condition with it.
  //
  // Promotion is deliberately narrow: the link must have been found ON the
  // registrant's own product page, that page must be about the
  // register-resolved product, the PDF must be on the same host, and the link
  // text must say label without saying SDS/brochure/TDS. Anything looser
  // promotes marketing collateral to label authority.
  const promoted = promoteFromInspectedPages({
    inspectedPages,
    countryCode,
    registeredProductName,
    classified,
    rejected,
  });
  const manufacturerLabelCandidate = promoted.label;
  if (!productPageCandidate && manufacturerLabelCandidate) {
    const source = inspectedPages.find((p) =>
      manufacturerLabelCandidate.url.startsWith(new URL(p.finalUrl).origin)
    );
    if (source) {
      earnedProductPage = {
        ...classifyUrl(source.finalUrl, countryCode),
        kind: "product_page",
        isProductPageCandidate: true,
        reason:
          `identified as the registrant's product/catalogue page after its own-host label link ` +
          `corresponded to the register-resolved product (page heading "${source.pageProductName}")`,
      };
    }
  }
  noteUninspectedModelHints(research, inspectedPages, rejected);

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
  //
  // Rates are bound to their OWN context first (§9/§10): targets share a rate
  // set only when crop, rates, WHP, REI and restrictions all agree, so a rate
  // can never be copied onto a target the label did not give it to.
  const registered_uses: Record<string, unknown>[] = [];
  for (const use of groupResearchUseContexts(research.registered_uses)) {
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
    // Gate D1.2 — ONE printed direction, ONE identity. The loop below fans the
    // direction into one row per target, destroying its complete target set,
    // so the grouping has to be captured BEFORE that happens or the identity
    // would later be derived from a single surviving pest.
    //
    // Gate D1.3 — but it is captured as a SEED, not minted as an identity.
    // `direction_id` is product-bound, and at this point the registration is
    // still an unconfirmed research LEAD that `discardUnverifiedAiIdentity`
    // may strip. Minting here produced a product-less hash that downstream
    // then honoured verbatim, so the SAME printed direction reaching the app
    // through research carried a different identity than through the
    // manufacturer label — for what is one registered direction of one
    // product.
    //
    // The seed is internal only: never exposed as `direction_id`, never
    // stored, and removed once the register locks identity and the real ids
    // are minted against the resolved product.
    const directionSeed = {
      crop: use.crop,
      targets: [...use.targets],
      condition: null,
    };

    const targets = use.targets.length > 0 ? use.targets : [""];
    for (const target of targets) {
      registered_uses.push({
        crop: use.crop,
        target,
        [DIRECTION_SEED_KEY]: { ...directionSeed, targets: [...directionSeed.targets] },
        // Each projected row gets its OWN rate objects. Sharing one object
        // across the fan-out is what let a later in-place stamp overwrite
        // every sibling row's identity — "last write wins" on a value that
        // must not depend on processing order at all.
        rates: rates.map((r) => ({ ...r })),
        withholding_period_days: whpDays(use.whp),
        // The withholding WORDING, for the same reason as the re-entry wording
        // below: `whpDays` refuses to invent a number for a period it cannot
        // parse, and with nowhere to put the words the whole instruction was
        // dropped. The wording is the legal instruction; the day count is only
        // its scheduling projection.
        withholding_statement: (use.whp ?? "").trim() || null,
        re_entry_period_hours: reiHours(use.rei),
        // The SAME defect, in the second path: `reiHours` correctly refuses to
        // invent a number for "until the spray has dried", and without a field
        // for the wording the whole rule was dropped and rendered as "not
        // stated". The verbatim text travels alongside the hours, never
        // instead of them.
        re_entry_statement: (use.rei ?? "").trim() || null,
        restrictions: use.restrictions.length ? use.restrictions.join("; ") : null,
      });
    }
  }

  const resolverHints = resolverHintsFor(research, countryCode, expectedScheme);

  const unresolved = [...research.unresolved];
  // A manufacturer label IS a label. `label_reference` is unresolved only when
  // neither source produced one.
  if (!officialLabelCandidate && !manufacturerLabelCandidate) {
    unresolved.push("label_reference");
  }

  const extraction: Record<string, unknown> = {
    product_name: research.product.canonical_name ?? research.product.searched_name,
    product_category: research.product.category,
    form_type: research.product.form_type,
    // A LEAD, not a registration. Downstream, `discardUnverifiedAiIdentity`
    // strips this whenever the register was consulted and did not confirm it.
    registration_number: resolverHints[0]?.registrationNumber ?? null,
    registrant: research.product.registrant ?? research.product.manufacturer,
    // The REGULATOR's approved label stays in the legacy field — it is the
    // authoritative document and what existing clients already decode.
    label_reference: officialLabelCandidate?.url ?? null,
    label_version: null,
    // Additive, each with its own provenance. Never collapsed into one URL:
    // losing the distinction is how a marketing PDF becomes the label.
    manufacturer_label_url: manufacturerLabelCandidate?.url ?? null,
    regulator_label_url: officialLabelCandidate?.url ?? null,
    // URL-signature classification first (it is the stronger signal when it
    // fires), then the inspected page's own SDS link — which is how an SDS
    // whose filename says nothing still reaches the operator.
    sdsURL: sdsCandidates[0]?.url ?? promoted.sds?.url ?? null,
    productURL: productPageCandidate?.url ?? earnedProductPage?.url ?? null,
    active_ingredients,
    registered_uses,
    unresolved,
  };

  return {
    extraction,
    resolverHints,
    classified,
    officialLabelCandidate,
    productPageCandidate: productPageCandidate ?? earnedProductPage,
    manufacturerLabelCandidate,
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
  countryCode?: string,
  expectedScheme?: string | null,
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

  // The identity the primary row belongs to, so selecting it hands the NEXT
  // structured lookup a number it no longer has to rediscover (§6). Matched
  // by name against the candidate list — never "the first candidate", which
  // would risk stamping candidate A's number onto product B.
  const code = (countryCode ?? research.product.country ?? "").trim().toUpperCase();
  const primaryNorm = (primary ?? "").trim().toLowerCase();
  const primaryCandidate = code
    ? resolverHintsFor(research, code, expectedScheme ?? null).find(
      (h) => (h.registeredProductName ?? "").trim().toLowerCase() === primaryNorm,
    ) ?? null
    : null;

  if (primary) {
    rows.push({
      name: primary,
      activeIngredient: actives,
      chemicalGroup: groups.join(" + "),
      brand: research.product.manufacturer ?? research.product.registrant ?? "",
      primaryUse: "",
      modeOfAction: groups.join(" + "),
      source: "research",
      ...(primaryCandidate
        ? {
          registration_number: primaryCandidate.registrationNumber,
          registration_country: primaryCandidate.country,
          registration_scheme: primaryCandidate.scheme ?? undefined,
        }
        : {}),
    });
  }

  // Alternate registered identities the research surfaced are legitimate
  // separate products the operator might have meant. Each keeps its OWN
  // number/name pairing.
  for (const c of research.registration_candidates) {
    const name = (c.registered_product_name ?? "").trim();
    if (!name || name.toLowerCase() === primaryNorm) continue;
    rows.push({
      name,
      activeIngredient: actives,
      chemicalGroup: groups.join(" + "),
      brand: research.product.manufacturer ?? research.product.registrant ?? "",
      primaryUse: "",
      modeOfAction: groups.join(" + "),
      source: "research",
      registration_number: c.number ?? undefined,
      registration_country: (c.country || code) || undefined,
      registration_scheme: c.scheme ?? undefined,
    });
  }
  return rows;
}
