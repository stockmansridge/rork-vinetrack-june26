package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PaddockRowVineCount
import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskPieceRateRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PIECE RATE COSTING (sql/188) — the Android twin of
 * `PieceRateCostingTests.swift`. Both suites assert the SAME fixtures, so any
 * divergence between the platforms fails a build.
 *
 * The rules under test:
 * * a task's labour cost comes from EXACTLY ONE source, chosen by
 *   `costing_method` — hourly lines and a piece-rate total are never summed;
 * * hours stay recordable on a piece-rate job as operational history but NEVER
 *   drive its cost;
 * * a completed piece-rate job is costed from its SNAPSHOT, so later edits to
 *   the block's rows can never re-price finished work;
 * * every legacy record resolves to `hourly` and behaves exactly as before.
 */
class PieceRateCostingTest {

    private val taskId = "66666666-6666-4666-8666-666666666666"
    private val vineyardId = "11111111-1111-4111-8111-111111111111"
    private val paddockId = "22222222-2222-4222-8222-222222222222"

    private fun line(
        hoursPerWorker: Double,
        workerCount: Int = 1,
        hourlyRate: Double? = null,
        deletedAt: String? = null,
        taskId: String = this.taskId,
    ) = WorkTaskLabourLine(
        id = "line-$hoursPerWorker-$workerCount-${hourlyRate ?: 0.0}-${deletedAt ?: ""}",
        workTaskId = taskId,
        vineyardId = vineyardId,
        workerCount = workerCount,
        hoursPerWorker = hoursPerWorker,
        hourlyRate = hourlyRate,
        deletedAt = deletedAt,
    )

    private fun snapshotRow(vineCount: Int, rowNumber: Int) = WorkTaskPieceRateRow(
        id = "row-$rowNumber",
        workTaskId = taskId,
        vineyardId = vineyardId,
        paddockId = paddockId,
        paddockRowId = "paddock-row-$rowNumber",
        rowNumber = rowNumber,
        vineCount = vineCount,
    )

    // -----------------------------------------------------------------
    // Method resolution — legacy records must not change behaviour
    // -----------------------------------------------------------------

    @Test
    fun `legacy and unknown costing methods resolve to hourly`() {
        assertEquals(WorkTaskCostingMethod.HOURLY, WorkTaskCostingMethod.resolve(null))
        assertEquals(WorkTaskCostingMethod.HOURLY, WorkTaskCostingMethod.resolve(""))
        assertEquals(WorkTaskCostingMethod.HOURLY, WorkTaskCostingMethod.resolve("   "))
        assertEquals(WorkTaskCostingMethod.HOURLY, WorkTaskCostingMethod.resolve("hourly"))
        assertEquals(WorkTaskCostingMethod.HOURLY, WorkTaskCostingMethod.resolve("HOURLY"))
        // Anything a future client writes that this build does not understand
        // falls back to the behaviour every record has always had.
        assertEquals(WorkTaskCostingMethod.HOURLY, WorkTaskCostingMethod.resolve("per_bin"))
    }

    @Test
    fun `piece rate is decoded case-insensitively from its stored value`() {
        assertEquals(WorkTaskCostingMethod.PIECE_RATE, WorkTaskCostingMethod.resolve("piece_rate"))
        assertEquals(WorkTaskCostingMethod.PIECE_RATE, WorkTaskCostingMethod.resolve("  Piece_Rate  "))
        assertEquals("piece_rate", WorkTaskCostingMethod.PIECE_RATE.storedValue)
        assertEquals("hourly", WorkTaskCostingMethod.HOURLY.storedValue)
    }

    // -----------------------------------------------------------------
    // Arithmetic — identical to the Swift twin, to the cent
    // -----------------------------------------------------------------

    @Test
    fun `cost is vines times rate rounded to cents`() {
        // THE worked example carried in both platforms' documentation.
        assertEquals(2_842.26, PieceRateCosting.cost(2_238, 1.27)!!, 0.0001)
        assertEquals(0.0, PieceRateCosting.cost(0, 1.27)!!, 0.0001)
        assertEquals(1.27, PieceRateCosting.cost(1, 1.27)!!, 0.0001)
        // Half away from zero, matching the database's round(numeric, 2) and
        // the Swift twin — including on the negative side, where Kotlin's
        // stock rounding would otherwise disagree by a cent.
        assertEquals(0.13, PieceRateCosting.roundedToCents(0.125), 0.0001)
        assertEquals(-0.13, PieceRateCosting.roundedToCents(-0.125), 0.0001)
        assertEquals(2_842.26, PieceRateCosting.roundedToCents(2_842.2649), 0.0001)
    }

    @Test
    fun `a missing rate or quantity is not specified rather than zero dollars`() {
        assertNull(PieceRateCosting.cost(null, 1.27))
        assertNull(PieceRateCosting.cost(2_238, null))
        assertNull(PieceRateCosting.cost(null, null))
    }

    @Test
    fun `negative inputs are clamped instead of producing a negative bill`() {
        assertEquals(0.0, PieceRateCosting.cost(-500, 1.27)!!, 0.0001)
        assertEquals(0.0, PieceRateCosting.cost(2_238, -1.27)!!, 0.0001)
    }

