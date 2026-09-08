import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const THIRTY_MINUTES_MS = 30 * 60 * 1000;

type NormalizedObservation = {
  observedAt: string;
  temperatureC: number | null;
  humidityPct: number | null;
  windSpeedKmh: number | null;
  windGustKmh: number | null;
  windDirectionDeg: number | null;
  rainMm: number | null;
  providerRecordId: string;
};
type ProviderResult = { observation: NormalizedObservation | null; definitiveNoData: boolean; mode: "live" | "historical_archive" };
type Integration = { provider: "davis_weatherlink" | "wunderground"; station_id: string | null; station_name: string | null; api_key: string | null; api_secret: string | null };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function num(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}
function fahrenheitToCelsius(value: unknown): number | null {
  const parsed = num(value);
  return parsed === null ? null : (parsed - 32) * 5 / 9;
}
function mphToKmh(value: unknown): number | null {
  const parsed = num(value);
  return parsed === null ? null : parsed * 1.609344;
}
function stationDate(slot: Date, timeZone: string): string {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(slot);
    const part = (type: string): string => parts.find((item) => item.type === type)?.value ?? "";
    return `${part("year")}${part("month")}${part("day")}`;
  } catch {
    return slot.toISOString().slice(0, 10).replaceAll("-", "");
  }
}
function observationTime(record: Record<string, unknown>): Date | null {
  const text = typeof record.obsTimeUtc === "string" ? record.obsTimeUtc : null;
  const epoch = num(record.epoch ?? record.ts);
  const date = text ? new Date(text) : epoch === null ? null : new Date(epoch * 1000);
  return date && Number.isFinite(date.getTime()) ? date : null;
}

export function normalizeWu(record: Record<string, unknown>, stationId: string, historical: boolean): NormalizedObservation | null {
  const observed = observationTime(record);
  if (!observed) return null;
  const metric = record.metric && typeof record.metric === "object" ? record.metric as Record<string, unknown> : {};
  const temperatureC = num(historical ? metric.tempAvg ?? metric.tempHigh ?? metric.tempLow : metric.temp);
  const windSpeedKmh = num(historical ? metric.windspeedAvg ?? metric.windSpeedAvg : metric.windSpeed);
  const windGustKmh = num(historical ? metric.windgustHigh ?? metric.windspeedHigh ?? metric.windGustHigh : metric.windGust);
  const humidityPct = num(historical ? record.humidityAvg ?? record.humidityHigh ?? record.humidityLow : record.humidity);
  const windDirectionDeg = num(historical ? record.winddirAvg : record.winddir);
  const rainMm = historical ? num(metric.precipTotal) : null;
  const epoch = Math.floor(observed.getTime() / 1000);
  return { observedAt: observed.toISOString(), temperatureC, humidityPct, windSpeedKmh, windGustKmh, windDirectionDeg, rainMm, providerRecordId: `wunderground:${stationId}:${epoch}` };
}

async function fetchWu(stationId: string, slot: Date, timeZone: string, apiKey: string): Promise<ProviderResult> {
  const live = Math.abs(Date.now() - slot.getTime()) <= THIRTY_MINUTES_MS;
  const url = new URL(live ? "https://api.weather.com/v2/pws/observations/current" : "https://api.weather.com/v2/pws/history/hourly");
  url.searchParams.set("stationId", stationId);
  url.searchParams.set("format", "json");
  url.searchParams.set("units", "m");
  url.searchParams.set("numericPrecision", "decimal");
  url.searchParams.set("apiKey", apiKey);
  if (!live) url.searchParams.set("date", stationDate(slot, timeZone));
  const response = await fetch(url);
  if (response.status === 204) return { observation: null, definitiveNoData: true, mode: live ? "live" : "historical_archive" };
  if (!response.ok) throw new Error(`Weather Underground HTTP ${response.status}`);
  const payload = await response.json();
  const records: Array<Record<string, unknown>> = Array.isArray(payload?.observations) ? payload.observations : [];
  const nearest = records.map((record) => ({ record, time: observationTime(record) }))
    .filter((entry): entry is { record: Record<string, unknown>; time: Date } => entry.time !== null)
    .map((entry) => ({ ...entry, distance: Math.abs(entry.time.getTime() - slot.getTime()) }))
    .filter((entry) => entry.distance <= THIRTY_MINUTES_MS)
    .sort((left, right) => left.distance - right.distance)[0]?.record;
  return { observation: nearest ? normalizeWu(nearest, stationId, !live) : null, definitiveNoData: !nearest, mode: live ? "live" : "historical_archive" };
}

