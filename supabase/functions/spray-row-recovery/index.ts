import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type Coordinate,
  deriveRecoveryAssignments,
  type RecoveryBlock,
  type RecoverySession,
} from "../_shared/spray-row-recovery.ts";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type RpcError = { code?: string | null; message?: string | null };
type RecoveryRpcResult = {
  status?: string;
  operationId?: string;
  requestOperationId?: string;
  assignmentFingerprint?: string;
  inserted?: number;
  preserved?: number;
  retryable?: boolean;
  retryAfterSeconds?: number;
  conflicts?: unknown[];
  evidence?: unknown[];
  message?: string;
};

type EdgeGuardEntry = {
  windowStartedAt: number;
  acceptedCount: number;
  lastStartedAt: number;
  lastOperationId: string;
  replayWindowStartedAt: number;
  replayCount: number;
};

/** Best-effort isolate-local protection; V2 repeats the guard transactionally in Postgres. */
export class RecoveryEdgeRateGuard {
  private readonly entries = new Map<string, EdgeGuardEntry>();

  check(tripId: string, operationId: string, now = Date.now()): number | null {
    const prior = this.entries.get(tripId);
    if (prior?.lastOperationId === operationId) {
      const replayCount = now - prior.replayWindowStartedAt < 2_000
        ? prior.replayCount + 1
        : 1;
      if (replayCount > 5) return 2;
      this.entries.set(tripId, {
        ...prior,
        replayWindowStartedAt: replayCount === 1
          ? now
          : prior.replayWindowStartedAt,
        replayCount,
      });
      return null;
    }
    if (prior && now - prior.lastStartedAt < 2_000) return 2;
    if (
      prior && now - prior.windowStartedAt < 60_000 && prior.acceptedCount >= 5
    ) return 60;
    const next = !prior || now - prior.windowStartedAt >= 60_000
      ? {
        windowStartedAt: now,
        acceptedCount: 1,
        lastStartedAt: now,
        lastOperationId: operationId,
        replayWindowStartedAt: now,
        replayCount: 1,
      }
      : {
        ...prior,
        acceptedCount: prior.acceptedCount + 1,
        lastStartedAt: now,
        lastOperationId: operationId,
        replayWindowStartedAt: now,
        replayCount: 1,
      };
    this.entries.set(tripId, next);
    if (this.entries.size > 1_000) {
      for (const [key, entry] of this.entries) {
        if (now - entry.windowStartedAt >= 60_000) this.entries.delete(key);
      }
    }
    return null;
  }
}

const edgeRateGuard = new RecoveryEdgeRateGuard();

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/** Accepts a caller identity unchanged, or creates one only for a new explicit request. */
export function resolveOperationId(
  value: unknown,
  create: () => string = crypto.randomUUID,
): { operationId: string; error?: string } {
  if (value === undefined || value === null || value === "") {
    return { operationId: create() };
  }
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    return { operationId: "", error: "operationId must be a UUID" };
  }
  return { operationId: value };
}

/** Database errors are retryable only when PostgreSQL identifies infrastructure unavailability. */
export function classifyRpcError(
  error: RpcError,
): { status: number; retryable: boolean } {
  const code = error.code ?? "";
  if (code === "42501") return { status: 403, retryable: false };
  if (code === "P0002" || code === "PGRST116") {
    return { status: 404, retryable: false };
  }
  if (code === "40001" || code === "55P03" || code === "23505") {
    return { status: 409, retryable: false };
  }
  if (
    code === "22023" || code === "23514" || code === "23502" || code === "22P02"
  ) return { status: 422, retryable: false };
  if (
    code.startsWith("08") || code === "57P01" || code === "57P02" ||
    code === "57P03" || code === "53300" || code === "PGRST000" ||
    code === "PGRST001" || code === "PGRST002"
  ) {
    return { status: 503, retryable: true };
  }
  return { status: 500, retryable: false };
}

/** Converts V2's explicit non-throwing outcomes into the public HTTP contract. */
export function statusForRecoveryResult(result: RecoveryRpcResult): number {
  if (
    result.status === "already_in_progress" ||
    result.status === "operation_id_conflict"
  ) return 409;
  if (result.status === "validation_failed") return 422;
  if (result.status === "rate_limited") return 429;
  return 200;
}

function coordinate(value: unknown): Coordinate | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  const latitude = Number(raw.latitude);
  const longitude = Number(raw.longitude);
  return Number.isFinite(latitude) && Number.isFinite(longitude)
    ? { latitude, longitude }
    : null;
}

function coordinates(value: unknown): Coordinate[] {
  return Array.isArray(value)
    ? value.map(coordinate).filter((point): point is Coordinate =>
      point !== null
    )
    : [];
}

function numbers(value: unknown): number[] {
  return Array.isArray(value) ? value.map(Number).filter(Number.isFinite) : [];
}

function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string =>
      typeof item === "string" && item.length > 0
    )
    : [];
}

