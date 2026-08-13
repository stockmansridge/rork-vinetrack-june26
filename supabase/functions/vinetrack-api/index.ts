// Supabase Edge Function: vinetrack-api
//
// VineTrack public API gateway — Stages 3A-3D (reads) + Stage 8 (writes).
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
//   GET /v1/work-tasks?vineyard_id=<uuid>[&from=&to=&status=&task_type=&block_id=]   (3C)
//   GET /v1/work-tasks/{work_task_id}                                                (3C)
//   GET /v1/pruning?vineyard_id=<uuid>[&from=&to=&block_id=]                         (3C)
//   GET /v1/pruning/{pruning_activity_id}                                            (3C)
//   GET /v1/irrigation-records?vineyard_id=<uuid>[&from=&to=&status=&block_id=]      (3C)
//   GET /v1/irrigation-records/{irrigation_record_id}                                (3C)
//   GET /v1/growth-stages?vineyard_id=<uuid>[&from=&to=&block_id=&stage_code=]       (3C)
//   GET /v1/growth-stages/{growth_stage_id}                                          (3C)
//   GET /v1/yield-records?vineyard_id=<uuid>[&from=&to=&vintage=]                    (3C)
//   GET /v1/yield-records/{yield_record_id}                                          (3C)
//   GET /v1/pins?vineyard_id=<uuid>[&block_id=&status=&category=&type=]              (3C)
//   GET /v1/pins/{pin_id}                                                            (3C)
//   GET /v1/weather?vineyard_id=<uuid>                                               (3D)
//   GET /v1/rainfall?vineyard_id=<uuid>[&from=&to=]                                  (3D)
//   GET /v1/disease-risk?vineyard_id=<uuid>                                          (3D)
//   POST  /v1/work-tasks                        (8; work_tasks:write, Idempotency-Key)
//   PATCH /v1/work-tasks/{work_task_id}         (8; work_tasks:write, expected_updated_at)
//   POST  /v1/fuel-records                      (8; fuel:write, Idempotency-Key)
//   PATCH /v1/fuel-records/{fuel_record_id}     (8; fuel:write, expected_updated_at)
//   POST  /v1/irrigation-records                (8; irrigation:write, create-only)
//   POST  /v1/growth-stages                     (8; growth_stages:write, create-only)
//   POST  /v1/yield-records                     (8; yield:write, Idempotency-Key)
//   PATCH /v1/yield-records/{yield_record_id}   (8; yield:write, expected_updated_at)
//
// Stage 8 writes: every POST requires an Idempotency-Key header (durable,
// database-backed replay protection); every PATCH requires
// expected_updated_at in the body (optimistic concurrency). All mutations go
// through SECURITY DEFINER RPCs (sql/186) that re-run the full five-check
// validation — the gateway never performs direct inserts/updates. There are
// NO DELETE routes.
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
//   WILLYWEATHER_API_KEY (existing global project secret; only used to
//     refresh the per-vineyard forecast cache — never exposed in responses)

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
  method_not_allowed: { status: 405, message: "This method is not supported on this endpoint." },
  validation_failed: { status: 422, message: "The request failed validation." },
  idempotency_required: { status: 400, message: "POST requests require an Idempotency-Key header (1-255 characters)." },
  idempotency_conflict: { status: 409, message: "This Idempotency-Key was already used with a different request payload." },
  conflict: { status: 409, message: "The request conflicts with the current state of the resource." },
  internal_error: { status: 500, message: "An internal error occurred. Contact support and quote the request_id." },
  disease_risk_unavailable: { status: 503, message: "Disease risk is currently unavailable for this vineyard. Ensure the vineyard has mapped blocks or a configured weather station, then try again shortly." },
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
    "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type, idempotency-key",
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
  /** Safe field-level validation details (never SQL/internal text). */
  details?: unknown;
  constructor(code: string, details?: unknown) {
    super(code);
    this.code = ERRORS[code] ? code : "internal_error";
    this.details = details;
  }
}

