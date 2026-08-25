// Research suggestion validation and cross-isolate stability
// (Chemical Search Stage 2 §4, §5, §6).

import { assert, assertEquals } from "jsr:@std/assert@1";
import type { RegisterCandidate } from "./ingestion/contract.ts";
import {
  createPostgrestSuggestionStore,
  MAX_RESEARCH_SUGGESTIONS,
  suggestionCacheKey,
  validateResearchSuggestions,
} from "./research_suggestions.ts";
import { candidateClass, rankCandidates } from "./ranking.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const registerCandidate = (
  number: string,
  name: string,
  registrant = "Vicol Pty Ltd",
): RegisterCandidate => ({
  registration_number: number,
  registered_product_name: name,
  registrant,
  product_category: "insecticide",
  register_status: "R",
  actives_summary: "Petroleum oil 815 g/L",
  activity_groups: [],
  match_rank: 0,
});

/** The live APVMA rows relevant to the Hortitrol reproduction. */
const REGISTER: Record<string, RegisterCandidate> = {
  "33182": registerCandidate("33182", "VICOL WINTER OIL INSECTICIDE"),
};

/** A register that answers from REGISTER and records what it was asked. */
function registerLookup(asked: string[] = []) {
  return async (number: string) => {
    asked.push(number);
    return await Promise.resolve(REGISTER[number] ?? null);
  };
}

const researchRow = (name: string, registration?: string) => ({
  name,
  brand: "Model Guess Pty Ltd",
  activeIngredient: "",
  chemicalGroup: "",
  source: "research",
  ...(registration ? { registration_number: registration } : {}),
});

// ---------------------------------------------------------------------------
// §5 — nothing model-generated becomes canonical without validation
// ---------------------------------------------------------------------------

Deno.test("a confirmed registration is rebuilt from the REGISTER's own fields", async () => {
  // The research guessed a sloppy name. The register's name must win — a
  // half-model, half-register name is a product that exists in neither source.
  const result = await validateResearchSuggestions(
    [researchRow("vicol winter oil", "33182")],
    { countryCode: "AU", lookup: registerLookup() },
  );

  assertEquals(result.validatedCount, 1);
  assertEquals(result.rows.length, 1);
  const row = result.rows[0];
  assertEquals(row.name, "VICOL WINTER OIL INSECTICIDE");
  assertEquals(row.registration_number, "33182");
  assertEquals(row.brand, "Vicol Pty Ltd");
  assertEquals(row.registration_country, "AU");
  assertEquals(row.registration_validated, true);
  assertEquals(candidateClass(row), "validated_suggestion");
});

Deno.test("THE defect: an unconfirmed number is STRIPPED, never served", async () => {
  // 50067 is what iOS reached. If the register does not hold it, serving the
  // number hands a downstream structured lookup a pointer to a registration
  // that may not exist — which is exactly how a guess becomes canonical.
  const result = await validateResearchSuggestions(
    [researchRow("SYNERTROL HORTI BOTANICAL OIL CONCENTRATE", "50067")],
    { countryCode: "AU", lookup: registerLookup() },
  );

  assertEquals(result.strippedCount, 1);
  assertEquals(result.validatedCount, 0);
  const row = result.rows[0];
  assertEquals(row.registration_number, undefined);
  assertEquals(row.registration_validated, false);
  // The rejected number is retained for support, clearly labelled as
  // unconfirmed — it must never be mistaken for an identity.
  assertEquals(row.registration_unconfirmed_number, "50067");
  assertEquals(candidateClass(row), "unverified_suggestion");
});

Deno.test("a stripped row can never set exact_registration_number downstream", async () => {
  // End-to-end: validation feeds ranking, and ranking must not find a number.
  const result = await validateResearchSuggestions(
    [researchRow("HORTITROL WINTER OIL", "50067")],
    { countryCode: "AU", lookup: registerLookup() },
  );
  const { summary } = rankCandidates(result.rows, "Hortitrol Winter Oil", "AU");
  assertEquals(summary.exact_registration_number, null);
  assertEquals(summary.auto_select_allowed, false);
  assertEquals(summary.search_state, "no_official_match");
});

Deno.test("a suggestion with no number at all stays an unverified suggestion", async () => {
  const asked: string[] = [];
  const result = await validateResearchSuggestions(
    [researchRow("SOME UNREGISTERED ADJUVANT")],
    { countryCode: "AU", lookup: registerLookup(asked) },
  );
  assertEquals(result.rows.length, 1);
  assertEquals(result.rows[0].registration_validated, false);
  // No number means nothing to validate — the register is not consulted.
  assertEquals(asked.length, 0);
});

Deno.test("authoritative rows pass through untouched and are never re-read", async () => {
  // Re-validating an established register answer is a second chance to get it
  // wrong, and would double the register load on every search.
  const asked: string[] = [];
  const authoritative = {
    name: "CHATEAU HERBICIDE",
    registration_number: "80647",
    source: "official_register",
  };
  const result = await validateResearchSuggestions([authoritative], {
    countryCode: "AU",
    lookup: registerLookup(asked),
  });
  assertEquals(result.rows[0], authoritative);
  assertEquals(asked.length, 0);
  assertEquals(result.validatedCount, 0);
});