function applicationBlockIds(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((item) =>
    item && typeof item === "object"
      ? String(
        (item as Record<string, unknown>).blockId ??
          (item as Record<string, unknown>).block_id ?? "",
      )
      : ""
  ).filter(Boolean);
}

function normalizeBlocks(
  rows: Array<Record<string, unknown>>,
): RecoveryBlock[] {
  return rows.map((block) => ({
    id: String(block.id),
    name: typeof block.name === "string" && block.name.trim()
      ? block.name
      : "Archived block",
    rows: Array.isArray(block.rows)
      ? block.rows.flatMap((raw) => {
        if (!raw || typeof raw !== "object") return [];
        const row = raw as Record<string, unknown>;
        const number = Number(row.number);
        if (!Number.isInteger(number)) return [];
        return [{
          id: typeof row.id === "string" ? row.id : null,
          number,
          startPoint: coordinate(row.startPoint ?? row.start_point),
          endPoint: coordinate(row.endPoint ?? row.end_point),
        }];
      })
      : [],
  }));
}

function normalizeSessions(value: unknown): RecoverySession[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const session = raw as Record<string, unknown>;
    const tank = Number(session.tankNumber ?? session.tank_number);
    return [{
      id: typeof (session.id ?? session.tank_session_id) === "string"
        ? String(session.id ?? session.tank_session_id)
        : null,
      tankNumber: Number.isInteger(tank) && tank >= 1 ? tank : null,
      pathsCovered: numbers(session.pathsCovered ?? session.paths_covered),
    }];
  });
}

function evidencePathNumber(value: unknown): number | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  const original = row.original_evidence;
  const candidate = original && typeof original === "object"
    ? Number((original as Record<string, unknown>).pathNumber)
    : Number(row.row_number);
  return Number.isFinite(candidate) ? candidate : null;
}

function samePath(left: number, right: number): boolean {
  return Math.abs(left - right) < 0.000_001;
}

