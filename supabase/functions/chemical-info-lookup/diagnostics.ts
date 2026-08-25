// Production lookup diagnostics (task §14).
//
// # Why this exists
//
// "Portal resolves Hortitrol winter oil to APVMA 50067, iOS resolves it to
// 33182" is not a reproducible bug report — it is two observations that cannot
// be compared, because nothing in either request records WHICH server build
// answered, WHICH candidates came back, in WHAT order, or whether the answer
// came from a cache. Without that, every parity claim is anecdote.
//
// This module makes one lookup self-describing. Every search and structured
// response carries a `diagnostics` envelope, and the same envelope is emitted
// as a single structured log line so a request can be found server-side by id
// after the fact.
//
// # What it must never become
//
// Diagnostics are OBSERVATION ONLY. Nothing here may influence ranking,
// selection, extraction or verification: a diagnostic that changes the answer
// stops being a diagnostic and becomes an untested code path in the resolver.
// The envelope is built from values the pipeline has ALREADY decided.
//
// # Secrets
//
// The envelope is returned to the client and written to logs. It therefore
// carries no API keys, no JWTs, no service-role material and no user identity.
// The Supabase project is identified by its PROJECT REF only — the public
// subdomain already present in every client's base URL.

/**
 * Which client asked. Free text from the request is normalised onto this
 * closed set so log queries can group by platform without string-matching
 * whatever a future client happens to send.
 */
export type LookupClientPlatform = "ios" | "android" | "portal" | "unknown";

/** How the served answer was actually produced. */
export type LookupMethod =
  /** Served whole from an approved Master Catalogue row. */
  | "master_catalogue"
  /** The jurisdiction's official register answered. */
  | "official_register"
  /** Register candidates plus web research. */
  | "official_register_and_research"
  /** Web research only — the register returned nothing. */
  | "research"
  /** Legacy chat-completions fallback. */
  | "ai_legacy"
  /** Nothing resolved. */
  | "unresolved";

/** Whether the answer came from a cache, and which one. */
export type LookupCacheState = "hit" | "miss" | "bypass" | "none";

export interface LookupClientContext {
  platform: LookupClientPlatform;
  /** Marketing version, e.g. "2.14.0". Absent when the client did not say. */
  appVersion: string | null;
  /** Build/bundle number, e.g. "1487". */
  appBuild: string | null;
  /** Client-supplied correlation id, echoed so a client log line and a server
   *  log line can be joined. Never trusted as the request id. */
  correlationId: string | null;
}

export interface CandidateDiagnostic {
  /** Registration number as the register states it, or null for a row that
   *  carries no registration identity (AI suggestions). */
  registrationNumber: string | null;
  name: string;
  /** "master" | "official_register" | "research" | "ai" */
  source: string;
  /** Server ranking score, when ranking ran. */
  score: number | null;
  /** Why the ranker placed it here, in words. */
  reason: string | null;
}

export interface LookupDiagnostics {
  request_id: string;
  correlation_id: string | null;
  client: {
    platform: LookupClientPlatform;
    app_version: string | null;
    app_build: string | null;
  };
  server: {
    /** Deployed function version — the git SHA baked in at deploy time. */
    lookup_version: string;
    /** Supabase project ref (public subdomain), never the URL or any key. */
    project_ref: string;
  };
  action: string;
  country: {
    requested: string;
    resolved_code: string | null;
  };
  /** The query EXACTLY as received, so a leading space or a smart quote that
   *  changed the register's answer is visible rather than inferred. */
  query: string;
  /** Candidate registration numbers IN SERVED ORDER. The single most
   *  important field for parity: two clients showing different products is
   *  provable here in one comparison. */
  candidate_registration_numbers: (string | null)[];
  candidates: CandidateDiagnostic[];
  /** The registration the caller asked to resolve (structured action). */
  selected_registration: string | null;
  lookup_method: LookupMethod;
  cache: LookupCacheState;
  duration_ms: number;
  /** Non-fatal stage failures, e.g. "register_timeout". Fail-soft paths are
   *  invisible by design; this is where they become visible. */
  degraded: string[];
}

/**
 * The deployed build identifier.
 *
 * Set `LOOKUP_GIT_SHA` at deploy time. When it is absent the value is the
 * literal string "unknown" — NOT a generated or timestamped stand-in, because
 * a build id that changes per isolate would make two identical deployments
 * look like different builds and send a parity investigation chasing nothing.
 */
export function lookupVersion(env: (k: string) => string | undefined = Deno.env.get): string {
  const sha = (env("LOOKUP_GIT_SHA") ?? "").trim();
  return sha || "unknown";
}

/**
 * The Supabase project ref, derived from the function's own SUPABASE_URL.
 *
 * `https://abcdefgh.supabase.co` → `abcdefgh`. Returns "unknown" rather than
 * guessing when the URL is absent or shaped differently (self-hosted).
 */
