package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.*
import com.rork.vinetrack.data.model.*
import java.time.Instant
import kotlinx.serialization.json.Json

/** Fixed metadata only. Never retain an exception message, key, payload or record identifier. */
data class RecoveryEvidenceDiagnostic internal constructor(
    val category: String,
    val rule: String,
    val schemaVersion: Int? = null,
    val recordCount: Int? = null,
)

internal class EvidenceContractFailure(val diagnostic: RecoveryEvidenceDiagnostic) : IllegalStateException()

/** Read-only admission, not replay or acknowledgement. Unlisted writer formats stay protected. */
internal object RetainedEvidenceContract {
    private val json = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private val statuses = PendingWriteStatus.unresolved + PendingWriteStatus.SYNCED
    private fun requireRule(value: Boolean, category: String, rule: String, schema: Int? = null, count: Int? = null) {
        if (!value) throw EvidenceContractFailure(RecoveryEvidenceDiagnostic(category, rule, schema, count))
    }
    private inline fun <T> decode(category: String, schema: Int? = null, count: Int? = null, block: () -> T): T =
        try { block() } catch (failure: EvidenceContractFailure) { throw failure }
        catch (_: Exception) { throw EvidenceContractFailure(RecoveryEvidenceDiagnostic(category, "DECODE_SCHEMA", schema, count)) }

    fun queue(values: Map<String, *>, original: String?): Set<String> {
        val category = "vinetrack_pending_writes"
        requireRule(values.keys.all { it == "pending_writes_json" }, category, "STORE_KEYS", count = values.size)
        val raw = values["pending_writes_json"] ?: return emptySet()
        requireRule(raw is String, category, "VALUE_TYPE")
        val writes = decode(category) { json.decodeFromString<List<PendingWrite>>(raw as String) }
        return writes(writes, original, category)
    }

    private fun envelope(write: PendingWrite, category: String, count: Int) {
        requireRule(write.id.isNotBlank() && write.clientId.isNotBlank() && write.createdAt >= 0 &&
            write.updatedAt >= write.createdAt && write.attemptCount >= 0 && write.status in statuses,
            category, "WRITE_ENVELOPE", count = count)
    }

    private fun writes(writes: List<PendingWrite>, original: String?, category: String): Set<String> {
        requireRule(writes.map { it.id }.distinct().size == writes.size, category, "DUPLICATE_WRITE_ID", count = writes.size)
        return writes.mapTo(mutableSetOf()) { write ->
            envelope(write, category, writes.size)
            // PIN/CREATE is the audited production payload with explicit author and vineyard.
            // ID-only deletes/updates and every other unreviewed discriminator remain globally locked.
            requireRule(write.entityType == PendingEntityType.PIN && write.opType == PendingOpType.CREATE,
                category, "UNSUPPORTED_OPERATION_OWNER", count = writes.size)
            val input = decode(category, count = writes.size) { json.decodeFromString<PinRepository.PinInput>(write.payloadJson) }
            requireRule(original != null && input.createdBy == original, category, "WRITE_OWNER", count = writes.size)
            requireRule(input.id == write.clientId && input.vineyardId.isNotBlank(), category, "WRITE_SCOPE_IDENTITY", count = writes.size)
            input.vineyardId
        }
    }

