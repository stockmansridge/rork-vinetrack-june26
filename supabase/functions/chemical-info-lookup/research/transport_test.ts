// Task §38 — OpenAI transport tests.
//
// These prove the SHAPE of what we send and how we read what comes back.
// They do not, and cannot, prove anything about what the live model says:
// there is no API key in this environment, so every response here is a
// fixture written by hand.

import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";

import {
  buildResponsesRequestBody,
  callResponsesApi,
  DEFAULT_RESEARCH_FALLBACK_MODEL,
  DEFAULT_RESEARCH_MODEL,
  OPENAI_RESPONSES_URL,
  OpenAIResearchError,
} from "./responses_client.ts";
import { CHEMICAL_RESEARCH_SCHEMA_NAME } from "./schema.ts";
import { readResearchConfig, runChemicalResearch } from "./research.ts";
import {
  cloneResearch,
  DITHANE_RESEARCH_PAYLOAD,
  fakeFetch,
  jsonResponse,
  responsesEnvelope,
} from "./test_fixtures.ts";

const baseOpts = {
  instructions: "instructions",
  input: "input",
  reasoningEffort: "medium" as const,
  searchCountry: "AU",
};

Deno.test("§38.1 research posts to /v1/responses, never to chat completions", async () => {
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
  ]);
  await callResponsesApi({
    ...baseOpts,
    model: DEFAULT_RESEARCH_MODEL,
    apiKey: "sk-test",
    fetchFn: fn,
    timeoutMs: 5000,
  });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, OPENAI_RESPONSES_URL);
  assertEquals(calls[0].url, "https://api.openai.com/v1/responses");
  assert(!calls[0].url.includes("chat/completions"));
});

Deno.test("§38.2 default research model is gpt-5.6-terra, fallback is gpt-5.6-sol", () => {
  assertEquals(DEFAULT_RESEARCH_MODEL, "gpt-5.6-terra");
  assertEquals(DEFAULT_RESEARCH_FALLBACK_MODEL, "gpt-5.6-sol");

  const config = readResearchConfig(() => undefined);
  assertEquals(config.model, "gpt-5.6-terra");
  assertEquals(config.fallbackModel, "gpt-5.6-sol");
  assertEquals(config.enabled, true);
});

Deno.test("§38.2 the bare gpt-5.6 alias is never the default (it routes to Sol)", () => {
  const config = readResearchConfig(() => undefined);
  assert(config.model !== "gpt-5.6", "default must be explicit Terra, not the Sol-routing alias");
});

Deno.test("§38.3 the built-in web_search tool is enabled on every research call", () => {
  const body = buildResponsesRequestBody({ ...baseOpts, model: DEFAULT_RESEARCH_MODEL });
  const tools = body.tools as { type: string }[];
  assertEquals(tools.length, 1);
  assertEquals(tools[0].type, "web_search");
  assertEquals(body.tool_choice, "auto");
});

Deno.test("§38.4 source metadata is requested via include", () => {
  const body = buildResponsesRequestBody({ ...baseOpts, model: DEFAULT_RESEARCH_MODEL });
  const include = body.include as string[];
  assert(include.includes("web_search_call.action.sources"));
  assert(
    !include.includes("web_search_call.results"),
    "full result bodies stay off unless debugging asks for them",
  );

  const debugBody = buildResponsesRequestBody({
    ...baseOpts,
    model: DEFAULT_RESEARCH_MODEL,
    includeSearchResults: true,
  });
  assert((debugBody.include as string[]).includes("web_search_call.results"));
});

Deno.test("§38.5 output is bound by a strict JSON schema, not json_object mode", () => {
  const body = buildResponsesRequestBody({ ...baseOpts, model: DEFAULT_RESEARCH_MODEL });
  const text = body.text as { format: Record<string, unknown> };
  assertEquals(text.format.type, "json_schema");
  assertEquals(text.format.strict, true);
  assertEquals(text.format.name, CHEMICAL_RESEARCH_SCHEMA_NAME);
  assert(text.format.schema, "the schema itself must travel with the request");
  assertEquals((body as Record<string, unknown>).response_format, undefined);
});

