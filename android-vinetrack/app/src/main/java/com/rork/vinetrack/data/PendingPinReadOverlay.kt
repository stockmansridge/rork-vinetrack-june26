package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Pin
import kotlinx.serialization.json.Json

/** Display-only overlay. Never replays, acknowledges, timestamps or persists work. */
internal object PendingPinReadOverlay {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Returns null when a legacy/custom operation cannot yet be reconstructed safely.
     * The caller retains existing state instead of publishing a misleading snapshot.
     * Vineyard-less completion/edit/delete payloads apply only to scoped known rows.
     */
    fun overlay(
        baseline: List<Pin>,
        existing: List<Pin>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<Pin>? {
        val writes = pending.filter { it.status in PendingWriteStatus.unresolved }
        if (writes.any { it.entityType == PendingEntityType.CUSTOM_PIN ||
                it.entityType == PendingEntityType.MANUAL_ISSUE }) return null
        val rows = baseline.filter { it.vineyardId.equals(vineyardId, ignoreCase = true) }
            .associateByTo(linkedMapOf()) { it.id }
        val pinWrites = writes.filter {
            it.entityType == PendingEntityType.PIN || it.entityType == PendingEntityType.PIN_EDIT
        }.sortedWith(compareBy<PendingWrite> { it.updatedAt }.thenBy { it.createdAt })
        for (write in pinWrites.filter { it.entityType == PendingEntityType.PIN && it.opType == PendingOpType.CREATE }) {
            // PinInput and Pin use the same stored wire field names. Decoding the
            // display model preserves capture precision without minting identities.
            val created = runCatching { json.decodeFromString(Pin.serializer(), write.payloadJson) }.getOrNull()
                ?: return null
            if (!created.vineyardId.equals(vineyardId, ignoreCase = true)) continue
            if (created.id != write.clientId) return null
            val local = existing.firstOrNull { it.id == created.id && it.vineyardId == created.vineyardId }
            rows.putIfAbsent(created.id, local ?: created)
        }
        val deleted = mutableSetOf<String>()
        for (write in pinWrites) {
            when {
                write.entityType == PendingEntityType.PIN_EDIT && write.opType == PendingOpType.UPDATE -> {
                    val edit = runCatching { json.decodeFromString(PinEditSync.Payload.serializer(), write.payloadJson) }
                        .getOrNull() ?: return null
                    rows[edit.pinId]?.let { row ->
                        rows[edit.pinId] = row.copy(title = edit.title, category = edit.category,
                            mode = edit.mode, notes = edit.notes, clientUpdatedAt = edit.clientUpdatedAt)
                    }
                }
                write.entityType == PendingEntityType.PIN && write.opType == PendingOpType.UPDATE -> {
                    val toggle = runCatching { json.decodeFromString(PinCompletionSync.Payload.serializer(), write.payloadJson) }
                        .getOrNull() ?: return null
                    rows[toggle.pinId]?.let { rows[toggle.pinId] = it.copy(isCompleted = toggle.isCompleted) }
                }
                write.entityType == PendingEntityType.PIN && write.opType == PendingOpType.DELETE -> {
                    val deletion = runCatching { json.decodeFromString(PinDeleteSync.Payload.serializer(), write.payloadJson) }
                        .getOrNull() ?: return null
                    deleted.add(deletion.pinId)
                }
            }
        }
        return rows.values.filterNot { it.id in deleted }
    }
}
