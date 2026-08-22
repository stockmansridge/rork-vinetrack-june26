// ChemicalResearchResult — the JSON Schema the web-research model MUST fill.
//
// WHAT THIS IS: an INTERMEDIATE research artefact. It is not a database
// shape, it is not the client wire contract, and nothing in it is
// authoritative by virtue of appearing here. It exists so the server can
// receive DISCOVERY as typed data instead of prose, then decide — in
// `authority.ts` — which parts survive contact with the official register.
//
// WHY STRICT: OpenAI Structured Outputs `strict: true` guarantees the model
// cannot emit a key we did not ask for. That is a security property, not a
// convenience: mapping into SavedChemical stays explicit and a model can
// never inject an unexpected field into storage (task §28).
//
// STRICT-MODE RULES (OpenAI): every object needs `additionalProperties:
// false` and EVERY property listed in `required`. "Optional" is therefore
// expressed as a nullable type, never as an absent key.

/** sql/194 rate bases, verbatim — research never invents a new basis. */
export const RESEARCH_RATE_BASES = [
  "per_hectare",
  "range_per_hectare",
  "per_100_litres",
  "range_per_100_litres",
  "per_100_metres",
  "range_per_100_metres",
  "per_treated_hectare",
  "other",
] as const;

/** How much the model believes a discovered fact. Never a provenance tier. */
export const RESEARCH_CONFIDENCE = ["high", "medium", "low"] as const;

/**
 * What KIND of page a URL is. The classifier re-derives this server-side
 * (`classify.ts`); the model's opinion is a hint that is checked, never
 * trusted — a marketing page must never be able to self-declare as a label.
 */
export const RESEARCH_SOURCE_TYPES = [
  "official_register",
  "regulator_document",
  "manufacturer_label",
  "manufacturer_product_page",
  "safety_data_sheet",
  "viticulture_reference",
  "reseller",
  "search_engine",
  "other",
] as const;

function str(description: string) {
  return { type: "string", description } as const;
}
function nullableStr(description: string) {
  return { type: ["string", "null"], description } as const;
}
function nullableNum(description: string) {
  return { type: ["number", "null"], description } as const;
}
function enumOf(values: readonly string[], description: string) {
  return { type: "string", enum: [...values], description } as const;
}
function nullableEnum(values: readonly string[], description: string) {
  return { type: ["string", "null"], enum: [...values, null], description } as const;
}
function obj(properties: Record<string, unknown>, description?: string) {
  return {
    type: "object",
    additionalProperties: false,
    required: Object.keys(properties),
    properties,
    ...(description ? { description } : {}),
  } as const;
}
function arr(items: unknown, description: string) {
  return { type: "array", items, description } as const;
}

/** Every fact carries the URLs that support it (task §16). */
const sourceRefs = arr(
  str("A URL from the sources[] array that supports this value."),
  "URLs supporting this value. EMPTY means the model inferred it with no source — it will be treated as ai_interpretation and can never become authoritative.",
);

const productSchema = obj({
  searched_name: str("The operator's query, verbatim, including any typo."),
  canonical_name: nullableStr(
    "Full registered/marketed product name as published by the registrant or register, e.g. 'Dithane Rainshield Neo Tec Fungicide'. Null if not established.",
  ),
  manufacturer: nullableStr("Marketing manufacturer/brand owner."),
  registrant: nullableStr("Legal registrant on the register, when different from manufacturer."),
  category: nullableStr("fungicide | herbicide | insecticide | miticide | adjuvant | foliar nutrient | fertiliser | biostimulant | biological | other"),
  form_type: nullableStr("liquid | solid | null"),
  country: str("ISO-2 country the research was scoped to."),
  source_refs: sourceRefs,
});

const registrationCandidateSchema = obj({
  scheme: nullableEnum(
    ["apvma", "acvm", "nz_epa", "other"],
    "Registration scheme. MUST match the researched country: apvma for AU, acvm/nz_epa for NZ.",
  ),
  number: nullableStr("Registration number as printed by the register, digits only where applicable."),
  registered_product_name: nullableStr("Product name EXACTLY as it appears on the register entry."),
  country: str("ISO-2 country of this registration."),
  source_url: nullableStr("The page this candidate was read from."),
  source_domain: nullableStr("Host of source_url."),
  confidence: enumOf(RESEARCH_CONFIDENCE, "How strongly the evidence supports this identity."),
  reason: str("One sentence: why this registration is believed to match the searched product."),
});

const activeIngredientSchema = obj({
  name: str("Active constituent common name, e.g. 'Mancozeb'."),
  concentration: nullableNum("Numeric strength only."),
  concentration_unit: nullableStr("e.g. 'g/kg', 'g/L'."),
  suggested_scheme: nullableEnum(
    ["frac", "hrac", "irac", "not_applicable"],
    "Resistance scheme the model believes applies. ALWAYS re-checked against VineTrack's authoritative table.",
  ),
  suggested_group: nullableStr("Group code the model believes applies, e.g. 'M3'. Never trusted directly."),
  source_refs: sourceRefs,
});

