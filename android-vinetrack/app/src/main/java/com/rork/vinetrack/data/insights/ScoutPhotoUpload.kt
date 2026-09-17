package com.rork.vinetrack.data.insights

/**
 * The durable upload progression for one Scout photograph.
 *
 * ## Why a photograph needs five states and not a boolean
 *
 * Uploading a photograph is TWO independent server effects: the bytes into the
 * `scout-photos` bucket, and a metadata row in `scout_observation_photos`. They
 * fail separately. A single "uploaded" flag cannot distinguish "bytes are in the
 * bucket, row still owed" from "fully stored", so a crash between the two either
 * loses the photograph or re-uploads bytes that are already there.
 *
 * The state that matters most is [OBJECT_UPLOADED]. It is persisted, so an app
 * restart resumes at the metadata upsert instead of starting again — and, far
 * more importantly, so the photograph is never reported complete while the row
 * that makes it findable does not yet exist. A storage object with no row is
 * invisible to every client: the operator would be told their evidence was
 * saved, and it would not appear in any report.
 */
enum class PhotoUploadState(val code: String) {

    /** Bytes are on disk with a final photo id. Nothing has been promised yet. */
    LOCAL_SAVED("local_saved"),

    /** Durably queued, carrying its own vineyard ownership. */
    QUEUED("queued"),

    /**
     * Bytes are in the bucket; the metadata row is still owed. NOT complete,
     * and deliberately not presented to the operator as uploaded.
     */
    OBJECT_UPLOADED("object_uploaded"),

    /** The metadata row exists. Both effects have landed. */
    ROW_COMMITTED("row_committed"),

    /** Both effects landed and the queue obligation has been discharged. */
    COMPLETED("completed"),
    ;

    companion object {
        fun byCode(code: String?): PhotoUploadState? = entries.firstOrNull { it.code == code }
    }
}

/**
 * The decision layer over [PhotoUploadState].
 *
 * Pure and free of Android, Ktor and the filesystem so every rule below is
 * exercisable in an ordinary JVM test rather than inferred by reading the
 * worker.
 */
object ScoutPhotoUpload {

    /** The next server effect owed for a queued photograph. */
    sealed interface Step {

        /**
         * Upload the bytes. [storagePath] is derived from the photo id, so a
         * retry overwrites the same object rather than creating a second one.
         */
        data class UploadObject(val photoId: String, val storagePath: String) : Step

        /**
         * Upsert the metadata row on the photo's own primary key, so a retry
         * after a failed row write updates rather than duplicates.
         */
        data class CommitRow(val photoId: String, val storagePath: String) : Step

        /** Both effects are done; drop the queue entry. */
        data class Complete(val photoId: String) : Step

        /**
         * The operator deleted this photograph while it was queued. Discharge
         * the obligation instead of continuing.
         *
         * [orphanedStoragePath] is non-null when bytes had already reached the
         * bucket but no row was ever written — that object is referenced by
         * nothing and must be removed, or it becomes unreachable clutter the
         * operator is billed for and cannot see.
         */
        data class Cancel(val photoId: String, val orphanedStoragePath: String?) : Step
    }

    /**
     * Decide the next step for a queue entry.
     *
     * @param stillPresentLocally whether the photograph is still attached to its
     *   observation. False means the operator deleted it — possibly WHILE this
     *   upload was in flight, which is exactly the race that must not resurrect
     *   it.
     * @param uploadedStoragePath the persisted [PhotoUploadState.OBJECT_UPLOADED]
     *   marker, non-null once bytes are known to be in the bucket.
     */
    fun nextStep(
        photoId: String,
        storagePath: String,
        uploadedStoragePath: String?,
        stillPresentLocally: Boolean,
        rowCommitted: Boolean,
    ): Step = when {
        // Checked FIRST, before any upload work: a deletion always wins over an
        // upload that was already under way.
        !stillPresentLocally -> Step.Cancel(
            photoId = photoId,
            // A row already exists, so the object is referenced and is handled
            // by the soft-delete path instead of being hard-removed here.
            orphanedStoragePath = uploadedStoragePath?.takeIf { !rowCommitted },
        )
        rowCommitted -> Step.Complete(photoId)
        // Bytes already landed. Resume at the row rather than re-uploading.
        uploadedStoragePath != null -> Step.CommitRow(photoId, uploadedStoragePath)
        else -> Step.UploadObject(photoId, storagePath)
    }

    /**
     * The observable state of a queued photograph, for display and assertions.
     */
    fun state(
        isQueued: Boolean,
        uploadedStoragePath: String?,
        rowCommitted: Boolean,
    ): PhotoUploadState = when {
        rowCommitted && !isQueued -> PhotoUploadState.COMPLETED
        rowCommitted -> PhotoUploadState.ROW_COMMITTED
        uploadedStoragePath != null -> PhotoUploadState.OBJECT_UPLOADED
        isQueued -> PhotoUploadState.QUEUED
        else -> PhotoUploadState.LOCAL_SAVED
    }

    /**
     * True only when BOTH effects have landed.
     *
     * The single rule the upload path exists to honour: a photograph is never
     * presented as stored on the strength of the bucket write alone.
     */
    fun isFullyStored(uploadedStoragePath: String?, rowCommitted: Boolean): Boolean =
        uploadedStoragePath != null && rowCommitted

    /** What deleting a photograph must do, by how far its upload had progressed. */
    sealed interface Deletion {

        /** Never queued. Remove the bytes; there is nothing server-side. */
        data class LocalOnly(val localPath: String?) : Deletion

        /** Queued but no bytes uploaded. Cancel first, then remove the bytes. */
        data class Queued(val localPath: String?) : Deletion

        /**
         * Bytes uploaded, no row. Cancel, remove the bytes, and remove the
         * unreferenced object — nothing points at it, so nothing can recover it.
         */
        data class ObjectUploadedPending(
            val localPath: String?,
            val orphanedStoragePath: String,
        ) : Deletion

        /**
         * Fully stored. The row is SOFT-deleted and the object retained, per the
         * established evidence-retention policy: a tombstoned row can be
         * reviewed, whereas a hard delete destroys the record of a real
         * observation.
         */
        data class FullyUploaded(
            val localPath: String?,
            val storagePath: String,
        ) : Deletion
    }

    fun planDeletion(
        localPath: String?,
        isQueued: Boolean,
        uploadedStoragePath: String?,
        rowCommitted: Boolean,
    ): Deletion = when {
        rowCommitted && uploadedStoragePath != null ->
            Deletion.FullyUploaded(localPath, uploadedStoragePath)
        uploadedStoragePath != null ->
            Deletion.ObjectUploadedPending(localPath, uploadedStoragePath)
        isQueued -> Deletion.Queued(localPath)
        else -> Deletion.LocalOnly(localPath)
    }
}
