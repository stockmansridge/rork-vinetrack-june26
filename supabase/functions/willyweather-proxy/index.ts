// Supabase Edge Function: willyweather-proxy
//
// Optional Australian-focused forecast provider. The WillyWeather API key
// is GLOBAL and lives only in this function's environment as
// WILLYWEATHER_API_KEY. It is never stored per-vineyard and never sent to
// clients. Per-vineyard config (selected location, last_tested_at, etc.)
// lives in `vineyard_weather_integrations` with provider = 'willyweather'.
//
// Auth: caller must send the Supabase JWT in the Authorization header.
//       Owner/Manager role required for `set_location`, `delete`, and
//       `set_provider_preference`. All other actions are available to any
//       vineyard member.
//
// Actions:
//   - test_connection          → tests the global API key
//   - search_locations         → search by query or lat/lon
//   - set_location             → save the vineyard's WillyWeather location
//   - fetch_forecast           → fetch + normalise forecast for the vineyard
//   - delete                   → remove the vineyard's WillyWeather config
//   - get_provider_preference  → read vineyards.forecast_provider
//   - set_provider_preference  → write vineyards.forecast_provider
//
// Deprecated:
//   - save_api_key             → returns 410 Gone. Key is now global.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PROXY_VERSION = "willyweather-proxy-2026-05-17-debug-capabilities";
const WW_BASE = "https://api.willyweather.com.au/v2";
const PROVIDER = "willyweather";

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

function getGlobalApiKey(): string | null {
  const key = Deno.env.get("WILLYWEATHER_API_KEY")?.trim();
  return key && key.length > 0 ? key : null;
}

async function getLocation(admin: any, vineyardId: string): Promise<{ id: string; name: string | null; lat: number | null; lon: number | null } | null> {
  const { data } = await admin
    .from("vineyard_weather_integrations")
    .select("station_id, station_name, station_latitude, station_longitude, is_active")
    .eq("vineyard_id", vineyardId)
    .eq("provider", PROVIDER)
    .maybeSingle();
  if (!data || !data.station_id) return null;
  if (data.is_active === false) return null;
  return {
    id: String(data.station_id),
    name: typeof data.station_name === "string" ? data.station_name : null,
    lat: num(data.station_latitude),
    lon: num(data.station_longitude),
  };
}

// ---------------------------------------------------------------------------
// WillyWeather REST helpers
// ---------------------------------------------------------------------------

async function wwSearch(apiKey: string, query: string): Promise<any> {
  // WillyWeather v2 text search: only `query` + `units` are accepted.
  // Adding `types` / `limit` triggers HTTP 400 on the upstream.
  const u = new URL(`${WW_BASE}/${encodeURIComponent(apiKey)}/search.json`);
  u.searchParams.set("query", query);
  u.searchParams.set("units", "distance:km");
  const res = await fetch(u.toString());
  const body = await res.text();
  let parsed: any = null;
  try { parsed = JSON.parse(body); } catch { /* fall through */ }
  return { status: res.status, ok: res.ok, body: parsed ?? body };
}

async function wwSearchByCoords(apiKey: string, lat: number, lon: number): Promise<any> {
  const u = new URL(`${WW_BASE}/${encodeURIComponent(apiKey)}/search.json`);
  u.searchParams.set("lat", String(lat));
  u.searchParams.set("lng", String(lon));
  u.searchParams.set("units", "distance:km");
  const res = await fetch(u.toString());
  const body = await res.text();
  let parsed: any = null;
  try { parsed = JSON.parse(body); } catch { /* fall through */ }
  return { status: res.status, ok: res.ok, body: parsed ?? body };
}

