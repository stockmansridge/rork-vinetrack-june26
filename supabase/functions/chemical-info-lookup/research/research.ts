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
  decideCandidateDiscoveryEscalation,
  decideEscalation,
  type EscalationDecision,
  type EscalationReason,
  solTerminalDecision,
} from "./escalation.ts";
import { mergeCandidateResearch } from "./candidate_merge.ts";
import { looksLikeProductCode } from "../ranking.ts";

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
5. Report the registered product name EXACTLY as the register prints it, including formulation suffixes. Do not tidy it up. This matters more than it looks: the registered name you return for a registration number is re-checked against the register TOGETHER WITH that number, so a shortened or tidied name ('Dithane Rainshield' where the register says 'Dithane Rainshield Neo Tec Fungicide') will cause the lead to be rejected. Put the full register name in registration_candidates[].registered_product_name, and keep each number with the name it was found with — never mix a number from one product with a name from another.

DOCUMENT CLASSIFICATION — get this right, it matters:
- official_label_candidates: only regulator-hosted approved labels, or the registrant's own hosted LABEL document. A product marketing page is not a label. An SDS is not a label.
- product_page_candidates: only pages on the manufacturer's or registrant's own domain.
- sds_candidates: safety data sheets. Keep them here. Never list an SDS as a label.

RATES: preserve the label's own basis for every rate — per hectare, per 100 litres, per 100 metres of row, ranges, or reference-only. Never convert one basis into another, and never drop a basis because another one looks more useful.

TARGETS: keep every pest and disease a use is registered against. Never reduce a use to a single primary target.

USE CONTEXTS — one registered_uses entry per DISTINCT context, and this is where flattening does real harm. Targets may be listed together in ONE entry only when the crop, the rates, the withholding period, the re-entry interval and the restrictions are identical for all of them. The moment two targets take different rates they become two separate entries. Never emit one entry that lists several targets and several rates and leaves the reader to guess which rate belongs to which target — that reads as though every target accepts every rate, which is wrong and unsafe. Worked example: if a grapevine label gives 200 g/100 L for black spot and downy mildew, and 150-200 g/100 L for phomopsis cane and leaf spot, that is TWO entries: {crop: Grapevines, targets: [Black spot, Downy mildew], rates: [200 g/100 L]} and {crop: Grapevines, targets: [Phomopsis cane and leaf spot], rates: [150-200 g/100 L]}. Where the label prints a rate against a named target, name that target in the rate's raw_text as well.

