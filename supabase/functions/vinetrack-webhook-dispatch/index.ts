// Supabase Edge Function: vinetrack-webhook-dispatch
//
// VineTrack outbound webhook dispatcher — Stage 5A.
//
// Invoked on a schedule (Supabase cron / pg_cron+pg_net, e.g. every minute)
// or manually. Each run:
//   1. Claims due deliveries via integration_webhook_claim_deliveries
//      (FOR UPDATE SKIP LOCKED + lease → safe under parallel invocations;
//      the RPC also cancels/defers deliveries whose endpoint/integration/
//      grant/scope chain is no longer intact — lazy revocation).
//   2. For each claimed delivery:
//        - fetches the endpoint signing secret from Vault (service-role RPC),
//        - re-validates the destination host and its DNS resolution against
//          the SSRF policy (defence in depth on top of the SQL validation),
//        - POSTs the signed envelope with a 10s timeout, no redirects,
//        - records the outcome via integration_webhook_record_attempt
//          (which owns the backoff schedule and auto-disable logic).
//   3. Repeats until the queue is drained or the ~45s time budget is spent.
//
// Signature contract (documented in docs/vinetrack-webhooks.md):
//   X-VineTrack-Signature: v1=HEX(HMAC_SHA256(secret, `${timestamp}.${rawBody}`))
//   X-VineTrack-Timestamp: unix seconds used in the signed message
//
// Auth: NOT a public endpoint. Callers must present either the service-role
// key as a Bearer token or the shared WEBHOOK_DISPATCH_SECRET header.
// Deploy with --no-verify-jwt only if the scheduler cannot attach a JWT.
//
// Env:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   (provided by the platform)
//   WEBHOOK_DISPATCH_SECRET                   (optional shared cron secret)
//
// SINGLE-FILE DEPLOYMENT NOTE: this file is fully self-contained so it can be
// pasted into the Supabase Dashboard Edge Function editor (which deploys only
// index.ts). The pure helpers below are mirrored in ./lib.ts, which exists
// solely so `deno test lib_test.ts` can unit-test them. If you change a helper
// here, apply the identical change in lib.ts (and vice versa).

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// ===========================================================================
// Pure helpers (inlined from ./lib.ts — keep in sync with that file).
// ===========================================================================

/** Webhook envelope — the exact JSON body POSTed to receiver endpoints. */
interface WebhookEnvelope {
  id: string;
  type: string;
  api_version: string;
  occurred_at: string;
  vineyard_id: string | null;
  data: Record<string, unknown>;
}

/** One claimed delivery as returned by integration_webhook_claim_deliveries. */
interface ClaimedDelivery {
  delivery_id: string;
  claim_token: string;
  delivery_public_id: string;
  attempt_number: number;
  endpoint_id: string;
  url: string;
  event: WebhookEnvelope;
}

/**
 * Builds the canonical raw request body. Key order is fixed so the signed
 * bytes are exactly what receivers can re-serialize deterministically.
 */
function buildEnvelopeBody(event: WebhookEnvelope): string {
  return JSON.stringify({
    id: event.id,
    type: event.type,
    api_version: event.api_version,
    occurred_at: event.occurred_at,
    vineyard_id: event.vineyard_id,
    data: event.data ?? {},
  });
}

/**
 * HMAC-SHA256 signature over `${timestamp}.${rawBody}` with the endpoint
 * signing secret. Returned as the header value `v1=<hex>`.
 */
async function signWebhook(
  secret: string,
  timestamp: number,
  rawBody: string,
): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    enc.encode(`${timestamp}.${rawBody}`),
  );
  const hex = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `v1=${hex}`;
}

/**
 * Hostname-level SSRF policy (mirror of SQL _integration_validate_webhook_url).
 * Returns a reason string when blocked, or null when allowed.
 */
function blockedHostnameReason(hostname: string): string | null {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  if (host.length === 0) return "empty_host";
  if (host.startsWith("[") || host.includes(":")) return "ipv6_literal";
  if (/^[0-9.]+$/.test(host)) return "ip_literal";
  if (/^0x/.test(host)) return "hex_ip_literal";
  if (!/\.[a-z][a-z0-9-]*$/.test(host)) return "no_public_tld";
  if (
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local") ||
    host.endsWith(".internal") ||
    host.endsWith(".home.arpa") ||
    host === "metadata.google.internal"
  ) {
    return "internal_hostname";
  }
  return null;
}

/** True when an IPv4 address string is private/reserved (RFC1918 + friends). */
function isPrivateIpv4(ip: string): boolean {
  const parts = ip.split(".").map((p) => Number(p));
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    return true; // malformed → treat as blocked
  }
  const [a, b] = parts;
  if (a === 0 || a === 10 || a === 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
  if (a === 192 && b === 0) return true; // 192.0.0.0/24 + 192.0.2.0/24 doc
  if (a === 198 && (b === 18 || b === 19)) return true; // benchmarking
  if (a >= 224) return true; // multicast + reserved + broadcast
  return false;
}

