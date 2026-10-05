package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class FertiliserRegionParityTest {
    @Test fun actualAndAssumedMultiBlockTotals() {
        val a = Paddock(id = "a", vineyardId = "v", name = "A", vineCountOverride = 4200, rowLengthOverride = 10000.0, vineSpacing = 2.0)
        val b = Paddock(id = "b", vineyardId = "v", name = "B", vineCountOverride = 3600, rowLengthOverride = 8000.0, vineSpacing = 2.0)
        assertEquals(7800, FertiliserVineCounts.total(listOf(a, b), "actual"))
        assertEquals(9000, FertiliserVineCounts.total(listOf(a, b), "assumed_full"))
        assertEquals(78.0, FertiliserCalc.totalForPerVine(7800, 10.0), 0.0)
        assertEquals(listOf(42.0, 36.0), FertiliserVineCounts.shares(78.0, listOf(4200.0, 3600.0)))
        assertEquals(listOf(50.0, 40.0), FertiliserVineCounts.shares(90.0, listOf(5000.0, 4000.0)))
    }

    @Test fun geometryOnlyIsNotActualAndBadGeometryNeverInventsCounts() {
        val block = Paddock(id = "a", vineyardId = "v", name = "A", rowLengthOverride = 10001.0, vineSpacing = 2.0)
        assertNull(FertiliserVineCounts.count(block, "actual"))
        assertEquals(5000, FertiliserVineCounts.count(block, "assumed_full"))
        for (spacing in listOf(null, 0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNull(FertiliserVineCounts.count(block.copy(vineSpacing = spacing), "assumed_full"))
        }
        assertNull(FertiliserVineCounts.total(listOf(block.copy(vineCountOverride = 4200), block), "actual"))
        assertNull(FertiliserVineCounts.count(block.copy(rowLengthOverride = Double.NaN), "assumed_full"))
    }

    @Test fun actualRowsRequireOverrideAndEveryRowToResolve() {
        val row = PaddockRow(id = "r", number = 1, startPoint = CoordinatePoint(0.0, 0.0), endPoint = CoordinatePoint(100.0 / 111320, 0.0), vineCountOverride = 42)
        val automatic = row.copy(id = "s", number = 2, vineCountOverride = null)
        val block = Paddock(id = "a", vineyardId = "v", name = "A", rows = listOf(row, automatic), vineSpacing = 2.0)
        assertEquals(92, FertiliserVineCounts.count(block, "actual"))
        assertNull(FertiliserVineCounts.count(block.copy(vineSpacing = null), "actual"))
        assertEquals(42, FertiliserVineCounts.count(block.copy(rows = listOf(row), vineSpacing = null), "actual"))
        assertEquals(4200, FertiliserVineCounts.count(block.copy(vineCountOverride = 4200), "actual"))
        assertNull(FertiliserVineCounts.count(block.copy(rows = listOf(row, automatic.copy(endPoint = null))), "assumed_full"))
    }

    @Test fun residualsAndOverflowAreSafe() {
        val shares = FertiliserVineCounts.shares(0.7, listOf(1.0, 2.0, 3.0))
        assertEquals(0.7, shares.sum(), 0.0)
        val block = Paddock(id = "a", vineyardId = "v", name = "A", vineCountOverride = Int.MAX_VALUE)
        assertNull(FertiliserVineCounts.total(listOf(block, block), "actual"))
    }

    @Test fun legacyAndNewSnapshotsRoundTripWithoutInference() {
        val json = Json { encodeDefaults = true }
        val legacy = json.decodeFromString<FertiliserRecord>("""{"id":"r","vineyardId":"v","date":"2026-10-05","mode":"perVine","vineCount":7800,"totalProduct":78.0}""")
        assertNull(legacy.vineCountBasis)
        val completed = legacy.copy(status = "completed")
        assertEquals(7800, completed.vineCount)
        assertEquals(78.0, completed.totalProduct, 0.0)
        for (basis in listOf(null, "", "actual", "assumed_full", "manual")) {
            val record = legacy.copy(vineCountBasis = basis)
            assertEquals(record, json.decodeFromString<FertiliserRecord>(json.encodeToString(record)))
        }
        assertNull(FertiliserSyncRepository.RecordRow("r", "v", totalVines = 7800).toModel(emptyList()).vineCountBasis)
        assertEquals("actual", FertiliserSyncRepository.RecordRow("r", "v", vineCountBasis = "actual").toModel(emptyList()).vineCountBasis)
    }

    @Test fun commonAuUsGbpForwardInverseFixtures() {
        for (settings in listOf(RegionSettings(), RegionSettings(countryCode = "US", currencyCode = "USD", areaUnit = "acres", volumeUnit = "gallons", fuelUnit = "gallons", distanceUnit = "imperial", sprayRateAreaUnit = "acre"), RegionSettings(countryCode = "GB", currencyCode = "GBP", areaUnit = "acres", volumeUnit = "gallons", fuelUnit = "gallons", distanceUnit = "imperial", sprayRateAreaUnit = "acre"))) {
            val f = RegionFormatter(settings)
            assertEquals(12.5, f.areaToCanonical(f.areaValue(12.5)), 1e-9)
            assertEquals(100.0, f.volumeToCanonical(f.volumeValue(100.0)), 1e-9)
            assertEquals(100.0, f.fuelToCanonical(f.fuelValue(100.0)), 1e-9)
            assertEquals(1200.0, f.volumePerAreaToCanonical(f.volumePerAreaValue(1200.0)), 1e-9)
            assertEquals(1.89, f.fuelCostToCanonical(f.fuelCostValue(1.89)), 1e-9)
            assertEquals(2.0, f.lengthToCanonical(f.lengthValue(2.0)), 1e-9)
            assertEquals(2.54, f.smallLengthToCanonical(f.smallLengthValue(2.54)), 1e-9)
            assertEquals(2000.0, f.perAreaToCanonical(f.perAreaValue(2000.0)), 1e-9)
        }
    }

    @Test fun independentUnitsAndGallons() {
        val us = RegionFormatter(RegionSettings(countryCode = "US", volumeUnit = "gallons", fuelUnit = "litres", sprayRateAreaUnit = "hectare", areaUnit = "acres"))
        assertEquals("264.17 gal/ha", us.formatVolumePerArea(1000.0, 2))
        assertEquals(1000.0, us.fuelValue(1000.0), 0.0)
        assertEquals(264.172052, us.volumeValue(1000.0), 1e-9)
        val gb = RegionFormatter(RegionSettings(countryCode = "GB", currencyCode = "GBP", volumeUnit = "gallons"))
        assertEquals(219.969157, gb.volumeValue(1000.0), 1e-9)
        assertTrue(gb.formatCurrency(12.5).contains("£"))
    }

    @Test fun irrigationMixedUnitsUseIndependentAreaVolumeAndDepth() {
        val acresLitres = RegionFormatter(RegionSettings(areaUnit = "acres", volumeUnit = "litres", distanceUnit = "metric"))
        assertEquals("405 L/ac", acresLitres.formatVolumePerLandArea(1000.0))
        assertEquals("25.40 mm", acresLitres.formatRainfall(25.4, 2))
        val hectaresGallons = RegionFormatter(RegionSettings(countryCode = "US", volumeUnit = "gallons", distanceUnit = "imperial"))
        assertEquals("264 gal/ha", hectaresGallons.formatVolumePerLandArea(1000.0))
        assertEquals("1.000 in", hectaresGallons.formatRainfall(25.4, 3))
    }

    @Test fun dateOnlyAndTimezoneBoundary() {
        val us = RegionFormatter(RegionSettings(countryCode = "US", currencyCode = "USD", timezone = "America/Los_Angeles", dateFormat = "MM/DD/YYYY"))
        assertEquals("10/05/2026", us.formatDate("2026-10-05"))
        assertEquals("2026-10-04", us.todayIso(Instant.parse("2026-10-05T01:00:00Z").toEpochMilli()))
        assertEquals("10/04/2026", us.formatDate(Instant.parse("2026-10-05T01:00:00Z").toEpochMilli()))
    }
}
