package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.ManualIssue
import com.rork.vinetrack.data.model.ManualIssueCategories
import com.rork.vinetrack.data.model.ManualIssueContract
import com.rork.vinetrack.data.model.ManualIssueCreateParams
import com.rork.vinetrack.data.model.ManualIssueLatLng
import com.rork.vinetrack.data.model.ManualIssuePriorities
import com.rork.vinetrack.data.model.ManualIssueScopes
import com.rork.vinetrack.data.model.ManualIssueSegment
import com.rork.vinetrack.data.model.ManualIssueStatuses
import com.rork.vinetrack.data.model.toMapPin
import kotlin.math.abs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Manual Issue contract tests — mirrored by iOS `ManualIssueContractTests`.
 * The parity fixture values asserted here MUST stay byte-identical to the
 * Swift suite so both platforms produce the same validation, marker
 * derivation and customer-facing wording.
 */
class ManualIssueContractTest {

    // Fixture (shared with iOS): straight north-south rows 1–6, anchored at
    // (-34.0, 138.0); row r runs from (-34.0, 138.0 + (r-1)*0.00004) to
    // (-33.999, same longitude).
    private fun rowLines(): Map<Int, Pair<ManualIssueLatLng, ManualIssueLatLng>> =
        (1..6).associateWith { row ->
            val lon = 138.0 + (row - 1) * 0.00004
            Pair(ManualIssueLatLng(-34.0, lon), ManualIssueLatLng(-33.999, lon))
        }

    private val blockPolygon = listOf(
        ManualIssueLatLng(-34.0, 138.0),
        ManualIssueLatLng(-34.0, 138.0002),
        ManualIssueLatLng(-33.999, 138.0002),
        ManualIssueLatLng(-33.999, 138.0),
    )

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    // MARK: Defaults & value sets

    @Test
    fun defaultsMatchContract() {
        assertEquals("general", ManualIssueContract.DEFAULT_CATEGORY)
        assertEquals("normal", ManualIssueContract.DEFAULT_PRIORITY)
        assertEquals("open", ManualIssueContract.DEFAULT_STATUS)
    }

    @Test
    fun categoryValuesAreStable() {
        assertEquals(
            listOf(
                "general", "action_required", "inspection", "planning",
                "infrastructure", "vine_or_row", "safety", "other",
            ),
            ManualIssueCategories.all,
        )
    }

    @Test
    fun priorityValuesAreStable() {
        assertEquals(listOf("low", "normal", "high", "urgent"), ManualIssuePriorities.all)
    }

    @Test
    fun statusValuesAreStable() {
        assertEquals(listOf("open", "in_progress", "completed", "cancelled"), ManualIssueStatuses.all)
        assertTrue(ManualIssueStatuses.isActive("open"))
        assertTrue(ManualIssueStatuses.isActive("in_progress"))
        assertFalse(ManualIssueStatuses.isActive("completed"))
        assertFalse(ManualIssueStatuses.isActive("cancelled"))
    }

    @Test
    fun scopeValuesAreStable() {
        assertEquals(listOf("point", "row", "block"), ManualIssueScopes.all)
    }

    // MARK: Validation

    @Test
    fun titleIsRequired() {
        assertNotNull(
            ManualIssueContract.validationError(
                title = "   ", scope = ManualIssueScopes.POINT,
                latitude = -34.0, longitude = 138.0, paddockId = "p", segments = emptyList(),
            ),
        )
    }

    @Test
    fun pointRequiresCoordinates() {
        assertNotNull(
            ManualIssueContract.validationError(
                title = "Leak", scope = ManualIssueScopes.POINT,
                latitude = null, longitude = null, paddockId = null, segments = emptyList(),
            ),
        )
    }

    @Test
    fun validPointPasses() {
        assertNull(
            ManualIssueContract.validationError(
                title = "Leak", scope = ManualIssueScopes.POINT,
                latitude = -34.0, longitude = 138.0, paddockId = null, segments = emptyList(),
            ),
        )
    }

