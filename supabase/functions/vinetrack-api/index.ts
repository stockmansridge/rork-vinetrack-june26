// Supabase Edge Function: vinetrack-api
//
// VineTrack public read-only API gateway — Stage 3A + Stage 3B.
//
// Routes (versioned; the route version is authoritative):
//   GET /v1/me
//   GET /v1/vineyards
//   GET /v1/vineyards/{vineyard_id}
//   GET /v1/blocks?vineyard_id=<uuid>
//   GET /v1/blocks/{block_id}
//   GET /v1/trips?vineyard_id=<uuid>[&from=&to=&equipment_id=]          (3B)
//   GET /v1/trips/{trip_id}                                             (3B)
//   GET /v1/spray-jobs?vineyard_id=<uuid>[&from=&to=]                   (3B)
//   GET /v1/spray-jobs/{spray_job_id}                                   (3B)
//   GET /v1/fuel-records?vineyard_id=<uuid>[&from=&to=&equipment_id=]   (3B)
//   GET /v1/fuel-records/{fuel_record_id}                               (3B)
//   GET /v1/fuel-purchases?vineyard_id=<uuid>[&from=&to=]               (3B)
//   GET /v1/fuel-purchases/{fuel_purchase_id}                           (3B)
//   GET /v1/equipment?vineyard_id=<uuid>[&type=]                        (3B)
//   GET /v1/equipment/{equipment_id}                                    (3B)
//
// Authentication:  Authorization: Bearer vt_live_... / vt_test_...
//   - Supabase JWTs are NOT accepted as integration credentials.
//   - Query-string credentials are rejected.
//   - The presented key is hashed inside Postgres (SQL 172 convention);
//     the plaintext is never stored or logged anywhere.
//
// Every request:
//   parse -> request id -> authenticate -> integration active -> key not
//   expired/revoked -> rate limit -> scope -> explicit vineyard grant ->
//   query canonical data -> stable external mapping -> safe log -> envelope.
//
// Per-vineyard resources are validated by SQL 172's
// integration_validate_api_request() (the canonical five-check validator).
// /v1/me and /v1/vineyards use SQL 173's integration_authenticate_api_key()
// (checks 1-4 + safe profile) because they have no single-vineyard context.
//
// Sensitive-scope field gating (Stage 3B):
//   Base resource scopes (trips:read, sprays:read, fuel:read,
//   equipment:read) expose OPERATIONAL data only. Cost/financial fields
//   additionally require costs:read; operator/labour identity fields
//   additionally require labour:read. Sensitive scopes NEVER grant access
//   to a resource on their own — the base resource scope is always
//   required. Sensitive fields are OMITTED (not nulled) when the extra
//   scope is absent.
//
// DEPLOY with --no-verify-jwt (external callers present VineTrack API keys,
// not Supabase JWTs):
//   supabase functions deploy vinetrack-api --project-ref tbafuqwruefgkbyxrxyb --no-verify-jwt
//
// Secrets: uses only the standard Supabase-injected SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY. Optional configuration:
//   VINETRACK_API_RATE_LIMIT_PER_MINUTE (default 300)
//   VINETRACK_API_CORS_ORIGINS (comma-separated exact origins; default none)

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const API_VERSION = "v1";
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 1000;

// ---------------------------------------------------------------------------
// Error catalogue — stable machine-readable codes.
// ---------------------------------------------------------------------------
const ERRORS: Record<string, { status: number; message: string }> = {
  missing_api_key: { status: 401, message: "No API key was provided. Send it as: Authorization: Bearer <API_KEY>." },
  invalid_api_key: { status: 401, message: "The supplied API key is invalid." },
  expired_api_key: { status: 401, message: "The supplied API key has expired." },
  revoked_api_key: { status: 401, message: "The supplied API key has been revoked." },
  integration_not_active: { status: 403, message: "This integration is paused or revoked." },
  insufficient_scope: { status: 403, message: "This integration has not been granted the scope required for this endpoint." },
  vineyard_access_denied: { status: 403, message: "This integration is not authorised for the requested vineyard." },
  resource_not_found: { status: 404, message: "The requested resource does not exist." },
  invalid_request: { status: 400, message: "The request is invalid." },
  invalid_cursor: { status: 400, message: "The supplied pagination cursor is invalid." },
  rate_limit_exceeded: { status: 429, message: "The API request limit has been exceeded." },
  method_not_allowed: { status: 405, message: "This API is read-only. Only GET is supported." },
  internal_error: { status: 500, message: "An internal error occurred. Contact support and quote the request_id." },
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

interface AuthProfile {
  valid: boolean;
  failure_code?: string;
  integration_client_id?: string;
  api_key_id?: string;
  environment?: string;
  integration_name?: string;
  status?: string;
  scopes?: string[];
  vineyards?: { id: string; name: string }[];
}

interface RequestContext {
  requestId: string;
  method: string;
  /** Canonical route template for logging, e.g. /v1/trips/{trip_id} */
  canonicalPath: string;
  startedAt: number;
  integrationClientId: string | null;
  apiKeyId: string | null;
  vineyardId: string | null;
  rateHeaders: Record<string, string>;
}

function newRequestId(): string {
  return "req_" + crypto.randomUUID().replaceAll("-", "");
}

function corsHeaders(req: Request): Record<string, string> {
  const allowlist = (Deno.env.get("VINETRACK_API_CORS_ORIGINS") ?? "")
    .split(",").map((s) => s.trim()).filter(Boolean);
  const origin = req.headers.get("origin") ?? "";
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
  if (origin && allowlist.includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Vary"] = "Origin";
  }
  return headers;
}

function jsonResponse(
  req: Request,
  ctx: RequestContext,
  body: unknown,
  status: number,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "X-VineTrack-Request-ID": ctx.requestId,
      "X-VineTrack-API-Version": API_VERSION,
      ...ctx.rateHeaders,
      ...corsHeaders(req),
      ...extraHeaders,
    },
  });
}

class ApiError extends Error {
  code: string;
  constructor(code: string) {
    super(code);
    this.code = ERRORS[code] ? code : "internal_error";
  }
}

function errorResponse(req: Request, ctx: RequestContext, code: string, extraHeaders: Record<string, string> = {}): Response {
  const def = ERRORS[code] ?? ERRORS.internal_error;
  // Every gateway error — including 403 vineyard_access_denied — carries the
  // documented JSON envelope. Regression-tested by scripts/test-vinetrack-api.sh.
  return jsonResponse(req, ctx, {
    error: { code, message: def.message, request_id: ctx.requestId },
  }, def.status, extraHeaders);
}

// ---------------------------------------------------------------------------
// Pagination — opaque keyset cursor over (created_at, id). Deterministic in
// both directions: structural resources iterate ascending (Stage 3A
// behaviour, unchanged); operational/chronological resources iterate
// created_at DESC, id DESC (newest first). No duplicates or gaps.
// ---------------------------------------------------------------------------
interface Cursor { t: string; id: string }

function encodeCursor(c: Cursor): string {
  return btoa(JSON.stringify(c)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeCursor(raw: string): Cursor {
  try {
    const b64 = raw.replaceAll("-", "+").replaceAll("_", "/");
    const parsed = JSON.parse(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)));
    if (typeof parsed?.t !== "string" || typeof parsed?.id !== "string" || !UUID_RE.test(parsed.id)) {
      throw new Error("bad cursor");
    }
    if (Number.isNaN(Date.parse(parsed.t))) throw new Error("bad cursor timestamp");
    return { t: parsed.t, id: parsed.id };
  } catch {
    throw new ApiError("invalid_cursor");
  }
}

function parseLimit(raw: string | null): number {
  if (raw === null) return DEFAULT_LIMIT;
  if (!/^\d+$/.test(raw)) throw new ApiError("invalid_request");
  const n = Number(raw);
  if (n < 1 || n > MAX_LIMIT) throw new ApiError("invalid_request");
  return n;
}

/** Reject any query parameter that is not explicitly allowlisted. */
function enforceAllowedParams(url: URL, allowed: string[]): void {
  for (const key of url.searchParams.keys()) {
    if (!allowed.includes(key)) throw new ApiError("invalid_request");
  }
}