RESISTANCE GROUPS: suggested_scheme and suggested_group are suggestions only. They are cross-checked against an authoritative FRAC/HRAC/IRAC table. Never merge the three schemes.`;

/** A product a previous pass already found, for the recall prompt. */
export interface KnownCandidate {
  name: string;
  number: string | null;
}

/**
 * Tell the fallback what is already known, and ask it to WIDEN.
 *
 * # Why the fallback cannot simply be re-asked the same question
 *
 * Re-running an identical prompt against a stronger model is a good way to
 * buy the same answer more expensively. Terra returned SYNERTROL HORTI for
 * "Hortitrol Winter Oil" because that IS a defensible reading of the name;
 * Sol, asked the same open question, would very likely agree, and the whole
 * escalation would achieve nothing.
 *
 * So the second pass gets a different job: here is what we have, find what
 * ELSE could plausibly be meant. That is a genuinely different search, and it
 * is the only kind that improves recall.
 *
 * What this deliberately does NOT do is name a product we hope to see. It
 * describes the SHAPE of the answer -- approximate, misspelled, historical,
 * abbreviated or imperfectly remembered trade names -- and never the answer
 * itself. A prompt that hinted at the expected product would make the
 * regression prove only that a model can be told what to say.
 */
function buildRecallLine(known: KnownCandidate[]): string {
  if (!known.length) return "";
  const listed = known
    .map((k) => (k.number ? `${k.name} (registration ${k.number})` : k.name))
    .join("; ");
  return "\n\nA faster model has already searched this name and found: " +
    listed +
    ".\n\nYour job is DIFFERENT: find ADDITIONAL, genuinely different registered products in this country that the operator could plausibly have meant. " +
    "Treat the search text as possibly misspelled, abbreviated, out of date, discontinued, renamed, or a trade name remembered imperfectly -- growers often ask for a product by a name close to, but not exactly, the registered one. " +
    "Search differently from an obvious name match: consider the product TYPE the name implies and what else is registered for that purpose. " +
    "Do not repeat or re-describe the candidate(s) above. If, after searching, you genuinely find no other plausible product, return none rather than padding the list. " +
    "Return each additional product in registration_candidates[] with its registration number and its exact registered name.";
}

export function buildResearchPrompt(
  query: string,
  countryCode: string,
  countryLabel: string,
  mode: ResearchMode,
  escalationReasons: EscalationReason[] = [],
  knownCandidates: KnownCandidate[] = [],
): { instructions: string; input: string } {
  const instructions = `${BASE_INSTRUCTIONS}\n\n${sourcePolicyFor(countryCode)}`;

  const country = countryLabel || countryCode || "the vineyard's country";
  const scopeLine =
    `The vineyard is in ${country} (${countryCode || "country unresolved"}). Research the product AS REGISTERED AND SOLD IN ${country}. Country is a hard boundary: never present another country's registration as this country's.`;

  const modeLine = mode === "candidate_discovery"
    ? `The operator is still searching, so favour breadth and speed: identify which product or products they most likely mean, including for a misspelling or a partial name, and return the registration leads and identity. Deep label detail is not required at this stage — leave registered_uses empty rather than guessing at it.`
    : `The operator has selected this product, so favour depth: establish the full registered identity, the actives and their strengths, the official label document, the manufacturer's product page, and the registered uses with their crops, targets, rates, withholding periods, re-entry intervals and restrictions. Split the registered uses by use context: targets that take different rates must not share an entry.`;

  const escalationLine = escalationReasons.length
    ? `\n\nA faster model already researched this and could not settle the following. Concentrate on exactly these: ${
      escalationReasons.join(", ")
    }. Search differently rather than repeating the same query.`
    : "";

  const input =
    `Research this vineyard input: "${query}"\n\n${scopeLine}\n\n${modeLine}\n\nThe search text may contain a typo or be only part of the product name. If so, identify the real product and return its full canonical name in product.canonical_name, keeping the operator's original text verbatim in product.searched_name.${escalationLine}${
      buildRecallLine(knownCandidates)
    }`;

  return { instructions, input };
}

/** The products a completed pass established, for the recall prompt. */
function knownCandidatesFrom(
  research: ChemicalResearchResult | null,
): KnownCandidate[] {
  if (!research) return [];
  const out: KnownCandidate[] = [];
  const seen = new Set<string>();
  const push = (name: string | null, number: string | null) => {
    const trimmed = (name ?? "").trim();
    if (!trimmed) return;
    const key = trimmed.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ name: trimmed, number: (number ?? "").trim() || null });
  };
  for (const c of research.registration_candidates) {
    push(c.registered_product_name, c.number);
  }
  // The canonical product need not appear in the candidate list at all.
  push(research.product.canonical_name, null);
  return out;
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

