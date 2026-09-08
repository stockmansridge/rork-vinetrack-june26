import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { deriveRecoveryAssignments, type Coordinate, type RecoveryBlock, type RecoverySession } from "../_shared/spray-row-recovery.ts";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

function coordinate(value: unknown): Coordinate | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  const latitude = Number(raw.latitude);
  const longitude = Number(raw.longitude);
  return Number.isFinite(latitude) && Number.isFinite(longitude) ? { latitude, longitude } : null;
}

function coordinates(value: unknown): Coordinate[] {
  return Array.isArray(value) ? value.map(coordinate).filter((point): point is Coordinate => point !== null) : [];
}

function numbers(value: unknown): number[] {
  return Array.isArray(value) ? value.map(Number).filter(Number.isFinite) : [];
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && item.length > 0) : [];
}

function applicationBlockIds(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((item) => item && typeof item === "object" ? String((item as Record<string, unknown>).blockId ?? (item as Record<string, unknown>).block_id ?? "") : "").filter(Boolean);
}

function normalizeBlocks(rows: Array<Record<string, unknown>>): RecoveryBlock[] {
  return rows.map((block) => ({
    id: String(block.id),
    name: typeof block.name === "string" && block.name.trim() ? block.name : "Archived block",
    rows: Array.isArray(block.rows) ? block.rows.flatMap((raw) => {
      if (!raw || typeof raw !== "object") return [];
      const row = raw as Record<string, unknown>;
      const number = Number(row.number);
      if (!Number.isInteger(number)) return [];
      return [{ id: typeof row.id === "string" ? row.id : null, number, startPoint: coordinate(row.startPoint ?? row.start_point), endPoint: coordinate(row.endPoint ?? row.end_point) }];
    }) : [],
  }));
}

function normalizeSessions(value: unknown): RecoverySession[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const session = raw as Record<string, unknown>;
    const tank = Number(session.tankNumber ?? session.tank_number);
    return [{
      id: typeof (session.id ?? session.tank_session_id) === "string" ? String(session.id ?? session.tank_session_id) : null,
      tankNumber: Number.isInteger(tank) && tank >= 1 ? tank : null,
      pathsCovered: numbers(session.pathsCovered ?? session.paths_covered),
    }];
  });
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "Server misconfigured" }, 500);
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return json({ error: "Authentication required" }, 401);
  const user = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await user.auth.getUser();
  if (authError || !authData.user) return json({ error: "Authentication required" }, 401);
  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const tripId = typeof body.tripId === "string" ? body.tripId : "";
  if (!/^[0-9a-f-]{36}$/i.test(tripId)) return json({ error: "tripId is required" }, 400);

  const { data: trip, error: tripError } = await user.from("trips")
    .select("id,vineyard_id,paddock_id,paddock_ids,row_sequence,completed_paths,skipped_paths,path_points,tank_sessions")
    .eq("id", tripId).is("deleted_at", null).maybeSingle();
  if (tripError || !trip) return json({ error: "Trip not found or access denied" }, 404);
  const { data: membership } = await admin.from("vineyard_members").select("role")
    .eq("vineyard_id", trip.vineyard_id).eq("user_id", authData.user.id).maybeSingle();
  if (!membership || !["owner", "manager", "supervisor"].includes(String(membership.role))) return json({ error: "Recovery access required" }, 403);

  const { data: sprayRecords, error: sprayError } = await admin.from("spray_records")
    .select("id,spray_job_id,application_blocks,updated_at")
    .eq("trip_id", tripId).is("deleted_at", null).order("updated_at", { ascending: false }).limit(1);
  if (sprayError) return json({ error: "Unable to read spray evidence" }, 502);
  const spray = sprayRecords?.[0] ?? null;
  let jobBlockIds: string[] = [];
  if (spray?.spray_job_id) {
    const { data: jobBlocks, error: jobError } = await admin.from("spray_job_paddocks").select("paddock_id").eq("spray_job_id", spray.spray_job_id);
    if (jobError) return json({ error: "Unable to read saved job plan" }, 502);
    jobBlockIds = (jobBlocks ?? []).map((row) => String(row.paddock_id));
  }
  const authoritativeBlockIds = applicationBlockIds(spray?.application_blocks);
  const tripBlockIds = [...strings(trip.paddock_ids), ...(trip.paddock_id ? [String(trip.paddock_id)] : [])];
  const plannedBlockIds = [...new Set([...tripBlockIds, ...jobBlockIds])];
  const { data: paddocks, error: paddockError } = await admin.from("paddocks").select("id,name,rows")
    .eq("vineyard_id", trip.vineyard_id).is("deleted_at", null);
  if (paddockError) return json({ error: "Unable to read saved row identities" }, 502);

  const result = deriveRecoveryAssignments({
    rowSequence: numbers(trip.row_sequence),
    completedPaths: numbers(trip.completed_paths),
    skippedPaths: numbers(trip.skipped_paths),
    route: coordinates(trip.path_points),
    blocks: normalizeBlocks((paddocks ?? []) as Array<Record<string, unknown>>),
    authoritativeBlockIds,
    plannedBlockIds,
    sessions: normalizeSessions(trip.tank_sessions),
  });
  if (result.assignments.length === 0) {
    return json({ success: true, recovered: 0, unresolved: result.unresolved, evidenceVersion: "spray-row-recovery-v1" });
  }
  const operationId = crypto.randomUUID();
  const { data: recovered, error: recoveryError } = await admin.rpc("recover_spray_row_assignments_v1", {
    p_operation_id: operationId,
    p_trip_id: tripId,
    p_actor_user_id: authData.user.id,
    p_assignments: result.assignments,
  });
  if (recoveryError) return json({ error: "Unable to persist derived assignments" }, 502);
  return json({ success: true, operationId, recovered: result.assignments.length, unresolved: result.unresolved, evidenceVersion: "spray-row-recovery-v1", assignments: recovered });
});
