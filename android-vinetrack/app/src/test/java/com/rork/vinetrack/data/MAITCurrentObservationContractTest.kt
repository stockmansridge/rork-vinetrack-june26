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

    @Test fun supplementaryRequestIsOnlyVineyardAndAction() {
        val vineyard = "11111111-1111-4111-8111-111111111111"
        assertEquals(buildJsonObject { put("vineyardId", vineyard); put("action", "supplementary_current") }, CurrentObservationRepository.supplementaryBody(vineyard))
    }

    @Test fun suppliedPrimaryFixtureExposesSixMetricsAndSameCompass() {
        val row = SupabaseClient.json.decodeFromString<CurrentObservationRepository.CachedRow>("""{"source":"mait_intelliweb","station_name":"Mt Bera Weather Station","observed_at":"2026-10-26T06:00:00Z","temperature_c":14.5,"humidity_pct":54.4,"wind_speed_kmh":4,"wind_direction_deg":133,"wind_gust_kmh":14.5,"rain_today_mm":0,"rain_rate_mm_per_hr":null,"leaf_wetness":null,"status":"ok","is_stale":false}""")
        assertEquals("Mt Bera Weather Station", row.stationName)
        assertEquals("2026-10-26T06:00:00Z", row.observedAt)
        assertEquals(listOf(14.5, 54.4, 4.0, 133.0, 14.5, 0.0), listOfNotNull(row.temperatureC, row.humidityPct, row.windSpeedKmh, row.windDirectionDeg, row.windGustKmh, row.rainTodayMm, row.rainRateMmPerHr, row.leafWetness))
        assertFalse(row.isStale)
        assertEquals("SE", CurrentObservationRepository.compassDirection(requireNotNull(row.windDirectionDeg)))
        assertEquals("N", CurrentObservationRepository.compassDirection(360.0))
        assertEquals("W", CurrentObservationRepository.compassDirection(-90.0))
    }

    @Test fun supplementaryUsesNormalizedValuesAndDoesNotInferUnitsOrNulls() {
        val extra = SupabaseClient.json.decodeFromString<MAITSupplementarySensors>("""{"success":true,"partial":false,"modules":[{"module_id":221,"friendly_name":"EnviroPro Moisture","observed_at":"2026-10-26T06:00:00Z","status":"ok","partial":false,"readings":[{"canonical_metric":"soil_moisture","channel_key":"1","channel_number":1,"source_label":"Soil moisture","source_unit":"%","raw_value":245,"value":24.5},{"canonical_metric":"soil_moisture","source_unit":"kPa","raw_value":999,"value":12},{"canonical_metric":"leaf_wetness","source_unit":"index","raw_value":999,"value":2.5},{"canonical_metric":"leaf_wetness","raw_value":100,"value":null}]},{"module_id":222,"friendly_name":"EnviroPro Temperature","observed_at":"2026-10-26T06:00:00Z","status":"ok","partial":false,"readings":[{"canonical_metric":"soil_temperature","channel_key":"1","channel_number":1,"source_label":"Soil temperature","source_unit":"°C","raw_value":182,"value":18.2}]}]}""")
        assertNull(extra.warning)
        assertEquals(listOf("EnviroPro Moisture", "EnviroPro Temperature"), extra.modules.map { it.title })
        assertEquals("2026-10-26T06:00:00Z", extra.modules[0].observedAt)
        assertEquals(3, extra.modules[0].visibleReadings.size)
        assertEquals(24.5, extra.modules[0].readings[0].value)
        assertTrue(extra.modules[0].readings[0].displayValue!!.endsWith(" %"))
        assertTrue(extra.modules[0].readings[1].displayValue!!.endsWith(" kPa"))
        assertTrue(extra.modules[0].readings[2].displayValue!!.endsWith(" index"))
        assertNull(extra.modules[0].readings[3].displayValue)
        assertEquals(18.2, extra.modules[1].visibleReadings[0].value)
        assertTrue(extra.modules[1].readings[0].displayValue!!.endsWith(" °C"))
    }

    @Test fun individualModuleFailuresRetainSuccessfulReadingsAndScopedWarning() {
        val extra = SupabaseClient.json.decodeFromString<MAITSupplementarySensors>("""{"success":true,"partial":true,"modules":[{"friendly_name":"Working","status":"ok","readings":[{"canonical_metric":"leaf_wetness","value":0}]},{"friendly_name":"Missing","status":"no_data"},{"friendly_name":"Failed","status":"error"}]}""")
        assertEquals(listOf("Observed", "No recent data", "Sensor data unavailable"), extra.modules.map { it.statusLabel })
        assertEquals(listOf(1, 0, 0), extra.modules.map { it.visibleReadings.size })
        assertEquals("0", extra.modules[0].readings[0].displayValue)
        assertEquals(MAITSupplementarySensors.WARNING, extra.warning)
        val empty = SupabaseClient.json.decodeFromString<MAITSupplementarySensors>("""{"success":true,"partial":false,"modules":[]}""")
        assertTrue(empty.modules.isEmpty())
        assertNull(empty.warning)
    }

    @Test fun explicitFreshProvidersForceOnlyTheSelectedRouteAndNoneNeverRefreshes() {
        for (source in listOf("mait_intelliweb", "davis_weatherlink", "wunderground_pws")) {
            assertNull(CurrentObservationRepository.actionFor(source, "ok", false, false))
            assertEquals(source, CurrentObservationRepository.actionFor(source, "ok", false, true))
        }
        assertNull(CurrentObservationRepository.actionFor("none", "ok", true, true))
        assertEquals("Live observations not refreshed — Weather Underground PWS", CurrentObservationRepository.CachedRow(source = "wunderground_pws").refreshFailureMessage)
        assertEquals("Davis WeatherLink", CurrentObservationRepository.labelFor("davis_weatherlink"))
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
