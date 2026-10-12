package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.CompletedPhotoCacheEntry
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PhotoDisplaySource
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
class PendingPhotoRepository internal constructor(
    private val rootDir: File,
    private val store: PendingPhotoStoring,
    private val fileAccess: com.rork.vinetrack.data.auth.FieldStoreAccess? = null,
) {
    constructor(context: Context) : this(
        context.applicationContext.filesDir,
        PendingPhotoStore(context.applicationContext),
        com.rork.vinetrack.data.auth.FieldStoreAccess(context),
    )

    private val admission = fileAccess ?: (store as? PendingPhotoStore)?.fieldAccess
    private fun <T> admitted(action: () -> T): T = if (admission == null) action() else admission.admitted(action)

    private val photoDir: File
        get() = fileCommit { File(rootDir, PHOTO_DIR).apply { check(exists() || mkdirs()) } }

    private fun <T> fileCommit(action: () -> T): T = if (fileAccess == null) action() else fileAccess.commit(action)

    private fun writeJpeg(file: File, bytes: ByteArray) = fileCommit {
        java.io.FileOutputStream(file).use { it.write(bytes); it.fd.sync() }
    }

    private var scopeProvider: (() -> PendingWriteRepository.ReplayScope?)? = null
    private val claimedScopes = mutableMapOf<Pair<String, String>, PendingWriteRepository.ReplayScope>()

    @Synchronized
    fun configureReplayScope(provider: () -> PendingWriteRepository.ReplayScope?) { scopeProvider = provider }

    private val _attachments = MutableStateFlow(recoverPreviousProcessWork())
    private val captureClock = java.util.concurrent.atomic.AtomicLong(maxOf(System.currentTimeMillis(), _attachments.value.maxOfOrNull { it.createdAt } ?: 0L))
    private var completedCache: List<CompletedPhotoCacheEntry> = store.loadCompletedCache()
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

    /** Latest readable unresolved capture for a source identity, if one exists. */
    fun latestFile(entityId: String): File? = latestAttachment(entityId)
        ?.let { File(it.localPath) }
        ?.takeIf { it.exists() && it.canRead() && it.length() > 0L }

    fun latestAttachment(entityId: String): PendingPhotoAttachment? = _attachments.value
        .filter {
            (it.clientPinId == entityId || it.growthRecordId == entityId) &&
                it.status in PendingPhotoStatus.unresolved && File(it.localPath).exists()
        }
        .maxByOrNull { it.createdAt }

    @Synchronized
    fun isCurrent(id: String, revision: String): Boolean = _attachments.value.any {
        it.id == id && it.revision == revision && it.status in PendingPhotoStatus.unresolved
    } && (claimedScopes[id to revision]?.let { it == scopeProvider?.invoke() } ?: true)

    /** Observable-display token for rejecting callbacks from an older capture. */
    fun currentRevision(entityId: String): String? = latestAttachment(entityId)?.revision

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
    fun enqueue(target: PinPresentationTarget, jpeg: ByteArray, previousPhotoPaths: List<String> = emptyList()): PendingPhotoAttachment {
        val bytes = jpeg.copyOf()
        val paths = previousPhotoPaths.toList()
        val createdAt = captureClock.updateAndGet { maxOf(System.currentTimeMillis(), it + 1L) }
        val revision = UUID.randomUUID().toString()
        val id = UUID.randomUUID().toString()
        return admitted { enqueueLocked(target, bytes, paths, createdAt, revision, id) }
    }

    @Synchronized
    private fun enqueueLocked(
        target: PinPresentationTarget,
        jpeg: ByteArray,
        previousPhotoPaths: List<String>,
        now: Long,
        revision: String,
        id: String,
    ): PendingPhotoAttachment {
        require(jpeg.isNotEmpty() && jpeg.size <= 20_971_520) { "Photo data is empty." }
        val entityId = target.pinId ?: requireNotNull(target.growthRecordId)
        val file = fileFor(entityId, revision)
        val kind = when (target.kind) {
            PinPresentationTarget.Kind.PIN -> PendingPhotoEntityKind.PIN
            PinPresentationTarget.Kind.LINKED_GROWTH -> PendingPhotoEntityKind.LINKED_GROWTH
            PinPresentationTarget.Kind.STANDALONE_GROWTH -> PendingPhotoEntityKind.GROWTH
        }
        val attachment = PendingPhotoAttachment(
            id = id,
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
        val journal = if (admission != null) PendingPhotoCaptureJournal(photoDir) else null
        val intent = journal?.retain(admission?.ownerUserId, admission?.identityEpoch ?: 0L, attachment, jpeg)
        com.rork.vinetrack.data.auth.CleanExitDiagnostics.checkpoint("field.photo.intent.durable")
        check(_attachments.value.none { it.clientPinId == attachment.clientPinId && it.growthRecordId == attachment.growthRecordId && it.createdAt > attachment.createdAt }) {
            "A newer capture is already retained. This older photo intent remains protected for review."
        }
        // If any later disk step fails, this envelope remains authoritative recovery evidence.
        if (journal == null) writeJpeg(file, jpeg) else journal.writeJpeg(file, jpeg)
        val replaced = _attachments.value.filter {
            it.clientPinId == attachment.clientPinId && it.growthRecordId == attachment.growthRecordId
        }
        update { list -> list - replaced.toSet() + attachment }
        if (intent != null) requireNotNull(journal).finish(intent)
        replaced.forEach { runCatching { fileCommit { File(it.localPath).delete() } } }
        return attachment
    }

    fun recordUploadedPath(id: String, revision: String, path: String): Boolean = admitted { recordUploadedPathLocked(id, revision, path) }

    @Synchronized
    private fun recordUploadedPathLocked(id: String, revision: String, path: String): Boolean {
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
    fun promoteToDisplayCache(attachment: PendingPhotoAttachment, remotePath: String, remoteIdentity: String): File =
        admitted { promoteToDisplayCacheLocked(attachment, remotePath, remoteIdentity) }

    @Synchronized
    private fun promoteToDisplayCacheLocked(
        attachment: PendingPhotoAttachment,
        remotePath: String,
        remoteIdentity: String,
    ): File {
        val source = File(attachment.localPath)
        check(source.exists() && source.canRead() && source.length() > 0L) {
            "The retained photo couldn't be preserved for offline display."
        }
        val directory = fileCommit { File(rootDir, DISPLAY_DIR).apply {
            check(exists() || mkdirs()) { "Couldn't create offline photo storage." }
        } }
        val entityId = attachment.growthRecordId ?: attachment.clientPinId
        val destination = File(directory, "${entityId.lowercase()}__${attachment.revision.lowercase()}.jpg")
        fileCommit {
            source.inputStream().use { input ->
                java.io.FileOutputStream(destination).use { output -> input.copyTo(output); output.fd.sync() }
            }
        }
        val next = completedCache.filterNot { it.entityId == entityId } + CompletedPhotoCacheEntry(
            entityId = entityId,
            localPath = destination.absolutePath,
            remotePath = remotePath,
            remoteIdentity = remoteIdentity,
            cachedAt = System.currentTimeMillis(),
        )
        store.saveCompletedCache(next)
        completedCache.filter { it.entityId == entityId && it.localPath != destination.absolutePath }
            .forEach { runCatching { fileCommit { File(it.localPath).delete() } } }
        completedCache = next
        return destination
    }

    fun cacheRemoteDisplay(entityId: String, remotePath: String, remoteIdentity: String, bytes: ByteArray): File =
        admitted { cacheRemoteDisplayLocked(entityId, remotePath, remoteIdentity, bytes) }

    @Synchronized
    private fun cacheRemoteDisplayLocked(entityId: String, remotePath: String, remoteIdentity: String, bytes: ByteArray): File {
        require(bytes.isNotEmpty()) { "Downloaded photo was empty." }
        check(latestAttachment(entityId) == null) { "A newer local capture is pending." }
        val directory = fileCommit { File(rootDir, DISPLAY_DIR).apply {
            check(exists() || mkdirs()) { "Couldn't create offline photo storage." }
        } }
        val destination = File(directory, "${entityId.lowercase()}__remote-${remoteIdentity.hashCode()}.jpg")
        writeJpeg(destination, bytes)
        val next = completedCache.filterNot { it.entityId == entityId } + CompletedPhotoCacheEntry(
            entityId = entityId,
            localPath = destination.absolutePath,
            remotePath = remotePath,
            remoteIdentity = remoteIdentity,
            cachedAt = System.currentTimeMillis(),
        )
        store.saveCompletedCache(next)
        completedCache.filter { it.entityId == entityId && it.localPath != destination.absolutePath }
            .forEach { runCatching { fileCommit { File(it.localPath).delete() } } }
        completedCache = next
        return destination
    }

    /** Resolve local display independently from signed-URL availability. */
    fun displaySource(entityId: String, remotePath: String?, remoteIdentity: String?): PhotoDisplaySource {
        latestAttachment(entityId)?.let { pending ->
            val file = File(pending.localPath)
            if (file.exists() && file.canRead() && file.length() > 0L) {
                return PhotoDisplaySource(
                    localPath = file.absolutePath,
                    isPending = true,
                    isStaleCompletedCache = false,
                    localRevision = pending.revision,
                )
            }
            return PhotoDisplaySource(
                localPath = null,
                isPending = true,
                isStaleCompletedCache = false,
                localRevision = pending.revision,
                error = pending.lastError ?: "Saved photo is unavailable. Tap retry after checking device storage.",
            )
        }
        val entry = completedCache.firstOrNull { it.entityId == entityId }
        val file = entry?.let { File(it.localPath) }?.takeIf { it.exists() && it.canRead() && it.length() > 0L }
        val isCurrent = entry != null && remotePath == entry.remotePath && remoteIdentity == entry.remoteIdentity
        return PhotoDisplaySource(
            localPath = file?.absolutePath,
            isPending = false,
            isStaleCompletedCache = file != null && !isCurrent,
            localRevision = null,
        )
    }

    @Deprecated("Use displaySource with authoritative attachment identity")
    fun retainedDisplayFile(entityId: String): File? =
        displaySource(entityId, remotePath = null, remoteIdentity = null).localPath?.let(::File)

    /** Durable revision-conditional outcome, sharing the enqueue/persistence monitor. */
    fun updateStatusIfCurrent(attachment: PendingPhotoAttachment, status: String, error: String? = null): Boolean =
        admitted { updateStatusIfCurrentLocked(attachment, status, error) }

    @Synchronized
    private fun updateStatusIfCurrentLocked(attachment: PendingPhotoAttachment, status: String, error: String? = null): Boolean {
        if (!isCurrent(attachment.id, attachment.revision)) return false
        val scope = scopeProvider?.invoke()
        if (scopeProvider != null && scope == null) return false
        update { rows -> rows.map { if (it.id == attachment.id && it.revision == attachment.revision)
            it.copy(status = status, lastError = error, updatedAt = System.currentTimeMillis()) else it } }
        if (status == PendingPhotoStatus.IN_PROGRESS && scope != null) claimedScopes[attachment.id to attachment.revision] = scope
        return true
    }

    fun retryIfCurrent(attachment: PendingPhotoAttachment, error: String, maxAttempts: Int): Boolean =
        admitted { retryIfCurrentLocked(attachment, error, maxAttempts) }

    @Synchronized
    private fun retryIfCurrentLocked(attachment: PendingPhotoAttachment, error: String, maxAttempts: Int): Boolean {
        if (!isCurrent(attachment.id, attachment.revision)) return false
        update { rows -> rows.map { if (it.id == attachment.id && it.revision == attachment.revision) {
            val attempts = it.attemptCount + 1
            it.copy(attemptCount = attempts, lastError = error, updatedAt = System.currentTimeMillis(),
                status = if (attempts >= maxAttempts) PendingPhotoStatus.BLOCKED else PendingPhotoStatus.FAILED)
        } else it } }
        return true
    }

    /** Commit metadata before deleting only this revision's retained bytes. */
    fun removeIfCurrent(id: String, revision: String): Boolean = admitted { removeIfCurrentLocked(id, revision) }

    @Synchronized
    private fun removeIfCurrentLocked(id: String, revision: String): Boolean {
        val attachment = _attachments.value.firstOrNull { it.id == id && it.revision == revision } ?: return false
        if (claimedScopes[id to revision]?.let { it != scopeProvider?.invoke() } == true) return false
        update { rows -> rows.filterNot { it.id == id && it.revision == revision } }
        runCatching { fileCommit { File(attachment.localPath).delete() } }
        return true
    }

    /** Promotion and acknowledgement cannot race a replacement capture. */
    fun completeIfCurrent(attachment: PendingPhotoAttachment, path: String, remoteIdentity: String): Boolean =
        admitted { completeIfCurrentLocked(attachment, path, remoteIdentity) }

    @Synchronized
    private fun completeIfCurrentLocked(attachment: PendingPhotoAttachment, path: String, remoteIdentity: String): Boolean {
        if (!isCurrent(attachment.id, attachment.revision)) return false
        promoteToDisplayCache(attachment, path, remoteIdentity)
        return removeIfCurrent(attachment.id, attachment.revision)
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
        updateStatus(id, PendingPhotoStatus.UPLOADED)
        deleteFileFor(id)
    }

    /** Remove an attachment entirely and delete its local file. */
    fun remove(id: String): Unit = admitted { removeLocked(id) }

    @Synchronized
    private fun removeLocked(id: String) {
        val attachment = _attachments.value.firstOrNull { it.id == id }
        update { list -> list.filterNot { it.id == id } }
        attachment?.let { runCatching { fileCommit { File(it.localPath).delete() } } }
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
    fun clearAll(): Unit = admitted { clearAllLocked() }

    @Synchronized
    private fun clearAllLocked() {
        store.clear()
        runCatching {
            fileCommit { photoDir.listFiles()?.forEach { runCatching { it.delete() } } }
        }
        completedCache.forEach { runCatching { fileCommit { File(it.localPath).delete() } } }
        completedCache = emptyList()
        _attachments.value = emptyList()
        _pendingCount.value = 0
    }

    private fun deleteFileFor(id: String) {
        _attachments.value.firstOrNull { it.id == id }?.let { runCatching { fileCommit { File(it.localPath).delete() } } }
    }

    private fun update(transform: (List<PendingPhotoAttachment>) -> List<PendingPhotoAttachment>): Unit = admitted { updateLocked(transform) }

    @Synchronized
    private fun updateLocked(transform: (List<PendingPhotoAttachment>) -> List<PendingPhotoAttachment>) {
        val next = transform(_attachments.value)
        store.save(next)
        _attachments.value = next
        claimedScopes.keys.retainAll(next.map { it.id to it.revision }.toSet())
        _pendingCount.value = countUnresolved(next)
    }

    /** Constructor-only recovery: no current-process replay can be active yet. */
    private fun recoverPreviousProcessWork(): List<PendingPhotoAttachment> {
        val directory = File(rootDir, PHOTO_DIR)
        val loaded = if (admission != null && directory.exists()) admitted {
            val journal = PendingPhotoCaptureJournal(directory)
            var rows = store.load()
            journal.pending().forEach { (file, capture) ->
                check(capture.ownerUserId != null) { "A retained photo intent needs ownership review." }
                admission.commitForOwner(capture.ownerUserId) {
                    check(capture.identityEpoch == admission.identityEpoch) { "A photo intent from an earlier account session remains protected and needs recovery review." }
                    val attachment = capture.attachment
                    val current = rows.filter { it.clientPinId == attachment.clientPinId && it.growthRecordId == attachment.growthRecordId }
                    if (current.none { it.revision == attachment.revision || it.createdAt >= attachment.createdAt }) {
                        journal.writeJpeg(File(attachment.localPath), capture.jpeg)
                        val next = rows - current.toSet() + attachment
                        store.save(next)
                        rows = next
                        current.forEach { previous -> runCatching { File(previous.localPath).delete() } }
                    } else if (current.any { it.revision == attachment.revision }) {
                        // Metadata may have committed immediately before interruption. Repair only its bytes.
                        journal.writeJpeg(File(attachment.localPath), capture.jpeg)
                        // SharedPreferences may have updated memory even when its disk commit failed.
                        // Recommit metadata before removing the only durable transaction envelope.
                        store.save(rows)
                    } else {
                        // A later capture won. Never republish or overwrite it with interrupted older intent.
                        runCatching { File(attachment.localPath).delete() }
                    }
                    journal.finish(file)
                }
            }
            rows
        } else store.load()
        val now = System.currentTimeMillis()
        val recovered = loaded.map { attachment ->
            if (attachment.status == PendingPhotoStatus.IN_PROGRESS) {
                attachment.copy(
                    status = PendingPhotoStatus.FAILED,
                    lastError = "Photo upload was interrupted. Tap retry or reconnect to continue.",
                    updatedAt = now,
                )
            } else attachment
        }
        if (recovered != loaded) admitted { store.save(recovered) }
        return recovered
    }

    private fun countUnresolved(list: List<PendingPhotoAttachment>): Int =
        list.count { it.status in PendingPhotoStatus.unresolved }

    private companion object {
        const val PHOTO_DIR = "pending_pin_photos"
        const val DISPLAY_DIR = "pin_photo_display_cache"
    }
}
