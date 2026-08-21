// Ingestion orchestration — turns an unknown commercial chemical into a
// structured, deduplicated Master CANDIDATE (Stage 3 §§B–D, F, J).
//
// Lifecycle (docs/master-chemical-ingestion.md):
//   grower search → same-country approved-master lookup → authoritative
//   discovery (registry-selected adapter) → structured candidate →
//   registration-identity dedupe → candidate enqueue/refresh → admin review.
//
// Non-negotiables enforced here:
//   * Candidates only. `review_status` is the literal type "candidate"; this
//     module cannot mint approved rows (and sql/199's CHECK backs that up).
//   * Registration identity is the ONLY dedupe key; name spelling never
//     creates a second row for the same registration.
//   * AI evidence never overwrites an authoritative candidate.
//   * Source disagreements become structured verification_conflicts and the
//     evidence state "conflict" — never a silent winner.
//   * Facts an authoritative source does not provide stay unresolved.

// deno-lint-ignore-file no-explicit-any

import { normaliseActiveName } from "./activity_groups.ts";
import type {
  AdapterDeps,
  CandidateRowPayload,
  DiscoveryOutcome,
  DiscoveryResult,
  MasterOps,
  MasterRow,
  RegisterCandidate,
  ResolvedRegistration,
  WireConflict,
  WireDataSource,
} from "./contract.ts";
import { identityKey } from "./contract.ts";
import { mergeLabelEvidenceIntoUses } from "./label.ts";
import { adapterFor } from "./registry.ts";
import {
  CANDIDATE_EVIDENCE_MAX_AGE_MS,
  materialChanges,
} from "./refresh.ts";

// ---------------------------------------------------------------------------
// Discovery entry point (jurisdiction fail-closed)
// ---------------------------------------------------------------------------

/**
 * Run authoritative discovery for a resolved vineyard country.
 *
 * No country → no ingestion (fail closed, mirrors the apps' jurisdiction
 * gate; the device locale is never consulted). Unsupported country → the
 * lookup continues on the existing AI path, explicitly marked as such.
 * Adapter errors are contained: discovery can say "source_unavailable" but
 * can never break the lookup.
 */
export async function discoverAuthoritative(
  countryCode: string,
  query: string,
  hintRegistrationNumber: string | null,
  deps: AdapterDeps,
): Promise<DiscoveryResult> {
  const code = countryCode.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) {
    return { outcome: "no_country", adapter: null, cache: "none" };
  }
  const adapter = adapterFor(code);
  if (!adapter) {
    return { outcome: "not_supported", adapter: null, cache: "none" };
  }
  try {
    return await adapter.discover(query, hintRegistrationNumber, deps);
  } catch (err) {
    // Adapters contain their own failures; this is belt-and-braces so a bug
    // can never take the Chemical Store down with it.
    console.error(
      "authoritative discovery crashed:",
      err instanceof Error ? err.message : String(err),
    );
    return {
      outcome: "source_unavailable",
      adapter: adapter.id,
      error_category: "unexpected_error",
      cache: "none",
    };
  }
}

/**
 * Free-text register CANDIDATE discovery for human search listings.
 *
 * Same jurisdiction gate as `discoverAuthoritative` — the resolved vineyard
 * country (and only the registry) selects the adapter; no country or no
 * adapter means no register candidates, never a foreign register. Discovery
 * is NOT verification: candidates are identity/display rows a human picks
 * from, and the strict resolver then re-establishes identity on the exact
 * selection. Fail-soft everywhere: any failure returns [] so a register
 * hiccup can never break search.
 */
export async function discoverRegisterCandidates(
  countryCode: string,
  query: string,
  deps: AdapterDeps,
  limit = 6,
): Promise<RegisterCandidate[]> {
  const code = countryCode.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) return [];
  const adapter = adapterFor(code);
  if (!adapter?.discoverCandidates) return [];
  try {
    return await adapter.discoverCandidates(query, deps, limit);
  } catch (err) {
    console.error(
      "register candidate discovery crashed:",
      err instanceof Error ? err.message : String(err),
    );
    return [];
  }
}

// ---------------------------------------------------------------------------
// Merge: register evidence over the AI extraction
// ---------------------------------------------------------------------------

function formatActiveDisplay(a: any): string {
  const conc = a?.concentration != null
    ? ` ${a.concentration}${a?.concentration_unit ? ` ${a.concentration_unit}` : ""}`
    : "";
  return `${String(a?.name ?? "").trim()}${conc}`.trim();
}

function recomputeGroups(actives: any[]): { codes: string[]; scheme: string | null } {
  const codes = Array.from(
    new Set(
      actives
        .map((a) => a?.activity_group?.code)
        .filter((c: string | undefined): c is string => Boolean(c)),
    ),
  );
  const scheme = actives
    .map((a) => a?.activity_group?.scheme)
    .find((s: string | undefined) => s && s !== "not_applicable") ?? null;
  return { codes, scheme };
}