/** True when an IPv6 address string is private/reserved. */
function isPrivateIpv6(ip: string): boolean {
  const v = ip.toLowerCase();
  if (v === "::" || v === "::1") return true;
  if (v.startsWith("fc") || v.startsWith("fd")) return true; // ULA fc00::/7
  if (v.startsWith("fe8") || v.startsWith("fe9") || v.startsWith("fea") || v.startsWith("feb")) {
    return true; // link-local fe80::/10
  }
  if (v.startsWith("::ffff:")) {
    // IPv4-mapped — apply the IPv4 policy to the embedded address
    const mapped = v.slice(7);
    return mapped.includes(".") ? isPrivateIpv4(mapped) : true;
  }
  return false;
}

type AttemptOutcome = "success" | "retryable" | "permanent";

interface Classification {
  outcome: AttemptOutcome;
  errorCategory: string | null;
}

/** Maps an HTTP response status to an attempt outcome + safe error category. */
function classifyHttpStatus(status: number): Classification {
  if (status >= 200 && status < 300) {
    return { outcome: "success", errorCategory: null };
  }
  if (status >= 300 && status < 400) {
    // redirects are NOT followed (SSRF policy) and are treated as permanent
    return { outcome: "permanent", errorCategory: "http_3xx" };
  }
  if (status === 408 || status === 429) {
    return { outcome: "retryable", errorCategory: "http_4xx" };
  }
  if (status >= 400 && status < 500) {
    return { outcome: "permanent", errorCategory: "http_4xx" };
  }
  return { outcome: "retryable", errorCategory: "http_5xx" };
}

/**
 * Parses a Retry-After header (delta-seconds or HTTP-date) into clamped
 * seconds (0..3600), or null when absent/invalid.
 */
function parseRetryAfterSeconds(
  header: string | null,
  nowMs: number = Date.now(),
): number | null {
  if (header === null || header.trim() === "") return null;
  const trimmed = header.trim();
  if (/^\d+$/.test(trimmed)) {
    return Math.min(Number(trimmed), 3600);
  }
  const dateMs = Date.parse(trimmed);
  if (Number.isNaN(dateMs)) return null;
  const deltaSeconds = Math.ceil((dateMs - nowMs) / 1000);
  if (deltaSeconds <= 0) return null;
  return Math.min(deltaSeconds, 3600);
}

// ===========================================================================
// Dispatcher runtime.
// ===========================================================================

const REQUEST_TIMEOUT_MS = 10_000;
const RUN_BUDGET_MS = 45_000;
const CLAIM_BATCH = 20;
const CLAIM_LEASE_SECONDS = 90;
const USER_AGENT = "VineTrack-Webhooks/1.0";

interface AttemptResult {
  outcome: "success" | "retryable" | "permanent";
  httpStatus: number | null;
  errorCategory: string | null;
  errorDetail: string | null;
  retryAfterSeconds: number | null;
}

function isAuthorized(req: Request): boolean {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const dispatchSecret = Deno.env.get("WEBHOOK_DISPATCH_SECRET") ?? "";

  const auth = req.headers.get("authorization") ?? "";
  const bearer = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (serviceKey.length > 0 && bearer === serviceKey) return true;

  const presented = req.headers.get("x-dispatch-secret") ?? "";
  if (dispatchSecret.length > 0 && presented === dispatchSecret) return true;

  return false;
}

/**
 * Defence-in-depth SSRF check at send time: hostname policy + DNS resolution
 * of every A/AAAA record against private/reserved ranges. DNS rebinding
 * between this check and fetch() remains a documented residual risk.
 */
async function ssrfBlockReason(url: string): Promise<string | null> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return "unparseable_url";
  }
  if (parsed.protocol !== "https:") return "not_https";
  if (parsed.username !== "" || parsed.password !== "") return "userinfo";
  if (parsed.port !== "" && parsed.port !== "443" && parsed.port !== "8443") {
    return "port_not_allowed";
  }

  const hostReason = blockedHostnameReason(parsed.hostname);
  if (hostReason !== null) return hostReason;

  let sawAddress = false;
  for (const recordType of ["A", "AAAA"] as const) {
    try {
      const addresses = await Deno.resolveDns(parsed.hostname, recordType);
      for (const address of addresses) {
        sawAddress = true;
        const blocked = recordType === "A" ? isPrivateIpv4(address) : isPrivateIpv6(address);
        if (blocked) return `resolves_to_private_${recordType.toLowerCase()}`;
      }
    } catch {
      // NXDOMAIN / no records of this type — fine as long as the other
      // record type resolves publicly.
    }
  }
  if (!sawAddress) return "dns_resolution_failed";
  return null;
}

