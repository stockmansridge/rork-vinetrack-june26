// The chemical research orchestrator: Terra first, Sol once, never a loop.
//
// This is the module the edge function calls. It owns the prompts, the
// bounded retry policy, the Terra→Sol escalation, the research cache, and
// the telemetry line that tells us whether Sol is firing 1% or 80% of the
// time.
//
// WHAT IT DELIBERATELY DOES NOT OWN: authority. This module produces
// research. `authority.ts` projects it, and the register overrules it.
// Nothing here can promote a web finding into a registered fact.

import {
  callResponsesApi,
  DEFAULT_RESEARCH_FALLBACK_MODEL,
  DEFAULT_RESEARCH_MODEL,
  OpenAIResearchError,
  type ReasoningEffort,
  type ResponsesCallResult,
} from "./responses_client.ts";
import {
  type ChemicalResearchResult,
  parseChemicalResearchResult,
  ResearchSchemaError,
} from "./schema.ts";
import { classifyUrl, type ClassifiedUrl, preferredResearchDomains } from "./classify.ts";
import {
  decideEscalation,
  type EscalationDecision,
  type EscalationReason,
  solTerminalDecision,
} from "./escalation.ts";

export const RESEARCH_PROMPT_VERSION = 3;

/** Per-attempt wall clock. Two attempts must still fit an edge invocation. */
export const RESEARCH_TIMEOUT_MS = 55_000;
export const RESEARCH_CANDIDATE_TIMEOUT_MS = 30_000;

export type ResearchMode =
  /** Broad discovery for a search listing. Latency matters most. */
  | "candidate_discovery"
  /** Deep research for one selected product. Completeness matters most. */
  | "product_enrichment";

export interface ResearchConfig {
  model: string;
  fallbackModel: string;
  enabled: boolean;
}

/**
 * Read the research model configuration.
 *
 * The legacy `OPENAI_MODEL` variable is deliberately NOT consulted: it still
 * exists for the other, unrelated functions that use chat completions, and
 * if research honoured it a stale `gpt-4o` in the environment would silently
 * undo this entire upgrade (task §38.7).
 */
