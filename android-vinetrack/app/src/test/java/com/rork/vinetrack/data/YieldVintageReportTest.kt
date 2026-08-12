package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.BunchCountEntry
import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.HistoricalBlockResult
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.PickingFinancialRow
import com.rork.vinetrack.data.model.PickingRecord
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.data.model.mergePickingFinancials
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset

/**
 * Contract tests for the Vintage-driven Yield Report and Bunch Count Trip
 * rules. Mirrors `YieldVintageReportTests.swift` on iOS so both platforms pin
 * the same behaviour:
 *  - latest COMPLETED trip per Block + Vintage drives the current estimate
 *    (never summed, never averaged; drafts ignored)
 *  - damage adjustment is presentation-time and never mutates base counts
 *  - past vintages: Detailed Picking Log supersedes Basic actuals
 *  - route reuse preserves site identity but strips counts
 *  - financial merge is owner/manager-only projection data
 */
class YieldVintageReportTest {

    private val vy = "vy-1"
    private val blockA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val blockB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private val paddocks = listOf(
        Paddock(
            id = blockA, vineyardId = vy, name = "Shiraz North",
            vineCountOverride = 1000,
            varietyAllocations = listOf(PaddockVarietyAllocation(name = "Shiraz", percentage = 100.0)),
        ),
        Paddock(
            id = blockB, vineyardId = vy, name = "River Block",
            vineCountOverride = 500,
            varietyAllocations = listOf(PaddockVarietyAllocation(name = "Grenache", percentage = 100.0)),
        ),
    )

    private fun trip(
        id: String,
        blockId: String,
        avgBunches: Double,
        completedAt: String?,
        createdAt: String = "2025-11-01T00:00:00Z",
        isCompleted: Boolean = completedAt != null,
        applyDamage: Boolean = true,
        recorded: Boolean = true,
    ) = YieldEstimationSession(
        id = id,
        vineyardId = vy,
        createdAt = createdAt,
        selectedPaddockIds = listOf(blockId),
        samplesPerHectare = 20,
        sampleSites = listOf(
            SampleSite(
                id = "$id-site-1", paddockId = blockId, rowNumber = 1,
                latitude = 0.0, longitude = 0.0, siteIndex = 1,
                bunchCountEntry = if (recorded) BunchCountEntry(avgBunches, "2025-12-01T00:00:00Z") else null,
            ),
        ),
        blockBunchWeightsKg = mapOf(blockId to 0.1), // 100 g bunches
        isCompleted = isCompleted,
        completedAt = completedAt,
        applyDamage = applyDamage,
    )

    // ---- Latest completed trip wins --------------------------------------

    @Test
    fun latestCompletedTripDrivesTheCurrentEstimate() {
        val december = trip("t-dec", blockA, avgBunches = 30.0, completedAt = "2025-12-10T02:00:00Z")
        val january = trip("t-jan", blockA, avgBunches = 20.0, completedAt = "2026-01-15T02:00:00Z")
        val newerDraft = trip("t-draft", blockA, avgBunches = 50.0, completedAt = null, createdAt = "2026-02-01T00:00:00Z")

        val rows = YieldVintageReport.estimateRows(
            listOf(december, january, newerDraft), paddocks, emptyList(),
            vintage = 2026, seasonStartMonth = 7, seasonStartDay = 1,
        )

        assertEquals(1, rows.size)
        val row = rows.first()
        // 1000 vines × 20 bunches × 0.1 kg = 2.0 t — the January (latest) count.
        assertEquals("t-jan", row.sessionId)
        assertEquals(2.0, row.baseTonnes, 1e-9)
        // Never the December value (3.0), the sum (5.0) or the average (2.5).
        assertFalse(row.baseTonnes == 3.0 || row.baseTonnes == 5.0 || row.baseTonnes == 2.5)
        assertEquals("Shiraz", row.varietyLabel)
    }