/**
 * Merge a resolved register identity into an AI structured extraction.
 *
 * The register wins on everything it actually asserts (identity, registrant,
 * actives + concentrations, category/form, current label approval). The AI
 * extraction keeps contributing what the register extract cannot provide —
 * registered uses, rates, WHP — with its own honest attribution. Where the
 * two DISAGREE on a register-asserted fact, the register value is served AND
 * a structured conflict is recorded, forcing the evidence state to
 * "conflict" for a human to resolve.
 */
export function mergeDiscoveryIntoStructured(
  structured: any,
  reg: ResolvedRegistration,
): any {
  const merged = { ...structured };
  const conflicts: WireConflict[] = Array.isArray(structured?.verification?.conflicts)
    ? [...structured.verification.conflicts]
    : [];

  // ---- Registration identity (register-authoritative) --------------------
  const aiReg = structured?.registration ?? {};
  const aiNumber = String(aiReg?.registration_number ?? "").trim();
  if (aiNumber && aiNumber.toUpperCase() !== reg.registration_number.toUpperCase()) {
    conflicts.push({
      field: "registration_number",
      extracted_value: aiNumber,
      authoritative_value: reg.registration_number,
      extracted_source: "ai_interpretation",
      authoritative_source: "official_register",
    });
  }

  merged.registration = {
    ...aiReg,
    country_code: reg.country_code,
    scheme: reg.scheme,
    registration_number: reg.registration_number,
    registrant: reg.registrant ?? aiReg?.registrant ?? null,
    registered_product_name: reg.registered_product_name,
    // Stage LD-1: the register-confirmed label DOCUMENT wins; an AI-supplied
    // URL is only carried when no authoritative document was discovered.
    label_reference: reg.label_document?.url ?? aiReg?.label_reference ?? null,
    label_version: reg.label_version ?? aiReg?.label_version ?? null,
  };
  merged.product_name = reg.registered_product_name;
  merged.product_category = reg.product_category ?? structured?.product_category ?? "";
  merged.form_type = reg.form_type ?? structured?.form_type ?? null;

  // ---- Actives (register chemistry wins; disagreements become conflicts) --
  const aiActives: any[] = Array.isArray(structured?.active_ingredients)
    ? structured.active_ingredients
    : [];
  let mergedActives: any[] = aiActives;
  if (reg.active_ingredients.length) {
    const registerNames = new Set(
      reg.active_ingredients.map((a) => normaliseActiveName(a.name)),
    );
    for (const regActive of reg.active_ingredients) {
      const aiMatch = aiActives.find(
        (a) => normaliseActiveName(String(a?.name ?? "")) === normaliseActiveName(regActive.name),
      );
      if (
        aiMatch &&
        aiMatch?.concentration != null &&
        regActive.concentration != null &&
        (Number(aiMatch.concentration) !== Number(regActive.concentration) ||
          (String(aiMatch?.concentration_unit ?? "").toLowerCase() !==
              String(regActive.concentration_unit ?? "").toLowerCase() &&
            Boolean(aiMatch?.concentration_unit)))
      ) {
        conflicts.push({
          field: "concentration",
          active_ingredient_name: regActive.name,
          extracted_value: formatActiveDisplay(aiMatch),
          authoritative_value: formatActiveDisplay(regActive),
          extracted_source: "ai_interpretation",
          authoritative_source: "official_register",
        });
      }
    }
    for (const aiActive of aiActives) {
      const name = String(aiActive?.name ?? "").trim();
      if (name && !registerNames.has(normaliseActiveName(name))) {
        conflicts.push({
          field: "active_ingredients",
          active_ingredient_name: name,
          extracted_value: "extracted as an active ingredient",
          authoritative_value: "not an active constituent of this registration",
          extracted_source: "ai_interpretation",
          authoritative_source: "official_register",
        });
      }
    }
    mergedActives = reg.active_ingredients;
  }
  merged.active_ingredients = mergedActives;

  const { codes, scheme } = recomputeGroups(mergedActives);
  merged.activity_groups = codes;
  merged.activity_group_scheme = scheme;

  // ---- Registered uses (label evidence ONLY) ------------------------------
  // On a register-resolved product the authoritative label evidence is the
  // ONLY source that can populate registered_uses. When it resolves, the
  // label's claim set IS the served uses: label-stated WHP/re-entry/
  // restrictions win (AI disagreements become conflicts), AI rates ride
  // along clearly attributed, and AI-only uses are dropped as conflicts.
  // Without label evidence the field stays honestly UNRESOLVED — AI-read
  // uses move to the clearly-non-authoritative `ai_suggested_uses` envelope
  // instead of standing in the authoritative field. An unsupported guess
  // never overwrites an unresolved fact.
  const aiUses: any[] = Array.isArray(structured?.registered_uses)
    ? structured.registered_uses
    : [];
  const evidence = reg.label_evidence ?? null;
  let uses: any[] = [];
  if (evidence && evidence.claims.length) {
    const labelMerge = mergeLabelEvidenceIntoUses(aiUses, evidence);
    uses = labelMerge.uses;
    for (const c of labelMerge.conflicts) conflicts.push(c);
    // Stage LD-2: label DOCUMENT vs register-statement disagreements (both
    // manufacturer_label) always surface for review — never silently won.
    for (const c of evidence.document_conflicts ?? []) conflicts.push(c);
  } else if (aiUses.length) {
    merged.ai_suggested_uses = aiUses;
  }
  merged.registered_uses = uses;
  merged.label_rate_bases = Array.from(
    new Set(uses.flatMap((u: any) => (u?.rates ?? []).map((r: any) => r?.basis).filter(Boolean))),
  );
  // Stage LD-2 (additive envelope): document-extraction provenance plus the
  // verbatim DFU rows the fail-closed binder refused to attach. Present ONLY
  // when a document text pass actually completed — timeout/404/extraction
  // failure leaves the response byte-identical to a no-extraction lookup.
  if (evidence?.document) {
    merged.label_extraction = {
      document_url: evidence.document.url,
      document_sha256: evidence.document.sha256,
      parser_version: evidence.document.parser_version,
      unbound_rows: evidence.unbound_rows ?? [],
    };
  }

  // ---- Evidence: sources, unresolved, status ------------------------------
  const sources: WireDataSource[] = Array.isArray(structured?.verification?.sources)
    ? [...structured.verification.sources]
    : [];
  for (const s of reg.sources) {
    if (!sources.some((x) => x?.kind === s.kind && x?.name === s.name)) sources.push(s);
  }

  const unresolved = new Set<string>(
    Array.isArray(structured?.verification?.unresolved_fields)
      ? structured.verification.unresolved_fields
      : [],
  );
  unresolved.delete("registration_number");
  unresolved.delete("registration");
  unresolved.delete("country");
  if (merged.registration.label_version) unresolved.delete("label_version");
  // Per-active gaps are recomputed from the MERGED actives.
  for (const entry of Array.from(unresolved)) {
    if (/^(concentration|activity_group|active_ingredient):/.test(entry)) unresolved.delete(entry);
  }
  unresolved.delete("active_ingredients");
  for (const a of mergedActives) {
    if (a?.concentration == null) unresolved.add(`concentration:${a.name}`);
    if (!a?.activity_group) unresolved.add(`activity_group:${a.name}`);
  }
  if (!mergedActives.length) unresolved.add("active_ingredients");
  for (const f of reg.unresolved_fields) {
    if (f === "registered_uses" && uses.length) continue;
    if (f === "label_reference" && merged.registration.label_reference) continue;
    if (f === "active_ingredients" && mergedActives.length) continue;
    unresolved.add(f);
  }
  if (evidence && evidence.claims.length) {
    // Label evidence resolved the claim set; the AI-era whole-array gap goes,
    // replaced by the evidence's own per-context gaps (rates:<crop>,
    // withholding_period:<crop>…) carried in reg.unresolved_fields above.
    unresolved.delete("registered_uses");
    if (evidence.claims.every((c) => c.re_entry_period_hours !== undefined)) {
      unresolved.delete("re_entry_period_hours");
    }
  }

  merged.verification = {
    ...(structured?.verification ?? {}),
    status: conflicts.length
      ? "conflict"
      : mergedActives.length
      ? "partially_verified"
      : "unverified",
    sources,
    conflicts,
    unresolved_fields: Array.from(unresolved).sort(),
    verified_at: null,
  };
  merged.field_provenance = buildFieldProvenance(
    merged,
    reg,
    Boolean(evidence && evidence.claims.length),
  );
  // Contract invariant: entries the register/label just resolved must not
  // survive from the AI extraction's unresolved list (see prune JSDoc).
  pruneAuthoritativelyResolvedFields(merged);
  merged.match_source = "authoritative_candidate";
  return merged;
}

