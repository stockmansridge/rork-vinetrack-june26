package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant
import java.util.UUID

/** Durable Saved Chemical CREATE using the shared pending-write outbox and stable chemical UUID. */
internal class SavedChemicalCreateSync(
    private val repository: SavedChemicalRepository,
    private val pending: PendingWriteRepository,
    private val local: SavedChemicalLocalStoring,
    private val ownerId: () -> String?,
    private val upload: suspend (SavedChemicalRepository.ChemicalInsert) -> SavedChemical = repository::create,
    private val findById: suspend (String) -> SavedChemical? = repository::findById,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
    private val lock = Mutex()

    @Serializable
    internal data class Payload(val ownerId: String, val insert: SavedChemicalRepository.ChemicalInsert)

    private fun decode(write: PendingWrite): Payload? = runCatching {
        json.decodeFromString(Payload.serializer(), write.payloadJson)
    }.getOrNull()?.takeIf { it.insert.id == write.clientId }

    /** Commit the immutable insert to the existing outbox and local Chemical Store before reporting success. */
    fun save(vineyardId: String, input: SavedChemicalRepository.ChemicalInput): SavedChemical {
        val userId = requireNotNull(ownerId()) { "Sign in before saving a chemical." }
        val id = UUID.randomUUID().toString()
        val body = repository.prepareCreate(vineyardId, input, id, Instant.now().toString())
        val chemical = repository.localCreate(body)
        pending.enqueue(
            PendingEntityType.SAVED_CHEMICAL, PendingOpType.CREATE,
            json.encodeToString(Payload.serializer(), Payload(userId, body)), id,
        )
        check(storeRow(userId, chemical)) { "Saved Chemical could not be committed locally." }
        return chemical
    }

    /** Local snapshot plus unsynced inserts; the outbox also repairs a torn two-store commit. */
    fun rows(userId: String, vineyardId: String): List<SavedChemical> {
        val cached = local.load(userId, vineyardId).filter { it.deletedAt == null && it.isActive }
        val queued = pending.list().filter { it.entityType == PendingEntityType.SAVED_CHEMICAL &&
            it.opType == PendingOpType.CREATE && it.status != PendingWriteStatus.SYNCED }
            .mapNotNull { write -> decode(write)?.takeIf { it.ownerId == userId && it.insert.vineyardId == vineyardId }
                ?.let { repository.localCreate(it.insert) } }
        return (cached + queued).distinctBy { it.id }.sortedBy { it.displayName.lowercase() }
    }

    /** Overlay local creates by id; never replace an unsynced local row with a stale server list. */
    fun mergeRemote(userId: String, vineyardId: String, remote: List<SavedChemical>): List<SavedChemical> {
        val localRows = rows(userId, vineyardId)
        val unresolved = pending.list().filter { it.entityType == PendingEntityType.SAVED_CHEMICAL &&
            it.opType == PendingOpType.CREATE && it.status != PendingWriteStatus.SYNCED }
            .mapNotNull { write -> decode(write)?.takeIf { it.ownerId == userId }?.insert?.id }.toSet()
        val merged = (remote.filter { it.id !in unresolved } + localRows.filter { it.id in unresolved })
            .distinctBy { it.id }.sortedBy { it.displayName.lowercase() }
        local.save(userId, vineyardId, merged)
        return merged
    }

    fun removeLocal(userId: String, vineyardId: String, id: String) {
        local.save(userId, vineyardId, local.load(userId, vineyardId).filterNot { it.id == id })
    }

    suspend fun replayAll(onSynced: (SavedChemical) -> Unit = {}) {
        if (!lock.tryLock()) return
        try {
            val owner = ownerId() ?: return
            val candidates = pending.list().filter { it.entityType == PendingEntityType.SAVED_CHEMICAL &&
                it.opType == PendingOpType.CREATE && it.status in setOf(
                    PendingWriteStatus.PENDING, PendingWriteStatus.FAILED, PendingWriteStatus.IN_PROGRESS,
                ) }
            for (write in candidates) {
                val payload = decode(write)
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Saved Chemical insert could not be read.")
                    continue
                }
                if (payload.ownerId != owner) continue
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val body = payload.insert
                try {
                    val saved = try {
                        upload(body)
                    } catch (error: BackendError.Server) {
                        if (error.code != 409) throw error
                        // A conflict is only success after reading the SAME primary key in the SAME vineyard.
                        val existing = findById(body.id)
                        if (existing == null || existing.id != body.id || existing.vineyardId != body.vineyardId) throw error
                        existing
                    }
                    if (saved.id != body.id || saved.vineyardId != body.vineyardId) {
                        pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Saved Chemical identity mismatch.")
                        continue
                    }
                    check(storeRow(owner, saved)) { "Saved Chemical could not be committed locally." }
                    pending.remove(write.id)
                    onSynced(saved)
                } catch (cancelled: CancellationException) {
                    pending.updateStatus(write.id, PendingWriteStatus.FAILED, "Sync interrupted.")
                    throw cancelled
                } catch (_: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this chemical.")
                } catch (error: BackendError.Server) {
                    if (error.code in 500..599) retryOrBlock(write, "Server error (${error.code}).")
                    else pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Chemical rejected (${error.code}).")
                } catch (_: Exception) {
                    retryOrBlock(write, "No connection to sync this chemical.")
                }
            }
        } finally {
            lock.unlock()
        }
    }

    private fun storeRow(userId: String, row: SavedChemical): Boolean =
        local.save(userId, row.vineyardId, (local.load(userId, row.vineyardId).filterNot { it.id == row.id } + row))

    private fun retryOrBlock(write: PendingWrite, message: String) {
        pending.incrementAttempt(write.id)
        pending.updateStatus(write.id,
            if (write.attemptCount + 1 >= 8) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED,
            message)
    }
}
