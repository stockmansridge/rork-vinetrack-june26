// OpenAI Responses API transport for chemical research.
//
// This module replaces the legacy `POST /v1/chat/completions` + JSON-mode
// call for the RESEARCH path. Three things change materially:
//
//   1. `POST /v1/responses` with `tools: [{ type: "web_search" }]` so the
//      model reads the live web instead of its February 2026 memory.
//   2. `text.format = json_schema (strict)` so the payload is schema-bound
//      rather than "please reply with JSON" and hope.
//   3. `include: ["web_search_call.action.sources"]` so the SERVER can see
//      every URL consulted — evidence classification is done here, not by
//      the model's say-so.
//
// STATELESS BY DESIGN (task §27): `store: false` on every call. Chemical
// research is a product question, not a conversation; nothing is retained
// on OpenAI's side and no lookup ever carries user history.
//
// The API key is read from the environment INSIDE the edge function and is
// never returned in any response body — no client ever sees it.

import {
  CHEMICAL_RESEARCH_SCHEMA,
  CHEMICAL_RESEARCH_SCHEMA_NAME,
} from "./schema.ts";

export const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";

/**
 * Model roles. The bare `gpt-5.6` alias routes to Sol, so using it as a
 * "default" would silently buy the flagship on every keystroke — the models
 * are named EXPLICITLY here and in the env defaults (task §26).
 */
export const DEFAULT_RESEARCH_MODEL = "gpt-5.6-terra";
export const DEFAULT_RESEARCH_FALLBACK_MODEL = "gpt-5.6-sol";

export type ReasoningEffort = "none" | "low" | "medium" | "high" | "xhigh" | "max";

export interface ResponsesCallOptions {
  model: string;
  instructions: string;
  input: string;
  reasoningEffort: ReasoningEffort;
  apiKey: string;
  fetchFn: typeof fetch;
  /** Wall-clock budget for one attempt, including the model's tool calls. */
  timeoutMs: number;
  /** Country hint passed to the web-search tool for regional results. */
  searchCountry?: string | null;
  /** Domains the model should prefer. Empty/omitted = unfiltered search. */
  allowedDomains?: string[];
  /** Capture full per-result detail for debugging. Off in production. */
  includeSearchResults?: boolean;
}

export interface WebSearchCallRecord {
  id: string | null;
  status: string | null;
  action_type: string | null;
  query: string | null;
  /** URLs the tool actually consulted (from action.sources). */
  sources: string[];
  /** Present only when `includeSearchResults` was requested. */
  results?: unknown;
}

export interface ResponsesCallResult {
  /** The parsed JSON object the model emitted under the strict schema. */
  payload: unknown;
  responseId: string | null;
  model: string;
  webSearchCalls: WebSearchCallRecord[];
  /** Every URL consulted across all web-search calls, de-duplicated. */
  consultedUrls: string[];
  /** URLs the model cited inline in its output message. */
  citedUrls: string[];
  usage: { input_tokens: number | null; output_tokens: number | null; total_tokens: number | null };
  incomplete: boolean;
  refusal: string | null;
  durationMs: number;
}