/** Validate an ISO date query parameter (YYYY-MM-DD, real calendar date). */
function parseDateParam(raw: string | null): string | null {
  if (raw === null) return null;
  if (!DATE_RE.test(raw)) throw new ApiError("invalid_request");
  const ms = Date.parse(raw + "T00:00:00Z");
  if (Number.isNaN(ms)) throw new ApiError("invalid_request");
  // Reject non-real dates like 2026-02-31 (Date.parse rolls them over).
  const d = new Date(ms);
  if (d.toISOString().slice(0, 10) !== raw) throw new ApiError("invalid_request");
  return raw;
}

/** Day after an ISO date — used for exclusive `to` upper bounds. */
function nextDay(iso: string): string {
  const d = new Date(Date.parse(iso + "T00:00:00Z") + 86_400_000);
  return d.toISOString().slice(0, 10);
}

/** Coerce a loosely-typed jsonb value into a finite number or null. */
function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function round3(v: number): number {
  return Math.round(v * 1000) / 1000;
}

// ---------------------------------------------------------------------------
// Authentication helpers
// ---------------------------------------------------------------------------
function extractApiKey(req: Request, url: URL): string {
  // Never accept credentials in the query string.
  for (const key of url.searchParams.keys()) {
    if (["api_key", "apikey", "key", "token", "authorization"].includes(key.toLowerCase())) {
      throw new ApiError("invalid_request");
    }
  }
  const header = req.headers.get("authorization");
  if (!header) throw new ApiError("missing_api_key");
  const match = header.match(/^Bearer\s+(\S+)$/i);
  if (!match) throw new ApiError("invalid_api_key");
  const key = match[1];
  // Supabase JWTs / anything not shaped like a VineTrack key are refused.
  if (!/^vt_(live|test)_[0-9a-f]{48}$/.test(key)) throw new ApiError("invalid_api_key");
  return key;
}

function mapAuthFailure(code: string | undefined): string {
  switch (code) {
    case "invalid_key": return "invalid_api_key";
    case "key_revoked": return "revoked_api_key";
    case "key_expired": return "expired_api_key";
    case "integration_not_active": return "integration_not_active";
    case "scope_not_granted": return "insufficient_scope";
    case "vineyard_not_granted": return "vineyard_access_denied";
    default: return "invalid_api_key";
  }
}

async function authenticate(db: SupabaseClient, key: string): Promise<AuthProfile> {
  const { data, error } = await db.rpc("integration_authenticate_api_key", { p_presented_key: key });
  if (error) {
    console.error("[vinetrack-api] authenticate rpc failed:", error.message);
    throw new ApiError("internal_error");
  }
  return data as AuthProfile;
}

/**
 * SQL 172 canonical five-check validator for per-vineyard resources.
 * Returns nothing on success, throws mapped ApiError on failure.
 * `notFoundOnDenied` controls non-disclosure for direct resource fetches.
 */
