package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.FertiliserProduct
import com.rork.vinetrack.data.model.FertiliserRecord
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.Json
import java.time.LocalDate

/**
 * Offline-first coordinator for the Fertiliser Calculator (System Admin only
 * while in development). Mirrors iOS `FertiliserSyncService`: local-first
 * writes into [FertiliserStore] plus queued replays into the shared
 * `fertiliser_products` / `fertiliser_records` / `fertiliser_record_allocations`
 * tables; [refresh] pulls and reconciles, keeping records with unresolved
 * queued writes untouched until their push lands.
 */
class FertiliserSyncCoordinator(
    private val store: FertiliserStore,
    private val repo: FertiliserSyncRepository,
    private val pending: PendingWriteRepository,
    private val scope: CoroutineScope,
    private val canSync: () -> Boolean,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val replayLock = Mutex()

    // MARK: Cached reads

    fun products(vineyardId: String): List<FertiliserProduct> = store.loadProducts(vineyardId)

    fun records(vineyardId: String): List<FertiliserRecord> = store.loadRecords(vineyardId)

    // MARK: Local-first writes

    fun upsertProduct(vineyardId: String, product: FertiliserProduct): List<FertiliserProduct> {
        val updated = store.upsertProduct(vineyardId, product)
        enqueueCoalesced(
            entityType = PendingEntityType.FERTILISER_PRODUCT,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(FertiliserProduct.serializer(), product),
            clientId = product.id,
        )
        scope.launch { replayAll() }
        return updated
    }

    fun deleteProduct(vineyardId: String, productId: String): List<FertiliserProduct> {
        val updated = store.deleteProduct(vineyardId, productId)
        removeUnresolved(PendingEntityType.FERTILISER_PRODUCT, PendingOpType.UPDATE, productId)
        enqueueCoalesced(
            entityType = PendingEntityType.FERTILISER_PRODUCT,
            opType = PendingOpType.DELETE,
            payloadJson = productId,
            clientId = productId,
        )
        scope.launch { replayAll() }
        return updated
    }

    fun addRecord(vineyardId: String, record: FertiliserRecord): List<FertiliserRecord> {
        val updated = store.addRecord(vineyardId, record)
        enqueueRecordUpsert(record)
        scope.launch { replayAll() }
        return updated
    }

    fun markCompleted(vineyardId: String, recordId: String, date: String = LocalDate.now().toString()): List<FertiliserRecord> {
        val updated = store.markCompleted(vineyardId, recordId, date)
        updated.firstOrNull { it.id == recordId }?.let { enqueueRecordUpsert(it) }
        scope.launch { replayAll() }
        return updated
    }

    fun deleteRecord(vineyardId: String, recordId: String): List<FertiliserRecord> {
        val updated = store.deleteRecord(vineyardId, recordId)
        removeUnresolved(PendingEntityType.FERTILISER_RECORD, PendingOpType.UPDATE, recordId)
        enqueueCoalesced(
            entityType = PendingEntityType.FERTILISER_RECORD,
            opType = PendingOpType.DELETE,
            payloadJson = recordId,
            clientId = recordId,
        )
        scope.launch { replayAll() }
        return updated
    }

    // MARK: Replay

    /** Products push before records so product foreign keys always resolve. */
    suspend fun replayAll() {
        if (!canSync()) return
        if (!replayLock.tryLock()) return
        try {
            replayPass(PendingEntityType.FERTILISER_PRODUCT, PendingOpType.UPDATE) { write ->
                val product = json.decodeFromString(FertiliserProduct.serializer(), write.payloadJson)
                repo.upsertProduct(product)
            }
            replayPass(PendingEntityType.FERTILISER_RECORD, PendingOpType.UPDATE) { write ->
                val record = json.decodeFromString(FertiliserRecord.serializer(), write.payloadJson)
                repo.upsertRecord(record)
            }
            replayPass(PendingEntityType.FERTILISER_PRODUCT, PendingOpType.DELETE) { write ->
                repo.softDeleteProduct(write.clientId)
            }
            replayPass(PendingEntityType.FERTILISER_RECORD, PendingOpType.DELETE) { write ->
                repo.softDeleteRecord(write.clientId)
            }
        } finally {
            replayLock.unlock()
        }
    }

    // MARK: Refresh (pull + reconcile)

    suspend fun refresh(vineyardId: String): Pair<List<FertiliserProduct>, List<FertiliserRecord>> {
        if (!canSync()) return store.loadProducts(vineyardId) to store.loadRecords(vineyardId)
        replayAll()
        return try {
            val unresolved = pending.list().filter { it.status in PendingWriteStatus.unresolved }
            val pendingProductIds = unresolved
                .filter { it.entityType == PendingEntityType.FERTILISER_PRODUCT }
                .map { it.clientId }.toSet()
            val pendingRecordIds = unresolved
                .filter { it.entityType == PendingEntityType.FERTILISER_RECORD }
                .map { it.clientId }.toSet()

            val remoteProducts = repo.fetchProducts(vineyardId)
            val remoteRecords = repo.fetchRecords(vineyardId)
            val remoteAllocations = repo.fetchAllocations(vineyardId)
            val allocationsByRecord = remoteAllocations.groupBy { it.fertiliserRecordId }

            val localProducts = store.loadProducts(vineyardId)
            val remoteProductIds = remoteProducts.map { it.id }.toSet()
            val mergedProducts = remoteProducts
                .filter { it.deletedAt == null && it.id !in pendingProductIds }
                .map { it.toModel() } +
                localProducts.filter { it.id in pendingProductIds }
            localProducts
                .filter { it.id !in remoteProductIds && it.id !in pendingProductIds }
                .forEach { product ->
                    enqueueCoalesced(
                        entityType = PendingEntityType.FERTILISER_PRODUCT,
                        opType = PendingOpType.UPDATE,
                        payloadJson = json.encodeToString(FertiliserProduct.serializer(), product),
                        clientId = product.id,
                    )
                }
            store.saveProducts(vineyardId, mergedProducts)

            val localRecords = store.loadRecords(vineyardId)
            val remoteRecordIds = remoteRecords.map { it.id }.toSet()
            val mergedRecords = remoteRecords
                .filter { it.deletedAt == null && it.id !in pendingRecordIds }
                .map { row -> row.toModel(allocationsByRecord[row.id].orEmpty().map { it.toModel() }) } +
                localRecords.filter { it.id in pendingRecordIds }
            localRecords
                .filter { it.id !in remoteRecordIds && it.id !in pendingRecordIds }
                .forEach { enqueueRecordUpsert(it) }
            store.saveRecords(vineyardId, mergedRecords)

            mergedProducts to mergedRecords
        } catch (_: Exception) {
            store.loadProducts(vineyardId) to store.loadRecords(vineyardId)
        }
    }

    // MARK: Outbox plumbing

    private fun enqueueRecordUpsert(record: FertiliserRecord) {
        enqueueCoalesced(
            entityType = PendingEntityType.FERTILISER_RECORD,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(FertiliserRecord.serializer(), record),
            clientId = record.id,
        )
    }

    private fun enqueueCoalesced(entityType: String, opType: String, payloadJson: String, clientId: String) {
        pending.list()
            .filter {
                it.entityType == entityType && it.opType == opType && it.clientId == clientId &&
                    it.status in PendingWriteStatus.unresolved
            }
            .forEach { pending.remove(it.id) }
        pending.enqueue(entityType = entityType, opType = opType, payloadJson = payloadJson, clientId = clientId)
    }

    private fun removeUnresolved(entityType: String, opType: String, clientId: String) {
        pending.list()
            .filter {
                it.entityType == entityType && it.opType == opType && it.clientId == clientId &&
                    it.status in PendingWriteStatus.unresolved
            }
            .forEach { pending.remove(it.id) }
    }

    private suspend fun replayPass(entityType: String, opType: String, action: suspend (PendingWrite) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == entityType && it.opType == opType &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            try {
                action(write)
                pending.remove(write.id)
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync fertiliser data.")
            } catch (e: BackendError.Server) {
                when {
                    e.code == 409 -> pending.remove(write.id)
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Rejected (${e.code}).")
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        const val MAX_ATTEMPTS = 8
    }
}
