// deno-lint-ignore-file no-import-prefix
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { aggregateRainfallEntries, normaliseForecast } from "./forecast.ts";

const timestamp0 = "2026-09-23T00:00:00+10:00";
const timestamp1 = "2026-09-23T04:00:00+10:00";

function coreFixture() {
  return {
    apiKey: "must-never-be-returned",
    location: { id: 123, name: "Stockmans Ridge", timeZone: "Australia/Sydney" },
    forecasts: {
      rainfall: {
        days: [{
          dateTime: timestamp0,
          entries: [{ dateTime: timestamp0, startRange: 1, endRange: 2 }],
        }],
      },
      rainfallprobability: {
        days: [{
          dateTime: timestamp0,
          entries: [
            { dateTime: timestamp0, probability: 35 },
            { dateTime: timestamp1, probability: 60 },
          ],
        }],
      },
      temperature: {
        days: [{
          dateTime: timestamp0,
          entries: [
            { dateTime: timestamp0, temperature: 10.2, providerOnly: "discard" },
            { dateTime: timestamp1, temperature: 14.8 },
          ],
        }],
      },
      wind: {
        days: [{
          dateTime: timestamp0,
          entries: [
            { dateTime: timestamp0, speed: 7.2, direction: 180, directionText: "S", gustSpeed: 11.1 },
            { dateTime: timestamp1, speed: 12.4 },
          ],
        }],
      },
    },
  };
}

function requiredDailyFields(day: Record<string, unknown>): string[] {
  return Object.keys(day).sort();
}

Deno.test("daily response remains the mobile contract when includeDetail is absent", () => {
  const result = normaliseForecast(coreFixture(), 5);
  assert(result.ok);
  assertEquals(requiredDailyFields(result.days[0] as unknown as Record<string, unknown>), [
    "date",
    "et0_mm",
    "rain_mm",
    "rain_probability",
    "temp_max_c",
    "temp_min_c",
    "wind_kmh_max",
  ]);
  assertEquals(result.days[0].rain_mm, 2);
  assertEquals(result.days[0].rain_probability, 60);
  assertEquals(result.days[0].temp_min_c, 10.2);
  assertEquals(result.days[0].temp_max_c, 14.8);
  assertEquals(result.days[0].wind_kmh_max, 12.4);
});

Deno.test("includeDetail false is identical to an omitted detail flag", () => {
  const omitted = normaliseForecast(coreFixture(), 5);
  const explicit = normaliseForecast(coreFixture(), 5, { includeDetail: false });
  assert(omitted.ok && explicit.ok);
  assertEquals(explicit, omitted);
});

Deno.test("detail returns only genuine temperature entries and preserves timestamps", () => {
  const result = normaliseForecast(coreFixture(), 5, { includeDetail: true });
  assert(result.ok);
  assertEquals(result.days[0].temperatureEntries, [
    { dateTime: timestamp0, temperature: 10.2 },
    { dateTime: timestamp1, temperature: 14.8 },
  ]);
});

Deno.test("detail returns genuine wind entries with clean optional provider fields", () => {
  const result = normaliseForecast(coreFixture(), 5, { includeDetail: true });
  assert(result.ok);
  assertEquals(result.days[0].windEntries, [
    { dateTime: timestamp0, speed: 7.2, direction: 180, directionText: "S", gust: 11.1 },
    { dateTime: timestamp1, speed: 12.4 },
  ]);
});

Deno.test("unsupported humidity leaves the core forecast successful", () => {
  const result = normaliseForecast(coreFixture(), 5, {
    includeDetail: true,
    optionalForecasts: {},
  });
  assert(result.ok);
  assertEquals(result.days[0].humidityEntries, []);
  assertEquals(result.detailAvailability?.humidity, false);
  assertEquals(result.days[0].temperatureEntries?.length, 2);
});

Deno.test("relativehumidity is accepted only through an obvious humidity field", () => {
  const relative = {
    forecasts: {
      relativehumidity: {
        days: [{ dateTime: timestamp0, entries: [{ dateTime: timestamp0, relativeHumidity: 83 }] }],
      },
    },
  };
  const result = normaliseForecast(coreFixture(), 5, {
    includeDetail: true,
    optionalForecasts: { relativehumidity: relative },
  });
  assert(result.ok);
  assertEquals(result.days[0].humidityEntries, [{ dateTime: timestamp0, humidity: 83 }]);
});

Deno.test("unsupported weather and precis leave the core forecast successful", () => {
  const result = normaliseForecast(coreFixture(), 5, {
    includeDetail: true,
    optionalForecasts: { weather: {}, precis: {} },
  });
  assert(result.ok);
  assertEquals(result.days[0].precis, undefined);
  assertEquals(result.days[0].precisCode, undefined);
  assertEquals(result.days[0].wind_kmh_max, 12.4);
});

Deno.test("weather provides genuine condition text and code without deriving from temperature", () => {
  const weather = {
    forecasts: {
      weather: {
        days: [{
          dateTime: timestamp0,
          entries: [{ dateTime: timestamp0, precis: "Partly cloudy", precisCode: "partly-cloudy" }],
        }],
      },
    },
  };
  const result = normaliseForecast(coreFixture(), 5, {
    includeDetail: true,
    optionalForecasts: { weather },
  });
  assert(result.ok);
  assertEquals(result.days[0].precis, "Partly cloudy");
  assertEquals(result.days[0].precisCode, "partly-cloudy");
});

Deno.test("multiple rainfall periods sum upper bounds and duplicate periods are not counted twice", () => {
  const entries = [
    { dateTime: timestamp0, startRange: 0.2, endRange: 1 },
    { dateTime: timestamp1, startRange: 1, endRange: 3 },
    { dateTime: timestamp1, startRange: 1, endRange: 3 },
  ];
  assertEquals(aggregateRainfallEntries(entries), 4);
});

Deno.test("daily probability is the maximum across forecast periods", () => {
  const result = normaliseForecast(coreFixture(), 5);
  assert(result.ok);
  assertEquals(result.days[0].rain_probability, 60);
});

Deno.test("detail contains no fabricated six-point series", () => {
  const result = normaliseForecast(coreFixture(), 5, { includeDetail: true });
  assert(result.ok);
  assertEquals(result.days[0].temperatureEntries?.length, 2);
  assertEquals(result.days[0].windEntries?.length, 2);
});

Deno.test("provider timezone is returned only for detail and secrets are never projected", () => {
  const daily = normaliseForecast(coreFixture(), 5);
  const detailed = normaliseForecast(coreFixture(), 5, { includeDetail: true });
  assert(daily.ok && detailed.ok);
  assertEquals(daily.timezone, undefined);
  assertEquals(detailed.timezone, "Australia/Sydney");
  assertEquals(detailed.providerLocation, {
    id: 123,
    name: "Stockmans Ridge",
    timezone: "Australia/Sydney",
  });
  assert(!JSON.stringify(detailed).includes("must-never-be-returned"));
});