/**
 * Discard unverified AI registration-identity claims.
 *
 * Called when the jurisdiction's register was CONSULTED and did not verify
 * (outcome unresolved/ambiguous — an outage keeps today's honesty-labelled
 * behaviour instead, because "could not check" is not "checked and wrong").
 * The AI's number already had its chance to verify as a discovery pointer;
 * past that, AI assists discovery but never establishes registration: the
 * number/scheme/registered-name claims are removed and the field goes
 * honestly unresolved. Returns the discarded number for the discovery
 * envelope. The rest of the AI extraction is then quarantined by
 * quarantineUnverifiedAiFacts — on a checked-but-unverified consult NO
 * AI-derived product fact stays in the canonical fields.
 */
export function discardUnverifiedAiIdentity(
  structured: any,
  discoveryOutcome: DiscoveryOutcome,
): string | null {
  if (discoveryOutcome !== "unresolved" && discoveryOutcome !== "ambiguous") return null;
  const regBlock = structured?.registration;
  if (!regBlock) return null;
  if (!regBlock.registration_number && !regBlock.registered_product_name) return null;
  const discarded = regBlock.registration_number ?? null;
  regBlock.registration_number = null;
  regBlock.scheme = null;
  regBlock.registered_product_name = null;
  regBlock.label_version = null;
  if (structured.verification) {
    structured.verification.unresolved_fields = Array.from(
      new Set([
        ...(structured.verification.unresolved_fields ?? []),
        "registration_number",
      ]),
    ).sort();
  }
  return discarded;
}