    @Test
    fun olderTripsRemainHistoricalPerVintage() {
        val v25 = trip("t-25", blockA, avgBunches = 40.0, completedAt = "2025-01-20T02:00:00Z")
        val v26 = trip("t-26", blockA, avgBunches = 20.0, completedAt = "2026-01-20T02:00:00Z")

        val rows25 = YieldVintageReport.estimateRows(
            listOf(v25, v26), paddocks, emptyList(), 2025, 7, 1,
        )
        val rows26 = YieldVintageReport.estimateRows(
            listOf(v25, v26), paddocks, emptyList(), 2026, 7, 1,
        )

        assertEquals("t-25", rows25.single().sessionId)
        assertEquals(4.0, rows25.single().baseTonnes, 1e-9)
        assertEquals("t-26", rows26.single().sessionId)
    }

    // ---- Damage adjustment ------------------------------------------------

    @Test
    fun damageAdjustsDisplayWithoutMutatingBase() {
        val session = trip("t-1", blockA, avgBunches = 30.0, completedAt = "2026-01-15T02:00:00Z")
        val damage = listOf(
            DamageRecord(id = "d1", vineyardId = vy, paddockId = blockA, damagePercent = 20.0),
        )

        val rows = YieldVintageReport.estimateRows(listOf(session), paddocks, damage, 2026, 7, 1)
        val row = rows.single()

        assertEquals(3.0, row.baseTonnes, 1e-9)
        assertEquals(2.4, row.adjustedTonnes, 1e-9)
        assertEquals(2.4, row.displayTonnes, 1e-9) // applyDamage = true
        // The field observations were never touched.
        assertEquals(30.0, session.sampleSites.single().bunchCountEntry!!.bunchesPerVine, 1e-9)
    }

    @Test
    fun applyDamageFalseShowsBaseButKeepsAdjustedAvailable() {
        val session = trip("t-1", blockA, avgBunches = 30.0, completedAt = "2026-01-15T02:00:00Z", applyDamage = false)
        val damage = listOf(
            DamageRecord(id = "d1", vineyardId = vy, paddockId = blockA, damagePercent = 50.0),
        )

        val row = YieldVintageReport.estimateRows(listOf(session), paddocks, damage, 2026, 7, 1).single()
        assertEquals(3.0, row.displayTonnes, 1e-9)
        assertEquals(1.5, row.adjustedTonnes, 1e-9)
    }

    // ---- Session vintage & available vintages ------------------------------

    @Test
    fun sessionVintageUsesSeasonSettings() {
        val s = trip("t-1", blockA, 10.0, completedAt = "2025-12-15T02:00:00Z")
        // July season start: Dec 2025 belongs to the season ending 2026.
        assertEquals(2026, YieldVintageReport.sessionVintage(s, 7, 1, ZoneOffset.UTC))
        // January season start: Dec 2025 is vintage 2025.
        assertEquals(2025, YieldVintageReport.sessionVintage(s, 1, 1, ZoneOffset.UTC))
    }

    @Test
    fun availableVintagesLeadsWithCurrentAndSortsDescending() {
        val picks = listOf(pick("p1", blockA, "Shiraz", 1000.0, vintage = 2025))
        val records = listOf(historical("h1", 2024, blockA, actual = 10.0, estimate = 11.0))
        val vintages = YieldVintageReport.availableVintages(2026, emptyList(), records, picks, 7, 1)
        assertEquals(listOf(2026, 2025, 2024), vintages)
    }

    // ---- Past vintage actuals: Detailed supersedes Basic --------------------

