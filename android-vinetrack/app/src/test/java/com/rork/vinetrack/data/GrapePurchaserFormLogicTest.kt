package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrapeAllocation
import com.rork.vinetrack.data.model.GrapeAllocationCalculator
import com.rork.vinetrack.data.model.GrapeAllocationFormLogic
import com.rork.vinetrack.data.model.GrapePurchaser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the sql/219 purchaser + allocation-form rules. Mirrors
 * `GrapePurchaserLogicTests.swift` on iOS so both platforms pin the same
 * behaviour:
 *  - selecting a saved purchaser SNAPSHOTS its current details onto the
 *    allocation (external only)
 *  - editing the purchaser later never rewrites an existing snapshot
 *  - Own Use can never carry a purchaser link or purchaser/contact data
 *  - one purchaser can back multiple allocations, each with its own
 *    contract (tonnes × THAT contract's $/t — never averaged)
 *  - additive block assignment must never exceed the committed quantity
 */
class GrapePurchaserFormLogicTest {

    private val vineyardId = "11111111-1111-4111-8111-111111111111"
    private val purchaserId = "22222222-2222-4222-8222-222222222222"

    private val purchaser = GrapePurchaser(
        id = purchaserId,
        vineyardId = vineyardId,
        wineryName = "Stone Hut Wines",
        contactName = "Alice",
        contactEmail = "alice@stonehut.test",
        contactPhone = "+61 400 000 001",
        contactAddress = "1 Cellar Lane",
    )

    private fun externalAllocation(tonnes: Double = 10.0, price: Double? = null) = GrapeAllocation(
        id = "33333333-3333-4333-8333-333333333333",
        vineyardId = vineyardId,
        vintage = 2027,
        allocationType = GrapeAllocation.TYPE_EXTERNAL,
        varietyName = "Shiraz",
        quantityTonnes = tonnes,
        pricePerTonne = price,
    )

    // ---- Purchaser snapshot ------------------------------------------------

    @Test
    fun selectingPurchaserCopiesCurrentDetailsOntoAllocation() {
        val linked = GrapeAllocationFormLogic.applyPurchaserSnapshot(externalAllocation(), purchaser)
        assertEquals(purchaserId, linked.purchaserId)
        assertEquals("Stone Hut Wines", linked.purchaserName)
        assertEquals("Alice", linked.contactName)
        assertEquals("alice@stonehut.test", linked.contactEmail)
        assertEquals("+61 400 000 001", linked.contactPhone)
        assertEquals("1 Cellar Lane", linked.contactAddress)
    }

    @Test
    fun editingPurchaserLaterDoesNotAlterOldAllocationSnapshot() {
        val linked = GrapeAllocationFormLogic.applyPurchaserSnapshot(externalAllocation(), purchaser)

        // The purchaser record is renamed AFTER the allocation was saved.
        val renamed = purchaser.copy(wineryName = "Stone Hut Renamed", contactEmail = "new@stonehut.test")

        // The old allocation keeps its own snapshot untouched.
        assertEquals("Stone Hut Wines", linked.purchaserName)
        assertEquals("alice@stonehut.test", linked.contactEmail)

        // A NEW allocation snapshots the NEW details.
        val newAllocation = GrapeAllocationFormLogic.applyPurchaserSnapshot(externalAllocation(), renamed)
        assertEquals("Stone Hut Renamed", newAllocation.purchaserName)
        assertEquals("new@stonehut.test", newAllocation.contactEmail)
    }

    @Test
    fun ownUseCannotCarryPurchaser() {
        val ownUse = GrapeAllocation(
            id = "44444444-4444-4444-8444-444444444444",
            vineyardId = vineyardId,
            vintage = 2027,
            allocationType = GrapeAllocation.TYPE_OWN_USE,
            varietyName = "Shiraz",
            quantityTonnes = 3.0,
        )
        // Applying a snapshot to Own Use is a no-op.
        val unchanged = GrapeAllocationFormLogic.applyPurchaserSnapshot(ownUse, purchaser)
        assertNull(unchanged.purchaserId)
        assertNull(unchanged.purchaserName)

        // And sanitising strips any stray purchaser data + price.
        val stray = ownUse.copy(purchaserId = purchaserId, purchaserName = "Stray", pricePerTonne = 999.0)
        val sanitized = GrapeAllocationFormLogic.sanitized(stray)
        assertNull(sanitized.purchaserId)
        assertNull(sanitized.purchaserName)
        assertNull(sanitized.contactEmail)
        assertNull(sanitized.pricePerTonne)
    }

    @Test
    fun sanitizedLeavesExternalAllocationUntouched() {
        val linked = GrapeAllocationFormLogic.applyPurchaserSnapshot(externalAllocation(price = 2400.0), purchaser)
        val sanitized = GrapeAllocationFormLogic.sanitized(linked)
        assertEquals(purchaserId, sanitized.purchaserId)
        assertEquals(2400.0, sanitized.pricePerTonne!!, 0.0001)
    }

    @Test
    fun onePurchaserBacksMultipleIndividualContracts() {
        val first = GrapeAllocationFormLogic.applyPurchaserSnapshot(
            externalAllocation(tonnes = 10.0, price = 2000.0).copy(id = "a1"), purchaser,
        )
        val second = GrapeAllocationFormLogic.applyPurchaserSnapshot(
            externalAllocation(tonnes = 5.0, price = 3000.0).copy(id = "a2"), purchaser,
        )
        assertEquals(first.purchaserId, second.purchaserId)
        // Each contract's value is tonnes × ITS OWN price — summed, never averaged.
        assertEquals(20_000.0, first.contractValue!!, 0.0001)
        assertEquals(15_000.0, second.contractValue!!, 0.0001)
        assertEquals(
            35_000.0,
            GrapeAllocationCalculator.totalContractedIncome(listOf(first, second), 2027),
            0.0001,
        )
    }

    // ---- Block assignment ---------------------------------------------------

    @Test
    fun blockAssignmentWithinQuantity() {
        val summary = GrapeAllocationFormLogic.blockAssignmentSummary(6.0, listOf(2.5, 1.5))
        assertEquals(4.0, summary.assignedTonnes, 0.0001)
        assertEquals(2.0, summary.unassignedTonnes, 0.0001)
        assertFalse(summary.exceedsQuantity)
    }

    @Test
    fun blockAssignmentCannotExceedCommittedQuantity() {
        val summary = GrapeAllocationFormLogic.blockAssignmentSummary(6.0, listOf(4.0, 3.0))
        assertEquals(7.0, summary.assignedTonnes, 0.0001)
        assertEquals(0.0, summary.unassignedTonnes, 0.0001)
        assertTrue(summary.exceedsQuantity)
    }

    @Test
    fun blockAssignmentIgnoresRowsWithoutTonnes() {
        val summary = GrapeAllocationFormLogic.blockAssignmentSummary(6.0, listOf(2.5, null, null))
        assertEquals(2.5, summary.assignedTonnes, 0.0001)
        assertEquals(3.5, summary.unassignedTonnes, 0.0001)
        assertFalse(summary.exceedsQuantity)
    }

    @Test
    fun blockAssignmentExactMatchIsNotAnOverrun() {
        val summary = GrapeAllocationFormLogic.blockAssignmentSummary(6.0, listOf(4.0, 2.0))
        assertFalse(summary.exceedsQuantity)
        assertEquals(0.0, summary.unassignedTonnes, 0.0001)
    }
}