// ---------------------------------------------------------------------------
// Strict fail-closed identity gate (checked-but-unverified register consults)
// ---------------------------------------------------------------------------

// The whole-field gaps a fail-closed response honestly reports. Deliberately
// free of per-context entries ("concentration:<active>", "rates:<crop>") —
// those would leak the AI's unverified chemistry/uses as if they were facts
// about the product.
const FAIL_CLOSED_UNRESOLVED_FIELDS: readonly string[] = [
  "active_ingredients",
  "activity_groups",
  "form_type",
  "label_reference",
  "label_version",
  "product_category",
  "product_name",
  "registered_uses",
  "registrant",
  "registration_number",
];

/**
 * Strict fail-closed identity gate — GENERAL resolver invariant, never
 * product-specific.
 *
 * When a supported authoritative register was successfully consulted and the
 * identity outcome is "unresolved" or "ambiguous" (which is also how a
 * checked name↔number conflict surfaces — a mismatching hint falls through
 * to the name path), the AI must not establish or populate ANY
 * product-specific fact in the canonical structured response:
 *
 *   * match_source becomes "unresolved" — never "ai_candidate";
 *   * registration / registrant / actives / concentrations / activity
 *     groups / registered uses / rates / WHP / re-entry / restrictions all
 *     stay unresolved (activity groups are cleared even when the
 *     authoritative table classified them — the table classified an
 *     UNVERIFIED AI-claimed active, so the classification inherits the
 *     uncertainty);
 *   * verification is rebuilt: status "unverified", conflicts moved out of
 *     the canonical envelope, unresolved_fields = the whole-field gap list
 *     (no per-active/per-crop entries that would leak AI chemistry);
 *   * field_provenance reads "unresolved" for every field;
 *   * no Master candidate can be minted (the registration block is empty,
 *     so buildCandidatePayload structurally returns null).
 *
 * The AI's reading is preserved — clearly separated — in the additive
 * `ai_suggestion` advisory envelope (plus `guidance` for the operator), so
 * discovery hints stay useful without ever looking like chemical facts.
 *
 * The gate does NOT apply when the register itself was unavailable
 * (source_unavailable) or never consulted (not_supported / no_country):
 * "could not check" is not "checked and could not verify", and the existing
 * degraded-mode behaviour (clearly AI-attributed extraction) remains. A
 * REGISTER-RESOLVED result never reaches this gate — authoritative facts
 * win and AI disagreements are recorded as structured conflicts by the
 * merge.
 *
 * Returns true when the gate fail-closed the response.
 */
export function quarantineUnverifiedAiFacts(
  structured: any,
  discoveryOutcome: DiscoveryOutcome,
  registerCountryName?: string | null,
): boolean {
  if (discoveryOutcome !== "unresolved" && discoveryOutcome !== "ambiguous") {
    return false;
  }
  if (!structured) return false;

  const regBlock = structured.registration ?? {};
  const actives: any[] = Array.isArray(structured.active_ingredients)
    ? structured.active_ingredients
    : [];
  const uses: any[] = Array.isArray(structured.registered_uses)
    ? structured.registered_uses
    : [];
  const aiConflicts: WireConflict[] = Array.isArray(structured?.verification?.conflicts)
    ? structured.verification.conflicts
    : [];

  // ---- Advisory: the AI's reading, clearly non-authoritative --------------
  const suggestion: Record<string, any> = {
    note:
      "Unverified AI suggestion. The official register was consulted and " +
      "could not uniquely verify this product, so nothing here is an " +
      "established product fact. Do not rely on it for spray decisions.",
    product_name: structured.product_name ?? null,
    registrant: regBlock?.registrant ?? null,
    product_category: structured.product_category || null,
    form_type: structured.form_type ?? null,
    active_ingredients: actives,
    registered_uses: uses,
  };
  if (aiConflicts.length) suggestion.conflicts = aiConflicts;
  structured.ai_suggestion = suggestion;
  structured.guidance =
    `We could not uniquely verify this product in the official register for ${
      registerCountryName || "this jurisdiction"
    }. Please refine the product name or registration number.`;

  // ---- Canonical fields: emptied, never AI-populated ----------------------
  structured.product_name = null;
  structured.product_category = "";
  structured.form_type = null;
  structured.registration = {
    country_code: regBlock?.country_code ?? null,
    scheme: null,
    registration_number: null,
    registrant: null,
    registered_product_name: null,
    label_reference: null,
    label_version: null,
  };
  structured.active_ingredients = [];
  structured.activity_groups = [];
  structured.activity_group_scheme = null;
  structured.registered_uses = [];
  structured.label_rate_bases = [];

  // ---- Evidence state: honestly unverified ---------------------------------
  // The model consult stays cited (its output lives in the advisory); the
  // authoritative-classification citation goes with the groups it classified.
  const sources: WireDataSource[] = Array.isArray(structured?.verification?.sources)
    ? structured.verification.sources.filter((s: any) => s?.kind === "ai_interpretation")
    : [];
  structured.verification = {
    ...(structured.verification ?? {}),
    status: "unverified",
    sources,
    conflicts: [],
    unresolved_fields: [...FAIL_CLOSED_UNRESOLVED_FIELDS],
    verified_at: null,
  };
  structured.field_provenance = buildFieldProvenance(structured, null, false);
  structured.match_source = "unresolved";
  return true;
}

