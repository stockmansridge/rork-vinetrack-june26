import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildDiagnostics,
  type CandidateDiagnostic,
  diagnosticsLog,
  lookupVersion,
  newRequestId,
  normaliseClientPlatform,
  projectRef,
  readClientContext,
} from "./diagnostics.ts";

const envOf = (map: Record<string, string>) => (k: string) => map[k];

Deno.test("lookupVersion reports the deployed SHA", () => {
  assertEquals(lookupVersion(envOf({ LOOKUP_GIT_SHA: "a1b2c3d" })), "a1b2c3d");
});

Deno.test("lookupVersion is a STABLE 'unknown' when unset", () => {
  // A generated stand-in would differ per isolate and make one deployment
  // look like several builds during a parity investigation.
  assertEquals(lookupVersion(envOf({})), "unknown");
  assertEquals(lookupVersion(envOf({ LOOKUP_GIT_SHA: "   " })), "unknown");
});

Deno.test("projectRef extracts the public subdomain only", () => {
  assertEquals(
    projectRef(envOf({ SUPABASE_URL: "https://abcdefghijkl.supabase.co" })),
    "abcdefghijkl",
  );
});

Deno.test("projectRef never leaks a URL or guesses", () => {
  assertEquals(projectRef(envOf({})), "unknown");
  assertEquals(projectRef(envOf({ SUPABASE_URL: "not a url" })), "unknown");
});

Deno.test("client platform normalises onto the closed set", () => {
  assertEquals(normaliseClientPlatform("iOS"), "ios");
  assertEquals(normaliseClientPlatform("iPhone"), "ios");
  assertEquals(normaliseClientPlatform("Android"), "android");
  assertEquals(normaliseClientPlatform("portal"), "portal");
  assertEquals(normaliseClientPlatform("web"), "portal");
  assertEquals(normaliseClientPlatform("Lovable"), "portal");
  assertEquals(normaliseClientPlatform("toaster"), "unknown");
  assertEquals(normaliseClientPlatform(undefined), "unknown");
});

Deno.test("readClientContext accepts snake_case and camelCase", () => {
  const a = readClientContext({
    client: { platform: "ios", app_version: "2.14.0", app_build: "1487" },
  });
  assertEquals(a.platform, "ios");
  assertEquals(a.appVersion, "2.14.0");
  assertEquals(a.appBuild, "1487");

  const b = readClientContext({
    client: { platform: "portal", appVersion: "1.0.3", appBuild: "9" },
  });
  assertEquals(b.appVersion, "1.0.3");
  assertEquals(b.appBuild, "9");
});

Deno.test("readClientContext never fails on a hostile or empty body", () => {
  // Diagnostics must not be able to break a lookup.
  const empty = readClientContext({});
  assertEquals(empty.platform, "unknown");
  assertEquals(empty.appVersion, null);

  assertEquals(readClientContext(undefined).platform, "unknown");
  assertEquals(readClientContext({ client: "nonsense" }).platform, "unknown");
  assertEquals(readClientContext({ client: { platform: 42 } }).platform, "unknown");

  const long = readClientContext({ client: { app_version: "x".repeat(500) } });
  assert((long.appVersion ?? "").length <= 64, "unbounded client text reached the log stream");
});

Deno.test("request ids are unique", () => {
  const a = newRequestId();
  const b = newRequestId();
  assert(a !== b);
  assert(a.length >= 32);
});

const candidates: CandidateDiagnostic[] = [
  {
    registrationNumber: "50067",
    name: "HORTITROL WINTER OIL",
    source: "official_register",
    score: 100,
    reason: "exact_name",
  },
  {
    registrationNumber: "33182",
    name: "SOME OTHER WINTER OIL",
    source: "official_register",
    score: 40,
    reason: "contained_phrase",
  },
  {
    registrationNumber: null,
    name: "AI suggestion",
    source: "ai",
    score: null,
    reason: null,
  },
];