export function projectRef(env: (k: string) => string | undefined = Deno.env.get): string {
  const raw = (env("SUPABASE_URL") ?? "").trim();
  if (!raw) return "unknown";
  try {
    const host = new URL(raw).hostname;
    const first = host.split(".")[0] ?? "";
    return first || "unknown";
  } catch {
    return "unknown";
  }
}

/** Normalises whatever the client called itself onto the closed platform set. */
export function normaliseClientPlatform(raw: unknown): LookupClientPlatform {
  const v = String(raw ?? "").trim().toLowerCase();
  if (!v) return "unknown";
  if (v === "ios" || v === "iphone" || v === "ipad") return "ios";
  if (v === "android") return "android";
  if (v === "portal" || v === "web" || v === "lovable") return "portal";
  return "unknown";
}

/** Trims a short free-text field, or null. Bounded so a malformed client
 *  cannot write unbounded strings into the log stream. */
function shortText(raw: unknown, max = 64): string | null {
  const v = String(raw ?? "").trim();
  if (!v) return null;
  return v.length > max ? v.slice(0, max) : v;
}

/**
 * Reads the client context block from a request body.
 *
 * Entirely optional and entirely untrusted: a client that sends nothing is
 * recorded as "unknown" rather than rejected. Diagnostics must never be able
 * to fail a lookup.
 */
export function readClientContext(body: unknown): LookupClientContext {
  const b = (body ?? {}) as Record<string, unknown>;
  const c = (b.client ?? {}) as Record<string, unknown>;
  return {
    platform: normaliseClientPlatform(c.platform ?? b.clientPlatform),
    appVersion: shortText(c.app_version ?? c.appVersion),
    appBuild: shortText(c.app_build ?? c.appBuild),
    correlationId: shortText(c.correlation_id ?? c.correlationId, 80),
  };
}

/** A fresh server-side request id. */
export function newRequestId(): string {
  return crypto.randomUUID();
}

export interface BuildDiagnosticsInput {
  requestId: string;
  client: LookupClientContext;
  action: string;
  requestedCountry: string;
  resolvedCountryCode: string | null;
  query: string;
  candidates?: CandidateDiagnostic[];
  selectedRegistration?: string | null;
  method: LookupMethod;
  cache?: LookupCacheState;
  startedAt: number;
  degraded?: string[];
  env?: (k: string) => string | undefined;
  now?: () => number;
}

/** Assembles the envelope from decisions the pipeline has already made. */
export function buildDiagnostics(input: BuildDiagnosticsInput): LookupDiagnostics {
  const env = input.env ?? Deno.env.get;
  const now = input.now ?? Date.now;
  const candidates = input.candidates ?? [];
  return {
    request_id: input.requestId,
    correlation_id: input.client.correlationId,
    client: {
      platform: input.client.platform,
      app_version: input.client.appVersion,
      app_build: input.client.appBuild,
    },
    server: {
      lookup_version: lookupVersion(env),
      project_ref: projectRef(env),
    },
    action: input.action,
    country: {
      requested: input.requestedCountry,
      resolved_code: input.resolvedCountryCode || null,
    },
    query: input.query,
    candidate_registration_numbers: candidates.map((c) => c.registrationNumber),
    candidates,
    selected_registration: input.selectedRegistration ?? null,
    lookup_method: input.method,
    cache: input.cache ?? "none",
    duration_ms: Math.max(0, now() - input.startedAt),
    degraded: input.degraded ?? [],
  };
}

/**
 * Projects served search rows onto candidate diagnostics.
 *
 * Reads the rows AS SERVED, after every ordering decision has been made, so
 * the recorded order is the order the client received — not the order some
 * earlier stage intended. Rows carrying no registration identity (AI
 * suggestions) record `null` rather than being dropped: a platform showing an
 * unregistered suggestion where another shows a register row is exactly the
 * divergence this is meant to expose.
 */
export function candidatesFromSearchResults(
  results: unknown[],
): CandidateDiagnostic[] {
  return (results ?? []).map((raw) => {
    const r = (raw ?? {}) as Record<string, unknown>;
    const reg = String(r.registration_number ?? "").trim();
    const score = typeof r.rank_score === "number" ? r.rank_score : null;
    const reason = shortText(r.rank_reason, 48);
    return {
      registrationNumber: reg || null,
      name: String(r.name ?? "").trim(),
      source: String(r.source ?? "ai").trim() || "ai",
      score,
      reason,
    };
  });
}

/**
 * One structured log line per lookup.
 *
 * Single-line JSON on purpose: the Supabase log explorer treats a line as a
 * record, and a multi-line dump of the same data cannot be filtered by
 * request id — which is the only reason this exists.
 */
export function diagnosticsLog(d: LookupDiagnostics): string {
  return JSON.stringify({ evt: "chemical_lookup_diagnostics", ...d });
}