const rateSchema = obj({
  label: nullableStr("Label wording for this rate row, e.g. 'Protectant programme'."),
  basis: enumOf(RESEARCH_RATE_BASES, "The basis the LABEL states. Never convert between bases."),
  value: nullableNum("Single rate value, when the label gives one."),
  min_value: nullableNum("Low end, when the label gives a range."),
  max_value: nullableNum("High end, when the label gives a range."),
  unit: nullableStr("Rate unit exactly as printed, e.g. 'kg', 'g', 'L', 'mL'."),
  raw_text: nullableStr("The rate sentence verbatim from the label."),
  source_refs: sourceRefs,
});

const registeredUseSchema = obj({
  crop: str("Crop as the label states it, e.g. 'Grapevines'."),
  targets: arr(
    str("One pest/disease per entry."),
    "EVERY target this use covers. Do NOT reduce to a single primary target.",
  ),
  rates: arr(rateSchema, "Every rate row for this use, in every basis the label states."),
  whp: nullableStr("Withholding period, verbatim."),
  rei: nullableStr("Re-entry interval, verbatim."),
  restrictions: arr(str("One restriction per entry."), "Use restrictions/critical comments."),
  source_refs: sourceRefs,
});

const documentCandidateSchema = obj({
  url: str("Absolute URL."),
  title: nullableStr("Document/page title."),
  domain: str("Host of the URL."),
  reason: str("Why this URL is believed to be this kind of document."),
});

const documentsSchema = obj({
  official_label_candidates: arr(
    documentCandidateSchema,
    "Regulator-hosted approved labels or registrant-hosted actual label DOCUMENTS. Never an SDS, never a marketing page.",
  ),
  product_page_candidates: arr(
    documentCandidateSchema,
    "Manufacturer/registrant-owned product pages. Never a reseller.",
  ),
  sds_candidates: arr(documentCandidateSchema, "Safety data sheets. Never offered as a label."),
});

const sourceSchema = obj({
  url: str("Absolute URL actually consulted."),
  domain: str("Host of the URL."),
  title: nullableStr("Page title."),
  source_type: enumOf(RESEARCH_SOURCE_TYPES, "What kind of source this is."),
  supports_fields: arr(
    str("Dotted field path this source supports, e.g. 'registration.number'."),
    "Which researched facts this source backs.",
  ),
});

/** The strict JSON Schema handed to the Responses API. */
export const CHEMICAL_RESEARCH_SCHEMA = obj({
  product: productSchema,
  registration_candidates: arr(
    registrationCandidateSchema,
    "Possible register identities. These are LEADS for the official resolver, not registrations.",
  ),
  active_ingredients: arr(activeIngredientSchema, "Actives with strengths where published."),
  registered_uses: arr(registeredUseSchema, "Label uses. Keep every crop, target, and rate basis."),
  documents: documentsSchema,
  sources: arr(sourceSchema, "Every source consulted, classified."),
  unresolved: arr(
    str("One unanswered question per entry."),
    "What research could NOT establish. Say so here instead of guessing.",
  ),
  notes: nullableStr("Short reconciliation note for a human reviewer."),
});

export const CHEMICAL_RESEARCH_SCHEMA_NAME = "chemical_research_result";

// ---------------------------------------------------------------------------
// TypeScript mirror
// ---------------------------------------------------------------------------

export type ResearchConfidence = typeof RESEARCH_CONFIDENCE[number];
export type ResearchSourceType = typeof RESEARCH_SOURCE_TYPES[number];
export type ResearchRateBasis = typeof RESEARCH_RATE_BASES[number];

export interface ResearchProduct {
  searched_name: string;
  canonical_name: string | null;
  manufacturer: string | null;
  registrant: string | null;
  category: string | null;
  form_type: string | null;
  country: string;
  source_refs: string[];
}

export interface ResearchRegistrationCandidate {
  scheme: string | null;
  number: string | null;
  registered_product_name: string | null;
  country: string;
  source_url: string | null;
  source_domain: string | null;
  confidence: ResearchConfidence;
  reason: string;
}

export interface ResearchActiveIngredient {
  name: string;
  concentration: number | null;
  concentration_unit: string | null;
  suggested_scheme: string | null;
  suggested_group: string | null;
  source_refs: string[];
}

export interface ResearchRate {
  label: string | null;
  basis: ResearchRateBasis;
  value: number | null;
  min_value: number | null;
  max_value: number | null;
  unit: string | null;
  raw_text: string | null;
  source_refs: string[];
}

