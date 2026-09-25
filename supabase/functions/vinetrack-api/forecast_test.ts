// deno-lint-ignore-file no-import-prefix
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { normaliseApiWillyWeatherForecast } from "./forecast.ts";
import { normaliseForecast } from "../willyweather-proxy/forecast.ts";

Deno.test("API keeps first-period legacy midpoint while sharing genuine multi-period range and probability", () => {
  const dateTime = "2026-09-25T00:00:00+10:00";
  const raw = { forecasts: {
    rainfall: { days: [{ dateTime, entries: [
      { dateTime, startRange: 0, endRange: 1 },
      { dateTime: "2026-09-25T04:00:00+10:00", startRange: 1, endRange: 3 },
      { dateTime: "2026-09-25T04:00:00+10:00", startRange: 1, endRange: 3 },
    ] }] },
    rainfallprobability: { days: [{ dateTime, entries: [
      { probability: 20 }, { probability: 75 },
    ] }] },
    temperature: { days: [{ dateTime, entries: [{ dateTime, temperature: 11 }, { dateTime, temperature: 24 }] }] },
    wind: { days: [{ dateTime, entries: [{ dateTime, speed: 20 }] }] },
  } };
  const weather = { forecasts: { weather: { days: [{ dateTime, entries: [{ precis: "Partly cloudy" }] }] } } };
  const options = { weather };
  const proxy = normaliseForecast(raw, 7, { optionalForecasts: options });
  const api = normaliseApiWillyWeatherForecast(raw, 7, options)?.[0];
  assertEquals(proxy.ok, true);
  if (!proxy.ok) throw Error("Unexpected fixture failure");
  assertEquals(api?.rain_mm, 0.5);
  assertEquals(api?.rain_min_mm, 1);
  assertEquals(api?.rain_max_mm, 4);
  assertEquals(api?.rain_min_mm, proxy.days[0].rain_min_mm);
  assertEquals(api?.rain_max_mm, proxy.days[0].rain_max_mm);
  assertEquals(api?.rain_probability_percent, proxy.days[0].rain_probability);
  assertEquals(api?.condition_key, "partly_cloudy");
  assertEquals(api?.condition_description, "Partly cloudy");
  assertEquals(api?.temp_min_c, 11);
  assertEquals(api?.temp_max_c, 24);
  assertEquals(api?.wind_speed_max_kmh, 20);
});
