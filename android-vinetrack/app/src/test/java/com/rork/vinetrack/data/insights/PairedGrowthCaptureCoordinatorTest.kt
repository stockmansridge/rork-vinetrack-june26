package com.rork.vinetrack.data.insights

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairedGrowthCaptureCoordinatorTest {
    private fun journal(operationId: String = "operation-1") = PairedGrowthCaptureJournal(
        operationId = operationId,
        pinId = "pin-1",
        growthRecordId = "record-1",
        vineyardId = "vineyard-1",
        paddockId = "block-1",
        latitude = -33.28,
        longitude = 149.09,
        stageCode = "23",
        stageLabel = "E-L 23",
        observedAtIso = "2026-09-17T01:00:00Z",
        originatingFeature = "growth_screen",
        createdAtMillis = 1,
        updatedAtMillis = 1,
    )

    @Test
    fun `pin save succeeds and record save failure leaves resumable pin_saved journal`() {
        val store = MemoryStore()
        val writer = FakeWriter(recordSaveSucceeds = false)
        val coordinator = PairedGrowthCaptureCoordinator(store) { 2 }
        val pending = coordinator.beginOrReuse(journal())!!

        coordinator.resume(pending.operationId, writer) { complete, _ -> assertFalse(complete) }

        assertEquals(setOf("pin-1"), writer.pins)
        assertTrue(writer.records.isEmpty())
        assertEquals(PairedGrowthCaptureJournal.State.PIN_SAVED, store.load().single().state)
    }

    @Test
    fun `restart resume creates only missing record with original identities`() {
        val store = MemoryStore(mutableListOf(journal().copy(state = PairedGrowthCaptureJournal.State.PIN_SAVED)))
        val writer = FakeWriter(pins = mutableSetOf("pin-1"))
        val restarted = PairedGrowthCaptureCoordinator(store) { 3 }

        restarted.resumeAll(writer)

        assertEquals(0, writer.pinSaveCalls)
        assertEquals(setOf("record-1"), writer.records)
        assertTrue(store.load().isEmpty())
    }

    @Test
    fun `repeated resume creates neither a second pin nor a second record`() {
        val store = MemoryStore()
        val writer = FakeWriter()
        val coordinator = PairedGrowthCaptureCoordinator(store)
        val pending = coordinator.beginOrReuse(journal())!!
        coordinator.resume(pending.operationId, writer) { _, _ -> }
        coordinator.resume(pending.operationId, writer) { _, _ -> }

        assertEquals(1, writer.pinSaveCalls)
        assertEquals(1, writer.recordSaveCalls)
    }

    @Test
    fun `user retry while pending reuses existing operation and stable ids`() {
        val store = MemoryStore()
        val coordinator = PairedGrowthCaptureCoordinator(store)
        val first = coordinator.beginOrReuse(journal())!!
        val retry = coordinator.beginOrReuse(journal("new-operation").copy(pinId = "new-pin", growthRecordId = "new-record"))!!

        assertEquals(first.operationId, retry.operationId)
        assertEquals("pin-1", retry.pinId)
        assertEquals("record-1", retry.growthRecordId)
        assertEquals(1, store.load().size)
    }

    @Test
    fun `successful completion clears pending operation`() {
        val store = MemoryStore()
        val writer = FakeWriter()
        val coordinator = PairedGrowthCaptureCoordinator(store)
        val pending = coordinator.beginOrReuse(journal())!!
        var complete = false

        coordinator.resume(pending.operationId, writer) { ok, _ -> complete = ok }

        assertTrue(complete)
        assertTrue(store.load().isEmpty())
    }

    @Test
    fun `record already local while pin is temporarily absent creates only pin`() {
        val store = MemoryStore()
        val writer = FakeWriter(records = mutableSetOf("record-1"))
        val coordinator = PairedGrowthCaptureCoordinator(store)
        val pending = coordinator.beginOrReuse(journal())!!

        coordinator.resume(pending.operationId, writer) { complete, _ -> assertTrue(complete) }

        assertEquals(1, writer.pinSaveCalls)
        assertEquals(0, writer.recordSaveCalls)
    }

    @Test
    fun `server foreign key failure for missing pin is retryable evidence`() {
        assertTrue(GrowthCaptureServerOrdering.isMissingPinForeignKey("{\"code\":\"23503\",\"message\":\"pin_id violates foreign key\"}"))
        assertFalse(GrowthCaptureServerOrdering.isMissingPinForeignKey("{\"code\":\"23505\",\"message\":\"duplicate id\"}"))
    }

    private class MemoryStore(
        private val journals: MutableList<PairedGrowthCaptureJournal> = mutableListOf(),
    ) : PairedGrowthCaptureJournalStore {
        override fun load(): List<PairedGrowthCaptureJournal> = journals.toList()
        override fun save(journal: PairedGrowthCaptureJournal): Boolean {
            journals.removeAll { it.operationId == journal.operationId }
            journals += journal
            return true
        }
        override fun remove(operationId: String): Boolean {
            journals.removeAll { it.operationId == operationId }
            return true
        }
    }

    private class FakeWriter(
        val pins: MutableSet<String> = mutableSetOf(),
        val records: MutableSet<String> = mutableSetOf(),
        private val pinSaveSucceeds: Boolean = true,
        private val recordSaveSucceeds: Boolean = true,
    ) : PairedGrowthCaptureCoordinator.Writer {
        var pinSaveCalls: Int = 0
        var recordSaveCalls: Int = 0
        override fun hasPin(pinId: String): Boolean = pinId in pins
        override fun hasRecord(recordId: String): Boolean = recordId in records
        override fun savePin(journal: PairedGrowthCaptureJournal, completion: (Boolean) -> Unit) {
            pinSaveCalls += 1
            if (pinSaveSucceeds) pins += journal.pinId
            completion(pinSaveSucceeds)
        }
        override fun saveRecord(journal: PairedGrowthCaptureJournal, completion: (Boolean) -> Unit) {
            recordSaveCalls += 1
            if (recordSaveSucceeds) records += journal.growthRecordId
            completion(recordSaveSucceeds)
        }
    }
}