export interface ResearchRegisteredUse {
  crop: string;
  targets: string[];
  rates: ResearchRate[];
  whp: string | null;
  rei: string | null;
  restrictions: string[];
  source_refs: string[];
}

export interface ResearchDocumentCandidate {
  url: string;
  title: string | null;
  domain: string;
  reason: string;
}

export interface ResearchSource {
  url: string;
  domain: string;
  title: string | null;
  source_type: ResearchSourceType;
  supports_fields: string[];
}

export interface ChemicalResearchResult {
  product: ResearchProduct;
  registration_candidates: ResearchRegistrationCandidate[];
  active_ingredients: ResearchActiveIngredient[];
  registered_uses: ResearchRegisteredUse[];
  documents: {
    official_label_candidates: ResearchDocumentCandidate[];
    product_page_candidates: ResearchDocumentCandidate[];
    sds_candidates: ResearchDocumentCandidate[];
  };
  sources: ResearchSource[];
  unresolved: string[];
  notes: string | null;
}

// ---------------------------------------------------------------------------
// Validation — fail CLOSED
// ---------------------------------------------------------------------------

export class ResearchSchemaError extends Error {
  readonly path: string;
  constructor(path: string, message: string) {
    super(`${path}: ${message}`);
    this.name = "ResearchSchemaError";
    this.path = path;
  }
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

function reqString(o: Record<string, unknown>, key: string, path: string): string {
  const v = o[key];
  if (typeof v !== "string") throw new ResearchSchemaError(`${path}.${key}`, "expected string");
  return v;
}
function optString(o: Record<string, unknown>, key: string, path: string): string | null {
  const v = o[key];
  if (v === null || v === undefined) return null;
  if (typeof v !== "string") throw new ResearchSchemaError(`${path}.${key}`, "expected string or null");
  return v;
}
function optNumber(o: Record<string, unknown>, key: string, path: string): number | null {
  const v = o[key];
  if (v === null || v === undefined) return null;
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new ResearchSchemaError(`${path}.${key}`, "expected finite number or null");
  }
  return v;
}
function strArray(o: Record<string, unknown>, key: string, path: string): string[] {
  const v = o[key];
  if (v === null || v === undefined) return [];
  if (!Array.isArray(v)) throw new ResearchSchemaError(`${path}.${key}`, "expected array");
  return v.filter((x): x is string => typeof x === "string" && x.trim() !== "");
}
function objArray(o: Record<string, unknown>, key: string, path: string): Record<string, unknown>[] {
  const v = o[key];
  if (v === null || v === undefined) return [];
  if (!Array.isArray(v)) throw new ResearchSchemaError(`${path}.${key}`, "expected array");
  return v.filter(isRecord);
}

function hostOf(url: string): string {
  try {
    return new URL(url).host.toLowerCase().replace(/^www\./, "");
  } catch {
    return "";
  }
}

