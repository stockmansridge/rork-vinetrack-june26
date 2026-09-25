package com.rork.vinetrack.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/** Same app-private-file + committed-metadata pattern as PendingPhotoRepository, scoped to chemical labels. */
internal class ChemicalLabelPhotoRepository(
    private val root: File,
    private val store: ChemicalLabelPhotoStoring,
) {
    constructor(context: Context) : this(context.applicationContext.filesDir, ChemicalLabelPhotoStore(context))

    private val directory: File get() = File(root, "pending_chemical_label_photos")
    private var rows = store.load().map {
        if (it.status == ChemicalLabelAttachment.IN_PROGRESS) it.copy(status = ChemicalLabelAttachment.FAILED) else it
    }.also { if (it != store.load()) store.save(it) }

    private val _attachments = MutableStateFlow(rows)
    val attachments = _attachments.asStateFlow()

    @Synchronized fun list(): List<ChemicalLabelAttachment> = rows

    @Synchronized fun enqueue(ownerId: String, vineyardId: String, chemicalId: String, jpeg: ByteArray): ChemicalLabelAttachment {
        require(jpeg.isNotEmpty() && jpeg.size <= 10_485_760) { "Label JPEG must be nonempty and under 10 MB." }
        check(directory.exists() || directory.mkdirs()) { "Couldn't create label photo storage." }
        val id = UUID.randomUUID().toString()
        val file = File(directory, "$id.jpg")
        try {
            FileOutputStream(file).use { output -> output.write(jpeg); output.fd.sync() }
            val attachment = ChemicalLabelAttachment(
                id = id, ownerId = ownerId, chemicalId = chemicalId, vineyardId = vineyardId,
                localPath = file.absolutePath,
                remotePath = "${vineyardId.lowercase()}/${chemicalId.lowercase()}/$id.jpg",
                createdAt = System.currentTimeMillis(),
            )
            val replaced = rows.filter { it.ownerId == ownerId && it.chemicalId == chemicalId }
            store.save(rows - replaced.toSet() + attachment)
            rows = rows - replaced.toSet() + attachment
            _attachments.value = rows
            replaced.forEach { File(it.localPath).delete() }
            return attachment
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }

    @Synchronized fun update(id: String, transform: (ChemicalLabelAttachment) -> ChemicalLabelAttachment) {
        val next = rows.map { if (it.id == id) transform(it) else it }
        store.save(next)
        rows = next
        _attachments.value = rows
    }

    /** Metadata removal precedes file deletion; a failed commit leaves the JPEG retryable. */
    @Synchronized fun remove(id: String) {
        val file = rows.firstOrNull { it.id == id }?.localPath ?: return
        val next = rows.filterNot { it.id == id }
        store.save(next)
        rows = next
        _attachments.value = rows
        File(file).delete()
    }

    @Synchronized fun removeForChemical(id: String) {
        rows.filter { it.chemicalId == id }.forEach { remove(it.id) }
    }

    @Synchronized fun clearAll() {
        store.save(emptyList())
        rows = emptyList()
        _attachments.value = rows
        directory.listFiles()?.forEach { it.delete() }
    }
}