    @Test
    fun detailedPickingTotalsSupersedeBasicActuals() {
        val records = listOf(
            HistoricalYieldRecord(
                id = "h1", vineyardId = vy, year = 2025,
                blockResults = listOf(
                    HistoricalBlockResult(id = "b1", paddockId = blockA, paddockName = "Shiraz North", areaHectares = 2.0, yieldTonnes = 12.0, actualYieldTonnes = 10.0),
                    HistoricalBlockResult(id = "b2", paddockId = blockB, paddockName = "River Block", areaHectares = 1.0, yieldTonnes = 6.0, actualYieldTonnes = 5.0),
                ),
            ),
        )
        val picks = listOf(
            pick("p1", blockA, "Shiraz", 5000.0, vintage = 2025),
            pick("p2", blockA, "Shiraz", 3000.0, vintage = 2025),
        )

        val rows = YieldVintageReport.actualRows(2025, paddocks, records, picks)

        // Block A: the summed picking log (8 t) IS the actual — Basic 10 t superseded.
        val a = rows.filter { it.paddockId.equals(blockA, ignoreCase = true) }
        assertEquals(1, a.size)
        assertTrue(a.single().fromDetailed)
        assertEquals(8.0, a.single().tonnes, 1e-9)
        assertEquals(12.0, a.single().estimatedTonnes!!, 1e-9)
        assertEquals(-4.0, a.single().varianceTonnes!!, 1e-9)

        // Block B keeps its Basic actual (no picks).
        val b = rows.single { it.paddockId.equals(blockB, ignoreCase = true) }
        assertFalse(b.fromDetailed)
        assertEquals(5.0, b.tonnes, 1e-9)
        assertEquals("Grenache", b.varietyName)
    }

    @Test
    fun actualRowsGroupPerBlockAndVariety() {
        val picks = listOf(
            pick("p1", blockA, "Shiraz", 2000.0, vintage = 2025),
            pick("p2", blockA, "Grenache", 1000.0, vintage = 2025),
            pick("p3", blockB, "Grenache", 500.0, vintage = 2025),
        )
        val rows = YieldVintageReport.actualRows(2025, paddocks, emptyList(), picks)
        assertEquals(3, rows.size)
        assertEquals(
            setOf("Shiraz" to 2.0, "Grenache" to 1.0),
            rows.filter { it.paddockId.equals(blockA, ignoreCase = true) }
                .map { it.varietyName to it.tonnes }.toSet(),
        )
    }

    // ---- Financial merge -----------------------------------------------------

    @Test
    fun financialMergeAppliesManagerProjectionCaseInsensitively() {
        val masked = pick("P1", blockA, "Shiraz", 2000.0, vintage = 2025, sold = true)
        val merged = mergePickingFinancials(
            listOf(masked),
            listOf(PickingFinancialRow(pickingRecordId = "p1", soldTo = "Wine Co", pricePerTonne = 1500.0, grapeValue = 3.0)),
        ).single()
        assertEquals("Wine Co", merged.soldTo)
        assertEquals(1500.0, merged.pricePerTonne!!, 1e-9)
        assertEquals(3.0, merged.displayGrapeValue!!, 1e-9)

        // Operators (no projection) keep masked NULLs.
        val untouched = mergePickingFinancials(listOf(masked), emptyList()).single()
        assertNull(untouched.soldTo)
        assertNull(untouched.pricePerTonne)
    }

    private fun pick(
        id: String,
        blockId: String,
        variety: String,
        weightKg: Double,
        vintage: Int,
        sold: Boolean = false,
    ) = PickingRecord(
        id = id, vineyardId = vy, pickedAt = "2025-02-10", vintage = vintage,
        paddockId = blockId, paddockName = paddocks.first { it.id == blockId }.name,
        varietyName = variety, weightKg = weightKg, sold = sold,
    )

    private fun historical(id: String, year: Int, blockId: String, actual: Double?, estimate: Double) =
        HistoricalYieldRecord(
            id = id, vineyardId = vy, year = year,
            blockResults = listOf(
                HistoricalBlockResult(
                    id = "$id-b", paddockId = blockId, paddockName = "Block",
                    yieldTonnes = estimate, actualYieldTonnes = actual,
                ),
            ),
        )
}

/** Bunch Count Trip session lifecycle + route reuse contract. */
class BunchCountTripLogicTest {

    private val vy = "vy-1"
    private val blockA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val blockB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private fun sessionWithSites(
        id: String,
        blockId: String,
        siteCount: Int,
        isCompleted: Boolean,
        completedAt: String? = null,
        createdAt: String = "2025-11-01T00:00:00Z",
    ) = YieldEstimationSession(
        id = id, vineyardId = vy, createdAt = createdAt,
        selectedPaddockIds = listOf(blockId),
        sampleSites = (1..siteCount).map { idx ->
            SampleSite(
                id = "$id-site-$idx", paddockId = blockId, rowNumber = idx,
                latitude = idx * 0.001, longitude = idx * 0.001, siteIndex = idx,
                bunchCountEntry = BunchCountEntry(idx * 10.0, "2025-12-01T00:00:00Z"),
            )
        },
        isCompleted = isCompleted,
        completedAt = completedAt,
    )