    fun snapshots(values: Map<String, *>, original: String?): Set<String> {
        val category = "vinetrack_recovery_snapshots_v2"
        val vineyards = mutableSetOf<String>()
        values.forEach { (key, raw) ->
            requireRule(raw is String, category, "VALUE_TYPE", count = values.size)
            requireRule(!RecoverySnapshotStore.hasUnprovenEvidence(key), category, "UNPROVEN_COMMIT", count = values.size)
            when {
                key.startsWith("snapshot_") -> {
                    val snapshot = decode(category) { json.decodeFromString<RecoverySnapshotStore.Snapshot>(raw as String) }
                    val version = snapshot.formatVersion
                    val count = snapshot.pendingWrites.size + snapshot.captureEvidence.size + snapshot.cachedPins.size +
                        snapshot.cachedTrips.size + if (snapshot.activeTrip == null) 0 else 1
                    fun rule(ok: Boolean, code: String) = requireRule(ok, category, code, version, count)
                    rule(version == 3, "SNAPSHOT_VERSION")
                    rule(snapshot.vineyardId.isNotBlank() && key == "snapshot_${snapshot.vineyardId}", "SNAPSHOT_SCOPE_KEY")
                    rule(snapshot.source == "before_vineyard_load_refresh_or_replay" &&
                        runCatching { Instant.parse(snapshot.snapshotAt) }.isSuccess && snapshot.buildVersion > 0 && snapshot.appVersion.isNotBlank(), "SNAPSHOT_PROVENANCE")
                    val counts = mapOf("pending_writes" to snapshot.pendingWrites.size, "pin_capture_evidence" to snapshot.captureEvidence.size,
                        "cached_pins" to snapshot.cachedPins.size, "cached_trips" to snapshot.cachedTrips.size,
                        "active_trip" to if (snapshot.activeTrip == null) 0 else 1)
                    rule(snapshot.sourceStatuses.size == counts.size && snapshot.sourceStatuses.map { it.source }.toSet() == counts.keys &&
                        snapshot.sourceStatuses.all { it.status == "read" && it.itemCount == counts[it.source] }, "SNAPSHOT_SOURCE_COUNTS")
                    rule(snapshot.excludedOrUnreadable.isEmpty(), "SNAPSHOT_UNRESOLVED_SOURCE")
                    rule(snapshot.cachedPins.map { it.id }.distinct().size == snapshot.cachedPins.size &&
                        snapshot.cachedTrips.map { it.id }.distinct().size == snapshot.cachedTrips.size, "SNAPSHOT_DUPLICATE_ID")
                    // Older format-3 snapshots have no owner envelope. Only their explicit record
                    // identities can prove attribution; today's selected vineyard/cache owner cannot.
                    snapshot.cachedPins.forEach {
                        rule(it.id.isNotBlank() && it.vineyardId == snapshot.vineyardId, "SNAPSHOT_PIN_SCOPE")
                        rule(original != null && it.createdBy == original, "SNAPSHOT_PIN_OWNER")
                    }
                    (snapshot.cachedTrips + listOfNotNull(snapshot.activeTrip)).forEach {
                        rule(it.id.isNotBlank() && it.vineyardId == snapshot.vineyardId, "SNAPSHOT_TRIP_SCOPE")
                        rule(original != null && it.operatorUserId == original, "SNAPSHOT_TRIP_OWNER")
                    }
                    snapshot.captureEvidence.forEach {
                        rule(it.pinId.isNotBlank() && it.vineyardId == snapshot.vineyardId, "SNAPSHOT_CAPTURE_SCOPE")
                        rule(original != null && it.captureUserId == original, "SNAPSHOT_CAPTURE_OWNER")
                    }
                    val scopes = writes(snapshot.pendingWrites, original, category)
                    rule(scopes.all { it == snapshot.vineyardId }, "SNAPSHOT_WRITE_SCOPE")
                    vineyards.add(snapshot.vineyardId)
                }
                key.startsWith("delete_receipt_") -> {
                    val receipt = decode(category) { json.decodeFromString<RecoverySnapshotStore.TombstoneReceipt>(raw as String) }
                    fun rule(ok: Boolean, code: String) = requireRule(ok, category, code, count = 1)
                    val digest = java.security.MessageDigest.getInstance("SHA-256").digest((raw as String).toByteArray())
                        .joinToString("") { "%02x".format(it) }
                    rule(key == "delete_receipt_$digest", "RECEIPT_DIGEST")
                    rule(original != null && receipt.ownerUserId == original, "RECEIPT_OWNER")
                    envelope(receipt.original, category, 1)
                    rule(receipt.original.entityType == PendingEntityType.PIN && receipt.original.opType == PendingOpType.DELETE &&
                        receipt.original.status == PendingWriteStatus.BLOCKED, "RECEIPT_OPERATION")
                    val payload = decode(category, count = 1) { json.decodeFromString<PinDeleteSync.Payload>(receipt.original.payloadJson) }
                    rule(payload.pinId.isNotBlank() && payload.pinId == receipt.original.clientId && payload.pinId == receipt.server.id &&
                        receipt.server.vineyardId.isNotBlank(), "RECEIPT_TARGET_SCOPE")
                    rule(receipt.server.deletedAt?.let { runCatching { Instant.parse(it) }.isSuccess } == true, "RECEIPT_TOMBSTONE")
                    vineyards.add(receipt.server.vineyardId)
                    // Historical original is never inserted into the live outbox or marked successful.
                }
                else -> requireRule(false, category, "STORE_KEYS", count = values.size)
            }
        }
        return vineyards
    }
}
