package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PendingPhotoEntityKind
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

    /** Latest readable retained file for a source identity, if one exists. */
    fun latestFile(entityId: String): File? = latestAttachment(entityId)
        ?.let { File(it.localPath) }
        ?.takeIf { it.exists() && it.length() > 0L }

    fun latestAttachment(entityId: String): PendingPhotoAttachment? = _attachments.value
        .filter {
            (it.clientPinId == entityId || it.growthRecordId == entityId) &&
                it.status in PendingPhotoStatus.unresolved && File(it.localPath).exists()
        }
        .maxByOrNull { it.createdAt }

    fun isCurrent(id: String, revision: String): Boolean = _attachments.value.any {
        it.id == id && it.revision == revision && it.status in PendingPhotoStatus.unresolved
    }

    private fun fileFor(entityId: String, revision: String): File =
        File(photoDir, "${entityId.lowercase()}-${revision.lowercase()}.jpg")

    /**
     * Persist compressed JPEG [jpeg] for [clientPinId] and record a pending
     * attachment. If an attachment for the same pin already exists, its file is
     * overwritten and the row reset to pending (one photo per pin, mirroring the
     * single `pins.photo_path` column). Returns the stored attachment.
     *
     * Does NOT upload — Stage 7B retains the photo only.
     */
    fun enqueue(clientPinId: String, vineyardId: String, jpeg: ByteArray): PendingPhotoAttachment =
        enqueue(
            target = PinPresentationTarget(vineyardId, clientPinId, null, PinPresentationTarget.Kind.PIN),
            jpeg = jpeg,
        )

    /** Atomically retain the newest capture for its actual pin/growth identity. */
    @Synchronized
    fun enqueue(
        target: PinPresentationTarget,
        jpeg: ByteArray,
        previousPhotoPaths: List<String> = emptyList(),
    ): PendingPhotoAttachment {
        require(jpeg.isNotEmpty()) { "Photo data is empty." }
        val entityId = target.pinId ?: requireNotNull(target.growthRecordId)
        val revision = UUID.randomUUID().toString()
        val file = fileFor(entityId, revision)
        file.writeBytes(jpeg)
        val now = System.currentTimeMillis()
        val kind = when (target.kind) {
            PinPresentationTarget.Kind.PIN -> PendingPhotoEntityKind.PIN
            PinPresentationTarget.Kind.LINKED_GROWTH -> PendingPhotoEntityKind.LINKED_GROWTH
            PinPresentationTarget.Kind.STANDALONE_GROWTH -> PendingPhotoEntityKind.GROWTH
        }
        val attachment = PendingPhotoAttachment(
            id = UUID.randomUUID().toString(),
            clientPinId = target.pinId ?: entityId,
            entityKind = kind,
            growthRecordId = target.growthRecordId,
            revision = revision,
            vineyardId = target.vineyardId,
            localPath = file.absolutePath,
            createdAt = now,
            previousPhotoPaths = previousPhotoPaths,
            updatedAt = now,
        )
        val replaced = _attachments.value.filter {
            it.clientPinId == attachment.clientPinId && it.growthRecordId == attachment.growthRecordId
        }
        update { list -> list - replaced.toSet() + attachment }
        replaced.forEach { runCatching { File(it.localPath).delete() } }
        return attachment
    }

    fun recordUploadedPath(id: String, revision: String, path: String): Boolean {
        if (!isCurrent(id, revision)) return false
        val now = System.currentTimeMillis()
        update { list ->
            list.map { if (it.id == id && it.revision == revision) it.copy(uploadedPath = path, updatedAt = now) else it }
        }
        return isCurrent(id, revision)
    }

    fun removeForTarget(pinId: String?, growthRecordId: String?) {
        list().filter {
            (pinId != null && it.clientPinId == pinId) ||
                (growthRecordId != null && it.growthRecordId == growthRecordId)
        }.forEach { remove(it.id) }
    }

    /** Copy the successful revision into durable display storage before queue cleanup. */
    fun promoteToDisplayCache(attachment: PendingPhotoAttachment): File? {
        val source = File(attachment.localPath)
        if (!source.exists()) return null
        val directory = File(appContext.filesDir, DISPLAY_DIR).apply { mkdirs() }
        val entityId = attachment.growthRecordId ?: attachment.clientPinId
        directory.listFiles()?.filter { it.name.startsWith("${entityId.lowercase()}__") }?.forEach { it.delete() }
        val destination = File(directory, "${entityId.lowercase()}__${attachment.revision.lowercase()}.jpg")
        return runCatching { source.copyTo(destination, overwrite = true) }.getOrNull()
    }

    fun retainedDisplayFile(entityId: String): File? {
        latestFile(entityId)?.let { return it }
        val directory = File(appContext.filesDir, DISPLAY_DIR)
        return directory.listFiles()
            ?.filter { it.name.startsWith("${entityId.lowercase()}__") && it.length() > 0L }
            ?.maxByOrNull { it.lastModified() }
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

    @Synchronized
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
        const val DISPLAY_DIR = "pin_photo_display_cache"
    }
}
