import { classifyUrl } from "./research/classify.ts";
import { nameCorresponds } from "./ingestion/matching.ts";
import type { WebCandidate } from "./web_lookup.ts";
import type { ChemicalResearchResult } from "./research/schema.ts";
import { DEFAULT_RESEARCH_MODEL, OPENAI_RESPONSES_URL } from "./research/responses_client.ts";

/** A catalogue identity is not a claim that its vineyard label/rates are complete. */
export interface WebIdentity {
  name: string;
  registrant: string;
  registrationNumber: string | null;
  category: string | null;
  activeNames: string;
  pageUrls: string[];
  labelUrls: string[];
  resistanceState?: "classified" | "not_applicable" | "unresolved";
}

const CROP = /\b(herbicide|fungicide|insecticide|miticide|fertili[sz]er|adjuvant|biostimulant|foliar|crop)\b/i;
const ANIMAL = /\b(cattle|horse|sheep|livestock|veterinary|pour-on|drench|pet)\b/i;

// Documented, fetched manufacturer PDF fixture for the measured missing-vineyard Master identity.
// An exact identity cross-check is mandatory: this is a URL lead, never pre-verified rate data.
const VERIFIED_LABEL_LEADS: Record<string, string> = {
  "AU:90143:cropsure beast 200 herbicide":
    "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf",
};

export function verifiedManufacturerLead(identity: WebIdentity, country: string): string | null {
  const key = `${country}:${identity.registrationNumber ?? ""}:${identity.name.trim().toLowerCase()}`;
  return VERIFIED_LABEL_LEADS[key] ?? null;
}

export function manufacturerUrlsFromMaster(row: Record<string, unknown>, country: string): { pages: string[]; labels: string[] } {
  const pages: string[] = [];
  const labels: string[] = [];
  const sources = Array.isArray(row.verification_sources) ? row.verification_sources : [];
  for (const source of sources) {
    if (!source || typeof source !== "object") continue;
    const item = source as Record<string, unknown>;
    const url = String(item.reference ?? "");
    const classified = classifyUrl(url, country);
    // A JSON 'manufacturer_label' tag cannot override government host classification.
    if (classified.trust !== "registrant" || !url.startsWith("https://")) continue;
    if (classified.kind === "label_document") labels.push(url);
    else if (classified.isInspectableProductPage) pages.push(url);
  }
  return { pages: [...new Set(pages)], labels: [...new Set(labels)] };
}

/** Separate, read-only identity query; deliberately does not use the vineyard eligibility gate. */
export async function findWebMasterIdentities(
  select: (query: string) => Promise<Record<string, unknown>[] | null>, query: string, country: string,
): Promise<WebIdentity[]> {
  if (!country || query.trim().length < 2) return [];
  const needle = query.trim().toLowerCase();
  const safe = needle.replace(/[\\%_*,().]/g, "").replace(/\s+/g, " ");
  if (safe.length < 2) return [];
  const rows = await select(`select=registered_product_name,registration_number,registrant,registration_country,registration_scheme,product_category,active_ingredients,resistance_classification_state,verification_status,verification_sources,source_kind,source_reference,review_status&registration_country=eq.${encodeURIComponent(country)}&registered_product_name=ilike.${encodeURIComponent(`*${safe}*`)}&limit=25`) ?? [];
  return rows.filter((row) => {
    const name = String(row.registered_product_name ?? "");
    const category = String(row.product_category ?? "");
    return String(row.registration_country).toUpperCase() === country &&
      String(row.registration_scheme).toLowerCase() === "apvma" &&
      String(row.registration_number ?? "").trim().length > 0 &&
      ["approved", "candidate"].includes(String(row.review_status)) &&
      ["verified", "partially_verified"].includes(String(row.verification_status)) &&
      CROP.test(`${name} ${category}`) && !ANIMAL.test(`${name} ${category}`) &&
      (String(row.source_kind) === "official_register" ||
        (Array.isArray(row.verification_sources) && row.verification_sources.some((s: unknown) =>
          typeof s === "object" && s !== null && (s as Record<string, unknown>).kind === "official_register")));
  }).map((row) => {
    const urls = manufacturerUrlsFromMaster(row, country);
    const actives = Array.isArray(row.active_ingredients) ? row.active_ingredients : [];
    return { name: String(row.registered_product_name), registrant: String(row.registrant ?? ""),
      registrationNumber: String(row.registration_number), category: String(row.product_category ?? "") || null,
      activeNames: actives.map((a: unknown) => typeof a === "object" && a !== null ? String((a as Record<string, unknown>).name ?? "") : "").filter(Boolean).join(", "),
      pageUrls: urls.pages, labelUrls: urls.labels,
      resistanceState: ["classified", "not_applicable", "unresolved"].includes(String(row.resistance_classification_state))
        ? row.resistance_classification_state as WebIdentity["resistanceState"] : "unresolved" };
  });
}

