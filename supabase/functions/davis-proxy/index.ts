// Supabase Edge Function: davis-proxy
//
// Server-side proxy for Davis WeatherLink v2. Reads vineyard-shared
// credentials from `vineyard_weather_integrations` using the service-role
// key, so operators can fetch rainfall / current conditions for the
// configured station without ever holding the API Secret.
//
// Auth: caller must send the Supabase JWT in the Authorization header.
// We verify the caller is a member of the requested vineyard, then load
// credentials with the service-role client.
//
// Request (POST JSON):
//   {
//     "vineyardId": "<uuid>",
//     "action": "stations" | "current" | "historic" | "test" | "test_saved" | "backfill_rainfall",
//     "stationId"?: string,            // for current / historic / backfill
//     "startEpoch"?: number,           // for historic, seconds
//     "endEpoch"?: number,             // for historic, seconds
//     "days"?: number,                 // for backfill_rainfall: target window 1..365 (default 14)
//     "offsetDays"?: number,           // skip first N days from yesterday (default 0)
//     "chunkDays"?: number,            // process at most N days this call (default 60, max 60)
//     "timezone"?: string,             // IANA tz, default 'Australia/Sydney'
//     "apiKey"?: string,               // for "test" only (owner/manager)
//     "apiSecret"?: string             // for "test" only (owner/manager)
//   }
//
// "backfill_rainfall" — owner/manager only. Iterates the past N vineyard-
//                  local days and upserts public.rainfall_daily rows for
//                  source='davis_weatherlink'. Returns counts only; never
//                  returns credentials or raw payloads.
//
// "test"        — owner/manager verifies an ad-hoc key/secret pair before
//                  saving. Credentials come in the request body and are not
//                  persisted; nothing is written.
// "test_saved"  — owner/manager re-tests the credentials already stored in
//                  vineyard_weather_integrations for the vineyard. Updates
//                  last_tested_at / last_test_status. Never returns secrets.
//
// 401 if not authenticated, 403 if not a vineyard member, 404 if no
// integration / station configured, 502 on upstream errors.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DAVIS_BASE = "https://api.weatherlink.com/v2";

// Bumped whenever the proxy contract changes so the iOS client can prove
// which deployed code is actually serving requests. Surfaced in the
// `_proxy.version` field of `current` responses and in the top-level
// `version` field of every JSON response.
const PROXY_VERSION = "chunked-backfill-2026-05-07";
const BACKFILL_MAX_DAYS = 365;
const BACKFILL_MAX_CHUNK = 60;
const BACKFILL_DEFAULT_CHUNK = 60;

// ---------------------------------------------------------------------------
// Vineyard-local date helper.
// Computes the YYYY-MM-DD date for an instant in a given IANA timezone.
function localDateString(d: Date, timezone: string): string {
  try {
    const fmt = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
    });
    return fmt.format(d); // en-CA gives YYYY-MM-DD
  } catch {
    return d.toISOString().slice(0, 10);
  }
}

// Returns the UTC instant of midnight (start-of-day) in the given tz for
// the given local YYYY-MM-DD date. Approximate but sufficient for daily
// rainfall windows (off by at most an hour around DST transitions).
function localMidnightUtc(localDate: string, timezone: string): Date {
  // Start with the candidate at UTC midnight then correct for the offset.
  const utcGuess = new Date(localDate + "T00:00:00Z");
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const parts = fmt.formatToParts(utcGuess).reduce<Record<string,string>>((acc, p) => {
    if (p.type !== "literal") acc[p.type] = p.value;
    return acc;
  }, {});
  const asUtc = Date.UTC(
    Number(parts.year), Number(parts.month) - 1, Number(parts.day),
    Number(parts.hour), Number(parts.minute), Number(parts.second),
  );
  const offsetMs = asUtc - utcGuess.getTime();
  return new Date(utcGuess.getTime() - offsetMs);
}

