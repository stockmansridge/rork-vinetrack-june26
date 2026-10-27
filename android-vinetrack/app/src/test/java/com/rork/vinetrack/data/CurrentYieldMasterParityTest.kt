package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class CurrentYieldMasterParityTest {
    @Serializable data class Planting(val key: String, val name: String, val share: Double)
    @Serializable data class Block(val id: String, val name: String, val vines: Int, val sideMetres: Double, val counts: List<Double>, val remaining: Double, val plantings: List<Planting>)
    @Serializable data class Resolution(val block: Int, val key: String, val grams: Double, val source: String)
    @Serializable data class Fixture(val vineyardId: String, val tripId: String, val blocks: List<Block>, val resolutions: List<Resolution>,
        val expectedWeightsKg: List<Double>, val expectedBaseTonnes: List<Double>, val expectedAdjustedTonnes: List<Double>,
        val expectedTotalBase: Double, val expectedTotalAdjusted: Double, val expectedSampledAreaHa: Double, val expectedPerHa: Double) {
        val paddocks get() = blocks.map { b ->
            val d = b.sideMetres / 111320
            Paddock(id = b.id, vineyardId = vineyardId, name = b.name, vineCountOverride = b.vines,
                polygonPoints = listOf(CoordinatePoint(0.0, 0.0), CoordinatePoint(d, 0.0), CoordinatePoint(d, d), CoordinatePoint(0.0, d)),
                varietyAllocations = b.plantings.map { PaddockVarietyAllocation(varietyId = vineyardId, name = it.name, varietyKey = it.key, percent = it.share) })
        }
        val weights get() = resolutions.associate { CurrentYieldEstimate.key(blocks[it.block].id, it.key) to YieldMasterWeight(it.grams, it.source, tripId, it.key) }
        val session get() = YieldEstimationSession(id = tripId, vineyardId = vineyardId, createdAt = "2026-10-14T00:26:40Z",
            selectedPaddockIds = blocks.map { it.id }, sampleSites = blocks.flatMap { b ->
                b.counts.mapIndexed { i, c -> SampleSite("${b.id}/$i", b.id, rowNumber = 1, latitude = 0.0, longitude = 0.0, siteIndex = i + 1,
                    bunchCountEntry = BunchCountEntry(c, "2026-10-14T00:26:40Z")) } +
                    SampleSite("${b.id}/planned", b.id, rowNumber = 2, latitude = 0.0, longitude = 0.0, siteIndex = 99)
            }, blockBunchWeightsKg = blocks.associate { it.id to 0.15 }, isCompleted = true, completedAt = "2026-10-15T04:13:20Z", blockVineCounts = blocks.associate { it.id to 1 })
        fun trip(s: YieldEstimationSession = session, w: Map<String, YieldMasterWeight> = weights) = CurrentYieldEstimate.trip(s, paddocks, w) { id -> blocks.first { it.id.equals(id, true) }.remaining }
    }
    private fun fixture() = javaClass.getResourceAsStream("/yield-master-parity.json")!!.bufferedReader().use { Json.decodeFromString<Fixture>(it.readText()) }
    @Test fun sharedOverrideMasterAndMixedWeights() {
        val f = fixture(); val t = f.trip()
        for (i in 0..2) assertEquals(f.expectedWeightsKg[i], t.blocks[i].weightKg!!, 1e-12)
        assertEquals(listOf("Renamed Shiraz: Block override"), t.blocks[0].weightSources)
        assertEquals(listOf("Merlot: Vineyard variety master"), t.blocks[1].weightSources)
    }
    @Test fun sharedBaseTonnesAndCurrentAuthoritativeVines() {
        val f = fixture(); val t = f.trip()
        for (i in 0..2) { assertEquals(f.blocks[i].vines, t.blocks[i].vines); assertEquals(f.expectedBaseTonnes[i], t.blocks[i].baseTonnes!!, 1e-12) }
    }
    @Test fun sharedDamageAndTripTotals() {
        val f = fixture(); val t = f.trip()
        for (i in 0..2) assertEquals(f.expectedAdjustedTonnes[i], t.blocks[i].adjustedTonnes!!, 1e-12)
        assertEquals(f.expectedTotalAdjusted, t.totalTonnes!!, 1e-12)
    }
    @Test fun sampledAreaExcludesPlannedBlock() {
        val f = fixture(); val t = f.trip()
        assertEquals(f.expectedSampledAreaHa, t.sampledAreaHa, 1e-8); assertEquals(f.expectedPerHa, t.tonnesPerHa!!, 1e-8)
        assertEquals(0.0, t.blocks[3].sampledAreaHa, 0.0)
    }
    @Test fun missingMixedVarietyWithholdsWholeBlockAndTrip() {
        val f = fixture(); val w = f.weights - CurrentYieldEstimate.key(f.blocks[2].id, "merlot"); val t = f.trip(w = w)
        assertNull(t.blocks[2].weightKg); assertNull(t.blocks[2].baseTonnes); assertNull(t.totalTonnes); assertNull(t.tonnesPerHa); assertNotNull(t.blocks[0].displayTonnes)
    }
    @Test fun historicalWeightNeverBecomesCurrent() {
        val t = fixture().trip(w = emptyMap()); assertEquals(0.15, t.blocks[0].historicalWeightKg!!, 0.0); assertNull(t.blocks[0].weightKg); assertNull(t.totalTonnes)
    }
    @Test fun storedKeyWinsOverRenamedDisplay() { assertEquals("shiraz", CurrentYieldEstimate.plantings(fixture().paddocks[0])[0].key) }
    @Test fun onlyAbsentStoredKeyUsesNameFallback() {
        val p = fixture().paddocks[0]; assertEquals("renamed_shiraz", CurrentYieldEstimate.plantings(p.copy(varietyAllocations = p.varietyAllocations!!.map { it.copy(varietyKey = null) }))[0].key)
    }
    @Test fun recordedZeroIsASampleNotMissing() {
        val f = fixture(); val s = f.session.copy(sampleSites = f.session.sampleSites.filter { it.paddockId == f.blocks[0].id && it.isRecorded }.take(1).map { it.copy(bunchCountEntry = it.bunchCountEntry!!.copy(bunchesPerVine = 0.0)) })
        val t = f.trip(s); assertEquals(0.0, t.blocks[0].baseTonnes!!, 0.0); assertTrue(t.sampledAreaHa > 0)
    }
    @Test fun noRecordedSamplesHaveNoTonnesOrPerHa() {
        val f = fixture(); val t = f.trip(f.session.copy(sampleSites = emptyList())); assertNull(t.totalTonnes); assertNull(t.tonnesPerHa); assertEquals(0.0, t.sampledAreaHa, 0.0)
    }
    @Test fun damageOffRestoresBaseWithoutChangingEvidence() {
        val f = fixture(); val s = f.session; assertEquals(f.expectedTotalBase, f.trip(s.copy(applyDamage = false)).totalTonnes!!, 1e-12); assertEquals(listOf(18.0, 22.0, 20.0, 25.0), s.sampleSites.mapNotNull { it.bunchCountEntry?.bunchesPerVine })
    }
    @Test fun unroundedRecordedAverageDrivesTonnes() {
        val f = fixture(); val first = f.session.sampleSites.first(); val s = f.session.copy(sampleSites = listOf(1.0, 2.0, 2.0).map { first.copy(bunchCountEntry = first.bunchCountEntry!!.copy(bunchesPerVine = it)) })
        assertEquals(0.2, f.trip(s).blocks[0].baseTonnes!!, 1e-12)
    }
    @Test fun confirmedAbsenceInvalidatesPriorWeight() {
        val f = fixture(); val w = f.weights + (CurrentYieldEstimate.key(f.blocks[0].id, "shiraz") to YieldMasterWeight(null, "not_configured", null, "shiraz")); assertNull(f.trip(w = w).blocks[0].weightKg)
    }
    @Test fun invalidUnconfirmedOrNonpositiveWeightRejected() {
        for (g in listOf(0.0, -1.0, Double.POSITIVE_INFINITY)) assertNull(YieldMasterWeight(g, "variety_default", "record", "x").kg)
        assertNull(YieldMasterWeight(150.0, "historical", "record", "x").kg)
    }
    @Test fun latestCompletedObservationStillWinsWithoutDrafts() {
        val f = fixture(); val s = f.session; val latest = YieldVintageReport.latestCompletedSessionForBlock(listOf(s, s.copy(isCompleted = false, createdAt = "2099-01-01T00:00:00Z")), f.blocks[0].id, YieldVintageReport.sessionVintage(s, 7, 1), 7, 1)
        assertTrue(latest!!.isCompleted); assertNotNull(latest.completedAt)
    }
}