export function readResearchConfig(
  env: (key: string) => string | undefined = (k) => Deno.env.get(k),
): ResearchConfig {
  const flag = (env("CHEMICAL_RESEARCH_RESPONSES_ENABLED") ?? "true").trim().toLowerCase();
  return {
    model: (env("CHEMICAL_RESEARCH_MODEL") ?? "").trim() || DEFAULT_RESEARCH_MODEL,
    fallbackModel: (env("CHEMICAL_RESEARCH_FALLBACK_MODEL") ?? "").trim() ||
      DEFAULT_RESEARCH_FALLBACK_MODEL,
    enabled: flag !== "false" && flag !== "0" && flag !== "off",
  };
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

const AU_SOURCE_POLICY =
  `SOURCE PRIORITY FOR AUSTRALIA, strongest first:
1. apvma.gov.au and elabels.apvma.gov.au (the APVMA register and approved labels)
2. the registrant's or manufacturer's own website
3. other Australian government/regulator documents
4. AWRI viticulture references
Resellers, marketplaces, agronomy blogs and search-engine result pages may help you FIND a source, but they are never the evidence. Cite the underlying source, never the search page you passed through.`;

const NZ_SOURCE_POLICY =
  `SOURCE PRIORITY FOR NEW ZEALAND, strongest first:
1. MPI ACVM register sources (mpi.govt.nz)
2. NZ EPA (epa.govt.nz) where the approval is relevant
3. the registrant's or manufacturer's own website
4. approved NZ label documents and NZ Winegrowers references
An Australian APVMA registration is NEVER evidence for New Zealand. If you can only find an Australian registration, say so in unresolved[] and leave the NZ registration candidates empty.`;

const GENERIC_SOURCE_POLICY =
  `SOURCE PRIORITY, strongest first: the country's official pesticide/veterinary-medicine register, then other government documents, then the registrant's own website. Resellers, marketplaces and search-engine result pages are never evidence.`;

function sourcePolicyFor(countryCode: string): string {
  const code = countryCode.trim().toUpperCase();
  if (code === "AU") return AU_SOURCE_POLICY;
  if (code === "NZ") return NZ_SOURCE_POLICY;
  return GENERIC_SOURCE_POLICY;
}

const BASE_INSTRUCTIONS =
  `You research agricultural and viticultural inputs — crop protection, fertilisers, foliar nutrients, biostimulants, adjuvants, surfactants and biological controls — including small specialty and regional brands, not just mainstream agrochemicals.

Use the web_search tool. Do not answer from memory: registrations, concentrations, labels and rates change, and a remembered answer is worth less than no answer. Search, open the pages, and read them.

HONESTY RULES, in order of importance:
1. NEVER invent a URL. Only return URLs you actually retrieved through web search. A fabricated link is worse than an empty field.
2. NEVER invent a registration number, concentration, rate, withholding period or re-entry interval. If you could not find it, name the gap in unresolved[].
3. Every fact you report must list the URLs that support it in its source_refs. A fact with no source_refs is treated as your opinion and is handled accordingly downstream.
4. A registration number you find on the web is a LEAD, not a fact. It will be re-checked against the official register before it is believed. Report what you actually saw and let the register decide.
5. Report the registered product name EXACTLY as the register prints it, including formulation suffixes. Do not tidy it up.

DOCUMENT CLASSIFICATION — get this right, it matters:
- official_label_candidates: only regulator-hosted approved labels, or the registrant's own hosted LABEL document. A product marketing page is not a label. An SDS is not a label.
- product_page_candidates: only pages on the manufacturer's or registrant's own domain.
- sds_candidates: safety data sheets. Keep them here. Never list an SDS as a label.

RATES: preserve the label's own basis for every rate — per hectare, per 100 litres, per 100 metres of row, ranges, or reference-only. Never convert one basis into another, and never drop a basis because another one looks more useful.

TARGETS: keep every pest and disease a use is registered against. Never reduce a use to a single primary target.

RESISTANCE GROUPS: suggested_scheme and suggested_group are suggestions only. They are cross-checked against an authoritative FRAC/HRAC/IRAC table. Never merge the three schemes.`;

export function buildResearchPrompt(
  query: string,
  countryCode: string,
  countryLabel: string,
  mode: ResearchMode,
  escalationReasons: EscalationReason[] = [],
): { instructions: string; input: string } {
  const instructions = `${BASE_INSTRUCTIONS}\n\n${sourcePolicyFor(countryCode)}`;

  const country = countryLabel || countryCode || "the vineyard's country";
  const scopeLine =
    `The vineyard is in ${country} (${countryCode || "country unresolved"}). Research the product AS REGISTERED AND SOLD IN ${country}. Country is a hard boundary: never present another country's registration as this country's.`;

  const modeLine = mode === "candidate_discovery"
    ? `The operator is still searching, so favour breadth and speed: identify which product or products they most likely mean, including for a misspelling or a partial name, and return the registration leads and identity. Deep label detail is not required at this stage — leave registered_uses empty rather than guessing at it.`
    : `The operator has selected this product, so favour depth: establish the full registered identity, the actives and their strengths, the official label document, the manufacturer's product page, and the registered uses with their crops, targets, rates, withholding periods, re-entry intervals and restrictions.`;

  const escalationLine = escalationReasons.length
    ? `\n\nA faster model already researched this and could not settle the following. Concentrate on exactly these: ${
      escalationReasons.join(", ")
    }. Search differently rather than repeating the same query.`
    : "";

  const input =
    `Research this vineyard input: "${query}"\n\n${scopeLine}\n\n${modeLine}\n\nThe search text may contain a typo or be only part of the product name. If so, identify the real product and return its full canonical name in product.canonical_name, keeping the operator's original text verbatim in product.searched_name.${escalationLine}`;

  return { instructions, input };
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

export interface ResearchAttemptTelemetry {
  model: string;
  role: "primary" | "fallback";
  ok: boolean;
  error_category: string | null;
  retried: boolean;
  web_search_calls: number;
  queries: string[];
  sources_consulted: number;
  input_tokens: number | null;
  output_tokens: number | null;
  duration_ms: number;
  response_id: string | null;
}

export interface ResearchTelemetry {
  prompt_version: number;
  mode: ResearchMode;
  country: string;
  cache: "hit" | "miss" | "bypass";
  attempts: ResearchAttemptTelemetry[];
  escalated: boolean;
  escalation_reasons: EscalationReason[];
  total_duration_ms: number;
}

export interface ResearchOutcome {
  research: ChemicalResearchResult | null;
  /** Server-classified URLs from the winning attempt. */
  classified: ClassifiedUrl[];
  telemetry: ResearchTelemetry;
  /** Present when research produced nothing usable. */
  error: { category: string; message: string } | null;
  escalation: EscalationDecision | null;
  /** Raw transport result of the winning attempt — debug/admin only. */
  raw: ResponsesCallResult | null;
}

/** One line per lookup, greppable in the edge logs (task §32). */
export function researchLog(t: ResearchTelemetry): string {
  const primary = t.attempts.find((a) => a.role === "primary");
  const fallback = t.attempts.find((a) => a.role === "fallback");
  const parts = [
    "chemical_research",
    `mode=${t.mode}`,
    `country=${t.country || "none"}`,
    `cache=${t.cache}`,
    `primary=${primary?.model ?? "none"}`,
    `primary_ok=${primary?.ok ?? false}`,
    `retried=${primary?.retried ?? false}`,
    `sol=${fallback ? fallback.model : "no"}`,
    `escalated=${t.escalated}`,
    `reasons=${t.escalation_reasons.join("|") || "none"}`,
    `websearch_calls=${t.attempts.reduce((n, a) => n + a.web_search_calls, 0)}`,
    `sources=${t.attempts.reduce((n, a) => n + a.sources_consulted, 0)}`,
    `in_tok=${t.attempts.reduce((n, a) => n + (a.input_tokens ?? 0), 0)}`,
    `out_tok=${t.attempts.reduce((n, a) => n + (a.output_tokens ?? 0), 0)}`,
    `ms=${t.total_duration_ms}`,
  ];
  return parts.join(" ");
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

interface ResearchCacheEntry {
  outcome: ResearchOutcome;
  expiresAtMs: number;
}

/** Research is stable enough to reuse inside one workflow, no longer. */
export const RESEARCH_CACHE_TTL_MS = 30 * 60 * 1000;
const RESEARCH_CACHE_MAX = 128;

const researchCache = new Map<string, ResearchCacheEntry>();

/**
 * Cache key: country + normalised query + mode + model + prompt version.
 *
 * The model and prompt version are IN the key so a model change or a prompt
 * change can never be served a previous generation's research. Register
 * resolution is not cached here at all — it stays independently refreshable,
 * so cached research can never mask fresher authoritative data (§25).
 */
export function researchCacheKey(
  countryCode: string,
  query: string,
  mode: ResearchMode,
  model: string,
): string {
  const norm = query.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
  return `${countryCode.toUpperCase()}::${mode}::${model}::v${RESEARCH_PROMPT_VERSION}::${norm}`;
}

export function clearResearchCache(): void {
  researchCache.clear();
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

export interface RunResearchOptions {
  query: string;
  countryCode: string;
  countryLabel: string;
  mode: ResearchMode;
  apiKey: string;
  fetchFn: typeof fetch;
  config: ResearchConfig;
  /**
   * Whether the official register already resolved this lookup. Passed in so
   * escalation can decline to spend Sol on a question already answered.
   */
  registerResolved: boolean;
  labelMissingForResolvedRegistration?: boolean;
  now?: () => number;
  useCache?: boolean;
  includeSearchResults?: boolean;
}

interface AttemptResult {
  research: ChemicalResearchResult | null;
  classified: ClassifiedUrl[];
  raw: ResponsesCallResult | null;
  telemetry: ResearchAttemptTelemetry;
  error: { category: string; message: string } | null;
}

async function runAttempt(
  opts: RunResearchOptions,
  model: string,
  role: "primary" | "fallback",
  effort: ReasoningEffort,
  escalationReasons: EscalationReason[],
): Promise<AttemptResult> {
  const { instructions, input } = buildResearchPrompt(
    opts.query,
    opts.countryCode,
    opts.countryLabel,
    opts.mode,
    escalationReasons,
  );

  const timeoutMs = opts.mode === "candidate_discovery"
    ? RESEARCH_CANDIDATE_TIMEOUT_MS
    : RESEARCH_TIMEOUT_MS;

  const call = () =>
    callResponsesApi({
      model,
      instructions,
      input,
      reasoningEffort: effort,
      apiKey: opts.apiKey,
      fetchFn: opts.fetchFn,
      timeoutMs,
      searchCountry: opts.countryCode || null,
      // Preference, not a filter: hard-restricting to regulator hosts would
      // hide the manufacturer pages that make niche products findable.
      allowedDomains: [],
      includeSearchResults: opts.includeSearchResults === true,
    });

  const base: ResearchAttemptTelemetry = {
    model,
    role,
    ok: false,
    error_category: null,
    retried: false,
    web_search_calls: 0,
    queries: [],
    sources_consulted: 0,
    input_tokens: null,
    output_tokens: null,
    duration_ms: 0,
    response_id: null,
  };

  let raw: ResponsesCallResult | null = null;
  let retried = false;
  try {
    raw = await call();
  } catch (err) {
    const category = err instanceof OpenAIResearchError ? err.category : "transient";
    // Exactly one retry, and only for a transient failure. A 401 or a bad
    // model name is retried zero times — repeating it just burns the budget.
    if (category === "transient") {
      retried = true;
      try {
        raw = await call();
      } catch (err2) {
        const cat2 = err2 instanceof OpenAIResearchError ? err2.category : "transient";
        return {
          research: null,
          classified: [],
          raw: null,
          error: { category: cat2, message: err2 instanceof Error ? err2.message : String(err2) },
          telemetry: { ...base, retried, error_category: cat2 },
        };
      }
    } else {
      return {
        research: null,
        classified: [],
        raw: null,
        error: { category, message: err instanceof Error ? err.message : String(err) },
        telemetry: { ...base, error_category: category },
      };
    }
  }

  const telemetry: ResearchAttemptTelemetry = {
    ...base,
    retried,
    web_search_calls: raw.webSearchCalls.length,
    queries: raw.webSearchCalls.map((c) => c.query ?? "").filter(Boolean),
    sources_consulted: raw.consultedUrls.length,
    input_tokens: raw.usage.input_tokens,
    output_tokens: raw.usage.output_tokens,
    duration_ms: raw.durationMs,
    response_id: raw.responseId,
  };

  let research: ChemicalResearchResult;
  try {
    research = parseChemicalResearchResult(raw.payload);
  } catch (err) {
    // Fail CLOSED on a malformed payload: no salvage attempt, no loose
    // parsing. The lookup proceeds as if research were unavailable.
    const message = err instanceof ResearchSchemaError
      ? err.message
      : err instanceof Error
      ? err.message
      : String(err);
    return {
      research: null,
      classified: [],
      raw,
      error: { category: "malformed", message },
      telemetry: { ...telemetry, error_category: "malformed" },
    };
  }

  // Classify everything the TOOL consulted too, not just what the model
  // chose to report — that is the evidence trail the server reasons over.
  const urls = new Set<string>(raw.consultedUrls);
  for (const s of research.sources) urls.add(s.url);
  for (const d of research.documents.official_label_candidates) urls.add(d.url);
  for (const d of research.documents.product_page_candidates) urls.add(d.url);
  const classified = [...urls].map((u) => classifyUrl(u, opts.countryCode));

  return {
    research,
    classified,
    raw,
    error: null,
    telemetry: { ...telemetry, ok: true },
  };
}

/**
 * Run chemical web research: Terra, then at most one Sol escalation.
 *
 * Never throws. Every failure path returns `research: null` with the reason
 * recorded, because research is an ENRICHMENT layer — the caller's register
 * and catalogue lookups must still be able to answer without it (§30).
 */
export async function runChemicalResearch(
  opts: RunResearchOptions,
): Promise<ResearchOutcome> {
  const now = opts.now ?? (() => Date.now());
  const startedAt = now();
  const useCache = opts.useCache !== false;
  const cacheKey = researchCacheKey(opts.countryCode, opts.query, opts.mode, opts.config.model);

  if (useCache) {
    const hit = researchCache.get(cacheKey);
    if (hit && hit.expiresAtMs > now()) {
      return {
        ...hit.outcome,
        telemetry: { ...hit.outcome.telemetry, cache: "hit" },
      };
    }
    if (hit) researchCache.delete(cacheKey);
  }

  const telemetry: ResearchTelemetry = {
    prompt_version: RESEARCH_PROMPT_VERSION,
    mode: opts.mode,
    country: opts.countryCode,
    cache: useCache ? "miss" : "bypass",
    attempts: [],
    escalated: false,
    escalation_reasons: [],
    total_duration_ms: 0,
  };

  // Discovery is latency-sensitive, so it runs at low effort; enrichment is
  // the deep pass and gets medium. Neither uses high/xhigh/max by default.
  const primaryEffort: ReasoningEffort = opts.mode === "candidate_discovery" ? "low" : "medium";

  const primary = await runAttempt(opts, opts.config.model, "primary", primaryEffort, []);
  telemetry.attempts.push(primary.telemetry);

  const escalation = decideEscalation({
    research: primary.research,
    registerResolved: opts.registerResolved,
    labelMissingForResolvedRegistration: opts.labelMissingForResolvedRegistration === true,
    classified: primary.classified,
  });

  let winner = primary;
  let finalEscalation: EscalationDecision = escalation;

  // Candidate discovery never escalates: the operator is mid-search and a
  // second frontier-model call is the wrong trade at that moment.
  const mayEscalate = escalation.escalate && opts.mode === "product_enrichment";

  if (mayEscalate) {
    telemetry.escalated = true;
    telemetry.escalation_reasons = escalation.reasons;
    const fallback = await runAttempt(
      opts,
      opts.config.fallbackModel,
      "fallback",
      "high",
      escalation.reasons,
    );
    telemetry.attempts.push(fallback.telemetry);
    // Sol is terminal. Its result is evaluated for nothing except whether it
    // is better than Terra's — there is no second escalation from here.
    if (fallback.research) winner = fallback;
    finalEscalation = solTerminalDecision(escalation.reasons);
  }

  telemetry.total_duration_ms = now() - startedAt;

  const outcome: ResearchOutcome = {
    research: winner.research,
    classified: winner.classified,
    telemetry,
    error: winner.error,
    escalation: finalEscalation,
    raw: winner.raw,
  };

  if (useCache && winner.research) {
    if (researchCache.size >= RESEARCH_CACHE_MAX) {
      const oldest = researchCache.keys().next().value;
      if (oldest !== undefined) researchCache.delete(oldest);
    }
    researchCache.set(cacheKey, {
      outcome: { ...outcome, telemetry: { ...telemetry } },
      expiresAtMs: now() + RESEARCH_CACHE_TTL_MS,
    });
  }

  return outcome;
}

/** Domains the prompt tells the model to prefer — surfaced for debugging. */
export { preferredResearchDomains };
