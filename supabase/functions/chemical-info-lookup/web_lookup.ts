import type { ChemicalResearchResult } from "./research/schema.ts";
import type { ManufacturerEnrichmentResult } from "./ingestion/manufacturer_enrichment.ts";
import { classifyUrl } from "./research/classify.ts";
import { callResponsesApi, DEFAULT_RESEARCH_MODEL } from "./research/responses_client.ts";
import { parseChemicalResearchResult } from "./research/schema.ts";

const ANIMAL_OR_HUMAN = /\b(veterinary|livestock|horse|equine|sheep|cattle|companion.animals?|dogs?|cats?|human|pet|parasiticide|drench)\b/i;
const CROP_CONTEXT = /\b(agricultur\w*|vineyard\w*|grape\w*|herbicide|fungicide|insecticide|adjuvant|fertili[sz]er|biostimulant|crop|weed\w*|plant|foliar|horticultur\w*)\b/i;

/** An APVMA number is evidence only when the fetched, identity-checked Australian label prints it. */
/** V2 can read a verified document even when the table parser found no rows. */
export function readableV2Label(result: ManufacturerEnrichmentResult | null): string | null {
  return result?.fetchedUrl && result.labelText &&
      result.diagnostics.manufacturer_label_fetch_outcome === "fetched"
    ? result.fetchedUrl : null;
}