// ---------------------------------------------------------------------------
// Helpers: parse Davis /current payload into safe, metric, normalised fields
// for the vineyard_weather_observations cache. We never persist credentials
// or auth headers — only the parsed sensor values plus a scrubbed copy of
// the upstream JSON sensors array (no auth fields are present in that
// payload anyway, but we extract just the data records to be safe).
// ---------------------------------------------------------------------------

function fToC(f: unknown): number | null {
  const n = typeof f === "number" ? f : Number(f);
  if (!isFinite(n)) return null;
  return Math.round(((n - 32) * 5 / 9) * 10) / 10;
}
function mphToKmh(v: unknown): number | null {
  const n = typeof v === "number" ? v : Number(v);
  if (!isFinite(n)) return null;
  return Math.round(n * 1.609344 * 10) / 10;
}
function inToMmRaw(v: unknown): number | null {
  const n = typeof v === "number" ? v : Number(v);
  if (!isFinite(n)) return null;
  return n * 25.4;
}
function inToMm(v: unknown): number | null {
  const n = typeof v === "number" ? v : Number(v);
  if (!isFinite(n)) return null;
  return Math.round(n * 25.4 * 100) / 100;
}
function num(v: unknown): number | null {
  const n = typeof v === "number" ? v : Number(v);
  return isFinite(n) ? n : null;
}

function parseDavisCurrent(body: any): {
  observed_at: string | null;
  temperature_c: number | null;
  humidity_pct: number | null;
  wind_speed_kmh: number | null;
  wind_direction_deg: number | null;
  wind_gust_kmh: number | null;
  rain_today_mm: number | null;
  rain_rate_mm_per_hr: number | null;
  leaf_wetness: number | null;
  station_id: string | null;
  safe_sensors: unknown;
} {
  const out = {
    observed_at: null as string | null,
    temperature_c: null as number | null,
    humidity_pct: null as number | null,
    wind_speed_kmh: null as number | null,
    wind_direction_deg: null as number | null,
    wind_gust_kmh: null as number | null,
    rain_today_mm: null as number | null,
    rain_rate_mm_per_hr: null as number | null,
    leaf_wetness: null as number | null,
    station_id: null as string | null,
    safe_sensors: null as unknown,
  };
  if (!body || typeof body !== "object") return out;

  if (body.station_id != null) out.station_id = String(body.station_id);

  const sensors: any[] = Array.isArray(body.sensors) ? body.sensors : [];
  let latestTs = 0;
  const safeSensors: any[] = [];
  for (const s of sensors) {
    const records: any[] = Array.isArray(s?.data) ? s.data : [];
    safeSensors.push({
      lsid: s?.lsid ?? null,
      sensor_type: s?.sensor_type ?? null,
      data_structure_type: s?.data_structure_type ?? null,
      data: records,
    });
    for (const r of records) {
      if (!r || typeof r !== "object") continue;
      const ts = num(r.ts);
      if (ts != null && ts > latestTs) latestTs = ts;

      // Temperature: prefer Celsius if provided, else convert from F.
      const tC = num(r.temp_c);
      if (tC != null) out.temperature_c = tC;
      else if (out.temperature_c == null && r.temp != null) out.temperature_c = fToC(r.temp);

      // Humidity
      const h = num(r.hum) ?? num(r.hum_last) ?? num(r.hum_out);
      if (h != null) out.humidity_pct = Math.round(h * 10) / 10;

      // Wind
      const wsKmh = num(r.wind_speed_last_kmh) ?? num(r.wind_speed_kmh);
      if (wsKmh != null) out.wind_speed_kmh = Math.round(wsKmh * 10) / 10;
      else if (out.wind_speed_kmh == null) {
        const wsMph = num(r.wind_speed_last) ?? num(r.wind_speed);
        if (wsMph != null) out.wind_speed_kmh = mphToKmh(wsMph);
      }
      const wd = num(r.wind_dir_last) ?? num(r.wind_dir) ?? num(r.wind_dir_scalar_avg_last_2_min);
      if (wd != null) out.wind_direction_deg = wd;

      // Wind gust (current/recent observed high). Prefer the last-10-min
      // high in km/h, then mph, then other Davis high-wind variants.
      // NOTE: never fall back to 0 — absence stays null.
      const gustKmh = num(r.wind_speed_hi_last_10_min_kmh) ?? num(r.wind_speed_hi_kmh);
      if (gustKmh != null) out.wind_gust_kmh = Math.round(gustKmh * 10) / 10;
      else if (out.wind_gust_kmh == null) {
        const gustMph = num(r.wind_speed_hi_last_10_min)
          ?? num(r.wind_speed_hi)
          ?? num(r.wind_gust_10_min);
        if (gustMph != null) out.wind_gust_kmh = mphToKmh(gustMph);
      }

      // Rain today
      const rTodayMm = num(r.rainfall_daily_mm) ?? num(r.rain_daily_mm);
      if (rTodayMm != null) out.rain_today_mm = Math.round(rTodayMm * 100) / 100;
      else if (out.rain_today_mm == null) {
        const rTodayIn = num(r.rainfall_daily_in) ?? num(r.rain_daily_in);
        if (rTodayIn != null) out.rain_today_mm = inToMm(rTodayIn);
      }

      // Rain rate
      const rRateMm = num(r.rain_rate_last_mm) ?? num(r.rain_rate_mm);
      if (rRateMm != null) out.rain_rate_mm_per_hr = Math.round(rRateMm * 100) / 100;
      else if (out.rain_rate_mm_per_hr == null) {
        const rRateIn = num(r.rain_rate_last_in) ?? num(r.rain_rate_in);
        if (rRateIn != null) out.rain_rate_mm_per_hr = inToMm(rRateIn);
      }

      // Leaf wetness (Davis 0..15 scale)
      const lw = num(r.wet_leaf_last_1) ?? num(r.wet_leaf_last) ?? num(r.wet_leaf);
      if (lw != null) out.leaf_wetness = lw;
    }
  }
  if (latestTs > 0) {
    out.observed_at = new Date(latestTs * 1000).toISOString();
  }
  out.safe_sensors = safeSensors;
  return out;
}


