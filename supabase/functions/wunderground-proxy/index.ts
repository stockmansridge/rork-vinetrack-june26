// Supabase Edge Function: wunderground-proxy
//
// Server-side proxy for Weather Underground PWS history. Reads the
// platform-wide WUNDERGROUND_API_KEY secret and the per-vineyard
// station ID from `vineyard_weather_integrations` (provider =
// 'wunderground'), so the API key is never exposed to the device or
// portal.
//
// Auth: caller must send the Supabase JWT in the Authorization header.
// Owner/Manager role required for backfill.
//
// Request (POST JSON):
//   {
//     "vineyardId": "<uuid>",
//     "action": "backfill_rainfall",
//     "stationId"?: string,            // optional override
//     "days"?: number,                 // target window 1..365 (default 14)
//     "offsetDays"?: number,           // skip first N days from yesterday (default 0)
//     "chunkDays"?: number,            // process at most N days this call (default 30, max 30)
//     "timezone"?: string              // IANA tz, default 'Australia/Sydney'
//   }
//
// Response (200 JSON):
//   {
//     success, days_requested, days_processed, rows_upserted,
//     errors_count, station_id, station_name, timezone, proxy_version,
//     attempted_dates: [...], per_day: [{ date, status, mm? }]
//   }
//
// Writes: only source = 'wunderground_pws' rows via
// public.upsert_wunderground_rainfall_daily(...). Never touches
// manual, davis_weatherlink, or open_meteo rows.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const WU_BASE = "https://api.weather.com";
const PROXY_VERSION = "wunderground-chunked-backfill-2026-05-07";
const BACKFILL_MAX_DAYS = 365;
const BACKFILL_MAX_CHUNK = 30;
const BACKFILL_DEFAULT_CHUNK = 30;

function json(body: unknown, status = 200): Response {
  let payload: unknown = body;
  if (body && typeof body === "object" && !Array.isArray(body)) {
    payload = { _proxy_version: PROXY_VERSION, ...(body as Record<string, unknown>) };
  }
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function num(v: unknown): number | null {
  if (v == null) return null;
  const n = typeof v === "number" ? v : Number(v);
  return isFinite(n) ? n : null;
}

// Format a Date as YYYY-MM-DD in the given IANA timezone.
function localDateString(d: Date, timezone: string): string {
  try {
    const fmt = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
    });
    return fmt.format(d);
  } catch {
    return d.toISOString().slice(0, 10);
  }
}

// Compact YYYYMMDD form (Weather Underground history requires this).
function compactDate(yyyyMmDd: string): string {
  return yyyyMmDd.replaceAll("-", "");
}

// Subtract N days from a vineyard-local date (YYYY-MM-DD), returning
// the resulting local date string. Uses UTC arithmetic on noon to avoid
// DST edge cases for whole-day stepping.
function subtractDays(yyyyMmDd: string, days: number, timezone: string): string {
  const base = new Date(yyyyMmDd + "T12:00:00Z");
  const stepped = new Date(base.getTime() - days * 86400000);
  return localDateString(stepped, timezone);
}

