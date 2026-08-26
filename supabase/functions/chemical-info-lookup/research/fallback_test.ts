// Task §39 — Terra→Sol fallback and failure-isolation tests.

import { assert, assertEquals } from "jsr:@std/assert@1";

import { readResearchConfig, runChemicalResearch } from "./research.ts";
import { decideEscalation, solTerminalDecision } from "./escalation.ts";
import {
  cloneResearch,
  DITHANE_RESEARCH_PAYLOAD,
  fakeFetch,
  jsonResponse,
  responsesEnvelope,
} from "./test_fixtures.ts";

const config = readResearchConfig(() => undefined);

const enrichment = {
  query: "dithane rainshield",
  countryCode: "AU",
  countryLabel: "Australia",
  mode: "product_enrichment" as const,
  apiKey: "sk-test",
  config,
  useCache: false,
};

Deno.test("§39.1 Terra resolves → Sol is never called", async () => {
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
  ]);
  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
  });

  assertEquals(calls.length, 1);
  assertEquals(calls[0].body.model, "gpt-5.6-terra");
  assertEquals(outcome.telemetry.escalated, false);
  assertEquals(outcome.telemetry.attempts.length, 1);
  assert(outcome.research);
});

Deno.test("§39.2 Terra unresolved with a configured reason → exactly one Sol request", async () => {
  const unresolvedPayload = cloneResearch();
  unresolvedPayload.registration_candidates = [];
  unresolvedPayload.unresolved = ["registration number not found"];

  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(unresolvedPayload, { model: "gpt-5.6-terra" })),
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD, { model: "gpt-5.6-sol" })),
  ]);

  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: false,
  });

  assertEquals(calls.length, 2);
  assertEquals(calls[0].body.model, "gpt-5.6-terra");
  assertEquals(calls[1].body.model, "gpt-5.6-sol");
  assertEquals(outcome.telemetry.escalated, true);
  assert(outcome.telemetry.escalation_reasons.includes("registration_unresolved"));
  // Sol's better answer is the one that survives.
  assertEquals(outcome.research?.registration_candidates[0]?.number, "59688");
});

Deno.test("§39.3 Sol cannot escalate again — the second attempt is terminal", async () => {
  const thin = cloneResearch();
  thin.registration_candidates = [];
  thin.unresolved = ["registration number not found"];

  // BOTH attempts return an unresolved result. A recursive design would loop.
  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(thin, { model: "gpt-5.6-terra" })),
    jsonResponse(responsesEnvelope(thin, { model: "gpt-5.6-sol" })),
  ]);

  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: false,
  });

  assertEquals(calls.length, 2, "at most one Sol attempt, ever");
  assertEquals(outcome.escalation?.terminal, true);
  assertEquals(outcome.escalation?.escalate, false);
  assertEquals(solTerminalDecision(["registration_unresolved"]).escalate, false);
});

// REPLACES "§24 candidate discovery never escalates to Sol".
//
// That rule protected latency mid-search, and it did — while silently capping
// RECALL at whatever the fast model happened to find first. Production showed
// the cost: for "Hortitrol winter oil" Terra returned one candidate, the
// register confirmed that registration genuinely exists, and discovery
// stopped there. "This registration is real" was treated as "this is the
// product they meant", and no alternative could ever be offered because none
// was ever discovered.
//
// Stage C changed WHEN that capability is bought, not whether it is.
//
// Stage A discovered the need for the capable model by spending a whole Terra
// pass and then escalating, which cost two serial frontier requests before a
// single row could be drawn. The escalation CONDITION turned out to be almost
// entirely predictable from the query itself, so it is now decided up front:
// an approximate name the register could not answer goes straight to the
// capable model, once.
//
// These two tests pin both halves of the trade: the capable model for a fuzzy
// name, and the cheap model whenever the answer is already known.
Deno.test("Stage C: a fuzzy discovery query runs ONE capable pass, never two", async () => {
  const thin = cloneResearch();
  thin.registration_candidates = [];

  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(thin)),
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
  ]);

  const outcome = await runChemicalResearch({
    ...enrichment,
    mode: "candidate_discovery",
    fetchFn: fn,
    registerResolved: false,
  });

  // Even a pass that finds NOTHING does not buy a second frontier request:
  // the strongest model has already answered, so there is nowhere to escalate
  // to and a retry would only repeat the same question at the same cost.
  assertEquals(calls.length, 1, "one model request, whatever it returns");
  assertEquals(calls[0].body.model, "gpt-5.6-sol");
  assertEquals(outcome.telemetry.discovery_pass, "single_capable_pass");
  assertEquals(outcome.telemetry.escalated, false);
});

Deno.test("Stage C: discovery stays CHEAP once the register has answered", async () => {
  const thin = cloneResearch();
  thin.registration_candidates = [];

  const { fn, calls } = fakeFetch([jsonResponse(responsesEnvelope(thin))]);

  const outcome = await runChemicalResearch({
    ...enrichment,
    mode: "candidate_discovery",
    fetchFn: fn,
    registerResolved: true,
  });

  assertEquals(calls.length, 1, "the authoritative source already answered");
  assertEquals(calls[0].body.model, "gpt-5.6-terra", "the CHEAP model");
  assertEquals(outcome.telemetry.discovery_pass, "fast_pass");
  assertEquals(outcome.telemetry.escalated, false);
});

Deno.test("Stage C: a bare registration number stays on the cheap model", async () => {
  const thin = cloneResearch();
  thin.registration_candidates = [];

  const { fn, calls } = fakeFetch([jsonResponse(responsesEnvelope(thin))]);

  const outcome = await runChemicalResearch({
    ...enrichment,
    query: "33182",
    mode: "candidate_discovery",
    fetchFn: fn,
    registerResolved: false,
  });

  assertEquals(calls.length, 1);
  assertEquals(calls[0].body.model, "gpt-5.6-terra");
  assertEquals(outcome.telemetry.discovery_pass, "fast_pass");
});