Deno.test("diagnostics records candidate registrations IN SERVED ORDER", () => {
  // The whole point of the envelope: parity is one comparison, not a debate.
  const d = buildDiagnostics({
    requestId: "req-1",
    client: readClientContext({ client: { platform: "ios", app_version: "2.14.0" } }),
    action: "search",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "Hortitrol winter oil",
    candidates,
    method: "official_register",
    startedAt: 1_000,
    env: envOf({ LOOKUP_GIT_SHA: "sha1", SUPABASE_URL: "https://proj.supabase.co" }),
    now: () => 1_250,
  });

  assertEquals(d.candidate_registration_numbers, ["50067", "33182", null]);
  assertEquals(d.query, "Hortitrol winter oil");
  assertEquals(d.country.requested, "AU");
  assertEquals(d.country.resolved_code, "AU");
  assertEquals(d.server.lookup_version, "sha1");
  assertEquals(d.server.project_ref, "proj");
  assertEquals(d.client.platform, "ios");
  assertEquals(d.duration_ms, 250);
  assertEquals(d.cache, "none");
  assertEquals(d.degraded, []);
});

Deno.test("the exact query is preserved, including whitespace that changed the answer", () => {
  const d = buildDiagnostics({
    requestId: "req-2",
    client: readClientContext({}),
    action: "search",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "  Hortitrol  winter oil ",
    method: "official_register",
    startedAt: 0,
    now: () => 0,
  });
  assertEquals(d.query, "  Hortitrol  winter oil ");
});

Deno.test("structured diagnostics record the selected registration", () => {
  const d = buildDiagnostics({
    requestId: "req-3",
    client: readClientContext({ client: { platform: "portal" } }),
    action: "structured",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "HORTITROL WINTER OIL",
    selectedRegistration: "50067",
    method: "official_register",
    cache: "hit",
    startedAt: 0,
    now: () => 12,
  });
  assertEquals(d.selected_registration, "50067");
  assertEquals(d.cache, "hit");
  assertEquals(d.action, "structured");
});

Deno.test("degraded stages are visible rather than silent", () => {
  // Fail-soft paths are invisible by design; a parity split caused by a
  // register timeout on ONE platform is otherwise unexplainable.
  const d = buildDiagnostics({
    requestId: "req-4",
    client: readClientContext({}),
    action: "search",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "x",
    method: "research",
    startedAt: 0,
    degraded: ["register_timeout", "research_provider_error"],
    now: () => 5,
  });
  assertEquals(d.degraded, ["register_timeout", "research_provider_error"]);
});

Deno.test("duration can never be negative", () => {
  const d = buildDiagnostics({
    requestId: "req-5",
    client: readClientContext({}),
    action: "search",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "x",
    method: "unresolved",
    startedAt: 1_000,
    now: () => 900,
  });
  assertEquals(d.duration_ms, 0);
});

Deno.test("the log line is single-line JSON tagged for filtering", () => {
  const d = buildDiagnostics({
    requestId: "req-6",
    client: readClientContext({ client: { platform: "ios" } }),
    action: "search",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "Hortitrol winter oil",
    candidates,
    method: "official_register",
    startedAt: 0,
    now: () => 1,
  });
  const line = diagnosticsLog(d);
  assert(!line.includes("\n"), "a multi-line record cannot be filtered by request id");
  const parsed = JSON.parse(line);
  assertEquals(parsed.evt, "chemical_lookup_diagnostics");
  assertEquals(parsed.request_id, "req-6");
  assertEquals(parsed.candidate_registration_numbers, ["50067", "33182", null]);
});

Deno.test("the envelope carries no secret material", () => {
  const d = buildDiagnostics({
    requestId: "req-7",
    client: readClientContext({ client: { platform: "ios" } }),
    action: "structured",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "Hortitrol winter oil",
    method: "official_register",
    startedAt: 0,
    env: envOf({
      LOOKUP_GIT_SHA: "sha1",
      SUPABASE_URL: "https://proj.supabase.co",
      OPENAI_API_KEY: "sk-must-never-appear",
      SUPABASE_SERVICE_ROLE_KEY: "service-role-must-never-appear",
    }),
    now: () => 1,
  });
  const line = diagnosticsLog(d);
  assert(!line.includes("sk-must-never-appear"), "an API key reached the diagnostics envelope");
  assert(!line.includes("service-role-must-never-appear"), "service-role material reached the envelope");
  assert(!line.includes("supabase.co"), "the full project URL reached the envelope");
});

Deno.test("a client correlation id is echoed but never used as the request id", () => {
  const d = buildDiagnostics({
    requestId: "server-owned",
    client: readClientContext({ client: { platform: "ios", correlation_id: "client-owned" } }),
    action: "search",
    requestedCountry: "AU",
    resolvedCountryCode: "AU",
    query: "x",
    method: "official_register",
    startedAt: 0,
    now: () => 1,
  });
  assertEquals(d.request_id, "server-owned");
  assertEquals(d.correlation_id, "client-owned");
});