Deno.test("§27 research is stateless — store:false and no conversation history", () => {
  const body = buildResponsesRequestBody({ ...baseOpts, model: DEFAULT_RESEARCH_MODEL });
  assertEquals(body.store, false);
  assertEquals((body as Record<string, unknown>).previous_response_id, undefined);
  assertEquals(typeof body.input, "string");
});

Deno.test("§3 reasoning effort is explicit and modest by default", () => {
  const body = buildResponsesRequestBody({ ...baseOpts, model: DEFAULT_RESEARCH_MODEL });
  assertEquals(body.reasoning, { effort: "medium" });
});

Deno.test("§24 candidate discovery runs at low effort, enrichment at medium", async () => {
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
  ]);
  const config = readResearchConfig(() => undefined);

  await runChemicalResearch({
    query: "dithane rainshield",
    countryCode: "AU",
    countryLabel: "Australia",
    mode: "candidate_discovery",
    apiKey: "sk-test",
    fetchFn: fn,
    config,
    registerResolved: false,
    useCache: false,
  });
  assertEquals((calls[0].body.reasoning as { effort: string }).effort, "low");

  await runChemicalResearch({
    query: "dithane rainshield",
    countryCode: "AU",
    countryLabel: "Australia",
    mode: "product_enrichment",
    apiKey: "sk-test",
    fetchFn: fn,
    config,
    registerResolved: true,
    useCache: false,
  });
  assertEquals((calls[1].body.reasoning as { effort: string }).effort, "medium");
});

Deno.test("§38.7 a legacy OPENAI_MODEL=gpt-4o cannot route research to gpt-4o", () => {
  const env = (k: string) => (k === "OPENAI_MODEL" ? "gpt-4o" : undefined);
  const config = readResearchConfig(env);
  assertEquals(config.model, "gpt-5.6-terra");
  assertEquals(config.fallbackModel, "gpt-5.6-sol");
});

Deno.test("§26 explicit research env vars override the defaults", () => {
  const env = (k: string) => {
    if (k === "CHEMICAL_RESEARCH_MODEL") return "gpt-5.6-luna";
    if (k === "CHEMICAL_RESEARCH_FALLBACK_MODEL") return "gpt-5.6-terra";
    return undefined;
  };
  const config = readResearchConfig(env);
  assertEquals(config.model, "gpt-5.6-luna");
  assertEquals(config.fallbackModel, "gpt-5.6-terra");
});

Deno.test("§44 the feature flag can fall the research path back", () => {
  assertEquals(readResearchConfig((k) => k === "CHEMICAL_RESEARCH_RESPONSES_ENABLED" ? "false" : undefined).enabled, false);
  assertEquals(readResearchConfig((k) => k === "CHEMICAL_RESEARCH_RESPONSES_ENABLED" ? "true" : undefined).enabled, true);
});

Deno.test("§38.8 the API key travels in the Authorization header and never in the body", async () => {
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
  ]);
  await callResponsesApi({
    ...baseOpts,
    model: DEFAULT_RESEARCH_MODEL,
    apiKey: "sk-secret-value",
    fetchFn: fn,
    timeoutMs: 5000,
  });
  const headers = calls[0].init.headers as Record<string, string>;
  assertEquals(headers.Authorization, "Bearer sk-secret-value");
  const serialisedBody = String(calls[0].init.body);
  assert(
    !serialisedBody.includes("sk-secret-value"),
    "the key must never be serialised into the request body",
  );
});

Deno.test("§4 web-search sources and citations are collected from the response", async () => {
  const sources = [
    "https://portal.apvma.gov.au/pubcris?p_id=1",
    "https://elabels.apvma.gov.au/59688.pdf",
  ];
  const { fn } = fakeFetch([
    jsonResponse(
      responsesEnvelope(DITHANE_RESEARCH_PAYLOAD, {
        searchQueries: ["dithane rainshield apvma", "mancozeb 750 g/kg label"],
        sources,
      }),
    ),
  ]);
  const result = await callResponsesApi({
    ...baseOpts,
    model: DEFAULT_RESEARCH_MODEL,
    apiKey: "sk-test",
    fetchFn: fn,
    timeoutMs: 5000,
  });
  assertEquals(result.webSearchCalls.length, 2);
  assertEquals(result.webSearchCalls[0].query, "dithane rainshield apvma");
  assertEquals(result.webSearchCalls[0].sources, sources);
  assertEquals(result.consultedUrls.length, 2);
  assertEquals(result.citedUrls.length, 2);
});