// ---------------------------------------------------------------------------
// Per-field provenance (additive wire key)
// ---------------------------------------------------------------------------

export type FieldProvenance =
  | "official_register"
  | "manufacturer_label"
  | "authoritative_classification"
  | "ai_interpretation"
  | "master_catalogue"
  | "unresolved";

/**
 * Which evidence tier populated each structured field — and "unresolved"
 * where nothing did. Additive wire key (clients ignore unknown keys); it
 * never claims an authority that did not actually contribute. For uses-level
 * facts it defers to the per-use `provenance` recorded by the label merge,
 * so an AI-carried WHP on a label-backed claim still reads ai_interpretation.
 */
export function buildFieldProvenance(
  structured: any,
  reg: ResolvedRegistration | null,
  labelUsesResolved: boolean,
): Record<string, FieldProvenance> {
  const regBlock = structured?.registration ?? null;
  const actives: any[] = Array.isArray(structured?.active_ingredients)
    ? structured.active_ingredients
    : [];
  const uses: any[] = Array.isArray(structured?.registered_uses)
    ? structured.registered_uses
    : [];

  const has = (v: unknown): boolean => v !== null && v !== undefined && v !== "";
  const fromRegister = (regProvided: boolean, present: boolean): FieldProvenance =>
    present ? (regProvided ? "official_register" : "ai_interpretation") : "unresolved";

  const useFact = (
    key: "withholding_period" | "re_entry" | "restrictions",
    present: (u: any) => boolean,
  ): FieldProvenance => {
    if (!uses.some(present)) return "unresolved";
    if (uses.some((u) => u?.provenance?.[key] === "manufacturer_label")) {
      return "manufacturer_label";
    }
    if (labelUsesResolved && !uses.some((u) => u?.provenance)) {
      return "manufacturer_label";
    }
    return "ai_interpretation";
  };

  const groupsPresent = actives.some((a) => a?.activity_group);
  const groupsAuthoritative = actives.some(
    (a) => a?.group_source === "authoritative_classification",
  );

  return {
    product_name: fromRegister(Boolean(reg), has(structured?.product_name)),
    product_category: fromRegister(
      Boolean(reg?.product_category),
      has(structured?.product_category),
    ),
    form_type: fromRegister(Boolean(reg?.form_type), has(structured?.form_type)),
    registration: has(regBlock?.registration_number)
      ? (reg ? "official_register" : "ai_interpretation")
      : "unresolved",
    registrant: has(regBlock?.registrant)
      ? (reg?.registrant ? "official_register" : "ai_interpretation")
      : "unresolved",
    active_ingredients: actives.length
      ? (reg?.active_ingredients.length ? "official_register" : "ai_interpretation")
      : "unresolved",
    activity_groups: groupsPresent
      ? (groupsAuthoritative ? "authoritative_classification" : "ai_interpretation")
      : "unresolved",
    registered_uses: uses.length
      ? (labelUsesResolved ? "manufacturer_label" : "ai_interpretation")
      : "unresolved",
    label_rates: uses.some((u) => Array.isArray(u?.rates) && u.rates.length)
      // Stage LD-2: document-bound rates read manufacturer_label — the
      // per-use provenance recorded by the merge is the arbiter, so AI rates
      // riding on other claims never inflate the field-level tier.
      ? (uses.some((u) => u?.provenance?.rates === "manufacturer_label")
        ? "manufacturer_label"
        : "ai_interpretation")
      : "unresolved",
    withholding_periods: useFact(
      "withholding_period",
      (u) => u?.withholding_period_days != null,
    ),
    re_entry: useFact("re_entry", (u) => u?.re_entry_period_hours != null),
    restrictions: useFact("restrictions", (u) => has(u?.restrictions)),
    label_version: has(regBlock?.label_version)
      ? (reg?.label_version ? "official_register" : "ai_interpretation")
      : "unresolved",
    // Stage LD-1: only the EXACT document URL the register portal confirmed
    // reads manufacturer_label; any other populated value is the AI's.
    label_reference: has(regBlock?.label_reference)
      ? (reg?.label_document?.url === regBlock?.label_reference
        ? "manufacturer_label"
        : "ai_interpretation")
      : "unresolved",
  };
}

