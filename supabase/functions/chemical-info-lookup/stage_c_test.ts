// Stage C — discovery / selection / enrichment boundary and latency.
//
// The defect, stated once: a product search could enter the structured
// lookup's stages — register resolution, product enrichment, page inspection,
// PDF download, PDF extraction — and each of those has its own multi-second
// timeout. Two serial frontier model calls sat in front of them. A simple
// search therefore became a multi-minute operation that ended in a 502.
//
// These tests pin the boundary (search never enters an enrichment stage), the
// call budget (one model request for a fuzzy name), and the two caches that
// stop the same work being paid for twice.

import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";

import {
  LookupTimer,
  STRUCTURED_ONLY_STAGES,
  structuredOnlyStagesEntered,
} from "./timings.ts";
import {
  cachedEnrichmentIsUsable,
  createPostgrestEnrichmentCache,
  ENRICHMENT_CACHE_TTL_SECONDS,
  ENRICHMENT_CACHE_VERSION,
  enrichmentCacheKey,
} from "./ingestion/enrichment_cache.ts";
import {
  CANDIDATE_DISCOVERY_CACHE_VERSION,
  SUGGESTION_CACHE_TTL_SECONDS,
  suggestionCacheKey,
} from "./research_suggestions.ts";
import { planCandidateDiscovery, readResearchConfig } from "./research/research.ts";
import { candidateClass } from "./ranking.ts";

const config = readResearchConfig(() => undefined);

// ===========================================================================
// A — search must be search-only
// ===========================================================================

Deno.test("A: a search that entered no enrichment stage reports exactly that", () => {
  let clock = 0;
  const timer = new LookupTimer(() => clock);

  // What a search legitimately does.
  timer.add("search_register", 180);
  timer.add("model_discovery", 2400);
  timer.add("registration_validation", 260);
  clock = 2900;

  assertEquals(structuredOnlyStagesEntered(timer), [], "search stayed in its lane");

  const snap = timer.snapshot();
  assertEquals(snap.stages.search_register, 180);
  assertEquals(snap.stages.model_discovery, 2400);
  assertEquals(snap.stages.registration_validation, 260);
  assertEquals(snap.total_ms, 2900);

  // The stages that make a lookup slow were never entered.
  for (const stage of STRUCTURED_ONLY_STAGES) {
    assertFalse(timer.entered(stage), `search must never enter ${stage}`);
  }
});

Deno.test("A2: entering a PDF stage during search is DETECTED, not silently tolerated", () => {
  // The guard has to be able to fail, or it proves nothing.
  const timer = new LookupTimer(() => 0);
  timer.add("search_register", 10);
  timer.add("pdf_extraction", 9000);

  assertEquals(structuredOnlyStagesEntered(timer), ["pdf_extraction"]);
});

Deno.test("A3: a stage that THREW still records the time it consumed", () => {
  // A timeout is precisely the case a latency investigation most needs, and it
  // is exactly the case a naive stopwatch loses.
  let clock = 0;
  const timer = new LookupTimer(() => clock);

  return timer
    .time("pdf_download", () => {
      clock = 6000;
      return Promise.reject(new Error("registrant host timed out"));
    })
    .then(
      () => {
        throw new Error("the rejection should have propagated");
      },
      () => {
        assertEquals(timer.snapshot().stages.pdf_download, 6000);
      },
    );
});

// ===========================================================================
// B — one model call for an approximate name
// ===========================================================================

Deno.test("B: an approximate name is planned as ONE capable pass", () => {
  const plan = planCandidateDiscovery({
    query: "Hortitrol Winter Oil",
    registerResolved: false,
    config,
  });
  assertEquals(plan.kind, "single_capable_pass");
  assertEquals(plan.model, config.fallbackModel);
  assert(plan.model !== config.model, "not the cheap model");
});

Deno.test("B2: exact and already-answered queries stay on the cheap model", () => {
  const code = planCandidateDiscovery({
    query: "33182",
    registerResolved: false,
    config,
  });
  assertEquals(code.kind, "fast_pass");
  assertEquals(code.model, config.model);

  const answered = planCandidateDiscovery({
    query: "Hortitrol Winter Oil",
    registerResolved: true,
    config,
  });
  assertEquals(answered.kind, "fast_pass");
  assertEquals(answered.model, config.model);
});

// ===========================================================================
// C — candidate cache TTL
// ===========================================================================

Deno.test("C: validated candidate identities are cached for a day, not an hour", () => {
  assertEquals(SUGGESTION_CACHE_TTL_SECONDS, 24 * 60 * 60);
  // The version segment remains the immediate invalidation lever.
  assert(suggestionCacheKey("AU", "Hortitrol Winter Oil")
    .includes(CANDIDATE_DISCOVERY_CACHE_VERSION));
});

// ===========================================================================
// D — a candidate with no registration is never a "registered product"
// ===========================================================================