async function wuGetDailyRainMm(
  stationId: string,
  apiKey: string,
  yyyyMmDd: string,
): Promise<{ status: number; mm: number | null; error: string | null }> {
  // PWS history daily summary; units=m means metric (mm for precip).
  const u = new URL(WU_BASE + "/v2/pws/history/daily");
  u.searchParams.set("stationId", stationId);
  u.searchParams.set("format", "json");
  u.searchParams.set("units", "m");
  u.searchParams.set("date", compactDate(yyyyMmDd));
  u.searchParams.set("numericPrecision", "decimal");
  u.searchParams.set("apiKey", apiKey);

  let res: Response;
  try {
    res = await fetch(u.toString());
  } catch (e) {
    return { status: 0, mm: null, error: e instanceof Error ? e.message : String(e) };
  }
  if (res.status === 204) return { status: 204, mm: null, error: "no_data" };
  if (!res.ok) return { status: res.status, mm: null, error: `http_${res.status}` };

  let data: any = null;
  try { data = await res.json(); } catch { /* ignore */ }
  const obs: any[] = Array.isArray(data?.observations) ? data.observations : [];
  if (obs.length === 0) return { status: 200, mm: null, error: "no_observations" };

  // Daily summary returns one row with metric.precipTotal (mm).
  let mm: number | null = null;
  for (const o of obs) {
    const v = num(o?.metric?.precipTotal) ?? num(o?.precipTotal);
    if (v != null) { mm = (mm ?? 0) + v; }
  }
  if (mm == null) return { status: 200, mm: null, error: "no_precip_field" };
  return { status: 200, mm: Math.round(mm * 100) / 100, error: null };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const apiKey = Deno.env.get("WUNDERGROUND_API_KEY") ?? "";
  if (!supabaseUrl || !serviceKey || !anonKey) {
    return json({ error: "Server misconfigured" }, 500);
  }
  if (!apiKey) {
    return json({ error: "Server is missing WUNDERGROUND_API_KEY secret" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Authentication required" }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userRes, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userRes?.user) return json({ error: "Authentication required" }, 401);
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

  // Resolve station ID + integration metadata.
  const { data: integ, error: integErr } = await admin
    .from("vineyard_weather_integrations")
    .select("station_id, station_name, is_active")
    .eq("vineyard_id", vineyardId)
    .eq("provider", "wunderground")
    .maybeSingle();
  if (integErr) return json({ error: integErr.message }, 500);

  const stationIdParam = typeof body.stationId === "string" && body.stationId
    ? body.stationId
    : null;
  const stationId = stationIdParam ?? (integ?.station_id ? String(integ.station_id) : "");
  const stationName = integ?.station_name ?? null;

  switch (action) {
    case "backfill_rainfall": {
      if (role !== "owner" && role !== "manager") {
        return json({ error: "Owner or manager role required" }, 403);
      }
      if (!stationId) {
        return json({
          error: "No Weather Underground station configured for this vineyard",
        }, 404);
      }

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

      const todayLocal = localDateString(new Date(), timezone);
      const attemptedDates: string[] = [];
      const perDay: Array<{
        date: string; status: string; mm?: number | null;
      }> = [];
      let processed = 0;
      let upserted = 0;
      let errorsCount = 0;
      let rateLimited = false;

      // Process slice [offsetDays+1 .. endIndex] from yesterday backwards.
      // Skip today: WU daily summary for an in-progress day is incomplete
      // and would later need to be overwritten.
      const startIndex = offsetDays + 1;
      const endIndex = Math.min(days, offsetDays + chunkDays);
      const sliceLength = Math.max(0, endIndex - startIndex + 1);

      for (let i = startIndex; i <= endIndex; i++) {
        const dateStr = subtractDays(todayLocal, i, timezone);
        attemptedDates.push(dateStr);

        const r = await wuGetDailyRainMm(stationId, apiKey, dateStr);
        if (r.status === 429) {
          perDay.push({ date: dateStr, status: "rate_limited" });
          errorsCount++;
          rateLimited = true;
          break;
        }
        if (r.status === 0) {
          perDay.push({ date: dateStr, status: "network_error" });
          errorsCount++;
          continue;
        }
        if (r.status === 204 || r.error === "no_observations" || r.error === "no_data") {
          perDay.push({ date: dateStr, status: "no_data" });
          processed++;
          continue;
        }
        if (r.status < 200 || r.status >= 300) {
          perDay.push({ date: dateStr, status: r.error ?? `http_${r.status}` });
          errorsCount++;
          continue;
        }
        if (r.mm == null) {
          perDay.push({ date: dateStr, status: r.error ?? "no_precip_field" });
          processed++;
          continue;
        }
        processed++;

        const { error: rpcErr } = await admin.rpc(
          "upsert_wunderground_rainfall_daily",
          {
            p_vineyard_id: vineyardId,
            p_date: dateStr,
            p_rainfall_mm: r.mm,
            p_station_id: stationId,
            p_station_name: stationName,
          },
        );
        if (rpcErr) {
          perDay.push({ date: dateStr, status: "upsert_error", mm: r.mm });
          errorsCount++;
          console.log(JSON.stringify({
            tag: "wunderground-proxy.backfill.upsert_failed",
            vineyardId, stationId, date: dateStr,
            code: (rpcErr as any).code ?? null,
            message: rpcErr.message ?? null,
          }));
        } else {
          upserted++;
          perDay.push({ date: dateStr, status: "upserted", mm: r.mm });
        }
      }

      const reachedEnd = endIndex >= days;
      const more = !reachedEnd && !rateLimited;
      const nextOffsetDays = more ? endIndex : null;

      return json({
        success: errorsCount === 0,
        days_requested: days,
        days_processed: processed,
        rows_upserted: upserted,
        offset_days: offsetDays,
        chunk_days: chunkDays,
        slice_length: sliceLength,
        next_offset_days: nextOffsetDays,
        more,
        rate_limited: rateLimited,
        errors_count: errorsCount,
        station_id: stationId,
        station_name: stationName,
        timezone,
        proxy_version: PROXY_VERSION,
        attempted_dates: attemptedDates,
        per_day: perDay,
      });
    }

    default:
      return json({ error: `Unknown action: ${action}` }, 400);
  }
});
