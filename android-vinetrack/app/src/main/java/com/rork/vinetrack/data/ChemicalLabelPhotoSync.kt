package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLabelAttachmentV2Repository
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import java.io.File

/** Replays durable label photos only after their exact Saved Chemical UUID exists server-side. */
internal class ChemicalLabelPhotoSync(
    private val photos: ChemicalLabelPhotoRepository,
    private val writes: PendingWriteRepository,
    private val repository: SavedChemicalRepository,
    private val ownerId: () -> String?,
    private val findParent: suspend (String) -> com.rork.vinetrack.data.model.SavedChemical? = repository::findById,
    private val upload: suspend (ChemicalLabelAttachment, ByteArray) -> Unit = { attachment, bytes ->
        ChemicalLabelAttachmentV2Repository().upload(
            bytes, attachment.vineyardId, attachment.chemicalId, attachment.id, attachment.remotePath,
        )
    },
) {
    private val lock = Mutex()

    suspend fun replayAll() {
        if (!lock.tryLock()) return
        try {
            val owner = ownerId() ?: return
            for (attachment in photos.list().filter { it.ownerId == owner && it.status in setOf(
                ChemicalLabelAttachment.PENDING, ChemicalLabelAttachment.FAILED,
            ) }) {
                // A queued/blocked CREATE remains authoritative; do not upload an orphan.
                if (writes.list().any { it.entityType == PendingEntityType.SAVED_CHEMICAL &&
                        it.opType == PendingOpType.CREATE && it.clientId == attachment.chemicalId }) continue
                try {
                    val parent = findParent(attachment.chemicalId)
                    if (parent == null) continue // creation may be acknowledged but not yet visible
                    if (parent.id != attachment.chemicalId || parent.vineyardId != attachment.vineyardId || parent.deletedAt != null) {
                        photos.update(attachment.id) { it.copy(status = ChemicalLabelAttachment.BLOCKED, lastError = "Chemical identity mismatch.") }
                        continue
                    }
                    val file = File(attachment.localPath)
                    if (!file.isFile || !file.canRead() || file.length() == 0L) {
                        photos.update(attachment.id) { it.copy(status = ChemicalLabelAttachment.BLOCKED, lastError = "Saved label photo is missing.") }
                        continue
                    }
                    photos.update(attachment.id) { it.copy(status = ChemicalLabelAttachment.IN_PROGRESS) }
                    upload(attachment, file.readBytes())
                    // Remote attachment is reconciled before the local marker/file is removed.
                    photos.remove(attachment.id)
                } catch (cancelled: CancellationException) {
                    photos.update(attachment.id) { it.copy(status = ChemicalLabelAttachment.FAILED, lastError = "Upload interrupted.") }
                    throw cancelled
                } catch (_: BackendError.Unauthorized) {
                    fail(attachment, "Sign in to upload the label photo.")
                } catch (error: BackendError.Server) {
                    if (error.code == 401 || error.code == 403 || error.code in 400..499 && error.code != 409) {
                        photos.update(attachment.id) { it.copy(status = ChemicalLabelAttachment.BLOCKED, lastError = "Label photo rejected (${error.code}).") }
                    } else fail(attachment, "Label upload failed (${error.code}).")
                } catch (_: Exception) {
                    fail(attachment, "Label photo upload will retry when connected.")
                }
            }
        } finally {
            lock.unlock()
        }
    }

    private fun fail(attachment: ChemicalLabelAttachment, message: String) {
        photos.update(attachment.id) {
            val count = it.attempts + 1
            it.copy(attempts = count, status = if (count >= 8) ChemicalLabelAttachment.BLOCKED else ChemicalLabelAttachment.FAILED, lastError = message)
        }
    }
}
