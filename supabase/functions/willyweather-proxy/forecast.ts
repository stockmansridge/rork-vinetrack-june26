// Pure WillyWeather forecast normalisation. Kept separate from the Edge Function
// handler so provider fixtures can be tested without starting Deno.serve.

// deno-lint-ignore-file no-explicit-any

export interface ForecastNormaliseOptions {
  includeDetail?: boolean;
  optionalForecasts?: Record<string, any>;
}

export interface NormalisedForecastDay {
  date: string;
  rain_mm: number | null;
  rain_probability: number | null;
  temp_min_c: number | null;
  temp_max_c: number | null;
  wind_kmh_max: number | null;
  et0_mm: number | null;
  temperatureEntries?: Array<Record<string, unknown>>;
  windEntries?: Array<Record<string, unknown>>;
  humidityEntries?: Array<Record<string, unknown>>;
  precis?: string;
  precisCode?: string;
  rainfall_mm?: number | null;
  probability_pct?: number | null;
  wind_max_kmh?: number | null;
}

export interface NormalisedForecast {
  ok: true;
  days: NormalisedForecastDay[];
  timezone?: string;
  detailAvailability?: Record<string, boolean>;
  providerLocation?: Record<string, unknown>;
}

export interface ForecastNormaliseFailure {
  ok: false;
  error: string;
}