// Reverse-geocode fallback via OpenStreetMap Nominatim. We use this when
// WillyWeather's coordinate search returns no usable locations — we derive
// candidate town/suburb/locality names from the GPS centre and then text-search
// each one against WillyWeather until we find a match.
async function reverseGeocodeCandidates(lat: number, lon: number): Promise<string[]> {
  try {
    const u = new URL("https://nominatim.openstreetmap.org/reverse");
    u.searchParams.set("format", "jsonv2");
    u.searchParams.set("lat", String(lat));
    u.searchParams.set("lon", String(lon));
    u.searchParams.set("zoom", "12");
    u.searchParams.set("addressdetails", "1");
    const res = await fetch(u.toString(), {
      headers: { "User-Agent": "VineTrack/1.0 (willyweather-proxy)" },
    });
    if (!res.ok) return [];
    const j: any = await res.json();
    const a = j?.address ?? {};
    const names = [
      a.town, a.village, a.suburb, a.city, a.hamlet, a.municipality,
      a.county, a.state_district, a.locality,
    ].filter((s: unknown) => typeof s === "string" && (s as string).length > 0) as string[];
    // Dedupe while preserving order.
    const seen = new Set<string>();
    const out: string[] = [];
    for (const n of names) {
      const k = n.toLowerCase();
      if (!seen.has(k)) { seen.add(k); out.push(n); }
    }
    return out;
  } catch {
    return [];
  }
}

function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const R = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}

async function wwForecast(apiKey: string, locationId: string, days: number): Promise<any> {
  const u = new URL(`${WW_BASE}/${encodeURIComponent(apiKey)}/locations/${encodeURIComponent(locationId)}/weather.json`);
  u.searchParams.set("forecasts", "rainfall,temperature,wind,rainfallprobability");
  u.searchParams.set("days", String(Math.max(1, Math.min(days, 7))));
  u.searchParams.set("units", "speed:km/h,temperature:c,distance:km");
  const res = await fetch(u.toString());
  const body = await res.text();
  let parsed: any = null;
  try { parsed = JSON.parse(body); } catch { /* fall through */ }
  return { status: res.status, ok: res.ok, body: parsed ?? body };
}

// ---------------------------------------------------------------------------
// Forecast normalisation
// ---------------------------------------------------------------------------

function rainfallMidpoint(entry: any): number | null {
  const s = num(entry?.startRange);
  const e = num(entry?.endRange);
  if (s != null && e != null) return (s + e) / 2;
  if (e != null) return e / 2;
  if (s != null) return s;
  return null;
}

function estimateET0(tmin: number | null, tmax: number | null): number | null {
  if (tmin == null || tmax == null || tmax <= tmin) return null;
  const tmean = (tmin + tmax) / 2;
  const ra = 15;
  const et0 = 0.0023 * (tmean + 17.8) * Math.sqrt(tmax - tmin) * (ra / 2.45);
  return Math.max(0, Math.round(et0 * 100) / 100);
}