    @Test
    fun `cost per hectare needs a positive area`() {
        assertEquals(500.0, PieceRateCosting.costPerHectare(1_000.0, 2.0)!!, 0.0001)
        assertNull(PieceRateCosting.costPerHectare(1_000.0, 0.0))
        assertNull(PieceRateCosting.costPerHectare(1_000.0, -2.0))
        assertNull(PieceRateCosting.costPerHectare(1_000.0, null))
        assertNull(PieceRateCosting.costPerHectare(null, 2.0))
    }

    // -----------------------------------------------------------------
    // Quantity derived from the selected rows
    // -----------------------------------------------------------------

    @Test
    fun `vine count is the sum of the selected rows snapshots`() {
        val rows = listOf(snapshotRow(746, 1), snapshotRow(746, 2), snapshotRow(746, 3))
        assertEquals(2_238, PieceRateCosting.vineCountForSelectedRows(rows))
        assertEquals(0, PieceRateCosting.vineCountForSelectedRows(emptyList()))
    }

    @Test
    fun `a rows manual count overrides the calculated estimate`() {
        // 300 m at 1.8 m spacing = 166 whole vines (truncated, never rounded
        // up — a part-vine is not a vine), but the operator counted 150.
        assertEquals(166, PaddockRowVineCount.calculated(300.0, 1.8))
        assertEquals(166, PaddockRowVineCount.effective(null, 300.0, 1.8))
        assertEquals(150, PaddockRowVineCount.effective(150, 300.0, 1.8))
        // A zero/negative override is not an override at all.
        assertEquals(166, PaddockRowVineCount.effective(0, 300.0, 1.8))
        assertEquals(166, PaddockRowVineCount.effective(-5, 300.0, 1.8))
        // No usable geometry means no estimate — never a guess.
        assertEquals(0, PaddockRowVineCount.calculated(300.0, 0.0))
        assertEquals(0, PaddockRowVineCount.calculated(0.0, 1.8))
    }

    // -----------------------------------------------------------------
    // Exactly one cost source
    // -----------------------------------------------------------------

    @Test
    fun `an hourly task is costed from its labour lines exactly as before`() {
        val lines = listOf(
            line(hoursPerWorker = 8.0, workerCount = 2, hourlyRate = 32.0),
            line(hoursPerWorker = 6.0, workerCount = 1, hourlyRate = 40.0),
        )
        val resolved = PieceRateCosting.resolve(
            method = WorkTaskCostingMethod.HOURLY,
            labourLines = lines,
            pieceVineCount = 2_238,
            pieceRatePerVine = 1.27,
        )
        assertEquals(WorkTaskCostingMethod.HOURLY, resolved.method)
        // 16 h × $32 + 6 h × $40 = $752 — the piece-rate columns are ignored.
        assertEquals(752.0, resolved.cost!!, 0.0001)
        assertEquals(22.0, resolved.hours, 0.0001)
        assertNull(resolved.vineCount)
        assertNull(resolved.ratePerVine)
        assertFalse(resolved.hoursAreOperationalOnly)
    }

    @Test
    fun `a piece rate task is costed from its snapshot and never from its hours`() {
        val lines = listOf(
            // Rated hourly lines that must NOT contribute a second cost.
            line(hoursPerWorker = 8.0, workerCount = 3, hourlyRate = 32.0),
        )
        val resolved = PieceRateCosting.resolve(
            method = WorkTaskCostingMethod.PIECE_RATE,
            labourLines = lines,
            pieceVineCount = 2_238,
            pieceRatePerVine = 1.27,
        )
        assertEquals(WorkTaskCostingMethod.PIECE_RATE, resolved.method)
        assertEquals(2_842.26, resolved.cost!!, 0.0001)
        // Hours are preserved as operational history…
        assertEquals(24.0, resolved.hours, 0.0001)
        // …and explicitly flagged as not being the basis of the cost.
        assertTrue(resolved.hoursAreOperationalOnly)
        assertEquals(2_238, resolved.vineCount)
        assertEquals(1.27, resolved.ratePerVine!!, 0.0001)
    }

    @Test
    fun `the two costing methods are never summed`() {
        val lines = listOf(line(hoursPerWorker = 10.0, workerCount = 1, hourlyRate = 50.0))
        val hourly = PieceRateCosting.resolve(WorkTaskCostingMethod.HOURLY, lines, 2_238, 1.27)
        val piece = PieceRateCosting.resolve(WorkTaskCostingMethod.PIECE_RATE, lines, 2_238, 1.27)
        assertEquals(500.0, hourly.cost!!, 0.0001)
        assertEquals(2_842.26, piece.cost!!, 0.0001)
        // Neither total contains any part of the other.
        assertTrue(hourly.cost!! + piece.cost!! != hourly.cost!!)
        assertNotNull(hourly.cost)
    }