function num(value: unknown): number | null {
  if (value == null) return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

function dateKey(value: unknown): string | null {
  const raw = text(value);
  if (!raw) return null;
  const date = raw.slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : null;
}

function forecastDays(raw: any, type: string): any[] {
  const days = raw?.forecasts?.[type]?.days;
  return Array.isArray(days) ? days : [];
}

function entriesForDay(day: any): any[] {
  return Array.isArray(day?.entries) ? day.entries : [];
}

/** WillyWeather rainfall forecasts are ranges; VineTrack uses the conservative upper bound. */
export function rainfallUpperBound(entry: any): number | null {
  const upper = num(entry?.endRange);
  if (upper != null) return Math.max(0, upper);
  const lower = num(entry?.startRange);
  if (lower != null) return Math.max(0, lower);
  const amount = num(entry?.amount ?? entry?.rainfall);
  return amount == null ? null : Math.max(0, amount);
}

/** Sum distinct forecast periods. Duplicate timestamps are one provider period, not extra rain. */
export function aggregateRainfallEntries(entries: any[]): number | null {
  const distinct = new Map<string, any>();
  entries.forEach((entry: any, index: number) => {
    const key = text(entry?.dateTime) ?? `untimed:${index}`;
    if (!distinct.has(key)) distinct.set(key, entry);
  });
  let total = 0;
  let count = 0;
  for (const entry of distinct.values()) {
    const amount = rainfallUpperBound(entry);
    if (amount == null) continue;
    total += amount;
    count += 1;
  }
  return count > 0 ? Math.round(total * 100) / 100 : null;
}

function estimateET0(tmin: number | null, tmax: number | null): number | null {
  if (tmin == null || tmax == null || tmax <= tmin) return null;
  const tmean = (tmin + tmax) / 2;
  const ra = 15;
  const et0 = 0.0023 * (tmean + 17.8) * Math.sqrt(tmax - tmin) * (ra / 2.45);
  return Math.max(0, Math.round(et0 * 100) / 100);
}

function timezoneFrom(...payloads: any[]): string | undefined {
  for (const payload of payloads) {
    const zone = text(payload?.location?.timeZone ?? payload?.location?.timezone ?? payload?.timeZone ?? payload?.timezone);
    if (zone) return zone;
  }
  return undefined;
}

function providerLocationFrom(raw: any): Record<string, unknown> | undefined {
  const location = raw?.location;
  if (!location || typeof location !== "object") return undefined;
  const output: Record<string, unknown> = {};
  const id = num(location.id);
  const name = text(location.name);
  const region = text(location.region);
  const state = text(location.state);
  const postcode = text(location.postcode);
  const timezone = text(location.timeZone ?? location.timezone);
  const latitude = num(location.lat ?? location.latitude);
  const longitude = num(location.lng ?? location.longitude);
  if (id != null) output.id = id;
  if (name) output.name = name;
  if (region) output.region = region;
  if (state) output.state = state;
  if (postcode) output.postcode = postcode;
  if (timezone) output.timezone = timezone;
  if (latitude != null) output.latitude = latitude;
  if (longitude != null) output.longitude = longitude;
  return Object.keys(output).length > 0 ? output : undefined;
}

function temperatureEntries(entries: any[]): Array<Record<string, unknown>> {
  return entries.flatMap((entry: any) => {
    const dateTime = text(entry?.dateTime);
    const temperature = num(entry?.temperature);
    return dateTime && temperature != null ? [{ dateTime, temperature }] : [];
  });
}

function windEntries(entries: any[]): Array<Record<string, unknown>> {
  return entries.flatMap((entry: any) => {
    const dateTime = text(entry?.dateTime);
    const speed = num(entry?.speed);
    if (!dateTime || speed == null) return [];
    const item: Record<string, unknown> = { dateTime, speed };
    const direction = num(entry?.direction);
    const directionText = text(entry?.directionText);
    const gust = num(entry?.gust ?? entry?.gustSpeed);
    if (direction != null) item.direction = direction;
    if (directionText) item.directionText = directionText;
    if (gust != null) item.gust = gust;
    return [item];
  });
}

function humidityEntries(entries: any[]): Array<Record<string, unknown>> {
  return entries.flatMap((entry: any) => {
    const dateTime = text(entry?.dateTime);
    const humidity = num(entry?.humidity ?? entry?.relativeHumidity ?? entry?.percentage);
    return dateTime && humidity != null ? [{ dateTime, humidity }] : [];
  });
}

function firstCondition(entries: any[]): { precis?: string; precisCode?: string } {
  for (const entry of entries) {
    const precis = text(entry?.precis ?? entry?.description ?? entry?.weather);
    const precisCode = text(entry?.precisCode ?? entry?.code);
    if (precis || precisCode) return {
      ...(precis ? { precis } : {}),
      ...(precisCode ? { precisCode } : {}),
    };
  }
  return {};
}

function optionalPayload(options: ForecastNormaliseOptions, type: string): any {
  return options.optionalForecasts?.[type] ?? null;
}

/**
 * Preserve the original daily contract and add genuine provider entries only
 * when detail is requested. Timestamps are copied verbatim; no interpolation or
 * timezone conversion is performed.
 */
export function normaliseForecast(
  raw: any,
  days: number,
  options: ForecastNormaliseOptions = {},
): NormalisedForecast | ForecastNormaliseFailure {
  const forecasts = raw?.forecasts;
  if (!forecasts || typeof forecasts !== "object") {
    return { ok: false, error: "missing_forecasts" };
  }

  interface DayBucket {
    date: string;
    rainMm: number | null;
    probability: number | null;
    tmin: number | null;
    tmax: number | null;
    windKmh: number | null;
    temperatureEntries: Array<Record<string, unknown>>;
    windEntries: Array<Record<string, unknown>>;
    humidityEntries: Array<Record<string, unknown>>;
    precis?: string;
    precisCode?: string;
  }

  const byDate = new Map<string, DayBucket>();
  const bucket = (value: unknown): DayBucket | null => {
    const date = dateKey(value);
    if (!date) return null;
    const existing = byDate.get(date);
    if (existing) return existing;
    const created: DayBucket = {
      date,
      rainMm: null,
      probability: null,
      tmin: null,
      tmax: null,
      windKmh: null,
      temperatureEntries: [],
      windEntries: [],
      humidityEntries: [],
    };
    byDate.set(date, created);
    return created;
  };

  for (const day of forecastDays(raw, "rainfall")) {
    const target = bucket(day?.dateTime);
    if (target) target.rainMm = aggregateRainfallEntries(entriesForDay(day));
  }

  for (const day of forecastDays(raw, "rainfallprobability")) {
    const target = bucket(day?.dateTime);
    if (!target) continue;
    const probabilities = entriesForDay(day)
      .map((entry: any) => num(entry?.probability))
      .filter((value: number | null): value is number => value != null);
    target.probability = probabilities.length > 0 ? Math.max(...probabilities) : null;
  }

  for (const day of forecastDays(raw, "temperature")) {
    const target = bucket(day?.dateTime);
    if (!target) continue;
    const genuineEntries = temperatureEntries(entriesForDay(day));
    const values = genuineEntries.map((entry) => entry.temperature as number);
    target.tmin = values.length > 0 ? Math.min(...values) : null;
    target.tmax = values.length > 0 ? Math.max(...values) : null;
    if (options.includeDetail) target.temperatureEntries = genuineEntries;
  }

  for (const day of forecastDays(raw, "wind")) {
    const target = bucket(day?.dateTime);
    if (!target) continue;
    const genuineEntries = windEntries(entriesForDay(day));
    const values = genuineEntries.map((entry) => entry.speed as number);
    target.windKmh = values.length > 0 ? Math.max(...values) : null;
    if (options.includeDetail) target.windEntries = genuineEntries;
  }

  if (options.includeDetail) {
    const existingBucket = (value: unknown): DayBucket | null => {
      const date = dateKey(value);
      return date ? byDate.get(date) ?? null : null;
    };
    const hasHumidity = forecastDays(optionalPayload(options, "humidity"), "humidity").length > 0;
    const humidityPayload = hasHumidity
      ? optionalPayload(options, "humidity")
      : optionalPayload(options, "relativehumidity");
    const humidityType = hasHumidity ? "humidity" : "relativehumidity";
    for (const day of forecastDays(humidityPayload, humidityType)) {
      const target = existingBucket(day?.dateTime);
      if (target) target.humidityEntries = humidityEntries(entriesForDay(day));
    }

    for (const type of ["weather", "precis"]) {
      const payload = optionalPayload(options, type);
      for (const day of forecastDays(payload, type)) {
        const target = existingBucket(day?.dateTime);
        if (!target) continue;
        const condition = firstCondition(entriesForDay(day));
        if (!target.precis && condition.precis) target.precis = condition.precis;
        if (!target.precisCode && condition.precisCode) target.precisCode = condition.precisCode;
      }
    }
  }

  const selected = [...byDate.values()]
    .sort((left, right) => left.date.localeCompare(right.date))
    .slice(0, Math.max(1, days));

  const normalisedDays: NormalisedForecastDay[] = selected.map((value) => {
    const daily: NormalisedForecastDay = {
      date: value.date,
      rain_mm: value.rainMm,
      rain_probability: value.probability,
      temp_min_c: value.tmin,
      temp_max_c: value.tmax,
      wind_kmh_max: value.windKmh,
      et0_mm: estimateET0(value.tmin, value.tmax),
    };
    if (!options.includeDetail) return daily;
    return {
      ...daily,
      rainfall_mm: value.rainMm,
      probability_pct: value.probability,
      wind_max_kmh: value.windKmh,
      temperatureEntries: value.temperatureEntries,
      windEntries: value.windEntries,
      humidityEntries: value.humidityEntries,
      ...(value.precis ? { precis: value.precis } : {}),
      ...(value.precisCode ? { precisCode: value.precisCode } : {}),
    };
  });

  if (!options.includeDetail) return { ok: true, days: normalisedDays };

  const optionals = options.optionalForecasts ?? {};
  const humidityAvailable = forecastDays(optionals.humidity, "humidity").length > 0 ||
    forecastDays(optionals.relativehumidity, "relativehumidity").length > 0;
  const detailAvailability: Record<string, boolean> = {
    temperature: forecastDays(raw, "temperature").length > 0,
    wind: forecastDays(raw, "wind").length > 0,
    rainfall: forecastDays(raw, "rainfall").length > 0,
    rainfallprobability: forecastDays(raw, "rainfallprobability").length > 0,
    humidity: humidityAvailable,
    weather: forecastDays(optionals.weather, "weather").length > 0,
    precis: forecastDays(optionals.precis, "precis").length > 0,
    dewpoint: forecastDays(optionals.dewpoint, "dewpoint").length > 0,
  };
  const timezone = timezoneFrom(raw, ...Object.values(optionals));
  const providerLocation = providerLocationFrom(raw);
  return {
    ok: true,
    days: normalisedDays,
    ...(timezone ? { timezone } : {}),
    ...(providerLocation ? { providerLocation } : {}),
    detailAvailability,
  };
}
