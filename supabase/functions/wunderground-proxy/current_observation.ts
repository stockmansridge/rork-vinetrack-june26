export interface CurrentObservation {
  vineyard_id: string;
  source: "wunderground_pws";
  station_id: string;
  station_name: string | null;
  observed_at: string;
  fetched_at: string;
  temperature_c: number | null;
  humidity_pct: number | null;
  wind_speed_kmh: number | null;
  wind_direction_deg: number | null;
  wind_gust_kmh: number | null;
  rain_today_mm: number | null;
  rain_rate_mm_per_hr: number | null;
  leaf_wetness: null;
}

function numberOrNull(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/** Only station-provided timestamps are used; a fetch must not turn old data into fresh data. */
export function normalizeCurrentObservation(
  payload: unknown,
  vineyardId: string,
  stationId: string,
  stationName: string | null,
  fetchedAt: string,
): CurrentObservation | null {
  const observations = (payload as { observations?: unknown })?.observations;
  if (!Array.isArray(observations)) return null;
  const obs = observations.find((o) => o && typeof o === "object" &&
    (o as Record<string, unknown>).stationID === stationId) as Record<string, unknown> | undefined;
  if (!obs) return null;
  const time = obs.obsTimeUtc;
  if (typeof time !== "string" || !Number.isFinite(Date.parse(time))) return null;
  const metric = (obs.metric ?? {}) as Record<string, unknown>;
  return {
    vineyard_id: vineyardId, source: "wunderground_pws", station_id: stationId,
    station_name: stationName, observed_at: new Date(time).toISOString(), fetched_at: fetchedAt,
    temperature_c: numberOrNull(metric.temp), humidity_pct: numberOrNull(obs.humidity),
    wind_speed_kmh: numberOrNull(metric.windSpeed), wind_direction_deg: numberOrNull(obs.winddir),
    wind_gust_kmh: numberOrNull(metric.windGust), rain_today_mm: numberOrNull(metric.precipTotal),
    rain_rate_mm_per_hr: numberOrNull(metric.precipRate), leaf_wetness: null,
  };
}

/** Fetch the official PWS current endpoint and persist a sanitized metric-only observation. */
export async function refreshWundergroundCurrent(
  vineyardId: string,
  stationId: string,
  stationName: string | null,
  apiKey: string,
  upsert: (row: CurrentObservation) => Promise<{ error: { message: string } | null }>,
  fetcher: typeof fetch = fetch,
): Promise<CurrentObservation> {
  const url = new URL("https://api.weather.com/v2/pws/observations/current");
  url.searchParams.set("stationId", stationId);
  url.searchParams.set("format", "json");
  url.searchParams.set("units", "m");
  url.searchParams.set("numericPrecision", "decimal");
  url.searchParams.set("apiKey", apiKey);
  const response = await fetcher(url.toString());
  if (!response.ok) throw new Error(response.status === 429 ? "rate_limited" : "upstream_unavailable");
  const row = normalizeCurrentObservation(await response.json(), vineyardId, stationId, stationName, new Date().toISOString());
  if (!row) throw new Error("no_valid_observation");
  const { error } = await upsert(row);
  if (error) throw new Error("cache_write_failed");
  return row;
}