Deno.test("D: a name-only suggestion is classified unverified, never registered", () => {
  // Exactly the shape of the unresolved saved chemical sitting in production:
  // a name, no registration number, no validation.
  const nameOnly = { name: "Hortitrol Winter Oil", source: "research" };
  assertEquals(candidateClass(nameOnly, "AU"), "unverified_suggestion");

  // A number the register REFUSED to confirm is also not a registered product.
  const stripped = {
    name: "Hortitrol Winter Oil",
    source: "research",
    registration_validated: false,
    registration_unconfirmed_number: "99999",
  };
  assertEquals(candidateClass(stripped, "AU"), "unverified_suggestion");

  // Only register confirmation earns the validated class.
  const confirmed = {
    name: "VICOL WINTER OIL INSECTICIDE",
    source: "research_validated",
    registration_number: "33182",
    registration_country: "AU",
    registration_validated: true,
  };
  assertEquals(candidateClass(confirmed, "AU"), "validated_suggestion");
});

// ===========================================================================
// G — the exact-registration enrichment cache
// ===========================================================================

Deno.test("G: the cache is keyed by exact identity, never by a typed name", () => {
  const key = enrichmentCacheKey("AU", "apvma", "33182");
  assertEquals(key, `AU:apvma:33182::${ENRICHMENT_CACHE_VERSION}`);

  // Case and spacing of the operator's query cannot reach this key at all.
  assertEquals(enrichmentCacheKey("au", "APVMA", " 33182 "), key);

  // Country and scheme are never merged away.
  assert(enrichmentCacheKey("NZ", "apvma", "33182") !== key);
  assert(enrichmentCacheKey("AU", "acvm", "33182") !== key);
});

Deno.test("G2: a parser-contract bump retires every stored entry", () => {
  const key = enrichmentCacheKey("AU", "apvma", "33182");
  assert(key.includes(ENRICHMENT_CACHE_VERSION));
  // A result produced by a previous parser generation is not addressable, so a
  // parser fix can never be masked by the output of the parser it fixed.
  assertFalse(key.includes("enrichment-v0"));
});

Deno.test("G3: a fresh cached enrichment prevents the web + PDF pipeline", async () => {
  const calls: { url: string; method: string }[] = [];
  const payload = {
    manufacturer_product_url: "https://www.vicchem.com/product_detail?pn=19200",
    manufacturer_label_url: "https://www.vicchem.com/prods/label/VICOLWOLabel.pdf",
    regulator_label_url: "https://portal.apvma.gov.au/elabels/33182.PDF",
    registered_uses: [{
      crop: "Grapes",
      target: "Grapevine Scale",
      rates: [{ basis: "per_100_litres", value: 2, unit: "L", label: "Tas", raw_text: "2 L / 100 L" }],
    }],
    withholding_period_days: 1,
    re_entry_period_hours: null,
    practical_source: "manufacturer_label",
    source_fingerprint: "abc123",
    parser_version: ENRICHMENT_CACHE_VERSION,
    refreshed_at: new Date().toISOString(),
  };

  const store = createPostgrestEnrichmentCache(
    "https://project.supabase.co",
    "service-key",
    ((input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), method: init?.method ?? "GET" });
      return Promise.resolve(
        new Response(JSON.stringify([{ payload }]), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      );
    }) as typeof fetch,
  );
  assert(store);

  const hit = await store.read(enrichmentCacheKey("AU", "apvma", "33182"));
  assert(hit, "a fresh entry is served");
  assertEquals(hit.practical_source, "manufacturer_label");
  assertEquals(hit.withholding_period_days, 1);

  // ONE PostgREST read. No research call, no page fetch, no PDF download.
  assertEquals(calls.length, 1);
  assertEquals(calls[0].method, "GET");
  assert(calls[0].url.includes("chemical_enrichment_cache"));
  // Expiry is enforced in the QUERY, so a stale row is never returned.
  assert(calls[0].url.includes("expires_at=gt."));

  assert(cachedEnrichmentIsUsable(hit));
});

Deno.test("G4: an enrichment carrying no usable rate is not worth a fast path", () => {
  // Caching a MISS would make "we found nothing" sticky for a week, which is
  // the opposite of what a lookup with no rates should do.
  assertFalse(cachedEnrichmentIsUsable(null));
  assertFalse(cachedEnrichmentIsUsable({
    registered_uses: [],
  } as never));
  assertFalse(cachedEnrichmentIsUsable({
    registered_uses: [{ crop: "Grapes", rates: [{ basis: "other", raw_text: "see label" }] }],
  } as never));
});

Deno.test("G5: a cache outage degrades to doing the work, never to failing", async () => {
  const store = createPostgrestEnrichmentCache(
    "https://project.supabase.co",
    "service-key",
    (() => Promise.reject(new Error("network down"))) as typeof fetch,
  );
  assert(store);

  // Both directions swallow the failure: a missing table (the deploy-before-
  // migration case) must not break a lookup.
  assertEquals(await store.read("any"), null);
  await store.write(
    "any",
    { countryCode: "AU", scheme: "apvma", registrationNumber: "33182" },
    { registered_uses: [] } as never,
    ENRICHMENT_CACHE_TTL_SECONDS,
  );
});

Deno.test("G6: the cache is unavailable without service-role credentials", () => {
  // It must never fall back to an anon key: this table is service-role only.
  assertEquals(createPostgrestEnrichmentCache("", "key"), null);
  assertEquals(createPostgrestEnrichmentCache("https://project.supabase.co", ""), null);
});