function errorResponse(
  req: Request,
  ctx: RequestContext,
  code: string,
  extraHeaders: Record<string, string> = {},
  details?: unknown,
): Response {
  const def = ERRORS[code] ?? ERRORS.internal_error;
  // Every gateway error — including 403 vineyard_access_denied — carries the
  // documented JSON envelope. Regression-tested by scripts/test-vinetrack-api.sh.
  const err: Record<string, unknown> = { code, message: def.message, request_id: ctx.requestId };
  if (details !== undefined && details !== null) err.details = details;
  return jsonResponse(req, ctx, { error: err }, def.status, extraHeaders);
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

function round1(v: number): number {
  return Math.round(v * 10) / 10;
}

function round2(v: number): number {
  return Math.round(v * 100) / 100;
}

function round3(v: number): number {
  return Math.round(v * 1000) / 1000;
}

function round4(v: number): number {
  return Math.round(v * 10000) / 10000;
}

/** Optional plain-text equality filter value (bounded, applied via .eq). */
function textParam(url: URL, name: string): string | null {
  const raw = url.searchParams.get(name);
  if (raw === null) return null;
  if (raw.length < 1 || raw.length > 100) throw new ApiError("invalid_request");
  return raw;
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
  origin: string; external_id: string | null;
  created_at: string; updated_at: string;
}

const FUEL_LOG_COLUMNS =
  "id, vineyard_id, tractor_id, machine_id, fill_datetime, litres_added, engine_hours, " +
  "operator_user_id, operator_name, cost_per_litre, total_cost, filled_to_full, notes, " +
  "origin, external_id, created_at, updated_at";

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
    origin: row.origin,
    external_id: row.external_id ?? null,
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
// Stage 3C shared helpers
// ---------------------------------------------------------------------------

/** Cap for id-list sub-filters resolved through child/join tables. */
const SUBFILTER_MAX_IDS = 5000;

/** Batch block-name lookup restricted to the validated vineyard. */
async function loadBlockNames(
  db: SupabaseClient, vineyardId: string, ids: string[],
): Promise<Map<string, string>> {
  const unique = [...new Set(ids)].filter((id) => UUID_RE.test(id));
  if (unique.length === 0) return new Map();
  const { data, error } = await db.from("paddocks")
    .select("id, name")
    .eq("vineyard_id", vineyardId)
    .in("id", unique);
  if (error) {
    console.error("[vinetrack-api] block name lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  return new Map((data ?? []).map((p: { id: string; name: string }) => [p.id, p.name]));
}

/** Validated optional block_id filter parameter. */
function blockIdParam(url: URL): string | null {
  const raw = url.searchParams.get("block_id");
  if (raw === null) return null;
  if (!UUID_RE.test(raw)) throw new ApiError("invalid_request");
  return raw;
}

// ---------------------------------------------------------------------------
// Work tasks (public.work_tasks, sql/014 + 050 additive columns; children
// work_task_paddocks sql/051, work_task_labour_lines sql/050,
// work_task_machine_lines sql/103; linked GPS trips via trips.work_task_id
// sql/102).
//
// There is no canonical title column — task_type is the task's label.
// Labour lines carry worker TYPE/counts (not identity), so they are
// operational; hourly_rate/total_cost require costs:read. Machine lines'
// operator_user_id requires labour:read; their monetary fields require
// costs:read.
// ---------------------------------------------------------------------------
interface WorkTaskRow {
  id: string; vineyard_id: string;
  task_type: string; status: string | null;
  date: string; start_date: string | null; end_date: string | null;
  duration_hours: number | null; area_ha: number | null;
  paddock_id: string | null; paddock_name: string;
  description: string | null; notes: string;
  is_archived: boolean; is_finalized: boolean;
  origin: string; external_id: string | null;
  // Piece Rate costing contract (sql/188). costing_method is the ONLY switch;
  // piece_rate_total_cost is generated by the database from the SNAPSHOT
  // quantity x rate, never from today's vineyard geometry.
  costing_method: string | null;
  piece_rate_per_vine: number | null;
  piece_vine_count: number | null;
  piece_rate_total_cost: number | null;
  created_at: string; updated_at: string;
}

const WORK_TASK_COLUMNS =
  "id, vineyard_id, task_type, status, date, start_date, end_date, duration_hours, area_ha, " +
  "paddock_id, paddock_name, description, notes, is_archived, is_finalized, origin, external_id, " +
  "costing_method, piece_rate_per_vine, piece_vine_count, piece_rate_total_cost, " +
  "created_at, updated_at";

// ---------------------------------------------------------------------------
// EFFECTIVE work task labour cost — the API side of sql/189.
//
//   costing_method = 'piece_rate'  -> work_tasks.piece_rate_total_cost
//   anything else (incl. null)     -> SUM of ACTIVE, RATED labour lines
//
// The two are NEVER summed, an unrecognised costing_method reads as hourly,
// and an absent figure is null ("not specified"), never 0. Unrated lines are
// skipped rather than counted as $0.00: total_cost is generated with
// coalesce(hourly_rate, 0), so summing them blindly turns "no rate entered"
// into a hard zero. Mirrors PieceRateCosting.effectiveLabourCost on both
// mobile clients and public.work_task_effective_labour_cost in the database.
// ---------------------------------------------------------------------------
function isPieceRate(row: WorkTaskRow): boolean {
  return row.costing_method === "piece_rate";
}

function effectiveWorkTaskLabourCost(
  row: WorkTaskRow, labourLineCost: number | null,
): number | null {
  if (isPieceRate(row)) return row.piece_rate_total_cost ?? null;
  return labourLineCost;
}

function workTaskLabourCostSource(
  row: WorkTaskRow, labourLineCost: number | null,
): string | null {
  if (isPieceRate(row)) return row.piece_rate_total_cost !== null ? "piece_rate" : null;
  return labourLineCost !== null ? "labour_lines" : null;
}

interface LabourCostRow { work_task_id: string; hourly_rate: number | null; total_cost: number }

/**
 * Active, RATED labour-line total per task. A task with no costed line is
 * absent from the map, so it reports "not specified" rather than $0.00.
 */
async function loadWorkTaskLabourLineCosts(
  db: SupabaseClient, taskIds: string[],
): Promise<Map<string, number>> {
  const result = new Map<string, number>();
  if (taskIds.length === 0) return result;
  const { data, error } = await db.from("work_task_labour_lines")
    .select("work_task_id, hourly_rate, total_cost")
    .in("work_task_id", taskIds)
    .is("deleted_at", null);
  if (error) {
    console.error("[vinetrack-api] work task labour costs lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  for (const l of (data ?? []) as LabourCostRow[]) {
    if (l.hourly_rate === null) continue;
    result.set(l.work_task_id, (result.get(l.work_task_id) ?? 0) + l.total_cost);
  }
  return result;
}

interface TaskBlockLink { work_task_id: string; paddock_id: string }

/** Blocks per task: work_task_paddocks joins, legacy paddock_id fallback. */
async function loadWorkTaskBlocks(
  db: SupabaseClient, vineyardId: string, tasks: WorkTaskRow[],
): Promise<Map<string, { id: string; name: string | null }[]>> {
  const result = new Map<string, { id: string; name: string | null }[]>();
  if (tasks.length === 0) return result;
  const { data, error } = await db.from("work_task_paddocks")
    .select("work_task_id, paddock_id")
    .in("work_task_id", tasks.map((t) => t.id))
    .is("deleted_at", null);
  if (error) {
    console.error("[vinetrack-api] work task paddocks lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  const links = (data ?? []) as TaskBlockLink[];
  const allBlockIds = links.map((l) => l.paddock_id);
  for (const t of tasks) if (t.paddock_id) allBlockIds.push(t.paddock_id);
  const names = await loadBlockNames(db, vineyardId, allBlockIds);
  for (const l of links) {
    const list = result.get(l.work_task_id) ?? [];
    if (!list.some((b) => b.id === l.paddock_id)) {
      list.push({ id: l.paddock_id, name: names.get(l.paddock_id) ?? null });
    }
    result.set(l.work_task_id, list);
  }
  // Legacy single-block tasks: fall back to the parent columns.
  for (const t of tasks) {
    if ((result.get(t.id)?.length ?? 0) === 0 && t.paddock_id) {
      result.set(t.id, [{
        id: t.paddock_id,
        name: names.get(t.paddock_id) ?? (t.paddock_name.trim() || null),
      }]);
    }
  }
  return result;
}

function mapWorkTask(
  row: WorkTaskRow,
  blocks: { id: string; name: string | null }[],
  profile: AuthProfile,
  labourLineCost: number | null = null,
) {
  const base: Record<string, unknown> = {
    id: row.id,
    vineyard_id: row.vineyard_id,
    task_type: row.task_type.trim() || null,
    status: row.status ?? null,
    date: row.date,
    start_date: row.start_date ?? null,
    end_date: row.end_date ?? null,
    duration_hours: row.duration_hours ?? null,
    area_ha: row.area_ha ?? null,
    blocks,
    description: row.description ?? null,
    notes: row.notes.trim() || null,
    is_archived: row.is_archived,
    is_finalized: row.is_finalized,
    origin: row.origin,
    external_id: row.external_id ?? null,
    // sql/188 contract. costing_method and the snapshot QUANTITY are
    // operational, so they are always present — a consumer must be able to
    // tell a piece-rate job apart without cost access. The agreed price and
    // the money it produces need costs:read.
    costing_method: row.costing_method ?? "hourly",
    piece_vine_count: row.piece_vine_count ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  if (hasScope(profile, "costs:read")) {
    base.piece_rate_per_vine = row.piece_rate_per_vine ?? null;
    base.piece_rate_total_cost = row.piece_rate_total_cost ?? null;
    // THE number to read. A piece-rate job reports it with zero labour lines;
    // no consumer ever has to fabricate a line to represent one.
    base.effective_labour_cost = effectiveWorkTaskLabourCost(row, labourLineCost);
    base.labour_cost_source = workTaskLabourCostSource(row, labourLineCost);
  }
  return base;
}

interface LabourLineRow {
  work_date: string; worker_type: string; worker_count: number;
  hours_per_worker: number; total_hours: number;
  hourly_rate: number | null; total_cost: number; notes: string;
}

interface MachineLineRow {
  work_date: string; equipment_source: string | null; equipment_ref_id: string | null;
  equipment_name_snapshot: string; operator_user_id: string | null;
  duration_hours: number | null; start_time: string | null; end_time: string | null;
  start_engine_hours: number | null; end_engine_hours: number | null;
  engine_hours_used: number | null; fuel_litres: number | null;
  fuel_cost: number | null; hourly_machine_rate: number | null;
  total_machine_cost: number | null; entry_source: string; notes: string;
}

/** Resolve a machine line's equipment link to the canonical machine id. */
function resolveLineEquipment(idx: MachineIndex, line: MachineLineRow): MachineRow | null {
  if (!line.equipment_ref_id) return null;
  if (line.equipment_source === "vineyard_machine") return idx.byId.get(line.equipment_ref_id) ?? null;
  if (line.equipment_source === "tractor") return idx.byLegacyTractorId.get(line.equipment_ref_id) ?? null;
  return null;
}

// ---------------------------------------------------------------------------
// Pruning (public.pruning_activities, sql/166 — the parent activity record;
// allocations live in public.pruning_entries, one per block).
//
// A REVERSED activity (deleted_at set via reverse/delete RPCs) has its
// quarters unclaimed — VineTrack's live progress excludes it entirely, so
// the API omits reversed activities from the collection. Reversed activity
// can therefore never inflate totals.
//
// worker_or_crew is a free-text identity snapshot -> labour:read.
// hourly_rate and the derived labour_cost -> costs:read.
// ---------------------------------------------------------------------------
interface PruningActivityRow {
  id: string; vineyard_id: string; entry_date: string;
  worker_or_crew: string; pruning_method: string;
  start_time: string | null; finish_time: string | null;
  labour_hours: number | null; hourly_rate: number | null;
  notes: string; work_task_id: string | null;
  season_year: number | null; vintage_year: number | null;
  allocation_count: number; total_quarters: number;
  total_row_equivalents: number; total_estimated_vines: number;
  block_summary: string;
  created_at: string; updated_at: string;
}

const PRUNING_ACTIVITY_COLUMNS =
  "id, vineyard_id, entry_date, worker_or_crew, pruning_method, start_time, finish_time, " +
  "labour_hours, hourly_rate, notes, work_task_id, season_year, vintage_year, " +
  "allocation_count, total_quarters, total_row_equivalents, total_estimated_vines, " +
  "block_summary, created_at, updated_at";

interface PruningAllocationRow {
  pruning_activity_id: string; paddock_id: string;
  row_equivalents_completed: number; estimated_vines_completed: number;
}

async function loadPruningAllocations(
  db: SupabaseClient, vineyardId: string, activityIds: string[],
): Promise<Map<string, { block_id: string; block_name: string | null; row_equivalents: number; vines_pruned: number }[]>> {
  const result = new Map<string, { block_id: string; block_name: string | null; row_equivalents: number; vines_pruned: number }[]>();
  if (activityIds.length === 0) return result;
  const { data, error } = await db.from("pruning_entries")
    .select("pruning_activity_id, paddock_id, row_equivalents_completed, estimated_vines_completed")
    .in("pruning_activity_id", activityIds)
    .is("deleted_at", null);
  if (error) {
    console.error("[vinetrack-api] pruning allocations lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  const rows = (data ?? []) as PruningAllocationRow[];
  const names = await loadBlockNames(db, vineyardId, rows.map((r) => r.paddock_id));
  for (const r of rows) {
    const list = result.get(r.pruning_activity_id) ?? [];
    list.push({
      block_id: r.paddock_id,
      block_name: names.get(r.paddock_id) ?? null,
      row_equivalents: round3(r.row_equivalents_completed),
      vines_pruned: r.estimated_vines_completed,
    });
    result.set(r.pruning_activity_id, list);
  }
  return result;
}

/**
 * Effective labour cost per pruning ACTIVITY — the API side of sql/189's
 * public.pruning_activity_effective_labour_cost.
 *
 *   linked piece-rate task -> its snapshot total (no fallback: an unpriced
 *                             piece-rate job is "not specified", and falling
 *                             back to hours x rate would report an HOURLY
 *                             figure for a piece-rate job)
 *   linked hourly/legacy   -> its rated labour lines, else the activity's own
 *                             hours x rate (so no pre-189 value changes)
 *   unlinked               -> hours x rate, exactly as before
 *
 * Precedence, never addition.
 */
interface ActivityLabour {
  cost: number | null;
  source: string | null;
  costing_method: string | null;
  piece_rate_per_vine: number | null;
  piece_vine_count: number | null;
}

async function loadPruningActivityLabour(
  db: SupabaseClient, rows: PruningActivityRow[],
): Promise<Map<string, ActivityLabour>> {
  const result = new Map<string, ActivityLabour>();
  const taskIds = [...new Set(rows
    .map((r) => r.work_task_id)
    .filter((v): v is string => typeof v === "string"))];

  const tasks = new Map<string, WorkTaskRow>();
  if (taskIds.length > 0) {
    const { data, error } = await db.from("work_tasks")
      .select(WORK_TASK_COLUMNS)
      .in("id", taskIds);
    if (error) {
      console.error("[vinetrack-api] pruning work task lookup failed:", error.message);
      throw new ApiError("internal_error");
    }
    for (const t of (data ?? []) as unknown as WorkTaskRow[]) tasks.set(t.id, t);
  }
  const lineCosts = await loadWorkTaskLabourLineCosts(db, taskIds);

  for (const r of rows) {
    const legacy = r.labour_hours !== null && r.hourly_rate !== null
      ? round3(r.labour_hours * r.hourly_rate)
      : null;
    const task = r.work_task_id ? tasks.get(r.work_task_id) : undefined;
    if (!task) {
      result.set(r.id, {
        cost: legacy,
        source: legacy !== null ? "activity_hours" : null,
        costing_method: null,
        piece_rate_per_vine: null,
        piece_vine_count: null,
      });
      continue;
    }
    const lineCost = lineCosts.get(task.id) ?? null;
    const piece = isPieceRate(task);
    const cost = piece ? (task.piece_rate_total_cost ?? null) : (lineCost ?? legacy);
    const source = piece
      ? (task.piece_rate_total_cost !== null ? "piece_rate" : null)
      : (lineCost !== null ? "labour_lines" : (legacy !== null ? "activity_hours" : null));
    result.set(r.id, {
      cost,
      source,
      costing_method: task.costing_method ?? "hourly",
      piece_rate_per_vine: task.piece_rate_per_vine ?? null,
      piece_vine_count: task.piece_vine_count ?? null,
    });
  }
  return result;
}

function mapPruningActivity(
  row: PruningActivityRow,
  blocks: { block_id: string; block_name: string | null; row_equivalents: number; vines_pruned: number }[],
  profile: AuthProfile,
  labour: ActivityLabour | null = null,
) {
  const hours = row.labour_hours;
  const vines = row.total_estimated_vines;
  const base: Record<string, unknown> = {
    id: row.id,
    vineyard_id: row.vineyard_id,
    date: row.entry_date,
    pruning_method: row.pruning_method || null,
    season_year: row.season_year ?? null,
    vintage_year: row.vintage_year ?? null,
    started_at: row.start_time ?? null,
    ended_at: row.finish_time ?? null,
    labour_hours: hours ?? null,
    vines_pruned: vines,
    row_equivalents: round3(row.total_row_equivalents),
    quarters_completed: row.total_quarters,
    // Derived: total estimated vines / activity labour hours (documented).
    vines_per_labour_hour: hours !== null && hours > 0 && vines > 0
      ? Math.round((vines / hours) * 10) / 10
      : null,
    block_summary: row.block_summary.trim() || null,
    blocks,
    work_task_id: row.work_task_id ?? null,
    notes: row.notes.trim() || null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  if (hasScope(profile, "labour:read")) {
    base.crew = row.worker_or_crew.trim() || null;
  }
  if (hasScope(profile, "costs:read")) {
    // hourly_rate stays as recorded — on a piece-rate job it is operational
    // history, never the cost basis.
    base.hourly_rate = row.hourly_rate ?? null;
    const legacy = hours !== null && row.hourly_rate !== null
      ? round3(hours * row.hourly_rate)
      : null;
    // sql/189: the shared effective rule. Falls back to the pre-189 value when
    // no linked task was resolved, so existing consumers see no change.
    base.labour_cost = labour ? labour.cost : legacy;
    base.labour_cost_source = labour
      ? labour.source
      : (legacy !== null ? "activity_hours" : null);
    base.costing_method = labour?.costing_method ?? null;
    base.piece_rate_per_vine = labour?.piece_rate_per_vine ?? null;
    base.piece_vine_count = labour?.piece_vine_count ?? null;
  }
  return base;
}

// ---------------------------------------------------------------------------
// Irrigation records (public.irrigation_sessions + irrigation_session_blocks,
// sql/125 + 130 + 142). Canonical units: litres, L/h, mm, whole minutes.
//
// Lifecycle: soft-deleted sessions are excluded; sessions with
// status='reversed' are excluded from the DEFAULT collection (they are
// corrections, not live history) but retrievable via ?status=reversed and
// by id. No cost or labour fields exist on irrigation sessions.
// ---------------------------------------------------------------------------
interface IrrigationSessionRow {
  id: string; vineyard_id: string;
  irrigation_system_id: string; valve_id: string;
  session_date: string; vintage_year: number;
  started_at: string | null; finished_at: string | null;
  duration_minutes: number; calculation_method: string;
  flow_litres_per_hour: number | null;
  total_volume_litres: number; effective_volume_litres: number | null;
  irrigation_efficiency_percent: number | null;
  status: string; source_type: string; notes: string | null;
  origin: string; external_id: string | null;
  created_at: string; updated_at: string;
}

const IRRIGATION_COLUMNS =
  "id, vineyard_id, irrigation_system_id, valve_id, session_date, vintage_year, started_at, " +
  "finished_at, duration_minutes, calculation_method, flow_litres_per_hour, total_volume_litres, " +
  "effective_volume_litres, irrigation_efficiency_percent, status, source_type, notes, " +
  "origin, external_id, created_at, updated_at";

const IRRIGATION_STATUS_VALUES = [
  "completed", "corrected", "reversed", "planned", "running", "cancelled", "imported", "estimated",
];

interface IrrigationSessionBlockRow {
  session_id: string; block_id: string;
  allocation_percentage: number; allocated_volume_litres: number;
  effective_volume_litres: number | null; serviced_area_m2: number | null;
  serviced_vine_count: number | null; water_litres_per_vine: number | null;
  water_litres_per_hectare: number | null; irrigation_depth_mm: number | null;
  effective_irrigation_depth_mm: number | null;
}

async function loadIrrigationBlocks(
  db: SupabaseClient, vineyardId: string, sessionIds: string[],
): Promise<Map<string, (IrrigationSessionBlockRow & { block_name: string | null })[]>> {
  const result = new Map<string, (IrrigationSessionBlockRow & { block_name: string | null })[]>();
  if (sessionIds.length === 0) return result;
  const { data, error } = await db.from("irrigation_session_blocks")
    .select("session_id, block_id, allocation_percentage, allocated_volume_litres, effective_volume_litres, " +
      "serviced_area_m2, serviced_vine_count, water_litres_per_vine, water_litres_per_hectare, " +
      "irrigation_depth_mm, effective_irrigation_depth_mm")
    .in("session_id", sessionIds);
  if (error) {
    console.error("[vinetrack-api] irrigation session blocks lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  const rows = (data ?? []) as unknown as IrrigationSessionBlockRow[];
  const names = await loadBlockNames(db, vineyardId, rows.map((r) => r.block_id));
  for (const r of rows) {
    const list = result.get(r.session_id) ?? [];
    list.push({ ...r, block_name: names.get(r.block_id) ?? null });
    result.set(r.session_id, list);
  }
  return result;
}

function mapIrrigationRecord(
  row: IrrigationSessionRow,
  blocks: (IrrigationSessionBlockRow & { block_name: string | null })[],
  detail: boolean,
) {
  return {
    id: row.id,
    vineyard_id: row.vineyard_id,
    date: row.session_date,
    vintage_year: row.vintage_year,
    status: row.status,
    started_at: row.started_at ?? null,
    ended_at: row.finished_at ?? null,
    duration_minutes: row.duration_minutes,
    calculation_method: row.calculation_method,
    source_type: row.source_type,
    flow_l_per_hour: row.flow_litres_per_hour ?? null,
    volume_l: row.total_volume_litres,
    effective_volume_l: row.effective_volume_litres ?? null,
    efficiency_percent: row.irrigation_efficiency_percent ?? null,
    irrigation_system_id: row.irrigation_system_id,
    valve_id: row.valve_id,
    blocks: blocks.map((b) => {
      const base: Record<string, unknown> = {
        block_id: b.block_id,
        block_name: b.block_name,
        allocation_percent: b.allocation_percentage,
        volume_l: b.allocated_volume_litres,
      };
      if (detail) {
        base.effective_volume_l = b.effective_volume_litres ?? null;
        // serviced_area_m2 is canonical; ha conversion is exact (÷ 10000).
        base.area_ha = b.serviced_area_m2 !== null ? round4(b.serviced_area_m2 / 10000) : null;
        base.vine_count = b.serviced_vine_count ?? null;
        base.water_l_per_vine = b.water_litres_per_vine ?? null;
        base.water_l_per_ha = b.water_litres_per_hectare ?? null;
        base.depth_mm = b.irrigation_depth_mm ?? null;
        base.effective_depth_mm = b.effective_irrigation_depth_mm ?? null;
      }
      return base;
    }),
    notes: (row.notes ?? "").trim() || null,
    origin: row.origin,
    external_id: row.external_id ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

// ---------------------------------------------------------------------------
// Growth stages (public.growth_stage_records, sql/055 — the canonical store;
// the iOS client mirrors legacy growth pins into it, so this table is the
// complete observation history).
//
// photo_paths (private storage paths) are intentionally NOT exposed.
// recorded_by identity -> labour:read.
// ---------------------------------------------------------------------------
interface GrowthStageRow {
  id: string; vineyard_id: string; paddock_id: string | null;
  stage_code: string; stage_label: string | null;
  variety: string | null; variety_id: string | null;
  observed_at: string; latitude: number | null; longitude: number | null;
  row_number: number | null; side: string | null; notes: string | null;
  recorded_by_name: string | null; created_by: string | null;
  origin: string; external_id: string | null;
  created_at: string; updated_at: string;
}

const GROWTH_STAGE_COLUMNS =
  "id, vineyard_id, paddock_id, stage_code, stage_label, variety, variety_id, observed_at, " +
  "latitude, longitude, row_number, side, notes, recorded_by_name, created_by, origin, external_id, " +
  "created_at, updated_at";

function mapGrowthStage(row: GrowthStageRow, blockName: string | null, profile: AuthProfile) {
  const base: Record<string, unknown> = {
    id: row.id,
    vineyard_id: row.vineyard_id,
    block_id: row.paddock_id ?? null,
    block_name: blockName,
    observed_at: row.observed_at,
    stage_code: row.stage_code,
    stage_label: row.stage_label ?? null,
    variety: row.variety ?? null,
    variety_id: row.variety_id ?? null,
    row_number: row.row_number ?? null,
    // Stored as 'Left'/'Right'; normalised to lowercase (documented).
    side: row.side ? row.side.toLowerCase() : null,
    latitude: row.latitude ?? null,
    longitude: row.longitude ?? null,
    notes: (row.notes ?? "").trim() || null,
    origin: row.origin,
    external_id: row.external_id ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  if (hasScope(profile, "labour:read")) {
    base.recorded_by = (row.created_by || row.recorded_by_name)
      ? { user_id: row.created_by ?? null, name: row.recorded_by_name ?? null }
      : null;
  }
  return base;
}

// ---------------------------------------------------------------------------
// Yield records (public.historical_yield_records, sql/014 — archived
// season results with per-block breakdown in block_results jsonb, camelCase
// iOS Codable keys).
//
// In-progress sampling sessions (yield_estimation_sessions) are working
// data, not recorded yield — intentionally NOT exposed.
// No pricing/revenue fields exist canonically; costs:read gates nothing
// here today (documented).
// ---------------------------------------------------------------------------
interface YieldRecordRow {
  id: string; vineyard_id: string;
  season: string; year: number; archived_at: string;
  total_yield_tonnes: number; total_area_hectares: number;
  notes: string; block_results: unknown;
  origin: string; external_id: string | null;
  created_at: string; updated_at: string;
}

const YIELD_RECORD_COLUMNS =
  "id, vineyard_id, season, year, archived_at, total_yield_tonnes, total_area_hectares, " +
  "notes, block_results, origin, external_id, created_at, updated_at";

interface YieldBlockJson {
  paddockId?: unknown; paddockName?: unknown; areaHectares?: unknown;
  yieldTonnes?: unknown; yieldPerHectare?: unknown; averageBunchesPerVine?: unknown;
  averageBunchWeightGrams?: unknown; totalVines?: unknown; samplesRecorded?: unknown;
  damageFactor?: unknown; actualYieldTonnes?: unknown; actualRecordedAt?: unknown;
}

function mapYieldBlocks(raw: unknown) {
  if (!Array.isArray(raw)) return [];
  return (raw as YieldBlockJson[]).map((b) => ({
    block_id: typeof b.paddockId === "string" ? b.paddockId.toLowerCase() : null,
    block_name: typeof b.paddockName === "string" ? b.paddockName : null,
    area_ha: num(b.areaHectares),
    estimated_yield_tonnes: num(b.yieldTonnes),
    yield_tonnes_per_ha: num(b.yieldPerHectare),
    average_bunches_per_vine: num(b.averageBunchesPerVine),
    average_bunch_weight_g: num(b.averageBunchWeightGrams),
    vine_count: num(b.totalVines),
    samples_recorded: num(b.samplesRecorded),
    damage_factor: num(b.damageFactor),
    actual_yield_tonnes: num(b.actualYieldTonnes),
    actual_recorded_at: typeof b.actualRecordedAt === "string" ? b.actualRecordedAt : null,
  }));
}

function mapYieldRecord(row: YieldRecordRow) {
  const area = row.total_area_hectares;
  return {
    id: row.id,
    vineyard_id: row.vineyard_id,
    season: row.season.trim() || null,
    vintage_year: row.year > 0 ? row.year : null,
    archived_at: row.archived_at,
    total_yield_tonnes: row.total_yield_tonnes,
    total_area_ha: area,
    // Derived: total_yield_tonnes / total_area_hectares (documented).
    yield_tonnes_per_ha: area > 0 ? round3(row.total_yield_tonnes / area) : null,
    blocks: mapYieldBlocks(row.block_results),
    notes: row.notes.trim() || null,
    origin: row.origin,
    external_id: row.external_id ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

// ---------------------------------------------------------------------------
// Pins (public.pins, sql/004 + 013/035/041/169/170; canonical placement
// resolution via the public.pin_placements view, sql/171).
//
// The exact snapped path/row identity is preserved: path_number
// (driving_row_number, e.g. 19.5), row_number (pin_row_number), side
// (left/right). photo_path (private storage path) is NOT exposed.
// Identity fields (assigned_to / completed_by) -> labour:read.
// Resolved (completed) pins remain in the collection as history and are
// filterable by status.
// ---------------------------------------------------------------------------
interface PinRow {
  id: string; vineyard_id: string; paddock_id: string | null;
  mode: string | null; category: string | null; priority: string | null;
  status: string | null; title: string | null; notes: string | null;
  latitude: number | null; longitude: number | null;
  row_number: number | null; side: string | null;
  growth_stage_code: string | null;
  is_completed: boolean; completed_by: string | null;
  completed_by_user_id: string | null; completed_at: string | null;
  assigned_user_id: string | null; due_date: string | null;
  linked_work_task_id: string | null; custom_type_id: string | null;
  driving_row_number: number | null; pin_row_number: number | null;
  pin_side: string | null; along_row_distance_m: number | null;
  snapped_latitude: number | null; snapped_longitude: number | null;
  snapped_to_row: boolean;
  created_at: string; updated_at: string;
}

const PIN_COLUMNS =
  "id, vineyard_id, paddock_id, mode, category, priority, status, title, notes, latitude, longitude, " +
  "row_number, side, growth_stage_code, is_completed, completed_by, completed_by_user_id, completed_at, " +
  "assigned_user_id, due_date, linked_work_task_id, custom_type_id, driving_row_number, pin_row_number, " +
  "pin_side, along_row_distance_m, snapped_latitude, snapped_longitude, snapped_to_row, created_at, updated_at";

const PIN_MODE_MAP: Record<string, string> = {
  "Repairs": "repairs", "Growth": "growth", "ManualIssue": "manual_issue",
};
const PIN_TYPE_PARAM_TO_MODE: Record<string, string> = {
  "repairs": "Repairs", "growth": "Growth", "manual_issue": "ManualIssue",
};
const PIN_STATUS_VALUES = ["open", "in_progress", "completed", "cancelled"];

/**
 * Canonical stored status wins (composer pins, sql/169); legacy pins have
 * no stored status and derive from is_completed. Documented derivation.
 */
function pinStatus(row: PinRow): string {
  if (row.status && PIN_STATUS_VALUES.includes(row.status)) return row.status;
  return row.is_completed ? "completed" : "open";
}

interface PinPlacementRow {
  pin_id: string;
  location_scope: string | null;
  location_assignment_basis: string | null;
  paddock_id: string | null;
  paddock_name: string | null;
  row_summary: string | null;
  segments: unknown;
  location_warning_code: string | null;
}

/** Batch placement resolution via the sql/171 canonical view. */
async function loadPinPlacements(
  db: SupabaseClient, pinIds: string[],
): Promise<Map<string, PinPlacementRow>> {
  if (pinIds.length === 0) return new Map();
  const { data, error } = await db.from("pin_placements")
    .select("pin_id, location_scope, location_assignment_basis, paddock_id, paddock_name, " +
      "row_summary, segments, location_warning_code")
    .in("pin_id", pinIds);
  if (error) {
    console.error("[vinetrack-api] pin placement lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  return new Map(((data ?? []) as unknown as PinPlacementRow[]).map((p) => [p.pin_id, p]));
}

async function loadCustomPinTypes(
  db: SupabaseClient, ids: string[],
): Promise<Map<string, string>> {
  const unique = [...new Set(ids)].filter((id) => UUID_RE.test(id));
  if (unique.length === 0) return new Map();
  const { data, error } = await db.from("vineyard_custom_pin_types")
    .select("id, name")
    .in("id", unique);
  if (error) {
    console.error("[vinetrack-api] custom pin type lookup failed:", error.message);
    throw new ApiError("internal_error");
  }
  return new Map((data ?? []).map((t: { id: string; name: string }) => [t.id, t.name]));
}

function mapPin(
  row: PinRow,
  placement: PinPlacementRow | null,
  customTypeNames: Map<string, string>,
  profile: AuthProfile,
  detail: boolean,
) {
  const base: Record<string, unknown> = {
    id: row.id,
    vineyard_id: row.vineyard_id,
    type: row.mode ? (PIN_MODE_MAP[row.mode] ?? row.mode.toLowerCase()) : null,
    custom_type: row.custom_type_id
      ? { id: row.custom_type_id, name: customTypeNames.get(row.custom_type_id) ?? null }
      : null,
    category: row.category ?? null,
    priority: row.priority ?? null,
    status: pinStatus(row),
    title: (row.title ?? "").trim() || null,
    notes: (row.notes ?? "").trim() || null,
    growth_stage_code: row.growth_stage_code ?? null,
    block_id: placement?.paddock_id ?? row.paddock_id ?? null,
    block_name: placement?.paddock_name ?? null,
    latitude: row.latitude ?? null,
    longitude: row.longitude ?? null,
    // Exact snapped path/row identity — never reduced to raw GPS.
    row: {
      snapped_to_row: row.snapped_to_row,
      path_number: row.driving_row_number ?? null,
      row_number: row.pin_row_number ?? row.row_number ?? null,
      side: (row.pin_side ?? row.side)?.toLowerCase() ?? null,
      along_row_distance_m: row.along_row_distance_m ?? null,
      snapped_latitude: row.snapped_latitude ?? null,
      snapped_longitude: row.snapped_longitude ?? null,
    },
    location: {
      scope: placement?.location_scope ?? null,
      assignment_basis: placement?.location_assignment_basis ?? null,
      row_summary: placement?.row_summary ?? null,
      warning: placement?.location_warning_code ?? null,
    },
    due_date: row.due_date ?? null,
    work_task_id: row.linked_work_task_id ?? null,
    resolved_at: row.completed_at ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  if (detail) {
    const segs = Array.isArray(placement?.segments) ? placement!.segments as Record<string, unknown>[] : [];
    base.row_segments = segs
      .map((s) => ({ row: num(s.row), segment: num(s.segment) }))
      .filter((s) => s.row !== null && s.segment !== null);
  }
  if (hasScope(profile, "labour:read")) {
    base.assigned_to = row.assigned_user_id ? { user_id: row.assigned_user_id, name: null } : null;
    base.completed_by = (row.completed_by_user_id || row.completed_by)
      ? { user_id: row.completed_by_user_id ?? null, name: row.completed_by?.trim() || null }
      : null;
  }
  return base;
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3C: Work tasks
// ---------------------------------------------------------------------------
async function handleWorkTaskList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "work_tasks:read",
    ["status", "task_type", "block_id"], true);

  const statusFilter = textParam(url, "status");
  const taskTypeFilter = textParam(url, "task_type");
  const blockFilter = blockIdParam(url);

  // block filter: parent legacy paddock_id OR membership in work_task_paddocks.
  let blockOrExpr: string | null = null;
  if (blockFilter) {
    const { data, error } = await db.from("work_task_paddocks")
      .select("work_task_id")
      .eq("vineyard_id", args.vineyardId)
      .eq("paddock_id", blockFilter)
      .is("deleted_at", null)
      .limit(SUBFILTER_MAX_IDS);
    if (error) {
      console.error("[vinetrack-api] work task block filter failed:", error.message);
      throw new ApiError("internal_error");
    }
    const ids = [...new Set((data ?? []).map((r: { work_task_id: string }) => r.work_task_id))];
    blockOrExpr = ids.length > 0
      ? `paddock_id.eq.${blockFilter},id.in.(${ids.join(",")})`
      : `paddock_id.eq.${blockFilter}`;
  }

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "date");
  const { rows, nextCursor } = await pagedList<WorkTaskRow>(
    db, "work_tasks", WORK_TASK_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      q = dateFilter(q);
      if (statusFilter) q = q.eq("status", statusFilter);
      if (taskTypeFilter) q = q.eq("task_type", taskTypeFilter);
      if (blockOrExpr) q = q.or(blockOrExpr);
      return q;
    },
  );

  const blocks = await loadWorkTaskBlocks(db, args.vineyardId, rows);
  // Effective labour cost needs the hourly side too. Only fetched when the key
  // may see money at all, so an unprivileged listing costs no extra query.
  const labourCosts = hasScope(profile, "costs:read")
    ? await loadWorkTaskLabourLineCosts(db, rows.map((r) => r.id))
    : new Map<string, number>();
  return jsonResponse(req, ctx, {
    data: rows.map((r) =>
      mapWorkTask(r, blocks.get(r.id) ?? [], profile, labourCosts.get(r.id) ?? null)
    ),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleWorkTaskGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, taskId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(taskId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("work_tasks")
    .select(WORK_TASK_COLUMNS)
    .eq("id", taskId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] work task fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "work_tasks:read");
    throw new ApiError("resource_not_found");
  }

  const task = data as unknown as WorkTaskRow;
  ctx.vineyardId = task.vineyard_id;
  await validateVineyardRequest(db, key, "work_tasks:read", task.vineyard_id, true);

  const blocks = await loadWorkTaskBlocks(db, task.vineyard_id, [task]);

  const includeCosts = hasScope(profile, "costs:read");
  const includeLabour = hasScope(profile, "labour:read");

  // Labour lines (per-day, per-worker-type; counts and hours — no identity).
  // Loaded BEFORE the task is mapped so effective_labour_cost is resolved from
  // the same lines the response reports, never a second query that could drift.
  const { data: labourData, error: labourErr } = await db.from("work_task_labour_lines")
    .select("work_date, worker_type, worker_count, hours_per_worker, total_hours, hourly_rate, total_cost, notes")
    .eq("work_task_id", task.id)
    .is("deleted_at", null)
    .order("work_date", { ascending: true });
  if (labourErr) {
    console.error("[vinetrack-api] work task labour lines failed:", labourErr.message);
    throw new ApiError("internal_error");
  }
  const labourLines = (labourData ?? []) as LabourLineRow[];

  // Rated lines only: an unrated line is recorded hours, not a $0.00 cost.
  const ratedLines = labourLines.filter((l) => l.hourly_rate !== null);
  const labourLineCost = ratedLines.length > 0
    ? ratedLines.reduce((sum, l) => sum + l.total_cost, 0)
    : null;

  const body = mapWorkTask(
    task, blocks.get(task.id) ?? [], profile, labourLineCost,
  ) as Record<string, unknown>;

  let totalLabourHours = 0;
  body.labour_lines = labourLines.map((l) => {
    totalLabourHours += l.total_hours;
    const line: Record<string, unknown> = {
      work_date: l.work_date,
      worker_type: l.worker_type.trim() || null,
      worker_count: l.worker_count,
      hours_per_worker: l.hours_per_worker,
      total_hours: l.total_hours,
      notes: l.notes.trim() || null,
    };
    if (includeCosts) {
      line.hourly_rate = l.hourly_rate ?? null;
      line.total_cost = l.hourly_rate !== null ? l.total_cost : null;
    }
    return line;
  });
  body.total_labour_hours = round3(totalLabourHours);

  // Machine lines (manual machine work; equipment resolves to canonical id).
  const { data: machineData, error: machineErr } = await db.from("work_task_machine_lines")
    .select("work_date, equipment_source, equipment_ref_id, equipment_name_snapshot, operator_user_id, " +
      "duration_hours, start_time, end_time, start_engine_hours, end_engine_hours, engine_hours_used, " +
      "fuel_litres, fuel_cost, hourly_machine_rate, total_machine_cost, entry_source, notes")
    .eq("work_task_id", task.id)
    .is("deleted_at", null)
    .order("work_date", { ascending: true });
  if (machineErr) {
    console.error("[vinetrack-api] work task machine lines failed:", machineErr.message);
    throw new ApiError("internal_error");
  }
  const machineLines = (machineData ?? []) as unknown as MachineLineRow[];
  const idx = machineLines.length > 0
    ? await loadMachineIndex(db, task.vineyard_id)
    : { byId: new Map<string, MachineRow>(), byLegacyTractorId: new Map<string, MachineRow>() };
  body.machine_lines = machineLines.map((l) => {
    const machine = resolveLineEquipment(idx, l);
    const line: Record<string, unknown> = {
      work_date: l.work_date,
      equipment_id: machine?.id ?? null,
      equipment_name: l.equipment_name_snapshot.trim() || (machine ? machine.name.trim() : "") || null,
      duration_hours: l.duration_hours ?? null,
      started_at: l.start_time ?? null,
      ended_at: l.end_time ?? null,
      engine_hours_start: l.start_engine_hours ?? null,
      engine_hours_end: l.end_engine_hours ?? null,
      engine_hours_used: l.engine_hours_used ?? null,
      fuel_volume_l: l.fuel_litres ?? null,
      entry_source: l.entry_source,
      notes: l.notes.trim() || null,
    };
    if (includeCosts) {
      line.fuel_cost = l.fuel_cost ?? null;
      line.hourly_rate = l.hourly_machine_rate ?? null;
      line.total_cost = l.total_machine_cost ?? null;
    }
    if (includeLabour) {
      line.operator = l.operator_user_id ? { user_id: l.operator_user_id, name: null } : null;
    }
    return line;
  });

  // Linked GPS trips (ids only; full trips are a separate scoped resource).
  const { data: tripData, error: tripErr } = await db.from("trips")
    .select("id")
    .eq("work_task_id", task.id)
    .is("deleted_at", null);
  if (tripErr) {
    console.error("[vinetrack-api] work task trips lookup failed:", tripErr.message);
    throw new ApiError("internal_error");
  }
  body.trip_ids = (tripData ?? []).map((t: { id: string }) => t.id);

  return jsonResponse(req, ctx, { data: body }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3C: Pruning
// ---------------------------------------------------------------------------
async function handlePruningList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "pruning:read", ["block_id"], true);

  const blockFilter = blockIdParam(url);
  let activityIdFilter: string[] | null = null;
  if (blockFilter) {
    const { data, error } = await db.from("pruning_entries")
      .select("pruning_activity_id")
      .eq("vineyard_id", args.vineyardId)
      .eq("paddock_id", blockFilter)
      .is("deleted_at", null)
      .not("pruning_activity_id", "is", null)
      .limit(SUBFILTER_MAX_IDS);
    if (error) {
      console.error("[vinetrack-api] pruning block filter failed:", error.message);
      throw new ApiError("internal_error");
    }
    activityIdFilter = [...new Set((data ?? [])
      .map((r: { pruning_activity_id: string | null }) => r.pruning_activity_id)
      .filter((v): v is string => typeof v === "string"))];
    if (activityIdFilter.length === 0) return emptyCollection(req, ctx);
  }

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "entry_date");
  const { rows, nextCursor } = await pagedList<PruningActivityRow>(
    db, "pruning_activities", PRUNING_ACTIVITY_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      q = dateFilter(q);
      if (activityIdFilter) q = q.in("id", activityIdFilter);
      return q;
    },
  );

  const allocations = await loadPruningAllocations(db, args.vineyardId, rows.map((r) => r.id));
  const labour = hasScope(profile, "costs:read")
    ? await loadPruningActivityLabour(db, rows)
    : new Map<string, ActivityLabour>();
  return jsonResponse(req, ctx, {
    data: rows.map((r) =>
      mapPruningActivity(r, allocations.get(r.id) ?? [], profile, labour.get(r.id) ?? null)
    ),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handlePruningGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, activityId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(activityId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("pruning_activities")
    .select(PRUNING_ACTIVITY_COLUMNS)
    .eq("id", activityId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] pruning fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "pruning:read");
    throw new ApiError("resource_not_found");
  }

  const activity = data as unknown as PruningActivityRow;
  ctx.vineyardId = activity.vineyard_id;
  await validateVineyardRequest(db, key, "pruning:read", activity.vineyard_id, true);

  const allocations = await loadPruningAllocations(db, activity.vineyard_id, [activity.id]);
  const labour = hasScope(profile, "costs:read")
    ? await loadPruningActivityLabour(db, [activity])
    : new Map<string, ActivityLabour>();
  return jsonResponse(req, ctx, {
    data: mapPruningActivity(
      activity, allocations.get(activity.id) ?? [], profile, labour.get(activity.id) ?? null,
    ),
  }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3C: Irrigation records
// ---------------------------------------------------------------------------
async function handleIrrigationList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "irrigation:read",
    ["status", "block_id"], true);

  const statusFilter = url.searchParams.get("status");
  if (statusFilter !== null && !IRRIGATION_STATUS_VALUES.includes(statusFilter)) {
    throw new ApiError("invalid_request");
  }

  const blockFilter = blockIdParam(url);
  let sessionIdFilter: string[] | null = null;
  if (blockFilter) {
    const { data, error } = await db.from("irrigation_session_blocks")
      .select("session_id")
      .eq("vineyard_id", args.vineyardId)
      .eq("block_id", blockFilter)
      .limit(SUBFILTER_MAX_IDS);
    if (error) {
      console.error("[vinetrack-api] irrigation block filter failed:", error.message);
      throw new ApiError("internal_error");
    }
    sessionIdFilter = [...new Set((data ?? []).map((r: { session_id: string }) => r.session_id))];
    if (sessionIdFilter.length === 0) return emptyCollection(req, ctx);
  }

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "session_date");
  const { rows, nextCursor } = await pagedList<IrrigationSessionRow>(
    db, "irrigation_sessions", IRRIGATION_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      q = dateFilter(q);
      if (statusFilter) q = q.eq("status", statusFilter);
      // Reversed sessions are corrections — excluded from the default view.
      else q = q.neq("status", "reversed");
      if (sessionIdFilter) q = q.in("id", sessionIdFilter);
      return q;
    },
  );

  const blocks = await loadIrrigationBlocks(db, args.vineyardId, rows.map((r) => r.id));
  return jsonResponse(req, ctx, {
    data: rows.map((r) => mapIrrigationRecord(r, blocks.get(r.id) ?? [], false)),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleIrrigationGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, recordId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(recordId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("irrigation_sessions")
    .select(IRRIGATION_COLUMNS)
    .eq("id", recordId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] irrigation fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "irrigation:read");
    throw new ApiError("resource_not_found");
  }

  const session = data as unknown as IrrigationSessionRow;
  ctx.vineyardId = session.vineyard_id;
  await validateVineyardRequest(db, key, "irrigation:read", session.vineyard_id, true);

  const blocks = await loadIrrigationBlocks(db, session.vineyard_id, [session.id]);
  const body = mapIrrigationRecord(session, blocks.get(session.id) ?? [], true) as Record<string, unknown>;

  // System / valve display names (detail only).
  const [{ data: system, error: sysErr }, { data: valve, error: valveErr }] = await Promise.all([
    db.from("irrigation_systems").select("id, name").eq("id", session.irrigation_system_id).maybeSingle(),
    db.from("irrigation_valves").select("id, name, valve_number").eq("id", session.valve_id).maybeSingle(),
  ]);
  if (sysErr || valveErr) {
    console.error("[vinetrack-api] irrigation system/valve lookup failed:", sysErr?.message ?? valveErr?.message);
    throw new ApiError("internal_error");
  }
  body.system = system ? { id: system.id, name: system.name } : null;
  body.valve = valve ? { id: valve.id, name: valve.name, valve_number: valve.valve_number ?? null } : null;

  return jsonResponse(req, ctx, { data: body }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3C: Growth stages
// ---------------------------------------------------------------------------
async function handleGrowthStageList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "growth_stages:read",
    ["block_id", "stage_code"], true);

  const blockFilter = blockIdParam(url);
  const stageCodeFilter = textParam(url, "stage_code");

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "observed_at");
  const { rows, nextCursor } = await pagedList<GrowthStageRow>(
    db, "growth_stage_records", GROWTH_STAGE_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      q = dateFilter(q);
      if (blockFilter) q = q.eq("paddock_id", blockFilter);
      if (stageCodeFilter) q = q.eq("stage_code", stageCodeFilter);
      return q;
    },
  );

  const names = await loadBlockNames(db, args.vineyardId,
    rows.map((r) => r.paddock_id).filter((v): v is string => v !== null));
  return jsonResponse(req, ctx, {
    data: rows.map((r) => mapGrowthStage(r, r.paddock_id ? names.get(r.paddock_id) ?? null : null, profile)),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleGrowthStageGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, recordId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(recordId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("growth_stage_records")
    .select(GROWTH_STAGE_COLUMNS)
    .eq("id", recordId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] growth stage fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "growth_stages:read");
    throw new ApiError("resource_not_found");
  }

  const record = data as unknown as GrowthStageRow;
  ctx.vineyardId = record.vineyard_id;
  await validateVineyardRequest(db, key, "growth_stages:read", record.vineyard_id, true);

  const names = record.paddock_id
    ? await loadBlockNames(db, record.vineyard_id, [record.paddock_id])
    : new Map<string, string>();
  return jsonResponse(req, ctx, {
    data: mapGrowthStage(record, record.paddock_id ? names.get(record.paddock_id) ?? null : null, profile),
  }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3C: Yield records
// ---------------------------------------------------------------------------
async function handleYieldRecordList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "yield:read", ["vintage"], true);

  const vintageRaw = url.searchParams.get("vintage");
  let vintage: number | null = null;
  if (vintageRaw !== null) {
    if (!/^\d{4}$/.test(vintageRaw)) throw new ApiError("invalid_request");
    vintage = Number(vintageRaw);
  }

  const dateFilter = applyDateRange(args.fromDate, args.toDate, "archived_at");
  const { rows, nextCursor } = await pagedList<YieldRecordRow>(
    db, "historical_yield_records", YIELD_RECORD_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      q = dateFilter(q);
      if (vintage !== null) q = q.eq("year", vintage);
      return q;
    },
  );

  return jsonResponse(req, ctx, {
    data: rows.map(mapYieldRecord),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handleYieldRecordGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, recordId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(recordId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("historical_yield_records")
    .select(YIELD_RECORD_COLUMNS)
    .eq("id", recordId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] yield record fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "yield:read");
    throw new ApiError("resource_not_found");
  }

  const record = data as unknown as YieldRecordRow;
  ctx.vineyardId = record.vineyard_id;
  await validateVineyardRequest(db, key, "yield:read", record.vineyard_id, true);

  return jsonResponse(req, ctx, { data: mapYieldRecord(record) }, 200);
}

// ---------------------------------------------------------------------------
// Route handlers — Stage 3C: Pins
// ---------------------------------------------------------------------------
async function handlePinList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL,
): Promise<Response> {
  const args = await prepareCollection(ctx, db, key, url, "pins:read",
    ["block_id", "status", "category", "type"], false);

  const blockFilter = blockIdParam(url);
  const categoryFilter = textParam(url, "category");

  const statusFilter = url.searchParams.get("status");
  if (statusFilter !== null && !PIN_STATUS_VALUES.includes(statusFilter)) {
    throw new ApiError("invalid_request");
  }

  const typeFilter = url.searchParams.get("type");
  let modeEq: string | null = null;
  if (typeFilter !== null) {
    modeEq = PIN_TYPE_PARAM_TO_MODE[typeFilter] ?? null;
    if (!modeEq) throw new ApiError("invalid_request");
  }

  const { rows, nextCursor } = await pagedList<PinRow>(
    db, "pins", PIN_COLUMNS, args.limit, args.cursor, false,
    (q) => {
      q = q.eq("vineyard_id", args.vineyardId);
      if (blockFilter) q = q.eq("paddock_id", blockFilter);
      if (categoryFilter) q = q.eq("category", categoryFilter);
      if (modeEq) q = q.eq("mode", modeEq);
      if (statusFilter) {
        // Matches the documented status derivation: canonical stored status
        // wins; legacy pins (no stored status) derive from is_completed.
        if (statusFilter === "completed") {
          q = q.or("status.eq.completed,and(status.is.null,is_completed.eq.true)");
        } else if (statusFilter === "open") {
          q = q.or("status.eq.open,and(status.is.null,is_completed.eq.false)");
        } else {
          q = q.eq("status", statusFilter);
        }
      }
      return q;
    },
  );

  const placements = await loadPinPlacements(db, rows.map((r) => r.id));
  const customTypes = await loadCustomPinTypes(db,
    rows.map((r) => r.custom_type_id).filter((v): v is string => v !== null));

  return jsonResponse(req, ctx, {
    data: rows.map((r) => mapPin(r, placements.get(r.id) ?? null, customTypes, profile, false)),
    pagination: { next_cursor: nextCursor },
  }, 200);
}

async function handlePinGet(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string,
  profile: AuthProfile, url: URL, pinId: string,
): Promise<Response> {
  enforceAllowedParams(url, []);
  if (!UUID_RE.test(pinId)) throw new ApiError("invalid_request");

  const { data, error } = await db.from("pins")
    .select(PIN_COLUMNS)
    .eq("id", pinId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] pin fetch failed:", error.message);
    throw new ApiError("internal_error");
  }
  if (!data) {
    requireScope(profile, "pins:read");
    throw new ApiError("resource_not_found");
  }

  const pin = data as unknown as PinRow;
  ctx.vineyardId = pin.vineyard_id;
  await validateVineyardRequest(db, key, "pins:read", pin.vineyard_id, true);

  const placements = await loadPinPlacements(db, [pin.id]);
  const customTypes = await loadCustomPinTypes(db, pin.custom_type_id ? [pin.custom_type_id] : []);
  return jsonResponse(req, ctx, {
    data: mapPin(pin, placements.get(pin.id) ?? null, customTypes, profile, true),
  }, 200);
}

// ---------------------------------------------------------------------------
// Stage 3D: environmental & advisory resources (weather / rainfall /
// disease-risk). Canonical sources — audited, never guessed:
//
//   * Current weather — public.vineyard_weather_observations (sql/026 +
//     sql/104): the Davis WeatherLink cache written ONLY by the davis-proxy
//     edge function. Reads here are CACHE-ONLY: the public API can never
//     trigger an upstream Davis fetch (the same rule the app RPC
//     get_vineyard_current_weather enforces). Canonical stale threshold:
//     20 minutes. raw_payload is NEVER selected or exposed.
//   * Forecast — the vineyard's canonical forecast provider chain
//     (sql/061 vineyards.forecast_provider: auto | open_meteo |
//     willyweather). WillyWeather uses the global project key and the
//     vineyard's saved WillyWeather location; Open-Meteo uses the
//     server-resolved vineyard coordinates. Both are served through
//     integration_environment_cache (sql/176) so API traffic can trigger
//     at most ONE upstream request per vineyard per TTL window.
//   * Rainfall — public.rainfall_daily (sql/028-031) via the
//     service-role helper integration_get_rainfall (sql/176). Observed
//     rainfall only (never forecast), priority-resolved per date:
//     manual > davis_weatherlink > wunderground_pws > open_meteo.
//   * Disease risk — the three MVP models shared 1:1 by the iOS and
//     Android apps (downy mildew simplified 10:10:24, powdery mildew
//     simplified Gubler-Thomas, botrytis simplified Broome/Bulit),
//     computed from Open-Meteo hourly data with the canonical
//     estimated-wetness proxy (rain > 0 OR RH >= 90% OR T - dewpoint
//     <= 2°C). No numeric score is exposed — the apps' 10/60/90 values
//     are a chart index, not a canonical score. Results are cached per
//     vineyard (30-minute TTL) with a marked stale fallback up to 24 h.
// ---------------------------------------------------------------------------
const CURRENT_WEATHER_STALE_MS = 20 * 60_000; // canonical (sql/026)
const FORECAST_CACHE_TTL_MS = 3 * 3_600_000;
const FORECAST_HORIZON_DAYS = 7;
const DISEASE_CACHE_TTL_MS = 30 * 60_000;
const DISEASE_STALE_FALLBACK_MAX_MS = 24 * 3_600_000;
const UPSTREAM_TIMEOUT_MS = 8_000;
const DISEASE_MODEL_VERSION = "mvp-1";

const COMPASS_POINTS = [
  "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
  "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
];

/** 16-point compass direction — the same mapping the weather-current proxy uses. */
function compassDirection(deg: number): string {
  const n = ((deg % 360) + 360) % 360;
  return COMPASS_POINTS[Math.round(n / 22.5) % 16];
}

/** Coerce upstream-provider values (numbers or numeric strings) safely. */
function coerceNum(v: unknown): number | null {
  if (v == null) return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

// Date-keyed keyset cursor for /v1/rainfall (daily series has no uuid key
// after priority resolution — the date IS the stable key).
function encodeDateCursor(date: string): string {
  return btoa(JSON.stringify({ d: date })).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeDateCursor(raw: string): string {
  try {
    const b64 = raw.replaceAll("-", "+").replaceAll("_", "/");
    const parsed = JSON.parse(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)));
    if (typeof parsed?.d !== "string" || !DATE_RE.test(parsed.d)) throw new Error("bad cursor");
    const ms = Date.parse(parsed.d + "T00:00:00Z");
    if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== parsed.d) throw new Error("bad cursor");
    return parsed.d;
  } catch {
    throw new ApiError("invalid_cursor");
  }
}

// --- Environment cache (sql/176) — service-role only, non-fatal on error ---
interface EnvCacheRow {
  payload: Record<string, unknown>;
  fetched_at: string;
}

async function readEnvCache(db: SupabaseClient, vineyardId: string, kind: string): Promise<EnvCacheRow | null> {
  const { data, error } = await db.from("integration_environment_cache")
    .select("payload, fetched_at")
    .eq("vineyard_id", vineyardId)
    .eq("kind", kind)
    .maybeSingle();
  if (error) {
    console.error("[vinetrack-api] env cache read failed:", error.message);
    return null;
  }
  return data ? (data as unknown as EnvCacheRow) : null;
}

async function writeEnvCache(db: SupabaseClient, vineyardId: string, kind: string, payload: Record<string, unknown>): Promise<void> {
  const { error } = await db.from("integration_environment_cache").upsert({
    vineyard_id: vineyardId,
    kind,
    payload,
    fetched_at: new Date().toISOString(),
  }, { onConflict: "vineyard_id,kind" });
  if (error) console.error("[vinetrack-api] env cache write failed:", error.message);
}

// --- Vineyard coordinate resolution -----------------------------------------
// Mirrors the canonical server-side order used by the open-meteo-proxy edge
// function: weather-station coordinates, then block polygon centroid, then
// pin centroid. Coordinates are exposed externally rounded to 2 dp (~1 km)
// — coarse weather location, never precise private geometry.
interface VineyardCoords {
  lat: number;
  lon: number;
  basis: "station" | "blocks" | "pins";
}

async function resolveVineyardCoords(db: SupabaseClient, vineyardId: string): Promise<VineyardCoords | null> {
  const { data: integs } = await db.from("vineyard_weather_integrations")
    .select("provider, station_latitude, station_longitude")
    .eq("vineyard_id", vineyardId);
  if (Array.isArray(integs)) {
    const order = ["davis_weatherlink", "wunderground", "willyweather"];
    const sorted = [...integs].sort((a, b) => {
      const ai = order.indexOf(String((a as Record<string, unknown>).provider));
      const bi = order.indexOf(String((b as Record<string, unknown>).provider));
      return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
    });
    for (const it of sorted) {
      const la = coerceNum((it as Record<string, unknown>).station_latitude);
      const lo = coerceNum((it as Record<string, unknown>).station_longitude);
      if (la !== null && lo !== null) return { lat: la, lon: lo, basis: "station" };
    }
  }

  const { data: paddocks } = await db.from("paddocks")
    .select("polygon_points")
    .eq("vineyard_id", vineyardId)
    .is("deleted_at", null);
  if (Array.isArray(paddocks) && paddocks.length > 0) {
    let sumLat = 0, sumLon = 0, count = 0;
    for (const p of paddocks) {
      const pts = (p as Record<string, unknown>).polygon_points;
      if (!Array.isArray(pts)) continue;
      for (const pt of pts) {
        const la = coerceNum((pt as Record<string, unknown>)?.latitude);
        const lo = coerceNum((pt as Record<string, unknown>)?.longitude);
        if (la !== null && lo !== null) { sumLat += la; sumLon += lo; count++; }
      }
    }
    if (count > 0) return { lat: sumLat / count, lon: sumLon / count, basis: "blocks" };
  }

  const { data: pins } = await db.from("pins")
    .select("latitude, longitude")
    .eq("vineyard_id", vineyardId)
    .is("deleted_at", null)
    .limit(2000);
  if (Array.isArray(pins) && pins.length > 0) {
    let sumLat = 0, sumLon = 0, count = 0;
    for (const p of pins) {
      const la = coerceNum((p as Record<string, unknown>).latitude);
      const lo = coerceNum((p as Record<string, unknown>).longitude);
      if (la !== null && lo !== null) { sumLat += la; sumLon += lo; count++; }
    }
    if (count > 0) return { lat: sumLat / count, lon: sumLon / count, basis: "pins" };
  }

  return null;
}

// --- Current weather (Davis cache, cache-only) ------------------------------
const WEATHER_CURRENT_COLUMNS =
  "station_id, station_name, observed_at, fetched_at, temperature_c, humidity_pct, " +
  "wind_speed_kmh, wind_gust_kmh, wind_direction_deg, rain_today_mm, rain_rate_mm_per_hr, leaf_wetness";

interface CurrentObsRow {
  station_id: string | null;
  station_name: string | null;
  observed_at: string;
  fetched_at: string;
  temperature_c: number | null;
  humidity_pct: number | null;
  wind_speed_kmh: number | null;
  wind_gust_kmh: number | null;
  wind_direction_deg: number | null;
  rain_today_mm: number | null;
  rain_rate_mm_per_hr: number | null;
  leaf_wetness: number | null;
}

interface CurrentWeatherResult {
  status: "ok" | "no_data" | "not_configured";
  observation: Record<string, unknown> | null;
}

async function loadCurrentWeather(db: SupabaseClient, vineyardId: string): Promise<CurrentWeatherResult> {
  // Configured = an active Davis integration with credentials present.
  // Presence is tested with NOT NULL filters — credential VALUES are never
  // selected into the gateway.
  const { data: integ, error: integErr } = await db.from("vineyard_weather_integrations")
    .select("station_id, station_name")
    .eq("vineyard_id", vineyardId)
    .eq("provider", "davis_weatherlink")
    .eq("is_active", true)
    .not("api_key", "is", null)
    .not("api_secret", "is", null)
    .maybeSingle();
  if (integErr) {
    console.error("[vinetrack-api] weather integration lookup failed:", integErr.message);
    throw new ApiError("internal_error");
  }
  if (!integ) return { status: "not_configured", observation: null };

  const { data: obsRows, error: obsErr } = await db.from("vineyard_weather_observations")
    .select(WEATHER_CURRENT_COLUMNS)
    .eq("vineyard_id", vineyardId)
    .eq("source", "davis_weatherlink")
    .order("observed_at", { ascending: false })
    .limit(1);
  if (obsErr) {
    console.error("[vinetrack-api] weather observation fetch failed:", obsErr.message);
    throw new ApiError("internal_error");
  }
  const row = (obsRows?.[0] ?? null) as unknown as CurrentObsRow | null;
  if (!row) return { status: "no_data", observation: null };

  const integRow = integ as unknown as { station_id: string | null; station_name: string | null };
  const deg = num(row.wind_direction_deg);
  const observedMs = Date.parse(row.observed_at);
  return {
    status: "ok",
    observation: {
      temperature_c: num(row.temperature_c),
      humidity_percent: num(row.humidity_pct),
      wind_speed_kmh: num(row.wind_speed_kmh),
      wind_gust_kmh: num(row.wind_gust_kmh),
      wind_direction_degrees: deg,
      wind_direction: deg !== null ? compassDirection(deg) : null,
      rainfall_today_mm: num(row.rain_today_mm),
      rainfall_rate_mm_per_hour: num(row.rain_rate_mm_per_hr),
      leaf_wetness: num(row.leaf_wetness),
      observed_at: row.observed_at,
      fetched_at: row.fetched_at,
      is_stale: Number.isFinite(observedMs) ? Date.now() - observedMs > CURRENT_WEATHER_STALE_MS : true,
      source: {
        provider: "davis_weatherlink",
        station_id: row.station_id ?? integRow.station_id ?? null,
        station_name: row.station_name ?? integRow.station_name ?? null,
      },
    },
  };
}

// --- Forecast (provider-abstracted, cached) ----------------------------------
interface ForecastDay {
  date: string;
  rain_mm: number | null;
  rain_probability_percent: number | null;
  temp_min_c: number | null;
  temp_max_c: number | null;
  wind_speed_max_kmh: number | null;
  et0_mm: number | null;
}

interface ForecastResult {
  days: ForecastDay[];
  status: "ok" | "stale" | "unavailable" | "not_configured";
  source: Record<string, unknown> | null;
}

/** Hargreaves ET0 estimate — ported 1:1 from the willyweather-proxy. */
function estimateHargreavesET0(tmin: number | null, tmax: number | null): number | null {
  if (tmin === null || tmax === null || tmax <= tmin) return null;
  const tmean = (tmin + tmax) / 2;
  const et0 = 0.0023 * (tmean + 17.8) * Math.sqrt(tmax - tmin) * (15 / 2.45);
  return Math.max(0, Math.round(et0 * 100) / 100);
}

/** Midpoint of a WillyWeather rainfall range entry (proxy-canonical rule). */
// deno-lint-ignore no-explicit-any
function wwRainfallMidpoint(entry: any): number | null {
  const s = coerceNum(entry?.startRange);
  const e = coerceNum(entry?.endRange);
  if (s !== null && e !== null) return (s + e) / 2;
  if (e !== null) return e / 2;
  if (s !== null) return s;
  return null;
}

/**
 * Normalise the WillyWeather combined forecast payload into the
 * VineTrack-normalised external contract. Ported 1:1 from the
 * willyweather-proxy normaliseForecast(). Provider field names never leak.
 */
// deno-lint-ignore no-explicit-any
function normaliseWillyWeatherForecast(raw: any): ForecastDay[] | null {
  const forecasts = raw?.forecasts;
  if (!forecasts || typeof forecasts !== "object") return null;

  interface Bucket { date: string; rain: number | null; prob: number | null; tmin: number | null; tmax: number | null; wind: number | null }
  const byDate: Record<string, Bucket> = {};
  const bucket = (dt: unknown): Bucket => {
    const date = String(dt ?? "").slice(0, 10);
    if (!byDate[date]) byDate[date] = { date, rain: null, prob: null, tmin: null, tmax: null, wind: null };
    return byDate[date];
  };

  const rainDays = forecasts?.rainfall?.days;
  if (Array.isArray(rainDays)) {
    for (const d of rainDays) {
      const b = bucket(d?.dateTime);
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      if (entries.length > 0) b.rain = wwRainfallMidpoint(entries[0]);
    }
  }
  const probDays = forecasts?.rainfallprobability?.days;
  if (Array.isArray(probDays)) {
    for (const d of probDays) {
      const b = bucket(d?.dateTime);
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      if (entries.length > 0) b.prob = coerceNum(entries[0]?.probability);
    }
  }
  const tempDays = forecasts?.temperature?.days;
  if (Array.isArray(tempDays)) {
    for (const d of tempDays) {
      const b = bucket(d?.dateTime);
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      let lo: number | null = null;
      let hi: number | null = null;
      for (const e of entries) {
        const t = coerceNum(e?.temperature);
        if (t === null) continue;
        if (lo === null || t < lo) lo = t;
        if (hi === null || t > hi) hi = t;
      }
      b.tmin = lo;
      b.tmax = hi;
    }
  }
  const windDays = forecasts?.wind?.days;
  if (Array.isArray(windDays)) {
    for (const d of windDays) {
      const b = bucket(d?.dateTime);
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      let maxSpd: number | null = null;
      for (const e of entries) {
        const s = coerceNum(e?.speed);
        if (s === null) continue;
        if (maxSpd === null || s > maxSpd) maxSpd = s;
      }
      b.wind = maxSpd;
    }
  }

  const sorted = Object.values(byDate)
    .filter((b) => DATE_RE.test(b.date))
    .sort((a, b) => a.date.localeCompare(b.date))
    .slice(0, FORECAST_HORIZON_DAYS);
  if (sorted.length === 0) return null;
  return sorted.map((b) => ({
    date: b.date,
    rain_mm: b.rain,
    rain_probability_percent: b.prob,
    temp_min_c: b.tmin,
    temp_max_c: b.tmax,
    wind_speed_max_kmh: b.wind,
    et0_mm: estimateHargreavesET0(b.tmin, b.tmax),
  }));
}

async function fetchWillyWeatherForecast(apiKey: string, locationId: string): Promise<ForecastDay[] | null> {
  const u = new URL(`https://api.willyweather.com.au/v2/${encodeURIComponent(apiKey)}/locations/${encodeURIComponent(locationId)}/weather.json`);
  u.searchParams.set("forecasts", "rainfall,temperature,wind,rainfallprobability");
  u.searchParams.set("days", String(FORECAST_HORIZON_DAYS));
  u.searchParams.set("units", "speed:km/h,temperature:c,distance:km");
  try {
    const res = await fetch(u.toString(), { signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS) });
    if (!res.ok) {
      // Log status only — never the upstream body (may echo the key path).
      console.error("[vinetrack-api] willyweather forecast upstream status:", res.status);
      return null;
    }
    return normaliseWillyWeatherForecast(await res.json());
  } catch (e) {
    console.error("[vinetrack-api] willyweather forecast fetch failed:", e instanceof Error ? e.name : String(e));
    return null;
  }
}

async function fetchOpenMeteoDailyForecast(lat: number, lon: number): Promise<ForecastDay[] | null> {
  const u = new URL("https://api.open-meteo.com/v1/forecast");
  u.searchParams.set("latitude", lat.toFixed(4));
  u.searchParams.set("longitude", lon.toFixed(4));
  u.searchParams.set("daily", "precipitation_sum,temperature_2m_min,temperature_2m_max,wind_speed_10m_max,et0_fao_evapotranspiration");
  u.searchParams.set("forecast_days", String(FORECAST_HORIZON_DAYS));
  u.searchParams.set("timezone", "auto");
  try {
    const res = await fetch(u.toString(), { signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS) });
    if (!res.ok) {
      console.error("[vinetrack-api] open-meteo daily upstream status:", res.status);
      return null;
    }
    // deno-lint-ignore no-explicit-any
    const data: any = await res.json();
    const daily = data?.daily;
    const time: unknown[] = Array.isArray(daily?.time) ? daily.time : [];
    if (time.length === 0) return null;
    const pick = (name: string, i: number): number | null => {
      const arr = daily?.[name];
      return Array.isArray(arr) ? coerceNum(arr[i]) : null;
    };
    return time.slice(0, FORECAST_HORIZON_DAYS).map((t, i) => ({
      date: String(t).slice(0, 10),
      rain_mm: pick("precipitation_sum", i),
      rain_probability_percent: null,
      temp_min_c: pick("temperature_2m_min", i),
      temp_max_c: pick("temperature_2m_max", i),
      wind_speed_max_kmh: pick("wind_speed_10m_max", i),
      et0_mm: pick("et0_fao_evapotranspiration", i),
    }));
  } catch (e) {
    console.error("[vinetrack-api] open-meteo daily fetch failed:", e instanceof Error ? e.name : String(e));
    return null;
  }
}

function forecastFromPayload(
  payload: Record<string, unknown>,
  fetchedAt: string,
  isStale: boolean,
  status: ForecastResult["status"],
): ForecastResult {
  const days = Array.isArray(payload.days) ? (payload.days as ForecastDay[]) : [];
  return {
    days,
    status,
    source: {
      provider: payload.provider ?? null,
      location: payload.location ?? null,
      horizon_days: payload.horizon_days ?? FORECAST_HORIZON_DAYS,
      fetched_at: fetchedAt,
      is_stale: isStale,
    },
  };
}

async function loadForecast(db: SupabaseClient, vineyardId: string): Promise<ForecastResult> {
  // Canonical per-vineyard provider preference (sql/061).
  const { data: vy, error: vyErr } = await db.from("vineyards")
    .select("forecast_provider")
    .eq("id", vineyardId)
    .maybeSingle();
  if (vyErr) console.error("[vinetrack-api] forecast provider lookup failed:", vyErr.message);
  const pref = String((vy as Record<string, unknown> | null)?.forecast_provider ?? "auto");

  const { data: ww } = await db.from("vineyard_weather_integrations")
    .select("station_id, station_name, station_latitude, station_longitude")
    .eq("vineyard_id", vineyardId)
    .eq("provider", "willyweather")
    .eq("is_active", true)
    .maybeSingle();
  const wwRow = ww as unknown as { station_id: string | null; station_name: string | null; station_latitude: number | null; station_longitude: number | null } | null;
  const wwLocationId = wwRow?.station_id ? String(wwRow.station_id) : null;

  const provider = pref === "willyweather" ? "willyweather"
    : pref === "open_meteo" ? "open_meteo"
    : (wwLocationId ? "willyweather" : "open_meteo");

  // Serve from cache while fresh (cache is invalidated by provider switch).
  const cached = await readEnvCache(db, vineyardId, "forecast");
  const providerCache = cached && String(cached.payload?.provider ?? "") === provider ? cached : null;
  if (providerCache && Date.now() - Date.parse(providerCache.fetched_at) < FORECAST_CACHE_TTL_MS) {
    return forecastFromPayload(providerCache.payload, providerCache.fetched_at, false, "ok");
  }

  // Refresh upstream (at most once per vineyard per TTL window).
  let fresh: { days: ForecastDay[]; location: Record<string, unknown> } | null = null;
  if (provider === "willyweather") {
    const apiKey = Deno.env.get("WILLYWEATHER_API_KEY") ?? "";
    if (!apiKey || !wwLocationId) return { days: [], status: "not_configured", source: null };
    const days = await fetchWillyWeatherForecast(apiKey, wwLocationId);
    if (days) {
      fresh = {
        days,
        location: {
          latitude: wwRow?.station_latitude != null ? round2(Number(wwRow.station_latitude)) : null,
          longitude: wwRow?.station_longitude != null ? round2(Number(wwRow.station_longitude)) : null,
          label: wwRow?.station_name ?? null,
          basis: "forecast_location",
        },
      };
    }
  } else {
    const coords = await resolveVineyardCoords(db, vineyardId);
    if (!coords) return { days: [], status: "not_configured", source: null };
    const days = await fetchOpenMeteoDailyForecast(coords.lat, coords.lon);
    if (days) {
      fresh = {
        days,
        location: { latitude: round2(coords.lat), longitude: round2(coords.lon), label: null, basis: coords.basis },
      };
    }
  }

  if (fresh) {
    const payload: Record<string, unknown> = {
      provider,
      horizon_days: FORECAST_HORIZON_DAYS,
      location: fresh.location,
      days: fresh.days,
    };
    await writeEnvCache(db, vineyardId, "forecast", payload);
    return forecastFromPayload(payload, new Date().toISOString(), false, "ok");
  }

  // Upstream failed — marked stale fallback if a same-provider bundle exists.
  if (providerCache) {
    return forecastFromPayload(providerCache.payload, providerCache.fetched_at, true, "stale");
  }
  return { days: [], status: "unavailable", source: null };
}

// --- Disease risk models (ported 1:1 from the shared iOS/Android MVP) --------
interface EnvHour {
  epochMs: number;
  temperatureC: number;
  dewPointC: number | null;
  humidityPercent: number | null;
  precipitationMm: number;
}

interface HourlyBundle {
  hours: EnvHour[];
  utcOffsetSeconds: number;
}

/** Canonical estimated-wetness proxy: rain > 0 OR RH >= 90% OR T - dewpoint <= 2°C. */
function isWetHour(h: EnvHour): boolean {
  if (h.precipitationMm > 0) return true;
  if (h.humidityPercent !== null && h.humidityPercent >= 90) return true;
  if (h.dewPointC !== null && (h.temperatureC - h.dewPointC) <= 2) return true;
  return false;
}

async function fetchOpenMeteoHourly(lat: number, lon: number): Promise<HourlyBundle | null> {
  const u = new URL("https://api.open-meteo.com/v1/forecast");
  u.searchParams.set("latitude", lat.toFixed(4));
  u.searchParams.set("longitude", lon.toFixed(4));
  u.searchParams.set("hourly", "temperature_2m,dew_point_2m,relative_humidity_2m,precipitation");
  u.searchParams.set("past_days", "3");
  u.searchParams.set("forecast_days", "1");
  u.searchParams.set("timezone", "auto");
  try {
    const res = await fetch(u.toString(), { signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS) });
    if (!res.ok) {
      console.error("[vinetrack-api] open-meteo hourly upstream status:", res.status);
      return null;
    }
    // deno-lint-ignore no-explicit-any
    const data: any = await res.json();
    const offset = coerceNum(data?.utc_offset_seconds) ?? 0;
    const hourly = data?.hourly;
    const time: unknown[] = Array.isArray(hourly?.time) ? hourly.time : [];
    if (time.length === 0) return null;
    const arr = (name: string): unknown[] => (Array.isArray(hourly?.[name]) ? hourly[name] : []);
    const temps = arr("temperature_2m");
    const dews = arr("dew_point_2m");
    const rhs = arr("relative_humidity_2m");
    const precs = arr("precipitation");
    const hours: EnvHour[] = [];
    for (let i = 0; i < time.length; i++) {
      const t = coerceNum(temps[i]);
      if (t === null) continue;
      // Open-Meteo returns local times without a zone suffix; convert using
      // the response's own UTC offset.
      const asIfUtc = Date.parse(String(time[i]) + "Z");
      if (Number.isNaN(asIfUtc)) continue;
      hours.push({
        epochMs: asIfUtc - offset * 1000,
        temperatureC: t,
        dewPointC: coerceNum(dews[i]),
        humidityPercent: coerceNum(rhs[i]),
        precipitationMm: coerceNum(precs[i]) ?? 0,
      });
    }
    if (hours.length === 0) return null;
    hours.sort((a, b) => a.epochMs - b.epochMs);
    return { hours, utcOffsetSeconds: offset };
  } catch (e) {
    console.error("[vinetrack-api] open-meteo hourly fetch failed:", e instanceof Error ? e.name : String(e));
    return null;
  }
}

interface DiseaseRiskItem {
  disease: string;
  risk_level: "low" | "medium" | "high";
  summary: string;
  window_hours: number;
  inputs: Record<string, number | null>;
}

const HOUR_MS = 3_600_000;

/** Downy mildew — simplified 10:10:24 rule (48 h window). */
function assessDownyMildew(hours: EnvHour[], nowMs: number): DiseaseRiskItem {
  const window = hours.filter((h) => h.epochMs >= nowMs - 48 * HOUR_MS && h.epochMs <= nowMs);
  if (window.length === 0) {
    return { disease: "downy_mildew", risk_level: "low", summary: "Insufficient hourly data to assess.", window_hours: 48, inputs: {} };
  }
  const rain = window.reduce((s, h) => s + h.precipitationMm, 0);
  const minTemp = Math.min(...window.map((h) => h.temperatureC));
  const wetHours = window.filter(isWetHour).length;
  let level: DiseaseRiskItem["risk_level"] = "low";
  if (rain >= 10 && minTemp >= 10 && wetHours >= 10) {
    level = rain >= 20 && wetHours >= 18 ? "high" : "medium";
  }
  return {
    disease: "downy_mildew",
    risk_level: level,
    summary: `Past 48h: ${round1(rain).toFixed(1)} mm rain, min ${round1(minTemp).toFixed(1)}°C, ${wetHours} estimated wet hours.`,
    window_hours: 48,
    inputs: { rainfall_mm: round1(rain), min_temperature_c: round1(minTemp), wet_hours: wetHours },
  };
}

/** Powdery mildew — simplified Gubler-Thomas (72 h window, local days). */
function assessPowderyMildew(hours: EnvHour[], nowMs: number, localDay: (ms: number) => string): DiseaseRiskItem {
  const window = hours.filter((h) => h.epochMs >= nowMs - 72 * HOUR_MS && h.epochMs <= nowMs);
  if (window.length === 0) {
    return { disease: "powdery_mildew", risk_level: "low", summary: "Insufficient hourly data to assess.", window_hours: 72, inputs: {} };
  }
  const byDay = new Map<string, EnvHour[]>();
  for (const h of window) {
    const key = localDay(h.epochMs);
    const list = byDay.get(key) ?? [];
    list.push(h);
    byDay.set(key, list);
  }
  let favourableDays = 0;
  for (const dayHours of byDay.values()) {
    const sorted = [...dayHours].sort((a, b) => a.epochMs - b.epochMs);
    let run = 0;
    let maxRun = 0;
    for (const h of sorted) {
      const humidOK = (h.humidityPercent ?? 0) >= 60;
      const tempOK = h.temperatureC >= 21 && h.temperatureC <= 30;
      if (humidOK && tempOK) {
        run += 1;
        maxRun = Math.max(maxRun, run);
      } else {
        run = 0;
      }
    }
    if (maxRun >= 6) favourableDays += 1;
  }
  const latestTemp = window[window.length - 1].temperatureC;
  let level: DiseaseRiskItem["risk_level"] = "low";
  if (favourableDays >= 3) level = "medium";
  if (favourableDays >= 3 && latestTemp >= 25) level = "high";
  return {
    disease: "powdery_mildew",
    risk_level: level,
    summary: `${favourableDays} of last 3 days had 6+ favourable hours (21–30°C, RH ≥ 60%).`,
    window_hours: 72,
    inputs: { favourable_days_of_last_3: favourableDays, latest_temperature_c: round1(latestTemp) },
  };
}

/** Botrytis — simplified Broome/Bulit (wet hours at 15–25°C over 36 h). */
function assessBotrytis(hours: EnvHour[], nowMs: number): DiseaseRiskItem {
  const window = hours.filter((h) => h.epochMs >= nowMs - 36 * HOUR_MS && h.epochMs <= nowMs);
  if (window.length === 0) {
    return { disease: "botrytis", risk_level: "low", summary: "Insufficient hourly data to assess.", window_hours: 36, inputs: {} };
  }
  const wetCount = window.filter((h) => isWetHour(h) && h.temperatureC >= 15 && h.temperatureC <= 25).length;
  let level: DiseaseRiskItem["risk_level"] = "low";
  if (wetCount >= 15) level = "medium";
  if (wetCount >= 24) level = "high";
  return {
    disease: "botrytis",
    risk_level: level,
    summary: `${wetCount} estimated wet hours in 15–25°C window over past 36h.`,
    window_hours: 36,
    inputs: { wet_hours_15_to_25_c: wetCount },
  };
}

function buildDiseaseRiskPayload(vineyardId: string, bundle: HourlyBundle, coords: VineyardCoords): Record<string, unknown> {
  const nowMs = Date.now();
  const nowIso = new Date(nowMs).toISOString();
  const localDay = (ms: number) => new Date(ms + bundle.utcOffsetSeconds * 1000).toISOString().slice(0, 10);
  const past = bundle.hours.filter((h) => h.epochMs <= nowMs);
  const observedThrough = past.length > 0 ? new Date(past[past.length - 1].epochMs).toISOString() : null;
  return {
    vineyard_id: vineyardId,
    calculated_at: nowIso,
    model_version: DISEASE_MODEL_VERSION,
    wetness_source: "estimated_proxy",
    weather_source: {
      provider: "open_meteo",
      location: { latitude: round2(coords.lat), longitude: round2(coords.lon), basis: coords.basis },
      fetched_at: nowIso,
      observed_through: observedThrough,
      hours_used: bundle.hours.length,
      source_status: "ok",
    },
    risks: [
      assessDownyMildew(bundle.hours, nowMs),
      assessPowderyMildew(bundle.hours, nowMs, localDay),
      assessBotrytis(bundle.hours, nowMs),
    ],
  };
}

// --- Stage 3D route handlers -------------------------------------------------
async function handleWeather(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  enforceAllowedParams(url, ["vineyard_id"]);
  const vineyardId = url.searchParams.get("vineyard_id");
  if (!vineyardId || !UUID_RE.test(vineyardId)) throw new ApiError("invalid_request");
  ctx.vineyardId = vineyardId;

  await validateVineyardRequest(db, key, "weather:read", vineyardId, false);

  const [current, forecast] = await Promise.all([
    loadCurrentWeather(db, vineyardId),
    loadForecast(db, vineyardId),
  ]);

  return jsonResponse(req, ctx, {
    data: {
      vineyard_id: vineyardId,
      current: current.observation,
      current_status: current.status,
      forecast: forecast.days,
      forecast_status: forecast.status,
      forecast_source: forecast.source,
    },
    meta: { generated_at: new Date().toISOString() },
  }, 200);
}

interface RainfallRpcRow {
  date: string;
  rainfall_mm: number | string;
  source: string;
  station_id: string | null;
  station_name: string | null;
  notes: string | null;
  updated_at: string;
}

async function handleRainfallList(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  enforceAllowedParams(url, ["vineyard_id", "from", "to", "limit", "cursor"]);
  const vineyardId = url.searchParams.get("vineyard_id");
  if (!vineyardId || !UUID_RE.test(vineyardId)) throw new ApiError("invalid_request");
  ctx.vineyardId = vineyardId;

  const limit = parseLimit(url.searchParams.get("limit"));
  const fromDate = parseDateParam(url.searchParams.get("from"));
  const toDate = parseDateParam(url.searchParams.get("to"));
  if (fromDate && toDate && fromDate > toDate) throw new ApiError("invalid_request");
  const rawCursor = url.searchParams.get("cursor");
  const before = rawCursor ? decodeDateCursor(rawCursor) : null;

  await validateVineyardRequest(db, key, "rainfall:read", vineyardId, false);

  const { data, error } = await db.rpc("integration_get_rainfall", {
    p_vineyard_id: vineyardId,
    p_from: fromDate,
    p_to: toDate,
    p_before: before,
    p_limit: limit + 1,
  });
  if (error) {
    console.error("[vinetrack-api] rainfall rpc failed:", error.message);
    throw new ApiError("internal_error");
  }
  const rows = (Array.isArray(data) ? data : []) as RainfallRpcRow[];
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);

  return jsonResponse(req, ctx, {
    data: page.map((r) => ({
      date: String(r.date).slice(0, 10),
      rainfall_mm: coerceNum(r.rainfall_mm),
      source: r.source,
      station: r.station_id || r.station_name
        ? { id: r.station_id ?? null, name: r.station_name ?? null }
        : null,
      notes: r.notes && String(r.notes).trim().length > 0 ? r.notes : null,
      updated_at: r.updated_at,
    })),
    pagination: {
      next_cursor: hasMore ? encodeDateCursor(String(page[page.length - 1].date).slice(0, 10)) : null,
    },
  }, 200);
}

async function handleDiseaseRisk(
  req: Request, ctx: RequestContext, db: SupabaseClient, key: string, url: URL,
): Promise<Response> {
  enforceAllowedParams(url, ["vineyard_id"]);
  const vineyardId = url.searchParams.get("vineyard_id");
  if (!vineyardId || !UUID_RE.test(vineyardId)) throw new ApiError("invalid_request");
  ctx.vineyardId = vineyardId;

  await validateVineyardRequest(db, key, "disease_risk:read", vineyardId, false);

  const cached = await readEnvCache(db, vineyardId, "disease_risk");
  const nowMs = Date.now();
  if (cached && nowMs - Date.parse(cached.fetched_at) < DISEASE_CACHE_TTL_MS) {
    return jsonResponse(req, ctx, {
      data: cached.payload,
      meta: { generated_at: new Date().toISOString(), source_updated_at: cached.fetched_at, is_stale: false },
    }, 200);
  }

  const coords = await resolveVineyardCoords(db, vineyardId);
  const bundle = coords ? await fetchOpenMeteoHourly(coords.lat, coords.lon) : null;

  if (!coords || !bundle || bundle.hours.length === 0) {
    // Marked stale fallback (existing app behaviour: keep serving the last
    // good assessment rather than failing hard) — capped at 24 h.
    if (cached && nowMs - Date.parse(cached.fetched_at) < DISEASE_STALE_FALLBACK_MAX_MS) {
      const payload = { ...cached.payload };
      payload.weather_source = {
        ...((payload.weather_source as Record<string, unknown>) ?? {}),
        source_status: "stale_fallback",
      };
      return jsonResponse(req, ctx, {
        data: payload,
        meta: { generated_at: new Date().toISOString(), source_updated_at: cached.fetched_at, is_stale: true },
      }, 200);
    }
    throw new ApiError("disease_risk_unavailable");
  }

  const payload = buildDiseaseRiskPayload(vineyardId, bundle, coords);
  await writeEnvCache(db, vineyardId, "disease_risk", payload);
  return jsonResponse(req, ctx, {
    data: payload,
    meta: { generated_at: new Date().toISOString(), source_updated_at: String(payload.calculated_at), is_stale: false },
  }, 200);
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
// Stage 8 — write routes (POST create / PATCH partial update). The gateway
// performs transport-level checks only; ALL validation, idempotency,
// provenance, audit and event behaviour lives in the sql/186 SECURITY
// DEFINER RPCs, which re-run the full five-check auth validation internally.
// ---------------------------------------------------------------------------
const MAX_WRITE_BODY_BYTES = 262_144; // 256 KB

interface WriteSpec {
  createRpc?: string;
  updateRpc?: string;
  updateIdParam?: string;
  idLabel: string;
}

const WRITE_RESOURCES: Record<string, WriteSpec> = {
  "work-tasks": {
    createRpc: "integration_api_create_work_task",
    updateRpc: "integration_api_update_work_task",
    updateIdParam: "p_work_task_id",
    idLabel: "work_task_id",
  },
  "fuel-records": {
    createRpc: "integration_api_create_fuel_record",
    updateRpc: "integration_api_update_fuel_record",
    updateIdParam: "p_fuel_record_id",
    idLabel: "fuel_record_id",
  },
  // Create-only: irrigation corrections are an in-app reverse/re-record
  // workflow; growth stages are insert-only by design (sql/055 + 178).
  "irrigation-records": {
    createRpc: "integration_api_create_irrigation_record",
    idLabel: "irrigation_record_id",
  },
  "growth-stages": {
    createRpc: "integration_api_create_growth_stage",
    idLabel: "growth_stage_id",
  },
  "yield-records": {
    createRpc: "integration_api_create_yield_record",
    updateRpc: "integration_api_update_yield_record",
    updateIdParam: "p_yield_record_id",
    idLabel: "yield_record_id",
  },
};

async function readJsonBody(req: Request): Promise<Record<string, unknown>> {
  const raw = await req.text();
  if (raw.length === 0 || raw.length > MAX_WRITE_BODY_BYTES) throw new ApiError("invalid_request");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ApiError("invalid_request");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new ApiError("invalid_request");
  }
  return parsed as Record<string, unknown>;
}

/** RPC envelope failure codes -> public error codes. Unknown codes never leak. */
const WRITE_ERROR_PASSTHROUGH = [
  "integration_not_active", "insufficient_scope", "vineyard_access_denied",
  "resource_not_found", "invalid_request", "validation_failed",
  "idempotency_required", "idempotency_conflict", "conflict",
];

function mapWriteFailure(code: string | undefined): string {
  if (code && WRITE_ERROR_PASSTHROUGH.includes(code)) return code;
  return mapAuthFailure(code);
}

interface WriteEnvelope {
  ok: boolean;
  status?: number;
  replayed?: boolean;
  data?: Record<string, unknown>;
  error?: string;
  details?: unknown;
}

async function handleWriteRequest(
  req: Request, ctx: RequestContext, db: SupabaseClient, url: URL, segments: string[],
): Promise<Response> {
  const def = segments[0] === "v1" && segments.length >= 2 ? WRITE_RESOURCES[segments[1]] : undefined;
  const isCreate = ctx.method === "POST" && segments.length === 2;
  const isUpdate = ctx.method === "PATCH" && segments.length === 3;

  if (!def || (!isCreate && !isUpdate) || (isCreate && !def.createRpc) || (isUpdate && !def.updateRpc)) {
    ctx.canonicalPath = "/" + segments.join("/");
    // A known resource path with an unsupported method is 405; an unknown
    // path stays 404.
    const knownShape = segments[0] === "v1" && segments.length >= 2 && segments.length <= 3 &&
      (RESOURCE_ROUTES[segments[1]] !== undefined ||
        ["me", "weather", "rainfall", "disease-risk"].includes(segments[1]));
    throw new ApiError(knownShape ? "method_not_allowed" : "resource_not_found");
  }
  ctx.canonicalPath = isCreate ? `/v1/${segments[1]}` : `/v1/${segments[1]}/{${def.idLabel}}`;

  enforceAllowedParams(url, []);

  const key = extractApiKey(req, url);
  const profile = await authenticate(db, key);
  if (!profile.valid) throw new ApiError(mapAuthFailure(profile.failure_code));
  ctx.integrationClientId = profile.integration_client_id ?? null;
  ctx.apiKeyId = profile.api_key_id ?? null;
  await checkRateLimit(db, ctx, profile.api_key_id!);

  const body = await readJsonBody(req);

  let rpc: string;
  let args: Record<string, unknown>;
  if (isCreate) {
    // Vineyard context arrives in the body and is stripped before the
    // resource payload reaches the validator; the RPC folds it back into the
    // idempotency fingerprint.
    const vineyardId = body.vineyard_id;
    if (typeof vineyardId !== "string" || !UUID_RE.test(vineyardId)) {
      throw new ApiError("validation_failed", [{ field: "vineyard_id", issue: "required vineyard UUID" }]);
    }
    ctx.vineyardId = vineyardId;
    const payload: Record<string, unknown> = { ...body };
    delete payload.vineyard_id;
    rpc = def.createRpc!;
    args = {
      p_presented_key: key,
      p_vineyard_id: vineyardId,
      p_idempotency_key: req.headers.get("idempotency-key"),
      p_payload: payload,
    };
  } else {
    const id = segments[2];
    if (!UUID_RE.test(id)) throw new ApiError("resource_not_found");
    rpc = def.updateRpc!;
    args = { p_presented_key: key, [def.updateIdParam!]: id, p_payload: body };
  }

  const { data, error } = await db.rpc(rpc, args);
  if (error) {
    console.error(`[vinetrack-api] ${rpc} rpc failed:`, error.message);
    throw new ApiError("internal_error");
  }
  const env = data as WriteEnvelope;
  if (!env?.ok) {
    throw new ApiError(mapWriteFailure(env?.error), env?.details);
  }
  const resource = env.data ?? {};
  const resourceVineyard = (resource as Record<string, unknown>).vineyard_id;
  if (typeof resourceVineyard === "string") ctx.vineyardId = resourceVineyard;
  const status = env.status ?? (isCreate ? 201 : 200);
  const headers: Record<string, string> = env.replayed ? { "Idempotency-Replayed": "true" } : {};
  return jsonResponse(req, ctx, { data: resource }, status, headers);
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
  | { name: "equipment_get"; id: string }
  | { name: "work_tasks_list" }
  | { name: "work_task_get"; id: string }
  | { name: "pruning_list" }
  | { name: "pruning_get"; id: string }
  | { name: "irrigation_list" }
  | { name: "irrigation_get"; id: string }
  | { name: "growth_stages_list" }
  | { name: "growth_stage_get"; id: string }
  | { name: "yield_records_list" }
  | { name: "yield_record_get"; id: string }
  | { name: "pins_list" }
  | { name: "pin_get"; id: string }
  | { name: "weather" }
  | { name: "rainfall_list" }
  | { name: "disease_risk" };

/** Collection + single-resource route table: segment -> route names + log templates. */
const RESOURCE_ROUTES: Record<string, { list: Route["name"]; get: Route["name"]; idLabel: string }> = {
  "vineyards": { list: "vineyards_list", get: "vineyard_get", idLabel: "vineyard_id" },
  "blocks": { list: "blocks_list", get: "block_get", idLabel: "block_id" },
  "trips": { list: "trips_list", get: "trip_get", idLabel: "trip_id" },
  "spray-jobs": { list: "sprays_list", get: "spray_get", idLabel: "spray_job_id" },
  "fuel-records": { list: "fuel_records_list", get: "fuel_record_get", idLabel: "fuel_record_id" },
  "fuel-purchases": { list: "fuel_purchases_list", get: "fuel_purchase_get", idLabel: "fuel_purchase_id" },
  "equipment": { list: "equipment_list", get: "equipment_get", idLabel: "equipment_id" },
  "work-tasks": { list: "work_tasks_list", get: "work_task_get", idLabel: "work_task_id" },
  "pruning": { list: "pruning_list", get: "pruning_get", idLabel: "pruning_activity_id" },
  "irrigation-records": { list: "irrigation_list", get: "irrigation_get", idLabel: "irrigation_record_id" },
  "growth-stages": { list: "growth_stages_list", get: "growth_stage_get", idLabel: "growth_stage_id" },
  "yield-records": { list: "yield_records_list", get: "yield_record_get", idLabel: "yield_record_id" },
  "pins": { list: "pins_list", get: "pin_get", idLabel: "pin_id" },
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
    if (!["GET", "POST", "PATCH"].includes(ctx.method)) {
      ctx.canonicalPath = "/" + segments.join("/");
      throw new ApiError("method_not_allowed");
    }

    if (ctx.method !== "GET") {
      // Stage 8 write routes. Success is logged here; failures fall through
      // to the shared error handler + log below.
      response = await handleWriteRequest(req, ctx, db, url, segments);
      status = response.status;
      await logRequest(db, ctx, status, null);
      return response;
    }

    // Resolve the canonical route template first (also used for logging —
    // templates never contain arbitrary ids, keeping log paths low-cardinality).
    let route: Route | null = null;
    if (segments[0] === "v1") {
      if (segments.length === 2 && segments[1] === "me") {
        route = { name: "me" };
        ctx.canonicalPath = "/v1/me";
      } else if (segments.length === 2 && segments[1] === "weather") {
        // Singleton environmental resources (Stage 3D) — no {id} form.
        route = { name: "weather" };
        ctx.canonicalPath = "/v1/weather";
      } else if (segments.length === 2 && segments[1] === "rainfall") {
        route = { name: "rainfall_list" };
        ctx.canonicalPath = "/v1/rainfall";
      } else if (segments.length === 2 && segments[1] === "disease-risk") {
        route = { name: "disease_risk" };
        ctx.canonicalPath = "/v1/disease-risk";
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
      case "work_tasks_list":
        response = await handleWorkTaskList(req, ctx, db, key, profile, url);
        break;
      case "work_task_get":
        response = await handleWorkTaskGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "pruning_list":
        response = await handlePruningList(req, ctx, db, key, profile, url);
        break;
      case "pruning_get":
        response = await handlePruningGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "irrigation_list":
        response = await handleIrrigationList(req, ctx, db, key, url);
        break;
      case "irrigation_get":
        response = await handleIrrigationGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "growth_stages_list":
        response = await handleGrowthStageList(req, ctx, db, key, profile, url);
        break;
      case "growth_stage_get":
        response = await handleGrowthStageGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "yield_records_list":
        response = await handleYieldRecordList(req, ctx, db, key, url);
        break;
      case "yield_record_get":
        response = await handleYieldRecordGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "pins_list":
        response = await handlePinList(req, ctx, db, key, profile, url);
        break;
      case "pin_get":
        response = await handlePinGet(req, ctx, db, key, profile, url, (route as { id: string }).id);
        break;
      case "weather":
        response = await handleWeather(req, ctx, db, key, url);
        break;
      case "rainfall_list":
        response = await handleRainfallList(req, ctx, db, key, url);
        break;
      case "disease_risk":
        response = await handleDiseaseRisk(req, ctx, db, key, url);
        break;
    }
    status = response.status;
  } catch (e) {
    let errorDetails: unknown = undefined;
    if (e instanceof ApiError) {
      errorCode = e.code;
      errorDetails = e.details;
    } else {
      // Never leak Postgres/PostgREST/internal details externally.
      console.error("[vinetrack-api] unexpected error:", e instanceof Error ? (e.stack ?? e.message) : String(e));
      errorCode = "internal_error";
    }
    response = errorResponse(req, ctx, errorCode, {}, errorDetails);
    status = response.status;
  }

  await logRequest(db, ctx, status, errorCode);
  return response;
});