    @Test
    fun rowRequiresSegmentsAndBlock() {
        assertNotNull(
            ManualIssueContract.validationError(
                title = "Netting", scope = ManualIssueScopes.ROW,
                latitude = -34.0, longitude = 138.0, paddockId = "p", segments = emptyList(),
            ),
        )
        assertNotNull(
            ManualIssueContract.validationError(
                title = "Netting", scope = ManualIssueScopes.ROW,
                latitude = -34.0, longitude = 138.0, paddockId = null,
                segments = listOf(ManualIssueSegment(2, 1)),
            ),
        )
        assertNull(
            ManualIssueContract.validationError(
                title = "Netting", scope = ManualIssueScopes.ROW,
                latitude = -34.0, longitude = 138.0, paddockId = "p",
                segments = listOf(ManualIssueSegment(2, 1)),
            ),
        )
    }

    @Test
    fun blockRequiresBlock() {
        assertNotNull(
            ManualIssueContract.validationError(
                title = "Out of production", scope = ManualIssueScopes.BLOCK,
                latitude = -34.0, longitude = 138.0, paddockId = null, segments = emptyList(),
            ),
        )
    }

    // MARK: Segments

    @Test
    fun canonicalSegmentsDedupeAndSort() {
        val raw = listOf(
            ManualIssueSegment(3, 2),
            ManualIssueSegment(2, 4),
            ManualIssueSegment(3, 2),
            ManualIssueSegment(2, 1),
        )
        assertEquals(
            listOf(ManualIssueSegment(2, 1), ManualIssueSegment(2, 4), ManualIssueSegment(3, 2)),
            ManualIssueContract.canonicalSegments(raw),
        )
    }

    // MARK: Marker derivation (parity fixture)

    @Test
    fun segmentMidpointUsesQuarterFractions() {
        val mid = ManualIssueContract.segmentMidpoint(
            ManualIssueLatLng(-34.0, 138.0),
            ManualIssueLatLng(-33.999, 138.0),
            quarter = 1,
        )
        // Quarter 1 midpoint = 1/8 along the row.
        assertTrue(abs(mid.latitude - (-34.0 + 0.001 * 0.125)) < 1e-12)
        assertTrue(abs(mid.longitude - 138.0) < 1e-12)
    }

    /** Parity fixture: whole row 2 → marker at the row 2 midline centre. */
    @Test
    fun wholeRowMarkerIsRowMidpoint() {
        val segments = (1..4).map { ManualIssueSegment(2, it) }
        val marker = ManualIssueContract.markerCoordinate(segments, rowLines())
        assertNotNull(marker)
        assertTrue(abs(marker!!.latitude - (-33.9995)) < 1e-9)
        assertTrue(abs(marker.longitude - 138.00004) < 1e-9)
    }

    /** Parity fixture: rows 2–3 whole + row 5 quarters 1–2 → mean of the ten quarter midpoints. */
    @Test
    fun multiRowMarkerIsMeanOfQuarterMidpoints() {
        val segments = (1..4).map { ManualIssueSegment(2, it) } +
            (1..4).map { ManualIssueSegment(3, it) } +
            listOf(ManualIssueSegment(5, 1), ManualIssueSegment(5, 2))
        val lines = rowLines()
        val marker = ManualIssueContract.markerCoordinate(segments, lines)
        var latSum = 0.0
        var lonSum = 0.0
        for (segment in ManualIssueContract.canonicalSegments(segments)) {
            val line = lines.getValue(segment.row)
            val mid = ManualIssueContract.segmentMidpoint(line.first, line.second, segment.segment)
            latSum += mid.latitude
            lonSum += mid.longitude
        }
        assertNotNull(marker)
        assertTrue(abs(marker!!.latitude - latSum / 10.0) < 1e-12)
        assertTrue(abs(marker.longitude - lonSum / 10.0) < 1e-12)
    }

    @Test
    fun markerIsNullWithoutGeometry() {
        assertNull(ManualIssueContract.markerCoordinate(listOf(ManualIssueSegment(99, 1)), rowLines()))
    }

