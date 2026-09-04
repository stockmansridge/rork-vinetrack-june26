// Supabase Edge Function: chemical-info-lookup
//
// Server-side AI proxy for chemical search and product info lookup, plus the
// Master Chemical Catalogue's authoritative ingestion pipeline (Stage 3).
// Keeps the OpenAI API key off the device.
//
// Request (POST JSON):
//   { "action": "search", "query": string, "country"?: string }
//   { "action": "info",   "productName": string, "country"?: string }
//   { "action": "structured", "productName": string, "country"?: string,
//     "registrationNumber"?: string }   // optional identity hint (sql/199)
//   { "action": "master_refresh", "masterChemicalId": uuid,
//     "apply"?: boolean }               // system admins only (Stage 3)
//   { "action": "master_review_preview", "masterChemicalId": uuid }
//                                        // system admins only (Stage 2 R2-B)
//                                        // — read-only refresh + SERVER-
//                                        // stored resolver patch
//                                        // (master_review_previews, sql/203).
//                                        // NEVER accepts a patch/apply input;
//                                        // apply is the master_review_apply
//                                        // RPC called with the ADMIN'S OWN
//                                        // JWT, never the service role.
//   { "action": "seed_apply", "registrationNumber": string,
//     "productName": string, "seedSource": string }
//                                        // system admins only (Stage 5B) —
//                                        // INSERT-ONLY reviewed-seed apply:
//                                        // existing rows (any review state)
//                                        // come back "already_exists"
//                                        // untouched; the live register
//                                        // re-verifies name↔number before
//                                        // any write; candidates only.
//
// Response 200 JSON shapes:
//   action=search -> { results: ChemicalSearchResult[], jurisdiction }
//                     Lookup order: approved master hits FIRST (source:
//                     "master"), then official-register CANDIDATES from the
//                     jurisdiction's register (source: "official_register",
//                     each with its registration_number) — DISCOVERY ONLY:
//                     partial names, typography variants and bare
//                     registration numbers all list plausible rows for a
//                     human to pick from, several when ambiguous, never a
//                     silent selection. Identity/authority is established
//                     ONLY by the structured action on the selected exact
//                     identity. AI suggestions follow (deduplicated).
//   action=info   -> ChemicalInfoResponse  (legacy AI-only quick info — the
//                     structured action is the identity resolver)
//   action=structured -> the sql/194 structured contract, plus (sql/199):
//       match_source: "master" | "authoritative_candidate" | "ai_candidate"
//                     | "unresolved"
//       master?:    { master_chemical_id, master_revision, catalogue_status,
//                     registration_identity_key }      (master matches only)
//       candidate?: { master_chemical_id, candidate_revision,
//                     catalogue_status: "candidate",
//                     registration_identity_key }      (additive, Stage 3 —
//                     NEVER a master match; approval is a human step;
//                     enqueued ONLY from register-verified identities)
//       discovery?: { adapter, outcome, registration_identity_key?,
//                     match_mode?, register_status?, error_category?,
//                     ai_registration_hint_discarded? }  (additive)
//       jurisdiction: { requested_country, resolved_country_code,
//                     resolved_country_name, register_adapter,
//                     register_support }  (additive — the ONE authoritative
//                     statement of the lookup jurisdiction; clients render
//                     lookup country AND registration country from this,
//                     never derived independently)
//       field_provenance: { <field>: official_register | manufacturer_label
//                     | authoritative_classification | ai_interpretation
//                     | master_catalogue | unresolved }  (additive)
//                     Invariant: verification.unresolved_fields never lists
//                     a whole field whose served value carries authoritative
//                     provenance. AI-populated (ai_interpretation) fields
//                     stay listed; per-context gaps (rates:<crop>, …) are
//                     untouched. Enforced on every serving path.
//       ai_suggested_uses?: AI-read uses on a register-resolved product with
//                     no label evidence — clearly-non-authoritative
//                     suggestions; NEVER served as registered_uses
//       ai_suggestion?: STRICT FAIL-CLOSED path only — when a supported
//                     register was successfully consulted and identity stayed
//                     unresolved/ambiguous, the ENTIRE AI reading (name,
//                     registrant, chemistry, uses) moves here; every
//                     canonical product field is served unresolved and
//                     match_source is "unresolved", never "ai_candidate"
//       guidance?:    operator-facing sentence on that fail-closed path
//                     ("could not uniquely verify … refine the product name
//                     or registration number")
//   action=master_refresh -> { outcome, changes[], applied, master }
//     outcome: no_material_change | material_change | evidence_refreshed
//              | conflict | source_unavailable
//   action=master_review_preview -> { outcome, changes[], identity_guard,
//     preview_stored, preview_id, expires_at, base_revision,
//     proposed_patch (display only), current, master,
//     no_preview_reason?, error_category? }
//     No preview row is stored for no_material_change / source_unavailable /
//     identity-guard refusal / no writable patch; a preview NEVER mutates
//     master_chemicals.
//
// Errors return { error: string } with appropriate HTTP status.
//
// See docs/master-chemical-ingestion.md for the ingestion trust model,
// dedupe, cache and failure behaviour. Old clients ignore every additive
// key; the pre-Stage-3 response contract is unchanged byte-for-byte on the
// master / ai_candidate / unresolved paths.

// deno-lint-ignore-file no-explicit-any

// ---------------------------------------------------------------------------
// Authoritative activity-group classification — MOVED to
// ingestion/activity_groups.ts (Stage 3) so the authoritative ingestion
// module and its deno tests consult the SAME table as the AI cross-check.
//
// Deployment note: `supabase functions deploy chemical-info-lookup`
// (scripts/deploy-edge-functions.ps1 / .sh) bundles the full local module
// graph — the same mechanism that already ships
// vinetrack-webhook-dispatch/lib.ts and the _shared/email imports. Pasting
// index.ts alone into the dashboard editor is NO LONGER a supported way to
// deploy this function.
// ---------------------------------------------------------------------------

import {
  ACTIVITY_GROUP_TABLE_VERSION,
  type ActivityGroup,
  type ActivityGroupScheme,
  type GroupConflict,
  normaliseCode,
  reconcileGroup,
} from "./ingestion/activity_groups.ts";
import type { MasterOps, MasterRow } from "./ingestion/contract.ts";
import {
  buildCandidatePayload,
  buildFieldProvenance,
  buildRegisterOnlyStructured,
  candidateEnvelope,
  discardUnverifiedAiIdentity,
  discoverAuthoritative,
  discoverRegisterCandidates,
  discoveryEnvelope,
  ingestionLog,
  mergeDiscoveryIntoStructured,
  pruneAuthoritativelyResolvedFields,
  quarantineUnverifiedAiFacts,
  upsertCandidate,
} from "./ingestion/ingest.ts";
import {
  jurisdictionEnvelope,
  registrationSchemeForCode,
  resolveLookupCountry,
} from "./ingestion/jurisdiction.ts";
import {
  buildMasterStructuredResponse,
  fetchApprovedMaster,
  masterHasCompleteVineyardData,
  searchMaster,
} from "./ingestion/master_lookup.ts";
import {
  buildCandidateRefreshPatch,
  refreshMasterRow,
} from "./ingestion/refresh.ts";
import {
  type PreviewStore,
  runMasterReviewPreview,
} from "./ingestion/review_preview.ts";
import {
  applyManufacturerEnrichment,
  enrichFromManufacturerLabel,
} from "./ingestion/manufacturer_enrichment.ts";
import {
  cachedEnrichmentIsUsable,
  createPostgrestEnrichmentCache,
  ENRICHMENT_CACHE_TTL_SECONDS,
  ENRICHMENT_CACHE_VERSION,
  enrichmentCacheKey,
} from "./ingestion/enrichment_cache.ts";
import { LookupTimer, structuredOnlyStagesEntered } from "./timings.ts";
import { runSeedApply } from "./ingestion/seed_apply.ts";
import {
  buildResolverAttempts,
  type InspectedProductPage,
  projectResearch,
  projectResearchToSearchResults,
  type ResearchProjection,
} from "./research/authority.ts";
import { inspectCandidateProductPages } from "./research/page_inspector.ts";
import {
  readResearchConfig,
  researchLog,
  runChemicalResearch,
  type ResearchOutcome,
} from "./research/research.ts";
import { discoveryDecision, rankCandidates } from "./ranking.ts";
import {
  readSelectedRegistration,
  registrationViolation,
  unresolvedForSelection,
} from "./identity_lock.ts";
import {
  projectGrapevineUses,
  selectLabelReferences,
} from "./grapevine_label.ts";
import {
  applyRateIdentities,
  DIRECTION_SEED_KEY,
  stripStructuredDirectionSeeds,
} from "./rate_identity.ts";
import { applyDefaultRateOptions } from "./default_rate_options.ts";
import {
  createPostgrestSuggestionStore,
  SUGGESTION_CACHE_TTL_SECONDS,
  suggestionCacheKey,
  validateResearchSuggestions,
} from "./research_suggestions.ts";
import {
  buildDiagnostics,
  type CandidateDiagnostic,
  candidatesFromSearchResults,
  diagnosticsLog,
  type LookupCacheState,
  type LookupClientContext,
  type LookupMethod,
  newRequestId,
  readClientContext,
} from "./diagnostics.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// LEGACY chat-completions model. Still used by the `info` action, which is
// an unrelated free-text helper. The RESEARCH path (search/structured) no
// longer reads this variable at all — see research/research.ts, where the
// models are named explicitly so a stale `gpt-4o` in the environment cannot
// silently undo the Responses API upgrade.
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") ?? "gpt-4o";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function callOpenAI(
  systemPrompt: string,
  userPrompt: string,
  apiKey: string,
): Promise<string> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      response_format: { type: "json_object" },
      temperature: 0.2,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
    }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OpenAI HTTP ${res.status}: ${text.slice(0, 200)}`);
  }
  const data: any = await res.json();
  const content: string | undefined = data?.choices?.[0]?.message?.content;
  if (!content) throw new Error("Empty response from AI provider");
  return content;
}

function buildSearchPrompt(query: string, country: string): {
  system: string;
  user: string;
} {
  const system =
    "You are an agricultural and viticultural input database expert covering ALL types of vineyard inputs across global and regional markets, including small specialty manufacturers (e.g. Switch AG, Stoller, Omnia, Campbells, AgNova, Grochem, Sipcam, ADAMA, Nufarm, Syngenta, Bayer, Corteva, BASF, UPL, FMC). You know niche Australian, New Zealand, US, EU, South African, and South American brands — not just the top mainstream products. You respond ONLY with valid JSON, no markdown, no explanation, no code fences.";
  const countryContext = country
    ? ` IMPORTANT: The vineyard is located in ${country}. You MUST prioritize products that are registered, sold, and commonly used in ${country}, including small specialty/regional brands. List ${country}-registered brand names first. Use ${country}-based manufacturers and distributors. Only include international/generic products if fewer than 8 local ${country} products match the query.`
    : "";
  const user =
    `Search for agricultural/viticultural inputs matching "${query}".${countryContext}\n\nConsider ALL of the following input categories — do NOT restrict to mainstream crop protection only:\n- Fungicides, herbicides, insecticides, miticides, nematicides, bactericides\n- Plant growth regulators (PGRs)\n- Surfactants, adjuvants, wetters, stickers, penetrants\n- Fertilisers (granular, liquid, foliar, fertigation)\n- Biostimulants (amino acids, seaweed/kelp, humic/fulvic acid, fish hydrolysate, microbial)\n- Foliar nutrients and trace elements (Ca, Mg, Zn, B, Mn, Fe, Mo, Cu)\n- Soil conditioners, gypsum, lime, compost teas\n- Biological controls (Trichoderma, Bacillus, mycorrhizae)\n- Specialty/niche regional products from small manufacturers (e.g. Switch AG amino acid range, Stoller, Omnia Nutriology, Campbells Liquifert, AgNova, Grochem)\n\nMatch broadly: brand names, product line names, active ingredients, manufacturer names, partial matches, fuzzy matches, and common misspellings. If the query mentions a manufacturer (e.g. "Switch AG"), list THAT manufacturer's products even if niche. Include products even if they are less common — do not filter out specialty/biostimulant/nutrition products. Return up to 8 products as JSON:\n{"results":[{"name":"Product name","activeIngredient":"active ingredient(s) or key components for biostimulants/fertilisers","chemicalGroup":"group e.g. Strobilurin, Triazole, Biostimulant - Amino Acid, Foliar Fertiliser - N","brand":"manufacturer","primaryUse":"primary use in vineyard e.g. Downy Mildew control, Foliar nitrogen, Stress recovery, Flowering biostimulant","modeOfAction":"MOA classification - REQUIRED for all crop protection products. Use the official resistance management code with a short name, e.g. \"11 (QoI / Strobilurin)\", \"3 (DMI / Triazole)\", \"M5 (Multi-site / Chlorothalonil)\", \"4A (Neonicotinoid)\", \"G (Glycine)\". Use FRAC codes for fungicides, HRAC for herbicides, IRAC for insecticides/miticides. Always look up and provide MOA — do NOT leave blank for crop protection products. Only return empty string for pure biostimulants, fertilisers, adjuvants, or surfactants where MOA does not apply."}]}`;
  return { system, user };
}

