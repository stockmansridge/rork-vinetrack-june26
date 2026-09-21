import {
  assertEquals,
  assertMatch,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  classifyRpcError,
  RecoveryEdgeRateGuard,
  resolveOperationId,
  statusForRecoveryResult,
} from "./index.ts";

Deno.test("caller operation id is preserved exactly across retries", () => {
  const supplied = "A1B2C3D4-0000-4000-8000-000000000001";
  assertEquals(resolveOperationId(supplied).operationId, supplied);
  assertEquals(resolveOperationId(supplied).operationId, supplied);
});

Deno.test("a first request without an operation id receives a valid generated id", () => {
  const result = resolveOperationId(
    undefined,
    () => "a1b2c3d4-0000-4000-8000-000000000002",
  );
  assertMatch(result.operationId, /^[0-9a-f-]{36}$/);
});

Deno.test("malformed operation identities are rejected rather than replaced", () => {
  assertEquals(
    resolveOperationId("retry-me").error,
    "operationId must be a UUID",
  );
});

Deno.test("deterministic database conflicts are never advertised as transient", () => {
  assertEquals(classifyRpcError({ code: "40001" }), {
    status: 409,
    retryable: false,
  });
  assertEquals(classifyRpcError({ code: "22023" }), {
    status: 422,
    retryable: false,
  });
  assertEquals(classifyRpcError({ code: "42501" }), {
    status: 403,
    retryable: false,
  });
  assertEquals(classifyRpcError({ code: "P0002" }), {
    status: 404,
    retryable: false,
  });
});

Deno.test("only infrastructure error classes are 503 and retryable", () => {
  assertEquals(classifyRpcError({ code: "08006" }), {
    status: 503,
    retryable: true,
  });
  assertEquals(classifyRpcError({ code: "57P03" }), {
    status: 503,
    retryable: true,
  });
  assertEquals(classifyRpcError({ code: "PGRST000" }), {
    status: 503,
    retryable: true,
  });
  assertEquals(classifyRpcError({ code: "XX000" }), {
    status: 500,
    retryable: false,
  });
});

Deno.test("V2 result statuses map to bounded public outcomes", () => {
  assertEquals(statusForRecoveryResult({ status: "already_recovered" }), 200);
  assertEquals(statusForRecoveryResult({ status: "recovered" }), 200);
  assertEquals(statusForRecoveryResult({ status: "already_in_progress" }), 409);
  assertEquals(
    statusForRecoveryResult({ status: "historical_evidence_preserved" }),
    409,
  );
  assertEquals(statusForRecoveryResult({ status: "rate_limited" }), 429);
});

Deno.test("a rapid logical retry loop keeps one caller operation identity", () => {
  const supplied = "a1b2c3d4-0000-4000-8000-000000000003";
  const ids = Array.from(
    { length: 1_000 },
    () => resolveOperationId(supplied).operationId,
  );
  assertEquals(new Set(ids), new Set([supplied]));
});

Deno.test("rapid repeated recovery calls are stopped before backend work", () => {
  const guard = new RecoveryEdgeRateGuard();
  const tripId = "a1b2c3d4-0000-4000-8000-000000000004";
  assertEquals(guard.check(tripId, 1_000), null);
  const blocked = Array.from({ length: 999 }, () => guard.check(tripId, 1_001));
  assertEquals(blocked.every((retryAfter) => retryAfter === 2), true);
});

Deno.test("novel attempts are capped per trip even when spaced beyond the burst guard", () => {
  const guard = new RecoveryEdgeRateGuard();
  const tripId = "a1b2c3d4-0000-4000-8000-000000000005";
  assertEquals(
    [0, 2, 4, 6, 8].map((seconds) => guard.check(tripId, seconds * 1_000)),
    [null, null, null, null, null],
  );
  assertEquals(guard.check(tripId, 10_000), 60);
});