    @Test
    fun blockCentroidIsMeanOfBoundary() {
        val centroid = ManualIssueContract.blockCentroid(blockPolygon)
        assertNotNull(centroid)
        assertTrue(abs(centroid!!.latitude - (-33.9995)) < 1e-9)
        assertTrue(abs(centroid.longitude - 138.0001) < 1e-9)
    }

    // MARK: Customer-facing wording (parity fixture)

    @Test
    fun wholeRowSummaryUsesRanges() {
        val segments = listOf(2, 3, 4, 6).flatMap { row -> (1..4).map { ManualIssueSegment(row, it) } }
        assertEquals("Rows 2–4, 6", ManualIssueContract.rowSelectionSummary(segments))
    }

    @Test
    fun singleWholeRowSummary() {
        val segments = (1..4).map { ManualIssueSegment(8, it) }
        assertEquals("Row 8", ManualIssueContract.rowSelectionSummary(segments))
    }

    @Test
    fun partialRowSummaryListsSections() {
        val segments = listOf(ManualIssueSegment(5, 1), ManualIssueSegment(5, 2))
        assertEquals("Row 5 (sections 1–2)", ManualIssueContract.rowSelectionSummary(segments))
    }

    @Test
    fun mixedSummaryPutsWholeRowsFirst() {
        val segments = (1..4).map { ManualIssueSegment(2, it) } +
            (1..4).map { ManualIssueSegment(3, it) } +
            listOf(ManualIssueSegment(5, 1), ManualIssueSegment(5, 2))
        assertEquals("Rows 2–3 · Row 5 (sections 1–2)", ManualIssueContract.rowSelectionSummary(segments))
    }

    @Test
    fun nonContiguousSectionsUseCommaList() {
        val segments = listOf(ManualIssueSegment(5, 1), ManualIssueSegment(5, 3))
        assertEquals("Row 5 (sections 1, 3)", ManualIssueContract.rowSelectionSummary(segments))
    }

    @Test
    fun attachedRowLabelPreservesDecimalPathRow() {
        // Exact path-row 19.5 stays intact in the wording and the data.
        assertEquals("On row 19.5", ManualIssueContract.attachedRowLabel(19.5, 19.0, null))
        assertEquals("On row 15 · left side", ManualIssueContract.attachedRowLabel(null, 15.0, "Left"))
        assertNull(ManualIssueContract.attachedRowLabel(null, null, null))
    }

    // MARK: Record behaviour