export async function handler(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed", retryable: false }, 405);
  }
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return json({ error: "Server misconfigured", retryable: false }, 500);
  }
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Authentication required", retryable: false }, 401);
  }
  const user = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await user.auth.getUser();
  if (authError || !authData.user) {
    return json({ error: "Authentication required", retryable: false }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid JSON", retryable: false }, 400);
  }
  const tripId = typeof body.tripId === "string"
    ? body.tripId.toLowerCase()
    : "";
  if (!UUID_PATTERN.test(tripId)) {
    return json({ error: "tripId must be a UUID", retryable: false }, 400);
  }
  const operation = resolveOperationId(body.operationId);
  if (operation.error) {
    return json({ error: operation.error, retryable: false }, 400);
  }
  const operationId = operation.operationId;
  const retryAfterSeconds = edgeRateGuard.check(tripId, operationId);
  if (retryAfterSeconds !== null) {
    return json({
      error: "Recovery request rate limited for this trip",
      status: "rate_limited",
      operationId,
      retryable: false,
      retryAfterSeconds,
    }, 429);
  }

  const { data: trip, error: tripError } = await user.from("trips")
    .select(
      "id,vineyard_id,paddock_id,paddock_ids,row_sequence,completed_paths,skipped_paths,path_points,tank_sessions",
    )
    .eq("id", tripId).is("deleted_at", null).maybeSingle();
  if (tripError) {
    const classification = classifyRpcError(tripError);
    return json(
      {
        error: "Unable to read trip",
        operationId,
        retryable: classification.retryable,
      },
      classification.status,
    );
  }
  if (!trip) {
    return json({
      error: "Trip not found or access denied",
      operationId,
      retryable: false,
    }, 404);
  }
  const { data: membership, error: membershipError } = await admin.from(
    "vineyard_members",
  ).select("role")
    .eq("vineyard_id", trip.vineyard_id).eq("user_id", authData.user.id)
    .maybeSingle();
  if (membershipError) {
    const classification = classifyRpcError(membershipError);
    return json({
      error: "Unable to verify recovery access",
      operationId,
      retryable: classification.retryable,
    }, classification.status);
  }
  if (
    !membership ||
    !["owner", "manager", "supervisor"].includes(String(membership.role))
  ) {
    return json({
      error: "Recovery access required",
      operationId,
      retryable: false,
    }, 403);
  }

  // Historical evidence is read first and remains authoritative even if today's
  // paddock rows or geometry differ from what existed at recovery time.
  const { data: existingEvidence, error: evidenceError } = await admin.from(
    "spray_row_assignment_evidence",
  )
    .select("*").eq("trip_id", tripId).order("derived_at", { ascending: true });
  if (evidenceError) {
    const classification = classifyRpcError(evidenceError);
    return json({
      error: "Unable to read historical row evidence",
      operationId,
      retryable: classification.retryable,
    }, classification.status);
  }
  const existingPaths = (existingEvidence ?? []).map(evidencePathNumber).filter(
    (value): value is number => value !== null,
  );
  const recordedSequence = numbers(trip.row_sequence);
  const missingSequence = recordedSequence.filter((path) =>
    !existingPaths.some((existing) => samePath(existing, path))
  );
  if (missingSequence.length === 0) {
    return json({
      success: true,
      status: existingPaths.length > 0 ? "already_recovered" : "no_assignments",
      operationId,
      recovered: 0,
      preserved: existingEvidence?.length ?? 0,
      unresolved: [],
      evidenceVersion: "spray-row-recovery-v1",
      assignments: existingEvidence ?? [],
      retryable: false,
    });
  }

  const { data: sprayRecords, error: sprayError } = await admin.from(
    "spray_records",
  )
    .select("id,spray_job_id,application_blocks,updated_at")
    .eq("trip_id", tripId).is("deleted_at", null).order("updated_at", {
      ascending: false,
    }).limit(1);
  if (sprayError) {
    const classification = classifyRpcError(sprayError);
    return json({
      error: "Unable to read spray evidence",
      operationId,
      retryable: classification.retryable,
    }, classification.status);
  }
  const spray = sprayRecords?.[0] ?? null;
  let jobBlockIds: string[] = [];
  if (spray?.spray_job_id) {
    const { data: jobBlocks, error: jobError } = await admin.from(
      "spray_job_paddocks",
    ).select("paddock_id").eq("spray_job_id", spray.spray_job_id);
    if (jobError) {
      const classification = classifyRpcError(jobError);
      return json({
        error: "Unable to read saved job plan",
        operationId,
        retryable: classification.retryable,
      }, classification.status);
    }
    jobBlockIds = (jobBlocks ?? []).map((row) => String(row.paddock_id));
  }
  const authoritativeBlockIds = applicationBlockIds(spray?.application_blocks);
  const tripBlockIds = [
    ...strings(trip.paddock_ids),
    ...(trip.paddock_id ? [String(trip.paddock_id)] : []),
  ];
  const plannedBlockIds = [...new Set([...tripBlockIds, ...jobBlockIds])];
  const { data: paddocks, error: paddockError } = await admin.from("paddocks")
    .select("id,name,rows")
    .eq("vineyard_id", trip.vineyard_id).is("deleted_at", null);
  if (paddockError) {
    const classification = classifyRpcError(paddockError);
    return json({
      error: "Unable to read saved row identities",
      operationId,
      retryable: classification.retryable,
    }, classification.status);
  }

  const result = deriveRecoveryAssignments({
    rowSequence: missingSequence,
    completedPaths: numbers(trip.completed_paths).filter((path) =>
      !existingPaths.some((existing) => samePath(existing, path))
    ),
    skippedPaths: numbers(trip.skipped_paths).filter((path) =>
      !existingPaths.some((existing) => samePath(existing, path))
    ),
    route: coordinates(trip.path_points),
    blocks: normalizeBlocks((paddocks ?? []) as Array<Record<string, unknown>>),
    authoritativeBlockIds,
    plannedBlockIds,
    sessions: normalizeSessions(trip.tank_sessions),
  });
  const missingAssignments = result.assignments.filter((assignment) =>
    !existingPaths.some((path) => samePath(path, assignment.rowNumber))
  );
  if (missingAssignments.length === 0) {
    return json({
      success: true,
      status: existingPaths.length > 0 ? "already_recovered" : "no_assignments",
      operationId,
      recovered: 0,
      preserved: existingEvidence?.length ?? 0,
      unresolved: result.unresolved,
      evidenceVersion: "spray-row-recovery-v1",
      assignments: existingEvidence ?? [],
      retryable: false,
    });
  }

  const { data: recovered, error: recoveryError } = await admin.rpc(
    "recover_spray_row_assignments_v2",
    {
      p_operation_id: operationId,
      p_trip_id: tripId,
      p_actor_user_id: authData.user.id,
      p_assignments: missingAssignments,
    },
  );
  if (recoveryError) {
    const classification = classifyRpcError(recoveryError);
    return json({
      error: classification.status === 503
        ? "Recovery backend temporarily unavailable"
        : recoveryError.message ?? "Recovery request rejected",
      code: recoveryError.code,
      operationId,
      retryable: classification.retryable,
    }, classification.status);
  }

  const rpcResult = (recovered ?? {}) as RecoveryRpcResult;
  const status = statusForRecoveryResult(rpcResult);
  return json({
    success: status === 200,
    ...rpcResult,
    operationId: rpcResult.operationId ?? operationId,
    requestOperationId: rpcResult.requestOperationId ?? operationId,
    recovered: rpcResult.inserted ?? 0,
    unresolved: result.unresolved,
    evidenceVersion: "spray-row-recovery-v1",
    assignments: rpcResult.evidence ?? [],
    retryable: rpcResult.retryable ?? false,
  }, status);
}

if (import.meta.main) Deno.serve(handler);
