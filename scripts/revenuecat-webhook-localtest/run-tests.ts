// =============================================================================
// revenuecat-webhook local controlled tests (Phase 2B)
// =============================================================================
// Runs the REAL supabase/functions/revenuecat-webhook/index.ts under Deno,
// pointed at an in-process mock of the Supabase REST + Auth admin APIs.
// No production database, no secrets, no receipts — fixtures only.
//
// Validates (per the Phase 2B interim instruction):
//   T0  missing REVENUECAT_WEBHOOK_SECRET  -> fails closed with 500
//   T1  invalid Authorization header       -> 401 rejected
//   T2  valid authenticated TEST event     -> accepted (stored, 'ignored')
//   T3  unknown product                    -> needs_review, NO access granted
//   T4  duplicate delivery of T3           -> already_processed (idempotent)
//   T5  entitlement 'premium' without 'pro'-> needs_review + mismatch audit
//   T6  anonymous App User ID              -> needs_review (attaches to nobody)
//   T7  across ALL tests: zero writes to vinetrack_subscriptions /
//       vinetrack_user_licences, and raw_payload stored with receipt /
//       purchase_token / subscriber_attributes keys stripped.
//
// Run from the repo root:
//   deno run --allow-net --allow-env --allow-run scripts/revenuecat-webhook-localtest/run-tests.ts
//
// Exit code 0 = all tests passed.

const MOCK_PORT = 9799;
const FN_PORT = 8000;
const FN_URL = `http://127.0.0.1:${FN_PORT}`;
const MOCK_URL = `http://127.0.0.1:${MOCK_PORT}`;
const SECRET = "local-ci-secret-0123456789abcdef";
const KNOWN_USER = "11111111-2222-3333-4444-555555555555";
const FN_ENTRY = "supabase/functions/revenuecat-webhook/index.ts";

// ---------------------------------------------------------------------------
// In-process mock of the Supabase APIs the webhook touches.
// ---------------------------------------------------------------------------
interface RecordedRequest {
  method: string;
  path: string;
  body: unknown;
}
const recorded: RecordedRequest[] = [];
const seenEventIds = new Set<string>();
let rowCounter = 0;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const mockServer = Deno.serve({ port: MOCK_PORT, hostname: "127.0.0.1" }, async (req) => {
  const url = new URL(req.url);
  const path = url.pathname;
  let body: unknown = null;
  if (req.method === "POST" || req.method === "PATCH") {
    try {
      body = await req.json();
    } catch {
      body = null;
    }
  }
  recorded.push({ method: req.method, path, body });

  if (path === "/rest/v1/billing_provider_events" && req.method === "POST") {
    const eventId = (body as Record<string, unknown>)?.provider_event_id as string;
    if (seenEventIds.has(eventId)) {
      return jsonResponse(
        {
          code: "23505",
          message: 'duplicate key value violates unique constraint "uniq_billing_provider_events_event"',
          details: "Key (provider, provider_event_id) already exists.",
          hint: null,
        },
        409,
      );
    }
    seenEventIds.add(eventId);
    rowCounter += 1;
    return jsonResponse({ id: `mock-row-${rowCounter}` }, 201);
  }
  if (path === "/rest/v1/billing_provider_events" && req.method === "PATCH") {
    return new Response(null, { status: 204 });
  }
  if (path.startsWith("/auth/v1/admin/users/") && req.method === "GET") {
    const id = path.split("/").pop() ?? "";
    if (id.toLowerCase() === KNOWN_USER) {
      const now = new Date().toISOString();
      return jsonResponse({
        id: KNOWN_USER,
        aud: "authenticated",
        role: "authenticated",
        email: "controlled-test@example.com",
        created_at: now,
        updated_at: now,
        app_metadata: {},
        user_metadata: {},
      });
    }
    return jsonResponse({ code: 404, error_code: "user_not_found", msg: "User not found" }, 404);
  }
  if (path === "/rest/v1/billing_product_catalog" && req.method === "GET") {
    return jsonResponse([]); // every product is UNKNOWN in this harness
  }
  if (path === "/rest/v1/vinetrack_entitlement_audit" && req.method === "POST") {
    return new Response(null, { status: 201 });
  }
  // Anything else (e.g. vinetrack_subscriptions writes) is a violation for
  // these fixtures — record it (asserted in T7) and fail the call loudly.
  return jsonResponse({ message: `mock: unexpected call ${req.method} ${path}` }, 500);
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function waitForFunction(timeoutMs = 20000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(FN_URL, { method: "GET" });
      await res.body?.cancel();
      return; // any HTTP response (405) means the server is up
    } catch {
      await new Promise((r) => setTimeout(r, 250));
    }
  }
  throw new Error("webhook function did not start in time");
}