Deno.test("§8 a register-resolved lookup does not spend Sol on a vague research result", async () => {
  const thin = cloneResearch();
  thin.registration_candidates = [];
  thin.active_ingredients = [];

  const { fn, calls } = fakeFetch([jsonResponse(responsesEnvelope(thin))]);
  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
  });

  assertEquals(calls.length, 1);
  assertEquals(outcome.telemetry.escalated, false);
});

Deno.test("§8 a concentration conflict between credible sources escalates once", () => {
  const conflicted = cloneResearch();
  conflicted.active_ingredients = [
    { ...conflicted.active_ingredients[0], concentration: 750 },
    { ...conflicted.active_ingredients[0], concentration: 640 },
  ];
  const decision = decideEscalation({
    research: conflicted,
    registerResolved: false,
    labelMissingForResolvedRegistration: false,
    classified: [],
  });
  assert(decision.escalate);
  assert(decision.reasons.includes("concentration_conflict"));
});

Deno.test("§8 a resolved registration with no label candidate escalates for the label only", () => {
  const decision = decideEscalation({
    research: cloneResearch(),
    registerResolved: true,
    labelMissingForResolvedRegistration: true,
    classified: [],
  });
  assertEquals(decision.reasons, ["label_missing_for_known_registration"]);
});

Deno.test("§31 one transient failure is retried once, then succeeds", async () => {
  let n = 0;
  const { fn, calls } = fakeFetch([
    () => {
      n += 1;
      return n === 1
        ? new Response("overloaded", { status: 503 })
        : jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD));
    },
  ]);

  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
  });

  assertEquals(calls.length, 2);
  assertEquals(outcome.telemetry.attempts[0].retried, true);
  assert(outcome.research);
});

Deno.test("§31 a permanent failure is not retried", async () => {
  const { fn, calls } = fakeFetch([new Response("bad key", { status: 401 })]);
  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
  });
  assertEquals(calls.length, 1);
  assertEquals(outcome.research, null);
  assertEquals(outcome.error?.category, "permanent");
});

Deno.test("§39.4/§30 OpenAI unavailable → research returns null and never throws", async () => {
  const { fn } = fakeFetch([
    () => {
      throw new TypeError("network unreachable");
    },
  ]);
  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
  });
  assertEquals(outcome.research, null);
  assert(outcome.error);
  // The caller sees a normal outcome object, so its register result stands.
  assertEquals(outcome.telemetry.attempts[0].ok, false);
});

Deno.test("§39.5 web search failing mid-response degrades to no research, not a crash", async () => {
  // Tool call failed; the model produced no structured output.
  const { fn } = fakeFetch([
    jsonResponse({
      id: "resp_x",
      model: "gpt-5.6-terra",
      status: "completed",
      output: [{
        type: "web_search_call",
        id: "ws_0",
        status: "failed",
        action: { type: "search", query: "dithane" },
      }],
    }),
  ]);
  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
  });
  assertEquals(outcome.research, null);
  assertEquals(outcome.error?.category, "malformed");
});

Deno.test("§39.6 a timeout fails safely with a timeout category", async () => {
  const { fn } = fakeFetch([
    () =>
      new Promise<Response>((_resolve, reject) => {
        // Mimic fetch's abort rejection.
        const err = new Error("aborted");
        err.name = "AbortError";
        setTimeout(() => reject(err), 5);
      }),
  ]);
  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
  });
  assertEquals(outcome.research, null);
  assertEquals(outcome.error?.category, "timeout");
});

Deno.test("§32 the telemetry line reports whether Sol fired", async () => {
  const thin = cloneResearch();
  thin.registration_candidates = [];
  const { fn } = fakeFetch([
    jsonResponse(responsesEnvelope(thin, { model: "gpt-5.6-terra" })),
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD, { model: "gpt-5.6-sol" })),
  ]);
  const outcome = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: false,
  });

  const { researchLog } = await import("./research.ts");
  const line = researchLog(outcome.telemetry);
  assert(line.includes("primary=gpt-5.6-terra"));
  assert(line.includes("sol=gpt-5.6-sol"));
  assert(line.includes("escalated=true"));
  assert(line.includes("websearch_calls="));
});

Deno.test("§25 identical research inside one workflow is served from cache", async () => {
  const { clearResearchCache } = await import("./research.ts");
  clearResearchCache();

  const { fn, calls } = fakeFetch([
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
    jsonResponse(responsesEnvelope(DITHANE_RESEARCH_PAYLOAD)),
  ]);

  const first = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
    useCache: true,
  });
  const second = await runChemicalResearch({
    ...enrichment,
    fetchFn: fn,
    registerResolved: true,
    useCache: true,
  });

  assertEquals(calls.length, 1, "the same product must not be web-searched twice");
  assertEquals(first.telemetry.cache, "miss");
  assertEquals(second.telemetry.cache, "hit");
  clearResearchCache();
});

Deno.test("§25 the cache key is scoped by country, so AU research never serves NZ", async () => {
  const { clearResearchCache, researchCacheKey } = await import("./research.ts");
  clearResearchCache();

  const au = researchCacheKey("AU", "Dithane Rainshield", "product_enrichment", "gpt-5.6-terra");
  const nz = researchCacheKey("NZ", "Dithane Rainshield", "product_enrichment", "gpt-5.6-terra");
  assert(au !== nz);

  // …and by model, so a model change cannot be served last generation's work.
  const other = researchCacheKey("AU", "Dithane Rainshield", "product_enrichment", "gpt-5.6-sol");
  assert(au !== other);
});
