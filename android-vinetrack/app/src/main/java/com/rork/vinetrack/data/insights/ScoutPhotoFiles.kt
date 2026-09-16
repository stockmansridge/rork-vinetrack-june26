package com.rork.vinetrack.data.insights

/**
 * The narrow file-storage boundary under Scout photo capture.
 *
 * Exists for the same reason as [InsightsKeyValueStore]: the durability rules —
 * bytes reach disk before an upload is queued, a failed write is never reported
 * as a saved photograph, and a deleted photograph's bytes genuinely go — must be
 * exercisable in a plain JVM test. Android's filesystem helpers are awkward to
 * drive off-device, and without this seam the only way to "test" those rules
 * would be to read the code and hope.
 *
 * Note [write] returns the relative path or null. A null is a genuine failure
 * the caller must surface, never an empty success.
 */
interface ScoutPhotoFiles {

    /** Path stored on the record. Relative, so it survives container changes. */
    fun relativePath(vineyardId: String, observationId: String, photoId: String): String

    /**
     * The matching object path inside the private `scout-photos` bucket.
     *
     * The first folder MUST be the vineyard id: the SQL 236 storage policies
     * authorise on `storage_first_folder_uuid(name)`.
     */
    fun storagePath(vineyardId: String, observationId: String, photoId: String): String

    /** Write bytes durably. Returns the relative path, or null when it failed. */
    fun write(
        jpeg: ByteArray,
        vineyardId: String,
        observationId: String,
        photoId: String,
    ): String?

    fun read(relativePath: String): ByteArray?

    fun exists(relativePath: String): Boolean

    fun remove(relativePath: String)

    fun clearForSignOut()
}
