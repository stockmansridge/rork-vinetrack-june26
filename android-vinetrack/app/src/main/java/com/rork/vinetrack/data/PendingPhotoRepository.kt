package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PendingPhotoStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.UUID

/**
 * Sole access point for locally-retained pin photo attachments (Stage 7B —
 * local persistence only).
 *
 * Wraps [PendingPhotoStore] for metadata and owns the app-private file storage
 * for the compressed JPEG bytes. Screens and other repositories must use this
 * rather than touching the store or files directly. It is intentionally
 * separate from [PendingWriteRepository]: the pin-create outbox replays an
 * insert, whereas this retains a binary that a later slice (Stage 7C) will
 * upload once the pin exists server-side.
 *
 * IMPORTANT (this slice): nothing uploads or retries here. [enqueue] copies the
 * photo to disk and records the attachment; the status helpers exist for the
 * future upload loop. The compressed bytes live under
 * `filesDir/pending_pin_photos/{clientPinId}.jpg` — never the original content
 * Uri, which can expire across app restarts.
 */
class PendingPhotoRepository(context: Context) {

    private val appContext = context.applicationContext
    private val store = PendingPhotoStore(appContext)

    private val photoDir: File
        get() = File(appContext.filesDir, PHOTO_DIR).apply { if (!exists()) mkdirs() }

    private val _attachments = MutableStateFlow(store.load())
    /** Live view of every persisted pending photo attachment. */
    val attachments: StateFlow<List<PendingPhotoAttachment>> = _attachments.asStateFlow()

    private val _pendingCount = MutableStateFlow(countUnresolved(_attachments.value))
    /**
     * Observable count of attachments still waiting to upload (pending /
     * in-progress / failed / blocked). Uploaded rows are excluded.
     */
    val pendingCount: StateFlow<Int> = _pendingCount.asStateFlow()

    /** Current pending count without collecting the flow. */
    fun currentPendingCount(): Int = countUnresolved(_attachments.value)

    /** Snapshot of all attachments. */
    fun list(): List<PendingPhotoAttachment> = _attachments.value

    /** Local file the photo for [clientPinId] is (or would be) stored at. */
    fun fileFor(clientPinId: String): File = File(photoDir, "${clientPinId.lowercase()}.jpg")

    /**
     * Persist compressed JPEG [jpeg] for [clientPinId] and record a pending
     * attachment. If an attachment for the same pin already exists, its file is
     * overwritten and the row reset to pending (one photo per pin, mirroring the
     * single `pins.photo_path` column). Returns the stored attachment.
     *
     * Does NOT upload — Stage 7B retains the photo only.
     */
    fun enqueue(clientPinId: String, vineyardId: String, jpeg: ByteArray): PendingPhotoAttachment {
        val file = fileFor(clientPinId)
        file.writeBytes(jpeg)
        val now = System.currentTimeMillis()
        val existing = _attachments.value.firstOrNull { it.clientPinId == clientPinId }
        val attachment = if (existing != null) {
            existing.copy(
                vineyardId = vineyardId,
                localPath = file.absolutePath,
                updatedAt = now,
                status = PendingPhotoStatus.PENDING,
                attemptCount = 0,
                lastError = null,
            )
        } else {
            PendingPhotoAttachment(
                id = UUID.randomUUID().toString(),
                clientPinId = clientPinId,
                vineyardId = vineyardId,
                localPath = file.absolutePath,
                createdAt = now,
                updatedAt = now,
            )
        }
        update { list -> list.filterNot { it.clientPinId == clientPinId } + attachment }
        return attachment
    }

    /** Update the status and optional error of an attachment by id. */
    fun updateStatus(id: String, status: String, lastError: String? = null) {
        val now = System.currentTimeMillis()
        update { list ->
            list.map {
                if (it.id == id) it.copy(status = status, lastError = lastError, updatedAt = now) else it
            }
        }
    }

    /** Increment the attempt counter for an attachment (future upload-retry use). */
    fun incrementAttempt(id: String) {
        val now = System.currentTimeMillis()
        update { list ->
            list.map {
                if (it.id == id) it.copy(attemptCount = it.attemptCount + 1, updatedAt = now) else it
            }
        }
    }

    /** Mark an attachment uploaded and delete its local file. */
    fun markUploaded(id: String) {
        deleteFileFor(id)
        updateStatus(id, PendingPhotoStatus.UPLOADED)
    }

    /** Remove an attachment entirely and delete its local file. */
    fun remove(id: String) {
        deleteFileFor(id)
        update { list -> list.filterNot { it.id == id } }
    }

    /** Drop all uploaded rows (their files are already deleted on markUploaded). */
    fun pruneUploaded() {
        update { list -> list.filterNot { it.status == PendingPhotoStatus.UPLOADED } }
    }

    /**
     * Clear all pending photo metadata and delete every app-private JPEG under
     * `filesDir/pending_pin_photos/` (Stage 8 — sign-out cleanup hygiene).
     * Local-only: no Storage deletes, no upload attempts. Leaves no orphaned
     * files behind.
     */
    fun clearAll() {
        runCatching {
            photoDir.listFiles()?.forEach { runCatching { it.delete() } }
        }
        store.clear()
        _attachments.value = emptyList()
        _pendingCount.value = 0
    }

    private fun deleteFileFor(id: String) {
        _attachments.value.firstOrNull { it.id == id }?.let { runCatching { File(it.localPath).delete() } }
    }

    private fun update(transform: (List<PendingPhotoAttachment>) -> List<PendingPhotoAttachment>) {
        val next = transform(_attachments.value)
        _attachments.value = next
        _pendingCount.value = countUnresolved(next)
        store.save(next)
    }

    private fun countUnresolved(list: List<PendingPhotoAttachment>): Int =
        list.count { it.status in PendingPhotoStatus.unresolved }

    private companion object {
        const val PHOTO_DIR = "pending_pin_photos"
    }
}