export function identityCandidate(identity: WebIdentity): WebCandidate & { registration_number: string | null; resistance_classification_state: string } {
  return { name: identity.name, brand: identity.registrant, activeIngredient: identity.activeNames,
    product_category: identity.category, registration_number: identity.registrationNumber, source: "research",
    resistance_classification_state: identity.resistanceState ?? "unresolved" };
}

export function identityResearch(identity: WebIdentity, query: string, country: string, leads: ManufacturerLeads): ChemicalResearchResult {
  const page = leads.productUrl ?? identity.pageUrls[0] ?? null;
  const label = leads.labelUrl ?? identity.labelUrls[0] ?? null;
  const document = (url: string) => ({ url, title: null, domain: new URL(url).hostname, reason: "Manufacturer URL lead" });
  return { product: { searched_name: query, canonical_name: identity.name, manufacturer: identity.registrant,
    registrant: identity.registrant, category: identity.category, form_type: null, country,
    source_refs: [page, label].filter((url): url is string => !!url) },
    registration_candidates: [], active_ingredients: [], registered_uses: [],
    documents: { product_page_candidates: page ? [document(page)] : [],
      official_label_candidates: label ? [document(label)] : [], sds_candidates: [] },
    sources: [], unresolved: [], notes: null };
}

export interface ManufacturerLeads { productUrl: string | null; labelUrl: string | null }
const URL_DISCOVERY_TIMEOUT_MS = 12_000;

/** One small, abortable web-search request; no full research schema and no serial model escalation. */
export async function discoverManufacturerUrls(input: {
  identity: WebIdentity | null; query: string; country: string; apiKey: string; fetchFn: typeof fetch;
  timeoutMs?: number;
}): Promise<ManufacturerLeads | null> {
  if (!input.apiKey) return null;
  const name = input.identity?.name ?? input.query;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), input.timeoutMs ?? URL_DISCOVERY_TIMEOUT_MS);
  try {
    const response = await input.fetchFn(OPENAI_RESPONSES_URL, {
      method: "POST", signal: controller.signal,
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${input.apiKey}` },
      body: JSON.stringify({ model: DEFAULT_RESEARCH_MODEL,
        instructions: "Find only the registrant/manufacturer-owned product page and commercial product label for the exact agricultural product. Never substitute a veterinary product, reseller, SDS or government/regulator PDF. Only report URLs found by web search; missing URLs are null. Do not interpret label content.",
        input: `Product: ${name}; registrant: ${input.identity?.registrant ?? "unknown"}; registration: ${input.identity?.registrationNumber ?? "unknown"}; country: ${input.country}. Find manufacturer product page and label URL only.`,
        tools: [{ type: "web_search", user_location: { type: "approximate", country: input.country } }],
        include: ["web_search_call.action.sources"], store: false, reasoning: { effort: "low" },
        text: { format: { type: "json_schema", name: "manufacturer_urls", strict: true, schema: {
          type: "object", additionalProperties: false, required: ["product_url", "label_url"],
          properties: { product_url: { type: ["string", "null"] }, label_url: { type: ["string", "null"] } },
        } } },
      }),
    });
    if (!response.ok) return null;
    const data = await response.json();
    const output = Array.isArray(data?.output) ? data.output : [];
    const consulted = new Set<string>();
    for (const item of output) if (item?.type === "web_search_call") {
      for (const source of item?.action?.sources ?? []) {
        const url = typeof source === "string" ? source : source?.url;
        if (typeof url === "string") consulted.add(url);
      }
    }
    const text = output.filter((item: { type?: string }) => item?.type === "message")
      .flatMap((item: { content?: Array<{ type?: string; text?: string }> }) => item.content ?? [])
      .filter((part: { type?: string }) => part.type === "output_text").map((part: { text?: string }) => part.text ?? "").join("");
    if (!text) return null;
    const result = JSON.parse(text);
    const accepted = (url: unknown, kind: "page" | "label"): string | null => {
      if (typeof url !== "string" || !url.startsWith("https://") || !consulted.has(url)) return null;
      const classified = classifyUrl(url, input.country);
      if (classified.trust !== "registrant") return null;
      return kind === "label" ? classified.kind === "label_document" ? url : null
        : classified.isInspectableProductPage ? url : null;
    };
    const productUrl = accepted(result.product_url, "page");
    const labelUrl = accepted(result.label_url, "label");
    return productUrl || labelUrl ? { productUrl, labelUrl } : null;
  } catch { return null; }
  finally { clearTimeout(timer); }
}

/** A locked name must correspond to the returned candidate; never silently swap identities. */
export function selectedIdentity(identities: WebIdentity[], selected: string): WebIdentity | null {
  const exact = identities.filter((identity) => nameCorresponds(identity.name, selected));
  return exact.length === 1 ? exact[0] : null;
}