async function waitForPortFree(timeoutMs = 10000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(FN_URL, { method: "GET" });
      await res.body?.cancel();
      await new Promise((r) => setTimeout(r, 250));
    } catch {
      return;
    }
  }
  throw new Error("port 8000 did not free up");
}

function spawnFunction(secret: string): Deno.ChildProcess {
  const cmd = new Deno.Command("deno", {
    args: ["run", "--quiet", "--allow-net", "--allow-env", FN_ENTRY],
    env: {
      REVENUECAT_WEBHOOK_SECRET: secret,
      SUPABASE_URL: MOCK_URL,
      SUPABASE_SERVICE_ROLE_KEY: "local-test-service-key-not-real",
    },
    stdout: "inherit",
    stderr: "inherit",
  });
  return cmd.spawn();
}

async function post(auth: string | null, payload: unknown): Promise<{ status: number; body: Record<string, unknown> }> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (auth !== null) headers["Authorization"] = auth;
  const res = await fetch(FN_URL, { method: "POST", headers, body: JSON.stringify(payload) });
  const body = (await res.json()) as Record<string, unknown>;
  return { status: res.status, body };
}

let passed = 0;
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (ok) {
    passed += 1;
    console.log(`PASS  ${name}`);
  } else {
    failed += 1;
    console.log(`FAIL  ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

function initialPurchaseFixture(eventId: string, overrides: Record<string, unknown> = {}): unknown {
  return {
    api_version: "1.0",
    event: {
      id: eventId,
      type: "INITIAL_PURCHASE",
      environment: "PRODUCTION",
      store: "APP_STORE",
      app_user_id: KNOWN_USER,
      product_id: "com.vinetrack.mystery.product",
      entitlement_ids: ["pro"],
      period_type: "NORMAL",
      purchased_at_ms: 1785000000000,
      expiration_at_ms: 1792900000000,
      event_timestamp_ms: 1785000001000,
      transaction_id: "fixture-txn-1",
      original_transaction_id: "fixture-orig-txn-1",
      // Receipt/token-looking keys that MUST be stripped before storage:
      receipt: { data: "FAKE_RECEIPT_DATA_MUST_NOT_PERSIST" },
      purchase_token: "FAKE_PURCHASE_TOKEN_MUST_NOT_PERSIST",
      subscriber_attributes: { secret_attr: "MUST_NOT_PERSIST" },
      ...overrides,
    },
  };
}

function lastPatchBody(): Record<string, unknown> | null {
  for (let i = recorded.length - 1; i >= 0; i--) {
    const r = recorded[i];
    if (r.method === "PATCH" && r.path === "/rest/v1/billing_provider_events") {
      return r.body as Record<string, unknown>;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// T0 — fail closed when the secret is not configured
// ---------------------------------------------------------------------------
let child = spawnFunction(""); // empty = unset per the function's `?? ""` guard
await waitForFunction();
{
  const res = await post(SECRET, { event: { id: "evt-local-t0", type: "TEST" } });
  check(
    "T0 secret not configured -> 500 fail-closed",
    res.status === 500 && String(res.body.error ?? "").includes("not configured"),
    `got ${res.status} ${JSON.stringify(res.body)}`,
  );
}
child.kill("SIGKILL");
await child.status;
await waitForPortFree();

// ---------------------------------------------------------------------------
// Main phase — secret configured
// ---------------------------------------------------------------------------
child = spawnFunction(SECRET);
await waitForFunction();

try {
  // T1 — invalid Authorization rejected
  {
    const res = await post("wrong-secret-value", { event: { id: "evt-local-t1", type: "TEST" } });
    check("T1 invalid Authorization -> 401", res.status === 401, `got ${res.status} ${JSON.stringify(res.body)}`);
    const stored = recorded.some((r) => r.method === "POST" && r.path === "/rest/v1/billing_provider_events");
    check("T1 rejected request stored NOTHING", !stored);
  }

  // T2 — valid authenticated TEST event accepted
  {
    const res = await post(SECRET, { event: { id: "evt-local-t2", type: "TEST" } });
    check(
      "T2 valid TEST event -> 200 accepted (ignored)",
      res.status === 200 && res.body.status === "ignored",
      `got ${res.status} ${JSON.stringify(res.body)}`,
    );
    check("T2 provider event row created", seenEventIds.has("evt-local-t2"));
  }

  // T3 — unknown product -> needs_review, no access
  {
    const res = await post(SECRET, initialPurchaseFixture("evt-local-t3"));
    check(
      "T3 unknown product -> 200 needs_review",
      res.status === 200 && res.body.status === "needs_review",
      `got ${res.status} ${JSON.stringify(res.body)}`,
    );
    const patch = lastPatchBody();
    check(
      "T3 event row finalised needs_review/unknown_product",
      patch?.processing_status === "needs_review" && patch?.processing_error_code === "unknown_product",
      JSON.stringify(patch),
    );
    const insert = recorded.find(
      (r) =>
        r.method === "POST" &&
        r.path === "/rest/v1/billing_provider_events" &&
        (r.body as Record<string, unknown>)?.provider_event_id === "evt-local-t3",
    );
    const rawText = JSON.stringify((insert?.body as Record<string, unknown>)?.raw_payload ?? {});
    check(
      "T3 raw_payload stripped of receipt/token/attributes",
      !rawText.includes("MUST_NOT_PERSIST") &&
        !rawText.includes("purchase_token") &&
        !rawText.includes("receipt") &&
        !rawText.includes("subscriber_attributes"),
      rawText.slice(0, 300),
    );
    check(
      "T3 payload_hash recorded",
      typeof (insert?.body as Record<string, unknown>)?.payload_hash === "string" &&
        ((insert?.body as Record<string, unknown>).payload_hash as string).length === 64,
    );
  }

  // T4 — duplicate delivery is idempotent
  {
    const res = await post(SECRET, initialPurchaseFixture("evt-local-t3"));
    check(
      "T4 duplicate delivery -> already_processed",
      res.status === 200 && res.body.status === "already_processed",
      `got ${res.status} ${JSON.stringify(res.body)}`,
    );
  }

  // T5 — entitlement 'premium' without 'pro' -> mismatch, needs_review
  {
    const res = await post(SECRET, initialPurchaseFixture("evt-local-t5", { entitlement_ids: ["premium"] }));
    check(
      "T5 premium-without-pro -> 200 needs_review",
      res.status === 200 && res.body.status === "needs_review",
      `got ${res.status} ${JSON.stringify(res.body)}`,
    );
    const patch = lastPatchBody();
    check("T5 classified entitlement_mismatch", patch?.processing_error_code === "entitlement_mismatch", JSON.stringify(patch));
    const auditRow = recorded.find(
      (r) =>
        r.method === "POST" &&
        r.path === "/rest/v1/vinetrack_entitlement_audit" &&
        (r.body as Record<string, unknown>)?.event_type === "store_subscription_sync_mismatch",
    );
    check("T5 mismatch audit event written", auditRow !== undefined);
  }

  // T6 — anonymous App User ID attaches to nobody
  {
    const res = await post(
      SECRET,
      initialPurchaseFixture("evt-local-t6", { app_user_id: "$RCAnonymousID:abc123", original_app_user_id: null }),
    );
    check(
      "T6 anonymous app_user_id -> 200 needs_review",
      res.status === 200 && res.body.status === "needs_review",
      `got ${res.status} ${JSON.stringify(res.body)}`,
    );
    const patch = lastPatchBody();
    check("T6 classified unresolved_app_user_id", patch?.processing_error_code === "unresolved_app_user_id", JSON.stringify(patch));
  }

  // T7 — across ALL tests: zero entitlement writes
  {
    const entitlementWrites = recorded.filter(
      (r) => r.path.includes("vinetrack_subscriptions") || r.path.includes("vinetrack_user_licences"),
    );
    check(
      "T7 NO vinetrack_subscriptions / vinetrack_user_licences writes occurred",
      entitlementWrites.length === 0,
      JSON.stringify(entitlementWrites.map((r) => `${r.method} ${r.path}`)),
    );
  }
} finally {
  child.kill("SIGKILL");
  await child.status;
  await mockServer.shutdown();
}

console.log(`\n${passed} passed, ${failed} failed`);
Deno.exit(failed === 0 ? 0 : 1);