function json(body: unknown, status = 200): Response {
  // Stamp every JSON response with the deployed proxy version so callers
  // can confirm which build is live without depending on Edge Function
  // log access. Top-level `_proxy_version` does not collide with Davis
  // payloads (Davis uses no underscore-prefixed keys).
  let payload: unknown = body;
  if (body && typeof body === "object" && !Array.isArray(body)) {
    payload = { _proxy_version: PROXY_VERSION, ...(body as Record<string, unknown>) };
  }
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function davisGet(
  path: string,
  apiKey: string,
  apiSecret: string,
  query: Record<string, string> = {},
): Promise<{ status: number; body: any }> {
  const u = new URL(DAVIS_BASE + path);
  u.searchParams.set("api-key", apiKey);
  for (const [k, v] of Object.entries(query)) u.searchParams.set(k, v);
  const res = await fetch(u.toString(), {
    headers: { "X-Api-Secret": apiSecret, Accept: "application/json" },
  });
  let body: any = null;
  try { body = await res.json(); } catch { /* ignore */ }
  return { status: res.status, body };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!supabaseUrl || !serviceKey || !anonKey) {
    return json({ error: "Server misconfigured" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Authentication required" }, 401);
  }

  // Verify the caller's identity using the user JWT.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userRes, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userRes?.user) {
    return json({ error: "Authentication required" }, 401);
  }
  const userId = userRes.user.id;

  let body: any;
  try { body = await req.json(); } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const vineyardId = typeof body?.vineyardId === "string" ? body.vineyardId : null;
  const action = typeof body?.action === "string" ? body.action : null;
  if (!vineyardId || !action) {
    return json({ error: "vineyardId and action are required" }, 400);
  }

  // Service-role client for privileged reads.
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Membership + role check.
  const { data: memberRow, error: memberErr } = await admin
    .from("vineyard_members")
    .select("role")
    .eq("vineyard_id", vineyardId)
    .eq("user_id", userId)
    .maybeSingle();
  if (memberErr) return json({ error: memberErr.message }, 500);
  if (!memberRow) return json({ error: "Not a vineyard member" }, 403);
  const role = memberRow.role as string;

  // For the "test" action we accept ad-hoc credentials passed in by an
  // owner/manager who is verifying a key before saving.
  if (action === "test") {
    if (role !== "owner" && role !== "manager") {
      return json({ error: "Owner or manager role required" }, 403);
    }
    const apiKey = String(body.apiKey ?? "");
    const apiSecret = String(body.apiSecret ?? "");
    if (!apiKey || !apiSecret) {
      return json({ error: "apiKey and apiSecret are required" }, 400);
    }
    const r = await davisGet("/stations", apiKey, apiSecret);
    if (r.status === 401 || r.status === 403) {
      return json({ error: "Invalid Davis credentials" }, 401);
    }
    if (r.status < 200 || r.status >= 300) {
      return json({ error: `WeatherLink HTTP ${r.status}` }, 502);
    }
    return json({ stations: r.body?.stations ?? [] });
  }

  // "test_saved" re-validates the credentials currently stored for this
  // vineyard and records the result. Credentials are never returned.
  if (action === "test_saved") {
    if (role !== "owner" && role !== "manager") {
      return json({ error: "Owner or manager role required" }, 403);
    }
    const { data: integ, error: integErr } = await admin
      .from("vineyard_weather_integrations")
      .select("api_key, api_secret, station_id, station_name")
      .eq("vineyard_id", vineyardId)
      .eq("provider", "davis_weatherlink")
      .maybeSingle();
    if (integErr) return json({ error: integErr.message }, 500);
    if (!integ?.api_key || !integ?.api_secret) {
      return json(
        { success: false, error: "Davis integration not configured for this vineyard" },
        404,
      );
    }
    const r = await davisGet("/stations", String(integ.api_key), String(integ.api_secret));
    const testedAt = new Date().toISOString();
    let success = false;
    let status = "";
    let message = "";
    if (r.status === 401 || r.status === 403) {
      status = "invalid_credentials";
      message = "Invalid Davis credentials";
    } else if (r.status < 200 || r.status >= 300) {
      status = `http_${r.status}`;
      message = `WeatherLink HTTP ${r.status}`;
    } else {
      success = true;
      status = "ok";
      message = "Connection successful";
    }
    await admin
      .from("vineyard_weather_integrations")
      .update({ last_tested_at: testedAt, last_test_status: status })
      .eq("vineyard_id", vineyardId)
      .eq("provider", "davis_weatherlink");
    return json({
      success,
      tested_at: testedAt,
      status,
      message,
      station_id: integ.station_id ?? null,
      station_name: integ.station_name ?? null,
      stations: success ? (r.body?.stations ?? []) : [],
    }, success ? 200 : (r.status === 401 || r.status === 403 ? 401 : 502));
  }

  // For all other actions we read the stored vineyard credentials.
  const { data: integ, error: integErr } = await admin
    .from("vineyard_weather_integrations")
    .select("*")
    .eq("vineyard_id", vineyardId)
    .eq("provider", "davis_weatherlink")
    .eq("is_active", true)
    .maybeSingle();
  if (integErr) return json({ error: integErr.message }, 500);
  if (!integ?.api_key || !integ?.api_secret) {
    return json({ error: "Davis integration not configured for this vineyard" }, 404);
  }
  const apiKey = String(integ.api_key);
  const apiSecret = String(integ.api_secret);

  switch (action) {
    case "stations": {
      const r = await davisGet("/stations", apiKey, apiSecret);
      if (r.status >= 200 && r.status < 300) {
        return json({ stations: r.body?.stations ?? [] });
      }
      return json({ error: `WeatherLink HTTP ${r.status}` }, 502);
    }

    case "current": {
      const stationId = String(body.stationId ?? integ.station_id ?? "");
      if (!stationId) return json({ error: "stationId required" }, 400);
      const r = await davisGet(`/current/${stationId}`, apiKey, apiSecret);
      if (r.status >= 200 && r.status < 300) {
        // Best-effort cache writes. Failures must not break the response,
        // but we log structured diagnostics (no secrets) so we can tell
        // from the function logs whether each write succeeded.
        const stationName = integ.station_name ?? null;
        const tz = typeof body.timezone === "string" && body.timezone
          ? body.timezone
          : "Australia/Sydney";

        let parsed: ReturnType<typeof parseDavisCurrent> | null = null;
        let parseError: string | null = null;
        try {
          parsed = parseDavisCurrent(r.body);
        } catch (e) {
          parseError = e instanceof Error ? e.message : String(e);
          console.log(JSON.stringify({
            tag: "davis-proxy.current.parse_failed",
            vineyardId, stationId,
            error: parseError,
          }));
        }

        // Diagnostics block returned to the caller alongside the raw
        // Davis payload so the iOS UI can confirm exactly which writes
        // succeeded server-side without depending on Edge Function logs
        // (Supabase only surfaces boot/shutdown lines in the dashboard
        // for some projects).
        const obsStatus = {
          attempted: false,
          success: false,
          code: null as string | null,
          message: null as string | null,
        };
        const rainStatus = {
          attempted: false,
          success: false,
          code: null as string | null,
          message: null as string | null,
        };
        let diagLocalDate: string | null = null;
        let diagRainMm: number | null = null;

        if (parsed && parsed.observed_at) {
          // 1) Observations cache.
          obsStatus.attempted = true;
          try {
            const safePayload = {
              station_id: parsed.station_id ?? stationId,
              generated_at: r.body?.generated_at ?? null,
              sensors: parsed.safe_sensors,
            };
            const { error: obsErr } = await admin
              .from("vineyard_weather_observations")
              .upsert({
                vineyard_id: vineyardId,
                source: "davis_weatherlink",
                station_id: String(parsed.station_id ?? stationId),
                station_name: stationName,
                observed_at: parsed.observed_at,
                fetched_at: new Date().toISOString(),
                temperature_c: parsed.temperature_c,
                humidity_pct: parsed.humidity_pct,
                wind_speed_kmh: parsed.wind_speed_kmh,
                wind_direction_deg: parsed.wind_direction_deg,
                wind_gust_kmh: parsed.wind_gust_kmh,
                rain_today_mm: parsed.rain_today_mm,
                rain_rate_mm_per_hr: parsed.rain_rate_mm_per_hr,
                leaf_wetness: parsed.leaf_wetness,
                raw_payload: safePayload,
              }, { onConflict: "vineyard_id,source" });
            if (obsErr) {
              obsStatus.code = (obsErr as any).code ?? null;
              obsStatus.message = obsErr.message ?? null;
              console.log(JSON.stringify({
                tag: "davis-proxy.current.observations_failed",
                vineyardId, stationId,
                code: obsStatus.code,
                message: obsStatus.message,
              }));
            } else {
              obsStatus.success = true;
            }
          } catch (e) {
            obsStatus.message = e instanceof Error ? e.message : String(e);
            console.log(JSON.stringify({
              tag: "davis-proxy.current.observations_threw",
              vineyardId, stationId,
              error: obsStatus.message,
            }));
          }

          // 2) Rain calendar daily row. Independent try so a failure here
          //    is reported separately from the observations write. We
          //    write even when rain_today_mm is 0 so the calendar reflects
          //    "no rain yet today" and the row exists once a station
          //    reports.
          const rainMm = parsed.rain_today_mm;
          const localDate = localDateString(new Date(parsed.observed_at), tz);
          diagLocalDate = localDate;
          diagRainMm = rainMm;
          if (rainMm != null && isFinite(rainMm) && rainMm >= 0) {
            rainStatus.attempted = true;
            try {
              const { error: rpcErr } = await admin.rpc(
                "upsert_davis_rainfall_daily",
                {
                  p_vineyard_id: vineyardId,
                  p_date: localDate,
                  p_rainfall_mm: rainMm,
                  p_station_id: String(parsed.station_id ?? stationId),
                  p_station_name: stationName,
                },
              );
              if (rpcErr) {
                rainStatus.code = (rpcErr as any).code ?? null;
                rainStatus.message = rpcErr.message ?? null;
              } else {
                rainStatus.success = true;
              }
            } catch (e) {
              rainStatus.message = e instanceof Error ? e.message : String(e);
            }
          } else {
            rainStatus.message = "rain_today_mm not available in parsed payload";
          }

          console.log(JSON.stringify({
            tag: "davis-proxy.current.rainfall_daily",
            vineyardId,
            stationId: String(parsed.station_id ?? stationId),
            stationName,
            localDate,
            rainTodayMm: rainMm,
            attempted: rainStatus.attempted,
            success: rainStatus.success,
            code: rainStatus.code,
            message: rainStatus.message,
          }));
        } else {
          console.log(JSON.stringify({
            tag: "davis-proxy.current.no_observed_at",
            vineyardId, stationId,
            hasParsed: parsed != null,
            parseError,
          }));
          obsStatus.message = parseError ?? "Davis payload had no observed_at";
          rainStatus.message = parseError ?? "Davis payload had no observed_at";
        }

        // Augment the raw Davis payload with a `_proxy` diagnostics block
        // so the iOS client can render an accurate success/failure
        // message. The Davis JSON itself never uses an `_proxy` key, so
        // this is non-conflicting for downstream parsers.
        const augmented = {
          ...(r.body && typeof r.body === "object" ? r.body : {}),
          _proxy: {
            version: PROXY_VERSION,
            observations: obsStatus,
            rainfall_daily: {
              ...rainStatus,
              date: diagLocalDate,
              rain_today_mm: diagRainMm,
            },
            station_id: String(parsed?.station_id ?? stationId),
            station_name: stationName,
            timezone: tz,
          },
        };
        return json(augmented);
      }
      return json({ error: `WeatherLink HTTP ${r.status}` }, 502);
    }

    case "backfill_rainfall": {
      if (role !== "owner" && role !== "manager") {
        return json({ error: "Owner or manager role required" }, 403);
      }
      const stationId = String(body.stationId ?? integ.station_id ?? "");
      if (!stationId) return json({ error: "stationId required" }, 400);
      const requestedDays = Number(body.days);
      const days = isFinite(requestedDays) && requestedDays > 0
        ? Math.min(BACKFILL_MAX_DAYS, Math.floor(requestedDays))
        : 14;
      const requestedOffset = Number(body.offsetDays);
      const offsetDays = isFinite(requestedOffset) && requestedOffset > 0
        ? Math.min(BACKFILL_MAX_DAYS, Math.floor(requestedOffset))
        : 0;
      const requestedChunk = Number(body.chunkDays);
      const chunkDays = isFinite(requestedChunk) && requestedChunk > 0
        ? Math.min(BACKFILL_MAX_CHUNK, Math.floor(requestedChunk))
        : BACKFILL_DEFAULT_CHUNK;
      const timezone = typeof body.timezone === "string" && body.timezone
        ? body.timezone
        : "Australia/Sydney";
      const stationName = integ.station_name ?? null;

      // Iterate from yesterday backwards. Skip today: rain_today_mm is
      // handled by the "current" action and not a closed day yet.
      const todayLocal = localDateString(new Date(), timezone);
      const todayMidnightUtc = localMidnightUtc(todayLocal, timezone);

      // Process the slice [offsetDays+1 .. endIndex] of the target window.
      const startIndex = offsetDays + 1;
      const endIndex = Math.min(days, offsetDays + chunkDays);
      const sliceLength = Math.max(0, endIndex - startIndex + 1);

      let processed = 0;
      let upserted = 0;
      let rateLimited = false;
      const errors: string[] = [];

      for (let i = startIndex; i <= endIndex; i++) {
        const endUtc = new Date(todayMidnightUtc.getTime() - (i - 1) * 86400000);
        const startUtc = new Date(endUtc.getTime() - 86400000);
        const startEpoch = Math.floor(startUtc.getTime() / 1000);
        const endEpoch = Math.floor(endUtc.getTime() / 1000);
        const localDate = localDateString(startUtc, timezone);

        const r = await davisGet(
          `/historic/${stationId}`,
          apiKey, apiSecret,
          { "start-timestamp": String(startEpoch), "end-timestamp": String(endEpoch) },
        );
        if (r.status === 429) {
          errors.push("rate_limited");
          rateLimited = true;
          break;
        }
        if (r.status < 200 || r.status >= 300) {
          errors.push(`http_${r.status}`);
          continue;
        }
        processed++;

        // Sum rainfall across all archive records for the day.
        let mm = 0;
        let sawAny = false;
        const sensors: any[] = Array.isArray(r.body?.sensors) ? r.body.sensors : [];
        for (const s of sensors) {
          const records: any[] = Array.isArray(s?.data) ? s.data : [];
          for (const rec of records) {
            if (!rec || typeof rec !== "object") continue;
            const mmVal = num(rec.rainfall_mm)
              ?? num(rec.rainfall_last_15_min_mm)
              ?? num(rec.rainfall_last_60_min_mm);
            if (mmVal != null) { mm += mmVal; sawAny = true; continue; }
            const inVal = num(rec.rainfall_in)
              ?? num(rec.rainfall_last_15_min_in)
              ?? num(rec.rainfall_last_60_min_in);
            if (inVal != null) {
              const conv = inToMmRaw(inVal);
              if (conv != null) { mm += conv; sawAny = true; }
            }
          }
        }

        if (!sawAny) continue;
        const rainfallMm = Math.round(mm * 100) / 100;

        const { error: rpcErr } = await admin.rpc("upsert_davis_rainfall_daily", {
          p_vineyard_id: vineyardId,
          p_date: localDate,
          p_rainfall_mm: rainfallMm,
          p_station_id: stationId,
          p_station_name: stationName,
        });
        if (rpcErr) {
          errors.push(rpcErr.message);
        } else {
          upserted++;
        }
      }

      const reachedEnd = endIndex >= days;
      const more = !reachedEnd && !rateLimited;
      const nextOffsetDays = more ? endIndex : null;

      return json({
        success: errors.length === 0,
        days_requested: days,
        days_processed: processed,
        rows_upserted: upserted,
        offset_days: offsetDays,
        chunk_days: chunkDays,
        slice_length: sliceLength,
        next_offset_days: nextOffsetDays,
        more,
        rate_limited: rateLimited,
        timezone,
        errors_count: errors.length,
        proxy_version: PROXY_VERSION,
      });
    }

    case "historic": {
      const stationId = String(body.stationId ?? integ.station_id ?? "");
      const startEpoch = Number(body.startEpoch);
      const endEpoch = Number(body.endEpoch);
      if (!stationId || !isFinite(startEpoch) || !isFinite(endEpoch)) {
        return json({ error: "stationId, startEpoch, endEpoch required" }, 400);
      }
      const r = await davisGet(
        `/historic/${stationId}`,
        apiKey,
        apiSecret,
        { "start-timestamp": String(startEpoch), "end-timestamp": String(endEpoch) },
      );
      if (r.status === 429) return json({ error: "WeatherLink rate limit reached" }, 429);
      if (r.status >= 200 && r.status < 300) return json(r.body ?? {});
      return json({ error: `WeatherLink HTTP ${r.status}` }, 502);
    }

    default:
      return json({ error: `Unknown action: ${action}` }, 400);
  }
});