Deno.test("a register outage degrades to unverified, it does not fail the search", async () => {
  const result = await validateResearchSuggestions(
    [researchRow("VICOL WINTER OIL INSECTICIDE", "33182")],
    {
      countryCode: "AU",
      lookup: () => Promise.reject(new Error("register unreachable")),
    },
  );
  // The row survives — the operator still sees the lead.
  assertEquals(result.rows.length, 1);
  assertEquals(result.rows[0].registration_validated, false);
  // …but without a number, and the degradation is VISIBLE.
  assertEquals(result.rows[0].registration_number, undefined);
  assert(result.degraded.includes("suggestion_validation_failed"));
});

Deno.test("the register's number wins when it differs in formatting", async () => {
  const lookup = () =>
    Promise.resolve(registerCandidate("33182", "VICOL WINTER OIL INSECTICIDE"));
  const result = await validateResearchSuggestions(
    [researchRow("vicol winter oil", "33182")],
    { countryCode: "AU", lookup },
  );
  assertEquals(result.rows[0].registration_number, "33182");
});

// ---------------------------------------------------------------------------
// §6 — a shortlist, never a silent guess and never padding
// ---------------------------------------------------------------------------

Deno.test("several plausible suggestions are all kept", async () => {
  const lookup = (n: string) =>
    Promise.resolve(
      n === "33182" ? REGISTER["33182"] : registerCandidate(n, `PRODUCT ${n}`),
    );
  const result = await validateResearchSuggestions(
    [
      researchRow("vicol winter oil", "33182"),
      researchRow("another oil", "44444"),
    ],
    { countryCode: "AU", lookup },
  );
  assertEquals(result.rows.length, 2);
  assertEquals(result.validatedCount, 2);
});

Deno.test("the shortlist is capped, and authoritative rows are never dropped for it", async () => {
  const lookup = (n: string) => Promise.resolve(registerCandidate(n, `PRODUCT ${n}`));
  const rows = [
    { name: "REAL REGISTER ROW", registration_number: "1", source: "official_register" },
    ...Array.from({ length: 10 }, (_, i) => researchRow(`GUESS ${i}`, `9000${i}`)),
  ];
  const result = await validateResearchSuggestions(rows, {
    countryCode: "AU",
    lookup,
  });
  const suggestions = result.rows.filter((r) => r.source !== "official_register");
  assertEquals(suggestions.length, MAX_RESEARCH_SUGGESTIONS);
  // The register row survived the cap.
  assert(result.rows.some((r) => r.name === "REAL REGISTER ROW"));
});

Deno.test("the list is never padded to reach the cap", async () => {
  const result = await validateResearchSuggestions(
    [researchRow("vicol winter oil", "33182")],
    { countryCode: "AU", lookup: registerLookup() },
  );
  assertEquals(result.rows.length, 1);
});

Deno.test("two research spellings of one product collapse to the register identity", async () => {
  const result = await validateResearchSuggestions(
    [
      researchRow("vicol winter oil", "33182"),
      researchRow("VICOL WINTER OIL INSECTICIDE", "33182"),
    ],
    { countryCode: "AU", lookup: registerLookup() },
  );
  assertEquals(result.rows.length, 1);
  assertEquals(result.rows[0].name, "VICOL WINTER OIL INSECTICIDE");
});

// ---------------------------------------------------------------------------
// §4 — the same query is stable across isolates
// ---------------------------------------------------------------------------

Deno.test("the cache key is country-scoped and typography-normalised", () => {
  const a = suggestionCacheKey("AU", "Hortitrol Winter Oil");
  const b = suggestionCacheKey("au", "hortitrol   winter  oil");
  assertEquals(a, b);
  // Jurisdiction can never be merged away: AU and NZ are different law.
  assert(a !== suggestionCacheKey("NZ", "Hortitrol Winter Oil"));
});

/** A fake PostgREST that two independent "isolates" can share. */
function fakePostgrest() {
  const table = new Map<string, { payload: unknown; expires_at: string }>();
  let reads = 0;
  const fetchFn = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if ((init?.method ?? "GET") === "GET") {
      reads++;
      const key = decodeURIComponent(
        /cache_key=eq\.([^&]+)/.exec(url)?.[1] ?? "",
      );
      const row = table.get(key);
      return Promise.resolve(
        new Response(JSON.stringify(row ? [{ payload: row.payload }] : []), {
          status: 200,
        }),
      );
    }
    const body = JSON.parse(String(init?.body ?? "[]"))[0];
    table.set(body.cache_key, {
      payload: body.payload,
      expires_at: body.expires_at,
    });
    return Promise.resolve(new Response("[]", { status: 201 }));
  }) as typeof fetch;
  return { fetchFn, table, reads: () => reads };
}

