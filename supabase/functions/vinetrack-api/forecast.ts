// Public API projection of the shared WillyWeather normaliser. The existing
// rain_mm field is a legacy compatibility value, not the provider's range.
// deno-lint-ignore-file no-explicit-any
import { normaliseForecast } from "../willyweather-proxy/forecast.ts";

export interface ForecastDay {
  date: string;
  /** Legacy /v1/weather value: midpoint of the first rainfall period only. */
  rain_mm: number | null;
  rain_min_mm: number | null;
  rain_max_mm: number | null;
  rain_probability_percent: number | null;
  condition_key: string | null;
  condition_description: string | null;
  temp_min_c: number | null;
  temp_max_c: number | null;
  wind_speed_max_kmh: number | null;
  et0_mm: number | null;
}

function legacyMidpoint(entry: any): number | null {
  const start = entry?.startRange == null ? null : Number(entry.startRange);
  const end = entry?.endRange == null ? null : Number(entry.endRange);
  const lower = start != null && Number.isFinite(start) ? start : null;
  const upper = end != null && Number.isFinite(end) ? end : null;
  if (lower != null && upper != null) return (lower + upper) / 2;
  if (upper != null) return upper / 2;
  return lower;
}

/** Project canonical ranges and provider condition while retaining the legacy API amount. */
export function normaliseApiWillyWeatherForecast(
  raw: any,
  days: number,
  optionalForecasts: Record<string, any> = {},
): ForecastDay[] | null {
  const normalised = normaliseForecast(raw, days, { includeDetail: true, optionalForecasts });
  if (!normalised.ok || normalised.days.length === 0) return null;
  const firstEntryByDate = new Map<string, any>();
  const rainDays = raw?.forecasts?.rainfall?.days;
  for (const day of Array.isArray(rainDays) ? rainDays : []) {
    const date = typeof day?.dateTime === "string" ? day.dateTime.slice(0, 10) : "";
    if (!firstEntryByDate.has(date)) firstEntryByDate.set(date, day?.entries?.[0]);
  }
  return normalised.days.map((day): ForecastDay => ({
    date: day.date,
    rain_mm: legacyMidpoint(firstEntryByDate.get(day.date)),
    rain_min_mm: day.rain_min_mm,
    rain_max_mm: day.rain_max_mm,
    rain_probability_percent: day.rain_probability,
    condition_key: day.condition_key ?? null,
    condition_description: day.precis ?? null,
    temp_min_c: day.temp_min_c,
    temp_max_c: day.temp_max_c,
    wind_speed_max_kmh: day.wind_kmh_max,
    et0_mm: day.et0_mm,
  }));
}