function normaliseForecast(raw: any, days: number): { ok: true; days: any[] } | { ok: false; error: string } {
  const forecasts = raw?.forecasts;
  if (!forecasts || typeof forecasts !== "object") {
    return { ok: false, error: "missing_forecasts" };
  }

  type DayBucket = { date: string; rainMm: number | null; probability: number | null; tmin: number | null; tmax: number | null; windKmh: number | null };
  const byDate: Record<string, DayBucket> = {};

  function bucket(dateTime: string): DayBucket {
    const date = String(dateTime).slice(0, 10);
    if (!byDate[date]) byDate[date] = { date, rainMm: null, probability: null, tmin: null, tmax: null, windKmh: null };
    return byDate[date];
  }

  const rainDays = forecasts?.rainfall?.days;
  if (Array.isArray(rainDays)) {
    for (const d of rainDays) {
      const b = bucket(String(d?.dateTime ?? ""));
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      if (entries.length > 0) {
        b.rainMm = rainfallMidpoint(entries[0]);
      }
    }
  }

  const probDays = forecasts?.rainfallprobability?.days;
  if (Array.isArray(probDays)) {
    for (const d of probDays) {
      const b = bucket(String(d?.dateTime ?? ""));
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      if (entries.length > 0) {
        b.probability = num(entries[0]?.probability);
      }
    }
  }

  const tempDays = forecasts?.temperature?.days;
  if (Array.isArray(tempDays)) {
    for (const d of tempDays) {
      const b = bucket(String(d?.dateTime ?? ""));
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      let lo: number | null = null;
      let hi: number | null = null;
      for (const e of entries) {
        const t = num(e?.temperature);
        if (t == null) continue;
        if (lo == null || t < lo) lo = t;
        if (hi == null || t > hi) hi = t;
      }
      b.tmin = lo;
      b.tmax = hi;
    }
  }

  const windDays = forecasts?.wind?.days;
  if (Array.isArray(windDays)) {
    for (const d of windDays) {
      const b = bucket(String(d?.dateTime ?? ""));
      const entries = Array.isArray(d?.entries) ? d.entries : [];
      let maxSpd: number | null = null;
      for (const e of entries) {
        const s = num(e?.speed);
        if (s == null) continue;
        if (maxSpd == null || s > maxSpd) maxSpd = s;
      }
      b.windKmh = maxSpd;
    }
  }

  const sorted = Object.values(byDate).sort((a, b) => a.date.localeCompare(b.date)).slice(0, days);
  const out = sorted.map((b) => ({
    date: b.date,
    rain_mm: b.rainMm,
    rain_probability: b.probability,
    temp_min_c: b.tmin,
    temp_max_c: b.tmax,
    wind_kmh_max: b.windKmh,
    et0_mm: estimateET0(b.tmin, b.tmax),
  }));
  return { ok: true, days: out };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

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
  const role = String(memberRow.role);
  const canEdit = role === "owner" || role === "manager";

  // The WillyWeather API key is global and required for any provider call.
  const apiKey = getGlobalApiKey();

  switch (action) {
    case "save_api_key": {
      // Deprecated — key is global, set as WILLYWEATHER_API_KEY secret.
      return json({
        error: "save_api_key is no longer supported. WillyWeather uses a global API key managed by VineTrack.",
        deprecated: true,
      }, 410);
    }

    case "set_location": {
      if (!canEdit) return json({ error: "Owner or manager role required" }, 403);
      if (!apiKey) return json({ error: "WillyWeather is not available right now." }, 503);
      const locationId = body?.locationId != null ? String(body.locationId) : "";
      if (!locationId) return json({ error: "locationId is required" }, 400);
      const locationName = typeof body?.locationName === "string" ? body.locationName : null;
      const lat = num(body?.latitude);
      const lon = num(body?.longitude);

      const { error: saveErr } = await admin.rpc("save_vineyard_weather_integration", {
        p_vineyard_id: vineyardId,
        p_provider: PROVIDER,
        p_api_key: null,
        p_api_secret: null,
        p_station_id: locationId,
        p_station_name: locationName,
        p_station_latitude: lat,
        p_station_longitude: lon,
        p_has_leaf_wetness: null,
        p_has_rain: true,
        p_has_wind: true,
        p_has_temperature_humidity: true,
        p_detected_sensors: null,
        p_last_tested_at: new Date().toISOString(),
        p_last_test_status: "ok",
        p_is_active: true,
      });
      if (saveErr) return json({ error: saveErr.message }, 500);
      return json({ success: true, locationId, locationName });
    }

    case "delete": {
      if (!canEdit) return json({ error: "Owner or manager role required" }, 403);
      const { error: delErr } = await admin.rpc("delete_vineyard_weather_integration", {
        p_vineyard_id: vineyardId,
        p_provider: PROVIDER,
      });
      if (delErr) return json({ error: delErr.message }, 500);
      return json({ success: true });
    }

    case "test_connection": {
      if (!apiKey) {
        return json({
          success: false,
          error: "WillyWeather is not available — global API key not configured.",
        }, 503);
      }
      const r = await wwSearch(apiKey, "Sydney");
      return json({ success: r.ok, http_status: r.status });
    }

    case "search_locations": {
      if (!apiKey) {
        return json({
          error: "WillyWeather is not available — global API key not configured.",
          reason: "missing_global_api_key",
        }, 503);
      }
      const query = typeof body?.query === "string" ? body.query.trim() : "";
      // Accept both `lon` (preferred) and `lng` (legacy) for resilience.
      const lat = num(body?.lat);
      const lon = num(body?.lon ?? body?.lng);

      function normaliseList(raw: any, originLat: number | null, originLon: number | null): any[] {
        const rawList = Array.isArray(raw?.location)
          ? raw.location
          : (Array.isArray(raw) ? raw : []);
        const list = rawList.map((loc: any) => {
          const lt = num(loc?.lat);
          const ln = num(loc?.lng);
          let dist = num(loc?.distance);
          if (dist == null && lt != null && ln != null && originLat != null && originLon != null) {
            dist = Math.round(haversineKm(originLat, originLon, lt, ln) * 10) / 10;
          }
          return {
            id: String(loc?.id ?? ""),
            name: typeof loc?.name === "string" ? loc.name : "",
            region: typeof loc?.region === "string" ? loc.region : null,
            state: typeof loc?.state === "string" ? loc.state : null,
            postcode: typeof loc?.postcode === "string" ? loc.postcode : null,
            latitude: lt,
            longitude: ln,
            distanceKm: dist,
          };
        }).filter((l: any) => l.id.length > 0);
        if (originLat != null && originLon != null) {
          list.sort((a: any, b: any) => {
            const da = a.distanceKm ?? Number.POSITIVE_INFINITY;
            const db = b.distanceKm ?? Number.POSITIVE_INFINITY;
            return da - db;
          });
        }
        return list;
      }

      // Manual text search.
      if (query.length > 0) {
        const r = await wwSearch(apiKey, query);
        if (!r.ok) {
          return json({
            error: "WillyWeather search failed",
            reason: "willyweather_rejected",
            mode: "query",
            http_status: r.status,
            upstream: r.body,
          }, 502);
        }
        return json({ success: true, mode: "query", locations: normaliseList(r.body, lat, lon) });
      }

      // Coordinate / nearest-town search.
      if (lat == null || lon == null) {
        return json({ error: "query or lat/lon required", reason: "missing_params" }, 400);
      }

      // 1) Direct coordinate search via WillyWeather.
      const direct = await wwSearchByCoords(apiKey, lat, lon);
      if (direct.ok) {
        const locations = normaliseList(direct.body, lat, lon);
        if (locations.length > 0) {
          return json({ success: true, mode: "coords", locations });
        }
      }

      // 2) Fallback: reverse-geocode the GPS centre into nearby town names
      //    and text-search each one until WillyWeather returns matches.
      const candidates = await reverseGeocodeCandidates(lat, lon);
      const attempts: Array<{ name: string; http_status: number; matches: number }> = [];
      const merged: any[] = [];
      const seenIds = new Set<string>();

      for (const name of candidates) {
        const r = await wwSearch(apiKey, name);
        attempts.push({ name, http_status: r.status, matches: 0 });
        if (!r.ok) continue;
        const found = normaliseList(r.body, lat, lon);
        attempts[attempts.length - 1].matches = found.length;
        for (const loc of found) {
          if (!seenIds.has(loc.id)) {
            seenIds.add(loc.id);
            merged.push(loc);
          }
        }
        if (merged.length >= 5) break;
      }

      if (merged.length > 0) {
        merged.sort((a, b) => (a.distanceKm ?? Infinity) - (b.distanceKm ?? Infinity));
        return json({
          success: true,
          mode: "nearest_town",
          locations: merged,
          fallback: { strategy: "reverse_geocode", candidates, attempts },
        });
      }

      // No match anywhere.
      return json({
        success: false,
        mode: "coords",
        locations: [],
        error: "No WillyWeather forecast location found near these coordinates.",
        reason: "no_nearest_match",
        http_status: direct.status,
        upstream: direct.ok ? null : direct.body,
        fallback: { strategy: "reverse_geocode", candidates, attempts },
      }, 200);
    }

    case "fetch_forecast": {
      if (!apiKey) {
        return json({ error: "WillyWeather is not available — global API key not configured." }, 503);
      }
      const loc = await getLocation(admin, vineyardId);
      if (!loc) return json({ error: "WillyWeather location is not selected for this vineyard." }, 400);

      const daysReq = num(body?.days) ?? 5;
      const days = Math.max(1, Math.min(Math.floor(daysReq), 7));
      const r = await wwForecast(apiKey, loc.id, days);
      if (!r.ok) {
        return json({
          error: "WillyWeather forecast failed",
          http_status: r.status,
        }, 502);
      }
      const norm = normaliseForecast(r.body, days);
      if (!norm.ok) {
        return json({ error: "WillyWeather forecast could not be parsed", reason: norm.error }, 502);
      }
      return json({
        success: true,
        source: "WillyWeather",
        location_id: loc.id,
        location_name: loc.name,
        days: norm.days,
      });
    }

    case "debug_capabilities": {
      // System-admin / debugging only. Probes the WillyWeather API for the
      // configured vineyard location to determine which forecast and
      // observational fields are actually available on the current API plan.
      // Used to decide whether Disease Risk Advisor can source hourly
      // temperature / RH / dew point / rainfall / wind from WillyWeather
      // instead of falling back to Open-Meteo.
      if (!apiKey) {
        return json({ error: "WillyWeather is not available — global API key not configured." }, 503);
      }
      const loc = await getLocation(admin, vineyardId);
      if (!loc) return json({ error: "WillyWeather location is not selected for this vineyard." }, 400);

      // Candidate forecast types to probe. WillyWeather rejects the whole
      // request if any unsupported type is included, so we probe each
      // independently and record which succeed.
      const forecastTypes = [
        "rainfall",
        "rainfallprobability",
        "temperature",
        "wind",
        "weather",
        "precis",
        "uv",
        "sunrisesunset",
        "dewpoint",
        "humidity",
        "relativehumidity",
      ];

      const forecastResults: Array<Record<string, unknown>> = [];
      let combined: any = null;

      for (const t of forecastTypes) {
        const u = new URL(`${WW_BASE}/${encodeURIComponent(apiKey)}/locations/${encodeURIComponent(loc.id)}/weather.json`);
        u.searchParams.set("forecasts", t);
        u.searchParams.set("days", "2");
        u.searchParams.set("units", "speed:km/h,temperature:c,distance:km");
        const res = await fetch(u.toString());
        const text = await res.text();
        let parsed: any = null;
        try { parsed = JSON.parse(text); } catch { /* keep raw */ }
        const days = parsed?.forecasts?.[t]?.days;
        const firstDay = Array.isArray(days) ? days[0] : null;
        const entries = Array.isArray(firstDay?.entries) ? firstDay.entries : [];
        const entryCount = entries.length;
        const sampleEntry = entries[0] ?? null;
        const sampleKeys = sampleEntry && typeof sampleEntry === "object"
          ? Object.keys(sampleEntry as Record<string, unknown>)
          : [];
        // Estimate interval (minutes) from first two entries if dateTime present.
        let intervalMinutes: number | null = null;
        if (entries.length >= 2) {
          const d0 = Date.parse(String(entries[0]?.dateTime ?? ""));
          const d1 = Date.parse(String(entries[1]?.dateTime ?? ""));
          if (isFinite(d0) && isFinite(d1) && d1 > d0) {
            intervalMinutes = Math.round((d1 - d0) / 60000);
          }
        }
        forecastResults.push({
          type: t,
          http_status: res.status,
          ok: res.ok,
          available: res.ok && entryCount > 0,
          first_day_entry_count: entryCount,
          interval_minutes: intervalMinutes,
          sample_entry: sampleEntry,
          sample_keys: sampleKeys,
          error_message: res.ok ? null : (parsed?.error?.description ?? parsed?.error ?? text.slice(0, 200)),
        });
      }

      // Also fetch the standard combined call we use today for comparison.
      const combinedRes = await wwForecast(apiKey, loc.id, 2);
      combined = {
        http_status: combinedRes.status,
        ok: combinedRes.ok,
        forecast_keys: combinedRes.ok && combinedRes.body?.forecasts && typeof combinedRes.body.forecasts === "object"
          ? Object.keys(combinedRes.body.forecasts)
          : [],
      };

      // Probe observational endpoint (real-time values; useful for current
      // RH / dew point even if forecast does not expose them).
      const obsUrl = new URL(`${WW_BASE}/${encodeURIComponent(apiKey)}/locations/${encodeURIComponent(loc.id)}/weather.json`);
      obsUrl.searchParams.set("observational", "true");
      obsUrl.searchParams.set("units", "speed:km/h,temperature:c,distance:km");
      const obsRes = await fetch(obsUrl.toString());
      const obsText = await obsRes.text();
      let obsParsed: any = null;
      try { obsParsed = JSON.parse(obsText); } catch { /* keep raw */ }
      const obs = obsParsed?.observational ?? null;
      const observational = {
        http_status: obsRes.status,
        ok: obsRes.ok,
        station_name: obs?.stations?.[0]?.name ?? null,
        station_distance_km: num(obs?.stations?.[0]?.distance),
        observation_keys: obs?.observations && typeof obs.observations === "object"
          ? Object.keys(obs.observations)
          : [],
        sample: obs?.observations ?? null,
      };

      // Disease Risk Advisor decision summary.
      const has = (t: string) => forecastResults.find((r) => r.type === t && r.available === true) != null;
      const summary = {
        has_forecast_temperature: has("temperature"),
        has_forecast_rainfall: has("rainfall"),
        has_forecast_rainfall_probability: has("rainfallprobability"),
        has_forecast_wind: has("wind"),
        has_forecast_dewpoint: has("dewpoint"),
        has_forecast_humidity: has("humidity") || has("relativehumidity"),
        has_observational_dewpoint: typeof observational.sample?.dewPoint !== "undefined"
          || typeof observational.sample?.["dewpoint"] !== "undefined",
        has_observational_humidity: typeof observational.sample?.humidity !== "undefined"
          || typeof observational.sample?.["relativeHumidity"] !== "undefined",
      };
      const recommendation = (summary.has_forecast_temperature
          && summary.has_forecast_rainfall
          && (summary.has_forecast_dewpoint || summary.has_forecast_humidity))
        ? "willyweather_can_drive_disease_risk"
        : "keep_open_meteo_for_disease_risk";

      return json({
        success: true,
        location: { id: loc.id, name: loc.name, latitude: loc.lat, longitude: loc.lon },
        forecast_probes: forecastResults,
        combined_forecast_call: combined,
        observational,
        summary,
        recommendation,
      });
    }

    case "get_provider_preference": {
      const { data, error } = await admin
        .from("vineyards")
        .select("forecast_provider")
        .eq("id", vineyardId)
        .maybeSingle();
      if (error) return json({ error: error.message }, 500);
      const provider = (data?.forecast_provider as string | null) ?? "auto";
      return json({ success: true, provider });
    }

    case "set_provider_preference": {
      if (!canEdit) return json({ error: "Owner or manager role required" }, 403);
      const provider = typeof body?.provider === "string" ? body.provider : "";
      if (!["auto", "open_meteo", "willyweather"].includes(provider)) {
        return json({ error: "provider must be one of auto, open_meteo, willyweather" }, 400);
      }
      const { error } = await admin
        .from("vineyards")
        .update({ forecast_provider: provider, updated_at: new Date().toISOString() })
        .eq("id", vineyardId);
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, provider });
    }

    default:
      return json({ error: `Unknown action: ${action}` }, 400);
  }
});