export interface ResearchAttemptTelemetry {
  model: string;
  role: "primary" | "fallback";
  ok: boolean;
  /** Distinct registration candidates THIS attempt produced -- the number the
   *  candidate-discovery escalation rule is decided on. */
  candidate_count: number;
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
  /** Registration numbers in the MERGED candidate set, in served order. The
   *  one field that proves whether recall actually improved. */
  merged_candidate_numbers: string[];
  /** Candidates the fallback contributed that the primary had not found. */
  candidates_added_by_fallback: number;
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
    `primary_candidates=${primary?.candidate_count ?? 0}`,
    `sol=${fallback ? fallback.model : "no"}`,
    `sol_candidates=${fallback?.candidate_count ?? 0}`,
    `escalated=${t.escalated}`,
    `reasons=${t.escalation_reasons.join("|") || "none"}`,
    `merged_candidates=[${t.merged_candidate_numbers.join(",")}]`,
    `added_by_sol=${t.candidates_added_by_fallback}`,
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
  knownCandidates: KnownCandidate[] = [],
): Promise<AttemptResult> {
  const { instructions, input } = buildResearchPrompt(
    opts.query,
    opts.countryCode,
    opts.countryLabel,
    opts.mode,
    escalationReasons,
    knownCandidates,
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
    candidate_count: 0,
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

  const distinctCandidates = new Set(
    research.registration_candidates
      .map((c) => (c.number ?? "").trim().toUpperCase())
      .filter((n) => n.length > 0),
  ).size;

  return {
    research,
    classified,
    raw,
    error: null,
    telemetry: { ...telemetry, ok: true, candidate_count: distinctCandidates },
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
    merged_candidate_numbers: [],
    candidates_added_by_fallback: 0,
    total_duration_ms: 0,
  };

  // Discovery is latency-sensitive, so it runs at low effort; enrichment is
  // the deep pass and gets medium. Neither uses high/xhigh/max by default.
  const primaryEffort: ReasoningEffort = opts.mode === "candidate_discovery" ? "low" : "medium";

  const primary = await runAttempt(opts, opts.config.model, "primary", primaryEffort, []);
  telemetry.attempts.push(primary.telemetry);

  // Two modes ask two different questions, so they get two different rules:
  //
  //   enrichment  "is this product's record complete?"   -> decideEscalation
  //   discovery   "has the operator got a CHOICE yet?"   -> the recall rule
  //
  // Discovery used to be barred from escalating outright. That protected
  // latency and destroyed recall: one Terra candidate ended discovery, and no
  // amount of downstream ranking can order an alternative it was never given.
  const isDiscovery = opts.mode === "candidate_discovery";
  const escalation = isDiscovery
    ? decideCandidateDiscoveryEscalation({
      research: primary.research,
      registerResolved: opts.registerResolved,
      isProductCodeQuery: looksLikeProductCode(opts.query),
    })
    : decideEscalation({
      research: primary.research,
      registerResolved: opts.registerResolved,
      labelMissingForResolvedRegistration: opts.labelMissingForResolvedRegistration === true,
      classified: primary.classified,
    });

  let winner = primary;
  let finalEscalation: EscalationDecision = escalation;

  if (escalation.escalate) {
    telemetry.escalated = true;
    telemetry.escalation_reasons = escalation.reasons;

    // Discovery tells the fallback what is already known and asks it to WIDEN.
    // Enrichment asks the same open question of a stronger model.
    const known = isDiscovery ? knownCandidatesFrom(primary.research) : [];

    const fallback = await runAttempt(
      opts,
      opts.config.fallbackModel,
      "fallback",
      "high",
      escalation.reasons,
      known,
    );
    telemetry.attempts.push(fallback.telemetry);

    if (isDiscovery && primary.research) {
      // MERGE, never replace. Terra's candidate is a real candidate, and Sol
      // was asked what ELSE exists -- so discarding Terra's answer could make
      // recall worse than before escalation existed, which would be a strange
      // result for a change whose whole purpose is recall.
      const mergedResult = mergeCandidateResearch(
        primary.research,
        fallback.research,
        opts.countryCode,
      );
      telemetry.merged_candidate_numbers = mergedResult.mergedNumbers;
      telemetry.candidates_added_by_fallback = mergedResult.addedCount;
      winner = {
        ...primary,
        research: mergedResult.research,
        // Both passes' evidence trails survive the merge.
        classified: [...primary.classified, ...fallback.classified],
        raw: fallback.raw ?? primary.raw,
      };
    } else if (fallback.research) {
      // Sol is terminal. Its result is evaluated for nothing except whether it
      // is better than Terra's — there is no second escalation from here.
      winner = fallback;
    }

    finalEscalation = solTerminalDecision(escalation.reasons);
  }

  // Recorded on EVERY discovery pass, escalated or not, so the diagnostics
  // line answers "what did the operator actually get?" without the reader
  // having to know whether escalation happened.
  if (isDiscovery && !telemetry.merged_candidate_numbers.length && winner.research) {
    telemetry.merged_candidate_numbers = winner.research.registration_candidates
      .map((c) => (c.number ?? "").trim())
      .filter((n) => n.length > 0);
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
