import { assertEquals, assertAlmostEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { normalizeDavis, normalizeWu } from "./index.ts";

Deno.test("Weather Underground historical hourly fields normalize separately from current fields", () => {
  const normalized = normalizeWu({ obsTimeUtc: "2026-09-03T22:00:00Z", humidityAvg: 61, winddirAvg: 5, metric: { tempAvg: 15.8, windspeedAvg: 2.1, windgustHigh: 4.3, precipTotal: 0.7, precipRate: 99 } }, "ISTATION", true);
  assertEquals(normalized?.temperatureC, 15.8);
  assertEquals(normalized?.humidityPct, 61);
  assertEquals(normalized?.rainMm, 0.7);
  assertEquals(normalized?.providerRecordId, "wunderground:ISTATION:1788472800");
});

Deno.test("Davis historical archive fields normalize and preserve provider identity", () => {
  const slot = new Date("2026-09-03T22:00:00Z");
  const normalized = normalizeDavis({ sensors: [{ lsid: 654321, data_structure_type: 11, data: [{ ts: 1788472680, temp_out: 60.44, hum_out: 61, wind_speed_avg: 2, wind_speed_hi: 4, wind_dir_of_prevail: 5, rainfall_mm: 0.7 }] }] }, "123456", slot, false);
  assertAlmostEquals(normalized?.temperatureC ?? 0, 15.8, 0.01);
  assertAlmostEquals(normalized?.windSpeedKmh ?? 0, 3.218688, 0.0001);
  assertEquals(normalized?.rainMm, 0.7);
  assertEquals(normalized?.providerRecordId, "davis:123456:1788472680:654321");
});

Deno.test("Davis leaves missing archive values null rather than manufacturing zero", () => {
  const slot = new Date("2026-09-03T22:00:00Z");
  const normalized = normalizeDavis({ sensors: [{ lsid: 1, data_structure_type: 11, data: [{ ts: 1788472800, hum_out: 50 }] }] }, "123456", slot, false);
  assertEquals(normalized?.temperatureC, null);
  assertEquals(normalized?.rainMm, null);
});