function parseDocumentCandidates(
  rows: Record<string, unknown>[],
  path: string,
): ResearchDocumentCandidate[] {
  const out: ResearchDocumentCandidate[] = [];
  rows.forEach((row, i) => {
    const url = optString(row, "url", `${path}[${i}]`);
    if (!url || !/^https?:\/\//i.test(url)) return; // drop unusable, never throw
    out.push({
      url,
      title: optString(row, "title", `${path}[${i}]`),
      domain: optString(row, "domain", `${path}[${i}]`) ?? hostOf(url),
      reason: optString(row, "reason", `${path}[${i}]`) ?? "",
    });
  });
  return out;
}

/**
 * Validate and normalise a model payload into `ChemicalResearchResult`.
 *
 * FAIL CLOSED on structure: a payload that is not an object, or that omits
 * `product.searched_name`, throws — the caller then behaves exactly as if
 * the AI were unavailable, which is a supported (register-only) outcome.
 *
 * FAIL SOFT on content: unusable individual rows (a rate with no numbers, a
 * document with no URL) are dropped rather than poisoning the whole result.
 * Unknown keys are ignored by construction — this reads only what it knows,
 * so the model cannot reach SavedChemical through an unexpected field.
 */
export function parseChemicalResearchResult(raw: unknown): ChemicalResearchResult {
  if (!isRecord(raw)) throw new ResearchSchemaError("$", "expected an object");

  const productRaw = raw.product;
  if (!isRecord(productRaw)) throw new ResearchSchemaError("$.product", "missing");
  const searched = reqString(productRaw, "searched_name", "$.product").trim();
  if (!searched) throw new ResearchSchemaError("$.product.searched_name", "empty");

  const product: ResearchProduct = {
    searched_name: searched,
    canonical_name: optString(productRaw, "canonical_name", "$.product"),
    manufacturer: optString(productRaw, "manufacturer", "$.product"),
    registrant: optString(productRaw, "registrant", "$.product"),
    category: optString(productRaw, "category", "$.product"),
    form_type: optString(productRaw, "form_type", "$.product"),
    country: (optString(productRaw, "country", "$.product") ?? "").toUpperCase(),
    source_refs: strArray(productRaw, "source_refs", "$.product"),
  };

  const registration_candidates: ResearchRegistrationCandidate[] = objArray(
    raw,
    "registration_candidates",
    "$",
  ).map((row, i) => {
    const p = `$.registration_candidates[${i}]`;
    const confidence = optString(row, "confidence", p);
    return {
      scheme: optString(row, "scheme", p),
      number: optString(row, "number", p),
      registered_product_name: optString(row, "registered_product_name", p),
      country: (optString(row, "country", p) ?? product.country).toUpperCase(),
      source_url: optString(row, "source_url", p),
      source_domain: optString(row, "source_domain", p),
      confidence: (RESEARCH_CONFIDENCE as readonly string[]).includes(confidence ?? "")
        ? confidence as ResearchConfidence
        : "low",
      reason: optString(row, "reason", p) ?? "",
    };
  });

  const active_ingredients: ResearchActiveIngredient[] = objArray(
    raw,
    "active_ingredients",
    "$",
  ).flatMap((row, i) => {
    const p = `$.active_ingredients[${i}]`;
    const name = (optString(row, "name", p) ?? "").trim();
    if (!name) return [];
    return [{
      name,
      concentration: optNumber(row, "concentration", p),
      concentration_unit: optString(row, "concentration_unit", p),
      suggested_scheme: optString(row, "suggested_scheme", p),
      suggested_group: optString(row, "suggested_group", p),
      source_refs: strArray(row, "source_refs", p),
    }];
  });

  const registered_uses: ResearchRegisteredUse[] = objArray(raw, "registered_uses", "$")
    .flatMap((row, i) => {
      const p = `$.registered_uses[${i}]`;
      const crop = (optString(row, "crop", p) ?? "").trim();
      if (!crop) return [];
      const rates: ResearchRate[] = objArray(row, "rates", p).flatMap((r, j) => {
        const rp = `${p}.rates[${j}]`;
        const basis = optString(r, "basis", rp);
        if (!(RESEARCH_RATE_BASES as readonly string[]).includes(basis ?? "")) return [];
        const value = optNumber(r, "value", rp);
        const min_value = optNumber(r, "min_value", rp);
        const max_value = optNumber(r, "max_value", rp);
        const raw_text = optString(r, "raw_text", rp);
        // A rate with neither numbers nor wording carries nothing.
        if (value === null && min_value === null && max_value === null && !raw_text) return [];
        return [{
          label: optString(r, "label", rp),
          basis: basis as ResearchRateBasis,
          value,
          min_value,
          max_value,
          unit: optString(r, "unit", rp),
          raw_text,
          source_refs: strArray(r, "source_refs", rp),
        }];
      });
      return [{
        crop,
        targets: strArray(row, "targets", p),
        rates,
        whp: optString(row, "whp", p),
        rei: optString(row, "rei", p),
        restrictions: strArray(row, "restrictions", p),
        source_refs: strArray(row, "source_refs", p),
      }];
    });

  const docsRaw = isRecord(raw.documents) ? raw.documents : {};
  const documents = {
    official_label_candidates: parseDocumentCandidates(
      objArray(docsRaw, "official_label_candidates", "$.documents"),
      "$.documents.official_label_candidates",
    ),
    product_page_candidates: parseDocumentCandidates(
      objArray(docsRaw, "product_page_candidates", "$.documents"),
      "$.documents.product_page_candidates",
    ),
    sds_candidates: parseDocumentCandidates(
      objArray(docsRaw, "sds_candidates", "$.documents"),
      "$.documents.sds_candidates",
    ),
  };

  const sources: ResearchSource[] = objArray(raw, "sources", "$").flatMap((row, i) => {
    const p = `$.sources[${i}]`;
    const url = optString(row, "url", p);
    if (!url || !/^https?:\/\//i.test(url)) return [];
    const declared = optString(row, "source_type", p);
    return [{
      url,
      domain: (optString(row, "domain", p) ?? hostOf(url)).toLowerCase().replace(/^www\./, ""),
      title: optString(row, "title", p),
      source_type: (RESEARCH_SOURCE_TYPES as readonly string[]).includes(declared ?? "")
        ? declared as ResearchSourceType
        : "other",
      supports_fields: strArray(row, "supports_fields", p),
    }];
  });

  return {
    product,
    registration_candidates,
    active_ingredients,
    registered_uses,
    documents,
    sources,
    unresolved: strArray(raw, "unresolved", "$"),
    notes: optString(raw, "notes", "$"),
  };
}
