// Supabase Edge Function: open-meteo-proxy
//
// Lowest-priority rainfall gap-fill from the Open-Meteo Archive API.
// Open-Meteo is free and requires no API key. This proxy runs server-side
// so the device never calls Open-Meteo directly and so we can enforce the
// "never overwrite Manual / Davis / Weather Underground" rule centrally.
//
// Auth: caller must send the Supabase JWT in the Authorization header.
// Owner/Manager role required for backfill_rainfall_gaps.
//
// Request (POST JSON):
//   {
//     "vineyardId": "<uuid>",
//     "action": "backfill_rainfall_gaps",
//     "days"?:    number,            // default 365, max 5 * 365 = 1825
//     "timezone"?: string,           // IANA tz, default 'Australia/Sydney'
//     "lat"?: number, "lon"?: number // optional manual override
//   }
//
// Behaviour:
//   * Resolves vineyard coordinates server-side (see resolveVineyardCoords).
//   * Skips today and yesterday (archive data may be incomplete).
//   * Fetches Open-Meteo Archive precipitation_sum for the whole window in
//     a single call (Archive API supports multi-day ranges natively).
//   * For each day in the response:
//       - skip if Manual / Davis / Weather Underground already has data
//       - skip if Open-Meteo returned no value
//       - otherwise call upsert_open_meteo_rainfall_daily(...)
//
// Response 200 JSON:
//   {
//     success, days_requested, days_processed, rows_upserted,
//     days_skipped_better_source, days_skipped_no_data, errors_count,
//     from_date, to_date, latitude, longitude, timezone, proxy_version
//   }
//
// Writes: only source = 'open_meteo' rows via
// public.upsert_open_meteo_rainfall_daily(...). Never touches Manual,
// Davis, or Weather Underground rows.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive";
const PROXY_VERSION = "open-meteo-gapfill-2026-05-07";
const DEFAULT_DAYS = 365;
const MAX_DAYS = 5 * 365; // 5 years
const DEFAULT_TZ = "Australia/Sydney";

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

function subtractDays(yyyyMmDd: string, days: number, timezone: string): string {
  const base = new Date(yyyyMmDd + "T12:00:00Z");
  const stepped = new Date(base.getTime() - days * 86400000);
  return localDateString(stepped, timezone);
}

// Resolve vineyard coordinates server-side. Order:
//   1. Explicit body.lat/body.lon (rare; mainly for ops/testing)
//   2. Any vineyard_weather_integrations.station_latitude/station_longitude
//      for this vineyard (Davis or Weather Underground station).
//   3. Centroid of paddocks.polygon_points (averaged across all paddocks).
//   4. Centroid of pins.latitude/longitude.
async function resolveVineyardCoords(
  admin: any,
  vineyardId: string,
  body: any,
): Promise<{ lat: number; lon: number; source: string } | { error: string }> {
  const explicitLat = num(body?.lat);
  const explicitLon = num(body?.lon);
  if (explicitLat != null && explicitLon != null) {
    return { lat: explicitLat, lon: explicitLon, source: "request" };
  }

  // 2. Weather integration station coordinates.
  const { data: integs } = await admin
    .from("vineyard_weather_integrations")
    .select("provider, station_latitude, station_longitude")
    .eq("vineyard_id", vineyardId);
  if (Array.isArray(integs)) {
    // Prefer Davis, then Weather Underground, then anything else.
    const order = ["davis", "wunderground"];
    const sorted = [...integs].sort((a: any, b: any) => {
      const ai = order.indexOf(String(a.provider));
      const bi = order.indexOf(String(b.provider));
      return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
    });
    for (const it of sorted) {
      const la = num(it.station_latitude);
      const lo = num(it.station_longitude);
      if (la != null && lo != null) {
        return { lat: la, lon: lo, source: `integration:${it.provider}` };
      }
    }
  }

  // 3. Paddock polygon centroid.
  const { data: paddocks } = await admin
    .from("paddocks")
    .select("polygon_points")
    .eq("vineyard_id", vineyardId)
    .is("deleted_at", null);
  if (Array.isArray(paddocks) && paddocks.length > 0) {
    let sumLat = 0, sumLon = 0, count = 0;
    for (const p of paddocks) {
      const pts = (p as any).polygon_points;
      if (!Array.isArray(pts)) continue;
      for (const pt of pts) {
        const la = num(pt?.latitude);
        const lo = num(pt?.longitude);
        if (la != null && lo != null) {
          sumLat += la; sumLon += lo; count++;
        }
      }
    }
    if (count > 0) {
      return { lat: sumLat / count, lon: sumLon / count, source: "paddocks" };
    }
  }

  // 4. Pin centroid.
  const { data: pins } = await admin
    .from("pins")
    .select("latitude, longitude")
    .eq("vineyard_id", vineyardId)
    .is("deleted_at", null);
  if (Array.isArray(pins) && pins.length > 0) {
    let sumLat = 0, sumLon = 0, count = 0;
    for (const p of pins as any[]) {
      const la = num(p.latitude);
      const lo = num(p.longitude);
      if (la != null && lo != null) {
        sumLat += la; sumLon += lo; count++;
      }
    }
    if (count > 0) {
      return { lat: sumLat / count, lon: sumLon / count, source: "pins" };
    }
  }

  return { error: "Vineyard coordinates are required to fetch Open-Meteo rainfall" };
}