    @Test
    fun recordDecodesCanonicalJson() {
        val raw = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "paddock_id": "33333333-3333-3333-3333-333333333333",
          "title": "Irrigation leak",
          "description": "Dripper line burst",
          "category": "infrastructure",
          "priority": "high",
          "status": "open",
          "location_scope": "row",
          "latitude": -33.9995,
          "longitude": 138.00004,
          "snapped_to_row": false,
          "due_date": "2026-09-01",
          "created_at": "2026-08-06T01:00:00.000000+00:00",
          "segments": [{"row": 2, "segment": 1}, {"row": 2, "segment": 2}]
        }
        """.trimIndent()
        val record = json.decodeFromString(ManualIssue.serializer(), raw)
        assertEquals("Irrigation leak", record.title)
        assertEquals("infrastructure", record.category)
        assertEquals("high", record.priority)
        assertEquals("row", record.locationScope)
        assertTrue(record.isActive)
        assertEquals(2, record.segments?.size)
        assertEquals("Row 2 (sections 1–2)", record.locationSummary)
        assertEquals("2026-09-01", record.dueDate)
    }

    @Test
    fun blockScopeSummaryIsWholeBlock() {
        val record = ManualIssue(
            id = "a", vineyardId = "v", paddockId = "p",
            title = "Out of production", category = "planning",
            status = ManualIssueStatuses.CANCELLED,
            locationScope = ManualIssueScopes.BLOCK,
            latitude = -33.9995, longitude = 138.0001,
        )
        assertEquals("Whole block", record.locationSummary)
        assertFalse(record.isActive)
    }

    /** The create RPC params encode with the exact argument names sql/169 declares. */
    @Test
    fun createParamsEncodeRpcArgumentNames() {
        val params = ManualIssueCreateParams(
            id = "11111111-1111-1111-1111-111111111111",
            vineyardId = "22222222-2222-2222-2222-222222222222",
            title = "Leak",
            locationScope = "row",
            latitude = -34.0,
            longitude = 138.0,
            clientUpdatedAt = "2026-08-06T01:00:00.000Z",
            segments = listOf(ManualIssueSegment(2, 1)),
        )
        val element = json.parseToJsonElement(json.encodeToString(ManualIssueCreateParams.serializer(), params)).jsonObject
        assertTrue(element.containsKey("p_id"))
        assertTrue(element.containsKey("p_vineyard_id"))
        assertTrue(element.containsKey("p_title"))
        assertTrue(element.containsKey("p_location_scope"))
        assertTrue(element.containsKey("p_category"))
        assertTrue(element.containsKey("p_priority"))
        assertTrue(element.containsKey("p_client_updated_at"))
        assertTrue(element.containsKey("p_segments"))
    }

    /** A queued offline op round-trips through the outbox envelope without loss. */
    @Test
    fun queuedOpRoundTripsThroughEnvelope() {
        val params = ManualIssueCreateParams(
            id = "11111111-1111-1111-1111-111111111111",
            vineyardId = "22222222-2222-2222-2222-222222222222",
            title = "Leak",
            locationScope = "point",
            latitude = -34.0,
            longitude = 138.0,
            clientUpdatedAt = "2026-08-06T01:00:00.000Z",
        )
        val op = ManualIssueSync.QueuedOp(ManualIssueSync.QueuedOp.KIND_CREATE, createParams = params)
        val decoded = json.decodeFromString(
            ManualIssueSync.QueuedOp.serializer(),
            json.encodeToString(ManualIssueSync.QueuedOp.serializer(), op),
        )
        assertEquals(ManualIssueSync.QueuedOp.KIND_CREATE, decoded.kind)
        assertEquals("Leak", decoded.createParams?.title)
    }

    /** Replay order: creates land before dependent edits/status/terminal ops. */
    @Test
    fun replayOrderIsCreateFirst() {
        assertTrue(
            ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_CREATE) <
                ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_UPDATE),
        )
        assertTrue(
            ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_UPDATE) <
                ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_STATUS),
        )
        assertTrue(
            ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_STATUS) <
                ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_CANCEL),
        )
        assertTrue(
            ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_CANCEL) <
                ManualIssueSync.QueuedOp.replayOrder(ManualIssueSync.QueuedOp.KIND_DELETE),
        )
    }

    /** Manual issues mirror onto the shared pins list with the amber identity. */
    @Test
    fun mapPinMirrorKeepsIdentityAndMode() {
        val issue = ManualIssue(
            id = "issue-1", vineyardId = "v", paddockId = "p",
            title = "Leak", priority = "high",
            locationScope = ManualIssueScopes.POINT,
            latitude = -34.0, longitude = 138.0,
        )
        val pin = issue.toMapPin()
        assertNotNull(pin)
        assertEquals("issue-1", pin!!.id)
        assertEquals("ManualIssue", pin.mode)
        assertEquals("orange", pin.buttonColor)
        assertEquals("Leak", pin.title)
        assertFalse(pin.isCompleted)
        // No coordinate → no marker.
        assertNull(issue.copy(latitude = null).toMapPin())
    }

    @Test
    fun completedIssueMirrorsAsCompletedPin() {
        val issue = ManualIssue(
            id = "issue-1", vineyardId = "v",
            title = "Leak", status = ManualIssueStatuses.COMPLETED,
            locationScope = ManualIssueScopes.POINT,
            latitude = -34.0, longitude = 138.0,
        )
        assertTrue(issue.toMapPin()!!.isCompleted)
    }
}