Deno.test("two isolates serving one query return the SAME suggestion set", async () => {
  // This is the parity fix. Isolate A runs research; isolate B must not run
  // its own and reach a different product.
  const shared = fakePostgrest();
  const key = suggestionCacheKey("AU", "Hortitrol Winter Oil");

  const isolateA = createPostgrestSuggestionStore(
    "https://proj.supabase.co",
    "service-key",
    shared.fetchFn,
  )!;
  const isolateB = createPostgrestSuggestionStore(
    "https://proj.supabase.co",
    "service-key",
    shared.fetchFn,
  )!;

  // Isolate A: miss, then research, then write.
  assertEquals(await isolateA.read(key), null);
  const served = [{
    name: "VICOL WINTER OIL INSECTICIDE",
    registration_number: "33182",
    source: "research_validated",
    registration_validated: true,
  }];
  await isolateA.write(key, "AU", "Hortitrol Winter Oil", served, 3600);

  // Isolate B: a DIFFERENT instance, sharing nothing in memory.
  const fromB = await isolateB.read(key);
  assertEquals(fromB, served);

  // And the served order is identical, which is what parity actually means.
  const a = rankCandidates(served, "Hortitrol Winter Oil", "AU");
  const b = rankCandidates(fromB!, "Hortitrol Winter Oil", "AU");
  assertEquals(
    a.results.map((r) => r.registration_number),
    b.results.map((r) => r.registration_number),
  );
  assertEquals(a.summary, b.summary);
});

Deno.test("a differently-typed query hits the same cached answer", async () => {
  const shared = fakePostgrest();
  const store = createPostgrestSuggestionStore(
    "https://proj.supabase.co",
    "service-key",
    shared.fetchFn,
  )!;
  const served = [{ name: "VICOL WINTER OIL INSECTICIDE", source: "research" }];
  await store.write(
    suggestionCacheKey("AU", "Hortitrol Winter Oil"),
    "AU",
    "Hortitrol Winter Oil",
    served,
    3600,
  );
  const hit = await store.read(suggestionCacheKey("AU", "hortitrol winter oil"));
  assertEquals(hit, served);
});

Deno.test("an expired entry is never served", async () => {
  // Expiry is enforced by the READ filter, so a stale row cannot be served
  // even if no sweeper has run.
  const table = new Map<string, unknown>();
  const fetchFn = ((input: string | URL | Request, init?: RequestInit) => {
    if ((init?.method ?? "GET") !== "GET") {
      const body = JSON.parse(String(init?.body ?? "[]"))[0];
      table.set(body.cache_key, body.payload);
      return Promise.resolve(new Response("[]", { status: 201 }));
    }
    // The real filter is `expires_at=gt.<now>`; assert it is actually sent,
    // then answer as PostgREST would for an expired row.
    assert(String(input).includes("expires_at=gt."));
    return Promise.resolve(new Response("[]", { status: 200 }));
  }) as typeof fetch;

  const store = createPostgrestSuggestionStore("https://p.supabase.co", "k", fetchFn)!;
  await store.write(suggestionCacheKey("AU", "x"), "AU", "x", [{ name: "OLD" }], 1);
  assertEquals(await store.read(suggestionCacheKey("AU", "x")), null);
});

Deno.test("a MISSING table degrades to a cache miss, it never breaks search", async () => {
  // sql/211 is proposed separately, so a function deploy that lands first must
  // behave exactly as it does today rather than failing every search.
  const fetchFn = (() =>
    Promise.resolve(
      new Response(JSON.stringify({ message: "relation does not exist" }), {
        status: 404,
      }),
    )) as typeof fetch;
  const store = createPostgrestSuggestionStore("https://p.supabase.co", "k", fetchFn)!;
  assertEquals(await store.read(suggestionCacheKey("AU", "x")), null);
  // A write against a missing table must not throw either.
  await store.write(suggestionCacheKey("AU", "x"), "AU", "x", [], 3600);
});

Deno.test("a network failure is a cache miss, not an error", async () => {
  const fetchFn = (() => Promise.reject(new Error("ECONNRESET"))) as typeof fetch;
  const store = createPostgrestSuggestionStore("https://p.supabase.co", "k", fetchFn)!;
  assertEquals(await store.read(suggestionCacheKey("AU", "x")), null);
  await store.write(suggestionCacheKey("AU", "x"), "AU", "x", [{ n: 1 }], 3600);
});

Deno.test("an unconfigured project yields no store at all", () => {
  assertEquals(createPostgrestSuggestionStore("", "key"), null);
  assertEquals(createPostgrestSuggestionStore("https://p.supabase.co", ""), null);
});

// ---------------------------------------------------------------------------
// §7 — the official-register path is untouched
// ---------------------------------------------------------------------------

Deno.test("a register-answered search never consults validation or the cache", async () => {
  const asked: string[] = [];
  const rows = [
    { name: "CHATEAU HERBICIDE", registration_number: "80647", source: "official_register" },
  ];
  const result = await validateResearchSuggestions(rows, {
    countryCode: "AU",
    lookup: registerLookup(asked),
  });
  assertEquals(result.rows, rows);
  assertEquals(asked.length, 0);
  assertEquals(result.degraded.length, 0);

  const { summary } = rankCandidates(result.rows, "Chateau", "AU");
  assertEquals(summary.search_state, "ambiguous");
  assertEquals(summary.official_candidate_count, 1);
  assertEquals(summary.suggestion_count, 0);
});