async function fetchOpenMeteoDailyPrecip(
  lat: number,
  lon: number,
  fromDate: string,
  toDate: string,
  timezone: string,
): Promise<
  | { ok: true; dates: string[]; precip: (number | null)[] }
  | { ok: false; status: number; error: string }
> {
  const u = new URL(ARCHIVE_URL);
  u.searchParams.set("latitude", lat.toFixed(5));
  u.searchParams.set("longitude", lon.toFixed(5));
  u.searchParams.set("start_date", fromDate);
  u.searchParams.set("end_date", toDate);
  u.searchParams.set("daily", "precipitation_sum");
  u.searchParams.set("timezone", timezone);

  let res: Response;
  try {
    res = await fetch(u.toString());
  } catch (e) {
    return { ok: false, status: 0, error: e instanceof Error ? e.message : String(e) };
  }
  if (!res.ok) {
    return { ok: false, status: res.status, error: `http_${res.status}` };
  }
  let data: any = null;
  try { data = await res.json(); } catch {
    return { ok: false, status: 200, error: "invalid_json" };
  }
  const dates: string[] = Array.isArray(data?.daily?.time) ? data.daily.time : [];
  const precip: (number | null)[] = Array.isArray(data?.daily?.precipitation_sum)
    ? data.daily.precipitation_sum.map((v: any) => num(v))
    : [];
  if (dates.length === 0) {
    return { ok: false, status: 200, error: "no_daily_data" };
  }
  return { ok: true, dates, precip };
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

  switch (action) {
    case "backfill_rainfall_gaps": {
      if (role !== "owner" && role !== "manager") {
        return json({ error: "Owner or manager role required" }, 403);
      }

      const requestedDays = Number(body.days);
      const days = isFinite(requestedDays) && requestedDays > 0
        ? Math.min(MAX_DAYS, Math.floor(requestedDays))
        : DEFAULT_DAYS;
      const timezone = typeof body.timezone === "string" && body.timezone
        ? body.timezone
        : DEFAULT_TZ;

      const coords = await resolveVineyardCoords(admin, vineyardId, body);
      if ("error" in coords) {
        return json({ error: coords.error }, 400);
      }

      // Skip today and yesterday — archive may be incomplete.
      const todayLocal = localDateString(new Date(), timezone);
      const toDate = subtractDays(todayLocal, 2, timezone);
      const fromDate = subtractDays(todayLocal, 1 + days, timezone);

      // 1. Pull "better source" days in one query.
      const { data: betterRows, error: betterErr } = await admin.rpc(
        "days_with_better_rainfall_source",
        {
          p_vineyard_id: vineyardId,
          p_from_date: fromDate,
          p_to_date: toDate,
        },
      );
      if (betterErr) return json({ error: betterErr.message }, 500);
      const betterSet = new Set<string>(
        Array.isArray(betterRows)
          ? betterRows.map((r: any) => String(r.date).slice(0, 10))
          : [],
      );

      // 2. Pull the whole window from Open-Meteo Archive in one call.
      const om = await fetchOpenMeteoDailyPrecip(
        coords.lat, coords.lon, fromDate, toDate, timezone,
      );
      if (!om.ok) {
        return json({
          success: false,
          error: `open_meteo_${om.error}`,
          http_status: om.status,
          from_date: fromDate, to_date: toDate,
          latitude: coords.lat, longitude: coords.lon,
          coords_source: coords.source,
          timezone,
        }, 502);
      }

      let processed = 0;
      let upserted = 0;
      let skippedBetter = 0;
      let skippedNoData = 0;
      let errorsCount = 0;

      for (let i = 0; i < om.dates.length; i++) {
        const dateStr = String(om.dates[i]).slice(0, 10);
        const mm = om.precip[i];
        processed++;

        if (betterSet.has(dateStr)) {
          skippedBetter++;
          continue;
        }
        if (mm == null) {
          skippedNoData++;
          continue;
        }

        const { data: rpcOut, error: rpcErr } = await admin.rpc(
          "upsert_open_meteo_rainfall_daily",
          {
            p_vineyard_id: vineyardId,
            p_date: dateStr,
            p_rainfall_mm: Math.round(mm * 100) / 100,
          },
        );
        if (rpcErr) {
          errorsCount++;
          console.log(JSON.stringify({
            tag: "open-meteo-proxy.upsert_failed",
            vineyardId, date: dateStr,
            code: (rpcErr as any).code ?? null,
            message: rpcErr.message ?? null,
          }));
          continue;
        }
        if (rpcOut === "skipped_better_source") {
          skippedBetter++;
        } else {
          upserted++;
        }
      }

      return json({
        success: errorsCount === 0,
        days_requested: days,
        days_processed: processed,
        rows_upserted: upserted,
        days_skipped_better_source: skippedBetter,
        days_skipped_no_data: skippedNoData,
        errors_count: errorsCount,
        from_date: fromDate,
        to_date: toDate,
        latitude: coords.lat,
        longitude: coords.lon,
        coords_source: coords.source,
        timezone,
        proxy_version: PROXY_VERSION,
      });
    }

    default:
      return json({ error: `Unknown action: ${action}` }, 400);
  }
});