function buildInfoPrompt(productName: string, country: string): {
  system: string;
  user: string;
} {
  const system =
    "You are an agricultural and viticultural input database expert covering crop protection, fertilisers, foliar nutrients, biostimulants (amino acid, seaweed, humic), adjuvants, and biological controls from both major and small specialty manufacturers globally (including niche Australian/NZ brands like Switch AG, AgNova, Grochem, Campbells, Omnia, Stoller). You respond ONLY with valid JSON, no markdown, no explanation, no code fences. CRITICAL: You must NEVER fabricate, guess, or construct URLs. URLs are validated against the live web after you respond and hallucinated URLs are dropped — but they also waste user trust. Default to empty strings for any URL you are not 100% certain exists.";
  const countryContext = country
    ? ` IMPORTANT: The vineyard is located in ${country}. You MUST use the ${country}-registered version of this product. Provide ${country}-specific brand name and label rates. If the product has a different brand name in ${country}, use the ${country} brand name.`
    : "";
  const user = `Provide details for the agricultural product "${productName}".${countryContext} Find the closest match if exact name not found. Include recommended application rates for vineyard/viticultural use where available. Return as JSON:
{"activeIngredient":"active ingredient(s)","brand":"manufacturer","chemicalGroup":"group classification","labelURL":"STRICT: Direct https URL to the OFFICIAL product LABEL document (PDF strongly preferred) hosted by the manufacturer, registrant, or a national regulator (APVMA, EPA, ACVM, EU register). MUST point directly at the label/SDS file, NOT a product marketing page, NOT a brand homepage, NOT a category/search page. If you cannot recall the exact label file URL with certainty, return an empty string. NEVER construct URLs from product names. NEVER guess paths like /products/<slug>. NEVER use example.com, placeholder.com, manufacturer.com, etc. When in doubt: empty string.","productURL":"Optional. The manufacturer's product information page (marketing/landing page) if you are confident the URL exists. Empty string if unsure. This is separate from labelURL and must NEVER be returned as labelURL.","sdsURL":"Optional. Direct https URL to the official Safety Data Sheet PDF if you are certain it exists. Empty string if unsure.","primaryUse":"primary use in vineyard e.g. Downy Mildew control, Nitrogen fertiliser, Botrytis prevention","formType":"liquid or solid","modeOfAction":"MOA classification - REQUIRED for all crop protection products. Use the official resistance management code with a short name, e.g. \"11 (QoI / Strobilurin)\", \"3 (DMI / Triazole)\", \"M5 (Multi-site / Chlorothalonil)\", \"4A (Neonicotinoid)\". Use FRAC for fungicides, HRAC for herbicides, IRAC for insecticides/miticides. Always look up and provide MOA — do NOT leave blank for crop protection products. Only return empty string for pure biostimulants, fertilisers, adjuvants, or surfactants where MOA does not apply.","ratesPerHectare":[{"label":"Standard rate","value":1.5}],"ratesPer100L":[{"label":"Standard rate","value":0.15}]}
IMPORTANT: The "formType" field must be either "liquid" or "solid". Determine this from the product's physical form. Liquid products (EC, SC, SL, SE, EW, flowables, suspension concentrates, emulsifiable concentrates, soluble liquids) should be "liquid". Solid products (WG, WDG, WP, DF, granules, wettable powders, dry flowables, water dispersible granules) should be "solid".
The ratesPerHectare array should contain recommended rates per hectare. For liquid products, values must be in Litres (L). For solid products, values must be in Kilograms (Kg). The ratesPer100L array should contain recommended rates per 100 litres of water, using the same unit convention. Include multiple rates if the label specifies different rates for different conditions (e.g. low/medium/high disease pressure). If rates are not available for a basis, return an empty array.`;
  return { system, user };
}

// ===========================================================================
// Structured chemical intelligence (action="structured")
// ===========================================================================
//
// The AI is an EXTRACTION AND MATCHING ASSISTANT here, not the authority. The
// source hierarchy, and what is actually wired today:
//
//   official register — AU: LIVE APVMA PubCRIS register extract (data.gov.au
//                       CKAN datastore), selected per jurisdiction by
//                       ingestion/registry.ts -> ingestion/apvma.ts
//     -> official label evidence — AU: the approved label's published claim
//        data (produse/host/pest use claims + prodcom label statements),
//        attributed `manufacturer_label` (ingestion/label.ts, Stage 4)
//       -> authoritative activity-group classification (server-side table)
//         -> viticulture-specific cross-check
//           -> AI/search interpretation (fallback; rates detail)
//
// For AU vineyards the structured lookup consults the live APVMA register:
// registration identity (AU:apvma:<number>), verbatim registered product name,
// registrant, actives with concentrations, registration status and the label
// approval pointer come from the register; the approved label's use claims,
// WHP, re-entry wording and restrictions come from official label evidence
// where it resolves (fail-soft otherwise). Both feed CANDIDATE-only master
// ingestion (ingestion/ingest.ts). Label RATES are not machine-published by
// the register: they stay the model's reading of public label material —
// attributed `ai_interpretation`, never promoted without label evidence, and
// never able to make a product Verified on their own. No live ACVM (NZ)
// source is wired yet; NZ remains AI-extraction-only under the same honesty
// rules. The FRAC/HRAC/IRAC classification table stays server-side
// authoritative and is applied to every active AFTER extraction.

// Register hints for the extraction prompt, keyed by RESOLVED ISO-2 code.
// Country resolution itself lives in ingestion/jurisdiction.ts — the server
// side of docs/vineyard-country-contract.md (canonical display names,
// approved aliases, bare ISO-2 codes; NO locale/default-country fallback).
const REGISTER_BY_CODE: Record<string, string> = {
  AU: "the APVMA public register (PUBCRIS) product number",
  NZ: "the NZ ACVM register number (and the EPA/HSNO approval number if that is what the label quotes)",
};

function buildStructuredPrompt(
  productName: string,
  country: string,
  countryCode: string,
): {
  system: string;
  user: string;
} {
  const system =
    "You extract structured agricultural product registration data. You respond ONLY with valid JSON " +
    "— no markdown, no explanation, no code fences.\n\n" +
    "CRITICAL RULES:\n" +
    "1. NEVER invent a registration number, a concentration, or a URL. If you are not certain, return null.\n" +
    "2. A field you cannot establish MUST be null AND its name MUST appear in `unresolved`. " +
    "Returning null with an honest `unresolved` entry is ALWAYS better than a plausible guess — " +
    "a wrong active ingredient concentration causes a real mis-dose in a real vineyard.\n" +
    "3. Product identity is COUNTRY-SPECIFIC. A product name used in Australia is NOT automatically " +
    "the same registered product in New Zealand. Never carry rates, actives or registration numbers " +
    "across countries.\n" +
    "4. List EVERY active ingredient separately. A mixture has multiple actives, each with its own " +
    "concentration and its own resistance group.";

  const register = REGISTER_BY_CODE[countryCode] ??
    "the national pesticide register that applies in that country";
  const countryContext = country
    ? `The vineyard is in ${country}. Use ONLY the ${country}-registered version of this product. ` +
      `For the registration identifier use ${register}. If this product is not registered in ${country}, ` +
      `say so by returning null for registration and adding "registration" to unresolved — do NOT ` +
      `substitute the registration from another country.`
    : "No country was supplied, so return null for registration and add \"country\" to unresolved.";

  const user = `Provide structured registration data for the agricultural product "${productName}".
${countryContext}

Return EXACTLY this JSON shape:
{
  "product_name": "exact registered product name, or null",
  "registrant": "registrant/manufacturer of record, or null",
  "registration_number": "register product number as printed, or null",
  "label_reference": "direct https URL to the official label PDF if you are certain it exists, else null",
  "label_version": "label approval date or version if known, else null",
  "product_category": "one of: fungicide, herbicide, insecticide, miticide, adjuvant, growthRegulator, foliarNutrient, granularFertiliser, liquidFertiliser, biostimulant, other",
  "form_type": "liquid or solid",
  "active_ingredients": [
    {
      "name": "ISO common name of the active, e.g. Tebuconazole",
      "concentration": 200,
      "concentration_unit": "g/L | g/kg | % w/w | % w/v | CFU/g",
      "activity_group_code": "resistance code only, e.g. 3, 11, M5, 4A, G — no words",
      "activity_group_scheme": "frac | hrac | irac | not_applicable"
    }
  ],
  "registered_uses": [
    {
      "crop": "e.g. Grapes (winegrapes)",
      "target": "target pest/disease exactly as the label words it, e.g. Powdery mildew",
      "rates": [
        {
          "label": "e.g. Standard rate, or Low disease pressure",
          "basis": "per_100_litres | per_hectare | range_per_100_litres | range_per_hectare | other",
          "value": 1.5,
          "min_value": null,
          "max_value": null,
          "unit": "L | mL | kg | g",
          "raw_text": "verbatim label wording when basis is other, else null"
        }
      ],
      "withholding_period_days": 14,
      "re_entry_period_hours": null,
      "restrictions": "short label restriction text, or null"
    }
  ],
  "unresolved": ["names of any fields above you could not establish"]
}

NOTES ON RATE BASIS — this matters and is frequently confused:
- The rate basis is what the LABEL quotes the product rate against. It is NOT how the sprayer
  measures water volume. A vineyard that measures carrier in L/100 m still applies a product whose
  label says 1.5 L/ha. Never convert a label rate into L/100 m.
- Use "range_per_hectare" / "range_per_100_litres" (with min_value and max_value) when the label
  gives a band rather than a single figure. Do not collapse a range to its midpoint.
- Only include registered_uses you are confident are on the label. Do NOT infer a registered use
  from the chemistry — "it is a Group 11 so it must control powdery mildew" is exactly the kind of
  inference that must not appear here. An empty registered_uses array is a valid, honest answer.`;
  return { system, user };
}

// `parseNumber`, `parseString`, `RATE_BASES`, `readDirectionSeed` and
// `normaliseRegisteredUses` now live in `registered_use_normaliser.ts`.
//
// They were moved because this module exports nothing and calls `Deno.serve`
// at load, so nothing in it could be imported by a test. The normaliser is the
// stage that rebuilds every registered use as a fresh object, which makes it
// the easiest place in the whole pipeline to silently DROP a field — as it did
// with the label's verbatim withholding wording. Its carry contract is now
// provable rather than assumed.

import {
  normaliseRegisteredUses,
  parseNumber,
  parseString,
  RATE_BASES,
} from "./registered_use_normaliser.ts";

const SCHEMES: ActivityGroupScheme[] = ["frac", "hrac", "irac", "not_applicable"];

function schemeFromCategory(category: string | null): ActivityGroupScheme | null {
  switch ((category ?? "").toLowerCase()) {
    case "fungicide":
      return "frac";
    case "herbicide":
      return "hrac";
    case "insecticide":
    case "miticide":
      return "irac";
    case "adjuvant":
    case "foliarnutrient":
    case "granularfertiliser":
    case "liquidfertiliser":
    case "biostimulant":
      return "not_applicable";
    default:
      return null;
  }
}

/**
 * Turns the model's raw extraction into the structured contract, then applies
 * the authoritative activity-group cross-check to every active.
 *
 * The verification status returned here is computed from EVIDENCE, never from
 * how confident the model sounded:
 *   - any group disagreement                       -> "conflict"
 *   - no actives established                       -> "unverified"
 *   - actives + registration + every group backed
 *     by the authoritative table                   -> "partially_verified"
 *
 * Note what is deliberately absent: this function NEVER returns "verified".
 * With no live official register available to this deployment, product identity
 * cannot be authoritatively confirmed server-side, so the highest honest state
 * is partially verified. Promotion to Verified is a human decision made in the
 * app's verify step. That ceiling is the entire point of Phase 4.
 */
/**
 * Provenance label for the model/path that actually produced an extraction.
 *
 * This has to be passed in, never assumed: the legacy chat-completions model
 * and the research model are different models reached by different code
 * paths, and stamping one path's model name on the other's output makes the
 * evidence trail lie about where a fact came from.
 */
