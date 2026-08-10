// Pure helpers for the VineTrack webhook dispatcher (Stage 5A).
// Kept dependency-free so they can be unit-tested with `deno test`.

/** Webhook envelope — the exact JSON body POSTed to receiver endpoints. */
export interface WebhookEnvelope {
  id: string;
  type: string;
  api_version: string;
  occurred_at: string;
  vineyard_id: string | null;
  data: Record<string, unknown>;
}

/** One claimed delivery as returned by integration_webhook_claim_deliveries. */
export interface ClaimedDelivery {
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
export function buildEnvelopeBody(event: WebhookEnvelope): string {
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
export async function signWebhook(
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
export function blockedHostnameReason(hostname: string): string | null {
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
export function isPrivateIpv4(ip: string): boolean {
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
export function isPrivateIpv6(ip: string): boolean {
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

export type AttemptOutcome = "success" | "retryable" | "permanent";

export interface Classification {
  outcome: AttemptOutcome;
  errorCategory: string | null;
}

/** Maps an HTTP response status to an attempt outcome + safe error category. */
export function classifyHttpStatus(status: number): Classification {
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
export function parseRetryAfterSeconds(
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
