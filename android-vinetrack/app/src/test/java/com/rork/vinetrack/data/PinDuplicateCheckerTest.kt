package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PinDuplicateCheckerTest {
    private val vineyardId = "vineyard-1"
    private val blockId = "block-1"
    private val latitude = -34.0
    private val longitude = 138.0

    private fun pin(
        id: String,
        type: String,
        mode: String = "Repairs",
        vineyardId: String = this.vineyardId,
        blockId: String? = this.blockId,
        completed: Boolean = false,
        deletedAt: String? = null,
        latitude: Double = this.latitude,
        longitude: Double = this.longitude,
        row: Double? = null,
        side: String? = "left",
        along: Double? = null,
        buttonName: String? = type,
        title: String? = type,
        category: String? = type,
    ): Pin = Pin(
        id = id,
        vineyardId = vineyardId,
        paddockId = blockId,
        title = title,
        category = category,
        buttonName = buttonName,
        mode = mode,
        side = side,
        isCompleted = completed,
        latitude = latitude,
        longitude = longitude,
        pinRowNumber = row,
        pinSide = side,
        alongRowDistanceM = along,
        snappedLatitude = if (row == null) null else latitude,
        snappedLongitude = if (row == null) null else longitude,
        snappedToRow = row != null,
        deletedAt = deletedAt,
    )

    private fun evaluate(
        type: String,
        mode: String = "Repairs",
        vineyardId: String? = this.vineyardId,
        blockId: String? = this.blockId,
        latitude: Double? = this.latitude,
        longitude: Double? = this.longitude,
        attachment: RowAttachment.Attachment? = null,
        pins: List<Pin>,
    ): PinDuplicateChecker.Evaluation = PinDuplicateChecker.evaluate(
        candidate = attachment,
        latitude = latitude,
        longitude = longitude,
        vineyardId = vineyardId,
        paddockId = blockId,
        mode = mode,
        logicalType = type,
        side = "left",
        manualRowNumber = null,
        paddock = Paddock(
            id = blockId ?: "block-1",
            vineyardId = this.vineyardId,
            name = "Block",
            rowWidth = 3.7,
            polygonPoints = listOf(CoordinatePoint(-34.1, 137.9)),
        ),
        pins = pins,
    )

    @Test
    fun `same type warns while different launcher types never warn`() {
        val broken = pin("broken", "Broken Post")
        assertEquals("broken", evaluate("Broken Post", pins = listOf(broken)).match?.pin?.id)
        assertNull(evaluate("Growth Stage", mode = "Growth", pins = listOf(broken)).match)
        assertNull(evaluate("Irrigation", pins = listOf(broken)).match)

        val powdery = pin("powdery", "Powdery", mode = "Growth")
        assertNull(evaluate("Downy", mode = "Growth", pins = listOf(powdery)).match)
    }

    @Test
    fun `growth stages case and repeated whitespace normalize to one logical type`() {
        val growth = pin("growth", " Growth   Stage EL 31 ", mode = "Growth")
        val growthResult = evaluate("Growth Stage EL 33", mode = "growth", pins = listOf(growth))
        assertEquals("growth", growthResult.match?.pin?.id)
        assertEquals("growth stage", growthResult.diagnostics.candidateKey.logicalType)

        val broken = pin("broken", "  broken   post ")
        assertEquals("broken", evaluate("Broken Post", pins = listOf(broken)).match?.pin?.id)
    }

    @Test
    fun `vineyard block radius completed and deleted scope is enforced`() {
        val candidates = listOf(
            pin("wrong-vineyard", "Broken Post", vineyardId = "vineyard-2"),
            pin("wrong-block", "Broken Post", blockId = "block-2"),
            pin("far", "Broken Post", longitude = 138.001),
            pin("completed", "Broken Post", completed = true),
            pin("deleted", "Broken Post", deletedAt = "2026-09-04T00:00:00Z"),
        )
        val result = evaluate("Broken Post", pins = candidates)
        assertNull(result.match)
        assertEquals("no_same_type_duplicate", result.diagnostics.result)
    }

    @Test
    fun `along row and legacy raw paths enforce identical type identity`() {
        val attachment = RowAttachment.Attachment(
            pinRowNumber = 1.0,
            pinSide = "left",
            alongRowDistanceM = 10.0,
            snappedLatitude = latitude,
            snappedLongitude = longitude,
        )
        val along = pin("along", "Broken Post", row = 1.0, along = 10.5)
        val alongResult = evaluate("Broken Post", attachment = attachment, pins = listOf(along))
        assertEquals(PinDuplicateChecker.Method.ALONG_ROW, alongResult.match?.method)
        assertNull(evaluate("Irrigation", attachment = attachment, pins = listOf(along)).match)

        val legacy = pin("legacy", "Broken Post")
        val rawResult = evaluate("Broken Post", attachment = attachment, pins = listOf(legacy))
        assertEquals(PinDuplicateChecker.Method.RAW_DISTANCE, rawResult.match?.method)
        assertNull(evaluate("Irrigation", attachment = attachment, pins = listOf(legacy)).match)
    }

    @Test
    fun `adjacent attached row cannot reenter through raw distance`() {
        val attachment = RowAttachment.Attachment(1.0, "left", 10.0, latitude, longitude)
        val adjacent = pin("adjacent", "Broken Post", row = 2.0, along = 10.0)
        assertNull(evaluate("Broken Post", attachment = attachment, pins = listOf(adjacent)).match)
    }

    @Test
    fun `large accumulated collection returns only same type without mutation`() {
        val otherPins = (0 until 5_000).map { index ->
            if (index % 2 == 0) pin("other-$index", "Irrigation")
            else pin("other-$index", "Growth Stage EL 31", mode = "Growth")
        }
        val snapshot = otherPins.toList()
        val noMatch = evaluate("Broken Post", pins = otherPins)
        assertNull(noMatch.match)
        assertEquals(5_000, noMatch.diagnostics.vineyardPinsInspected)
        assertEquals(0, noMatch.diagnostics.sameTypeCandidates)

        val valid = pin("valid", "Broken Post")
        val source = otherPins + valid
        val result = evaluate("Broken Post", pins = source)
        assertSame(valid, result.match?.pin)
        assertEquals(snapshot, otherPins)
        assertEquals(5_001, source.size)
        assertEquals("duplicate_same_type_raw_distance", result.diagnostics.result)
        assertTrue(result.diagnostics.description().contains("candidate=repairs|broken post"))
    }
}
