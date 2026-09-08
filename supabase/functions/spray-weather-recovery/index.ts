import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
function json(body: unknown, status = 200): Response { return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } }); }
function num(value: unknown): number | null { const parsed = typeof value === "number" ? value : Number(value); return Number.isFinite(parsed) ? parsed : null; }
type Observation = { obsTimeUtc?: string; epoch?: number; humidity?: number; winddir?: number; metric?: { temp?: number; windSpeed?: number; windGust?: number; precipRate?: number } };
async function fetchWu(stationId: string, slot: Date, apiKey: string): Promise<{ observation: Observation | null; definitiveNoData: boolean; mode: "live" | "historical_archive" }> {
  const isLive = Math.abs(Date.now() - slot.getTime()) <= 30 * 60 * 1000;
  const url = new URL(isLive ? "https://api.weather.com/v2/pws/observations/current" : "https://api.weather.com/v2/pws/history/hourly");
  url.searchParams.set("stationId", stationId); url.searchParams.set("format", "json"); url.searchParams.set("units", "m"); url.searchParams.set("numericPrecision", "decimal"); url.searchParams.set("apiKey", apiKey);
  if (!isLive) url.searchParams.set("date", slot.toISOString().slice(0, 10).replaceAll("-", ""));
  const response = await fetch(url);
  if (response.status === 204) return { observation: null, definitiveNoData: true, mode: isLive ? "live" : "historical_archive" };
  if (!response.ok) throw new Error(`Weather Underground HTTP ${response.status}`);
  const payload = await response.json();
  const observations: Observation[] = Array.isArray(payload?.observations) ? payload.observations : [];
  const nearest = observations.map((observation) => ({ observation, distance: Math.abs(new Date(observation.obsTimeUtc ?? (Number(observation.epoch) * 1000)).getTime() - slot.getTime()) })).filter((entry) => Number.isFinite(entry.distance) && entry.distance <= 30 * 60 * 1000).sort((left, right) => left.distance - right.distance)[0]?.observation ?? null;
  return { observation: nearest, definitiveNoData: nearest === null, mode: isLive ? "live" : "historical_archive" };
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL") ?? ""; const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? ""; const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""; const wuKey = Deno.env.get("WUNDERGROUND_API_KEY") ?? "";
  if (!url || !anon || !service) return json({ error: "Server misconfigured" }, 500);
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return json({ error: "Authentication required" }, 401);
  const user = createClient(url, anon, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const admin = createClient(url, service, { auth: { persistSession: false } });
  const { data: authData, error: authError } = await user.auth.getUser(); if (authError || !authData.user) return json({ error: "Authentication required" }, 401);
  let body: Record<string, unknown>; try { body = await request.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const tripId = typeof body.tripId === "string" ? body.tripId : ""; const through = typeof body.through === "string" ? body.through : new Date().toISOString();
  const { data: trip, error: tripError } = await user.from("trips").select("id,vineyard_id,start_time,end_time").eq("id", tripId).is("deleted_at", null).maybeSingle();
  if (tripError || !trip) return json({ error: "Trip not found or access denied" }, 404);
  const { data: membership } = await admin.from("vineyard_members").select("role").eq("vineyard_id", trip.vineyard_id).eq("user_id", authData.user.id).is("deleted_at", null).maybeSingle();
  if (!membership || !["owner", "manager", "supervisor", "operator"].includes(membership.role)) return json({ error: "Operational vineyard access required" }, 403);
  const { data: slots, error: slotError } = await user.rpc("spray_weather_missing_slots_v1", { p_trip_id: tripId, p_through: through });
  if (slotError) return json({ error: "Unable to resolve weather slots" }, 502);
  const { data: integration } = await admin.from("vineyard_weather_integrations").select("station_id,station_name,is_active").eq("vineyard_id", trip.vineyard_id).eq("provider", "wunderground").eq("is_active", true).maybeSingle();
  if (!integration?.station_id || !wuKey) return json({ success: true, captured: 0, unavailable: 0, pending: slots?.length ?? 0, provider: "not_configured" });
  let captured = 0; let unavailable = 0; const errors: string[] = [];
  for (const row of slots ?? []) {
    const slotText = String(row.sample_slot); const slot = new Date(slotText);
    try {
      const result = await fetchWu(String(integration.station_id), slot, wuKey);
      const observation = result.observation;
      if (!observation && !result.definitiveNoData) continue;
      const observedAt = observation?.obsTimeUtc ?? (observation?.epoch ? new Date(observation.epoch * 1000).toISOString() : null);
      const metric = observation?.metric ?? {};
      const params = observation ? {
        p_trip_id: tripId, p_sample_slot: slotText, p_observed_at: observedAt, p_source: integration.station_name ? `Weather Underground PWS · ${integration.station_name}` : "Weather Underground PWS", p_source_kind: "observed", p_station_id: String(integration.station_id), p_temperature_c: num(metric.temp), p_humidity_pct: num(observation.humidity), p_wind_speed_kmh: num(metric.windSpeed), p_wind_gust_kmh: num(metric.windGust), p_wind_direction_deg: num(observation.winddir), p_rain_mm: num(metric.precipRate), p_is_stale: false, p_retrieval_mode: result.mode, p_provider_record_id: observedAt,
      } : {
        p_trip_id: tripId, p_sample_slot: slotText, p_observed_at: null, p_source: "Weather Underground archive: no observation", p_source_kind: "unavailable", p_station_id: String(integration.station_id), p_temperature_c: null, p_humidity_pct: null, p_wind_speed_kmh: null, p_wind_gust_kmh: null, p_wind_direction_deg: null, p_rain_mm: null, p_is_stale: false, p_retrieval_mode: "unavailable", p_provider_record_id: null,
      };
      const { error } = await admin.rpc("record_trip_weather_observation_v2", params); if (error) throw error;
      if (observation) captured++; else unavailable++;
    } catch (error) { errors.push(error instanceof Error ? error.message : "Provider request failed"); }
  }
  return json({ success: errors.length === 0, captured, unavailable, pending: errors.length, provider: "wunderground_pws", errors });
});
