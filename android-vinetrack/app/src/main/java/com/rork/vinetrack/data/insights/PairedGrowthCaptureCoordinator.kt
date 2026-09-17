package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

/** Durable state for one pin + Growth Stage record capture. */
@Serializable
data class PairedGrowthCaptureJournal(
    val operationId: String,
    val pinId: String,
    val growthRecordId: String,
    val vineyardId: String,
    val paddockId: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val rowNumber: Int? = null,
    val stageCode: String,
    val stageLabel: String? = null,
    val variety: String? = null,
    val notes: String? = null,
    val observedAtIso: String,
    val originatingFeature: String,
    val locationScope: String? = null,
    val pinRowNumber: Double? = null,
    val pinSide: String? = null,
    val alongRowDistanceM: Double? = null,
    val snappedLatitude: Double? = null,
    val snappedLongitude: Double? = null,
    val snapState: String? = null,
    val drivingRowNumber: Double? = null,
    val headingDegrees: Double? = null,
    val segments: List<Segment> = emptyList(),
    val state: State = State.PLANNED,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
) {
    @Serializable
    data class Segment(val row: Int, val segment: Int)

    @Serializable
    enum class State { PLANNED, PIN_SAVED, RECORD_SAVED, COMPLETE }

    fun matchesPending(other: PairedGrowthCaptureJournal): Boolean =
        vineyardId == other.vineyardId && paddockId == other.paddockId &&
            originatingFeature == other.originatingFeature && state != State.COMPLETE
}

/** Storage seam implemented by SharedPreferences in production and memory in tests. */
interface PairedGrowthCaptureJournalStore {
    fun load(): List<PairedGrowthCaptureJournal>
    fun save(journal: PairedGrowthCaptureJournal): Boolean
    fun remove(operationId: String): Boolean
}

/** Cross-outbox classification for a growth row that reached the server first. */
object GrowthCaptureServerOrdering {
    fun isMissingPinForeignKey(body: String): Boolean =
        body.contains("23503") && body.contains("pin", ignoreCase = true)
}

/**
 * Orchestrates the real paired local writes. The journal is committed before the
 * pin write and after each durable step; retries and restart therefore reuse both
 * identities and execute only the missing half.
 */
class PairedGrowthCaptureCoordinator(
    private val store: PairedGrowthCaptureJournalStore,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val activeOperations: MutableSet<String> = mutableSetOf()

    interface Writer {
        fun hasPin(pinId: String): Boolean
        fun hasRecord(recordId: String): Boolean
        fun savePin(journal: PairedGrowthCaptureJournal, completion: (Boolean) -> Unit)
        fun saveRecord(journal: PairedGrowthCaptureJournal, completion: (Boolean) -> Unit)
    }

    fun beginOrReuse(candidate: PairedGrowthCaptureJournal): PairedGrowthCaptureJournal? {
        store.load().firstOrNull { it.matchesPending(candidate) }?.let { return it }
        return candidate.takeIf { store.save(it) }
    }

    fun resume(
        operationId: String,
        writer: Writer,
        completion: (Boolean, PairedGrowthCaptureJournal?) -> Unit,
    ) {
        val journal = store.load().firstOrNull { it.operationId == operationId }
            ?: return completion(false, null)
        val started = synchronized(activeOperations) { activeOperations.add(operationId) }
        if (!started) return completion(false, journal)
        resumeJournal(journal, writer) { complete, finalJournal ->
            synchronized(activeOperations) { activeOperations.remove(operationId) }
            completion(complete, finalJournal)
        }
    }

    fun resumeAll(writer: Writer, vineyardId: String? = null) {
        store.load()
            .filter { it.state != PairedGrowthCaptureJournal.State.COMPLETE }
            .filter { vineyardId == null || it.vineyardId == vineyardId }
            .forEach { resume(it.operationId, writer) { _, _ -> } }
    }

    private fun resumeJournal(
        initial: PairedGrowthCaptureJournal,
        writer: Writer,
        completion: (Boolean, PairedGrowthCaptureJournal?) -> Unit,
    ) {
        var journal = initial
        fun persist(state: PairedGrowthCaptureJournal.State): Boolean {
            journal = journal.copy(state = state, updatedAtMillis = nowMillis())
            return store.save(journal)
        }
        fun complete() {
            if (!persist(PairedGrowthCaptureJournal.State.COMPLETE)) {
                completion(false, journal); return
            }
            if (!store.remove(journal.operationId)) {
                completion(false, journal); return
            }
            completion(true, journal)
        }
        fun finishRecord() {
            if (writer.hasRecord(journal.growthRecordId)) {
                if (!persist(PairedGrowthCaptureJournal.State.RECORD_SAVED)) {
                    completion(false, journal); return
                }
                complete()
                return
            }
            writer.saveRecord(journal) { saved ->
                if (!saved || !persist(PairedGrowthCaptureJournal.State.RECORD_SAVED)) {
                    completion(false, journal); return@saveRecord
                }
                complete()
            }
        }
        fun finishPin() {
            if (writer.hasPin(journal.pinId)) {
                if (!persist(PairedGrowthCaptureJournal.State.PIN_SAVED)) {
                    completion(false, journal); return
                }
                finishRecord()
                return
            }
            writer.savePin(journal) { saved ->
                if (!saved || !persist(PairedGrowthCaptureJournal.State.PIN_SAVED)) {
                    completion(false, journal); return@savePin
                }
                finishRecord()
            }
        }
        when (journal.state) {
            PairedGrowthCaptureJournal.State.PLANNED -> finishPin()
            PairedGrowthCaptureJournal.State.PIN_SAVED -> finishRecord()
            PairedGrowthCaptureJournal.State.RECORD_SAVED -> complete()
            PairedGrowthCaptureJournal.State.COMPLETE -> {
                store.remove(journal.operationId)
                completion(true, journal)
            }
        }
    }
}