function buildStructuredResponse(
  parsed: any,
  countryCode: string,
  extractionSource: string,
): any {
  const unresolved = new Set<string>(
    Array.isArray(parsed?.unresolved)
      ? parsed.unresolved.filter((x: any) => typeof x === "string")
      : [],
  );

  const productCategory = parseString(parsed?.product_category);
  const categoryScheme = schemeFromCategory(productCategory);
  const conflicts: GroupConflict[] = [];
  const actives: any[] = [];

  const rawActives = Array.isArray(parsed?.active_ingredients)
    ? parsed.active_ingredients
    : [];

  for (const a of rawActives) {
    const name = parseString(a?.name);
    if (!name) continue;

    const code = normaliseCode(String(a?.activity_group_code ?? ""));
    let scheme = parseString(a?.activity_group_scheme)?.toLowerCase() as
      | ActivityGroupScheme
      | undefined;
    if (!scheme || !SCHEMES.includes(scheme)) {
      scheme = categoryScheme ?? undefined;
    }
    const extracted: ActivityGroup | null = code && scheme && scheme !== "not_applicable"
      ? { scheme, code, common_name: null }
      : null;

    // THE cross-check. Whatever the model said, the authoritative table gets
    // the last word, and any disagreement is surfaced rather than resolved.
    const { group, source, conflict } = reconcileGroup(name, extracted);
    if (conflict) conflicts.push(conflict);
    if (!group) unresolved.add(`activity_group:${name}`);

    const concentration = parseNumber(a?.concentration);
    if (concentration === null) unresolved.add(`concentration:${name}`);

    actives.push({
      name,
      concentration,
      concentration_unit: parseString(a?.concentration_unit),
      activity_group: group,
      group_source: source,
      identity_source: "ai_interpretation",
    });
  }

  if (!actives.length) unresolved.add("active_ingredients");

  const registrationNumber = parseString(parsed?.registration_number);
  if (!registrationNumber) unresolved.add("registration_number");
  if (!countryCode) unresolved.add("country");

  // Manufacturer label FIRST, regulator label second (task §2). Both are
  // retained: the manufacturer's rendering is the label a grower physically
  // holds, and the regulator's is the approved document — a marketing page can
  // never substitute for either.
  const labelRefs = selectLabelReferences({
    manufacturerLabelUrl: parsed?.manufacturer_label_reference ??
      parsed?.manufacturer_label_url,
    regulatorLabelUrl: parsed?.label_reference ?? parsed?.regulator_label_url,
    productUrl: parsed?.productURL ?? parsed?.product_url,
    sdsUrl: parsed?.sdsURL ?? parsed?.sds_url,
  });

  const registration = registrationNumber || countryCode
    ? {
      country_code: countryCode,
      scheme: registrationNumber ? registrationSchemeForCode(countryCode || null) : null,
      registration_number: registrationNumber,
      registrant: parseString(parsed?.registrant),
      registered_product_name: parseString(parsed?.product_name),
      // Legacy single field — keeps pointing at the AUTHORITATIVE document so
      // shipped builds do not regress while clients adopt the split.
      label_reference: labelRefs.label_reference,
      manufacturer_label_url: labelRefs.manufacturer_label_url,
      regulator_label_url: labelRefs.regulator_label_url,
      manufacturer_product_url: labelRefs.manufacturer_product_url,
      sds_url: labelRefs.sds_url,
      label_version: parseString(parsed?.label_version),
    }
    : null;

  const registeredUses = normaliseRegisteredUses(parsed?.registered_uses);
  if (!registeredUses.length) unresolved.add("registered_uses");

  // Registered-rate identity is DELIBERATELY NOT minted here (Gate D1.3).
  //
  // `registration` at this point is built from the extraction itself — a
  // research/AI LEAD that `discardUnverifiedAiIdentity` may strip once the
  // register has its say. Both identities are product-bound, so minting
  // against that lead would stamp an id for a product this record may turn out
  // not to be, and a carried `direction_id` is honoured downstream — so the
  // wrong value would survive the register's correction.
  //
  // Each row instead carries an internal direction SEED (its crop, complete
  // target set and condition), which survives the one-target-per-row fan-out.
  // The real ids are minted in the handler once the register locks identity,
  // and the seed is removed there.

  // Grapevine-first projection (task §3, §5, §6). Other crops are RETAINED,
  // never discarded — they are real label content, just not the vineyard
  // workflow. The reference range appears ONLY when grapevine is absent.
  const grapevine = projectGrapevineUses(registeredUses);

  const sources: any[] = [
    {
      kind: "ai_interpretation",
      name: extractionSource,
      reference: null,
      retrieved_at: new Date().toISOString(),
    },
  ];
  // Only cite the authoritative table when it actually contributed something.
  if (actives.some((a) => a.group_source === "authoritative_classification")) {
    sources.push({
      kind: "authoritative_classification",
      name: `VineTrack activity group reference v${ACTIVITY_GROUP_TABLE_VERSION} (FRAC/HRAC/IRAC)`,
      reference: null,
      retrieved_at: new Date().toISOString(),
    });
  }

  let status: string;
  if (conflicts.length) {
    status = "conflict";
  } else if (!actives.length) {
    status = "unverified";
  } else {
    status = "partially_verified";
  }

  const schemeUsed = actives
    .map((a) => a.activity_group?.scheme)
    .find((s: string | undefined) => s && s !== "not_applicable") ?? null;

  // Additive (§13): the registrant's own product page, when research found
  // and CLASSIFIED one. It seeds the existing SavedChemical.productURL and is
  // never an Official Label — `label_reference` is a separate field fed only
  // by classified label documents, and a reseller/SDS/search page can reach
  // neither. No schema change: the client field already exists.
  const productUrl = parseString(parsed?.productURL) ??
    parseString(parsed?.product_url) ?? null;

  return {
    product_name: parseString(parsed?.product_name),
    product_category: productCategory ?? "",
    form_type: parseString(parsed?.form_type),
    product_url: productUrl,
    registration,
    // The label URLs a client can OPEN, grouped (task Phase 12).
    //
    // The registration block keeps its own fields for the clients already
    // decoding them. This is the form the Review Chemical screen reads, so a
    // screen asking for "the official label" does not have to know the
    // history of three column names to find one. The REGULATOR document is
    // authoritative and leads; nothing here is ever synthesised from a
    // registration number pattern.
    label_urls: {
      regulator_label_url: labelRefs.regulator_label_url,
      manufacturer_label_url: labelRefs.manufacturer_label_url,
      product_url: labelRefs.manufacturer_product_url ?? productUrl,
    },
    active_ingredients: actives,
    // Bare codes for the queryable column: ["3", "11"] — never ["3 + 11"].
    activity_groups: Array.from(
      new Set(
        actives
          .map((a) => a.activity_group?.code)
          .filter((c: string | undefined): c is string => Boolean(c)),
      ),
    ),
    activity_group_scheme: schemeUsed,
    // Full list, unchanged, for every existing reader.
    registered_uses: registeredUses,
    // Grapevine-first view for the review screen (task §3, §8).
    grapevine_uses: grapevine.grapevine_uses,
    other_crop_uses: grapevine.other_crop_uses,
    registered_for_grapevine: grapevine.registered_for_grapevine,
    label_reference_rate_ranges: grapevine.label_reference_rate_ranges,
    label_rate_bases: Array.from(
      new Set(
        registeredUses.flatMap((u) => u.rates.map((r: any) => r.basis)),
      ),
    ),
    verification: {
      status,
      sources,
      conflicts,
      unresolved_fields: Array.from(unresolved).sort(),
      verified_at: null,
    },
    activity_group_table_version: ACTIVITY_GROUP_TABLE_VERSION,
    schema_version: 1,
  };
}

// ===========================================================================
// Master Chemical Catalogue (sql/199) — approved-master-first lookup
// ===========================================================================
//
// Lookup priority (general resolver):
//   1. APPROVED master catalogue row — by exact registration identity when a
//      hint is supplied, else exact (case-insensitive) registered name or
//      exact lower-cased alias — retried with pure-typography variants
//      ("Spray Seal" ↔ "sprayseal") — always country-scoped, always
//      unique-or-nothing. A known approved product NEVER goes back through
//      the AI.
//   2. The jurisdiction's OFFICIAL REGISTER (registry-selected adapter):
//      deterministic identity resolution with typography normalisation and
//      the AWRI variant guard, then official label evidence.
//   3. AI extraction — discovery assistance and clearly-attributed
//      interpretation ONLY. Where the register was consulted and did not
//      verify, AI identity claims are discarded, never served.
//   4. Manual structured entry (client-side, unchanged).
//
// Identity discipline mirrors the apps: only review_status='approved' rows are
// served; a name/alias must match EXACTLY ONE row or the match is abandoned
// ("custodia" can never reach "Custodia Forte"); aliases are exact whole-string
// equality, never substrings. Matching rules live in ingestion/matching.ts and
// ingestion/master_lookup.ts.
//
// A CANDIDATE master row is enqueued ONLY from a register-verified identity
// (service-role write, deduplicated on the identity key, existing rows always
// win). An AI-asserted registration can no longer mint a catalogue row.
// Candidates are never served to lookups — they exist so the catalogue grows
// from real demand and a human admin can approve them against the register
// (sql/199 blocks approving AI provenance).
//
// EVERY catalogue call here is fail-open: any error (including sql/199 not yet
// applied) falls through to the AI path, so "not in Master" can never become
// "cannot look up".

const MASTER_TABLE_URL = (() => {
  const base = Deno.env.get("SUPABASE_URL") ?? "";
  return base ? `${base.replace(/\/+$/, "")}/rest/v1/master_chemicals` : "";
})();
const REVIEW_PREVIEWS_URL = (() => {
  const base = Deno.env.get("SUPABASE_URL") ?? "";
  return base ? `${base.replace(/\/+$/, "")}/rest/v1/master_review_previews` : "";
})();
const MASTER_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function masterConfigured(): boolean {
  return Boolean(MASTER_TABLE_URL && MASTER_SERVICE_KEY);
}

function masterHeaders(): Record<string, string> {
  return {
    "apikey": MASTER_SERVICE_KEY,
    "Authorization": `Bearer ${MASTER_SERVICE_KEY}`,
    "Accept": "application/json",
  };
}

async function masterSelect(query: string): Promise<any[] | null> {
  if (!masterConfigured()) return null;
  const res = await fetch(`${MASTER_TABLE_URL}?${query}`, { headers: masterHeaders() });
  if (!res.ok) {
    // Table absent (sql/199 not applied yet) or transient failure — the
    // caller falls through to the AI path.
    try { await res.body?.cancel(); } catch { /* ignore */ }
    return null;
  }
  const rows = await res.json();
  return Array.isArray(rows) ? rows : null;
}

// fetchApprovedMaster / buildMasterStructuredResponse / searchMaster moved to
// ingestion/master_lookup.ts (injected masterSelect) so the identity rules
// are unit-testable. The rules themselves are unchanged — plus exact-equality
// typography variants ("Spray Seal" ↔ "Sprayseal"), still unique-or-nothing.

/**
 * Live sql/199 catalogue operations for the ingestion orchestrator
 * (ingestion/ingest.ts). Service-role PostgREST; every call is duplicate-safe
 * and fail-open — catalogue writes are side effects, never part of the
 * lookup's success. `updateCandidate` filters on review_status=candidate at
 * the DATABASE, so automation can never touch an approved or retired row
 * even if handed the wrong id.
 */