export function normalizeDavis(payload: Record<string, unknown>, stationId: string, slot: Date, live: boolean): NormalizedObservation | null {
  const sensors: Array<Record<string, unknown>> = Array.isArray(payload.sensors) ? payload.sensors : [];
  const records = sensors.flatMap((sensor) => {
    const lsid = String(sensor.lsid ?? "");
    const data: Array<Record<string, unknown>> = Array.isArray(sensor.data) ? sensor.data : [];
    return data.map((record) => ({ record, lsid, time: observationTime(record) })).filter((entry): entry is { record: Record<string, unknown>; lsid: string; time: Date } => entry.time !== null);
  });
  const nearest = records.map((entry) => ({ ...entry, distance: Math.abs(entry.time.getTime() - slot.getTime()) }))
    .filter((entry) => entry.distance <= THIRTY_MINUTES_MS)
    .sort((left, right) => left.distance - right.distance)[0];
  if (!nearest) return null;
  const epoch = Math.floor(nearest.time.getTime() / 1000);
  const contemporaneous = records.filter((entry) => Math.abs(entry.time.getTime() - nearest.time.getTime()) <= 60_000);
  const first = (...values: unknown[]): number | null => {
    for (const value of values) { const parsed = num(value); if (parsed !== null) return parsed; }
    return null;
  };
  let temperatureC: number | null = null;
  let humidityPct: number | null = null;
  let windSpeedKmh: number | null = null;
  let windGustKmh: number | null = null;
  let windDirectionDeg: number | null = null;
  let rainMm: number | null = null;
  const recordIds: string[] = [];
  for (const entry of contemporaneous) {
    const record = entry.record;
    recordIds.push(entry.lsid);
    temperatureC ??= first(record.temp_c, record.temp_out_c) ?? fahrenheitToCelsius(first(record.temp_out, record.temp));
    humidityPct ??= first(record.hum_out, record.hum, record.hum_last);
    windSpeedKmh ??= first(record.wind_speed_avg_kmh, record.wind_speed_last_kmh, record.wind_speed_kmh) ?? mphToKmh(first(record.wind_speed_avg, record.wind_speed_last, record.wind_speed));
    windGustKmh ??= first(record.wind_speed_hi_kmh, record.wind_speed_hi_last_10_min_kmh) ?? mphToKmh(first(record.wind_speed_hi, record.wind_speed_hi_last_10_min));
    windDirectionDeg ??= first(record.wind_dir_of_prevail, record.wind_dir_last, record.wind_dir);
    if (!live) rainMm ??= first(record.rainfall_mm) ?? ((value: number | null) => value === null ? null : value * 25.4)(first(record.rainfall_in));
  }
  return {
    observedAt: nearest.time.toISOString(), temperatureC, humidityPct, windSpeedKmh, windGustKmh, windDirectionDeg, rainMm,
    providerRecordId: `davis:${stationId}:${epoch}:${[...new Set(recordIds)].sort().join("+")}`,
  };
}

async function fetchDavis(integration: Integration, slot: Date): Promise<ProviderResult> {
  const stationId = String(integration.station_id ?? "");
  const apiKey = String(integration.api_key ?? "");
  const apiSecret = String(integration.api_secret ?? "");
  const live = Math.abs(Date.now() - slot.getTime()) <= THIRTY_MINUTES_MS;
  const url = new URL(`https://api.weatherlink.com/v2/${live ? "current" : "historic"}/${stationId}`);
  url.searchParams.set("api-key", apiKey);
  if (!live) {
    url.searchParams.set("start-timestamp", String(Math.floor((slot.getTime() - THIRTY_MINUTES_MS) / 1000)));
    url.searchParams.set("end-timestamp", String(Math.floor((slot.getTime() + THIRTY_MINUTES_MS) / 1000)));
  }
  const response = await fetch(url, { headers: { "X-Api-Secret": apiSecret, Accept: "application/json" } });
  if (response.status === 204) return { observation: null, definitiveNoData: true, mode: live ? "live" : "historical_archive" };
  if (!response.ok) throw new Error(`Davis WeatherLink HTTP ${response.status}`);
  const payload = await response.json() as Record<string, unknown>;
  const observation = normalizeDavis(payload, stationId, slot, live);
  return { observation, definitiveNoData: observation === null, mode: live ? "live" : "historical_archive" };
}

