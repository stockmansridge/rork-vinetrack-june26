package com.rork.vinetrack.data.insights

import android.content.Context
import android.util.Log
import java.io.File

/**
 * App-private file storage for Scout photographs.
 *
 * ## Why the bytes go to disk before anything else happens
 *
 * A scouting photograph is evidence of a condition that existed at one moment
 * in one block. It cannot be retaken later — the powdery mildew either looked
 * like that on the day or it did not. So the bytes are written to app-private
 * storage FIRST, and only then is an upload queued. An implementation that
 * uploads from memory loses the photograph whenever the process is killed in a
 * paddock with no signal, which is precisely where scouting happens.
 *
 * ## Layout mirrors the server path convention
 *
 * `filesDir/scout_photos/{vineyardId}/{observationId}/{photoId}.jpg`
 *
 * The same shape as the `scout-photos` bucket path in SQL 236
 * (`{vineyard_id}/{observation_id}/{uuid}.jpg`), so the local file and the
 * remote object are trivially reconcilable and every file is already scoped by
 * vineyard for the sign-out wipe.
 *
 * ## One file per photo id, never a shared name
 *
 * The filename is the photograph's own client-generated id, so two photographs
 * of the same item cannot overwrite one another — the defect a "current photo"
 * filename would reintroduce.
 *
 * Paths are stored RELATIVE. An absolute path captured under one app install
 * can be invalid after an upgrade or restore, which would silently orphan the
 * bytes.
 */
class ScoutPhotoFileStore(context: Context) : ScoutPhotoFiles {

    private val root: File = File(context.applicationContext.filesDir, DIR_NAME)

    override fun relativePath(
        vineyardId: String,
        observationId: String,
        photoId: String,
    ): String =
        "${vineyardId.lowercase()}/${observationId.lowercase()}/${photoId.lowercase()}.jpg"

    /**
     * The matching object path inside the private `scout-photos` bucket.
     *
     * The first folder MUST be the vineyard id: the SQL 236 storage policies
     * authorise on `storage_first_folder_uuid(name)`, so any other shape would
     * be refused by the bucket rather than silently misfiled.
     */
    override fun storagePath(
        vineyardId: String,
        observationId: String,
        photoId: String,
    ): String = relativePath(vineyardId, observationId, photoId)

    fun file(relativePath: String): File = File(root, relativePath)

    override fun exists(relativePath: String): Boolean = file(relativePath).exists()

    /**
     * Write the bytes durably and return the relative path, or null when the
     * write genuinely failed.
     *
     * Written to a temporary file and then renamed, so a process death
     * mid-write leaves either nothing or a complete JPEG — never a truncated
     * file that would later decode to a grey rectangle.
     */
    override fun write(
        jpeg: ByteArray,
        vineyardId: String,
        observationId: String,
        photoId: String,
    ): String? {
        val relative = relativePath(vineyardId, observationId, photoId)
        val target = file(relative)
        return runCatching {
            target.parentFile?.mkdirs()
            val temp = File(target.parentFile, "${target.name}.part")
            temp.writeBytes(jpeg)
            if (!temp.renameTo(target)) {
                // Fall back to a direct write rather than reporting success on
                // a file that is not actually in place.
                target.writeBytes(jpeg)
                temp.delete()
            }
            relative
        }.onFailure {
            Log.w(TAG, "Scout photo write failed: ${it.javaClass.simpleName}")
        }.getOrNull()
    }

    override fun read(relativePath: String): ByteArray? =
        runCatching { file(relativePath).takeIf { it.exists() }?.readBytes() }
            .onFailure { Log.w(TAG, "Scout photo read failed: ${it.javaClass.simpleName}") }
            .getOrNull()

    /** Remove one photograph's bytes. Used when the operator deletes a photo. */
    override fun remove(relativePath: String) {
        runCatching { file(relativePath).delete() }
            .onFailure { Log.w(TAG, "Scout photo delete failed: ${it.javaClass.simpleName}") }
    }

    /**
     * Drop every locally held Scout photograph.
     *
     * Sign-out must not leave one System Admin's field photographs readable to
     * the next person who signs in on the same handset.
     */
    override fun clearForSignOut() {
        runCatching { root.deleteRecursively() }
            .onFailure { Log.w(TAG, "Scout photo clear failed: ${it.javaClass.simpleName}") }
    }

    private companion object {
        const val DIR_NAME = "scout_photos"
        const val TAG = "VineyardInsights"
    }
}
