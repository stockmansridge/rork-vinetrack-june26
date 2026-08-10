// Supabase Edge Function: vinetrack-api
//
// VineTrack public read-only API gateway — Stage 3A.
//
// Routes (versioned; the route version is authoritative):
//   GET /v1/me
//   GET /v1/vineyards
//   GET /v1/vineyards/{vineyard_id}
//   GET /v1/blocks?vineyard_id=<uuid>
//   GET /v1/blocks/{block_id}
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
  /** Canonical route template for logging, e.g. /v1/blocks/{block_id} */
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
  return jsonResponse(req, ctx, {
    error: { code, message: def.message, request_id: ctx.requestId },
  }, def.status, extraHeaders);
}

// ---------------------------------------------------------------------------
// Pagination — opaque keyset cursor over (created_at, id). Deterministic:
// order by created_at asc, id asc; no duplicates or gaps while iterating.
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
// NOT exposed in Stage 3A — exposing geometry is a future explicit decision.
const BLOCK_COLUMNS =
  "id, vineyard_id, name, planting_year, row_width, vine_spacing, rows, variety_allocations, created_at, updated_at";

// ---------------------------------------------------------------------------
// Keyset-paginated list query helper.
// ---------------------------------------------------------------------------
async function pagedList<T extends { created_at: string; id: string }>(
  db: SupabaseClient,
  table: string,
  columns: string,
  limit: number,
  cursor: Cursor | null,
  applyFilters: (q: ReturnType<SupabaseClient["from"]>["select"] extends never ? never : any) => any,
): Promise<{ rows: T[]; nextCursor: string | null }> {
  let query = db.from(table).select(columns)
    .is("deleted_at", null)
    .order("created_at", { ascending: true })
    .order("id", { ascending: true })
    .limit(limit + 1);
  query = applyFilters(query);
  if (cursor) {
    query = query.or(
      `created_at.gt.${cursor.t},and(created_at.eq.${cursor.t},id.gt.${cursor.id})`,
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

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------
async function handleMe(req: Request, ctx: RequestContext, profile: AuthProfile): Promise<Response> {
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
    db, "vineyards", VINEYARD_COLUMNS, limit, cursor,
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

  // Stage 3A rule: vineyard_id is REQUIRED — vineyard isolation is explicit.
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
    db, "paddocks", BLOCK_COLUMNS, limit, cursor,
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

  // 1. resolve the block -> 2. resolve its vineyard.
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

  // 3. canonical five-check validation for the block's vineyard.
  //    Ungranted vineyard -> resource_not_found (no cross-vineyard probing).
  await validateVineyardRequest(db, key, "blocks:read", block.vineyard_id, true);

  return jsonResponse(req, ctx, { data: mapBlock(block) }, 200);
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
  const segments = path.split("/").filter(Boolean); // e.g. ["v1", "blocks", "<id>"]

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

    // Resolve the canonical route template first (also used for logging).
    let route:
      | { name: "me" }
      | { name: "vineyards_list" }
      | { name: "vineyard_get"; id: string }
      | { name: "blocks_list" }
      | { name: "block_get"; id: string }
      | null = null;

    if (segments[0] === "v1") {
      if (segments.length === 2 && segments[1] === "me") {
        route = { name: "me" }; ctx.canonicalPath = "/v1/me";
      } else if (segments.length === 2 && segments[1] === "vineyards") {
        route = { name: "vineyards_list" }; ctx.canonicalPath = "/v1/vineyards";
      } else if (segments.length === 3 && segments[1] === "vineyards") {
        route = { name: "vineyard_get", id: segments[2] }; ctx.canonicalPath = "/v1/vineyards/{vineyard_id}";
      } else if (segments.length === 2 && segments[1] === "blocks") {
        route = { name: "blocks_list" }; ctx.canonicalPath = "/v1/blocks";
      } else if (segments.length === 3 && segments[1] === "blocks") {
        route = { name: "block_get", id: segments[2] }; ctx.canonicalPath = "/v1/blocks/{block_id}";
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
        response = await handleMe(req, ctx, profile);
        break;
      case "vineyards_list":
        response = await handleVineyardList(req, ctx, db, profile, url);
        break;
      case "vineyard_get":
        response = await handleVineyardGet(req, ctx, db, key, url, route.id);
        break;
      case "blocks_list":
        response = await handleBlockList(req, ctx, db, key, url);
        break;
      case "block_get":
        response = await handleBlockGet(req, ctx, db, key, profile, url, route.id);
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
