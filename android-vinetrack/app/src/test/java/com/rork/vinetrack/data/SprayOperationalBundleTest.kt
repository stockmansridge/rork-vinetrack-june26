package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayApplicationPlanner
import com.rork.vinetrack.data.spray.SprayStartRateReview
import com.rork.vinetrack.data.spray.SprayStartRecipeValidation
import org.junit.Assert.*
import org.junit.Test

class SprayOperationalBundleTest {
    @Test fun independentTankAllocationValues() {
        val fixtures = listOf(
            listOf(350.0, 1000.0, 1.0, 0.0, 350.0), listOf(1000.0, 1000.0, 1.0, 0.0, 1000.0),
            listOf(2000.0, 1000.0, 2.0, 1.0, 1000.0), listOf(6250.0, 2000.0, 4.0, 3.0, 250.0),
            listOf(10000.0, 1.0, 10000.0, 9999.0, 1.0))
        for ((water, capacity, count, full, last) in fixtures) {
            val split = SprayApplicationPlanner.tankSplit(water, capacity)
            assertEquals(count.toInt(), split.totalTanks); assertEquals(full.toInt(), split.fullTankCount)
            assertEquals(last, split.lastTankLitres, 0.0); assertEquals(water, full * capacity + last, 0.0)
        }
    }

    @Test fun nonFiniteOrUnboundedTankAllocationsAreRejected() {
        listOf(Double.POSITIVE_INFINITY to 1000.0, 1000.0 to Double.NaN, 1000.0 to 0.0,
            Double.MAX_VALUE to Double.MIN_VALUE, 10001.0 to 1.0, -1.0 to 1000.0).forEach { (water, capacity) ->
            assertEquals(0, SprayApplicationPlanner.tankSplit(water, capacity).totalTanks)
        }
    }

    @Test fun actualConcentrationUsesTankQuantityAndBothStorageConventions() {
        val base = SprayChemical("a", "Product", volumePerTank = 6000.0, ratePer100L = 300.0,
            unit = "Litres", rateBasis = "per_100_litres")
        val display = base.copy(quantityBasis = "display", volumePerTank = 6.0, ratePer100L = 0.3)
        assertEquals(0.6, SprayStartRateReview.actualRate(base, 1000.0)!!, 0.000000001)
        assertEquals(0.6, SprayStartRateReview.actualRate(display, 1000.0)!!, 0.000000001)
        assertNull(SprayStartRateReview.actualRate(base, 0.0))
        assertEquals(2.0, SprayStartRateReview.actualRate(base.copy(rateBasis = "treated_area", ratePerHa = 2000.0), 1000.0)!!, 0.0)
        assertEquals(2.0, SprayStartRateReview.actualRate(display.copy(rateBasis = "treated_area", ratePerHa = 2.0), 1000.0)!!, 0.0)
    }

    @Test fun recipeEvidenceIgnoresGeneratedIdsButInvalidatesForChangedMix() {
        val a = SprayTank("a", waterVolume = 1000.0, sprayRatePerHa = 500.0,
            chemicals = listOf(SprayChemical("a", "Product", volumePerTank = 4000.0, ratePerHa = 2000.0)))
        val b = a.copy(id = "b", chemicals = a.chemicals.map { it.copy(id = "b") })
        assertEquals(SprayStartRateReview.evidence(listOf(a)), SprayStartRateReview.evidence(listOf(b)))
        assertNotEquals(SprayStartRateReview.evidence(listOf(a)), SprayStartRateReview.evidence(listOf(b.copy(waterVolume = 900.0))))
        assertNotEquals(SprayStartRateReview.evidence(listOf(a)), SprayStartRateReview.evidence(listOf(b.copy(chemicals = b.chemicals.map { it.copy(ratePerHa = 3000.0) }))))
    }

    @Test fun advisoryMetadataCannotBlockActualRateConfirmation() {
        val tank = SprayTank("a", waterVolume = 1000.0, concentrationFactor = 4.0,
            chemicals = listOf(SprayChemical("a", "Manual product", volumePerTank = 12000.0, ratePer100L = 300.0, rateBasis = "per_100_litres")))
        assertTrue(SprayStartRateReview.isReviewable(listOf(tank)))
        assertNull(SprayStartRecipeValidation.blocker(listOf(tank)))
        assertFalse(SprayStartRateReview.isReviewable(emptyList()))
    }

    @Test fun repeatedRefreshesCoalesceButScopesAndOldLeaseCleanupStaySeparate() {
        val gate = ScopedSyncReadGate()
        val scope = ScopedSyncReadGate.Scope("owner", 1, "vineyard", 1)
        val first = gate.acquire(scope)!!
        repeat(1000) { assertNull(gate.acquire(scope)) }
        val other = gate.acquire(scope.copy(vineyard = "other"))!!
        val nextIdentity = gate.acquire(scope.copy(identityEpoch = 2))!!
        gate.release(first)
        val next = gate.acquire(scope)!!
        gate.release(first)
        assertNull(gate.acquire(scope))
        gate.release(next); gate.release(other); gate.release(nextIdentity)
        assertNotNull(gate.acquire(scope))
    }
}