    @Test
    fun activeDraftIsNewestIncompleteAndCompletedTripsSortDescending() {
        val done1 = sessionWithSites("done-1", blockA, 2, true, completedAt = "2025-12-01T00:00:00Z")
        val done2 = sessionWithSites("done-2", blockA, 2, true, completedAt = "2026-01-05T00:00:00Z")
        val draftOld = sessionWithSites("draft-old", blockA, 1, false, createdAt = "2026-01-10T00:00:00Z")
        val draftNew = sessionWithSites("draft-new", blockB, 1, false, createdAt = "2026-02-01T00:00:00Z")

        val all = listOf(done1, draftOld, done2, draftNew)
        assertEquals("draft-new", BunchCountTripLogic.activeDraft(all, vy)!!.id)
        assertEquals(listOf("done-2", "done-1"), BunchCountTripLogic.completedTrips(all, vy).map { it.id })
        // Other vineyard sees nothing.
        assertNull(BunchCountTripLogic.activeDraft(all, "other"))
        assertTrue(BunchCountTripLogic.completedTrips(all, "other").isEmpty())
    }

    @Test
    fun startTripCreatesFreshDatedObservation() {
        val a = BunchCountTripLogic.startTrip(vy, 24)
        val b = BunchCountTripLogic.startTrip(vy, 500)
        assertFalse(a.id == b.id)
        assertEquals(24, a.samplesPerHectare)
        assertEquals(100, b.samplesPerHectare) // clamped
        assertFalse(a.isCompleted)
        assertTrue(a.sampleSites.isEmpty())
        assertTrue(a.applyDamage)
    }

    @Test
    fun reusableRoutePreservesSiteIdentityAndStripsCounts() {
        val completed = sessionWithSites("prior", blockA, 3, true, completedAt = "2025-12-01T00:00:00Z")
        val otherBlock = sessionWithSites("prior-b", blockB, 2, true, completedAt = "2025-11-01T00:00:00Z")

        val route = BunchCountTripLogic.reusableRoute(
            listOf(completed, otherBlock), listOf(blockA, blockB), excludeSessionId = "current-draft",
        )

        assertNotNull(route)
        assertEquals(5, route!!.sites.size)
        // Original site ids preserved (comparable locations across trips).
        assertTrue(route.sites.any { it.id == "prior-site-1" })
        assertTrue(route.sites.any { it.id == "prior-b-site-2" })
        // Counts stripped, indices sequential.
        assertTrue(route.sites.all { it.bunchCountEntry == null })
        assertEquals((1..5).toList(), route.sites.map { it.siteIndex })
        assertEquals("prior", route.sourceSessionId)
    }

    @Test
    fun reusableRoutePrefersNewestAndCompletedSources() {
        val older = sessionWithSites("older", blockA, 2, true, completedAt = "2025-11-01T00:00:00Z")
        val newer = sessionWithSites("newer", blockA, 3, true, completedAt = "2025-12-20T00:00:00Z")
        val route = BunchCountTripLogic.reusableRoute(listOf(older, newer), listOf(blockA))
        assertEquals("newer", route!!.sourceSessionId)
        assertEquals(3, route.sites.size)
    }

    @Test
    fun noPriorRouteMeansNoPrompt() {
        val otherBlockOnly = sessionWithSites("prior-b", blockB, 2, true, completedAt = "2025-11-01T00:00:00Z")
        // The current draft itself never counts as a prior route.
        val draft = sessionWithSites("current", blockA, 2, false)
        assertNull(BunchCountTripLogic.reusableRoute(listOf(otherBlockOnly), listOf(blockA)))
        assertNull(BunchCountTripLogic.reusableRoute(listOf(draft), listOf(blockA), excludeSessionId = "current"))
        assertNull(BunchCountTripLogic.reusableRoute(emptyList(), listOf(blockA)))
    }
}
