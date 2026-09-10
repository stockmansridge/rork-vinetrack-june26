package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PendingPhotoEntityKind
import com.rork.vinetrack.data.model.PendingPhotoStatus
import kotlinx.coroutines.sync.Mutex
import java.io.File

/**
 * Upload coordinator for retained pin photos only (Stage 7C).
 *
 * Stage 7B copies a photo to app-private storage and records a
 * [PendingPhotoAttachment] when it can't upload immediately (offline-created
 * pin, or an online pin whose photo upload failed). This replays those
 * attachments: it uploads the local JPEG to the canonical Supabase Storage
 * path and PATCHes the pin's `photo_path`, then cleans up on success.
 *
 * Deliberately narrow — it is NOT a general SyncManager. It handles pin photo
 * attachments and nothing else: no growth-record photos, no multi-photo, no
 * other entity, and no new offline write types.
 *
 * Pin-exists ordering: a photo is only uploaded once its pin exists
 * server-side. Offline-created pins still queued in the pin-create outbox are
 * skipped until [PinCreateSync] removes the create (i.e. the pin synced).
 *
 * Idempotency: the storage path is deterministic
 * (`{vineyardId}/pins/{clientPinId}/photo.jpg`) and uploads upsert, so a
 * retried upload is safe; `updatePhotoPath` re-runs against the same row.
 */
interface PinPhotoObjectGateway {
    suspend fun upload(vineyardId: String, pinId: String, jpeg: ByteArray, revision: String? = null): String
    suspend fun uploadAtPath(path: String, jpeg: ByteArray): String
    fun growthStoragePath(vineyardId: String, recordId: String, revision: String? = null): String
}

interface PinPhotoReferenceGateway {
    suspend fun updatePhotoPath(id: String, photoPath: String?): com.rork.vinetrack.data.model.Pin
}

interface GrowthPhotoReferenceGateway {
    suspend fun updatePhotoPaths(id: String, paths: List<String>?): com.rork.vinetrack.data.model.GrowthStageRecord
}

/** Server-confirmed attachment metadata reconciled into visible UI state. */
data class PhotoUploadConfirmation(
    val attachment: PendingPhotoAttachment,
    val path: String,
    val pin: com.rork.vinetrack.data.model.Pin? = null,
    val growthRecord: com.rork.vinetrack.data.model.GrowthStageRecord? = null,
    val remoteIdentity: String,
)

