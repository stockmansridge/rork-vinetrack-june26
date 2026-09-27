package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class ForecastParityContractTest {
    @Test fun willyWeatherRetainsProviderFactsAndVineyardCalendarDay() {
        // Controlled range exercise, not a claim about the live Stockmans Ridge rain payload.
        val response = SupabaseClient.json.decodeFromString(
            WillyWeatherForecastResult.serializer(),
            """{"source":"WillyWeather","timezone":"Australia/Sydney","days":[{"date":"2026-09-24","precis":"Partly cloudy","precisCode":"partly-cloudy","condition_key":"partly_cloudy","temp_min_c":11,"temp_max_c":24,"wind_kmh_max":20,"rain_mm":1,"rain_min_mm":0,"rain_max_mm":1,"rain_probability":10}],"rollingRain":{"next24hMm":2.4,"next48hMm":7.2,"source":"Open-Meteo"}}""",
        )
        val day = response.days.single().toRainDay(response.timezone)!!
        assertEquals("Partly cloudy", day.condition)
        assertEquals("partly_cloudy", day.conditionKey)
        assertEquals(0.0, day.rainMinMm!!, 0.0001)
        assertEquals(1.0, day.rainMaxMm!!, 0.0001)
        assertEquals(10.0, day.rainProbabilityPct!!, 0.0001)
        assertEquals(11.0, day.tempMinC!!, 0.0001)
        assertEquals(24.0, day.tempMaxC!!, 0.0001)
        assertEquals(20.0, day.windKmhMax!!, 0.0001)
        assertEquals(2.4, response.rollingRain!!.next24hMm!!, 0.0001)
        assertEquals(7.2, response.rollingRain!!.next48hMm!!, 0.0001)
        assertEquals("Open-Meteo", response.rollingRain!!.source)
        assertEquals("WillyWeather", response.source)
        assertEquals("24", SimpleDateFormat("dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("Australia/Sydney") }.format(Date(day.dateEpochMs)))
        assertEquals("23", SimpleDateFormat("dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("America/Los_Angeles") }.format(Date(day.dateEpochMs)))
    }

    @Test fun missingPrimaryConditionUsesDetailCodeAndKeepsWillyWeatherDailyFacts() {
        val response = SupabaseClient.json.decodeFromString(
            WillyWeatherForecastResult.serializer(),
            """{"source":"WillyWeather","timezone":"Australia/Sydney","days":[{"date":"2026-09-24","temp_min_c":10,"temp_max_c":21,"wind_kmh_max":23,"rain_mm":9,"rain_min_mm":0,"rain_max_mm":2,"rain_probability":30},{"date":"2026-09-25","precis":"Willy showers","condition_key":"rain"},{"date":"2026-09-26","precisCode":"cloudy"}],"rollingRain":{"next24hMm":null,"next48hMm":null}}""",
        )
        val detail = SprayForecastPeriodRepository.openMeteo(
            """{"timezone":"Australia/Sydney","daily":{"time":["2026-09-24","2026-09-25","2026-09-26"],"weather_code":[51,3,51]},"hourly":{"time":[]}}""",
        )
        val days = OpenMeteoDailyCondition.supplement(response.days.mapNotNull { it.toRainDay(response.timezone) }, detail.third, TimeZone.getTimeZone("Australia/Sydney"))
        assertEquals("Drizzle", days[0].condition)
        assertEquals("drizzle", days[0].conditionKey)
        assertEquals("Open-Meteo", days[0].conditionSource)
        assertEquals(10.0, days[0].tempMinC!!, 0.0001)
        assertEquals(21.0, days[0].tempMaxC!!, 0.0001)
        assertEquals(23.0, days[0].windKmhMax!!, 0.0001)
        assertEquals(0.0, days[0].rainMinMm!!, 0.0001)
        assertEquals(2.0, days[0].rainMaxMm!!, 0.0001)
        assertEquals(30.0, days[0].rainProbabilityPct!!, 0.0001)
        assertEquals("Willy showers", days[1].condition)
        assertEquals("WillyWeather", days[1].conditionSource)
        assertNull(days[2].condition)
        assertEquals("cloudy", days[2].conditionCode)
        assertEquals("Overcast", detail.third["2026-09-25"]?.description)
        assertEquals("WillyWeather", response.source)
        assertEquals(9.0, days[0].rainMm, 0.0001)
        assertNull(response.rollingRain?.next24hMm)
        assertNull(response.rollingRain?.next48hMm)
    }

    @Test fun fiveSuppliedReferenceDaysRetainConditionTemperatureAndWind() {
        // No rainfall/probability assumption: real values require the provider payload.
        val dates = listOf("24", "25", "26", "27", "28")
        val lows = listOf(11, 13, 13, 13, 10)
        val highs = listOf(24, 25, 27, 23, 20)
        val winds = listOf(20, 20, 17, 19, 19)
        val conditions = listOf("Partly cloudy", "Partly cloudy", "Partly cloudy", "Cloudy", "Cloudy")
        val days = dates.indices.map { index ->
            WillyWeatherForecastDay(
                date = "2026-09-${dates[index]}", precis = conditions[index],
                conditionKey = if (index < 3) "partly_cloudy" else "cloudy",
                tempMinC = lows[index].toDouble(), tempMaxC = highs[index].toDouble(),
                windKmhMax = winds[index].toDouble(),
            ).toRainDay("Australia/Sydney")!!
        }
        assertEquals(5, days.size)
        dates.indices.forEach { index ->
            assertEquals(conditions[index], days[index].condition)
            assertEquals(lows[index].toDouble(), days[index].tempMinC!!, 0.0001)
            assertEquals(highs[index].toDouble(), days[index].tempMaxC!!, 0.0001)
            assertEquals(winds[index].toDouble(), days[index].windKmhMax!!, 0.0001)
            assertNull(days[index].rainMinMm)
        }
    }
}