async function attemptDelivery(
  delivery: ClaimedDelivery,
  secret: string,
): Promise<AttemptResult> {
  const blockReason = await ssrfBlockReason(delivery.url);
  if (blockReason !== null) {
    return {
      outcome: "permanent",
      httpStatus: null,
      errorCategory: "ssrf_blocked",
      errorDetail: `destination refused by delivery policy: ${blockReason}`,
      retryAfterSeconds: null,
    };
  }

  const rawBody = buildEnvelopeBody(delivery.event);
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = await signWebhook(secret, timestamp, rawBody);

  const startedAt = performance.now();
  try {
    const response = await fetch(delivery.url, {
      method: "POST",
      redirect: "manual", // never follow redirects (SSRF policy)
      headers: {
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
        "X-VineTrack-Signature": signature,
        "X-VineTrack-Timestamp": String(timestamp),
        "X-VineTrack-Event": delivery.event.type,
        "X-VineTrack-Delivery": delivery.delivery_public_id,
        "X-VineTrack-API-Version": delivery.event.api_version,
      },
      body: rawBody,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    // drain (bounded) so the connection can be reused; body is never stored
    await response.body?.cancel();

    const classification = classifyHttpStatus(response.status);
    const retryAfter = classification.outcome === "retryable"
      ? parseRetryAfterSeconds(response.headers.get("retry-after"))
      : null;

    return {
      outcome: classification.outcome,
      httpStatus: response.status,
      errorCategory: classification.errorCategory,
      errorDetail: classification.outcome === "success"
        ? null
        : `receiver responded ${response.status}`,
      retryAfterSeconds: retryAfter,
    };
  } catch (error) {
    const isTimeout = error instanceof DOMException &&
      (error.name === "TimeoutError" || error.name === "AbortError");
    const message = error instanceof Error ? error.message : String(error);
    const tls = /tls|certificate|handshake/i.test(message);
    return {
      outcome: "retryable",
      httpStatus: null,
      errorCategory: isTimeout ? "timeout" : tls ? "tls" : "network",
      errorDetail: isTimeout
        ? `no response within ${REQUEST_TIMEOUT_MS / 1000}s`
        : message.slice(0, 300),
      retryAfterSeconds: null,
    };
  } finally {
    void startedAt;
  }
}

async function processDelivery(
  db: SupabaseClient,
  delivery: ClaimedDelivery,
  secretCache: Map<string, string | null>,
): Promise<void> {
  let secret = secretCache.get(delivery.endpoint_id);
  if (secret === undefined) {
    const { data, error } = await db.rpc("integration_webhook_get_endpoint_secret", {
      p_endpoint_id: delivery.endpoint_id,
    });
    secret = error ? null : (data as string | null);
    secretCache.set(delivery.endpoint_id, secret);
  }

  const startedAt = performance.now();
  const result: AttemptResult = secret === null || secret === ""
    ? {
      outcome: "retryable",
      httpStatus: null,
      errorCategory: "secret_unavailable",
      errorDetail: "signing secret could not be read from secure storage",
      retryAfterSeconds: null,
    }
    : await attemptDelivery(delivery, secret);
  const durationMs = Math.round(performance.now() - startedAt);

  const { error: recordError } = await db.rpc("integration_webhook_record_attempt", {
    p_delivery_id: delivery.delivery_id,
    p_claim_token: delivery.claim_token,
    p_outcome: result.outcome,
    p_http_status: result.httpStatus,
    p_duration_ms: durationMs,
    p_error_category: result.errorCategory,
    p_error_detail: result.errorDetail,
    p_retry_after_seconds: result.retryAfterSeconds,
  });
  if (recordError) {
    // The claim lease will expire and the delivery will be retried.
    console.error(
      `[dispatch] failed to record attempt for ${delivery.delivery_public_id}: ${recordError.message}`,
    );
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }
  if (!isAuthorized(req)) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "configuration_error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const db = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const runStartedAt = Date.now();
  const secretCache = new Map<string, string | null>();
  let claimed = 0;
  let batches = 0;

  while (Date.now() - runStartedAt < RUN_BUDGET_MS) {
    const { data, error } = await db.rpc("integration_webhook_claim_deliveries", {
      p_batch: CLAIM_BATCH,
      p_lease_seconds: CLAIM_LEASE_SECONDS,
    });
    if (error) {
      console.error(`[dispatch] claim failed: ${error.message}`);
      return new Response(
        JSON.stringify({ error: "claim_failed", claimed, batches }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    const deliveries = (data ?? []) as ClaimedDelivery[];
    if (deliveries.length === 0) break;

    batches += 1;
    claimed += deliveries.length;

    // Deliveries to distinct endpoints run concurrently (bounded by batch size).
    await Promise.all(deliveries.map((d) => processDelivery(db, d, secretCache)));
  }

  return new Response(
    JSON.stringify({
      ok: true,
      claimed,
      batches,
      duration_ms: Date.now() - runStartedAt,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