async function validateVineyardRequest(
  db: SupabaseClient,
  key: string,
  scope: string,
  vineyardId: string,
  notFoundOnDenied: boolean,
): Promise<void> {
  const { data, error } = await db.rpc("integration_validate_api_request", {
    p_presented_key: key,
    p_required_scope: scope,
    p_vineyard_id: vineyardId,
  });
  if (error) {
    console.error("[vinetrack-api] validate rpc failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data?.valid) {
    const mapped = mapAuthFailure(data?.failure_code);
    if (mapped === "vineyard_access_denied" && notFoundOnDenied) {
      // Cross-account resource ids must not be discoverable.
      throw new ApiError("resource_not_found");
    }
    throw new ApiError(mapped);
  }
}

async function checkRateLimit(db: SupabaseClient, ctx: RequestContext, apiKeyId: string): Promise<void> {
  const limit = Number(Deno.env.get("VINETRACK_API_RATE_LIMIT_PER_MINUTE") ?? "300") || 300;
  const { data, error } = await db.rpc("integration_check_rate_limit", {
    p_api_key_id: apiKeyId,
    p_limit: limit,
  });
  if (error) {
    console.error("[vinetrack-api] rate limit rpc failed:", error.message);
    throw new ApiError("internal_error");
  }
  ctx.rateHeaders["X-RateLimit-Limit"] = String(data?.limit ?? limit);
  ctx.rateHeaders["X-RateLimit-Remaining"] = String(data?.remaining ?? 0);
  if (!data?.allowed) {
    ctx.rateHeaders["Retry-After"] = String(data?.retry_after_seconds ?? 60);
    throw new ApiError("rate_limit_exceeded");
  }
}

function requireScope(profile: AuthProfile, scope: string): void {
  if (!profile.scopes?.includes(scope)) throw new ApiError("insufficient_scope");
}

/** Sensitive-scope check for FIELD gating (never grants resource access). */
function hasScope(profile: AuthProfile, scope: string): boolean {
  return profile.scopes?.includes(scope) ?? false;
}

// ---------------------------------------------------------------------------
// External resource mapping — deliberately stable, never `select *`.
// ---------------------------------------------------------------------------
interface VineyardRow {
  id: string; name: string; country: string | null; country_code: string | null;
  timezone: string | null; created_at: string; updated_at: string;
}

function mapVineyard(row: VineyardRow) {
  return {
    id: row.id,
    name: row.name,
    country_code: row.country_code ?? null,
    country: row.country ?? null,
    timezone: row.timezone ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

const VINEYARD_COLUMNS = "id, name, country, country_code, timezone, created_at, updated_at";

interface BlockRow {
  id: string; vineyard_id: string; name: string; planting_year: number | null;
  row_width: number | null; vine_spacing: number | null;
  rows: unknown; variety_allocations: unknown;
  created_at: string; updated_at: string;
}

function mapBlock(row: BlockRow) {
  const rowCount = Array.isArray(row.rows) ? row.rows.length : null;
  const varieties = Array.isArray(row.variety_allocations)
    ? (row.variety_allocations as Record<string, unknown>[])
      .map((v) => ({
        name: (v?.name ?? v?.varietyName ?? null) as string | null,
        percent: (v?.percent ?? v?.percentage ?? null) as number | null,
      }))
      .filter((v) => v.name !== null)
    : [];
  return {
    id: row.id,
    vineyard_id: row.vineyard_id,
    name: row.name,
    planting_year: row.planting_year ?? null,
    row_count: rowCount,
    row_width_m: row.row_width ?? null,
    vine_spacing_m: row.vine_spacing ?? null,
    varieties,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

// Boundary geometry (polygon_points) and per-row geometry are intentionally
// NOT exposed — exposing geometry is a future explicit decision.
const BLOCK_COLUMNS =
  "id, vineyard_id, name, planting_year, row_width, vine_spacing, rows, variety_allocations, created_at, updated_at";

// ---------------------------------------------------------------------------
// Equipment resolution (canonical machine model).
//
// vineyard_machines is the canonical machine catalogue (sql/097): legacy
// public.tractors rows are backfilled into it with machine_type='tractor'
// and legacy_tractor_id set. Operational records may reference machines via
// the preferred machine_id OR the legacy tractor_id — both resolve to the
// same canonical vineyard_machines row here, so external equipment_id is
// ALWAYS a vineyard_machines.id.
// ---------------------------------------------------------------------------
interface MachineRow {
  id: string; vineyard_id: string; name: string; machine_type: string | null;
  fuel_usage_l_per_hour: number | null; legacy_tractor_id: string | null;
  serial_number: string | null; vin_number: string | null;
  created_at: string; updated_at: string; deleted_at: string | null;
}

const MACHINE_COLUMNS =
  "id, vineyard_id, name, machine_type, fuel_usage_l_per_hour, legacy_tractor_id, serial_number, vin_number, created_at, updated_at, deleted_at";

interface MachineIndex {
  byId: Map<string, MachineRow>;
  byLegacyTractorId: Map<string, MachineRow>;
}

/**
 * Loads the machine catalogue for one vineyard INCLUDING soft-deleted rows —
 * historical trips/fuel logs may reference a machine that has since been
 * deleted, and their display name should still resolve. Deleted machines are
 * excluded from /v1/equipment listings separately.
 */
async function loadMachineIndex(db: SupabaseClient, vineyardId: string): Promise<MachineIndex> {
  const { data, error } = await db.from("vineyard_machines")
    .select(MACHINE_COLUMNS)
    .eq("vineyard_id", vineyardId);
  if (error) {
    console.error("[vinetrack-api] machine index query failed:", error.message);
    throw new ApiError("internal_error");
  }
  const byId = new Map<string, MachineRow>();
  const byLegacyTractorId = new Map<string, MachineRow>();
  for (const raw of (data ?? []) as unknown as MachineRow[]) {
    byId.set(raw.id, raw);
    if (raw.legacy_tractor_id) byLegacyTractorId.set(raw.legacy_tractor_id, raw);
  }
  return { byId, byLegacyTractorId };
}

/** Resolve a record's machine link (preferred machine_id, legacy tractor_id). */
function resolveMachine(idx: MachineIndex, machineId: string | null, tractorId: string | null): MachineRow | null {
  if (machineId) {
    const m = idx.byId.get(machineId);
    if (m) return m;
  }
  if (tractorId) {
    const m = idx.byLegacyTractorId.get(tractorId);
    if (m) return m;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Keyset-paginated list query helper.
// ---------------------------------------------------------------------------
// deno-lint-ignore no-explicit-any
type FilterFn = (q: any) => any;

async function pagedList<T extends { created_at: string; id: string }>(
  db: SupabaseClient,
  table: string,
  columns: string,
  limit: number,
  cursor: Cursor | null,
  ascending: boolean,
  applyFilters: FilterFn,
): Promise<{ rows: T[]; nextCursor: string | null }> {
  let query = db.from(table).select(columns)
    .is("deleted_at", null)
    .order("created_at", { ascending })
    .order("id", { ascending })
    .limit(limit + 1);
  query = applyFilters(query);
  if (cursor) {
    const op = ascending ? "gt" : "lt";
    query = query.or(
      `created_at.${op}.${cursor.t},and(created_at.eq.${cursor.t},id.${op}.${cursor.id})`,
    );
  }
  const { data, error } = await query;
  if (error) {
    console.error(`[vinetrack-api] ${table} query failed:`, error.message);
    throw new ApiError("internal_error");
  }
  const rows = (data ?? []) as unknown as T[];
  let nextCursor: string | null = null;
  if (rows.length > limit) {
    rows.length = limit;
    const last = rows[rows.length - 1];
    nextCursor = encodeCursor({ t: last.created_at, id: last.id });
  }
  return { rows, nextCursor };
}

/** Apply an optional [from, to] ISO-date range to a timestamptz column. */
function applyDateRange(fromDate: string | null, toDate: string | null, column: string): FilterFn {
  // deno-lint-ignore no-explicit-any
  return (q: any) => {
    if (fromDate) q = q.gte(column, fromDate);
    if (toDate) q = q.lt(column, nextDay(toDate));
    return q;
  };
}

// ---------------------------------------------------------------------------
// Trips (public.trips, sql/006 + additive columns).
// ---------------------------------------------------------------------------
interface TripRow {
  id: string; vineyard_id: string;
  trip_title: string | null; trip_function: string | null;
  start_time: string | null; end_time: string | null;
  is_active: boolean; is_paused: boolean;
  total_distance: number | null;
  paddock_id: string | null; paddock_ids: unknown; paddock_name: string | null;
  machine_id: string | null; tractor_id: string | null;
  operator_user_id: string | null; person_name: string | null;
  work_task_id: string | null; total_tanks: number | null;
  completion_notes: string | null;
  start_engine_hours: number | null; end_engine_hours: number | null;
  pause_timestamps: unknown; resume_timestamps: unknown;
  created_at: string; updated_at: string;
  // detail only
  row_sequence?: unknown; completed_paths?: unknown; skipped_paths?: unknown;
}

const TRIP_LIST_COLUMNS =
  "id, vineyard_id, trip_title, trip_function, start_time, end_time, is_active, is_paused, " +
  "total_distance, paddock_id, paddock_ids, paddock_name, machine_id, tractor_id, " +
  "operator_user_id, person_name, work_task_id, total_tanks, completion_notes, " +
  "start_engine_hours, end_engine_hours, pause_timestamps, resume_timestamps, created_at, updated_at";

const TRIP_DETAIL_COLUMNS = TRIP_LIST_COLUMNS + ", row_sequence, completed_paths, skipped_paths";

/**
 * Pause-aware trip duration in whole minutes, mirroring the canonical
 * client calculation (iOS Trip.activeDuration / Android
 * activeDurationSecondsAt). Only computed for ENDED trips — an active trip
 * has no stable duration and returns null. An unpaired trailing pause
 * freezes time at the pause moment.
 */
function tripDurationMinutes(row: TripRow): number | null {
  if (!row.start_time || !row.end_time) return null;
  const start = Date.parse(row.start_time);
  const end = Date.parse(row.end_time);
  if (Number.isNaN(start) || Number.isNaN(end) || end < start) return null;
  const pauses = Array.isArray(row.pause_timestamps) ? row.pause_timestamps : [];
  const resumes = Array.isArray(row.resume_timestamps) ? row.resume_timestamps : [];
  let pausedMs = 0;
  for (let i = 0; i < pauses.length; i++) {
    const p = typeof pauses[i] === "string" ? Date.parse(pauses[i] as string) : NaN;
    if (Number.isNaN(p)) continue;
    const rRaw = typeof resumes[i] === "string" ? Date.parse(resumes[i] as string) : NaN;
    const r = Number.isNaN(rRaw) ? end : rRaw;
    const from = Math.max(p, start);
    const to = Math.min(r, end);
    if (to > from) pausedMs += to - from;
  }
  return Math.max(0, Math.round((end - start - pausedMs) / 60_000));
}

function tripStatus(row: TripRow): string {
  if (row.is_active) return row.is_paused ? "paused" : "active";
  return "completed";
}

function tripBlockIds(row: TripRow): string[] {
  const ids = Array.isArray(row.paddock_ids)
    ? (row.paddock_ids as unknown[]).filter((v): v is string => typeof v === "string")
    : [];
  if (ids.length > 0) return [...new Set(ids)];
  return row.paddock_id ? [row.paddock_id] : [];
}

function mapTripSummary(row: TripRow, idx: MachineIndex, profile: AuthProfile) {
  const machine = resolveMachine(idx, row.machine_id, row.tractor_id);
  const base: Record<string, unknown> = {
    id: row.id,
    vineyard_id: row.vineyard_id,
    title: row.trip_title ?? null,
    function: row.trip_function ?? null,
    status: tripStatus(row),
    started_at: row.start_time ?? null,
    ended_at: row.end_time ?? null,
    duration_minutes: tripDurationMinutes(row),
    // trips.total_distance is stored in METRES (GPS tracker convention).
    distance_km: row.total_distance !== null ? round3(row.total_distance / 1000) : null,
    block_ids: tripBlockIds(row),
    block_name: row.paddock_name ?? null,
    equipment_id: machine?.id ?? null,
    equipment_name: machine ? (machine.name.trim() || null) : null,
    work_task_id: row.work_task_id ?? null,
    tank_count: row.total_tanks ?? null,
    engine_hours_start: row.start_engine_hours ?? null,
    engine_hours_end: row.end_engine_hours ?? null,
    notes: row.completion_notes ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  // Operator identity is labour-sensitive: omitted without labour:read.
  if (hasScope(profile, "labour:read")) {
    base.operator = (row.operator_user_id || row.person_name)
      ? { user_id: row.operator_user_id ?? null, name: row.person_name ?? null }
      : null;
  }
  return base;
}

interface TripCostSums {
  labour_cost: number | null; fuel_cost: number | null;
  chemical_cost: number | null; input_cost: number | null; total_cost: number | null;
}

/** Sums active trip_cost_allocations rows for one trip (costs:read gated). */
async function loadTripCosts(db: SupabaseClient, tripId: string): Promise<TripCostSums | null> {
  const { data, error } = await db.from("trip_cost_allocations")
    .select("labour_cost, fuel_cost, chemical_cost, input_cost, total_cost")
    .eq("trip_id", tripId)
    .is("deleted_at", null);
  if (error) {
    console.error("[vinetrack-api] trip cost query failed:", error.message);
    throw new ApiError("internal_error");
  }
  const rows = (data ?? []) as { labour_cost: number | null; fuel_cost: number | null; chemical_cost: number | null; input_cost: number | null; total_cost: number | null }[];
  if (rows.length === 0) return null;
  const sum = (pick: (r: typeof rows[number]) => number | null): number | null => {
    let acc: number | null = null;
    for (const r of rows) {
      const v = pick(r);
      if (v !== null) acc = (acc ?? 0) + v;
    }
    return acc !== null ? round3(acc) : null;
  };
  return {
    labour_cost: sum((r) => r.labour_cost),
    fuel_cost: sum((r) => r.fuel_cost),
    chemical_cost: sum((r) => r.chemical_cost),
    input_cost: sum((r) => r.input_cost),
    total_cost: sum((r) => r.total_cost),
  };
}

// ---------------------------------------------------------------------------
// Spray records (public.spray_records, sql/007 + 033 + 101).
//
// External resource name: spray-jobs. The canonical source is
// spray_records — the ACTUAL completed field/compliance records — because
// external consumers (compliance, SWNZ-style reporting) need what was
// applied, not the planning header. Planned work lives in public.spray_jobs
// and is linked via spray_records.spray_job_id; the detail endpoint
// includes the linked plan header. Template rows (is_template=true) are
// excluded — they are not operational records.
// ---------------------------------------------------------------------------
interface SprayRow {
  id: string; vineyard_id: string;
  trip_id: string | null; spray_job_id: string | null;
  date: string | null; start_time: string | null; end_time: string | null;
  temperature: number | null; wind_speed: number | null;
  wind_direction: string | null; humidity: number | null;
  spray_reference: string | null; notes: string | null;
  number_of_fans_jets: string | null; average_speed: number | null;
  equipment_type: string | null; tractor: string | null;
  machine_id: string | null; tractor_id: string | null;
  spray_equipment_id: string | null;
  operation_type: string | null;
  tanks: unknown;
  created_at: string; updated_at: string;
}

const SPRAY_COLUMNS =
  "id, vineyard_id, trip_id, spray_job_id, date, start_time, end_time, temperature, wind_speed, " +
  "wind_direction, humidity, spray_reference, notes, number_of_fans_jets, average_speed, " +
  "equipment_type, tractor, machine_id, tractor_id, spray_equipment_id, operation_type, tanks, " +
  "created_at, updated_at";

interface TankJson {
  tankNumber?: unknown; waterVolume?: unknown; sprayRatePerHa?: unknown;
  concentrationFactor?: unknown; chemicals?: unknown;
}
interface ChemicalJson {
  name?: unknown; volumePerTank?: unknown; ratePerHa?: unknown; ratePer100L?: unknown;
  costPerUnit?: unknown; unit?: unknown; savedChemicalId?: unknown;
}

function parseTanks(raw: unknown): TankJson[] {
  return Array.isArray(raw) ? (raw as TankJson[]) : [];
}

/** Hectares one tank covers: waterVolume * cf / sprayRatePerHa (canonical client derivation). */
function tankAreaHa(t: TankJson): number {
  const water = num(t.waterVolume) ?? 0;
  const rate = num(t.sprayRatePerHa) ?? 0;
  const cfRaw = num(t.concentrationFactor) ?? 0;
  const cf = cfRaw > 0 ? cfRaw : 1;
  return rate > 0 ? (water * cf) / rate : 0;
}

function sprayTotals(tanks: TankJson[]): { waterL: number; areaHa: number; productNames: string[] } {
  let waterL = 0;
  let areaHa = 0;
  const names: string[] = [];
  for (const t of tanks) {
    waterL += num(t.waterVolume) ?? 0;
    areaHa += tankAreaHa(t);
    const chems = Array.isArray(t.chemicals) ? (t.chemicals as ChemicalJson[]) : [];
    for (const c of chems) {
      const name = typeof c.name === "string" ? c.name.trim() : "";
      if (name && !names.includes(name)) names.push(name);
    }
  }
  return { waterL: round3(waterL), areaHa: round3(areaHa), productNames: names };
}

function mapSpraySummary(row: SprayRow, idx: MachineIndex) {
  const tanks = parseTanks(row.tanks);
  const totals = sprayTotals(tanks);
  const machine = resolveMachine(idx, row.machine_id, row.tractor_id);
  const equipmentName = (row.tractor ?? "").trim() || (machine ? machine.name.trim() : "") || null;
  return {
    id: row.id,
    vineyard_id: row.vineyard_id,
    // Spray records are completed applications by definition; planned work
    // lives in the linked spray job (see detail endpoint).
    status: "completed",
    date: row.date ?? null,
    started_at: row.start_time ?? null,
    ended_at: row.end_time ?? null,
    reference: row.spray_reference ?? null,
    operation_type: row.operation_type ?? null,
    equipment_id: machine?.id ?? null,
    equipment_name: equipmentName,
    equipment_type: row.equipment_type ?? null,
    spray_equipment_id: row.spray_equipment_id ?? null,
    // Weather values as recorded by the mobile apps (metric convention:
    // °C, km/h 10-min average, % relative humidity). Not converted.
    conditions: {
      temperature_c: row.temperature ?? null,
      wind_speed_kmh: row.wind_speed ?? null,
      wind_direction: row.wind_direction ?? null,
      humidity_percent: row.humidity ?? null,
    },
    // Derived from the canonical tank mix: water = sum(tank waterVolume);
    // area = sum(waterVolume * concentrationFactor / sprayRatePerHa).
    water_volume_l: totals.waterL,
    treated_area_ha: totals.areaHa > 0 ? totals.areaHa : null,
    tank_count: tanks.length,
    product_names: totals.productNames,
    average_speed_kmh: row.average_speed ?? null,
    fans_jets: row.number_of_fans_jets ?? null,
    trip_id: row.trip_id ?? null,
    spray_job_id: row.spray_job_id ?? null,
    notes: row.notes ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

/** Full tank/product detail (single-record endpoint only). */
function mapSprayTanks(raw: unknown, includeCosts: boolean) {
  return parseTanks(raw).map((t) => {
    const chems = Array.isArray(t.chemicals) ? (t.chemicals as ChemicalJson[]) : [];
    return {
      tank_number: num(t.tankNumber),
      water_volume_l: num(t.waterVolume),
      spray_rate_l_per_ha: num(t.sprayRatePerHa),
      concentration_factor: num(t.concentrationFactor),
      area_ha: round3(tankAreaHa(t)) || null,
      products: chems.map((c) => {
        const product: Record<string, unknown> = {
          product_id: typeof c.savedChemicalId === "string" ? c.savedChemicalId : null,
          name: typeof c.name === "string" ? c.name : null,
          // Quantities/rates are returned in the product's recorded unit
          // ('Litres', 'mL', 'Kg', 'g') — never converted.
          quantity_per_tank: num(c.volumePerTank),
          rate_per_ha: num(c.ratePerHa),
          rate_per_100l: num(c.ratePer100L),
          unit: typeof c.unit === "string" ? c.unit : null,
        };
        if (includeCosts) {
          product.cost_per_unit = num(c.costPerUnit);
        }
        return product;
      }),
    };
  });
}

/** Total chemical cost across every tank line (costs:read gated). */
function sprayChemicalCostTotal(raw: unknown): number | null {
  let total = 0;
  let found = false;
  for (const t of parseTanks(raw)) {
    const chems = Array.isArray(t.chemicals) ? (t.chemicals as ChemicalJson[]) : [];
    for (const c of chems) {
      const cost = num(c.costPerUnit) ?? 0;
      const qty = num(c.volumePerTank) ?? 0;
      if (cost > 0 && qty > 0) {
        total += cost * qty;
        found = true;
      }
    }
  }
  return found ? round3(total) : null;
}

/** Blocks treated: via the linked trip's paddock set, else the linked plan's paddock links. */
async function loadSprayBlocks(
  db: SupabaseClient, row: SprayRow,
): Promise<{ block_id: string; name: string | null }[]> {
  let blockIds: string[] = [];
  if (row.trip_id) {
    const { data, error } = await db.from("trips")
      .select("paddock_id, paddock_ids")
      .eq("id", row.trip_id)
      .maybeSingle();
    if (error) {
      console.error("[vinetrack-api] spray trip lookup failed:", error.message);
      throw new ApiError("internal_error");
    }
    if (data) {
      blockIds = tripBlockIds({ paddock_id: data.paddock_id, paddock_ids: data.paddock_ids } as TripRow);
    }
  }
  if (blockIds.length === 0 && row.spray_job_id) {
    const { data, error } = await db.from("spray_job_paddocks")
      .select("paddock_id")
      .eq("spray_job_id", row.spray_job_id);
    if (error) {
      console.error("[vinetrack-api] spray job paddocks lookup failed:", error.message);
      throw new ApiError("internal_error");
    }
    blockIds = (data ?? []).map((r: { paddock_id: string }) => r.paddock_id);
  }
  if (blockIds.length === 0) return [];
  const { data, error } = await db.from("paddocks")
    .select("id, name, vineyard_id")
    .in("id", blockIds)
    .eq("vineyard_id", row.vineyard_id);
  if (error) {
    console.error("[vinetrack-api] spray block names lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  const nameById = new Map((data ?? []).map((p: { id: string; name: string }) => [p.id, p.name]));
  return blockIds
    .filter((id) => nameById.has(id))
    .map((id) => ({ block_id: id, name: nameById.get(id) ?? null }));
}

// ---------------------------------------------------------------------------
// Fuel usage records (public.tractor_fuel_logs, sql/092 + 097).
// ---------------------------------------------------------------------------
interface FuelLogRow {
  id: string; vineyard_id: string;
  tractor_id: string | null; machine_id: string | null;
  fill_datetime: string; litres_added: number;
  engine_hours: number | null;
  operator_user_id: string | null; operator_name: string | null;
  cost_per_litre: number | null; total_cost: number | null;
  filled_to_full: boolean | null; notes: string | null;
  created_at: string; updated_at: string;
}

const FUEL_LOG_COLUMNS =
  "id, vineyard_id, tractor_id, machine_id, fill_datetime, litres_added, engine_hours, " +
  "operator_user_id, operator_name, cost_per_litre, total_cost, filled_to_full, notes, " +
  "created_at, updated_at";

function mapFuelRecord(row: FuelLogRow, idx: MachineIndex, profile: AuthProfile) {
  const machine = resolveMachine(idx, row.machine_id, row.tractor_id);
  const base: Record<string, unknown> = {
    id: row.id,
    vineyard_id: row.vineyard_id,
    date: row.fill_datetime,
    equipment_id: machine?.id ?? null,
    equipment_name: machine ? (machine.name.trim() || null) : null,
    volume_l: row.litres_added,
    engine_hours: row.engine_hours ?? null,
    filled_to_full: row.filled_to_full ?? null,
    notes: row.notes ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  if (hasScope(profile, "labour:read")) {
    base.operator = (row.operator_user_id || row.operator_name)
      ? { user_id: row.operator_user_id ?? null, name: row.operator_name ?? null }
      : null;
  }
  if (hasScope(profile, "costs:read")) {
    base.cost_per_litre = row.cost_per_litre ?? null;
    base.total_cost = row.total_cost ?? null;
  }
  return base;
}

// ---------------------------------------------------------------------------
// Fuel purchases (public.fuel_purchases, sql/011).
//
// Canonical storage is volume_litres + total_cost only. price_per_litre is
// DERIVED (total_cost / volume_litres) exactly like the apps'
// weightedFuelCostPerLitre convention — documented transformation.
// Monetary fields are OMITTED without costs:read (consistent omission
// policy). No supplier / notes / tax columns exist canonically.
// ---------------------------------------------------------------------------
interface FuelPurchaseRow {
  id: string; vineyard_id: string;
  volume_litres: number; total_cost: number; date: string;
  created_at: string; updated_at: string;
}

const FUEL_PURCHASE_COLUMNS = "id, vineyard_id, volume_litres, total_cost, date, created_at, updated_at";

function mapFuelPurchase(row: FuelPurchaseRow, profile: AuthProfile) {
  const base: Record<string, unknown> = {
    id: row.id,
    vineyard_id: row.vineyard_id,
    date: row.date,
    volume_l: row.volume_litres,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  if (hasScope(profile, "costs:read")) {
    base.total_price = row.total_cost;
    base.price_per_litre = row.volume_litres > 0 ? round3(row.total_cost / row.volume_litres) : null;
  }
  return base;
}

// ---------------------------------------------------------------------------
// Equipment (unified external contract over three canonical tables).
//
// Internal fragmentation (vineyard_machines / spray_equipment /
// equipment_items) is deliberately NOT leaked: /v1/equipment presents one
// typed resource with kind = machine | sprayer | item. The legacy
// public.tractors table is NOT listed separately — every active tractor is
// backfilled into vineyard_machines (sql/097); its make/model/year are
// enriched from the linked tractors row. Uuids are globally unique, so a
// single id space across the three tables is safe.
// ---------------------------------------------------------------------------
interface SprayEquipmentRow {
  id: string; vineyard_id: string; name: string;
  tank_capacity_litres: number | null;
  serial_number: string | null; vin_number: string | null;
  created_at: string; updated_at: string;
}

const SPRAY_EQUIPMENT_COLUMNS =
  "id, vineyard_id, name, tank_capacity_litres, serial_number, vin_number, created_at, updated_at";

interface EquipmentItemRow {
  id: string; vineyard_id: string; name: string; category: string;
  make: string | null; model: string | null;
  serial_number: string | null; vin_number: string | null;
  created_at: string; updated_at: string;
}

const EQUIPMENT_ITEM_COLUMNS =
  "id, vineyard_id, name, category, make, model, serial_number, vin_number, created_at, updated_at";

interface TractorRow { id: string; brand: string; model: string; model_year: number | null }

/** Legacy tractor rows enrich backfilled machines with make/model/year. */
async function loadTractorIndex(db: SupabaseClient, vineyardId: string): Promise<Map<string, TractorRow>> {
  const { data, error } = await db.from("tractors")
    .select("id, brand, model, model_year")
    .eq("vineyard_id", vineyardId);
  if (error) {
    console.error("[vinetrack-api] tractor index query failed:", error.message);
    throw new ApiError("internal_error");
  }
  return new Map(((data ?? []) as TractorRow[]).map((t) => [t.id, t]));
}

function mapMachineEquipment(row: MachineRow, tractors: Map<string, TractorRow>) {
  const legacy = row.legacy_tractor_id ? tractors.get(row.legacy_tractor_id) ?? null : null;
  return {
    id: row.id,
    vineyard_id: row.vineyard_id,
    kind: "machine",
    name: row.name.trim() || null,
    equipment_type: row.machine_type ?? null,
    make: legacy ? (legacy.brand.trim() || null) : null,
    model: legacy ? (legacy.model.trim() || null) : null,
    year: legacy?.model_year ?? null,
    serial_number: row.serial_number ?? null,
    vin_number: row.vin_number ?? null,
    // Hourly fuel usage; the apps treat 0 as "not set", so 0 maps to null.
    fuel_usage_l_per_hour: (row.fuel_usage_l_per_hour ?? 0) > 0 ? row.fuel_usage_l_per_hour : null,
    tank_capacity_l: null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

function mapSprayerEquipment(row: SprayEquipmentRow) {
  return {
    id: row.id,
    vineyard_id: row.vineyard_id,
    kind: "sprayer",
    name: row.name.trim() || null,
    equipment_type: "sprayer",
    make: null,
    model: null,
    year: null,
    serial_number: row.serial_number ?? null,
    vin_number: row.vin_number ?? null,
    fuel_usage_l_per_hour: null,
    tank_capacity_l: row.tank_capacity_litres ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

function mapItemEquipment(row: EquipmentItemRow) {
  return {
    id: row.id,
    vineyard_id: row.vineyard_id,
    kind: "item",
    name: row.name.trim() || null,
    equipment_type: row.category || "other",
    make: row.make ?? null,
    model: row.model ?? null,
    year: null,
    serial_number: row.serial_number ?? null,
    vin_number: row.vin_number ?? null,
    fuel_usage_l_per_hour: null,
    tank_capacity_l: null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

const MACHINE_TYPE_VALUES = [
  "tractor", "atv", "side_by_side", "harvester", "utility_vehicle", "other_vineyard_machine",
];
const EQUIPMENT_KIND_VALUES = ["machine", "sprayer", "item"];

// ---------------------------------------------------------------------------
// Route handlers — Stage 3A (unchanged behaviour)
// ---------------------------------------------------------------------------
function handleMe(req: Request, ctx: RequestContext, profile: AuthProfile): Response {
  // Authentication only — no resource scope required. Vineyard ids/names
  // here describe the integration itself; full vineyard resources still
  // require vineyards:read.
  return jsonResponse(req, ctx, {
    data: {
      integration_id: profile.integration_client_id,
      name: profile.integration_name,
      environment: profile.environment,
      status: profile.status,
      scopes: profile.scopes ?? [],
      vineyards: profile.vineyards ?? [],
    },
  }, 200);
}

async function handleVineyardList(
  req: Request, ctx: RequestContext, db: SupabaseClient, profile: AuthProfile, url: URL,
): Promise<Response> {
  enforceAllowedParams(url, ["limit", "cursor"]);
  requireScope(profile, "vineyards:read");

  const limit = parseLimit(url.searchParams.get("limit"));
  const rawCursor = url.searchParams.get("cursor");
  const cursor = rawCursor ? decodeCursor(rawCursor) : null;

  const grantedIds = (profile.vineyards ?? []).map((v) => v.id);
  if (grantedIds.length === 0) {
    return jsonResponse(req, ctx, { data: [], pagination: { next_cursor: null } }, 200);
  }

  const { rows, nextCursor } = await pagedList<VineyardRow>(
    db, "vineyards", VINEYARD_COLUMNS, limit, cursor, true,
    (q) => q.in("id", grantedIds),
  );

  return jsonResponse(req, ctx, {
    data: rows.map(mapVineyard),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleVineyardGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL, vineyardId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(vineyardId)) throw new ApiError("invalid_request");
  ctx.vineyardId = vineyardId;

  // Canonical five-check validation; ungranted vineyards are indistinguishable
  // from nonexistent ones (resource_not_found).
  await validateVineyardRequest(db, key, "vineyards:read", vineyardId, true);

  const { data, error } = await db.from("vineyards")
    .select(VINEYARD_COLUMNS)
    .eq("id", vineyardId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] vineyard fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) throw new ApiError("resource_not_found");

  return jsonResponse(req, ctx, { data: mapVineyard(data as unknown as VineyardRow) }, 200);
}

async function handleBlockList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  enforceAllowedParams(url, ["vineyard_id", "limit", "cursor"]);

  // vineyard_id is REQUIRED — vineyard isolation is explicit.
  const vineyardId = url.searchParams.get("vineyard_id");
  if (!vineyardId || !UUID_RE.test(vineyardId)) throw new ApiError("invalid_request");
  ctx.vineyardId = vineyardId;

  const limit = parseLimit(url.searchParams.get("limit"));
  const rawCursor = url.searchParams.get("cursor");
  const cursor = rawCursor ? decodeCursor(rawCursor) : null;

  // Explicitly named vineyard context -> vineyard_access_denied on refusal
  // (still non-disclosing: does not reveal whether the vineyard exists).
  await validateVineyardRequest(db, key, "blocks:read", vineyardId, false);

  const { rows, nextCursor } = await pagedList<BlockRow>(
    db, "paddocks", BLOCK_COLUMNS, limit, cursor, true,
    (q) => q.eq("vineyard_id", vineyardId),
  );

  return jsonResponse(req, ctx, {
    data: rows.map(mapBlock),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleBlockGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, blockId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(blockId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("paddocks")
    .select(BLOCK_COLUMNS)
    .eq("id", blockId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] block fetch failed:", error.message);
    throw new ApiError("internal_error");
  }

  if (!data) {
    // Keep the scope error consistent whether or not the block exists so
    // responses do not leak existence.
    requireScope(profile, "blocks:read");
    throw new ApiError("resource_not_found");
  }

  const block = data as unknown as BlockRow;
  ctx.vineyardId = block.vineyard_id;

  await validateVineyardRequest(db, key, "blocks:read", block.vineyard_id, true);

  return jsonResponse(req, ctx, { data: mapBlock(block) }, 200);
}

// ---------------------------------------------------------------------------
// Shared plumbing for Stage 3B collection endpoints.
// ---------------------------------------------------------------------------
interface CollectionArgs {
  vineyardId: string;
  limit: number;
  cursor: Cursor | null;
  fromDate: string | null;
  toDate: string | null;
}

/**
 * Parses the shared collection parameters (vineyard_id required, limit,
 * cursor, optional from/to dates) and runs the canonical five-check
 * validation for the requested scope.
 */
async function prepareCollection(
  ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
  scope: string, extraParams: string[], withDates: boolean,
): Promise<CollectionArgs> {
  const allowed = ["vineyard_id", "limit", "cursor", ...(withDates ? ["from", "to"] : []), ...extraParams];
  enforceAllowedParams(url, allowed);

  const vineyardId = url.searchParams.get("vineyard_id");
  if (!vineyardId || !UUID_RE.test(vineyardId)) throw new ApiError("invalid_request");
  ctx.vineyardId = vineyardId;

  const limit = parseLimit(url.searchParams.get("limit"));
  const rawCursor = url.searchParams.get("cursor");
  const cursor = rawCursor ? decodeCursor(rawCursor) : null;
  const fromDate = withDates ? parseDateParam(url.searchParams.get("from")) : null;
  const toDate = withDates ? parseDateParam(url.searchParams.get("to")) : null;
  if (fromDate && toDate && fromDate > toDate) throw new ApiError("invalid_request");

  await validateVineyardRequest(db, key, scope, vineyardId, false);
  return { vineyardId, limit, cursor, fromDate, toDate };
}

/**
 * Optional equipment_id filter (trips / fuel-records). The value must be a
 * canonical machine id. A machine id belonging to a different vineyard (or
 * no machine at all) matches nothing — the collection is simply empty, so
 * cross-vineyard equipment ids are never confirmed to exist.
 * Returns null when no filter was supplied, `{ empty: true }` when the
 * filter matches no machine in this vineyard, otherwise the PostgREST
 * or-expression matching both the preferred machine link and the legacy
 * tractor link.
 */
function resolveEquipmentFilter(
  url: URL, idx: MachineIndex, vineyardId: string,
): { empty: boolean; orExpr: string | null } | null {
  const raw = url.searchParams.get("equipment_id");
  if (raw === null) return null;
  if (!UUID_RE.test(raw)) throw new ApiError("invalid_request");
  const machine = idx.byId.get(raw);
  if (!machine || machine.vineyard_id !== vineyardId) return { empty: true, orExpr: null };
  const orExpr = machine.legacy_tractor_id
    ? `machine_id.eq.${machine.id},tractor_id.eq.${machine.legacy_tractor_id}`
    : `machine_id.eq.${machine.id}`;
  return { empty: false, orExpr };
}

function emptyCollection(req: Request, ctx: RequestContext): Response {
  return jsonResponse(req, ctx, { data: [], pagination: { next_cursor: null } }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3B: Trips
// ---------------------------------------------------------------------------
async function handleTripList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "trips:read", ["equipment_id"], true);
  const idx = await loadMachineIndex(db, args.vineyardId);

  const equipmentFilter = resolveEquipmentFilter(url, idx, args.vineyardId);
  if (equipmentFilter?.empty) return emptyCollection(req, ctx);

  // Date filters apply to the trip's business timestamp (start_time, UTC
  // days). Trips without a start_time are excluded by a date filter.
  const dateFilter = applyDateRange(args.fromDate, args.toDate, "start_time");

  const { rows, nextCursor } = await pagedList<TripRow>(
    db, "trips", TRIP_LIST_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      q = dateFilter(q);
      if (equipmentFilter?.orExpr) q = q.or(equipmentFilter.orExpr);
      return q;
    },
  );

  return jsonResponse(req, ctx, {
    data: rows.map((r) => mapTripSummary(r, idx, profile)),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleTripGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, tripId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(tripId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("trips")
    .select(TRIP_DETAIL_COLUMNS)
    .eq("id", tripId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] trip fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "trips:read");
    throw new ApiError("resource_not_found");
  }

  const trip = data as unknown as TripRow;
  ctx.vineyardId = trip.vineyard_id;
  await validateVineyardRequest(db, key, "trips:read", trip.vineyard_id, true);

  const idx = await loadMachineIndex(db, trip.vineyard_id);
  const body = mapTripSummary(trip, idx, profile);

  // Detail-only row work summary (derived from the canonical row plan).
  const planned = Array.isArray(trip.row_sequence) ? trip.row_sequence.length : 0;
  const completed = Array.isArray(trip.completed_paths) ? trip.completed_paths.length : 0;
  const skipped = Array.isArray(trip.skipped_paths) ? trip.skipped_paths.length : 0;
  body.rows = { planned, completed, skipped };

  // Costs require costs:read; labour_cost additionally requires labour:read.
  if (hasScope(profile, "costs:read")) {
    const sums = await loadTripCosts(db, trip.id);
    if (sums) {
      const costs: Record<string, unknown> = {
        fuel_cost: sums.fuel_cost,
        chemical_cost: sums.chemical_cost,
        input_cost: sums.input_cost,
        total_cost: sums.total_cost,
      };
      if (hasScope(profile, "labour:read")) costs.labour_cost = sums.labour_cost;
      body.costs = costs;
    } else {
      body.costs = null;
    }
  }

  return jsonResponse(req, ctx, { data: body }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3B: Spray jobs
// ---------------------------------------------------------------------------
async function handleSprayList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "sprays:read", [], true);
  const idx = await loadMachineIndex(db, args.vineyardId);

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "date");

  const { rows, nextCursor } = await pagedList<SprayRow>(
    db, "spray_records", SPRAY_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId).eq("is_template", false);
      return dateFilter(q);
    },
  );

  return jsonResponse(req, ctx, {
    data: rows.map((r) => mapSpraySummary(r, idx)),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleSprayGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, sprayId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(sprayId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("spray_records")
    .select(SPRAY_COLUMNS)
    .eq("id", sprayId)
    .eq("is_template", false)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] spray fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "sprays:read");
    throw new ApiError("resource_not_found");
  }

  const spray = data as unknown as SprayRow;
  ctx.vineyardId = spray.vineyard_id;
  await validateVineyardRequest(db, key, "sprays:read", spray.vineyard_id, true);

  const idx = await loadMachineIndex(db, spray.vineyard_id);
  const includeCosts = hasScope(profile, "costs:read");
  const body = mapSpraySummary(spray, idx) as Record<string, unknown>;

  body.blocks = await loadSprayBlocks(db, spray);
  body.tanks = mapSprayTanks(spray.tanks, includeCosts);
  if (includeCosts) {
    body.chemical_cost_total = sprayChemicalCostTotal(spray.tanks);
  }

  // Linked plan header (public.spray_jobs) when the record fulfilled a plan.
  if (spray.spray_job_id) {
    const { data: job, error: jobError } = await db.from("spray_jobs")
      .select("id, name, status, target, operation_type, planned_date")
      .eq("id", spray.spray_job_id)
      .maybeSingle();
    if (jobError) {
      console.error("[vinetrack-api] spray job header lookup failed:", jobError.message);
      throw new ApiError("internal_error");
    }
    body.spray_job = job
      ? {
        id: job.id,
        name: job.name || null,
        status: job.status,
        target: job.target ?? null,
        operation_type: job.operation_type ?? null,
        planned_date: job.planned_date ?? null,
      }
      : null;
  } else {
    body.spray_job = null;
  }

  return jsonResponse(req, ctx, { data: body }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3B: Fuel records + fuel purchases
// ---------------------------------------------------------------------------
async function handleFuelRecordList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "fuel:read", ["equipment_id"], true);
  const idx = await loadMachineIndex(db, args.vineyardId);

  const equipmentFilter = resolveEquipmentFilter(url, idx, args.vineyardId);
  if (equipmentFilter?.empty) return emptyCollection(req, ctx);

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "fill_datetime");

  const { rows, nextCursor } = await pagedList<FuelLogRow>(
    db, "tractor_fuel_logs", FUEL_LOG_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      q = dateFilter(q);
      if (equipmentFilter?.orExpr) q = q.or(equipmentFilter.orExpr);
      return q;
    },
  );

  return jsonResponse(req, ctx, {
    data: rows.map((r) => mapFuelRecord(r, idx, profile)),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleFuelRecordGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, recordId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(recordId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("tractor_fuel_logs")
    .select(FUEL_LOG_COLUMNS)
    .eq("id", recordId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] fuel record fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "fuel:read");
    throw new ApiError("resource_not_found");
  }

  const record = data as unknown as FuelLogRow;
  ctx.vineyardId = record.vineyard_id;
  await validateVineyardRequest(db, key, "fuel:read", record.vineyard_id, true);

  const idx = await loadMachineIndex(db, record.vineyard_id);
  return jsonResponse(req, ctx, { data: mapFuelRecord(record, idx, profile) }, 200);
}

async function handleFuelPurchaseList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "fuel:read", [], true);

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "date");

  const { rows, nextCursor } = await pagedList<FuelPurchaseRow>(
    db, "fuel_purchases", FUEL_PURCHASE_COLUMNS, args.limit, args.cursor, false,
    (q) => dateFilter(q.eq("vineyard_id", args.vineyardId)),
  );

  return jsonResponse(req, ctx, {
    data: rows.map((r) => mapFuelPurchase(r, profile)),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleFuelPurchaseGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, purchaseId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(purchaseId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("fuel_purchases")
    .select(FUEL_PURCHASE_COLUMNS)
    .eq("id", purchaseId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] fuel purchase fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "fuel:read");
    throw new ApiError("resource_not_found");
  }

  const purchase = data as unknown as FuelPurchaseRow;
  ctx.vineyardId = purchase.vineyard_id;
  await validateVineyardRequest(db, key, "fuel:read", purchase.vineyard_id, true);

  return jsonResponse(req, ctx, { data: mapFuelPurchase(purchase, profile) }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3B: Equipment
// ---------------------------------------------------------------------------
async function handleEquipmentList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "equipment:read", ["type"], false);

  // type filter: an external kind (machine|sprayer|item) or a canonical
  // machine_type value (tractor, atv, ...). Anything else -> invalid_request.
  const typeFilter = url.searchParams.get("type");
  let includeMachines = true;
  let includeSprayers = true;
  let includeItems = true;
  let machineTypeEq: string | null = null;
  if (typeFilter !== null) {
    if (EQUIPMENT_KIND_VALUES.includes(typeFilter)) {
      includeMachines = typeFilter === "machine";
      includeSprayers = typeFilter === "sprayer";
      includeItems = typeFilter === "item";
    } else if (MACHINE_TYPE_VALUES.includes(typeFilter)) {
      includeSprayers = false;
      includeItems = false;
      machineTypeEq = typeFilter;
    } else {
      throw new ApiError("invalid_request");
    }
  }

  // Merged keyset pagination across the three canonical tables: each table
  // is queried with the same (created_at, id) cursor predicate ascending,
  // then merge-sorted; the global first `limit` rows are always contained
  // in the per-table limit+1 prefixes, so the merge is deterministic and
  // gap-free. Equipment catalogues are small; this stays cheap.
  interface MergedRow { created_at: string; id: string; body: Record<string, unknown> }
  const merged: MergedRow[] = [];

  if (includeMachines) {
    const tractors = await loadTractorIndex(db, args.vineyardId);
    const { rows } = await pagedList<MachineRow>(
      db, "vineyard_machines", MACHINE_COLUMNS, args.limit, args.cursor, true,
      (q) => {
        q = q.eq("vineyard_id", args.vineyardId);
        if (machineTypeEq) q = q.eq("machine_type", machineTypeEq);
        return q;
      },
    );
    for (const r of rows) merged.push({ created_at: r.created_at, id: r.id, body: mapMachineEquipment(r, tractors) });
  }
  if (includeSprayers) {
    const { rows } = await pagedList<SprayEquipmentRow>(
      db, "spray_equipment", SPRAY_EQUIPMENT_COLUMNS, args.limit, args.cursor, true,
      (q) => q.eq("vineyard_id", args.vineyardId),
    );
    for (const r of rows) merged.push({ created_at: r.created_at, id: r.id, body: mapSprayerEquipment(r) });
  }
  if (includeItems) {
    const { rows } = await pagedList<EquipmentItemRow>(
      db, "equipment_items", EQUIPMENT_ITEM_COLUMNS, args.limit, args.cursor, true,
      (q) => q.eq("vineyard_id", args.vineyardId),
    );
    for (const r of rows) merged.push({ created_at: r.created_at, id: r.id, body: mapItemEquipment(r) });
  }

  merged.sort((a, b) =>
    a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  );
  const hasMore = merged.length > args.limit;
  const page = merged.slice(0, args.limit);
  const nextCursor = hasMore && page.length > 0
    ? encodeCursor({ t: page[page.length - 1].created_at, id: page[page.length - 1].id })
    : null;

  return jsonResponse(req, ctx, {
    data: page.map((r) => r.body),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleEquipmentGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, equipmentId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(equipmentId)) throw new ApiError("invalid_request");

  // Try the three canonical tables in a stable order (uuids never collide).
  const { data: machine, error: mErr } = await db.from("vineyard_machines")
    .select(MACHINE_COLUMNS).eq("id", equipmentId).is("deleted_at", null).maybeSingle();
  if (mErr) {
    console.error("[vinetrack-api] equipment machine fetch failed:", mErr.message);
    throw new ApiError("internal_error");
  }
  if (machine) {
    const row = machine as unknown as MachineRow;
    ctx.vineyardId = row.vineyard_id;
    await validateVineyardRequest(db, key, "equipment:read", row.vineyard_id, true);
    const tractors = await loadTractorIndex(db, row.vineyard_id);
    return jsonResponse(req, ctx, { data: mapMachineEquipment(row, tractors) }, 200);
  }

  const { data: sprayer, error: sErr } = await db.from("spray_equipment")
    .select(SPRAY_EQUIPMENT_COLUMNS).eq("id", equipmentId).is("deleted_at", null).maybeSingle();
  if (sErr) {
    console.error("[vinetrack-api] equipment sprayer fetch failed:", sErr.message);
    throw new ApiError("internal_error");
  }
  if (sprayer) {
    const row = sprayer as unknown as SprayEquipmentRow;
    ctx.vineyardId = row.vineyard_id;
    await validateVineyardRequest(db, key, "equipment:read", row.vineyard_id, true);
    return jsonResponse(req, ctx, { data: mapSprayerEquipment(row) }, 200);
  }

  const { data: item, error: iErr } = await db.from("equipment_items")
    .select(EQUIPMENT_ITEM_COLUMNS).eq("id", equipmentId).is("deleted_at", null).maybeSingle();
  if (iErr) {
    console.error("[vinetrack-api] equipment item fetch failed:", iErr.message);
    throw new ApiError("internal_error");
  }
  if (item) {
    const row = item as unknown as EquipmentItemRow;
    ctx.vineyardId = row.vineyard_id;
    await validateVineyardRequest(db, key, "equipment:read", row.vineyard_id, true);
    return jsonResponse(req, ctx, { data: mapItemEquipment(row) }, 200);
  }

  requireScope(profile, "equipment:read");
  throw new ApiError("resource_not_found");
}

// ---------------------------------------------------------------------------
// Safe request logging. Never logs credentials, headers or bodies.
// ---------------------------------------------------------------------------
async function logRequest(db: SupabaseClient, ctx: RequestContext, status: number, errorCode: string | null): Promise<void> {
  if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(ctx.method)) return;
  try {
    const { error } = await db.rpc("integration_log_api_request", {
      p_request_id: ctx.requestId,
      p_integration_client_id: ctx.integrationClientId,
      p_api_key_id: ctx.apiKeyId,
      p_vineyard_id: ctx.vineyardId,
      p_method: ctx.method,
      p_path: ctx.canonicalPath,
      p_status_code: status,
      p_duration_ms: Math.round(performance.now() - ctx.startedAt),
      p_error_code: errorCode,
    });
    if (error) console.error("[vinetrack-api] request log failed:", error.message);
  } catch (e) {
    console.error("[vinetrack-api] request log threw:", e instanceof Error ? e.message : String(e));
  }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
type Route =
  | { name: "me" }
  | { name: "vineyards_list" }
  | { name: "vineyard_get"; id: string }
  | { name: "blocks_list" }
  | { name: "block_get"; id: string }
  | { name: "trips_list" }
  | { name: "trip_get"; id: string }
  | { name: "sprays_list" }
  | { name: "spray_get"; id: string }
  | { name: "fuel_records_list" }
  | { name: "fuel_record_get"; id: string }
  | { name: "fuel_purchases_list" }
  | { name: "fuel_purchase_get"; id: string }
  | { name: "equipment_list" }
  | { name: "equipment_get"; id: string };

/** Collection + single-resource route table: segment -> route names + log templates. */
const RESOURCE_ROUTES: Record<string, { list: Route["name"]; get: Route["name"]; idLabel: string }> = {
  "vineyards": { list: "vineyards_list", get: "vineyard_get", idLabel: "vineyard_id" },
  "blocks": { list: "blocks_list", get: "block_get", idLabel: "block_id" },
  "trips": { list: "trips_list", get: "trip_get", idLabel: "trip_id" },
  "spray-jobs": { list: "sprays_list", get: "spray_get", idLabel: "spray_job_id" },
  "fuel-records": { list: "fuel_records_list", get: "fuel_record_get", idLabel: "fuel_record_id" },
  "fuel-purchases": { list: "fuel_purchases_list", get: "fuel_purchase_get", idLabel: "fuel_purchase_id" },
  "equipment": { list: "equipment_list", get: "equipment_get", idLabel: "equipment_id" },
};

Deno.serve(async (req: Request) => {
  const ctx: RequestContext = {
    requestId: newRequestId(),
    method: req.method.toUpperCase(),
    canonicalPath: "unknown",
    startedAt: performance.now(),
    integrationClientId: null,
    apiKeyId: null,
    vineyardId: null,
    rateHeaders: {},
  };

  const url = new URL(req.url);
  // Path arrives as /vinetrack-api/v1/... — strip the function segment.
  const path = url.pathname.replace(/^\/vinetrack-api/, "").replace(/\/+$/, "") || "/";
  const segments = path.split("/").filter(Boolean); // e.g. ["v1", "trips", "<id>"]

  if (ctx.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(req) });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("[vinetrack-api] missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
    return jsonResponse(req, ctx, {
      error: { code: "internal_error", message: ERRORS.internal_error.message, request_id: ctx.requestId },
    }, 500);
  }
  const db = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let status = 500;
  let errorCode: string | null = null;
  let response: Response;

  try {
    if (ctx.method !== "GET") {
      ctx.canonicalPath = "/" + segments.join("/");
      throw new ApiError("method_not_allowed");
    }

    // Resolve the canonical route template first (also used for logging —
    // templates never contain arbitrary ids, keeping log paths low-cardinality).
    let route: Route | null = null;
    if (segments[0] === "v1") {
      if (segments.length === 2 && segments[1] === "me") {
        route = { name: "me" };
        ctx.canonicalPath = "/v1/me";
      } else if (segments.length >= 2 && RESOURCE_ROUTES[segments[1]]) {
        const def = RESOURCE_ROUTES[segments[1]];
        if (segments.length === 2) {
          route = { name: def.list } as Route;
          ctx.canonicalPath = `/v1/${segments[1]}`;
        } else if (segments.length === 3) {
          route = { name: def.get, id: segments[2] } as Route;
          ctx.canonicalPath = `/v1/${segments[1]}/{${def.idLabel}}`;
        }
      }
    }
    if (!route) {
      ctx.canonicalPath = "/" + segments.join("/");
      throw new ApiError("resource_not_found");
    }

    // Authenticate (checks 1-4) and resolve the integration profile.
    const key = extractApiKey(req, url);
    const profile = await authenticate(db, key);
    if (!profile.valid) throw new ApiError(mapAuthFailure(profile.failure_code));
    ctx.integrationClientId = profile.integration_client_id ?? null;
    ctx.apiKeyId = profile.api_key_id ?? null;

    // Rate limit (per API key, shared Postgres counter).
    await checkRateLimit(db, ctx, profile.api_key_id!);

    switch (route.name) {
      case "me":
        enforceAllowedParams(url, []);
        response = handleMe(req, ctx, profile);
        break;
      case "vineyards_list":
        response = await handleVineyardList(req, ctx, db, profile, url);
        break;
      case "vineyard_get":
        response = await handleVineyardGet(req, ctx, db, key, url, (route as { id: string }).id);
        break;
      case "blocks_list":
        response = await handleBlockList(req, ctx, db, key, url);
        break;
      case "block_get":
        response = await handleBlockGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "trips_list":
        response = await handleTripList(req, ctx, db, key, profile, url);
        break;
      case "trip_get":
        response = await handleTripGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "sprays_list":
        response = await handleSprayList(req, ctx, db, key, url);
        break;
      case "spray_get":
        response = await handleSprayGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "fuel_records_list":
        response = await handleFuelRecordList(req, ctx, db, key, profile, url);
        break;
      case "fuel_record_get":
        response = await handleFuelRecordGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "fuel_purchases_list":
        response = await handleFuelPurchaseList(req, ctx, db, key, profile, url);
        break;
      case "fuel_purchase_get":
        response = await handleFuelPurchaseGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "equipment_list":
        response = await handleEquipmentList(req, ctx, db, key, url);
        break;
      case "equipment_get":
        response = await handleEquipmentGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
    }
    status = response.status;
  } catch (e) {
    if (e instanceof ApiError) {
      errorCode = e.code;
    } else {
      // Never leak Postgres/PostgREST/internal details externally.
      console.error("[vinetrack-api] unexpected error:", e instanceof Error ? (e.stack ?? e.message) : String(e));
      errorCode = "internal_error";
    }
    response = errorResponse(req, ctx, errorCode);
    status = response.status;
  }

  await logRequest(db, ctx, status, errorCode);
  return response;
});