if (import.meta.main) Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const wuKey = Deno.env.get("WUNDERGROUND_API_KEY") ?? "";
  if (!url || !anon || !service) return json({ error: "Server misconfigured" }, 500);
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return json({ error: "Authentication required" }, 401);
  const user = createClient(url, anon, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await user.auth.getUser();
  if (authError || !authData.user) return json({ error: "Authentication required" }, 401);
  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const tripId = typeof body.tripId === "string" ? body.tripId : "";
  const through = typeof body.through === "string" ? body.through : new Date().toISOString();
  const { data: trip, error: tripError } = await user.from("trips").select("id,vineyard_id,start_time,end_time").eq("id", tripId).is("deleted_at", null).maybeSingle();
  if (tripError || !trip) return json({ error: "Trip not found or access denied" }, 404);
  const { data: membership } = await admin.from("vineyard_members").select("role").eq("vineyard_id", trip.vineyard_id).eq("user_id", authData.user.id).maybeSingle();
  if (!membership || !["owner", "manager", "supervisor", "operator"].includes(String(membership.role))) return json({ error: "Operational vineyard access required" }, 403);
  const { data: slots, error: slotError } = await user.rpc("spray_weather_missing_slots_v1", { p_trip_id: tripId, p_through: through });
  if (slotError) return json({ error: "Unable to resolve weather slots" }, 502);
  const { data: integrations, error: integrationError } = await admin.from("vineyard_weather_integrations")
    .select("provider,station_id,station_name,api_key,api_secret,is_active,updated_at")
    .eq("vineyard_id", trip.vineyard_id).eq("is_active", true).in("provider", ["davis_weatherlink", "wunderground"]);
  if (integrationError) return json({ error: "Unable to resolve configured weather station" }, 502);
  const configured = ((integrations ?? []) as Integration[]).filter((item) => item.station_id).sort((left, right) => left.provider === right.provider ? 0 : left.provider === "davis_weatherlink" ? -1 : 1)[0];
  if (!configured) return json({ success: true, captured: 0, unavailable: 0, pending: slots?.length ?? 0, provider: "not_configured" });
  if (configured.provider === "davis_weatherlink" && (!configured.api_key || !configured.api_secret)) return json({ success: true, captured: 0, unavailable: 0, pending: slots?.length ?? 0, provider: "davis_weatherlink", reason: "configured_credentials_missing" });
  if (configured.provider === "wunderground" && !wuKey) return json({ success: true, captured: 0, unavailable: 0, pending: slots?.length ?? 0, provider: "wunderground", reason: "server_api_key_missing" });
  const { data: vineyard } = await admin.from("vineyards").select("timezone").eq("id", trip.vineyard_id).maybeSingle();
  const timeZone = typeof vineyard?.timezone === "string" && vineyard.timezone ? vineyard.timezone : "UTC";

  let captured = 0;
  let unavailable = 0;
  const errors: string[] = [];
  for (const row of slots ?? []) {
    const slotText = String(row.sample_slot);
    const slot = new Date(slotText);
    try {
      const result = configured.provider === "davis_weatherlink"
        ? await fetchDavis(configured, slot)
        : await fetchWu(String(configured.station_id), slot, timeZone, wuKey);
      const observation = result.observation;
      if (!observation && !result.definitiveNoData) continue;
      const providerLabel = configured.provider === "davis_weatherlink" ? "Davis WeatherLink" : "Weather Underground PWS";
      if (!observation && result.mode === "historical_archive") {
        await admin.rpc("record_trip_weather_retrieval_attempt_v1", {
          p_trip_id: tripId, p_sample_slot: slotText, p_provider: configured.provider,
          p_station_id: configured.station_id, p_station_name: configured.station_name,
          p_retrieval_mode: "historical_archive", p_outcome: "unavailable",
          p_source: `${providerLabel} archive: no qualifying observation`,
        });
      }
      const params = observation ? {
        p_trip_id: tripId, p_sample_slot: slotText, p_observed_at: observation.observedAt,
        p_source: configured.station_name ? `${providerLabel} · ${configured.station_name}` : providerLabel,
        p_source_kind: "observed", p_station_id: String(configured.station_id),
        p_temperature_c: observation.temperatureC, p_humidity_pct: observation.humidityPct,
        p_wind_speed_kmh: observation.windSpeedKmh, p_wind_gust_kmh: observation.windGustKmh,
        p_wind_direction_deg: observation.windDirectionDeg, p_rain_mm: observation.rainMm,
        p_is_stale: false, p_retrieval_mode: result.mode, p_provider_record_id: observation.providerRecordId,
        p_provider: configured.provider, p_station_name: configured.station_name,
      } : {
        p_trip_id: tripId, p_sample_slot: slotText, p_observed_at: null,
        p_source: `${providerLabel} archive: no qualifying observation`, p_source_kind: "unavailable",
        p_station_id: String(configured.station_id), p_temperature_c: null, p_humidity_pct: null,
        p_wind_speed_kmh: null, p_wind_gust_kmh: null, p_wind_direction_deg: null, p_rain_mm: null,
        p_is_stale: false, p_retrieval_mode: "unavailable", p_provider_record_id: null,
        p_provider: configured.provider, p_station_name: configured.station_name,
      };
      const { error } = await admin.rpc("record_trip_weather_observation_v2", params);
      if (error) throw new Error("Weather persistence failed");
      if (observation) captured++; else unavailable++;
    } catch (error) {
      const retrievalMode = Math.abs(Date.now() - slot.getTime()) <= THIRTY_MINUTES_MS ? "live" : "historical_archive";
      await admin.rpc("record_trip_weather_retrieval_attempt_v1", {
        p_trip_id: tripId, p_sample_slot: slotText, p_provider: configured.provider,
        p_station_id: configured.station_id, p_station_name: configured.station_name,
        p_retrieval_mode: retrievalMode, p_outcome: "transient_error",
        p_source: "Provider request or weather persistence failed",
      });
      errors.push(error instanceof Error ? error.message : "Provider request failed");
    }
  }
  return json({ success: errors.length === 0, captured, unavailable, pending: errors.length, provider: configured.provider, stationId: configured.station_id, errors });
});