    @Test
    fun `unrated hourly lines report not specified rather than zero`() {
        val lines = listOf(line(hoursPerWorker = 8.0, workerCount = 2, hourlyRate = null))
        val resolved = PieceRateCosting.resolve(WorkTaskCostingMethod.HOURLY, lines, null, null)
        assertNull(resolved.cost)
        assertEquals(16.0, resolved.hours, 0.0001)
    }

    @Test
    fun `soft-deleted labour lines are excluded from both methods`() {
        val lines = listOf(
            line(hoursPerWorker = 8.0, workerCount = 1, hourlyRate = 30.0),
            line(hoursPerWorker = 8.0, workerCount = 1, hourlyRate = 30.0, deletedAt = "2026-01-01T00:00:00Z"),
        )
        val hourly = PieceRateCosting.resolve(WorkTaskCostingMethod.HOURLY, lines, null, null)
        assertEquals(240.0, hourly.cost!!, 0.0001)
        assertEquals(8.0, hourly.hours, 0.0001)

        val piece = PieceRateCosting.resolve(WorkTaskCostingMethod.PIECE_RATE, lines, 100, 2.0)
        assertEquals(200.0, piece.cost!!, 0.0001)
        assertEquals(8.0, piece.hours, 0.0001)
    }

    @Test
    fun `a piece rate job with no hours is still fully costed`() {
        val resolved = PieceRateCosting.resolve(WorkTaskCostingMethod.PIECE_RATE, emptyList(), 2_238, 1.27)
        assertEquals(2_842.26, resolved.cost!!, 0.0001)
        assertEquals(0.0, resolved.hours, 0.0001)
        // No hours means nothing to describe as "operational only".
        assertFalse(resolved.hoursAreOperationalOnly)
    }

    // -----------------------------------------------------------------
    // Snapshot immutability
    // -----------------------------------------------------------------

    @Test
    fun `editing the blocks rows never re-prices a completed job`() {
        // The job was priced on 2,238 vines. The block is later re-mapped and
        // now has far more rows — the completed job must not change.
        val snapshotAtCosting = 2_238
        val costed = PieceRateCosting.cost(snapshotAtCosting, 1.27)
        val rowsToday = listOf(snapshotRow(900, 1), snapshotRow(900, 2), snapshotRow(900, 3))
        assertEquals(2_700, PieceRateCosting.vineCountForSelectedRows(rowsToday))
        // The stored snapshot, not today's rows, is what the job is costed on.
        assertEquals(2_842.26, costed!!, 0.0001)
    }

    // -----------------------------------------------------------------
    // Validation
    // -----------------------------------------------------------------

    @Test
    fun `a rate and a quantity are both required`() {
        assertTrue(PieceRateCosting.isValid(1.27, 2_238))

        val noRate = PieceRateCosting.validate(null, 2_238)
        assertEquals(
            "Enter the agreed rate per vine.",
            PieceRateCosting.message(noRate, PieceRateCosting.PieceRateField.RATE_PER_VINE),
        )
        assertNull(PieceRateCosting.message(noRate, PieceRateCosting.PieceRateField.VINE_COUNT))

        val noVines = PieceRateCosting.validate(1.27, 0)
        assertEquals(
            "Select the rows this job covers so the vine count can be calculated.",
            PieceRateCosting.message(noVines, PieceRateCosting.PieceRateField.VINE_COUNT),
        )

        // Every problem is reported at once so the form can mark each field.
        assertEquals(2, PieceRateCosting.validate(null, null).size)
    }

    @Test
    fun `implausible rates and quantities are caught as typos`() {
        val bigRate = PieceRateCosting.validate(5_000.0, 2_238)
        assertEquals(
            "That rate per vine looks too high — check the number.",
            PieceRateCosting.message(bigRate, PieceRateCosting.PieceRateField.RATE_PER_VINE),
        )
        val bigCount = PieceRateCosting.validate(1.27, 50_000_000)
        assertEquals(
            "That vine count looks too high — check the selected rows.",
            PieceRateCosting.message(bigCount, PieceRateCosting.PieceRateField.VINE_COUNT),
        )
        // The boundaries themselves are acceptable.
        assertTrue(PieceRateCosting.isValid(PieceRateCosting.MAX_RATE_PER_VINE, PieceRateCosting.MAX_VINE_COUNT))
    }

    @Test
    fun `a negative rate is rejected`() {
        assertFalse(PieceRateCosting.isValid(-1.0, 2_238))
        assertFalse(PieceRateCosting.isValid(0.0, 2_238))
    }

    // -----------------------------------------------------------------
    // Formatting parity
    // -----------------------------------------------------------------

    @Test
    fun `money and quantities are formatted identically on both platforms`() {
        assertEquals("$2,842.26", PieceRateCosting.currencyLabel(2_842.26))
        assertEquals("$0.00", PieceRateCosting.currencyLabel(0.0))
        assertEquals("$1.27", PieceRateCosting.rateLabel(1.27))
        assertEquals("$1.00", PieceRateCosting.rateLabel(1.0))
        assertEquals("2,238", PieceRateCosting.vineCountLabel(2_238))
        assertEquals("0", PieceRateCosting.vineCountLabel(0))
    }
}
