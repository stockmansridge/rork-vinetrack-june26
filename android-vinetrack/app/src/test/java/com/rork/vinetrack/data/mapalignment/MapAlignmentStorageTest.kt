package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The versioned local format, and the guarantees the field test depends on.
 *
 * The headline behaviour: three completed reference points survive leaving the
 * app, and the operator does not restart at Point 1. Everything else here
 * protects that from being quietly broken — by a version bump, a malformed
 * file, another installation's data, or a stored candidate drifting away from
 * the evidence it claims to come from.
 */
class MapAlignmentStorageTest {

    private val installation = "install-a"
    private val scope = MapAlignmentScope(installation, "vineyard-1")
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    private fun shift(
        from: CanonicalCoordinate,
        eastMetres: Double,
        northMetres: Double,
    ): CanonicalCoordinate {
        if (eastMetres == 0.0 && northMetres == 0.0) return from
        val display = from.toDisplay(
            MapAlignment(
                id = "fixture",
                scope = scope,
                eastOffsetMetres = eastMetres,
                northOffsetMetres = northMetres,
                isEnabled = true,
            ),
        )
        return CanonicalCoordinate(display.latitude, display.longitude)
    }

    private fun point(
        index: Int,
        scope: MapAlignmentScope = this.scope,
        eastMetres: Double = 9.0,
    ): MapAlignmentReferencePoint {
        val canonical = shift(origin, index * 60.0, if (index % 2 == 0) 0.0 else 55.0)
        val marked = shift(canonical, eastMetres, 0.0)
        return MapAlignmentReferencePoint(
            id = "p$index",
            scope = scope,
            canonicalCoordinate = canonical,
            selectedMapCoordinate = AndroidDisplayCoordinate(marked.latitude, marked.longitude),
            gpsAccuracyMetres = 2.4,
            gpsEvidence = MapAlignmentGpsEvidence(
                sampleCount = 6,
                samplingDurationMillis = 14_000L,
                representativeAccuracyMetres = 2.4,
                worstAccuracyMetres = 3.9,
                stabilityRadiusMetres = 1.8,
            ),
            capturedAtEpochMillis = 1_757_000_000_000 + index,
            referenceType = MapAlignmentReferenceType.RowEnd,
            description = "North-west corner post",
            rowNumber = 26,
            rowPosition = MapAlignmentRowPosition.End,
        )
    }

    private fun draft(pointCount: Int): MapAlignmentDraft {
        var draft = MapAlignmentDraft(
            scope = scope,
            vineyardName = "Stockmans Ridge",
            blockName = null,
        )
        repeat(pointCount) { draft = draft.withReferencePoint(point(it)) }
        return draft
    }

    private fun stored(
        pointCount: Int,
        step: MapAlignmentWizardStep = MapAlignmentWizardStep.Capture,
        pending: MapAlignmentPendingReference? = null,
        solvedAlignmentId: String? = null,
    ) = MapAlignmentStoredDraft(
        draft = draft(pointCount),
        step = step,
        pending = pending,
        solvedAlignmentId = solvedAlignmentId,
        updatedAtEpochMillis = 1_757_100_000_000,
    )

    // --- The field guarantee ----------------------------------------------