// Provenance tiers that count as AUTHORITATIVE for the unresolved-fields
// contract. ai_interpretation is deliberately absent: an AI-supplied value is
// "present but unverified", which is still unresolved.
const AUTHORITATIVE_PROVENANCE = new Set<FieldProvenance>([
  "official_register",
  "manufacturer_label",
  "authoritative_classification",
  "master_catalogue",
]);

// verification.unresolved_fields entry → field_provenance key. WHOLE-FIELD
// entries only: per-context gap entries ("rates:GRAPEVINE",
// "withholding_period:ALMOND", "concentration:<active>",
// "activity_group:<active>") name genuinely missing sub-facts and are never
// pruned by the whole-field rule.
const UNRESOLVED_ENTRY_PROVENANCE_KEY: Record<string, string> = {
  product_name: "product_name",
  product_category: "product_category",
  form_type: "form_type",
  registrant: "registrant",
  registration: "registration",
  registration_number: "registration",
  active_ingredients: "active_ingredients",
  activity_groups: "activity_groups",
  registered_uses: "registered_uses",
  label_version: "label_version",
  label_reference: "label_reference",
  re_entry_period_hours: "re_entry",
  withholding_period: "withholding_periods",
  rates: "label_rates",
  label_rates: "label_rates",
  restrictions: "restrictions",
};

/**
 * Contract invariant (general, never product-specific):
 * `verification.unresolved_fields` must not list a field whose served value
 * is POPULATED and whose `field_provenance` is authoritative
 * (official_register / manufacturer_label / authoritative_classification /
 * master_catalogue). `field_provenance` already encodes both conditions — an
 * authoritative tier is only ever assigned to a populated value that the
 * authority actually provided.
 *
 * What stays listed, on purpose:
 *   * AI-populated fields (ai_interpretation) — displayed but unverified is
 *     still unresolved;
 *   * genuinely empty fields (provenance "unresolved");
 *   * per-context gap entries ("rates:<crop>", "withholding_period:<crop>",
 *     "concentration:<active>", …) — sub-facts no authority provided.
 *
 * Runs at response assembly on EVERY serving path (register merge, AI-only,
 * master catalogue), so stored rows written before this invariant also serve
 * clean without any data or schema change.
 */
export function pruneAuthoritativelyResolvedFields(structured: any): void {
  const provenance = structured?.field_provenance;
  const verification = structured?.verification;
  if (!provenance || !verification || !Array.isArray(verification.unresolved_fields)) {
    return;
  }
  verification.unresolved_fields = verification.unresolved_fields.filter(
    (entry: string) => {
      const key = UNRESOLVED_ENTRY_PROVENANCE_KEY[String(entry)];
      if (!key) return true;
      return !AUTHORITATIVE_PROVENANCE.has(provenance[key]);
    },
  );
}

/**
 * A register-resolved product with NO AI extraction available (provider down
 * or skipped): everything the register asserted, nothing more. Registered
 * uses are honestly empty and unresolved.
 */
export function buildRegisterOnlyStructured(
  reg: ResolvedRegistration,
  tableVersion: number,
): any {
  const base = {
    product_name: null,
    product_category: "",
    form_type: null,
    registration: {
      country_code: reg.country_code,
      scheme: reg.scheme,
      registration_number: null,
      registrant: null,
      registered_product_name: null,
      label_reference: null,
      label_version: null,
    },
    active_ingredients: [],
    activity_groups: [],
    activity_group_scheme: null,
    registered_uses: [],
    label_rate_bases: [],
    verification: {
      status: "unverified",
      sources: [],
      conflicts: [],
      unresolved_fields: [],
      verified_at: null,
    },
    activity_group_table_version: tableVersion,
    schema_version: 1,
  };
  return mergeDiscoveryIntoStructured(base, reg);
}

// ---------------------------------------------------------------------------
// Candidate payload + dedupe/enqueue
// ---------------------------------------------------------------------------

/** Lower-cased exact-match search aliases (never identity, never fuzzy). */
function aliasSet(...names: Array<string | null | undefined>): string[] {
  const set = new Set<string>();
  for (const n of names) {
    const v = String(n ?? "").trim().toLowerCase();
    if (v) set.add(v);
  }
  return Array.from(set);
}