export class OpenAIResearchError extends Error {
  /** `transient` errors are eligible for exactly one retry. */
  readonly category: "transient" | "permanent" | "timeout" | "refusal" | "malformed";
  readonly status: number | null;
  constructor(
    category: OpenAIResearchError["category"],
    message: string,
    status: number | null = null,
  ) {
    super(message);
    this.name = "OpenAIResearchError";
    this.category = category;
    this.status = status;
  }
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Build the request body. Exported so tests can assert the exact wire shape. */
export function buildResponsesRequestBody(
  opts: Omit<ResponsesCallOptions, "apiKey" | "fetchFn" | "timeoutMs">,
): Record<string, unknown> {
  const webSearchTool: Record<string, unknown> = { type: "web_search" };
  if (opts.searchCountry) {
    webSearchTool.user_location = { type: "approximate", country: opts.searchCountry };
  }
  if (opts.allowedDomains && opts.allowedDomains.length > 0) {
    webSearchTool.filters = { allowed_domains: [...opts.allowedDomains] };
  }

  const include = ["web_search_call.action.sources"];
  if (opts.includeSearchResults) include.push("web_search_call.results");

  return {
    model: opts.model,
    instructions: opts.instructions,
    input: opts.input,
    tools: [webSearchTool],
    tool_choice: "auto",
    include,
    // Stateless: nothing about this lookup is retained by the provider.
    store: false,
    reasoning: { effort: opts.reasoningEffort },
    text: {
      format: {
        type: "json_schema",
        name: CHEMICAL_RESEARCH_SCHEMA_NAME,
        strict: true,
        schema: CHEMICAL_RESEARCH_SCHEMA,
      },
    },
  };
}

function collectWebSearchCalls(output: unknown[]): WebSearchCallRecord[] {
  const calls: WebSearchCallRecord[] = [];
  for (const item of output) {
    if (!isRecord(item) || item.type !== "web_search_call") continue;
    const action = isRecord(item.action) ? item.action : {};
    // `sources` is documented on the action; some payload versions hoist it
    // to the call itself. Read both rather than losing the evidence trail.
    const rawSources = Array.isArray(action.sources)
      ? action.sources
      : Array.isArray((item as Record<string, unknown>).sources)
      ? (item as Record<string, unknown>).sources as unknown[]
      : [];
    const sources = rawSources
      .map((s) => (typeof s === "string" ? s : isRecord(s) ? String(s.url ?? "") : ""))
      .filter((s) => /^https?:\/\//i.test(s));
    const record: WebSearchCallRecord = {
      id: typeof item.id === "string" ? item.id : null,
      status: typeof item.status === "string" ? item.status : null,
      action_type: typeof action.type === "string" ? action.type : null,
      query: typeof action.query === "string" ? action.query : null,
      sources,
    };
    const results = (item as Record<string, unknown>).results ??
      (action as Record<string, unknown>).results;
    if (results !== undefined) record.results = results;
    calls.push(record);
  }
  return calls;
}

function collectMessageText(output: unknown[]): { text: string; cited: string[]; refusal: string | null } {
  let text = "";
  const cited: string[] = [];
  let refusal: string | null = null;
  for (const item of output) {
    if (!isRecord(item) || item.type !== "message") continue;
    const content = Array.isArray(item.content) ? item.content : [];
    for (const part of content) {
      if (!isRecord(part)) continue;
      if (part.type === "refusal" && typeof part.refusal === "string") {
        refusal = part.refusal;
      }
      if (part.type !== "output_text") continue;
      if (typeof part.text === "string") text += part.text;
      const annotations = Array.isArray(part.annotations) ? part.annotations : [];
      for (const ann of annotations) {
        if (!isRecord(ann)) continue;
        const url = ann.url ?? (isRecord(ann.url_citation) ? ann.url_citation.url : null);
        if (typeof url === "string" && /^https?:\/\//i.test(url)) cited.push(url);
      }
    }
  }
  return { text, cited, refusal };
}

/**
 * One Responses API call. No retries here — retry policy lives in
 * `research.ts` so the escalation rules are all in one readable place.
 */
export async function callResponsesApi(
  opts: ResponsesCallOptions,
): Promise<ResponsesCallResult> {
  const startedAt = Date.now();
  const body = buildResponsesRequestBody(opts);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs);

  let res: Response;
  try {
    res = await opts.fetchFn(OPENAI_RESPONSES_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${opts.apiKey}`,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timer);
    const aborted = err instanceof Error &&
      (err.name === "AbortError" || err.name === "TimeoutError");
    throw new OpenAIResearchError(
      aborted ? "timeout" : "transient",
      aborted
        ? `Research request exceeded ${opts.timeoutMs}ms`
        : `Research transport failure: ${err instanceof Error ? err.message : String(err)}`,
    );
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) {
    const detail = (await res.text().catch(() => "")).slice(0, 300);
    // 408/409/429 and 5xx are worth one retry; 4xx config/auth errors are not.
    const transient = res.status === 408 || res.status === 409 ||
      res.status === 429 || res.status >= 500;
    throw new OpenAIResearchError(
      transient ? "transient" : "permanent",
      `OpenAI HTTP ${res.status}: ${detail}`,
      res.status,
    );
  }

  let data: unknown;
  try {
    data = await res.json();
  } catch {
    throw new OpenAIResearchError("malformed", "OpenAI returned a non-JSON body");
  }
  if (!isRecord(data)) {
    throw new OpenAIResearchError("malformed", "OpenAI returned a non-object body");
  }

  const output = Array.isArray(data.output) ? data.output : [];
  const webSearchCalls = collectWebSearchCalls(output);
  const { text, cited, refusal } = collectMessageText(output);

  if (refusal) {
    throw new OpenAIResearchError("refusal", `Model refused the research request: ${refusal}`);
  }

  const status = typeof data.status === "string" ? data.status : "";
  const incomplete = status === "incomplete";

  const flat = typeof data.output_text === "string" && data.output_text.trim()
    ? data.output_text
    : text;
  if (!flat.trim()) {
    throw new OpenAIResearchError(
      "malformed",
      incomplete
        ? "Research response was truncated before any structured output"
        : "Research response contained no structured output",
    );
  }

  let payload: unknown;
  try {
    payload = JSON.parse(flat);
  } catch {
    // Strict schema should make this impossible; treat it as malformed
    // rather than trying to salvage prose (task §28: no loose parsing).
    throw new OpenAIResearchError("malformed", "Structured output was not valid JSON");
  }

  const usageRaw = isRecord(data.usage) ? data.usage : {};
  const num = (v: unknown): number | null => (typeof v === "number" ? v : null);

  const consulted = new Set<string>();
  for (const call of webSearchCalls) for (const s of call.sources) consulted.add(s);
  for (const c of cited) consulted.add(c);

  return {
    payload,
    responseId: typeof data.id === "string" ? data.id : null,
    model: typeof data.model === "string" ? data.model : opts.model,
    webSearchCalls,
    consultedUrls: [...consulted],
    citedUrls: [...new Set(cited)],
    usage: {
      input_tokens: num(usageRaw.input_tokens),
      output_tokens: num(usageRaw.output_tokens),
      total_tokens: num(usageRaw.total_tokens),
    },
    incomplete,
    refusal: null,
    durationMs: Date.now() - startedAt,
  };
}