    @Test
    fun `three completed points survive a round trip and do not restart at point one`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(3))

        val decoded = MapAlignmentStorage.decodeDraft(encoded, installation)

        val restored = (decoded as MapAlignmentStorage.Decoded.Restored).value
        assertEquals(3, restored.pointCount)
        assertEquals(listOf("p0", "p1", "p2"), restored.draft.referencePoints.map { it.id })
        assertEquals(MapAlignmentWizardStep.Capture, restored.step)
        assertEquals(
            "3 of 4 minimum reference points completed",
            restored.progressSummary(),
        )
        // The next point the operator records is 4, not 1.
        assertEquals(4, restored.pointCount + 1)
    }

    @Test
    fun `every field of a reference point survives exactly`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(1))

        val restored =
            (MapAlignmentStorage.decodeDraft(encoded, installation)
                as MapAlignmentStorage.Decoded.Restored).value
        val before = point(0)
        val after = restored.draft.referencePoints.single()

        assertEquals(before.id, after.id)
        assertEquals(before.scope, after.scope)
        assertEquals(before.canonicalCoordinate, after.canonicalCoordinate)
        assertEquals(before.selectedMapCoordinate, after.selectedMapCoordinate)
        assertEquals(before.gpsAccuracyMetres, after.gpsAccuracyMetres)
        assertEquals(before.gpsEvidence, after.gpsEvidence)
        assertEquals(before.capturedAtEpochMillis, after.capturedAtEpochMillis)
        assertEquals(before.referenceType, after.referenceType)
        assertEquals(before.description, after.description)
        assertEquals(before.rowNumber, after.rowNumber)
        assertEquals(before.rowPosition, after.rowPosition)
        // The canonical/display distinction must survive storage: the whole
        // feature rests on these never being transposed.
        assertEquals(before.observedOffset, after.observedOffset)
    }

    // --- The GPS-complete checkpoint --------------------------------------

    @Test
    fun `a GPS-complete point resumes at marking rather than repeating the walk`() {
        val checkpoint = MapAlignmentPendingReference(
            editingId = null,
            canonicalCoordinate = shift(origin, 180.0, 0.0),
            gpsEvidence = MapAlignmentGpsEvidence(
                sampleCount = 7,
                samplingDurationMillis = 16_000L,
                representativeAccuracyMetres = 2.9,
                worstAccuracyMetres = 4.4,
                stabilityRadiusMetres = 2.1,
            ),
            capturedAtEpochMillis = 1_757_100_000_500,
        )
        val encoded = MapAlignmentStorage.encodeDraft(stored(3, pending = checkpoint))

        val restored =
            (MapAlignmentStorage.decodeDraft(encoded, installation)
                as MapAlignmentStorage.Decoded.Restored).value

        val pending = requireNotNull(restored.pending)
        assertEquals(checkpoint.canonicalCoordinate, pending.canonicalCoordinate)
        assertEquals(checkpoint.gpsEvidence, pending.gpsEvidence)
        assertEquals(checkpoint.capturedAtEpochMillis, pending.capturedAtEpochMillis)
        assertEquals(
            "Point 4 GPS complete — image point still needs marking",
            restored.pendingSummary(),
        )
        // The checkpoint is NOT a reference point: it has no image mark yet, so
        // it must not inflate the count or join the solve.
        assertEquals(3, restored.pointCount)
    }

    @Test
    fun `a draft with no points but a checkpoint still counts as progress`() {
        val checkpoint = MapAlignmentPendingReference(
            canonicalCoordinate = origin,
            capturedAtEpochMillis = 1_757_100_000_000,
        )

        assertTrue(stored(0, pending = checkpoint).hasProgress)
        assertFalse("an empty scoped draft is not worth resuming", stored(0).hasProgress)
        assertTrue(stored(1).hasProgress)
    }

    @Test
    fun `a retake checkpoint is described as a retake not a new point`() {
        val retake = MapAlignmentPendingReference(
            editingId = "p1",
            canonicalCoordinate = origin,
            capturedAtEpochMillis = 1_757_100_000_000,
        )
        assertEquals(
            "A GPS retake is waiting to be confirmed",
            stored(3, pending = retake).pendingSummary(),
        )

        val remark = retake.copy(remarkOnly = true)
        assertEquals(
            "An image point is part-way through being re-marked",
            stored(3, pending = remark).pendingSummary(),
        )
    }

    // --- The candidate is re-derived, never stored as numbers --------------

    @Test
    fun `a stored candidate is rebuilt from the evidence rather than trusted`() {
        val solved = draft(4).solved(alignmentId = "candidate-1", nowEpochMillis = 1L)
        val record = MapAlignmentStoredDraft(
            draft = solved,
            step = MapAlignmentWizardStep.Review,
            solvedAlignmentId = "candidate-1",
            updatedAtEpochMillis = 1_757_100_000_000,
        )

        val restored =
            (MapAlignmentStorage.decodeDraft(MapAlignmentStorage.encodeDraft(record), installation)
                as MapAlignmentStorage.Decoded.Restored).value
        val rebuilt = restored.restoredDraft()

        assertEquals(MapAlignmentWizardStep.Review, restored.step)
        assertNotNull(rebuilt.solution)
        // Re-derived from the restored points, so the candidate can never
        // disagree with the evidence shown beside it.
        assertEquals(
            solved.solution!!.alignment.eastOffsetMetres,
            rebuilt.solution!!.alignment.eastOffsetMetres,
            1e-9,
        )
        assertEquals(
            solved.solution!!.alignment.northOffsetMetres,
            rebuilt.solution!!.alignment.northOffsetMetres,
            1e-9,
        )
        assertEquals(4, rebuilt.solution!!.pointCount)
    }

    @Test
    fun `a draft with no calculated candidate restores without one`() {
        val restored =
            (MapAlignmentStorage.decodeDraft(
                MapAlignmentStorage.encodeDraft(stored(3)),
                installation,
            ) as MapAlignmentStorage.Decoded.Restored).value

        assertNull(restored.solvedAlignmentId)
        assertNull(restored.restoredDraft().solution)
    }

    // --- Versioning -------------------------------------------------------

    @Test
    fun `an unknown storage version is refused rather than guessed at`() {
        val future = MapAlignmentStorage.encodeDraft(stored(3))
            .replace("\"storage_version\":1", "\"storage_version\":2")

        val decoded = MapAlignmentStorage.decodeDraft(future, installation)

        val unusable = decoded as MapAlignmentStorage.Decoded.Unusable
        assertTrue(unusable.reason.contains("unsupported storage version"))
    }

    @Test
    fun `the document carries an explicit version and named fields`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(2))

        assertTrue(encoded.contains("\"storage_version\":1"))
        assertEquals(1, MapAlignmentStorage.STORAGE_VERSION)
        // Named fields rather than an opaque object graph, so a later class
        // rename cannot silently produce an unreadable file.
        assertTrue(encoded.contains("\"installation_id\""))
        assertTrue(encoded.contains("\"canonical_lat\""))
        assertTrue(encoded.contains("\"marked_lat\""))
    }

    @Test
    fun `malformed data is reported as unusable and never crashes`() {
        listOf("{", "not json at all", "{\"storage_version\":1}", "[]").forEach { raw ->
            val decoded = MapAlignmentStorage.decodeDraft(raw, installation)
            assertTrue(
                "\"$raw\" must be refused, not adopted",
                decoded is MapAlignmentStorage.Decoded.Unusable,
            )
        }
    }

    @Test
    fun `absent storage is Empty rather than Unusable`() {
        // The normal first-run state must not look like corruption, or the
        // operator would be offered a removal prompt on a clean install.
        assertEquals(
            MapAlignmentStorage.Decoded.Empty,
            MapAlignmentStorage.decodeDraft(null, installation),
        )
        assertEquals(
            MapAlignmentStorage.Decoded.Empty,
            MapAlignmentStorage.decodeDraft("   ", installation),
        )
    }

    @Test
    fun `an unknown enum name degrades instead of losing the walked points`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(3))
            .replace("\"reference_type\":\"RowEnd\"", "\"reference_type\":\"Trellis\"")

        val restored =
            (MapAlignmentStorage.decodeDraft(encoded, installation)
                as MapAlignmentStorage.Decoded.Restored).value

        assertEquals("three walked points are worth more than one label", 3, restored.pointCount)
        assertNull(restored.draft.referencePoints.first().referenceType)
        // The geographic evidence is untouched by the unknown label.
        assertEquals(
            point(0).canonicalCoordinate,
            restored.draft.referencePoints[0].canonicalCoordinate,
        )
    }

    @Test
    fun `an unknown step resumes at capture`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(3))
            .replace("\"step\":\"Capture\"", "\"step\":\"Nonsense\"")

        val restored =
            (MapAlignmentStorage.decodeDraft(encoded, installation)
                as MapAlignmentStorage.Decoded.Restored).value

        assertEquals(MapAlignmentWizardStep.Capture, restored.step)
    }

    // --- Scope --------------------------------------------------------------

    @Test
    fun `scope travels with the draft including a block override`() {
        val blockScope = scope.copy(blockId = "block-9")
        val record = MapAlignmentStoredDraft(
            draft = MapAlignmentDraft(
                scope = blockScope,
                vineyardName = "Stockmans Ridge",
                blockName = "Home Block",
                referencePoints = listOf(point(0, scope = blockScope)),
            ),
            updatedAtEpochMillis = 1_757_100_000_000,
        )

        val restored =
            (MapAlignmentStorage.decodeDraft(MapAlignmentStorage.encodeDraft(record), installation)
                as MapAlignmentStorage.Decoded.Restored).value

        assertEquals(installation, restored.draft.scope.androidInstallationId)
        assertEquals("vineyard-1", restored.draft.scope.vineyardId)
        assertEquals("block-9", restored.draft.scope.blockId)
        assertTrue(restored.draft.isBlockOverride)
        assertEquals("Home Block", restored.draft.blockName)
        assertEquals(blockScope, restored.draft.referencePoints.single().scope)
    }

    @Test
    fun `another installation's draft is refused rather than adopted`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(3))

        val decoded = MapAlignmentStorage.decodeDraft(encoded, installationId = "install-b")

        val unusable = decoded as MapAlignmentStorage.Decoded.Unusable
        assertTrue(unusable.reason.contains("different Android installation"))
    }

    @Test
    fun `a scope missing its identity is refused`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(2))
            .replace("\"vineyard_id\":\"vineyard-1\"", "\"vineyard_id\":\"\"")

        assertTrue(
            MapAlignmentStorage.decodeDraft(encoded, installation)
                is MapAlignmentStorage.Decoded.Unusable,
        )
    }

    @Test
    fun `no hardware identifier is written`() {
        val encoded = MapAlignmentStorage.encodeDraft(stored(3))

        listOf("imei", "serial", "android_id", "mac", "advertis").forEach { forbidden ->
            assertFalse(
                "identity is the installation id only",
                encoded.lowercase().contains(forbidden),
            )
        }
    }

    // --- Completed calibrations -------------------------------------------

    @Test
    fun `a completed calibration round trips separately from the draft`() {
        val solved = draft(4).solved(alignmentId = "saved-1", nowEpochMillis = 1L)
        val saved = MapAlignmentSavedCalibration(
            calibration = solved.solution!!.calibration,
            vineyardName = "Stockmans Ridge",
            savedAtEpochMillis = 1_757_200_000_000,
        )

        val encoded = MapAlignmentStorage.encodeCalibrations(listOf(saved))
        val restored =
            (MapAlignmentStorage.decodeCalibrations(encoded, installation)
                as MapAlignmentStorage.Decoded.Restored).value

        assertEquals(1, restored.size)
        val only = restored.single()
        assertEquals("saved-1", only.alignment.id)
        assertEquals(4, only.pointCount)
        assertEquals(
            saved.alignment.eastOffsetMetres,
            only.alignment.eastOffsetMetres,
            1e-9,
        )
        assertEquals(
            saved.alignment.northOffsetMetres,
            only.alignment.northOffsetMetres,
            1e-9,
        )
        assertEquals(1_757_200_000_000, only.savedAtEpochMillis)
    }

    @Test
    fun `saved calibrations from another installation are filtered out`() {
        val solved = draft(4).solved(alignmentId = "saved-1", nowEpochMillis = 1L)
        val encoded = MapAlignmentStorage.encodeCalibrations(
            listOf(
                MapAlignmentSavedCalibration(
                    calibration = solved.solution!!.calibration,
                    vineyardName = "Stockmans Ridge",
                    savedAtEpochMillis = 1L,
                ),
            ),
        )

        val restored =
            (MapAlignmentStorage.decodeCalibrations(encoded, "install-b")
                as MapAlignmentStorage.Decoded.Restored).value

        assertTrue(restored.isEmpty())
    }

    @Test
    fun `an unsupported saved-calibration version is refused`() {
        val encoded = MapAlignmentStorage.encodeCalibrations(emptyList())
            .replace("\"storage_version\":1", "\"storage_version\":99")

        assertTrue(
            MapAlignmentStorage.decodeCalibrations(encoded, installation)
                is MapAlignmentStorage.Decoded.Unusable,
        )
    }

    // --- Nothing here reaches production ----------------------------------

    @Test
    fun `stored state carries no production map decision`() {
        // A stored field-test calibration is evidence on one device. Whether
        // any map consults it is a separate, later decision — this phase's
        // resolver is not fed from storage at all.
        val solved = draft(4).solved(alignmentId = "saved-1", nowEpochMillis = 1L)
        val saved = MapAlignmentSavedCalibration(
            calibration = solved.solution!!.calibration,
            vineyardName = "Stockmans Ridge",
            savedAtEpochMillis = 1L,
        )

        assertEquals(scope, saved.alignment.scope)
        assertEquals(installation, saved.alignment.androidInstallationId)
        assertFalse(saved.isBlockOverride)
    }
}
