// deno test supabase/functions/vinetrack-webhook-dispatch/lib_test.ts
//
// Covers the Stage 5A verification matrix items that live in the dispatcher:
//   * signature determinism: same secret+timestamp+body → same signature;
//     different secret / timestamp / body → different signature
//   * envelope canonical shape and key order
//   * SSRF hostname policy (mirrors SQL _integration_validate_webhook_url)
//   * private/reserved IP detection for resolved addresses
//   * HTTP status → outcome classification (2xx/3xx/4xx/408/429/5xx)
//   * Retry-After parsing and clamping

import {
  blockedHostnameReason,
  buildEnvelopeBody,
  classifyHttpStatus,
  isPrivateIpv4,
  isPrivateIpv6,
  parseRetryAfterSeconds,
  signWebhook,
  WebhookEnvelope,
} from "./lib.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

function assertEquals<T>(actual: T, expected: T, msg: string): void {
  if (actual !== expected) {
    throw new Error(`${msg}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

const sampleEvent: WebhookEnvelope = {
  id: "evt_0123456789abcdef0123456789abcdef",
  type: "trip.completed",
  api_version: "v1",
  occurred_at: "2026-08-10T01:02:03.456Z",
  vineyard_id: "3a1c2f1e-0000-4000-8000-000000000001",
  data: { id: "5b2d3e4f-0000-4000-8000-000000000002", end_time: "2026-08-10T01:00:00Z" },
};

Deno.test("envelope body is canonical and key-ordered", () => {
  const body = buildEnvelopeBody(sampleEvent);
  const keys = Object.keys(JSON.parse(body));
  assertEquals(
    keys.join(","),
    "id,type,api_version,occurred_at,vineyard_id,data",
    "envelope key order",
  );
  assert(body.includes('"type":"trip.completed"'), "type present");
});

Deno.test("signature is deterministic for identical inputs", async () => {
  const secret = "whsec_" + "ab".repeat(24);
  const body = buildEnvelopeBody(sampleEvent);
  const s1 = await signWebhook(secret, 1765324800, body);
  const s2 = await signWebhook(secret, 1765324800, body);
  assertEquals(s1, s2, "same inputs, same signature");
  assert(/^v1=[0-9a-f]{64}$/.test(s1), "signature format v1=<64 hex>");
});

Deno.test("signature changes with secret, timestamp and body", async () => {
  const body = buildEnvelopeBody(sampleEvent);
  const base = await signWebhook("whsec_secret_a", 1765324800, body);
  const otherSecret = await signWebhook("whsec_secret_b", 1765324800, body);
  const otherTs = await signWebhook("whsec_secret_a", 1765324801, body);
  const otherBody = await signWebhook("whsec_secret_a", 1765324800, body + " ");
  assert(base !== otherSecret, "secret changes signature");
  assert(base !== otherTs, "timestamp changes signature");
  assert(base !== otherBody, "body changes signature");
});

Deno.test("known HMAC vector verifies round-trip", async () => {
  // Independent receivers must be able to reproduce this exact value.
  const sig = await signWebhook("whsec_test", 1700000000, "{}");
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode("whsec_test"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const expectedOk = await crypto.subtle.verify(
    "HMAC",
    key,
    Uint8Array.from(
      (sig.slice(3).match(/.{2}/g) ?? []).map((h) => parseInt(h, 16)),
    ),
    enc.encode("1700000000.{}"),
  );
  assert(expectedOk, "signature verifies with WebCrypto verify()");
});

Deno.test("hostname SSRF policy blocks internal destinations", () => {
  const blocked = [
    "localhost",
    "api.localhost",
    "printer.local",
    "db.internal",
    "metadata.google.internal",
    "router.home.arpa",
    "127.0.0.1",
    "10.0.0.8",
    "2130706433", // decimal IP
    "0x7f000001", // hex IP
    "intranet", // single label, no public TLD
  ];
  for (const host of blocked) {
    assert(blockedHostnameReason(host) !== null, `${host} must be blocked`);
  }
  const allowed = ["hooks.example.com", "webhook.site", "my-app.fly.dev"];
  for (const host of allowed) {
    assertEquals(blockedHostnameReason(host), null, `${host} must be allowed`);
  }
});

Deno.test("private IPv4 ranges are detected", () => {
  const priv = [
    "127.0.0.1",
    "10.1.2.3",
    "172.16.0.1",
    "172.31.255.255",
    "192.168.1.1",
    "169.254.169.254",
    "100.64.0.1",
    "0.0.0.0",
    "224.0.0.1",
    "255.255.255.255",
  ];
  for (const ip of priv) assert(isPrivateIpv4(ip), `${ip} is private`);
  const pub = ["8.8.8.8", "1.1.1.1", "172.32.0.1", "100.128.0.1"];
  for (const ip of pub) assert(!isPrivateIpv4(ip), `${ip} is public`);
});

Deno.test("private IPv6 ranges are detected", () => {
  for (const ip of ["::1", "fc00::1", "fd12:3456::1", "fe80::1", "::ffff:10.0.0.1"]) {
    assert(isPrivateIpv6(ip), `${ip} is private`);
  }
  assert(!isPrivateIpv6("2606:4700:4700::1111"), "public IPv6 allowed");
});

Deno.test("HTTP status classification matches the retry policy", () => {
  assertEquals(classifyHttpStatus(200).outcome, "success", "200");
  assertEquals(classifyHttpStatus(204).outcome, "success", "204");
  assertEquals(classifyHttpStatus(301).outcome, "permanent", "301 (no redirects)");
  assertEquals(classifyHttpStatus(400).outcome, "permanent", "400");
  assertEquals(classifyHttpStatus(404).outcome, "permanent", "404");
  assertEquals(classifyHttpStatus(408).outcome, "retryable", "408");
  assertEquals(classifyHttpStatus(429).outcome, "retryable", "429");
  assertEquals(classifyHttpStatus(500).outcome, "retryable", "500");
  assertEquals(classifyHttpStatus(503).outcome, "retryable", "503");
  assertEquals(classifyHttpStatus(500).errorCategory, "http_5xx", "5xx category");
  assertEquals(classifyHttpStatus(404).errorCategory, "http_4xx", "4xx category");
});

Deno.test("Retry-After parsing honours seconds and dates, clamped to 1h", () => {
  assertEquals(parseRetryAfterSeconds("30"), 30, "delta seconds");
  assertEquals(parseRetryAfterSeconds("7200"), 3600, "clamped to 3600");
  assertEquals(parseRetryAfterSeconds(null), null, "absent header");
  assertEquals(parseRetryAfterSeconds("garbage"), null, "invalid header");
  const now = Date.parse("2026-08-10T00:00:00Z");
  assertEquals(
    parseRetryAfterSeconds("Mon, 10 Aug 2026 00:01:00 GMT", now),
    60,
    "HTTP-date delta",
  );
  assertEquals(
    parseRetryAfterSeconds("Sun, 09 Aug 2026 23:00:00 GMT", now),
    null,
    "past date ignored",
  );
});
