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

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  blockedHostnameReason,
  buildEnvelopeBody,
  ClaimedDelivery,
  classifyHttpStatus,
  isPrivateIpv4,
  isPrivateIpv6,
  parseRetryAfterSeconds,
  signWebhook,
} from "./lib.ts";

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
