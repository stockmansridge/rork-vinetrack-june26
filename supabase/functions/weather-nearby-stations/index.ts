// Supabase Edge Function: weather-nearby-stations
//
// Returns nearby Weather Underground PWS station IDs for a given lat/lon.
// Keeps the WUNDERGROUND_API_KEY secret server-side.
//
// Request (POST JSON):
//   { "lat": number, "lon": number }
//
// Response 200 JSON:
//   { stations: [{ stationId: string, name?: string, distanceKm?: number }] }

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

function parseNumber(v: any): number | null {
  if (v == null) return null;
  if (typeof v === "number" && isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v);
    return isFinite(n) ? n : null;
  }
  return null;
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
    return json({ error: "Server is missing WUNDERGROUND_API_KEY secret" }, 500);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const lat = parseNumber(body?.lat);
  const lon = parseNumber(body?.lon);
  if (lat == null || lon == null) {
    return json({ error: "Provide lat and lon" }, 400);
  }

  const url =
    `https://api.weather.com/v3/location/near?geocode=${lat.toFixed(5)},${
      lon.toFixed(5)
    }&product=pws&format=json&apiKey=${apiKey}`;

  try {
    const res = await fetch(url);
    if (res.status === 204) return json({ stations: [] });
    if (!res.ok) return json({ error: `Wunderground HTTP ${res.status}` }, 502);
    const data: any = await res.json();
    const location = data?.location ?? {};
    const ids: string[] = location.stationId ?? [];
    const names: string[] = location.stationName ?? [];
    const lats: number[] = location.latitude ?? [];
    const lons: number[] = location.longitude ?? [];

    function haversineKm(la1: number, lo1: number, la2: number, lo2: number): number {
      const R = 6371;
      const dLa = ((la2 - la1) * Math.PI) / 180;
      const dLo = ((lo2 - lo1) * Math.PI) / 180;
      const a = Math.sin(dLa / 2) ** 2 +
        Math.cos((la1 * Math.PI) / 180) *
        Math.cos((la2 * Math.PI) / 180) *
        Math.sin(dLo / 2) ** 2;
      return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
    }

    const stations = ids.map((id, i) => {
      const sLat = lats[i];
      const sLon = lons[i];
      const distanceKm = (typeof sLat === "number" && typeof sLon === "number")
        ? haversineKm(lat, lon, sLat, sLon)
        : undefined;
      return {
        stationId: id,
        name: names[i] ?? null,
        distanceKm,
      };
    });

    return json({ stations });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message }, 502);
  }
});