export function labelApprovalNumber(text: string, country: string): string | null {
  if (country !== "AU") return null;
  const matches = [...text.matchAll(/\bAPVMA\s+(?:APPROVAL|REGISTRATION)\s*(?:NO\.?|NUMBER)?\s*[:#-]?\s*(\d{4,7}(?:\s*\/\s*\d{4,7})?)(?!\d)/gi)];
  const numbers = [...new Set(matches.map((match) => match[1].replace(/\s+/g, "")))];
  return numbers.length === 1 ? numbers[0] : null;
}

export function labelHeaderFacts(text: string): {
  active: { name: string; concentration: number; concentration_unit: string } | null;
  group: { scheme: string; code: string } | null;
  form: string | null;
} {
  const header = text.slice(0, 6000).replace(/\s+/g, " ");
  const active = /ACTIVE\s+CONSTITUENT\s*:\s*(\d+(?:\.\d+)?)\s*(g\s*\/\s*L|g\s*\/\s*kg)\s+([A-Z][A-Z0-9 -]{3,65}?)(?=\s+(?:GROUP|HERBICIDE|FUNGICIDE|INSECTICIDE|For\s+the|For\s+control|$))/i.exec(header);
  const group = /\bGROUP\s+([A-Z]?\d{1,2}[A-Z]?|[A-Z])\s+(HERBICIDE|FUNGICIDE|INSECTICIDE)\b/i.exec(header) ??
    /\b(HERBICIDE|FUNGICIDE|INSECTICIDE)\s+GROUP\s+([A-Z]?\d{1,2}[A-Z]?|[A-Z])\b/i.exec(header);
  const suffixCategory = group?.[2]?.toLowerCase();
  const category = suffixCategory && /^(herbicide|fungicide|insecticide)$/.test(suffixCategory)
    ? suffixCategory : group?.[1]?.toLowerCase();
  const code = category === suffixCategory ? group?.[1] : group?.[2];
  return {
    active: active ? { name: active[3].trim(), concentration: Number(active[1]),
      concentration_unit: active[2].replace(/\s/g, "") } : null,
    group: code && category ? { scheme: category === "herbicide" ? "hrac" : category === "fungicide" ? "frac" : "irac", code: code.toUpperCase() } : null,
    form: active?.[2]?.toLowerCase().includes("l") ? "liquid" : active?.[2] ? "solid" : null,
  };
}

// The existing Responses schema is reused for the PDF pass; no second model
// contract or rate normaliser is introduced. A document read occurs only when
// the deterministic label parser did not recover usable vineyard directions.
export async function readLabelWithResearchSchema(input: {
  text: string; label: string; name: string; country: string; apiKey: string;
  fetchFn?: typeof fetch;
}): Promise<ChemicalResearchResult | null> {
  try {
    const answer = await callResponsesApi({
      model: DEFAULT_RESEARCH_MODEL, apiKey: input.apiKey, fetchFn: input.fetchFn ?? fetch,
      timeoutMs: 30_000, reasoningEffort: "low", searchCountry: null,
      instructions: `Read ONLY the supplied product label text. Do not use web search or model memory. Populate the existing chemical research JSON schema. Set every source_ref to ${input.label}. Preserve EVERY distinct vineyard/grapevine weed or use rate row with its original basis, unit, range, withholding period and critical directions. Also include explicitly cross-referenced directions tables relevant to grapevines. Never convert /ha into /100 L or combine rates for different targets. If the label lacks a field, leave it unresolved. Registration is optional.`,
      input: `Product: ${input.name}. Country: ${input.country}. Label URL: ${input.label}\n\nDOCUMENT TEXT:\n${input.text.slice(0, 90_000)}`,
    });
    const extracted = parseChemicalResearchResult(answer.payload);
    // PDF table text interleaves columns, so a full-sentence substring check
    // wrongly rejects real rows. Require each stated number and printed unit
    // to occur in the fetched document; the model still binds the row context.
    const compact = input.text.toLowerCase().replace(/\s+/g, "");
    const valid = (raw: string | null) => {
      if (!raw) return false;
      const numbers = raw.match(/\d+(?:\.\d+)?/g) ?? [];
      const unit = /(?:ml|g|kg|l)\s*\/\s*(?:100\s*l|ha)/i.exec(raw)?.[0];
      return numbers.length > 0 && numbers.every((n) => compact.includes(n)) &&
        (!unit || compact.includes(unit.toLowerCase().replace(/\s+/g, "")));
    };
    return {
      ...extracted,
      registered_uses: extracted.registered_uses.map((use) => ({
        ...use, source_refs: [input.label],
        rates: use.rates.filter((rate) => rate.raw_text ? valid(rate.raw_text) : false)
          .map((rate) => ({ ...rate, source_refs: [input.label] })),
      })).filter((use) => use.rates.length > 0),
    };
  } catch {
    return null;
  }
}

export interface WebCandidate {
  name: string;
  brand: string;
  activeIngredient: string;
  product_category: string | null;
  source: "research";
}

/** Web candidates are crop inputs with traceable sources, not just registrations sharing a word. */
export function agriculturalWebCandidates(query: string, research: ChemicalResearchResult, country: string): WebCandidate[] {
  const tokens = query.toLowerCase().match(/[a-z0-9]+/g) ?? [];
  const relates = (name: string) => tokens.some((token) => token.length >= 3 && name.toLowerCase().includes(token));
  const credible = (url: string) => {
    const source = classifyUrl(url, country);
    return source.trust !== "search_engine" && source.trust !== "reseller" &&
      source.kind !== "safety_data_sheet" && source.kind !== "search_results" && /^https:\/\//i.test(url);
  };
  const name = research.product.canonical_name ?? "";
  const evidence = research.product.source_refs.some(credible) ||
    research.documents.product_page_candidates.some((d) => credible(d.url)) ||
    research.documents.official_label_candidates.some((d) => credible(d.url));
  const results: WebCandidate[] = [];
  if (name && relates(name) && !ANIMAL_OR_HUMAN.test(name) && evidence &&
    (CROP_CONTEXT.test(`${name} ${research.product.category ?? ""} ${research.notes ?? ""}`) ||
      research.registered_uses.some((use) => CROP_CONTEXT.test(use.crop)))) {
    results.push({ name, brand: research.product.manufacturer ?? research.product.registrant ?? "",
      activeIngredient: research.active_ingredients.map((a) => a.name).join(", "),
      product_category: research.product.category, source: "research" });
  }
  for (const candidate of research.registration_candidates) {
    const alternative = candidate.registered_product_name ?? "";
    if (!alternative || !relates(alternative) || ANIMAL_OR_HUMAN.test(`${alternative} ${candidate.reason}`) ||
      !CROP_CONTEXT.test(`${alternative} ${candidate.reason}`) || !candidate.source_url ||
      !credible(candidate.source_url) || results.some((r) => r.name.toLowerCase() === alternative.toLowerCase())) continue;
    results.push({ name: alternative, brand: "", activeIngredient: "",
      product_category: null, source: "research" });
  }
  return results;
}

/** Retain only source-backed facts; model memory and unverified registration leads never fill Review. */
export function supportedWebResearch(
  research: ChemicalResearchResult, country: string, verifiedLabel: string | null, productPage: string | null,
): ChemicalResearchResult {
  const backed = (refs: string[]) => refs.some((url) =>
    url === verifiedLabel || url === productPage ||
    (classifyUrl(url, country).isOfficialLabelCandidate && url === verifiedLabel));
  const productBacked = backed(research.product.source_refs) || Boolean(productPage);
  return {
    ...research,
    registration_candidates: [],
    product: { ...research.product,
      canonical_name: productBacked ? research.product.canonical_name : null,
      manufacturer: productBacked ? research.product.manufacturer : null,
      registrant: productBacked ? research.product.registrant : null,
      category: productBacked ? research.product.category : null,
      form_type: productBacked ? research.product.form_type : null,
    },
    active_ingredients: research.active_ingredients.filter((active) => backed(active.source_refs)),
    registered_uses: verifiedLabel ? research.registered_uses.filter((use) => backed(use.source_refs)).map((use) => ({
      ...use, rates: use.rates.filter((rate) => backed(rate.source_refs)),
    })) : [],
  };
}
