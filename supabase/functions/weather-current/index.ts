// Supabase Edge Function: weather-current
//
// Fetches current PWS observations from Weather Underground using a
// server-side WUNDERGROUND_API_KEY secret. Keeps the API key off the
// device.
//
// Request (POST JSON):
//   { "lat": number, "lon": number, "stationId"?: string }
//
// Response 200 JSON:
//   {
//     temperatureC: number | null,
//     windSpeedKmh: number | null,
//     windDirection: string,
//     humidityPercent: number | null,
//     observedAt: string (ISO8601),
//     stationId: string | null,
//     source: "Weather Underground PWS"
//   }
//
// Errors return { error: string } with appropriate HTTP status.

// deno-lint-ignore-file no-explicit-any

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function compassDirection(deg: number): string {
  const dirs = [
    "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
    "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
  ];
  const n = ((deg % 360) + 360) % 360;
  return dirs[Math.round(n / 22.5) % 16];
}

function parseNumber(v: any): number | null {
  if (v == null) return null;
  if (typeof v === "number" && isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v);
    return isFinite(n) ? n : null;
  }
  return null;
}

async function nearestStationId(
  lat: number,
  lon: number,
  apiKey: string,
): Promise<string> {
  const url =
    `https://api.weather.com/v3/location/near?geocode=${lat.toFixed(5)},${
      lon.toFixed(5)
    }&product=pws&format=json&apiKey=${apiKey}`;
  const res = await fetch(url);
  if (res.status === 204) throw new Error("No nearby weather station found");
  if (!res.ok) throw new Error(`Wunderground HTTP ${res.status}`);
  const data: any = await res.json();
  const ids: string[] | undefined = data?.location?.stationId;
  if (!ids || ids.length === 0) {
    throw new Error("No nearby weather station found");
  }
  return ids[0];
}

async function currentObservation(
  stationId: string,
  apiKey: string,
): Promise<Response> {
  const url =
    `https://api.weather.com/v2/pws/observations/current?stationId=${stationId}&format=json&units=m&numericPrecision=decimal&apiKey=${apiKey}`;
  const res = await fetch(url);
  if (res.status === 204) {
    return json({ error: "No current observations" }, 404);
  }
  if (!res.ok) {
    return json({ error: `Wunderground HTTP ${res.status}` }, 502);
  }
  const data: any = await res.json();
  const obs = data?.observations?.[0];
  if (!obs) return json({ error: "No current observations" }, 404);

  const metric = obs.metric ?? {};
  const tempC = parseNumber(metric.temp) ?? parseNumber(obs.temp);
  const windKmh = parseNumber(metric.windSpeed) ?? parseNumber(obs.windSpeed);
  const humidity = parseNumber(obs.humidity) ?? parseNumber(metric.humidity);
  const winddirDeg = parseNumber(obs.winddir) ?? parseNumber(metric.winddir);
  const windDirection = winddirDeg != null ? compassDirection(winddirDeg) : "";
  const observedAt = typeof obs.obsTimeUtc === "string"
    ? obs.obsTimeUtc
    : new Date().toISOString();

  return json({
    temperatureC: tempC,
    windSpeedKmh: windKmh,
    windDirection,
    humidityPercent: humidity,
    observedAt,
    stationId,
    source: "Weather Underground PWS",
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const apiKey = Deno.env.get("WUNDERGROUND_API_KEY") ?? "";
  if (!apiKey) {
    return json(
      { error: "Server is missing WUNDERGROUND_API_KEY secret" },
      500,
    );
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const lat = parseNumber(body?.lat);
  const lon = parseNumber(body?.lon);
  const requestedStation = typeof body?.stationId === "string"
    ? body.stationId
    : null;

  if (!requestedStation && (lat == null || lon == null)) {
    return json({ error: "Provide stationId or lat/lon" }, 400);
  }

  try {
    const stationId = requestedStation && requestedStation.length > 0
      ? requestedStation
      : await nearestStationId(lat!, lon!, apiKey);
    return await currentObservation(stationId, apiKey);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message }, 502);
  }
});