/**
 * Map a (possibly register-merged) structured result onto the sql/199
 * candidate columns. `review_status` is structurally pinned to "candidate".
 */
export function buildCandidatePayload(
  structured: any,
  requestedName: string,
  discovery: ResolvedRegistration | null,
  retrievedAtIso: string,
  tableVersion: number,
): CandidateRowPayload | null {
  const regBlock = structured?.registration ?? {};
  const country = String(regBlock?.country_code ?? "").trim().toUpperCase();
  const scheme = String(regBlock?.scheme ?? "").trim().toLowerCase();
  const number = String(regBlock?.registration_number ?? "").trim();
  if (!/^[A-Z]{2}$/.test(country) || !scheme || !number) return null;

  const productName = String(structured?.product_name ?? "").trim() ||
    String(regBlock?.registered_product_name ?? "").trim();
  if (!productName) return null;

  return {
    registration_country: country,
    registration_scheme: scheme,
    registration_number: number,
    registrant: regBlock?.registrant ?? null,
    registered_product_name: productName,
    common_names: aliasSet(productName, requestedName, regBlock?.registered_product_name),
    product_category: structured?.product_category || null,
    form_type: structured?.form_type ?? null,
    active_ingredients: structured?.active_ingredients ?? [],
    activity_groups: structured?.activity_groups ?? [],
    activity_group_scheme: structured?.activity_group_scheme ?? null,
    registered_uses: structured?.registered_uses ?? [],
    label_rate_bases: structured?.label_rate_bases ?? [],
    label_reference: regBlock?.label_reference ?? null,
    label_version: regBlock?.label_version ?? null,
    verification_status: structured?.verification?.status ?? "unverified",
    verification_sources: structured?.verification?.sources ?? [],
    verification_conflicts: structured?.verification?.conflicts ?? [],
    verification_unresolved_fields: structured?.verification?.unresolved_fields ?? [],
    source_kind: discovery ? "official_register" : "ai_interpretation",
    source_reference: discovery?.sources?.[0]?.reference ?? null,
    retrieved_at: retrievedAtIso,
    review_status: "candidate",
    activity_group_table_version: structured?.activity_group_table_version ?? tableVersion,
    intelligence_schema_version: structured?.schema_version ?? 1,
  };
}

export interface CandidateWriteOutcome {
  action:
    | "created"
    | "reused"
    | "refreshed"
    | "approved_exists"
    | "retired_exists"
    | "skipped"
    | "error";
  reason?: string;
  row: MasterRow | null;
}

function mergedAliases(existing: MasterRow, payload: CandidateRowPayload): string[] | null {
  const current = new Set((existing.common_names ?? []).map((n) => n.toLowerCase()));
  const additions = payload.common_names.filter((n) => !current.has(n));
  if (!additions.length) return null;
  return [...(existing.common_names ?? []), ...additions];
}

function contentPatch(payload: CandidateRowPayload, existing: MasterRow): Record<string, any> {
  const patch: Record<string, any> = {
    registrant: payload.registrant,
    registered_product_name: payload.registered_product_name,
    common_names: mergedAliases(existing, payload) ?? existing.common_names,
    product_category: payload.product_category ?? existing.product_category,
    form_type: payload.form_type ?? existing.form_type,
    active_ingredients: payload.active_ingredients,
    activity_groups: payload.activity_groups,
    activity_group_scheme: payload.activity_group_scheme,
    label_version: payload.label_version ?? existing.label_version,
    verification_status: payload.verification_status,
    verification_sources: payload.verification_sources,
    verification_conflicts: payload.verification_conflicts,
    verification_unresolved_fields: payload.verification_unresolved_fields,
    source_kind: payload.source_kind,
    source_reference: payload.source_reference,
    retrieved_at: payload.retrieved_at,
    activity_group_table_version: payload.activity_group_table_version,
    intelligence_schema_version: payload.intelligence_schema_version,
  };
  // Never blank richer data with an emptier lookup.
  if (payload.registered_uses.length) {
    patch.registered_uses = payload.registered_uses;
    patch.label_rate_bases = payload.label_rate_bases;
  }
  if (payload.label_reference) patch.label_reference = payload.label_reference;
  return patch;
}

function evidencePatch(payload: CandidateRowPayload, existing: MasterRow): Record<string, any> {
  return {
    common_names: mergedAliases(existing, payload) ?? existing.common_names,
    verification_sources: payload.verification_sources,
    retrieved_at: payload.retrieved_at,
    source_kind: payload.source_kind,
    source_reference: payload.source_reference,
  };
}

/**
 * Registration-identity dedupe, then enqueue or refresh (Stage 3 §§12–13).
 *
 *   * exact `country:scheme:number` match FIRST, across every review state;
 *   * approved/retired rows are never touched by automation;
 *   * one candidate per canonical registration identity — 20 vineyards
 *     searching the same unresolved product still yield ONE row;
 *   * refresh policy: authoritative evidence may upgrade an AI candidate,
 *     replace materially-changed content, or re-stamp stale evidence
 *     (older than 7 days). AI evidence can only ever add search aliases.
 */
