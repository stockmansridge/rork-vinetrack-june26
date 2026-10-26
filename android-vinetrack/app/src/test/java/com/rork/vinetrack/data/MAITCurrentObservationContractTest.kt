package com.rork.vinetrack.data

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class MAITCurrentObservationContractTest {
    @Test fun explicitMAITDoesNotBecomeAutomaticFallback() {
        assertEquals("mait_intelliweb", CurrentObservationRepository.resolvedSource("mait_intelliweb", "davis_weatherlink"))
        assertEquals("none", CurrentObservationRepository.resolvedSource(null, "mait_intelliweb"))
        assertEquals("davis_weatherlink", CurrentObservationRepository.resolvedSource(null, "davis_weatherlink"))
        assertEquals("wunderground_pws", CurrentObservationRepository.resolvedSource(null, "wunderground_pws"))
        assertEquals("none", CurrentObservationRepository.resolvedSource("none", "mait_intelliweb"))
        assertEquals("mait_intelliweb", CurrentObservationRepository.actionFor("mait_intelliweb", "no_data", false, false))
        assertNull(CurrentObservationRepository.actionFor("mait_intelliweb", "ok", false, false))
        assertNull(CurrentObservationRepository.actionFor("mait_intelliweb", "not_configured", true, true))
    }

    @Test fun normalizedNullsDoNotBecomeZeros() {
        val row = SupabaseClient.json.decodeFromString<CurrentObservationRepository.CachedRow>("""{"source":"mait_intelliweb","station_name":"North station","temperature_c":null,"humidity_pct":66,"wind_direction_deg":270,"rain_today_mm":0,"status":"ok","is_stale":true}""")
        assertEquals("MAIT iNTELLiWeb", row.sourceLabel)
        assertEquals("North station", row.stationName)
        assertNull(row.observedAt)
        assertNull(row.temperatureC)
        assertEquals(66.0, row.humidityPct)
        assertEquals(270.0, row.windDirectionDeg)
        assertNull(row.windSpeedKmh)
        assertNull(row.windGustKmh)
        assertEquals(0.0, row.rainTodayMm)
        assertNull(row.rainRateMmPerHr)
        assertNull(row.leafWetness)
        assertTrue(row.isStale)
    }

    @Test fun allPresentNormalizedMetricsRetainBackendValues() {
        val row = SupabaseClient.json.decodeFromString<CurrentObservationRepository.CachedRow>("""{"source":"mait_intelliweb","temperature_c":22.5,"humidity_pct":67,"wind_speed_kmh":11,"wind_direction_deg":270,"wind_gust_kmh":19,"rain_today_mm":4.2,"rain_rate_mm_per_hr":0.4,"leaf_wetness":2,"status":"ok"}""")
        assertEquals(listOf(22.5, 67.0, 11.0, 270.0, 19.0, 4.2, 0.4, 2.0), listOf(row.temperatureC, row.humidityPct, row.windSpeedKmh, row.windDirectionDeg, row.windGustKmh, row.rainTodayMm, row.rainRateMmPerHr, row.leafWetness))
    }

    @Test fun missingRereadRetainsOriginalReadingsAndStaleness() {
        val previous = CurrentObservationRepository.CachedRow(source = "mait_intelliweb", observedAt = "2026-10-26T01:00:00Z", temperatureC = 22.0, isStale = true, status = "ok")
        assertEquals(previous, CurrentObservationRepository.retainingLastKnown(null, previous))
        assertEquals(previous, CurrentObservationRepository.retainingLastKnown(previous.copy(temperatureC = null, status = "no_data"), previous))
        val different = CurrentObservationRepository.CachedRow(source = "davis_weatherlink", status = "no_data")
        assertEquals(different, CurrentObservationRepository.retainingLastKnown(different, previous))
        assertEquals("Live observations not refreshed — MAIT iNTELLiWeb", previous.refreshFailureMessage)
    }

    @Test fun requestHasOnlyVineyardAndCurrentAction() {
        val vineyard = "11111111-1111-4111-8111-111111111111"
        assertEquals("mait-intelliweb-proxy", CurrentObservationRepository.functionFor("mait_intelliweb"))
        assertEquals(buildJsonObject { put("vineyardId", vineyard); put("action", "current") }, CurrentObservationRepository.currentBody(vineyard, "mait_intelliweb", "must-not-leak-station"))
    }

    @Test fun irrigationUsesOnlyExactFrozenSnapshotNotImportInfo() {
        val id = "11111111-1111-4111-8111-111111111111"
        for ((source, provider, label) in listOf(Triple("controller_api", "mait_intelliweb", "MAIT iNTELLiWeb"), Triple("controller_api", "galcon_gsi", "Controller"), Triple("controller_api", "", "Controller"), Triple("manual_android", "mait_intelliweb", "Android"), Triple("csv_import", "mait_intelliweb", "CSV import"), Triple("galcon_gsi_import", "mait_intelliweb", "Galcon GSI import"))) {
            val snapshot = if (provider.isEmpty()) "" else """, "configuration_snapshot":{"import":{"provider":"$provider"}}"""
            val row = SupabaseClient.json.decodeFromString<IrrigationSessionRow>("""{"id":"$id","vineyard_id":"$id","irrigation_system_id":"$id","valve_id":"$id","session_date":"2026-10-26","source_type":"$source","total_volume_litres":500,"duration_minutes":10$snapshot}""")
            assertEquals(label, row.sourceLabel)
            assertEquals(500.0, row.totalVolumeLitres, 0.0)
            assertEquals(10, row.durationMinutes)
        }
        val legacy = IrrigationSessionRow(id, id, id, id, "2026-10-26", sourceType = "controller_api", importInfo = IrrigationImportInfo(provider = "mait_intelliweb"))
        assertEquals("Controller", legacy.sourceLabel)
    }
}
