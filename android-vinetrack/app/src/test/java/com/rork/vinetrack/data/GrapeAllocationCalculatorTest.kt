package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrapeAllocation
import com.rork.vinetrack.data.model.GrapeAllocationBlock
import com.rork.vinetrack.data.model.GrapeAllocationCalculator
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the Grape Allocation calculator. Mirrors
 * `GrapeAllocationLogicTests.swift` on iOS so both platforms pin the same
 * rules:
 *  - supply comes from the latest Yield Estimate rows and is split across a
 *    block's variety allocations by percent share
 *  - a NEW estimate changes the balance without touching any allocation
 *  - Balance = Estimated − Own Use − External; negative = Shortfall
 *  - money totals are sums of INDIVIDUAL contract values (tonnes × that
 *    contract's $/t), never an averaged $/t
 *  - a commitment split across multiple blocks attributes income per block
 */
class GrapeAllocationCalculatorTest {

    private val vineyardId = "11111111-1111-4111-8111-111111111111"
    private val blockA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val blockB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private val paddocks = listOf(
        Paddock(
            id = blockA,
            vineyardId = vineyardId,
            name = "Shiraz North",
            varietyAllocations = listOf(
                PaddockVarietyAllocation(varietyName = "Shiraz", percentage = 100.0),
            ),
        ),
        Paddock(
            id = blockB,
            vineyardId = vineyardId,
            name = "River Block",
            varietyAllocations = listOf(
                PaddockVarietyAllocation(varietyName = "Shiraz", percentage = 60.0),
                PaddockVarietyAllocation(varietyName = "Grenache", percentage = 40.0),
            ),
        ),
    )

    private fun estimateRow(blockId: String, blockName: String, tonnes: Double) =
        YieldVintageReport.EstimateRow(
            paddockId = blockId,
            blockName = blockName,
            varietyLabel = "",
            areaHectares = 1.0,
            baseTonnes = tonnes,
            adjustedTonnes = tonnes,
            damageFactor = 1.0,
            applyDamage = false,
            averageBunchesPerVine = 0.0,
            samplesRecorded = 1,
            samplesTotal = 1,
            sessionId = "session",
            completedAt = null,
        )

    private fun allocation(
        type: String,
        variety: String,
        tonnes: Double,
        vintage: Int = 2027,
        purchaser: String? = null,
        price: Double? = null,
        blocks: List<GrapeAllocationBlock> = emptyList(),
        id: String = java.util.UUID.randomUUID().toString(),
    ) = GrapeAllocation(
        id = id,
        vineyardId = vineyardId,
        vintage = vintage,
        allocationType = type,
        varietyName = variety,
        quantityTonnes = tonnes,
        purchaserName = purchaser,
        pricePerTonne = price,
        blocks = blocks,
    )

    private fun block(paddockId: String, name: String, tonnes: Double? = null) =
        GrapeAllocationBlock(
            id = java.util.UUID.randomUUID().toString(),
            allocationId = "a",
            vineyardId = vineyardId,
            paddockId = paddockId,
            paddockName = name,
            quantityTonnes = tonnes,
        )

    // ------------------------------------------ supply split by variety share

    @Test
    fun `variety estimates split blocks by allocation share`() {
        val estimates = GrapeAllocationCalculator.varietyEstimates(
            listOf(
                estimateRow(blockA, "Shiraz North", 10.0),
                estimateRow(blockB, "River Block", 5.0),
            ),
            paddocks,
        )
        // Shiraz: 10 (block A) + 5 × 60% (block B) = 13; Grenache: 5 × 40% = 2.
        assertEquals(13.0, estimates["shiraz"]?.tonnes ?: 0.0, 1e-4)
        assertEquals(2.0, estimates["grenache"]?.tonnes ?: 0.0, 1e-4)
    }

    // ---------------------------------------------------- balance & shortfall

    @Test
    fun `available becomes shortfall when over-committed`() {
        val estimates = GrapeAllocationCalculator.varietyEstimates(
            listOf(estimateRow(blockA, "Shiraz North", 10.0)),
            paddocks,
        )
        val allocations = listOf(
            allocation(GrapeAllocation.TYPE_OWN_USE, "Shiraz", 3.0),
            allocation(GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 5.0, purchaser = "Winery A"),
        )
        val summary = GrapeAllocationCalculator.summary(estimates, allocations, 2027)
        assertEquals(2.0, summary.balanceTonnes, 1e-4)
        assertFalse(summary.isShortfall)

        val overCommitted = allocations +
            allocation(GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 4.0, purchaser = "Winery B")
        val short = GrapeAllocationCalculator.summary(estimates, overCommitted, 2027)
        assertEquals(-2.0, short.balanceTonnes, 1e-4)
        assertTrue(short.isShortfall)
    }

    @Test
    fun `new yield estimate moves balance without touching allocations`() {
        val allocations = listOf(
            allocation(GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 8.0, purchaser = "Winery A"),
        )

        // First trip estimated 10 t → 2 t available.
        val before = GrapeAllocationCalculator.summary(
            GrapeAllocationCalculator.varietyEstimates(listOf(estimateRow(blockA, "Shiraz North", 10.0)), paddocks),
            allocations, 2027,
        )
        assertEquals(2.0, before.balanceTonnes, 1e-4)
        assertFalse(before.isShortfall)

        // A NEWER completed trip (latest wins) estimates only 6 t: the SAME
        // allocation records now show a 2 t shortfall.
        val after = GrapeAllocationCalculator.summary(
            GrapeAllocationCalculator.varietyEstimates(listOf(estimateRow(blockA, "Shiraz North", 6.0)), paddocks),
            allocations, 2027,
        )
        assertEquals(-2.0, after.balanceTonnes, 1e-4)
        assertTrue(after.isShortfall)
    }

    @Test
    fun `variety rows flag per-variety shortfall`() {
        val estimates = GrapeAllocationCalculator.varietyEstimates(
            listOf(estimateRow(blockB, "River Block", 5.0)),
            paddocks,
        )
        val rows = GrapeAllocationCalculator.varietyRows(
            estimates,
            listOf(allocation(GrapeAllocation.TYPE_EXTERNAL, "Grenache", 3.0, purchaser = "Winery A")),
            2027,
        )
        val grenache = rows.first { it.varietyKey == "grenache" }
        assertEquals(2.0, grenache.estimatedTonnes, 1e-4)
        assertEquals(3.0, grenache.externalTonnes, 1e-4)
        assertEquals(-1.0, grenache.balanceTonnes, 1e-4)
        assertTrue(grenache.isShortfall)

        // Shiraz has estimate but no allocation — still listed, no shortfall.
        val shiraz = rows.first { it.varietyKey == "shiraz" }
        assertEquals(3.0, shiraz.balanceTonnes, 1e-4)
        assertFalse(shiraz.isShortfall)
    }

    // -------------------------- money: individual contract values, never averaged

    @Test
    fun `contracts at different prices total individually`() {
        val allocations = listOf(
            allocation(GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 20.0, purchaser = "Winery A", price = 2500.0),
            allocation(GrapeAllocation.TYPE_EXTERNAL, "Chardonnay", 10.0, purchaser = "Winery B", price = 1800.0),
            // No price → contributes nothing (not a zero-priced average input).
            allocation(GrapeAllocation.TYPE_EXTERNAL, "Merlot", 5.0, purchaser = "Winery C"),
            // Own use never contributes income.
            allocation(GrapeAllocation.TYPE_OWN_USE, "Shiraz", 3.0),
        )
        // 20×2500 + 10×1800 = 68 000 — NOT (35 t × averaged $/t).
        assertEquals(68000.0, GrapeAllocationCalculator.totalContractedIncome(allocations, 2027), 1e-4)

        val byPurchaser = GrapeAllocationCalculator.incomeByPurchaser(allocations, 2027)
        assertEquals(50000.0, byPurchaser.first { it.label == "Winery A" }.value, 1e-4)
        assertEquals(18000.0, byPurchaser.first { it.label == "Winery B" }.value, 1e-4)
        assertNull(byPurchaser.firstOrNull { it.label == "Winery C" })

        val byVariety = GrapeAllocationCalculator.incomeByVariety(allocations, 2027)
        assertEquals(50000.0, byVariety.first { it.label == "Shiraz" }.value, 1e-4)
    }

    @Test
    fun `commitment split across multiple blocks attributes income per block`() {
        val contract = allocation(
            GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 15.0, purchaser = "Winery A", price = 2000.0,
            blocks = listOf(
                block(blockA, "Shiraz North", 9.0),
                block(blockB, "River Block", 6.0),
            ),
        )
        val byBlock = GrapeAllocationCalculator.incomeByBlock(listOf(contract), 2027)
        assertEquals(18000.0, byBlock.first { it.label == "Shiraz North" }.value, 1e-4)
        assertEquals(12000.0, byBlock.first { it.label == "River Block" }.value, 1e-4)
    }

    @Test
    fun `block split shares remainder and handles unassigned`() {
        // One block with an explicit 9 t, two without: they share 15−9 = 6 t.
        val mixed = allocation(
            GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 15.0, purchaser = "W", price = 1000.0,
            blocks = listOf(
                block(blockA, "A", 9.0),
                block(blockB, "B"),
                block("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "C"),
            ),
        )
        val split = GrapeAllocationCalculator.blockTonnesSplit(mixed).toMap()
        assertEquals(9.0, split["A"] ?: 0.0, 1e-4)
        assertEquals(3.0, split["B"] ?: 0.0, 1e-4)
        assertEquals(3.0, split["C"] ?: 0.0, 1e-4)

        // No blocks at all → everything lands under "Unassigned".
        val unassigned = allocation(GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 4.0, purchaser = "W", price = 1000.0)
        val byBlock = GrapeAllocationCalculator.incomeByBlock(listOf(unassigned), 2027)
        assertEquals(4000.0, byBlock.first { it.label == "Unassigned" }.value, 1e-4)
    }

    // ------------------------------------ financial privacy at the model layer

    @Test
    fun `allocation without price never produces a contract value`() {
        // A non-owner/manager device never receives prices — its model rows
        // therefore can never derive money.
        val masked = allocation(GrapeAllocation.TYPE_EXTERNAL, "Shiraz", 20.0, purchaser = "Winery A")
        assertNull(masked.contractValue)
        assertEquals(0.0, GrapeAllocationCalculator.totalContractedIncome(listOf(masked), 2027), 1e-9)
        assertTrue(GrapeAllocationCalculator.incomeByPurchaser(listOf(masked), 2027).isEmpty())
        assertTrue(GrapeAllocationCalculator.incomeByBlock(listOf(masked), 2027).isEmpty())
    }
}