export async function upsertCandidate(
  ops: MasterOps,
  payload: CandidateRowPayload,
  nowMs: number,
): Promise<CandidateWriteOutcome> {
  try {
    const key = identityKey(
      payload.registration_country,
      payload.registration_scheme,
      payload.registration_number,
    );
    let existing = await ops.selectByIdentityKey(key);
    if (!existing) {
      const inserted = await ops.insertCandidate(payload);
      if (inserted) return { action: "created", row: inserted };
      existing = await ops.selectByIdentityKey(key);
      if (!existing) return { action: "error", reason: "insert_failed", row: null };
    }

    if (existing.review_status === "approved") {
      return { action: "approved_exists", row: existing };
    }
    if (existing.review_status === "retired") {
      return { action: "retired_exists", row: existing };
    }

    const isAuthoritative = payload.source_kind === "official_register";
    const existingAuthoritative = existing.source_kind === "official_register" ||
      existing.source_kind === "manufacturer_label";

    if (!isAuthoritative) {
      const aliases = mergedAliases(existing, payload);
      if (aliases) await ops.updateCandidate(existing.id, { common_names: aliases });
      return { action: "reused", reason: "existing_candidate_wins", row: existing };
    }

    if (!existingAuthoritative) {
      const ok = await ops.updateCandidate(existing.id, contentPatch(payload, existing));
      return {
        action: ok ? "refreshed" : "reused",
        reason: "authority_upgrade",
        row: existing,
      };
    }

    const changes = materialChanges(existing, {
      registered_product_name: payload.registered_product_name,
      registrant: payload.registrant,
      product_category: payload.product_category,
      form_type: payload.form_type,
      label_version: payload.label_version,
      active_ingredients: payload.active_ingredients,
    });
    if (changes.length) {
      const ok = await ops.updateCandidate(existing.id, contentPatch(payload, existing));
      return { action: ok ? "refreshed" : "reused", reason: "material_change", row: existing };
    }

    const ageMs = nowMs - (Date.parse(existing.retrieved_at ?? "") || 0);
    if (ageMs > CANDIDATE_EVIDENCE_MAX_AGE_MS) {
      const ok = await ops.updateCandidate(existing.id, evidencePatch(payload, existing));
      return { action: ok ? "refreshed" : "reused", reason: "evidence_refreshed", row: existing };
    }

    const aliases = mergedAliases(existing, payload);
    if (aliases) await ops.updateCandidate(existing.id, { common_names: aliases });
    return { action: "reused", reason: "fresh_evidence", row: existing };
  } catch (err) {
    console.error(
      "candidate upsert skipped:",
      err instanceof Error ? err.message : String(err),
    );
    return { action: "error", reason: "exception", row: null };
  }
}

// ---------------------------------------------------------------------------
// Response envelopes + structured log
// ---------------------------------------------------------------------------

/** Additive envelope describing the candidate row backing this lookup. */
export function candidateEnvelope(row: MasterRow): Record<string, any> {
  return {
    master_chemical_id: row.id,
    candidate_revision: row.catalogue_version ?? 1,
    catalogue_status: row.review_status,
    registration_identity_key: row.registration_identity_key,
  };
}

/** Additive envelope describing what authoritative discovery did. */
export function discoveryEnvelope(discovery: DiscoveryResult): Record<string, any> {
  const out: Record<string, any> = {
    adapter: discovery.adapter,
    outcome: discovery.outcome,
  };
  if (discovery.registration) {
    out.registration_identity_key = discovery.registration.registration_identity_key;
    out.match_mode = discovery.registration.match_mode;
    if (discovery.registration.register_status) {
      out.register_status = discovery.registration.register_status;
    }
  }
  if (discovery.error_category) out.error_category = discovery.error_category;
  return out;
}

/** One structured, secret-free log line per ingestion attempt (§P). */
export function ingestionLog(fields: {
  jurisdiction: string;
  adapter: string | null;
  outcome: string;
  identity: string | null;
  master: "existing_approved" | "existing_retired" | "none";
  candidate: string;
  unresolvedCount: number;
  conflictCount: number;
  durationMs: number;
  cache: string;
  errorCategory?: string;
}): string {
  return JSON.stringify({
    evt: "chemical_ingestion",
    jurisdiction: fields.jurisdiction || "none",
    adapter: fields.adapter,
    outcome: fields.outcome,
    registration_identity: fields.identity,
    master: fields.master,
    candidate: fields.candidate,
    unresolved_count: fields.unresolvedCount,
    conflict_count: fields.conflictCount,
    duration_ms: fields.durationMs,
    cache: fields.cache,
    ...(fields.errorCategory ? { error_category: fields.errorCategory } : {}),
  });
}
