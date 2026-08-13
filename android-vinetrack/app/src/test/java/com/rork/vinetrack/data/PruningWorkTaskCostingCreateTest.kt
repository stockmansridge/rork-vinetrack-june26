package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningAllocationEditor
import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * CREATING A PRUNING WORK TASK **WITH ITS COSTING** (sql/188) — the Android twin
 * of `PruningWorkTaskCostingCreateTests.swift`. Both suites assert the SAME
 * fixtures, so any divergence between the platforms fails a build.
 *
 * The regression these tests lock down: "Create Work Task" in the pruning
 * activity editor opened a generic dialog with only a title, notes and a
 * completed toggle. It had no costing method, no hourly inputs and no piece
 * rate, so the operator created an incomplete task and had to go and price it
 * somewhere else.
 *
 * The fixture is the one from the field report:
 * ```text
 * Merlot · rows 45–46 · 8 quarters · 499 vines
 * 499 × $1.27 = $633.73
 * ```
 */
class PruningWorkTaskCostingCreateTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val merlot = "22222222-2222-4222-8222-222222222222"
    private val activityId = "55555555-5555-4555-8555-555555555555"
    private val taskId = "66666666-6666-4666-8666-666666666666"
    private val row45 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val row46 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    /**
     * Merlot's two rows. Different vine counts on purpose, so a quarter
     * selection cannot be faked by averaging.
     */
    private val merlotRows: List<PruningRowRef> = listOf(
        PruningRowRef(rowId = row45, number = 45, label = "45", lengthMetres = 500.0, vines = 250.0, isFallback = false),
        PruningRowRef(rowId = row46, number = 46, label = "46", lengthMetres = 498.0, vines = 249.0, isFallback = false),
    )

    private fun segment(rowId: String, number: Int, quarter: Int) =
        PruningSegment(row = number, quarter = quarter, rowId = rowId)

    /** Every quarter of rows 45 and 46 — the screenshot's 8 quarters / 499 vines. */
    private val wholeRowSegments: List<PruningSegment> =
        (1..4).map { segment(row45, 45, it) } + (1..4).map { segment(row46, 46, it) }

    /** A PARTIAL selection: half of row 45, three quarters of row 46. */
    private val partialSegments: List<PruningSegment> =
        (1..2).map { segment(row45, 45, it) } + (1..3).map { segment(row46, 46, it) }

    /**
     * The activity exactly as the editor builds it: segments chosen, then the
     * vine estimate re-derived from THOSE segments.
     */
    private fun activity(
        segments: List<PruningSegment>,
        labourHours: Double? = null,
    ): PruningActivityDraft {
        var draft = PruningActivityDraft(
            id = activityId,
            vineyardId = vineyard,
            date = "2026-08-13",
            worker = "Crew",
            method = "spur",
            labourHours = labourHours,
        )
        draft = PruningAllocationEditor.setSegments(draft, merlot, segments, "Merlot")
        draft = PruningAllocationEditor.setEstimatedVines(
            draft,
            merlot,
            PruningCalculator.vines(segments, merlotRows),
        )
        return draft
    }

    // ---- the activity's own quantity feeds the costing ----------------------

    @Test
    fun `the activity summary quantity is exactly what piece rate costs`() {
        val draft = activity(wholeRowSegments)

        // The number the Activity Summary shows…
        assertEquals(8, draft.totalQuarters)
        assertEquals(499, draft.totalEstimatedVines)
        // …is the number the create dialog prices, with nothing re-entered.
        assertEquals(499, PruningActivityTaskLink.vineCount(draft))
        assertEquals(499, PruningActivityTaskLink.createDraft(draft).vineCount)
    }

    @Test
    fun `creating from a pruning activity defaults to hourly`() {
        val create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))

        assertEquals(WorkTaskCostingMethod.HOURLY, create.costingMethod)
        assertFalse(create.isPieceRate)
        // Existing behaviour is untouched: a task with no costing entered is
        // still creatable, exactly as it always was.
        assertTrue(create.isValid)
        assertEquals("Pruning", create.trimmedType)
        assertTrue(create.markCompleted)
    }

    @Test
    fun `the activity hours seed the hourly form`() {
        val create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments, labourHours = 8.0))

        assertEquals(8.0, create.hoursPerWorker!!, 0.0001)
        assertEquals(1, create.workerCount)
        // No hours recorded on the activity leaves the field empty rather than
        // inventing a zero.
        assertNull(PruningActivityTaskLink.createDraft(activity(wholeRowSegments)).hoursPerWorker)
    }

    // ---- piece rate arithmetic ---------------------------------------------

    @Test
    fun `piece rate cost is quantity times rate`() {
        val create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(costingMethod = WorkTaskCostingMethod.PIECE_RATE, ratePerVine = 1.27)

        // 499 × $1.27 = $633.73 — the exact figure the dialog previews.
        assertEquals(633.73, create.estimatedCost!!, 0.0001)
        assertTrue(create.isValid)
        assertEquals("$633.73", PieceRateCosting.currencyLabel(create.estimatedCost!!))
    }

    @Test
    fun `a piece rate job cannot be created without a complete agreement`() {
        var create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(costingMethod = WorkTaskCostingMethod.PIECE_RATE)

        // No rate agreed yet — the cost has no other source, so Create is refused.
        assertFalse(create.isValid)
        assertNull(create.estimatedCost)

        create = create.copy(ratePerVine = 0.0)
        assertFalse(create.isValid)

        create = create.copy(ratePerVine = 1.27)
        assertTrue(create.isValid)

        // A quantity of zero means no rows were selected — never priced as $0.
        create = create.copy(vineCount = 0)
        assertFalse(create.isValid)
    }

    @Test
    fun `an hourly job can be created before the crews hours are known`() {
        val create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(hoursPerWorker = null)

        // Hourly labour is optional at creation: the task is real, its labour
        // lines land later. This is the pre-existing behaviour.
        assertTrue(create.isValid)
        assertFalse(create.recordsHourlyLabour)
        assertNull(create.estimatedCost)
    }

    @Test
    fun `hourly cost uses the standard labour arithmetic`() {
        val create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(workerCount = 1, hoursPerWorker = 8.0, hourlyRate = 32.50)

        // 1 person × 8 h × $32.50 = $260.00, straight through
        // WorkTaskLabourCosting — never a second hourly calculation.
        assertEquals(8.0, create.personHours, 0.0001)
        assertEquals(260.0, create.estimatedCost!!, 0.0001)
        assertTrue(create.recordsHourlyLabour)
    }

    @Test
    fun `the two costing bases are never summed`() {
        var create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(workerCount = 3, hoursPerWorker = 8.0, hourlyRate = 32.50, ratePerVine = 1.27)

        // Hourly selected: the piece rate sitting in the draft contributes nothing.
        assertEquals(780.0, create.estimatedCost!!, 0.0001)

        // Piece rate selected: the hours are kept as operational history, and
        // the cost is the agreement alone — not $780 + $633.73.
        create = create.copy(costingMethod = WorkTaskCostingMethod.PIECE_RATE)
        assertEquals(633.73, create.estimatedCost!!, 0.0001)
        assertEquals(24.0, create.personHours, 0.0001)
    }

    // ---- quarter-row handling ----------------------------------------------

    @Test
    fun `quarter selections price quarters not whole rows`() {
        val draft = activity(partialSegments)

        // 250 × 2/4 + 249 × 3/4 = 125 + 186.75 = 311.75 → 312 vines.
        // Emphatically NOT the 499 vines of two whole rows.
        assertEquals(5, draft.totalQuarters)
        assertEquals(312, draft.totalEstimatedVines)

        val create = PruningActivityTaskLink.createDraft(draft)
            .copy(costingMethod = WorkTaskCostingMethod.PIECE_RATE, ratePerVine = 1.27)
        assertEquals(312, create.vineCount)
        assertEquals(396.24, create.estimatedCost!!, 0.0001)
    }

    @Test
    fun `the snapshot breaks the quantity down by row`() {
        var seq = 0
        val snapshot = PruningActivityTaskLink.pieceRateRows(
            activity = activity(partialSegments),
            workTaskId = taskId,
            vineyardId = vineyard,
            rowsByPaddock = mapOf(merlot to merlotRows),
            newId = { "snapshot-${seq++}" },
        )

        assertEquals(2, snapshot.size)
        assertEquals(listOf(45, 46), snapshot.map { it.rowNumber })
        // Each row is snapshotted at ITS OWN quarter share.
        assertEquals(listOf(125, 187), snapshot.map { it.vineCount })
        assertTrue(snapshot.all { it.workTaskId == taskId })
        assertTrue(snapshot.all { it.paddockId == merlot })
        assertEquals(listOf(row45, row46), snapshot.map { it.paddockRowId })
    }

    @Test
    fun `whole row selections snapshot every vine of each row`() {
        var seq = 0
        val snapshot = PruningActivityTaskLink.pieceRateRows(
            activity = activity(wholeRowSegments),
            workTaskId = taskId,
            vineyardId = vineyard,
            rowsByPaddock = mapOf(merlot to merlotRows),
            newId = { "snapshot-${seq++}" },
        )

        assertEquals(listOf(250, 249), snapshot.map { it.vineCount })
        // The breakdown reconciles to the priced quantity.
        assertEquals(499, snapshot.sumOf { it.vineCount })
    }

    @Test
    fun `rows with no selected quarters are never snapshotted`() {
        var seq = 0
        val onlyRow46 = (1..4).map { segment(row46, 46, it) }
        val snapshot = PruningActivityTaskLink.pieceRateRows(
            activity = activity(onlyRow46),
            workTaskId = taskId,
            vineyardId = vineyard,
            rowsByPaddock = mapOf(merlot to merlotRows),
            newId = { "snapshot-${seq++}" },
        )

        assertEquals(listOf(46), snapshot.map { it.rowNumber })
        assertEquals(listOf(249), snapshot.map { it.vineCount })
    }

    @Test
    fun `vine rounding is half away from zero`() {
        // The same rule as the per-row vine-count calculation, so no platform
        // ever reports a vine another does not.
        assertEquals(187, PruningActivityTaskLink.roundVines(186.75))
        assertEquals(1, PruningActivityTaskLink.roundVines(0.5))
        assertEquals(2, PruningActivityTaskLink.roundVines(1.5))
        assertEquals(3, PruningActivityTaskLink.roundVines(2.5))
        assertEquals(-3, PruningActivityTaskLink.roundVines(-2.5))
        assertEquals(0, PruningActivityTaskLink.roundVines(0.0))
        assertEquals(0, PruningActivityTaskLink.roundVines(Double.NaN))
    }

    // ---- what the created task carries --------------------------------------

    @Test
    fun `a piece rate task is born with its snapshot and costs from it`() {
        val create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(costingMethod = WorkTaskCostingMethod.PIECE_RATE, ratePerVine = 1.27)

        // The task the create flow writes.
        val task = WorkTask(
            id = taskId,
            vineyardId = vineyard,
            date = "2026-08-13",
            taskType = create.trimmedType,
            costingMethod = create.costingMethod.storedValue,
            pieceRatePerVine = create.ratePerVine,
            pieceVineCount = create.vineCount,
        )

        assertTrue(task.isPieceRate)
        assertEquals(633.73, task.pieceRateCost!!, 0.0001)

        // Reopening it later resolves from the SNAPSHOT — hours recorded
        // afterwards never re-cost it.
        val resolved = PieceRateCosting.resolve(
            task = task,
            labourLines = listOf(
                WorkTaskLabourLine(
                    id = "line-1",
                    workTaskId = taskId,
                    vineyardId = vineyard,
                    workerCount = 3,
                    hoursPerWorker = 8.0,
                    hourlyRate = 32.50,
                ),
            ),
        )
        assertEquals(WorkTaskCostingMethod.PIECE_RATE, resolved.method)
        assertEquals(633.73, resolved.cost!!, 0.0001)
        assertEquals(499, resolved.vineCount)
        assertEquals(1.27, resolved.ratePerVine!!, 0.0001)
        assertEquals(24.0, resolved.hours, 0.0001)
        assertTrue(resolved.hoursAreOperationalOnly)
    }

    @Test
    fun `an hourly task is born with no piece rate columns`() {
        val create = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(hoursPerWorker = 8.0, hourlyRate = 32.50)

        val isPieceRate = create.isPieceRate
        val task = WorkTask(
            id = taskId,
            vineyardId = vineyard,
            date = "2026-08-13",
            taskType = create.trimmedType,
            costingMethod = create.costingMethod.storedValue,
            pieceRatePerVine = if (isPieceRate) create.ratePerVine else null,
            pieceVineCount = if (isPieceRate) create.vineCount else null,
        )

        assertEquals(WorkTaskCostingMethod.HOURLY, task.resolvedCostingMethod)
        assertNull(task.pieceRatePerVine)
        assertNull(task.pieceVineCount)
        assertNull(task.pieceRateCost)

        // Its cost comes from the labour line the create flow wrote alongside it.
        val resolved = PieceRateCosting.resolve(
            task = task,
            labourLines = listOf(
                WorkTaskLabourLine(
                    id = "line-1",
                    workTaskId = taskId,
                    vineyardId = vineyard,
                    workerCount = create.workerCount,
                    hoursPerWorker = create.hoursPerWorker!!,
                    hourlyRate = create.hourlyRate,
                ),
            ),
        )
        assertEquals(WorkTaskCostingMethod.HOURLY, resolved.method)
        assertEquals(260.0, resolved.cost!!, 0.0001)
        assertEquals(8.0, resolved.hours, 0.0001)
    }

    @Test
    fun `the labour seed carries the hourly line and drops a piece rate's rate`() {
        val hourly = PruningActivityTaskLink.createDraft(activity(wholeRowSegments))
            .copy(hoursPerWorker = 8.0, hourlyRate = 32.50, workerType = " Contract crew ")
        val seed = PruningActivityTaskLink.labourSeed(hourly, "2026-08-13")!!

        assertEquals("2026-08-13", seed.workDate)
        assertEquals("Contract crew", seed.workerType)
        assertEquals(1, seed.workerCount)
        assertEquals(8.0, seed.hoursPerWorker, 0.0001)
        assertEquals(32.50, seed.hourlyRate!!, 0.0001)

        // On a PIECE-RATE job the hours are kept as operational history, but the
        // hourly rate is dropped — it would be a second, competing cost basis.
        val piece = hourly.copy(costingMethod = WorkTaskCostingMethod.PIECE_RATE, ratePerVine = 1.27)
        val pieceSeed = PruningActivityTaskLink.labourSeed(piece, "2026-08-13")!!
        assertEquals(8.0, pieceSeed.hoursPerWorker, 0.0001)
        assertNull(pieceSeed.hourlyRate)

        // No hours entered means no labour line at all.
        assertNull(PruningActivityTaskLink.labourSeed(hourly.copy(hoursPerWorker = null), "2026-08-13"))
    }

    @Test
    fun `a freshly created task resolves immediately on this device`() {
        var draft = activity(wholeRowSegments)
        val created = WorkTask(
            id = taskId,
            vineyardId = vineyard,
            date = "2026-08-13",
            taskType = "Pruning",
        )
        draft = PruningActivityTaskLink.link(draft, created.id)

        // With the task present in state, the editor resolves it — the
        // "hasn't reached this device yet" warning is for a link this device
        // genuinely does not have, never for one it just created.
        assertFalse(PruningActivityTaskLink.hasUnresolvableLink(draft, listOf(created)))
        assertEquals(taskId, PruningActivityTaskLink.linkedTask(draft, listOf(created))?.id)
        // The link never disturbs the block selection it was created from.
        assertEquals(8, draft.totalQuarters)
        assertEquals(499, draft.totalEstimatedVines)
    }
}
