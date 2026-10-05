package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.BunchCountEntry
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.HistoricalBlockResult
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PruningYieldSettings
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class YieldAuthoritativeVineCountTest {
    private fun block(first: Int? = null, second: Int? = null, override: Int? = null): Paddock {
        val lat = -34.5121
        val lon = 138.7128
        return Paddock(
            id = "22222222-2222-4222-8222-222222222222", vineyardId = "11111111-1111-4111-8111-111111111111",
            name = "Yield fixture", vineSpacing = 1.5, vineCountOverride = override,
            polygonPoints = listOf(CoordinatePoint(lat, lon), CoordinatePoint(lat + 0.003, lon),
                CoordinatePoint(lat + 0.003, lon + 0.001), CoordinatePoint(lat, lon + 0.001)),
            rows = listOf(240.0, 252.0, 250.0).mapIndexed { index, length ->
                PaddockRow(id = "row-${index + 1}", number = index + 1,
                    startPoint = CoordinatePoint(lat, lon + index * 0.000027),
                    endPoint = CoordinatePoint(lat + length / 111320, lon + index * 0.000027),
                    vineCountOverride = if (index == 0) first else if (index == 1) second else null)
            },
        )
    }

    private fun session(p: Paddock) = YieldEstimationSession(
        id = "33333333-3333-4333-8333-333333333333", vineyardId = p.vineyardId,
        createdAt = "2026-10-05T00:00:00Z", selectedPaddockIds = listOf(p.id),
        blockBunchWeightsKg = mapOf(p.id to 0.12),
        sampleSites = listOf(SampleSite(id = "sample", paddockId = p.id, rowNumber = 1,
            latitude = -34.5121, longitude = 138.7128, siteIndex = 1,
            bunchCountEntry = BunchCountEntry(10.0, "2026-10-05T00:00:00Z"))),
    )

    private fun estimate(p: Paddock) = YieldSampleGenerator.calculateYieldEstimates(session(p), listOf(p)).single()

    @Test fun noOverridePreservesCalculatedCountAndYield() {
        val p = block()
        val e = estimate(p)
        assertEquals(494, e.totalVines)
        assertEquals(p.effectiveVineCount, p.authoritativeVineCount)
        assertEquals(0.5928, e.estimatedYieldTonnes, 1e-10)
    }

    @Test fun blockOverrideDrivesYield() {
        val e = estimate(block(override = 500))
        assertEquals(500, e.totalVines)
        assertEquals(0.6, e.estimatedYieldTonnes, 1e-10)
    }

    @Test fun oneRowOverrideIncludesUntouchedRows() {
        val p = block(first = 158)
        val e = estimate(p)
        assertEquals(493, e.totalVines)
        assertEquals(0.5916, e.estimatedYieldTonnes, 1e-10)
        assertNull(p.vineCountOverride)
        assertEquals(494, p.effectiveVineCount)
    }

    @Test fun multipleRowOverridesDriveYield() {
        val e = estimate(block(first = 158, second = 150))
        assertEquals(475, e.totalVines)
        assertEquals(0.57, e.estimatedYieldTonnes, 1e-10)
    }

    @Test fun blockOverrideWinsOverRows() {
        val e = estimate(block(first = 158, second = 150, override = 500))
        assertEquals(500, e.totalVines)
        assertEquals(0.6, e.estimatedYieldTonnes, 1e-10)
    }

    @Test fun clearingRowsRestoresPreviousFallback() {
        val p = block(first = 158, second = 150)
        assertEquals(475, estimate(p).totalVines)
        val cleared = p.copy(rows = p.rows.orEmpty().map { it.copy(vineCountOverride = null) })
        assertEquals(494, estimate(cleared).totalVines)
        assertEquals(0.5928, estimate(cleared).estimatedYieldTonnes, 1e-10)
    }

    @Test fun bunchCountTonnesChangeProportionally() {
        val before = estimate(block(override = 10000))
        val after = estimate(block(first = 9265)) // 9265 + 168 + 167 = 9600
        assertEquals(9600, after.totalVines)
        assertEquals(11.52, after.estimatedYieldTonnes, 1e-10)
        assertEquals(0.96, after.estimatedYieldTonnes / before.estimatedYieldTonnes, 1e-10)
    }

    @Test fun displayedCountMatchesFormulaAndDamageIsUnchanged() {
        val p = block(first = 158)
        val e = YieldSampleGenerator.calculateYieldEstimates(session(p), listOf(p)) { 0.8 }.single()
        assertEquals(p.summaryVineCount, e.totalVines)
        assertEquals(e.totalVines * e.averageBunchesPerVine, e.totalBunches, 0.0)
        assertEquals(e.totalBunches * e.averageBunchWeightKg * 0.8, e.estimatedYieldKg, 0.0)
        assertEquals(0.8, e.remainingYieldMultiplier, 0.0)
    }

    @Test fun invalidAndZeroOverridesAreIgnored() {
        for (invalid in listOf(0, -1, 100001)) {
            val p = block(first = invalid, override = if (invalid == 100001) 0 else invalid)
            assertEquals(494, p.authoritativeVineCount)
            assertEquals(494, p.summaryVineCount)
            assertFalse(p.hasAuthoritativeVineOverride)
            assertEquals(494, estimate(p).totalVines)
        }
        assertEquals(493, block(first = 158, override = 0).authoritativeVineCount)
    }

    @Test fun historicalStoredResultsAreNotRewritten() {
        val p = block()
        val stored = HistoricalBlockResult(id = "history", paddockId = p.id, paddockName = p.name,
            yieldTonnes = 12.0, totalVines = 10000)
        val data = Json.encodeToString(stored)
        estimate(p.copy(rows = p.rows.orEmpty().mapIndexed { i, r -> if (i == 0) r.copy(vineCountOverride = 158) else r }))
        val restored = Json.decodeFromString<HistoricalBlockResult>(data)
        assertEquals(10000, restored.totalVines)
        assertEquals(12.0, restored.yieldTonnes, 0.0)
        assertEquals(data, Json.encodeToString(stored))
    }

    @Test fun savedPruningDensityIsPreservedWithoutOverrides() {
        val p = block()
        assertEquals(2200.0, p.pruningYieldVinesPerHa(2200.0), 0.0)
        assertEquals(0.0, p.pruningYieldVinesPerHa(0.0), 0.0)
    }

    @Test fun physicalOverridesSupersedeSavedPruningDensity() {
        for (p in listOf(block(first = 158), block(first = 158, override = 500))) {
            assertEquals(p.authoritativeVineCount.toDouble(), p.pruningYieldVinesPerHa(2200.0) * p.areaHectares, 1e-8)
        }
        val p = block(first = 158)
        val settings = PruningYieldSettings(id = "settings", vineyardId = p.vineyardId, paddockId = p.id, vinesPerHa = 2200.0)
        p.pruningYieldVinesPerHa(settings.vinesPerHa ?: 0.0)
        val cleared = p.copy(rows = p.rows.orEmpty().map { it.copy(vineCountOverride = null) })
        assertEquals(2200.0, cleared.pruningYieldVinesPerHa(settings.vinesPerHa ?: 0.0), 0.0)
        assertEquals(2200.0, settings.vinesPerHa ?: 0.0, 0.0)
    }

    @Test fun newlyCompletedTripsKeepCapturedVineCount() {
        val p = block(first = 158)
        val completed = session(p).copy(isCompleted = true, blockVineCounts = mapOf(p.id to p.authoritativeVineCount))
        val restored = Json.decodeFromString<YieldEstimationSession>(Json.encodeToString(completed))
        val changed = p.copy(vineCountOverride = 500)
        val e = YieldSampleGenerator.calculateYieldEstimates(restored, listOf(changed)).single()
        assertEquals(493, e.totalVines)
        assertEquals(493, restored.vineCount(changed))
        assertEquals(0.5916, e.estimatedYieldTonnes, 1e-10)
    }

    @Test fun legacyCompletedTripsRetainPreviousCalculation() {
        val p = block(first = 158)
        val e = YieldSampleGenerator.calculateYieldEstimates(session(p).copy(isCompleted = true), listOf(p)).single()
        assertEquals(p.effectiveVineCount, e.totalVines)
        assertEquals(494, e.totalVines)
    }
}