Deno.test("§29 response id, model and token usage are captured for debugging", async () => {
  const { fn } = fakeFetch([
    jsonResponse(
      responsesEnvelope(DITHANE_RESEARCH_PAYLOAD, {
        id: "resp_abc123",
        model: "gpt-5.6-terra",
        usage: { input_tokens: 4321, output_tokens: 999 },
      }),
    ),
  ]);
  const result = await callResponsesApi({
    ...baseOpts,
    model: DEFAULT_RESEARCH_MODEL,
    apiKey: "sk-test",
    fetchFn: fn,
    timeoutMs: 5000,
  });
  assertEquals(result.responseId, "resp_abc123");
  assertEquals(result.model, "gpt-5.6-terra");
  assertEquals(result.usage.input_tokens, 4321);
  assertEquals(result.usage.output_tokens, 999);
});

Deno.test("a model refusal is surfaced as a refusal, not parsed as data", async () => {
  const { fn } = fakeFetch([
    jsonResponse({
      id: "resp_r",
      model: "gpt-5.6-terra",
      status: "completed",
      output: [{
        type: "message",
        content: [{ type: "refusal", refusal: "I can't help with that" }],
      }],
    }),
  ]);
  const err = await assertRejects(
    () =>
      callResponsesApi({
        ...baseOpts,
        model: DEFAULT_RESEARCH_MODEL,
        apiKey: "sk-test",
        fetchFn: fn,
        timeoutMs: 5000,
      }),
    OpenAIResearchError,
  );
  assertEquals(err.category, "refusal");
});

Deno.test("a 401 is permanent and a 503 is transient", async () => {
  const unauthorised = fakeFetch([new Response("nope", { status: 401 })]);
  const e1 = await assertRejects(
    () =>
      callResponsesApi({
        ...baseOpts,
        model: DEFAULT_RESEARCH_MODEL,
        apiKey: "bad",
        fetchFn: unauthorised.fn,
        timeoutMs: 5000,
      }),
    OpenAIResearchError,
  );
  assertEquals(e1.category, "permanent");

  const down = fakeFetch([new Response("upstream", { status: 503 })]);
  const e2 = await assertRejects(
    () =>
      callResponsesApi({
        ...baseOpts,
        model: DEFAULT_RESEARCH_MODEL,
        apiKey: "sk-test",
        fetchFn: down.fn,
        timeoutMs: 5000,
      }),
    OpenAIResearchError,
  );
  assertEquals(e2.category, "transient");
});

Deno.test("§11/§12 the prompt states the country's source priority", async () => {
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(cloneResearch())),
    jsonResponse(responsesEnvelope(cloneResearch())),
  ]);
  const config = readResearchConfig(() => undefined);

  await runChemicalResearch({
    query: "dithane",
    countryCode: "AU",
    countryLabel: "Australia",
    mode: "candidate_discovery",
    apiKey: "sk-test",
    fetchFn: fn,
    config,
    registerResolved: false,
    useCache: false,
  });
  assertStringIncludes(String(calls[0].body.instructions), "apvma.gov.au");

  await runChemicalResearch({
    query: "captan",
    countryCode: "NZ",
    countryLabel: "New Zealand",
    mode: "candidate_discovery",
    apiKey: "sk-test",
    fetchFn: fn,
    config,
    registerResolved: false,
    useCache: false,
  });
  const nzInstructions = String(calls[1].body.instructions);
  assertStringIncludes(nzInstructions, "mpi.govt.nz");
  assertStringIncludes(nzInstructions, "NEVER evidence for New Zealand");
});