class PinPhotoSync(
    private val pinPhotoRepo: PinPhotoObjectGateway,
    private val pinRepo: PinPhotoReferenceGateway,
    private val growthRepo: GrowthPhotoReferenceGateway,
    private val pending: PendingPhotoRepository,
    private val pendingCreates: () -> List<com.rork.vinetrack.data.model.PendingWrite>,
) {
    /** Serialises replay so overlapping connectivity/load events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Replay every retry-eligible pending photo. No-ops (returns) if a replay is
     * already running. For each attachment whose pin exists server-side: read
     * the local JPEG, upload it, PATCH the pin's `photo_path`, then mark
     * uploaded (deleting the local file). [onUploaded] fires on success with the
     * pin id and stored path so the caller can reconcile state.
     *
     * Caller is responsible for only invoking this when online and a session
     * token exists.
     */
    suspend fun replayAll(permittedAttachmentIds: Set<String>? = null, onUploaded: (PhotoUploadConfirmation) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            // Pins still queued for create haven't synced yet — their photos must
            // wait so the PATCH lands on an existing row.
            val writes = pendingCreates()
            val queuedPinIds = writes
                .filter { it.entityType == PendingEntityType.PIN && it.opType == PendingOpType.CREATE }
                .map { it.clientId }
                .toSet()
            val queuedGrowthIds = writes
                .filter { it.entityType == PendingEntityType.GROWTH_RECORD && it.opType == PendingOpType.CREATE }
                .map { it.clientId }
                .toSet()
            val deletingIds = writes
                .filter { it.opType == PendingOpType.DELETE }
                .map { it.clientId }
                .toSet()
            val candidates = pending.list().filter {
                (it.status == PendingPhotoStatus.PENDING || it.status == PendingPhotoStatus.FAILED) &&
                    (permittedAttachmentIds == null || it.id in permittedAttachmentIds)
            }
            for (att in candidates) {
                // Pin-exists ordering: leave the attachment pending until its pin
                // create has synced. Don't touch the file or counters.
                if (att.clientPinId in deletingIds || att.growthRecordId in deletingIds) {
                    pending.remove(att.id)
                    continue
                }
                if (shouldWaitForParent(att, queuedPinIds, queuedGrowthIds)) continue
                if (!pending.isCurrent(att.id, att.revision)) continue

                val file = File(att.localPath)
                if (!file.exists()) {
                    pending.updateStatus(att.id, PendingPhotoStatus.BLOCKED, "The saved photo is no longer on this device.")
                    continue
                }
                val bytes = runCatching { file.readBytes() }.getOrNull()
                if (bytes == null || bytes.isEmpty()) {
                    pending.updateStatus(att.id, PendingPhotoStatus.BLOCKED, "The saved photo couldn't be read.")
                    continue
                }

                pending.updateStatus(att.id, PendingPhotoStatus.IN_PROGRESS)
                try {
                    val path = att.uploadedPath ?: when (att.entityKind) {
                        PendingPhotoEntityKind.GROWTH -> pinPhotoRepo.uploadAtPath(
                            pinPhotoRepo.growthStoragePath(att.vineyardId, requireNotNull(att.growthRecordId), att.revision),
                            bytes,
                        )
                        else -> pinPhotoRepo.upload(att.vineyardId, att.clientPinId, bytes, att.revision)
                    }
                    if (!pending.recordUploadedPath(att.id, att.revision, path)) continue
                    try {
                        if (!pending.isCurrent(att.id, att.revision)) continue
                        val growthPaths = replacingOwnedPhoto(att.previousPhotoPaths, path)
                        val confirmation = when (att.entityKind) {
                            PendingPhotoEntityKind.GROWTH -> {
                                val updated = growthRepo.updatePhotoPaths(requireNotNull(att.growthRecordId), growthPaths)
                                PhotoUploadConfirmation(
                                    attachment = att,
                                    path = path,
                                    growthRecord = updated,
                                    remoteIdentity = growthRemoteIdentity(updated, path),
                                )
                            }
                            PendingPhotoEntityKind.LINKED_GROWTH -> {
                                val updatedPin = pinRepo.updatePhotoPath(att.clientPinId, path)
                                val updatedGrowth = att.growthRecordId?.let {
                                    if (!pending.isCurrent(att.id, att.revision)) return@let null
                                    growthRepo.updatePhotoPaths(it, growthPaths)
                                }
                                PhotoUploadConfirmation(
                                    attachment = att,
                                    path = path,
                                    pin = updatedPin,
                                    growthRecord = updatedGrowth,
                                    remoteIdentity = updatedGrowth?.let { growthRemoteIdentity(it, path) }
                                        ?: pinRemoteIdentity(updatedPin, path),
                                )
                            }
                            else -> {
                                val updatedPin = pinRepo.updatePhotoPath(att.clientPinId, path)
                                PhotoUploadConfirmation(
                                    attachment = att,
                                    path = path,
                                    pin = updatedPin,
                                    remoteIdentity = pinRemoteIdentity(updatedPin, path),
                                )
                            }
                        }
                        if (!pending.isCurrent(att.id, att.revision)) continue
                        pending.promoteToDisplayCache(att, path, confirmation.remoteIdentity)
                        onUploaded(confirmation)
                        if (pending.isCurrent(att.id, att.revision)) {
                            pending.markUploaded(att.id)
                            pending.remove(att.id)
                        }
                    } catch (e: BackendError.Unauthorized) {
                        // Upload succeeded but the row update needs re-auth. Keep
                        // the file so a later retry re-runs updatePhotoPath.
                        retryOrBlock(att, "Sign-in needed to finish saving the photo.")
                    } catch (e: BackendError.Server) {
                        when {
                            e.code in 500..599 -> retryOrBlock(att, "Server error (${e.code}).")
                            e.code == 401 || e.code == 403 ->
                                pending.updateStatus(att.id, PendingPhotoStatus.BLOCKED, "Not allowed to attach this photo (${e.code}).")
                            // Pin row may not exist yet, or another rejection —
                            // keep the file and retry rather than discarding it.
                            else -> retryOrBlock(att, "Couldn't attach the photo (${e.code}).")
                        }
                    } catch (e: Exception) {
                        retryOrBlock(att, e.message ?: "No connection.")
                    }
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(att, "Sign-in needed to upload the photo.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(att, "Server error (${e.code}).")
                        e.code == 401 || e.code == 403 ->
                            pending.updateStatus(att.id, PendingPhotoStatus.BLOCKED, "Not allowed to upload this photo (${e.code}).")
                        else -> pending.updateStatus(att.id, PendingPhotoStatus.BLOCKED, "The photo was rejected (${e.code}).")
                    }
                } catch (e: Exception) {
                    // Still offline / transient network failure — leave for next time.
                    retryOrBlock(att, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(att: PendingPhotoAttachment, error: String) {
        pending.incrementAttempt(att.id)
        val attempts = att.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingPhotoStatus.BLOCKED else PendingPhotoStatus.FAILED
        pending.updateStatus(att.id, status, error)
    }

    companion object {
        /** Cap retries so a persistently-failing photo can't loop indefinitely. */
        private const val MAX_ATTEMPTS = 8

        internal fun shouldWaitForParent(
            attachment: PendingPhotoAttachment,
            queuedPinIds: Set<String>,
            queuedGrowthIds: Set<String>,
        ): Boolean =
            (attachment.entityKind != PendingPhotoEntityKind.GROWTH && attachment.clientPinId in queuedPinIds) ||
                (attachment.growthRecordId != null && attachment.growthRecordId in queuedGrowthIds)

        internal fun replacingOwnedPhoto(previous: List<String>, newPath: String): List<String> =
            listOf(newPath) + previous.drop(1).filterNot { it == newPath }

        internal fun pinRemoteIdentity(pin: com.rork.vinetrack.data.model.Pin, path: String): String =
            listOf(path, pin.clientUpdatedAt, pin.updatedAt, pin.syncVersion?.toString()).joinToString("|") { it.orEmpty() }

        internal fun growthRemoteIdentity(record: com.rork.vinetrack.data.model.GrowthStageRecord, path: String): String =
            listOf(path, record.clientUpdatedAt, record.updatedAt, record.syncVersion?.toString()).joinToString("|") { it.orEmpty() }
    }
}
