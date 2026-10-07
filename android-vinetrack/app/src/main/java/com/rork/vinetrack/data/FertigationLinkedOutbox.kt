package com.rork.vinetrack.data

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.encodeToString

/** Atomic persisted envelope containing both writes and their server-acknowledged phase. */
class FertigationLinkedOutbox(private val load: () -> String?, private val store: (String) -> Unit) {
    @Serializable
    enum class Phase { IRRIGATION_PENDING, FERTIGATION_PENDING, ACKNOWLEDGED, PERMANENT_ERROR }
    @Serializable
    data class Entry(
        val id: String,
        val ownerId: String,
        val irrigation: PendingIrrigationSession,
        val step: JsonObject,
        val products: List<Product>,
        val notes: String?,
        val phase: Phase = Phase.IRRIGATION_PENDING,
        val acknowledgedProducts: List<JsonObject>? = null,
        val acknowledgedTotals: FertigationDomain.Totals? = null,
        val error: String? = null,
    ) {
        val message: String get() = when (phase) {
            Phase.IRRIGATION_PENDING -> "Irrigation and Fertigation saved on this device — waiting to sync."
            Phase.FERTIGATION_PENDING -> "Irrigation recorded — Fertigation still needs to be saved."
            Phase.ACKNOWLEDGED -> "Irrigation and Fertigation recorded."
            Phase.PERMANENT_ERROR -> "Irrigation recorded — Fertigation needs attention. ${error ?: "Contact a System Admin, then retry Fertigation."}"
        }
    }
    @Serializable
    data class Product(val id: String, val line: JsonObject, val actual: String) {
        fun payload(totals: FertigationDomain.Totals, step: JsonObject): JsonObject = FertigationDomain.DraftProduct(id, line, actual).payload(totals, step)
    }
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()
    @Synchronized fun entries(): List<Entry> = load()?.let { json.decodeFromString<List<Entry>>(it) } ?: emptyList()
    @Synchronized fun enqueue(entry: Entry) {
        val all = entries()
        if (all.any { it.id == entry.id || it.irrigation.id == entry.irrigation.id }) return
        store(json.encodeToString(all + entry))
    }
    @Synchronized private fun replace(entry: Entry) = store(json.encodeToString(entries().map { if (it.id == entry.id) entry else it }))
    @Synchronized fun retry(id: String) {
        val entry = entries().firstOrNull { it.id == id && it.phase == Phase.PERMANENT_ERROR } ?: return
        replace(entry.copy(phase = if (entry.acknowledgedTotals == null) Phase.IRRIGATION_PENDING else Phase.FERTIGATION_PENDING, error = null))
    }
    suspend fun flush(vineyardId: String, ownerId: String,
        record: suspend (PendingIrrigationSession) -> IrrigationSessionRow,
        upsert: suspend (Entry, List<JsonObject>) -> JsonObject,
        permanent: (Throwable) -> Boolean,
    ) = mutex.withLock {
        for (original in entries().filter { it.irrigation.vineyardId == vineyardId && it.ownerId == ownerId && it.phase != Phase.ACKNOWLEDGED && it.phase != Phase.PERMANENT_ERROR }) {
            var entry = original
            try {
                if (entry.phase == Phase.IRRIGATION_PENDING) {
                    val saved = record(entry.irrigation)
                    check(saved.id == entry.irrigation.id && saved.vineyardId == vineyardId && saved.status in listOf("completed", "corrected", "imported", "estimated")) { "Irrigation acknowledgement mismatch" }
                    val totals = FertigationDomain.Totals.from(saved.blocks.map { FertigationDomain.Allocation(it.servicedAreaM2, it.servicedVineCount?.toDouble()) })
                    entry = entry.copy(acknowledgedTotals = totals, phase = Phase.FERTIGATION_PENDING, error = null)
                    replace(entry)
                }
                if (entry.acknowledgedProducts == null) {
                    val totals = checkNotNull(entry.acknowledgedTotals)
                    entry = entry.copy(acknowledgedProducts = entry.products.map { it.payload(totals, entry.step) })
                    replace(entry)
                }
                val saved = upsert(entry, checkNotNull(entry.acknowledgedProducts))
                check(FertigationDomain.string(saved, "id").equals(entry.id, true) && FertigationDomain.string(saved, "irrigation_session_id").equals(entry.irrigation.id, true)) { "Fertigation acknowledgement mismatch" }
                replace(entry.copy(phase = Phase.ACKNOWLEDGED, error = null))
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                replace(entry.copy(phase = if (entry.phase == Phase.FERTIGATION_PENDING && permanent(e)) Phase.PERMANENT_ERROR else entry.phase,
                    error = "Check vineyard access and the Program Step, then retry Fertigation."))
            }
        }
    }
}
