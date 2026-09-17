package com.rork.vinetrack.data.insights

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The canonical paired Growth Stage capture.
 *
 * Android previously had two divergent half-flows — the Growth screen wrote a
 * record with no pin, the Pin Composer wrote a pin with no record — and
 * `synthesizeGrowthPins` fabricated display-only pins that hid the gap. These
 * tests hold the corrected contract: one observation, one pin, one record that
 * references it, the same identities through every retry, and a partial failure
 * that completes only the missing half.
 */
class CanonicalGrowthStageCaptureTest {

    private val vineyardId = "vineyard-1"
    private val blockA = "paddock-a"

    private fun request(
        pinId: String = "pin-1",
        recordId: String = "record-1",
        stageCode: String = "23",
    ) = GrowthStageCapture.Request(
        pinId = pinId,
        recordId = recordId,
        vineyardId = vineyardId,
        paddockId = blockA,
        stageCode = stageCode,
        stageLabel = "E-L $stageCode",
        variety = "Shiraz",
        observedAtIso = "2026-11-20T02:00:00Z",
        latitude = -33.28,
        longitude = 149.09,
    )

    // --- Paired creation ---------------------------------------------------

    @Test
    fun `a new capture creates both a pin and a record`() {
        val plan = GrowthStageCapture.plan(
            request = request(),
            existingRecordId = null,
            existingPinId = null,
            existingStageCode = null,
        )

        val paired = plan as GrowthStageCapture.Paired
        assertTrue("the pin is owed", paired.needsPin)
        assertTrue("the record is owed", paired.needsRecord)
    }

    @Test
    fun `the pin is always ordered before the record it is referenced by`() {
        // growth_stage_records.pin_id is a real foreign key, so a record
        // replayed before its pin would simply be rejected.
        val paired = GrowthStageCapture.plan(
            request = request(),
            existingRecordId = null,
            existingPinId = null,
            existingStageCode = null,
        ) as GrowthStageCapture.Paired

        assertEquals(
            listOf(GrowthStageCapture.Step.PIN, GrowthStageCapture.Step.RECORD),
            paired.orderedSteps,
        )
    }

    @Test
    fun `both identities are known before anything is persisted`() {
        // This is what lets the record carry a real pin_id while still offline,
        // instead of waiting for a server to hand back an id.
        val req = request(pinId = "pin-abc", recordId = "record-xyz")
        val paired = GrowthStageCapture.plan(
            request = req,
            existingRecordId = null,
            existingPinId = null,
            existingStageCode = null,
        ) as GrowthStageCapture.Paired

        assertEquals("pin-abc", paired.request.pinId)
        assertEquals("record-xyz", paired.request.recordId)
    }

    // --- Retry and replay --------------------------------------------------

    @Test
    fun `a retry reuses the same pin and record identities`() {
        val req = request(pinId = "pin-stable", recordId = "record-stable")

        val first = GrowthStageCapture.plan(req, null, null, null) as GrowthStageCapture.Paired
        val retry = GrowthStageCapture.plan(req, null, null, null) as GrowthStageCapture.Paired

        assertEquals(first.request.pinId, retry.request.pinId)
        assertEquals(first.request.recordId, retry.request.recordId)
    }

    @Test
    fun `a partial success completes only the missing half`() {
        // The pin landed but the record did not. Re-pushing the pin would be
        // wasted work; minting a NEW pin would strand the first as an orphan
        // the operator can see and nothing references.
        val paired = GrowthStageCapture.plan(
            request = request(),
            existingRecordId = null,
            existingPinId = null,
            existingStageCode = null,
            progress = GrowthStageCapture.Progress(pinPersisted = true, recordPersisted = false),
        ) as GrowthStageCapture.Paired

        assertFalse("the pin is already durable", paired.needsPin)
        assertTrue("only the record is still owed", paired.needsRecord)
        assertEquals(listOf(GrowthStageCapture.Step.RECORD), paired.orderedSteps)
    }

    @Test
    fun `the reverse partial success completes only the pin`() {
        val paired = GrowthStageCapture.plan(
            request = request(),
            existingRecordId = null,
            existingPinId = null,
            existingStageCode = null,
            progress = GrowthStageCapture.Progress(pinPersisted = false, recordPersisted = true),
        ) as GrowthStageCapture.Paired

        assertEquals(listOf(GrowthStageCapture.Step.PIN), paired.orderedSteps)
    }

    @Test
    fun `repeated replay of an applied capture does nothing`() {
        // The duplication this whole contract exists to prevent: a retry of a
        // capture that already landed must not mint a second phenology record.
        val plan = GrowthStageCapture.plan(
            request = request(stageCode = "23"),
            existingRecordId = "record-1",
            existingPinId = "pin-1",
            existingStageCode = "23",
        )

        val applied = plan as GrowthStageCapture.AlreadyApplied
        assertEquals("record-1", applied.recordId)
        assertEquals("pin-1", applied.pinId)
    }

    @Test
    fun `replaying many times still resolves to the same single event`() {
        repeat(5) {
            val plan = GrowthStageCapture.plan(
                request = request(stageCode = "23"),
                existingRecordId = "record-1",
                existingPinId = "pin-1",
                existingStageCode = "23",
            )
            assertEquals("record-1", (plan as GrowthStageCapture.AlreadyApplied).recordId)
        }
    }

    // --- Editing -----------------------------------------------------------

    @Test
    fun `changing the stage updates the same linked event`() {
        val plan = GrowthStageCapture.plan(
            request = request(stageCode = "27"),
            existingRecordId = "record-1",
            existingPinId = "pin-1",
            existingStageCode = "23",
        )

        val update = plan as GrowthStageCapture.UpdateExisting
        assertEquals("the same record", "record-1", update.recordId)
        assertEquals("the same pin", "pin-1", update.pinId)
        assertEquals("27", update.stageCode)
    }

    // --- Legacy pin-less records -------------------------------------------

    @Test
    fun `a historical record with no pin is recognised as legacy`() {
        assertTrue(GrowthStageCapture.isLegacyUnlinked("record-old", null))
        assertFalse(
            "a properly paired record is not legacy",
            GrowthStageCapture.isLegacyUnlinked("record-1", "pin-1"),
        )
        assertFalse(
            "a brand new capture is not legacy",
            GrowthStageCapture.isLegacyUnlinked(null, null),
        )
    }

    @Test
    fun `editing a historical record does not silently invent a pin`() {
        // Back-filling would drop a new map pin at TODAY's position for an
        // observation made somewhere else months ago, and the operator could
        // not tell it apart from one they dropped themselves.
        val plan = GrowthStageCapture.plan(
            request = request(stageCode = "27"),
            existingRecordId = "record-old",
            existingPinId = null,
            existingStageCode = "23",
        )

        val update = plan as GrowthStageCapture.UpdateExisting
        assertNull("no pin is fabricated for a historical record", update.pinId)
        assertEquals("record-old", update.recordId)
        assertEquals("27", update.stageCode)
    }

    @Test
    fun `editing a historical record never creates a duplicate record`() {
        val plan = GrowthStageCapture.plan(
            request = request(recordId = "record-new", stageCode = "27"),
            existingRecordId = "record-old",
            existingPinId = null,
            existingStageCode = "23",
        )

        // The freshly minted id in the request is ignored; the existing record
        // is amended instead.
        assertEquals("record-old", (plan as GrowthStageCapture.UpdateExisting).recordId)
    }
}
