// Stage 6A documentation checks for the VineTrack developer platform.
//
// Run:  deno run --allow-read scripts/check-developer-docs.ts
//
// Verifies (without duplicating application logic):
//   1. OpenAPI spec parses and is OpenAPI 3.1 with bearer auth.
//   2. OpenAPI path list EXACTLY matches the gateway route definitions
//      (derived from RESOURCE_ROUTES + the special routes in
//      supabase/functions/vinetrack-api/index.ts).
//   3. Every gateway route is mentioned in the developer guide.
//   4. Event catalogue JSON matches the SQL event catalogue (172 + 178),
//      contains no duplicates, and every required scope exists in the
//      SQL scope catalogue and matches the module→scope mapping.
//   5. Webhook header names + signature scheme in the docs match the
//      dispatcher implementation.
//   6. No committed live-looking secrets (vt_live_/vt_test_ full keys,
//      whsec_ full secrets, JWTs) anywhere under docs/.

import { parse as parseYaml } from "jsr:@std/yaml@1";

let failures = 0;
function check(ok: boolean, label: string, detail = ""): void {
  if (ok) {
    console.log(`  ok      ${label}`);
  } else {
    failures += 1;
    console.error(`  FAIL    ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

const read = (p: string): string => Deno.readTextFileSync(p);

// ---------------------------------------------------------------------------
// 1+2. Gateway routes vs OpenAPI
// ---------------------------------------------------------------------------
console.log("\n[1] Gateway routes vs OpenAPI spec");

const gateway = read("supabase/functions/vinetrack-api/index.ts");

const resourceRoutes: string[] = [];
const routeTable = gateway.match(/const RESOURCE_ROUTES[^=]*=\s*\{([\s\S]*?)\n\};/);
check(routeTable !== null, "RESOURCE_ROUTES table found in gateway");
if (routeTable) {
  for (const m of routeTable[1].matchAll(/"([a-z-]+)":\s*\{[^}]*idLabel:\s*"([a-z_]+)"/g)) {
    resourceRoutes.push(`/v1/${m[1]}`, `/v1/${m[1]}/{${m[2]}}`);
  }
}
const specialRoutes = ["/v1/me", "/v1/weather", "/v1/rainfall", "/v1/disease-risk"];
for (const s of ["me", "weather", "rainfall", "disease-risk"]) {
  check(gateway.includes(`segments[1] === "${s}"`), `gateway serves special route /v1/${s}`);
}
const gatewayRoutes = [...specialRoutes, ...resourceRoutes].sort();
check(gatewayRoutes.length === 30, "gateway defines exactly 30 routes", `found ${gatewayRoutes.length}`);

const openapiRaw = read("docs/openapi/vinetrack-v1.yaml");
let openapi: Record<string, unknown> | null = null;
try {
  openapi = parseYaml(openapiRaw) as Record<string, unknown>;
  check(true, "OpenAPI YAML parses");
} catch (e) {
  check(false, "OpenAPI YAML parses", String(e));
}
if (openapi) {
  const version = String(openapi.openapi ?? "");
  check(version.startsWith("3.1"), "OpenAPI version is 3.1.x", version);
  const components = openapi.components as Record<string, unknown> | undefined;
  const schemes = (components?.securitySchemes ?? {}) as Record<string, { type?: string; scheme?: string }>;
  const hasBearer = Object.values(schemes).some((s) => s.type === "http" && s.scheme === "bearer");
  check(hasBearer, "OpenAPI declares HTTP bearer security scheme");

  const paths = Object.keys((openapi.paths ?? {}) as Record<string, unknown>).sort();
  const missingInSpec = gatewayRoutes.filter((r) => !paths.includes(r));
  const extraInSpec = paths.filter((p) => !gatewayRoutes.includes(p));
  check(missingInSpec.length === 0, "every gateway route documented in OpenAPI", missingInSpec.join(", "));
  check(extraInSpec.length === 0, "OpenAPI documents no non-existent routes", extraInSpec.join(", "));
  check(paths.length === 30, "OpenAPI documents exactly 30 routes", `found ${paths.length}`);

  const specText = JSON.stringify(openapi);
  check(!specText.includes("post"), "OpenAPI contains no write operations (POST)");
  for (const method of ['"put"', '"patch"', '"delete"']) {
    check(!specText.includes(method), `OpenAPI contains no write operations (${method})`);
  }
}

// ---------------------------------------------------------------------------
// 3. Developer guide route coverage
// ---------------------------------------------------------------------------
console.log("\n[2] Developer guide route coverage");
const guide = read("docs/vinetrack-developer-platform.md");
const missingInGuide = gatewayRoutes.filter((r) => !guide.includes(r));
check(missingInGuide.length === 0, "every gateway route mentioned in developer guide", missingInGuide.join(", "));

// ---------------------------------------------------------------------------
// 4. Event catalogue: SQL vs JSON vs guide
// ---------------------------------------------------------------------------
console.log("\n[3] Webhook event catalogue");

const sql172 = read("sql/172_integration_platform_foundation.sql");
const sql178 = read("sql/178_integration_webhook_platform.sql");

// Events + module from the SQL 172 catalogue insert; webhook.test from 178.
const sqlEvents = new Map<string, string>();
for (const m of sql172.matchAll(/\('([a-z_]+\.[a-z_]+)',\s*'([a-z]+)',/g)) {
  sqlEvents.set(m[1], m[2]);
}
check(sql178.includes("'webhook.test', 'system'"), "webhook.test catalogued in SQL 178");
sqlEvents.set("webhook.test", "system");
check(sqlEvents.size === 26, "SQL catalogues exactly 26 events", `found ${sqlEvents.size}`);

// Module → scope mapping from _integration_event_scope in SQL 178.
const scopeFn = sql178.match(/_integration_event_scope[\s\S]*?\$\$([\s\S]*?)\$\$/);
const moduleScope = new Map<string, string>();
if (scopeFn) {
  for (const m of scopeFn[1].matchAll(/when '([a-z]+)'\s+then '([a-z_]+:read)'/g)) {
    moduleScope.set(m[1], m[2]);
  }
}
check(moduleScope.size >= 10, "module→scope mapping extracted from SQL 178", `found ${moduleScope.size}`);

// Scope catalogue from SQL 172.
const sqlScopes = new Set<string>();
for (const m of sql172.matchAll(/\('([a-z_]+:(?:read|write))',/g)) sqlScopes.add(m[1]);
check(sqlScopes.size >= 18, "scope catalogue extracted from SQL 172", `found ${sqlScopes.size}`);

const eventsJson = JSON.parse(read("docs/webhooks/vinetrack-events-v1.json")) as {
  events: { event: string; required_scope: string | null; vineyard_scoped: boolean; resource_type: string }[];
};
const jsonNames = eventsJson.events.map((e) => e.event);
check(new Set(jsonNames).size === jsonNames.length, "event JSON contains no duplicates");
const missingInJson = [...sqlEvents.keys()].filter((e) => !jsonNames.includes(e));
const extraInJson = jsonNames.filter((e) => !sqlEvents.has(e));
check(missingInJson.length === 0, "every SQL event present in event JSON", missingInJson.join(", "));
check(extraInJson.length === 0, "event JSON invents no events", extraInJson.join(", "));

for (const ev of eventsJson.events) {
  const module = sqlEvents.get(ev.event);
  const expectedScope = module === "system" ? null : moduleScope.get(module ?? "") ?? null;
  check(
    ev.required_scope === expectedScope,
    `scope for ${ev.event} matches SQL mapping`,
    `json=${ev.required_scope} sql=${expectedScope}`,
  );
  if (ev.required_scope !== null) {
    check(sqlScopes.has(ev.required_scope), `scope ${ev.required_scope} exists in scope catalogue`);
  }
  check(ev.vineyard_scoped === (ev.event !== "webhook.test"), `vineyard_scoped correct for ${ev.event}`);
}

const missingInGuideEvents = jsonNames.filter((e) => !guide.includes(`\`${e}\``));
check(missingInGuideEvents.length === 0, "every event mentioned in developer guide", missingInGuideEvents.join(", "));
const webhookDoc = read("docs/vinetrack-webhooks.md");
const missingInWebhookDoc = jsonNames.filter((e) => !webhookDoc.includes(e));
check(missingInWebhookDoc.length === 0, "every event mentioned in webhook reference", missingInWebhookDoc.join(", "));

// ---------------------------------------------------------------------------
// 5. Webhook headers + signature contract vs dispatcher
// ---------------------------------------------------------------------------
console.log("\n[4] Dispatcher contract vs docs");
const dispatcher = read("supabase/functions/vinetrack-webhook-dispatch/index.ts");
const headers = [
  "X-VineTrack-Signature",
  "X-VineTrack-Timestamp",
  "X-VineTrack-Event",
  "X-VineTrack-Delivery",
  "X-VineTrack-API-Version",
];
for (const h of headers) {
  check(dispatcher.includes(`"${h}"`), `dispatcher sends ${h}`);
  check(guide.includes(h), `guide documents ${h}`);
  check(webhookDoc.includes(h), `webhook reference documents ${h}`);
}
check(dispatcher.includes("`v1=${hex}`"), "dispatcher signature uses v1=<hex> scheme");
check(dispatcher.includes("${timestamp}.${rawBody}"), "dispatcher signs `${timestamp}.${rawBody}`");
check(guide.includes("HMAC_SHA256"), "guide documents HMAC_SHA256 signature contract");

// Retry schedule: SQL case-expression intervals vs guide.
const sqlBackoffSteps = [
  "interval '1 minute'",
  "interval '5 minutes'",
  "interval '30 minutes'",
  "interval '2 hours'",
  "interval '12 hours'",
  "interval '24 hours'",
];
check(
  sqlBackoffSteps.every((s) => sql178.includes(s)),
  "SQL retry schedule is 1m/5m/30m/2h/12h/24h",
  sqlBackoffSteps.filter((s) => !sql178.includes(s)).join(", "),
);
for (const s of ["+1 minute", "+5 minutes", "+30 minutes", "+2 hours", "+12 hours", "+24 hours"]) {
  check(guide.includes(s), `guide documents backoff step ${s}`);
}
check(guide.includes("7 attempts") || guide.includes("**7 attempts**"), "guide documents max 7 attempts");
check(sql178.includes("v_attempt >= 7"), "SQL max attempts is 7");

// ---------------------------------------------------------------------------
// 6. Secret scan across docs/
// ---------------------------------------------------------------------------
console.log("\n[5] Secret scan (docs/)");
const secretPatterns: [RegExp, string][] = [
  [/vt_(live|test)_[0-9a-f]{40,}/g, "full VineTrack API key"],
  [/whsec_[0-9a-f]{40,}/g, "full webhook signing secret"],
  [/eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{10,}/g, "JWT (service-role/anon key)"],
  [/sb_secret_[A-Za-z0-9]{20,}/g, "Supabase secret key"],
];
async function* walk(dir: string): AsyncGenerator<string> {
  for await (const entry of Deno.readDir(dir)) {
    const p = `${dir}/${entry.name}`;
    if (entry.isDirectory) yield* walk(p);
    else if (/\.(md|ya?ml|json)$/.test(entry.name)) yield p;
  }
}
let scanned = 0;
let leaks = 0;
for await (const file of walk("docs")) {
  scanned += 1;
  const text = read(file);
  for (const [re, label] of secretPatterns) {
    const hits = text.match(re);
    if (hits) {
      leaks += 1;
      check(false, `no ${label} in ${file}`, hits[0].slice(0, 24) + "…");
    }
  }
}
check(leaks === 0, `no committed secrets across ${scanned} docs files`);

// ---------------------------------------------------------------------------
console.log(failures === 0 ? "\nAll documentation checks passed." : `\n${failures} check(s) FAILED.`);
if (failures > 0) Deno.exit(1);
