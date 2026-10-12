package com.rork.vinetrack.data.auth

import android.content.Context
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Durable acquisition receipt. A returned photo is not complete until the field writer acknowledges it. */
class PhotoCaptureReceipt private constructor(
    private val context: Context,
    private val session: SessionStore,
    private val operation: AuthRetentionGuard.FieldOperation,
    val path: String,
) {
    val id: String get() = operation.id
    private val prefs get() = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun admitted(action: () -> Unit): Boolean = session.withFieldOperation(operation, action)

    /** Persist the external dependency before copying; missing permission/bytes remain uncertain evidence. */
    fun recordExternalSource(uri: String): Boolean {
        var durable = false
        return runCatching {
            admitted {
                val raw = prefs.getString(id, null) ?: return@admitted
                val original = codec.decodeFromString<Acquisition>(raw)
                check(original.account == operation.account.userId && original.path == path)
                durable = prefs.edit().putString(id, codec.encodeToString(original.copy(externalUri = uri))).commit()
            } && durable
        }.getOrDefault(false)
    }

    /** Call only after the destination metadata and bytes have been durably saved. */
    fun persisted(): Boolean = finish(completed = true)

    /** An explicit user cancellation is allowed only for the original, still-current acquisition. */
    fun cancelIfEmpty(): Boolean = if (File(path).length() == 0L) finish(completed = false) else false

    private fun finish(completed: Boolean): Boolean {
        var durable = false
        val admitted = runCatching {
            admitted {
                val raw = prefs.getString(id, null) ?: return@admitted
                val original = codec.decodeFromString<Acquisition>(raw)
                check(original.account == operation.account.userId && original.path == path)
                durable = prefs.edit().apply {
                    if (completed) putString(id, codec.encodeToString(original.copy(completed = true))) else remove(id)
                }.commit()
            }
        }.getOrDefault(false)
        if (admitted && durable) operation.complete()
        // Leave source bytes intact: failed destination persistence or receipt cleanup must remain recoverable.
        return admitted && durable
    }

    companion object {
        const val PREFERENCES = "vinetrack_photo_acquisitions"
        const val DIRECTORY = "photo-acquisitions"
        private val codec = Json { encodeDefaults = true }
        @Serializable private data class Acquisition(val account: String, val path: String, val kind: String, val completed: Boolean = false, val externalUri: String? = null)

        fun begin(context: Context, kind: String): PhotoCaptureReceipt? {
            val app = context.applicationContext
            val session = SessionStore(app)
            val operation = session.fieldOperation() ?: return null
            val file = File(app.filesDir, "$DIRECTORY/capture-${operation.id}.jpg")
            var durable = false
            try {
                val admitted = session.withFieldOperation(operation) {
                    check(file.parentFile?.mkdirs() == true || file.parentFile?.isDirectory == true)
                    durable = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
                        .putString(operation.id, codec.encodeToString(Acquisition(operation.account.userId, file.absolutePath, kind))).commit()
                }
                if (admitted && durable) return PhotoCaptureReceipt(app, session, operation, file.absolutePath)
            } finally {
                if (!durable) operation.complete()
            }
            return null
        }

        /** Same-process Activity recreation only; process-restored uncertain evidence remains isolated. */
        fun restore(context: Context, id: String): PhotoCaptureReceipt? {
            val app = context.applicationContext
            val session = SessionStore(app)
            val operation = session.retentionGuard.operation(id) ?: return null
            var receipt: PhotoCaptureReceipt? = null
            session.withFieldOperation(operation) {
                val raw = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(id, null) ?: return@withFieldOperation
                val acquisition = runCatching { codec.decodeFromString<Acquisition>(raw) }.getOrNull() ?: return@withFieldOperation
                val expected = File(app.filesDir, "$DIRECTORY/capture-$id.jpg").absolutePath
                if (acquisition.account == operation.account.userId && acquisition.path == expected) {
                    receipt = PhotoCaptureReceipt(app, session, operation, expected)
                }
            }
            return receipt
        }
    }
}
