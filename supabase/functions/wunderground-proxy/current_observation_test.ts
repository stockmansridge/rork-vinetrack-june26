import { normalizeCurrentObservation, refreshWundergroundCurrent } from "./current_observation.ts";

function expect(condition: unknown, message: string): void {
  if (!condition) throw new Error(message);
}

Deno.test("WU current action fetches official metric observation and upserts shared cache", async () => {
  let written: unknown = null;
  const row = await refreshWundergroundCurrent("vineyard", "PWS123", "Station", "test-key", async (value) => {
    written = value;
    return { error: null };
  }, async (input) => {
    const url = new URL(String(input));
    expect(url.pathname === "/v2/pws/observations/current", "wrong endpoint");
    expect(url.searchParams.get("units") === "m", "metric required");
    expect(url.searchParams.get("stationId") === "PWS123", "wrong station");
    return Response.json({ observations: [{ stationID: "PWS123", obsTimeUtc: "2026-09-23T01:00:00Z",
      humidity: 83, winddir: 275, metric: { temp: 18.3, windSpeed: 12, windGust: 25,
        precipTotal: 4.2, precipRate: 1.1 } }] });
  });
  expect(written === row, "cache write missing");
  expect(row.source === "wunderground_pws" && row.wind_gust_kmh === 25 && row.rain_today_mm === 4.2, "wrong units/fields");
  expect(row.humidity_pct === 83 && row.wind_direction_deg === 275 && row.rain_rate_mm_per_hr === 1.1, "lost weather data");
  expect(row.observed_at === "2026-09-23T01:00:00.000Z", "must keep station timestamp");
  expect(!("apiKey" in row) && !("raw_payload" in row), "credentials/raw payload must not be cached");
});

Deno.test("invalid or unrelated observation does not overwrite a station's cache", async () => {
  let writes = 0;
  const upsert = async () => { writes++; return { error: null }; };
  const fetcher: typeof fetch = async () => Response.json({ observations: [
    { stationID: "OTHER", obsTimeUtc: "2026-09-23T01:00:00Z", metric: { temp: 20 } },
  ] });
  try { await refreshWundergroundCurrent("v", "PWS123", null, "secret", upsert, fetcher); }
  catch (error) { expect((error as Error).message === "no_valid_observation", "unexpected error"); }
  expect(writes === 0, "unrelated station must not overwrite cache");
  expect(normalizeCurrentObservation({ observations: [{ stationID: "PWS123" }] }, "v", "PWS123", null, "2026-09-23T01:00:00Z") === null,
    "missing timestamp must not be replaced by fetch time");
});