const masterOps: MasterOps = {
  async selectByIdentityKey(identityKey: string): Promise<MasterRow | null> {
    const rows = await masterSelect(
      `select=*&registration_identity_key=eq.${encodeURIComponent(identityKey)}&limit=1`,
    );
    return rows && rows.length === 1 ? rows[0] as MasterRow : null;
  },
  async insertCandidate(payload): Promise<MasterRow | null> {
    if (!masterConfigured()) return null;
    const res = await fetch(`${MASTER_TABLE_URL}?on_conflict=registration_identity_key`, {
      method: "POST",
      headers: {
        ...masterHeaders(),
        "Content-Type": "application/json",
        "Prefer": "resolution=ignore-duplicates,return=representation",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      try { await res.body?.cancel(); } catch { /* ignore */ }
      return null;
    }
    const rows = await res.json().catch(() => null);
    return Array.isArray(rows) && rows.length ? rows[0] as MasterRow : null;
  },
  async updateCandidate(id: string, patch: Record<string, any>): Promise<boolean> {
    if (!masterConfigured()) return false;
    const res = await fetch(
      `${MASTER_TABLE_URL}?id=eq.${encodeURIComponent(id)}&review_status=eq.candidate`,
      {
        method: "PATCH",
        headers: {
          ...masterHeaders(),
          "Content-Type": "application/json",
          "Prefer": "return=minimal",
        },
        body: JSON.stringify(patch),
      },
    );
    try { await res.body?.cancel(); } catch { /* ignore */ }
    return res.ok;
  },
};

/**
 * Service-role store for master_review_previews (sql/203) — the ONE
 * service-role write in the Stage 2 review flow: INSERT the resolver-built
 * patch, and opportunistically DELETE expired unconsumed rows. There is no
 * UPDATE here and the grants don't allow one — consumption happens only
 * inside the master_review_apply RPC, under the admin's own JWT.
 */
const previewStore: PreviewStore = {
  async insertPreview(payload) {
    if (!REVIEW_PREVIEWS_URL || !MASTER_SERVICE_KEY) return null;
    const res = await fetch(REVIEW_PREVIEWS_URL, {
      method: "POST",
      headers: {
        ...masterHeaders(),
        "Content-Type": "application/json",
        "Prefer": "return=representation",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      try { await res.body?.cancel(); } catch { /* ignore */ }
      return null;
    }
    const rows = await res.json().catch(() => null);
    return Array.isArray(rows) && rows.length ? rows[0] : null;
  },
  async purgeExpired(nowIso) {
    if (!REVIEW_PREVIEWS_URL || !MASTER_SERVICE_KEY) return;
    try {
      const res = await fetch(
        `${REVIEW_PREVIEWS_URL}?consumed_at=is.null&expires_at=lt.${
          encodeURIComponent(nowIso)
        }`,
        {
          method: "DELETE",
          headers: { ...masterHeaders(), "Prefer": "return=minimal" },
        },
      );
      try { await res.body?.cancel(); } catch { /* ignore */ }
    } catch {
      /* fail-soft: purge is housekeeping, never blocks a preview */
    }
  },
};

/**
 * System-admin gate shared by master_refresh and seed_apply: the caller's own
 * JWT is presented to the database's is_system_admin() RPC. Anything short of
 * an explicit true — missing header, RPC failure, non-admin — is NOT an admin.
 */
async function isSystemAdmin(req: Request): Promise<boolean> {
  const authHeader = req.headers.get("Authorization") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabaseUrl = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  if (!authHeader || !anonKey || !supabaseUrl) return false;
  try {
    const adminRes = await fetch(`${supabaseUrl}/rest/v1/rpc/is_system_admin`, {
      method: "POST",
      headers: {
        "apikey": anonKey,
        "Authorization": authHeader,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    if (adminRes.ok) return (await adminRes.json()) === true;
    try { await adminRes.body?.cancel(); } catch { /* ignore */ }
    return false;
  } catch {
    return false;
  }
}

/**
 * Resolve the CALLER's auth user id from their own JWT via the Auth server
 * (which verifies the token — never decoded locally, never read from the
 * request body). Binds a stored review preview to the requesting admin;
 * sql/203 master_review_apply refuses every other caller.
 */
async function authenticatedUserId(req: Request): Promise<string | null> {
  const authHeader = req.headers.get("Authorization") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabaseUrl = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  if (!authHeader || !anonKey || !supabaseUrl) return null;
  try {
    const res = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { "apikey": anonKey, "Authorization": authHeader },
    });
    if (!res.ok) {
      try { await res.body?.cancel(); } catch { /* ignore */ }
      return null;
    }
    const user: any = await res.json().catch(() => null);
    return typeof user?.id === "string" && user.id ? user.id : null;
  } catch {
    return null;
  }
}

function extractJSON(text: string): any {
  let cleaned = text
    .replace(/```json/gi, "")
    .replace(/```/g, "")
    .trim();
  const firstBrace = cleaned.indexOf("{");
  const lastBrace = cleaned.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    cleaned = cleaned.slice(firstBrace, lastBrace + 1);
  }
  return JSON.parse(cleaned);
}

function normalizeSearchResults(parsed: any): any {
  const arr = Array.isArray(parsed?.results)
    ? parsed.results
    : Array.isArray(parsed)
    ? parsed
    : [];
  const results = arr
    .map((item: any) => {
      const name = String(item?.name ?? "").trim();
      if (!name) return null;
      return {
        name,
        activeIngredient: String(
          item?.activeIngredient ?? item?.active_ingredient ?? "",
        ),
        chemicalGroup: String(
          item?.chemicalGroup ?? item?.chemical_group ?? "",
        ),
        brand: String(item?.brand ?? item?.manufacturer ?? ""),
        primaryUse: String(item?.primaryUse ?? item?.primary_use ?? ""),
        modeOfAction: String(item?.modeOfAction ?? item?.mode_of_action ?? ""),
      };
    })
    .filter((x: any) => x);
  return { results };
}

function parseRateInfoArray(value: any): { label: string; value: number }[] {
  if (!Array.isArray(value)) return [];
  const out: { label: string; value: number }[] = [];
  for (const item of value) {
    const label = item?.label;
    if (typeof label !== "string") continue;
    let v: number | null = null;
    if (typeof item?.value === "number" && isFinite(item.value)) v = item.value;
    else if (typeof item?.value === "string") {
      const n = Number(item.value);
      if (isFinite(n)) v = n;
    }
    if (v == null) continue;
    out.push({ label, value: v });
  }
  return out;
}

function isPlaceholderURL(url: string): boolean {
  if (!url) return true;
  let host = "";
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return true;
  }
  const bad = [
    "example.com",
    "example.org",
    "example.net",
    "placeholder.com",
    "yourdomain.com",
    "domain.com",
    "manufacturer.com",
    "website.com",
    "company.com",
    "test.com",
    "localhost",
  ];
  return bad.some((b) => host === b || host.endsWith("." + b));
}

/**
 * Probe a URL with a short timeout. Returns true only when the server responds
 * with a successful (2xx) status. Tries HEAD first, falls back to a ranged GET
 * (some CDNs / WordPress hosts return 405 for HEAD on PDF uploads).
 */
async function isURLReachable(rawURL: string): Promise<boolean> {
  let target: URL;
  try {
    target = new URL(rawURL);
  } catch {
    return false;
  }
  if (target.protocol !== "https:" && target.protocol !== "http:") return false;

  const attempt = async (method: "HEAD" | "GET"): Promise<number | null> => {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 6000);
    try {
      const headers: Record<string, string> = {
        "User-Agent":
          "Mozilla/5.0 (compatible; VineTrack-ChemicalLookup/1.0; +https://rork.app)",
        "Accept": "*/*",
      };
      if (method === "GET") headers["Range"] = "bytes=0-0";
      const res = await fetch(target.toString(), {
        method,
        redirect: "follow",
        headers,
        signal: ctrl.signal,
      });
      // Drain body if any so the connection can be reused/closed.
      try { await res.body?.cancel(); } catch { /* ignore */ }
      return res.status;
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  };

  const headStatus = await attempt("HEAD");
  if (headStatus !== null && headStatus >= 200 && headStatus < 300) return true;
  // Some servers reject HEAD with 4xx but serve GET correctly.
  if (headStatus === null || headStatus === 403 || headStatus === 404 || headStatus === 405 || headStatus === 501) {
    const getStatus = await attempt("GET");
    if (getStatus !== null && getStatus >= 200 && getStatus < 300) return true;
  }
  return false;
}

/**
 * Reject obvious non-label URLs even when they're reachable, e.g. brand
 * homepages or generic product search pages that the AI sometimes substitutes
 * when it doesn't know the real PDF.
 */
function looksLikeLabelURL(rawURL: string): boolean {
  let u: URL;
  try {
    u = new URL(rawURL);
  } catch {
    return false;
  }
  const path = u.pathname.toLowerCase();
  // Bare homepage / brand root is never a label.
  if (path === "" || path === "/") return false;
  // Generic search/category pages.
  if (/\/(search|category|categories|tag|tags)\b/.test(path)) return false;
  return true;
}

async function normalizeInfo(parsed: any): Promise<any> {
  const activeIngredient = String(
    parsed?.activeIngredient ?? parsed?.active_ingredient ?? "",
  );
  const brand = String(parsed?.brand ?? parsed?.manufacturer ?? "");
  const chemicalGroup = String(
    parsed?.chemicalGroup ?? parsed?.chemical_group ?? "",
  );
  const rawLabelURL = String(
    parsed?.labelURL ?? parsed?.label_url ?? parsed?.labelUrl ?? "",
  ).trim();
  const rawProductURL = String(
    parsed?.productURL ?? parsed?.product_url ?? parsed?.productUrl ?? "",
  ).trim();
  const rawSDSURL = String(
    parsed?.sdsURL ?? parsed?.sds_url ?? parsed?.sdsUrl ?? "",
  ).trim();

  /**
   * Validate a candidate URL: reject placeholders, reject brand homepages,
   * then verify the URL is actually reachable. Hallucinated URLs are dropped.
   */
  const validate = async (raw: string, requireLabelShape: boolean): Promise<string> => {
    if (!raw) return "";
    if (isPlaceholderURL(raw)) return "";
    if (requireLabelShape && !looksLikeLabelURL(raw)) return "";
    const ok = await isURLReachable(raw);
    return ok ? raw : "";
  };

  // Validate in parallel.
  const [labelURL, productURL, sdsURL] = await Promise.all([
    validate(rawLabelURL, true),
    validate(rawProductURL, false),
    validate(rawSDSURL, true),
  ]);

  const primaryUse = String(parsed?.primaryUse ?? parsed?.primary_use ?? "");
  const formType = parsed?.formType ?? parsed?.form_type ?? null;
  const modeOfAction = parsed?.modeOfAction ?? parsed?.mode_of_action ?? null;
  const ratesPerHectare = parseRateInfoArray(
    parsed?.ratesPerHectare ?? parsed?.rates_per_hectare,
  );
  const ratesPer100L = parseRateInfoArray(
    parsed?.ratesPer100L ?? parsed?.rates_per_100l ?? parsed?.ratesPer100l,
  );
  return {
    activeIngredient,
    brand,
    chemicalGroup,
    labelURL,
    productURL,
    sdsURL,
    primaryUse,
    formType: typeof formType === "string" ? formType : null,
    modeOfAction: typeof modeOfAction === "string" ? modeOfAction : null,
    ratesPerHectare,
    ratesPer100L,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
  if (!apiKey) {
    return json(
      { error: "Server is missing OPENAI_API_KEY secret" },
      500,
    );
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const action = String(body?.action ?? "").toLowerCase();

  // Task §14 production diagnostics.
  //
  // Built from decisions the pipeline has ALREADY made. Nothing downstream
  // may read these values back to influence ranking, selection or
  // extraction — a diagnostic that changes the answer is not a diagnostic.
  const requestId = newRequestId();
  const clientCtx: LookupClientContext = readClientContext(body);
  const requestStartedAt = Date.now();
  const requestedCountryRaw = typeof body?.country === "string" ? body.country : "";
  // Fail-soft stages are invisible by design; this is where a register
  // timeout or a research outage becomes visible to a parity investigation.
  const degradedStages: string[] = [];

  /**
   * Per-stage stopwatch (Stage C §H).
   *
   * A total duration cannot distinguish a slow register from a slow model from
   * a slow registrant website, so every latency investigation used to begin by
   * guessing which stage to instrument next. It also cannot answer the
   * question Stage C exists to settle: whether a SEARCH entered a stage only a
   * structured lookup should reach.
   */
  const timer = new LookupTimer();

  /** Assemble + emit the envelope, and attach it to the response body. */
  const withDiagnostics = <T extends Record<string, unknown>>(
    payload: T,
    d: {
      query: string;
      candidates?: CandidateDiagnostic[];
      selectedRegistration?: string | null;
      method: LookupMethod;
      cache?: LookupCacheState;
    },
  ): T & { diagnostics: unknown } => {
    const diagnostics = buildDiagnostics({
      requestId,
      client: clientCtx,
      action,
      requestedCountry: requestedCountryRaw,
      resolvedCountryCode: countryCode || null,
      query: d.query,
      candidates: d.candidates,
      selectedRegistration: d.selectedRegistration ?? null,
      method: d.method,
      cache: d.cache,
      startedAt: requestStartedAt,
      degraded: degradedStages,
    });
    const timings = timer.snapshot();
    // The boundary guarantee, as DATA rather than something a reader has to
    // re-derive from the call graph. Empty is the contract for a search.
    const trespass = action === "search" ? structuredOnlyStagesEntered(timer) : [];
    if (trespass.length) {
      degradedStages.push("search_entered_enrichment_stage");
      console.error(JSON.stringify({
        evt: "search_stage_boundary_violation",
        stages: trespass,
      }));
    }
    const envelope = {
      ...diagnostics,
      timings: timings.stages,
      duration_ms: timings.total_ms,
      structured_only_stages_entered: trespass,
    };
    console.log(diagnosticsLog(envelope as typeof diagnostics));
    return { ...payload, diagnostics: envelope };
  };

  // Lookup jurisdiction — resolved ONCE, from the request's country value
  // (the vineyard's country, sent verbatim by the apps/portal), through the
  // vineyard-country contract table. Every response carries the resulting
  // envelope so clients render lookup jurisdiction AND registration country
  // from ONE resolved value. No locale/default fallback: unrecognised or
  // missing stays exactly that.
  const jur = resolveLookupCountry(
    typeof body?.country === "string" ? body.country : "",
  );
  const jurEnv = jurisdictionEnvelope(jur);
  const countryCode = jur.code ?? "";
  const countryLabel = jur.displayName ?? jur.raw;

  try {
    if (action === "search") {
      const query = typeof body?.query === "string" ? body.query.trim() : "";
      if (!query) return json({ error: "Missing query" }, 400);
      if (query.length > 200) {
        return json({ error: "Query too long" }, 400);
      }
      // Lookup order: 1) approved master catalogue, 2) the jurisdiction's
      // official register, 3) AI suggestions. Authoritative hits lead the
      // list; the AI still runs so unknown/unregistrable products keep
      // surfacing — and if the AI provider fails, authoritative hits alone
      // are a valid answer.
      const masterHits = masterConfigured()
        ? await searchMaster(masterSelect, query, countryCode)
        : [];

      // Register CANDIDATE discovery — discovery is separate from
      // verification. A partial name ("Dithane rainshield"), a loosely
      // spaced or differently cased name, or a bare registration number all
      // surface the register rows the operator might mean — SEVERAL when
      // the name is ambiguous, never a silent pick. Candidates carry
      // identity and display fields only; selecting one runs the strict
      // resolver on that exact identity (verbatim name + registration
      // number), which is the only place authority is established.
      // Fail-soft: a register hiccup can never break search.
      let registerCandidates: any[] = [];
      if (jurEnv.register_support === "supported" && query.length >= 3) {
        try {
          const candidates = await discoverRegisterCandidates(
            countryCode,
            query,
            { fetchFn: fetch, now: () => new Date() },
          );
          // # Dedupe by IDENTITY, never by fuzzy name
          //
          // The old filter dropped a register row whose NAME matched a master
          // row's name. Two different registrations can share one verbatim
          // registered name -- pack sizes, re-registrations, two companies
          // holding similar names -- so a name collision silently deleted a
          // DIFFERENT registered product from the operator's choices, and the
          // one it kept was whichever the catalogue happened to hold.
          //
          // Country + scheme + number is the only thing that means "the same
          // registered product". Rows with no identity on either side are
          // kept: an un-deduplicated duplicate is a cosmetic flaw, a
          // suppressed registration is a wrong answer.
          const identityOf = (row: any): string | null => {
            const country = String(row?.registration_country ?? "").trim().toUpperCase();
            const scheme = String(row?.registration_scheme ?? "").trim().toLowerCase();
            const number = String(row?.registration_number ?? "").trim().toUpperCase();
            return country && scheme && number ? `${country}:${scheme}:${number}` : null;
          };
          const masterIdentities = new Set(
            masterHits.map(identityOf).filter((k): k is string => k !== null),
          );
          const scheme = registrationSchemeForCode(jur.code);
          registerCandidates = candidates
            .map((c) => ({
              name: c.registered_product_name,
              activeIngredient: c.actives_summary,
              chemicalGroup: c.activity_groups.join(" + "),
              brand: c.registrant ?? "",
              primaryUse: "",
              modeOfAction: c.activity_groups.join(" + "),
              source: "official_register",
              // EXACT identity, complete. A candidate that cannot say WHICH
              // registration it is cannot be selected without re-running
              // name matching, which is the defect this repair exists to end.
              registration_country: countryCode,
              registration_scheme: scheme,
              registration_number: c.registration_number,
              registrant: c.registrant ?? null,
              product_category: c.product_category ?? null,
              // The register listing carries no use table, so grapevine
              // relevance is genuinely UNKNOWN here -- which is not the same
              // as false, and is sent as null so a picker can say so.
              has_grapevine_use: null,
            }))
            .filter((c) => {
              const key = identityOf(c);
              return key === null || !masterIdentities.has(key);
            });
        } catch (err) {
          // Fail-soft, and now VISIBLE. A register hiccup on one platform and
          // not another is a leading explanation for a parity split, and it
          // used to leave no trace in the response at all.
          degradedStages.push("register_discovery_failed");
          console.error(
            "register candidate search skipped:",
            err instanceof Error ? err.message : String(err),
          );
        }
      }

      const authoritative = [...masterHits, ...registerCandidates];

      /** The method label for an answer carried by the deterministic tiers. */
      const deterministicMethod = (): LookupMethod => {
        if (masterHits.length) return "master_catalogue";
        if (registerCandidates.length) return "official_register";
        return "unresolved";
      };

      /**
       * The ONE way the search action may answer (task §1, §2).
       *
       * Ranking happens HERE, at the single exit, rather than at each of the
       * five return sites — a path that forgot to rank would serve raw
       * register order to one platform and ranked order to another, which is
       * precisely the divergence this whole task exists to remove. The
       * diagnostics are built from the RANKED rows, so the recorded candidate
       * order is always the order the client actually received.
       */
      const servedSearch = (
        rows: any[],
        method: LookupMethod,
        cache: LookupCacheState = "none",
      ) => {
        const ranked = rankCandidates(rows ?? [], query, countryCode);
        return json(withDiagnostics(
          {
            results: ranked.results,
            ranking: ranked.summary,
            jurisdiction: jurEnv,
          },
          {
            query,
            candidates: candidatesFromSearchResults(ranked.results),
            method,
            cache,
          },
        ));
      };

      // ---- Stage 2: research suggestions are stabilised and validated -----
      //
      // Reached ONLY when the register found nothing. Everything below is
      // about a query the register could not answer.

      /**
       * Read ONE exact registration from the official register (Stage 2 §5).
       *
       * Reuses the adapter's digit-query path, so a research-suggested number
       * is confirmed by the same code that serves a user typing that number
       * into search. Returns null when the register does not hold it — at
       * which point the number is stripped rather than served.
       */
      const lookupRegistrationNumber = async (number: string) => {
        if (jurEnv.register_support !== "supported") return null;
        if (!/^\d{3,8}$/.test(number)) return null;
        const rows = await discoverRegisterCandidates(
          countryCode,
          number,
          { fetchFn: fetch, now: () => new Date() },
          2,
        );
        return rows.find((r) => r.registration_number === number) ?? null;
      };

      const suggestionStore = createPostgrestSuggestionStore(
        Deno.env.get("SUPABASE_URL") ?? "",
        MASTER_SERVICE_KEY,
        fetch,
      );
      const suggestionKey = suggestionCacheKey(countryCode, query);

      // WEB RESEARCH IS NOT FREE (task §24), and it is not FAST either.
      //
      // # Why an authoritative hit now ends the request
      //
      // The gate used to be `authoritative.length < 3`, which meant a query
      // answered by exactly one official-register row still went on to spend
      // up to RESEARCH_CANDIDATE_TIMEOUT_MS (30 s, plus one retry) looking for
      // more. The iOS search timeout is 30 s in total, so those requests could
      // not finish: the client gave up, cleared its rows, and reported "no
      // products found" for a product the register had already returned in
      // under a second.
      //
      // "CHATEAU HERBICIDE" (APVMA 80647) is exactly that shape — one exact
      // register match, niche enough that research burns its whole budget. The
      // register was never the problem; waiting for a second opinion about an
      // answer we already had was.
      //
      // So research is now the fallback it was meant to be: it runs when the
      // deterministic tiers found NOTHING, or when the client explicitly asks
      // to broaden. A register hit is a complete answer and is returned
      // immediately.
      const researchConfig = readResearchConfig();
      const wantsBroaderResults = body?.broaden === true;

      // # The gate is now the RANKING verdict, not a row count
      //
      // The old gate treated the mere EXISTENCE of one deterministic row as
      // certainty about which product the operator meant. Those are different
      // questions, and Hortitrol winter oil is the case that proves it: a
      // contaminated alias put ONE master row (50067) in front of a query
      // whose words appear nowhere in that product's registered name. The row
      // count said answered; the ranking said no_official_match. The count
      // won, discovery stopped, and the only product the operator could be
      // shown was the wrong one.
      //
      // So the question asked here is the one that matters: is this candidate
      // set SAFE TO AUTO-SELECT? Only search_state exact says yes, and only a
      // register- or catalogue-backed row can produce it. Anything weaker --
      // incidental, fuzzy, partial, or plural -- keeps discovering, because
      // the operator is going to have to choose and deserves the real field
      // to choose from.
      //
      // Ranked HERE over the deterministic rows alone. servedSearch ranks
      // again over whatever is finally served (research included); this pass
      // answers the narrower question -- is what we already hold sufficient
      // -- and must not see research rows, or a model suggestion could talk
      // the server out of looking for a better one.
      const discovery = discoveryDecision({
        authoritative,
        query,
        countryCode,
        broaden: wantsBroaderResults,
        researchEnabled: researchConfig.enabled,
      });
      const shouldResearch = discovery.research;
      console.log(JSON.stringify({
        evt: "search_discovery_gate",
        query_length: query.length,
        authoritative_rows: authoritative.length,
        search_state: discovery.summary.search_state,
        auto_select_allowed: discovery.summary.auto_select_allowed,
        research: discovery.research,
        reason: discovery.reason,
      }));

      if (!shouldResearch && authoritative.length) {
        return servedSearch(authoritative, deterministicMethod());
      }

      // # Cross-isolate stability (Stage 2 §4)
      //
      // The per-isolate `SourceCache` cannot deliver parity: Portal and iOS
      // land on different isolates, so each ran its OWN research pass and each
      // got its own answer — which is how one query reached 33182 on one
      // platform and 50067 on the other. This shared read makes the same
      // country + normalised query return the same suggestion set for the
      // cache lifetime, whichever isolate serves it.
      //
      // Only for the register-found-nothing case. A register answer is already
      // deterministic and must never be served from a suggestion cache.
      if (shouldResearch && suggestionStore && authoritative.length === 0) {
        const cached = await suggestionStore.read(suggestionKey);
        if (cached?.length) {
          return servedSearch(cached, "research", "hit");
        }
      }

      if (shouldResearch) {
        // Fail-soft, like every other stage of search. An exception escaping
        // here reached the outer handler as a 502, so a research provider
        // outage destroyed the register candidates sitting in `authoritative`
        // — the one part of the answer that was already correct.
        let outcome = null;
        try {
          outcome = await runChemicalResearch({
            query,
            countryCode,
            countryLabel,
            mode: "candidate_discovery",
            apiKey,
            fetchFn: fetch,
            config: researchConfig,
            registerResolved: registerCandidates.length > 0,
          });
          console.log(researchLog(outcome.telemetry));
        } catch (err) {
          degradedStages.push("candidate_research_failed");
          console.warn(
            "candidate research failed:",
            err instanceof Error ? err.message : String(err),
          );
        }

        if (outcome?.research) {
          const seen = new Set(
            authoritative.map((m: any) => String(m.name).toLowerCase()),
          );
          const researched = projectResearchToSearchResults(
            outcome.research,
            countryCode,
            registrationSchemeForCode(jur.code),
          )
            .filter((r) => !seen.has(String(r?.name ?? "").toLowerCase()));

          // # Nothing model-generated becomes canonical unvalidated (§5)
          //
          // Every suggested registration number is read back from the
          // register. Confirmed → the row is rebuilt from the REGISTER's name,
          // number and registrant. Not confirmed → the number is stripped, so
          // a downstream structured lookup can never be handed a pointer to a
          // registration that may not exist.
          const validated = await validateResearchSuggestions(
            [...authoritative, ...researched],
            { countryCode, lookup: lookupRegistrationNumber },
          );
          degradedStages.push(...validated.degraded);

          // Cache the SERVED rows, so the next isolate answers identically.
          if (suggestionStore && authoritative.length === 0) {
            await suggestionStore.write(
              suggestionKey,
              countryCode,
              query,
              validated.rows,
              SUGGESTION_CACHE_TTL_SECONDS,
            );
          }

          return servedSearch(
            validated.rows,
            authoritative.length ? "official_register_and_research" : "research",
            suggestionStore && authoritative.length === 0 ? "miss" : "none",
          );
        }
        // Research failed. Authoritative hits alone are a complete answer;
        // only fall through to the legacy model when there is nothing else.
        if (authoritative.length) {
          return servedSearch(authoritative, deterministicMethod());
        }
      }

      try {
        const { system, user } = buildSearchPrompt(query, countryLabel);
        const raw = await callOpenAI(system, user, apiKey);
        const parsed = extractJSON(raw);
        const normalized = normalizeSearchResults(parsed);
        if (authoritative.length) {
          const seen = new Set(
            authoritative.map((m: any) => String(m.name).toLowerCase()),
          );
          normalized.results = [
            ...authoritative,
            ...normalized.results.filter(
              (r: any) => !seen.has(String(r?.name ?? "").toLowerCase()),
            ),
          ];
        }
        return servedSearch(
          normalized.results ?? [],
          authoritative.length ? deterministicMethod() : "ai_legacy",
        );
      } catch (err) {
        degradedStages.push("ai_legacy_search_failed");
        if (authoritative.length) {
          return servedSearch(authoritative, deterministicMethod());
        }
        throw err;
      }
    }

    if (action === "structured") {
      const productName = typeof body?.productName === "string"
        ? body.productName.trim()
        : "";
      if (!productName) return json({ error: "Missing productName" }, 400);
      if (productName.length > 200) {
        return json({ error: "productName too long" }, 400);
      }

      const startedAt = Date.now();
      const deps = { fetchFn: fetch, now: () => new Date() };

      /**
       * Stage B observability: every transition between a locked registration
       * and served grapevine rates.
       *
       * Observation only. Nothing reads these values back to make a decision --
       * a diagnostic that changes the answer stops being a diagnostic. It
       * carries no document contents and no secrets: URLs, counts, outcomes
       * and a hash.
       */
      const stageB: Record<string, unknown> = {
        exact_registration: null,
        master_incomplete: false,
        enrichment_query_name: null,
        product_enrichment_ran: false,
        manufacturer_product_candidates: [],
        selected_manufacturer_product: null,
        manufacturer_label_candidates: [],
        selected_manufacturer_label: null,
        // Which candidates actually SPENT the two-attempt fetch budget.
        //
        // `manufacturer_product_candidates` lists only pages that were read
        // successfully, so a lead that was starved out of the budget — or
        // fetched and refused — left no trace on the wire at all, and the only
        // record was a platform console line. That made "was the page even
        // requested?" unanswerable from a response, which is precisely the
        // question the last investigation could not close.
        //
        // Diagnostic only, and only values `inspectCandidateProductPages`
        // already produced: url, outcome, reason, linkCount. No document
        // contents, no HTML, no secrets. Nothing reads it back.
        product_page_inspection_attempts: [],
        manufacturer_label_fetch: "skipped",
        manufacturer_label_extract: "skipped",
        grapevine_rows_found: 0,
        grapevine_rates_found: 0,
        practical_source: "none",
      };
      /** The inspected page a manufacturer label was accepted FROM. */
      let manufacturerSourcePage: string | null = null;

      // 1) Approved master catalogue (sql/199), name/alias path. A COMPLETE
      //    hit short-circuits everything: the AI is never called and the
      //    ingestion adapter is never invoked for a known approved product.
      //
      //    An INCOMPLETE hit no longer stops the lookup. See
      //    `masterHasCompleteVineyardData` for why an approved row can still
      //    be missing the one number a vineyard opened the app to find.
      let registrationNumber = typeof body?.registrationNumber === "string"
        ? body.registrationNumber.trim()
        : "";

      /**
       * An approved catalogue row that was found but is NOT complete enough
       * to answer with.
       *
       * Held for two reasons: its registration pins the enrichment that
       * follows, and if every enrichment path then fails it is still served
       * rather than lost. Incomplete data beats no data -- what it must not
       * do is prevent better data from being fetched.
       */
      let incompleteMaster: any = null;

      /**
       * The registration the OPERATOR selected, once and for all.
       *
       * Null when the caller sent no number — an unselected, name-only lookup
       * is unchanged and unlocked, because no human decision exists to hold.
       */
      const selectedRegistration = readSelectedRegistration(body, countryCode);

      /**
       * The ONE way the structured action may answer.
       *
       * Every exit passes through the identity lock. Written as a single gate
       * rather than a check at each of the five return sites for the same
       * reason `servedSearch` exists: a path that forgot the check would be
       * indistinguishable from a path that passed it, and the failure it lets
       * through is a silent product substitution.
       */
      const servedStructured = (
        payload: any,
        diag: {
          selectedRegistration: string | null;
          method: LookupMethod;
          cache: LookupCacheState;
        },
      ) => {
        const violation = registrationViolation(selectedRegistration, payload);
        if (violation && selectedRegistration) {
          // Refuse, name the registration, and say so loudly in the logs.
          // This branch firing in production means some stage resolved on the
          // typed phrase after a selection had been made — a defect worth
          // finding, not worth absorbing.
          console.error(JSON.stringify({
            evt: "identity_lock_violation",
            selected: selectedRegistration.number,
            detail: violation,
            method: diag.method,
          }));
          degradedStages.push("selected_registration_not_served");
          return json(withDiagnostics(
            {
              ...unresolvedForSelection(selectedRegistration, violation),
              jurisdiction: jurEnv,
            },
            {
              query: productName,
              selectedRegistration: selectedRegistration.number,
              method: "unresolved",
              cache: "none",
            },
          ));
        }
        // Gate D4A — the ONE place canonical default-rate options are produced.
        //
        // Every structured answer leaves through here: the AI+register path,
        // both master-catalogue short-circuits, the enrichment-cache path and
        // the unresolved path. Deriving at this boundary rather than inside
        // any one of them means a row cached or approved before this gate
        // existed still gets current options, and no cache format quietly
        // becomes a second contract of its own.
        //
        // WHY THE ROWS SEEN HERE ALREADY CARRY IDENTITIES (Gate D4A.2)
        //
        // This is NOT "after identity minting by construction". There are two
        // kinds of exit and they earn their identities differently:
        //
        //   * Resolved paths (register / research / AI+register): mint FIRST.
        //     `applyRateIdentities` runs at the product lock point below and
        //     the rows arrive here already stamped.
        //
        //   * Master fast paths: bypass the lock point entirely — a stored row
        //     is served verbatim and NOTHING here mints for it. They are only
        //     allowed to bypass it because `masterHasCompleteVineyardData`
        //     has already proven every eligible grapevine rate on that row
        //     carries a final persisted `rate_v1_` identity. That readiness
        //     check is the load-bearing part: remove it and pre-D1 approved
        //     rows short-circuit straight to this line with no identities, and
        //     this function will NOT repair them — it cannot, because the
        //     printed-direction grouping needed to mint correctly is not in a
        //     stored post-fan-out projection.
        //
        // So a violation logged below from a master path means the readiness
        // gate was weakened, not that minting was merely late.
        //
        // Fail-soft: options are a convenience derived from label evidence
        // that is already in the payload, so a fault here must never cost the
        // operator the chemical itself.
        try {
          const optionViolations = applyDefaultRateOptions(payload);
          if (optionViolations.length) {
            // A calculable label rate that reached the boundary without a
            // stable identity means an upstream invariant slipped. Worth
            // seeing, never worth fabricating an id over.
            degradedStages.push("default_rate_option_identity_missing");
            console.error(JSON.stringify({
              evt: "default_rate_option_invariant",
              query: productName,
              violations: optionViolations.slice(0, 10),
            }));
          }
        } catch (err) {
          degradedStages.push("default_rate_options_failed");
          console.error(
            "default rate options skipped:",
            err instanceof Error ? err.message : String(err),
          );
        }
        return json(withDiagnostics(payload, { query: productName, ...diag }));
      };

      try {
        const masterRow = await fetchApprovedMaster(
          masterSelect,
          productName,
          countryCode,
          registrationNumber,
          registrationSchemeForCode(jur.code),
        );
        if (masterRow && !masterHasCompleteVineyardData(masterRow)) {
          // Keep the IDENTITY, drop the short-circuit.
          //
          // This is the difference between a cache and a barrier. The row
          // knows which registration it is; that fact is now pinned for every
          // stage below, so enrichment runs against the EXACT registration
          // rather than re-deriving identity from the operator's typed words.
          // No fuzzy discovery restarts here -- that is the whole point.
          incompleteMaster = masterRow;
          const rowNumber = String(masterRow.registration_number ?? "").trim();
          if (!registrationNumber && rowNumber) registrationNumber = rowNumber;
          stageB.master_incomplete = true;
          stageB.exact_registration = rowNumber || registrationNumber || null;
          degradedStages.push("master_incomplete_enrichment_attempted");
          console.log(ingestionLog({
            jurisdiction: countryCode,
            adapter: null,
            outcome: "approved_master_incomplete",
            identity: masterRow.registration_identity_key ?? null,
            master: "existing_approved",
            candidate: "none",
            unresolvedCount:
              (masterRow.verification_unresolved_fields ?? []).length,
            conflictCount: 0,
            durationMs: Date.now() - startedAt,
            cache: "none",
          }));
        } else if (masterRow) {
          console.log(ingestionLog({
            jurisdiction: countryCode,
            adapter: null,
            outcome: "approved_master_name_hit",
            identity: masterRow.registration_identity_key ?? null,
            master: "existing_approved",
            candidate: "none",
            unresolvedCount: 0,
            conflictCount: 0,
            durationMs: Date.now() - startedAt,
            cache: "none",
          }));
          return servedStructured(
            { ...buildMasterStructuredResponse(masterRow), jurisdiction: jurEnv },
            {
              selectedRegistration: registrationNumber ||
                (masterRow.registration_number ?? null),
              method: "master_catalogue",
              cache: "hit",
            },
          );
        }
      } catch (err) {
        degradedStages.push("master_name_lookup_failed");
        console.error(
          "master lookup fell through:",
          err instanceof Error ? err.message : String(err),
        );
      }

      // 2) Authoritative discovery (Stage 3): the vineyard's jurisdiction —
      //    and only the source REGISTRY — selects the adapter. Missing
      //    country or unsupported jurisdiction fails closed to the AI path;
      //    a register outage can never break the lookup.
      let discovery = await discoverAuthoritative(
        countryCode,
        productName,
        registrationNumber || null,
        deps,
      );

      // 3) AI extraction (unchanged honesty rules). Fail-open in BOTH
      //    directions: an AI outage cannot hide a register-resolved product,
      //    and a register outage cannot break the AI lookup.
      let structured: any = null;
      let aiError: unknown = null;
      let projection: ResearchProjection | null = null;
      let researchOutcome: ResearchOutcome | null = null;

      const researchConfig = readResearchConfig();

      // The identity enrichment must research.
      //
      // Once the register has resolved the product, the operator's typed words
      // have done their job. Enrichment asks "where is THIS product's current
      // label?", and asking it with the discovery text means hunting
      // manufacturer assets under a name the product does not have -- no
      // registrant hosts a page for "Hortitrol Winter Oil", so the search
      // cannot succeed on its own terms, and any page it did return would be
      // about something else. The typed text survives as provenance below.
      const lockedIdentity = discovery.outcome === "resolved" && discovery.registration
        ? {
          registeredProductName: discovery.registration.registered_product_name,
          registrationNumber: discovery.registration.registration_number,
          scheme: discovery.registration.scheme,
          registrant: discovery.registration.registrant,
        }
        : null;
      if (lockedIdentity) {
        stageB.exact_registration = lockedIdentity.registrationNumber;
        stageB.enrichment_query_name = lockedIdentity.registeredProductName;
      }

      if (researchConfig.enabled) {
        // Live web research. Never throws: a provider outage returns a null
        // result and the register path below carries the lookup alone.
        researchOutcome = await runChemicalResearch({
          // Provenance only when an identity is locked -- the prompt builder
          // leads with the registered name and demotes this to context.
          query: productName,
          countryCode,
          countryLabel,
          mode: "product_enrichment",
          apiKey,
          fetchFn: fetch,
          config: researchConfig,
          registerResolved: discovery.outcome === "resolved",
          labelMissingForResolvedRegistration: discovery.outcome === "resolved" &&
            !discovery.registration?.label_document?.url,
          lockedIdentity,
        });
        stageB.product_enrichment_ran = true;
        console.log(researchLog(researchOutcome.telemetry));

        if (researchOutcome.research) {
          // Manufacturer enrichment runs ONLY behind register-resolved
          // identity. The register names the product; without that name there
          // is nothing to check a manufacturer's page against, and a page
          // about a different product must never confer label status.
          const registeredName = discovery.outcome === "resolved"
            ? (discovery.registration?.registered_product_name ?? null)
            : null;

          // Deterministic evidence layer: the server reads the registrant's
          // own product page rather than trusting the model's account of what
          // it linked. Model relationship metadata survives only as a lead
          // that helps choose which page is worth fetching.
          let inspectedPages: InspectedProductPage[] = [];
          if (registeredName) {
            const research = researchOutcome.research;
            const leads = [
              ...research.documents.product_page_candidates.map((d) => d.url),
              ...[
                ...research.documents.official_label_candidates,
                ...research.documents.product_page_candidates,
                ...research.documents.sds_candidates,
              ]
                .map((d) => (d.linked_from_url ?? "").trim())
                .filter((u) => u.length > 0),
            ];
            const inspection = await inspectCandidateProductPages(
              { fetchFn: fetch, now: () => new Date() },
              leads,
              countryCode,
            );
            inspectedPages = inspection.pages;
            // The same attempt trail the log line carries, now also on the
            // wire so a live response can prove which branch ran.
            stageB.product_page_inspection_attempts = inspection.attempts.map((a) => ({
              url: a.url,
              outcome: a.outcome,
              reason: a.reason,
              link_count: a.linkCount,
            }));
            // Why a manufacturer label was or was not promoted, in the logs,
            // without loosening a rule to find out.
            console.log(JSON.stringify({
              evt: "product_page_inspection",
              registered_product_name: registeredName,
              attempts: inspection.attempts,
            }));
          }

          projection = projectResearch(
            researchOutcome.research,
            countryCode,
            registrationSchemeForCode(jur.code),
            registeredName,
            inspectedPages,
          );
          // Research enters through the EXISTING extraction door, so every
          // downstream authority rule (register merge, unverified-identity
          // discard, group reconciliation, provenance) applies unchanged.
          // The model that actually ran, from the winning attempt's own
          // telemetry — Terra normally, Sol when it escalated.
          const producedBy = researchOutcome.telemetry.attempts
            .filter((a) => a.ok)
            .map((a) => a.model)
            .pop() ?? researchConfig.model;
          structured = buildStructuredResponse(
            projection.extraction,
            countryCode,
            `Web research extraction (${producedBy})`,
          );

          // §11 audit trail: every product-page candidate research offered,
          // with the server's verdict on each. When `product_url` comes back
          // null this line says WHY, in the logs, without loosening a rule.
          console.log(JSON.stringify({
            evt: "research_product_page_audit",
            candidates: researchOutcome.research.documents.product_page_candidates
              .map((d) => {
                const c = projection!.classified.find((x) => x.url === d.url);
                return {
                  url: d.url,
                  domain: c?.domain ?? null,
                  trust: c?.trust ?? null,
                  kind: c?.kind ?? null,
                  accepted: c?.isProductPageCandidate ?? false,
                  reason: c?.reason ?? "not classified (unparseable URL)",
                };
              }),
            chosen: projection.productPageCandidate?.url ?? null,
          }));

          // Stage B diagnostics: what the manufacturer hunt considered.
          stageB.manufacturer_product_candidates = inspectedPages.map((p) => p.finalUrl);
          stageB.selected_manufacturer_product = projection.productPageCandidate?.url ?? null;
          stageB.manufacturer_label_candidates = projection.classified
            .filter((c) => c.isOfficialLabelCandidate && c.trust !== "official_register")
            .map((c) => c.url);
          stageB.selected_manufacturer_label = projection.manufacturerLabelCandidate?.url ?? null;
          // The page a label was accepted FROM -- required for host custody on
          // the fetch below, and never inferred from the label URL alone.
          manufacturerSourcePage = projection.manufacturerLabelCandidate
            ? (inspectedPages.find((p) => {
              try {
                return projection!.manufacturerLabelCandidate!.url.startsWith(
                  new URL(p.finalUrl).origin,
                );
              } catch {
                return false;
              }
            })?.finalUrl ?? null)
            : null;
        } else if (researchOutcome.error) {
          aiError = new Error(
            `Chemical research unavailable (${researchOutcome.error.category}): ${researchOutcome.error.message}`,
          );
        }
      }

      if (!structured && !researchConfig.enabled) {
        // Legacy chat-completions path, retained behind the flag until the
        // Responses path is validated in production (task §44).
        try {
          const { system, user } = buildStructuredPrompt(
            productName,
            countryLabel,
            countryCode,
          );
          const raw = await callOpenAI(system, user, apiKey);
          const parsed = extractJSON(raw);
          structured = buildStructuredResponse(
            parsed,
            countryCode,
            `Model extraction (${OPENAI_MODEL})`,
          );
        } catch (err) {
          aiError = err;
        }
      }

      // 3b) The AI's extracted registration number may LOCATE a register row
      //     the name search missed. It is only ever a pointer: the adapter
      //     re-verifies number AND name against the register before anything
      //     binds (AI assists discovery, never becomes authority).
      if (
        (discovery.outcome === "unresolved" || discovery.outcome === "ambiguous") &&
        structured
      ) {
        // Research may have surfaced SEVERAL plausible numbers. Each is only
        // a pointer: the adapter re-verifies number AND name before anything
        // binds, so trying the best two costs at most one extra register
        // call and can never bind the wrong identity. Bounded deliberately —
        // this is a hint list, not a brute-force search.
        //
        // A lead is a NUMBER **and** the register name it was discovered
        // with, kept paired (research/authority.ts). Verifying 59688 against
        // the operator's shorthand "Dithane Rainshield" fails on a register
        // row named "Dithane Rainshield Neo Tec Fungicide" — correctly, since
        // NEO/TEC are meaningful tokens — so the paired register name is what
        // gets verified. The adapter still independently confirms that the
        // number exists AND that its name corresponds; research has granted
        // nothing.
        const attempts = buildResolverAttempts(
          projection?.resolverHints ?? [],
          productName,
          structured?.registration?.registration_number ?? null,
        );

        for (const attempt of attempts) {
          discovery = await discoverAuthoritative(
            countryCode,
            attempt.name,
            attempt.number,
            deps,
          );
          console.log(JSON.stringify({
            evt: "research_hint_reresolution",
            registration_number: attempt.number,
            verification_name: attempt.name,
            name_source: attempt.source,
            outcome: discovery.outcome,
          }));
          if (discovery.outcome === "resolved") break;
        }
      }

      const resolved = discovery.outcome === "resolved" && discovery.registration
        ? discovery.registration
        : null;

      // 4) A discovery-resolved identity may already be an APPROVED master
      //    the name path missed (unlisted alias). Serve it — an approved
      //    product never re-enters ingestion.
      //
      //    Same completeness rule as the name path: an approved row that
      //    admits an unresolved GRAPEVINE rate does not get to end a lookup
      //    that has, by this point, already resolved the register identity
      //    and is holding fresh label evidence.
      if (resolved) {
        try {
          const byIdentity = await fetchApprovedMaster(
            masterSelect,
            "",
            countryCode,
            resolved.registration_number,
            resolved.scheme,
          );
          if (byIdentity && !masterHasCompleteVineyardData(byIdentity)) {
            incompleteMaster = incompleteMaster ?? byIdentity;
            stageB.master_incomplete = true;
            if (!degradedStages.includes("master_incomplete_enrichment_attempted")) {
              degradedStages.push("master_incomplete_enrichment_attempted");
            }
            console.log(ingestionLog({
              jurisdiction: countryCode,
              adapter: discovery.adapter,
              outcome: "approved_master_incomplete",
              identity: resolved.registration_identity_key,
              master: "existing_approved",
              candidate: "none",
              unresolvedCount:
                (byIdentity.verification_unresolved_fields ?? []).length,
              conflictCount: 0,
              durationMs: Date.now() - startedAt,
              cache: discovery.cache,
            }));
          } else if (byIdentity) {
            console.log(ingestionLog({
              jurisdiction: countryCode,
              adapter: discovery.adapter,
              outcome: "approved_master_identity_hit",
              identity: resolved.registration_identity_key,
              master: "existing_approved",
              candidate: "none",
              unresolvedCount: 0,
              conflictCount: 0,
              durationMs: Date.now() - startedAt,
              cache: discovery.cache,
            }));
            return servedStructured(
              { ...buildMasterStructuredResponse(byIdentity), jurisdiction: jurEnv },
              {
                selectedRegistration: registrationNumber ||
                  (byIdentity.registration_number ?? null),
                method: "master_catalogue",
                cache: discovery.cache === "hit" ? "hit" : "miss",
              },
            );
          }
        } catch (err) {
          degradedStages.push("master_identity_lookup_failed");
          console.error(
            "identity master lookup fell through:",
            err instanceof Error ? err.message : String(err),
          );
        }
      }

      // 5) Neither the AI nor the register produced anything.
      //
      //    If a catalogue row was set aside as incomplete in (1) or (4), it is
      //    served NOW. Declining to short-circuit on an incomplete row is a
      //    decision to look for better data -- never a decision to discard the
      //    data we had. An enrichment attempt that fails must leave the
      //    operator exactly where they would have been, not worse off.
      if (!structured && !resolved) {
        if (incompleteMaster) {
          degradedStages.push("master_enrichment_unavailable");
          console.log(ingestionLog({
            jurisdiction: countryCode,
            adapter: discovery.adapter,
            outcome: "approved_master_incomplete_served",
            identity: incompleteMaster.registration_identity_key ?? null,
            master: "existing_approved",
            candidate: "none",
            unresolvedCount:
              (incompleteMaster.verification_unresolved_fields ?? []).length,
            conflictCount: 0,
            durationMs: Date.now() - startedAt,
            cache: "hit",
          }));
          return servedStructured(
            {
              ...buildMasterStructuredResponse(incompleteMaster),
              jurisdiction: jurEnv,
            },
            {
              selectedRegistration: registrationNumber ||
                (incompleteMaster.registration_number ?? null),
              method: "master_catalogue",
              cache: "hit",
            },
          );
        }
        throw aiError instanceof Error
          ? aiError
          : new Error(String(aiError ?? "lookup failed"));
      }

      // 6) Merge register evidence over the extraction (the register wins on
      //    register-asserted facts; disagreements become structured
      //    conflicts), or build a register-only result when the AI was
      //    unavailable. Facts no authoritative source provided stay
      //    unresolved — never invented.
      //
      //    When the register was CONSULTED and did NOT verify (unresolved or
      //    ambiguous — not an outage), the lookup FAILS CLOSED: the AI's
      //    registration identity claims are DISCARDED (its number already had
      //    its chance to verify as a pointer in 3b) and then EVERY remaining
      //    AI-derived product fact — chemistry, registrant, category, uses,
      //    rates, WHP — is quarantined into the clearly-non-authoritative
      //    `ai_suggestion` advisory. The canonical fields serve unresolved:
      //    "checked and could not uniquely verify" never looks like facts.
      //    An outage (source_unavailable) or a never-consulted register
      //    (not_supported / no_country) keeps the existing degraded-mode
      //    behaviour — clearly-AI-attributed extraction — because "could not
      //    check" is not "checked and unverified".
      let aiIdentityDiscarded: string | null = null;
      if (resolved) {
        structured = structured
          ? mergeDiscoveryIntoStructured(structured, resolved)
          : buildRegisterOnlyStructured(resolved, ACTIVITY_GROUP_TABLE_VERSION);
      } else if (structured) {
        aiIdentityDiscarded = discardUnverifiedAiIdentity(structured, discovery.outcome);
        quarantineUnverifiedAiFacts(
          structured,
          discovery.outcome,
          jurEnv.resolved_country_name,
        );
      }

      // 6a) THE PRODUCT LOCK POINT — the only place a persistable identity may
      //     be minted (Gate D1.3 §4).
      //
      //     Everything upstream carried its printed-direction grouping as an
      //     internal seed precisely so this mint could happen against the
      //     RESOLVED registration rather than against a research lead. Because
      //     the canonical input is the direction's meaning plus the locked
      //     product, the same registered direction now receives the same
      //     `direction_id` and `rate_id` whichever path discovered it.
      //
      //     When the register never resolved, NOTHING is minted: those rows are
      //     not eligible to become operational defaults, and fabricating a
      //     registration merely so ids could exist is exactly what §6 forbids.
      //     The seeds are stripped either way so an internal aid never escapes.
      if (structured) {
        if (resolved) {
          applyRateIdentities(structured);
        } else {
          stripStructuredDirectionSeeds(structured);
        }
      }

      // 6b) STAGE B — the registrant's CURRENT label supplies the practical
      //     vineyard data.
      //
      //     Deliberately AFTER the register merge. `mergeDiscoveryIntoStructured`
      //     assigns `registered_uses` from the register's own label evidence and
      //     only from that, so enriching earlier would have the merge quietly
      //     discard everything the manufacturer label established -- the exact
      //     "old APVMA extraction overwrites a newer manufacturer rate set"
      //     failure. The register keeps the last word on identity, chemistry,
      //     category and status; the manufacturer's label supplies the rates,
      //     conditions, restrictions and WHP a grower actually sprays by.
      //
      //     Fail-soft throughout: a registrant site that is down, slow, or
      //     serving a scanned label leaves the register result exactly as it
      //     was.
      //
      //     Stage C: the whole block is fronted by a cross-isolate cache keyed
      //     on the EXACT registration. Enrichment is the most expensive thing
      //     this function does -- a research call, a page fetch, a PDF
      //     download and a text extraction -- and until now its result lived
      //     only in the current response, so every operator opening the same
      //     registered chemical paid the full cost again.
      const enrichmentCache = createPostgrestEnrichmentCache(
        Deno.env.get("SUPABASE_URL") ?? "",
        MASTER_SERVICE_KEY,
        fetch,
      );
      const enrichmentKey = resolved
        ? enrichmentCacheKey(countryCode, resolved.scheme, resolved.registration_number)
        : null;

      let servedFromEnrichmentCache = false;
      if (structured && enrichmentCache && enrichmentKey) {
        const cached = await enrichmentCache.read(enrichmentKey);
        if (cachedEnrichmentIsUsable(cached) && cached) {
          // A cached reading of a public document is exactly equivalent to
          // having just fetched it -- it confers no authority of its own, and
          // it never touches identity, which the register has already fixed.
          applyManufacturerEnrichment(
            structured,
            {
              uses: cached.registered_uses,
              source: "manufacturer_label",
              fetchedUrl: cached.manufacturer_label_url,
              withholdingPeriodDays: cached.withholding_period_days,
              diagnostics: {
                manufacturer_label_fetch: "skipped",
                manufacturer_label_fetch_outcome: "skipped",
                manufacturer_label_fetch_reason: "served from the enrichment cache",
                manufacturer_label_extract: "skipped",
                manufacturer_label_bytes: null,
                manufacturer_label_sha256: cached.source_fingerprint,
                label_rows_found: cached.registered_uses.length,
                grapevine_rows_found: 0,
                grapevine_rates_found: 0,
                withholding_period_days: cached.withholding_period_days,
                practical_source: "manufacturer_label",
                practical_source_reason: "cached manufacturer label reading",
              },
            },
            {
              manufacturerLabelUrl: cached.manufacturer_label_url,
              manufacturerProductUrl: cached.manufacturer_product_url,
            },
          );
          servedFromEnrichmentCache = true;
          stageB.enrichment_cache = "hit";
          stageB.manufacturer_label_fetch = "skipped";
          stageB.practical_source = "manufacturer_label";
          stageB.selected_manufacturer_label = cached.manufacturer_label_url;
          stageB.selected_manufacturer_product = cached.manufacturer_product_url;
        } else {
          stageB.enrichment_cache = "miss";
        }
      }

      if (
        structured && !servedFromEnrichmentCache &&
        projection?.manufacturerLabelCandidate
      ) {
        try {
          const enrichment = await timer.time(
            "pdf_download",
            () =>
              enrichFromManufacturerLabel({
                deps,
                manufacturerLabelUrl: projection!.manufacturerLabelCandidate!.url,
                sourcePageUrl: manufacturerSourcePage,
                regulatorUses: Array.isArray(structured.registered_uses)
                  ? structured.registered_uses
                  : [],
                // Identity must be minted inside the projection, while each
                // printed direction still holds its complete target set and
                // before the one-target-per-row fan-out (Gate D1.2).
                product: {
                  country: countryCode,
                  scheme: resolved?.scheme ?? null,
                  registration_number: resolved?.registration_number ?? null,
                },
                registeredProductName: resolved?.registered_product_name ?? null,
              }),
          );
          applyManufacturerEnrichment(structured, enrichment, {
            manufacturerLabelUrl: projection.manufacturerLabelCandidate.url,
            manufacturerProductUrl: projection.productPageCandidate?.url ?? null,
          });
          Object.assign(stageB, enrichment.diagnostics);
          stageB.selected_manufacturer_label = enrichment.source === "manufacturer_label"
            ? (enrichment.fetchedUrl ?? projection.manufacturerLabelCandidate.url)
            : null;
          if (enrichment.diagnostics.manufacturer_label_fetch === "failure") {
            degradedStages.push("manufacturer_label_fetch_failed");
          }

          // Cache ONLY a reading that actually carries rates. Caching a miss
          // would make "we found nothing" sticky for a week, which is the
          // opposite of what a lookup with no rates should do.
          if (
            enrichmentCache && enrichmentKey && resolved &&
            enrichment.source === "manufacturer_label" &&
            cachedEnrichmentIsUsable({
              registered_uses: enrichment.uses,
            } as never)
          ) {
            await enrichmentCache.write(
              enrichmentKey,
              {
                countryCode,
                scheme: resolved.scheme,
                registrationNumber: resolved.registration_number,
              },
              {
                manufacturer_product_url: structured.label_urls?.product_url ?? null,
                manufacturer_label_url: structured.label_urls?.manufacturer_label_url ?? null,
                regulator_label_url: structured.label_urls?.regulator_label_url ?? null,
                registered_uses: enrichment.uses,
                withholding_period_days: enrichment.withholdingPeriodDays,
                re_entry_period_hours: null,
                practical_source: enrichment.source,
                source_fingerprint: enrichment.diagnostics.manufacturer_label_sha256,
                parser_version: ENRICHMENT_CACHE_VERSION,
                refreshed_at: new Date().toISOString(),
              },
              ENRICHMENT_CACHE_TTL_SECONDS,
            );
          }
        } catch (err) {
          // Contained: manufacturer enrichment can never damage a register
          // result. The lookup continues on regulator evidence alone.
          degradedStages.push("manufacturer_enrichment_failed");
          console.error(
            "manufacturer enrichment skipped:",
            err instanceof Error ? err.message : String(err),
          );
        }
      }

      // Per-field provenance for the non-merged paths (the merge computes its
      // own). Additive; every field states which evidence tier populated it.
      if (!structured.field_provenance) {
        structured.field_provenance = buildFieldProvenance(structured, null, false);
      }
      // Contract invariant on EVERY path: a populated field with
      // authoritative provenance is never listed unresolved (idempotent —
      // the merge already enforced it on register-resolved results).
      pruneAuthoritativelyResolvedFields(structured);

      // Validate the label URL exactly as `info` does; a hallucinated label
      // link is worse than none, because it looks like evidence. A Stage
      // LD-1 register-confirmed document URL (field_provenance
      // manufacturer_label) is NOT re-probed: it was confirmed by the
      // register portal itself, and a transient eLabels hiccup must never
      // strip authoritative provenance from the response.
      const labelRef = structured.registration?.label_reference;
      const labelRefAuthoritative =
        structured.field_provenance?.label_reference === "manufacturer_label";
      if (labelRef && !labelRefAuthoritative) {
        const ok = !isPlaceholderURL(labelRef) &&
          looksLikeLabelURL(labelRef) &&
          await isURLReachable(labelRef);
        if (!ok) {
          structured.registration.label_reference = null;
          structured.verification.unresolved_fields = Array.from(
            new Set([...structured.verification.unresolved_fields, "label_reference"]),
          ).sort();
          // Keep provenance coherent with the nulled field.
          if (structured.field_provenance) {
            structured.field_provenance.label_reference = "unresolved";
          }
        }
      }

      // Additive envelope: what kind of answer this is. "unresolved" means
      // no product fact was established — the client should route the
      // operator to manual entry rather than pretending. The merge sets
      // "authoritative_candidate" (register-backed but NOT approved: clients
      // must never treat it as a master match) and the fail-closed gate sets
      // "unresolved"; only a path that set neither — outage / unsupported /
      // no-country degraded mode — computes here, exactly as before.
      if (!structured.match_source) {
        structured.match_source =
          (structured.active_ingredients.length > 0 ||
              structured.registration?.registration_number)
            ? "ai_candidate"
            : "unresolved";
      }

      // 7) Grow the catalogue: identity-complete results become CANDIDATE
      //    rows — deduplicated on the registration identity (one candidate
      //    per canonical registration, however many vineyards search it),
      //    refreshed by policy, never auto-approved, never blocking the
      //    lookup.
      let candidateAction = "none";
      let candidateRow: MasterRow | null = null;
      // Candidates are enqueued ONLY from register-verified identities. An
      // AI-asserted registration can no longer mint a catalogue row — the
      // register verifies name↔number first, or nothing is written.
      const payload = resolved
        ? buildCandidatePayload(
          structured,
          productName,
          resolved,
          new Date().toISOString(),
          ACTIVITY_GROUP_TABLE_VERSION,
        )
        : null;
      if (payload) {
        const outcome = await upsertCandidate(masterOps, payload, Date.now());
        candidateAction = outcome.reason
          ? `${outcome.action}:${outcome.reason}`
          : outcome.action;
        if (
          outcome.action === "approved_exists" &&
          outcome.row &&
          String(outcome.row.registration_country ?? "").toUpperCase() === countryCode
        ) {
          // The identity's row is already approved (an alias the name path
          // missed, or a review that landed mid-request).
          //
          // Serving it unconditionally was the defect that made Stage B
          // invisible in production. The lookup reaches this line ONLY after
          // it deliberately declined to short-circuit on this very row --
          // because the row admitted an unresolved grapevine rate -- and then
          // spent a register call, a research call, a page fetch and a
          // document fetch filling exactly that gap. Handing back the same
          // incomplete row at the end discarded all of it, and the operator
          // saw "rates:GRAPEVINE unresolved" from a lookup that had just read
          // the rates off the manufacturer's label.
          //
          // So the approved row is served when it is genuinely COMPLETE (the
          // catalogue is a cache and a complete row is the whole point of it),
          // and the fresh result is served when the row is not. Persistence is
          // unchanged either way: nothing here writes, and the review workflow
          // still owns what the catalogue stores.
          const approvedIsComplete = masterHasCompleteVineyardData(outcome.row);
          if (approvedIsComplete) {
            return servedStructured(
              { ...buildMasterStructuredResponse(outcome.row), jurisdiction: jurEnv },
              {
                selectedRegistration: registrationNumber ||
                  (outcome.row.registration_number ?? null),
                method: "master_catalogue",
                cache: discovery.cache === "hit" ? "hit" : "miss",
              },
            );
          }
          degradedStages.push("approved_master_incomplete_fresh_enrichment_served");
          stageB.master_incomplete = true;
          console.log(ingestionLog({
            jurisdiction: countryCode,
            adapter: discovery.adapter,
            outcome: "approved_master_incomplete_superseded",
            identity: outcome.row.registration_identity_key ?? null,
            master: "existing_approved",
            candidate: candidateAction,
            unresolvedCount:
              (outcome.row.verification_unresolved_fields ?? []).length,
            conflictCount: 0,
            durationMs: Date.now() - startedAt,
            cache: discovery.cache,
          }));
          // Fall through: the freshly enriched `structured` is served below.
        }
        if (outcome.row && outcome.row.review_status === "candidate") {
          candidateRow = outcome.row;
        }
      }

      if (candidateRow) structured.candidate = candidateEnvelope(candidateRow);
      structured.discovery = discoveryEnvelope(discovery);
      if (aiIdentityDiscarded) {
        structured.discovery.ai_registration_hint_discarded = aiIdentityDiscarded;
      }
      structured.jurisdiction = jurEnv;

      // Stage B: the enrichment trail, as an additive envelope AND a single
      // log line. Recording `final_registration` beside `exact_registration`
      // makes a substitution provable from one record rather than inferred by
      // comparing two.
      stageB.final_registration = structured?.registration?.registration_number ?? null;
      stageB.unresolved_after_enrichment =
        structured.verification?.unresolved_fields ?? [];
      structured.stage_b = { ...stageB };
      console.log(JSON.stringify({
        evt: "manufacturer_enrichment",
        ...stageB,
      }));

      console.log(ingestionLog({
        jurisdiction: countryCode,
        adapter: discovery.adapter,
        outcome: discovery.outcome,
        identity: resolved?.registration_identity_key ??
          candidateRow?.registration_identity_key ?? null,
        master: "none",
        candidate: candidateAction,
        unresolvedCount: structured.verification?.unresolved_fields?.length ?? 0,
        conflictCount: structured.verification?.conflicts?.length ?? 0,
        durationMs: Date.now() - startedAt,
        cache: discovery.cache,
        errorCategory: discovery.error_category,
      }));

      // The identity actually served, preferring what the register RESOLVED
      // over what the caller asked for — a parity check compares the answer,
      // not the question.
      const servedRegistration = resolved?.registration_number ??
        structured?.registration?.registration_number ??
        (registrationNumber || null);
      const structuredMethod: LookupMethod = discovery.outcome === "resolved"
        ? "official_register"
        : projection
        ? "research"
        : structured
        ? "ai_legacy"
        : "unresolved";

      return servedStructured(structured, {
        selectedRegistration: servedRegistration,
        method: structuredMethod,
        cache: discovery.cache === "hit"
          ? "hit"
          : discovery.cache === "none"
          ? "none"
          : "miss",
      });
    }

    if (action === "info") {
      const productName = typeof body?.productName === "string"
        ? body.productName.trim()
        : "";
      if (!productName) return json({ error: "Missing productName" }, 400);
      if (productName.length > 200) {
        return json({ error: "productName too long" }, 400);
      }
      const { system, user } = buildInfoPrompt(productName, countryLabel);
      const raw = await callOpenAI(system, user, apiKey);
      const parsed = extractJSON(raw);
      const normalized = await normalizeInfo(parsed);
      return json(normalized);
    }

    if (action === "master_refresh") {
      // Stage 3 §G — re-check one master row against its jurisdiction's
      // authoritative sources. System admins only. Approved rows are NEVER
      // written here: the returned diff IS the reviewable update, applied
      // (if accepted) through the existing admin write path, which the
      // sql/199 triggers version. Candidate rows may be refreshed in place
      // with apply:true. saved_chemicals is never touched.
      if (!masterConfigured()) {
        return json({ error: "Master catalogue not configured" }, 500);
      }
      const masterId = String(
        body?.masterChemicalId ?? body?.master_chemical_id ?? "",
      ).trim();
      if (!masterId) return json({ error: "Missing masterChemicalId" }, 400);

      if (!(await isSystemAdmin(req))) return json({ error: "Not authorised" }, 403);

      const rows = await masterSelect(
        `select=*&id=eq.${encodeURIComponent(masterId)}&limit=1`,
      );
      if (!rows || rows.length !== 1) {
        return json({ error: "Master row not found" }, 404);
      }
      const row = rows[0] as MasterRow;
      const result = await refreshMasterRow(row, {
        fetchFn: fetch,
        now: () => new Date(),
      });

      let applied = false;
      if (body?.apply === true && row.review_status === "candidate") {
        const patch = buildCandidateRefreshPatch(row, result, new Date().toISOString());
        if (patch) applied = await masterOps.updateCandidate(row.id, patch);
      }

      console.log(JSON.stringify({
        evt: "master_refresh",
        jurisdiction: row.registration_country,
        registration_identity: row.registration_identity_key,
        review_status: row.review_status,
        outcome: result.outcome,
        changes: result.changes.length,
        applied,
        ...(result.error_category ? { error_category: result.error_category } : {}),
      }));

      return json({
        outcome: result.outcome,
        changes: result.changes,
        applied,
        master: {
          master_chemical_id: row.id,
          catalogue_status: row.review_status,
          master_revision: row.catalogue_version ?? 1,
          registration_identity_key: row.registration_identity_key ?? null,
        },
        ...(result.error_category ? { error_category: result.error_category } : {}),
      });
    }

    if (action === "master_review_preview") {
      // Stage 2 R2-B — build AND STORE the resolver-owned review patch for
      // one master row (any review state). System admins only.
      //
      //   * The row is NEVER written here: refreshMasterRow is read-only and
      //     this action has no master write path at all.
      //   * The patch is built by the reviewed refresh builder, validated
      //     against the sql/203 resolver patch contract, and stored in
      //     master_review_previews bound to the requesting admin. The
      //     returned proposed_patch/current are DISPLAY ONLY.
      //   * Apply is deliberately NOT proxied by this function: the portal
      //     calls the master_review_apply RPC directly (PostgREST) with the
      //     admin's own JWT, so the service role never applies and reviewer
      //     attribution (auth.uid()) stays real.
      if (!masterConfigured()) {
        return json({ error: "Master catalogue not configured" }, 500);
      }
      // Trust boundary, stated loudly: this action accepts NO patch and NO
      // apply flag from any client, ever.
      if (
        body?.proposedPatch !== undefined ||
        body?.proposed_patch !== undefined ||
        body?.patch !== undefined ||
        body?.apply !== undefined
      ) {
        return json({
          error:
            "master_review_preview accepts no patch/apply input; the patch is resolver-built and server-stored",
        }, 400);
      }
      const masterId = String(
        body?.masterChemicalId ?? body?.master_chemical_id ?? "",
      ).trim();
      if (!masterId) return json({ error: "Missing masterChemicalId" }, 400);

      if (!(await isSystemAdmin(req))) {
        return json({ error: "Not authorised" }, 403);
      }
      const adminId = await authenticatedUserId(req);
      if (!adminId) return json({ error: "Not authorised" }, 403);

      const rows = await masterSelect(
        `select=*&id=eq.${encodeURIComponent(masterId)}&limit=1`,
      );
      if (!rows || rows.length !== 1) {
        return json({ error: "Master row not found" }, 404);
      }
      const row = rows[0] as MasterRow;

      const result = await refreshMasterRow(row, {
        fetchFn: fetch,
        now: () => new Date(),
      });
      const response = await runMasterReviewPreview(row, result, adminId, {
        store: previewStore,
        nowIso: () => new Date().toISOString(),
      });

      console.log(JSON.stringify({
        evt: "master_review_preview",
        jurisdiction: row.registration_country,
        registration_identity: row.registration_identity_key,
        review_status: row.review_status,
        outcome: response.outcome,
        identity_guard: response.identity_guard.status,
        preview_stored: response.preview_stored,
        base_revision: response.base_revision,
        ...(response.preview_id ? { preview_id: response.preview_id } : {}),
        ...(response.no_preview_reason
          ? { no_preview_reason: response.no_preview_reason }
          : {}),
        ...(response.error ? { error: response.error } : {}),
        ...(response.error_category
          ? { error_category: response.error_category }
          : {}),
      }));

      if (response.error === "patch_contract_violation") {
        return json(response, 500);
      }
      if (response.error === "preview_store_failed") {
        return json(response, 503);
      }
      return json(response);
    }

    if (action === "seed_apply") {
      // Stage 5B — apply ONE reviewed seed identity as a Master CANDIDATE.
      // System admins only. INSERT-ONLY by construction (ingestion/
      // seed_apply.ts): an existing row in ANY review state is returned
      // "already_exists" untouched; the live register re-verifies
      // name↔number before anything binds; AWRI rides along as ONE
      // viticulture_reference evidence entry, never as facts; no AI call;
      // saved_chemicals and spray records are never touched; approval stays
      // a human step.
      if (!masterConfigured()) {
        return json({ error: "Master catalogue not configured" }, 500);
      }
      if (!(await isSystemAdmin(req))) return json({ error: "Not authorised" }, 403);

      const registrationNumber = String(body?.registrationNumber ?? "").trim();
      const productName = String(body?.productName ?? "").trim();
      const seedSource = String(body?.seedSource ?? "").trim();
      const deps = { fetchFn: fetch, now: () => new Date() };

      const outcome = await runSeedApply(
        {
          registration_number: registrationNumber,
          product_name: productName,
          seed_source_id: seedSource,
        },
        masterOps,
        (query, hint) => discoverAuthoritative("AU", query, hint, deps),
        new Date().toISOString(),
        ACTIVITY_GROUP_TABLE_VERSION,
      );

      console.log(JSON.stringify({
        evt: "seed_apply",
        seed_source: seedSource,
        registration_identity: outcome.registration_identity_key,
        outcome: outcome.outcome,
        detail: outcome.detail,
        writes: outcome.writes,
      }));

      return json(outcome);
    }

    return json({ error: "Unknown action" }, 400);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message }, 502);
  }
});
