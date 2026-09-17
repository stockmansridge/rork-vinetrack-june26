package com.rork.vinetrack.data.insights

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The durable photograph upload progression.
 *
 * local_saved -> queued -> object_uploaded -> row_committed -> completed
 *
 * The rule under test throughout: a photograph is reported stored, and its
 * queue obligation discharged, only when BOTH the storage object and the
 * metadata row exist. A storage object with no row is invisible to every
 * client, so completing on the upload alone would tell the operator their
 * evidence was saved when no report could ever find it.
 */
class ScoutPhotoUploadStateTest {

    private val photoId = "photo-1"
    private val path = "vineyard-1/observation-1/photo-1.jpg"

    // --- The progression ---------------------------------------------------

    @Test
    fun `bytes on disk but nothing queued is local_saved`() {
        assertEquals(
            PhotoUploadState.LOCAL_SAVED,
            ScoutPhotoUpload.state(isQueued = false, uploadedStoragePath = null, rowCommitted = false),
        )
    }

    @Test
    fun `an entry awaiting upload is queued`() {
        assertEquals(
            PhotoUploadState.QUEUED,
            ScoutPhotoUpload.state(isQueued = true, uploadedStoragePath = null, rowCommitted = false),
        )
    }

    @Test
    fun `bytes uploaded without a row is object_uploaded and NOT complete`() {
        val state = ScoutPhotoUpload.state(
            isQueued = true,
            uploadedStoragePath = path,
            rowCommitted = false,
        )

        assertEquals(PhotoUploadState.OBJECT_UPLOADED, state)
        assertFalse(
            "an object with no row is invisible to every client",
            ScoutPhotoUpload.isFullyStored(uploadedStoragePath = path, rowCommitted = false),
        )
    }

    @Test
    fun `only both effects together count as fully stored`() {
        assertFalse(ScoutPhotoUpload.isFullyStored(null, false))
        assertFalse("the bucket write alone is not enough", ScoutPhotoUpload.isFullyStored(path, false))
        assertFalse("a row without bytes is not enough", ScoutPhotoUpload.isFullyStored(null, true))
        assertTrue(ScoutPhotoUpload.isFullyStored(path, true))
    }

    @Test
    fun `the obligation is discharged only after the row commits`() {
        assertEquals(
            PhotoUploadState.ROW_COMMITTED,
            ScoutPhotoUpload.state(isQueued = true, uploadedStoragePath = path, rowCommitted = true),
        )
        assertEquals(
            PhotoUploadState.COMPLETED,
            ScoutPhotoUpload.state(isQueued = false, uploadedStoragePath = path, rowCommitted = true),
        )
    }

    // --- Step selection and retry ------------------------------------------

    @Test
    fun `a fresh queue entry uploads its bytes first`() {
        val step = ScoutPhotoUpload.nextStep(
            photoId = photoId,
            storagePath = path,
            uploadedStoragePath = null,
            stillPresentLocally = true,
            rowCommitted = false,
        )

        assertEquals(
            ScoutPhotoUpload.Step.UploadObject(photoId, path),
            step,
        )
    }

    @Test
    fun `a restart after object_uploaded resumes at the metadata row`() {
        // The whole reason object_uploaded is persisted: the bytes are already
        // in the bucket, so re-uploading them would be wasted work and the row
        // is what is actually still owed.
        val step = ScoutPhotoUpload.nextStep(
            photoId = photoId,
            storagePath = path,
            uploadedStoragePath = path,
            stillPresentLocally = true,
            rowCommitted = false,
        )

        assertEquals(ScoutPhotoUpload.Step.CommitRow(photoId, path), step)
    }

    @Test
    fun `storage success followed by metadata failure retries only the row`() {
        // The failure case that previously lost photographs: bytes landed, the
        // row write failed. The entry must survive and resume at the row.
        var attempt = ScoutPhotoUpload.nextStep(photoId, path, null, true, false)
        assertTrue(attempt is ScoutPhotoUpload.Step.UploadObject)

        // Bytes land, row write throws, entry stays queued carrying the marker.
        attempt = ScoutPhotoUpload.nextStep(photoId, path, path, true, false)
        assertEquals(ScoutPhotoUpload.Step.CommitRow(photoId, path), attempt)

        // And the retry re-upserts the SAME primary key at the SAME path.
        val retry = attempt as ScoutPhotoUpload.Step.CommitRow
        assertEquals(photoId, retry.photoId)
        assertEquals(path, retry.storagePath)
    }

    @Test
    fun `a storage retry reuses the same photo id and path`() {
        val first = ScoutPhotoUpload.nextStep(photoId, path, null, true, false)
            as ScoutPhotoUpload.Step.UploadObject
        val second = ScoutPhotoUpload.nextStep(photoId, path, null, true, false)
            as ScoutPhotoUpload.Step.UploadObject

        assertEquals("never a second object", first.storagePath, second.storagePath)
        assertEquals(first.photoId, second.photoId)
    }

    @Test
    fun `both effects done completes the entry`() {
        val step = ScoutPhotoUpload.nextStep(photoId, path, path, true, true)
        assertEquals(ScoutPhotoUpload.Step.Complete(photoId), step)
    }

    // --- Cancellation during an in-flight upload ---------------------------

    @Test
    fun `a photograph deleted mid-upload is cancelled rather than resurrected`() {
        val step = ScoutPhotoUpload.nextStep(
            photoId = photoId,
            storagePath = path,
            uploadedStoragePath = null,
            stillPresentLocally = false,
            rowCommitted = false,
        )

        assertTrue(step is ScoutPhotoUpload.Step.Cancel)
    }

    @Test
    fun `deletion wins even when the bytes already landed`() {
        // The object is referenced by nothing, so it must be removed rather
        // than left as unreachable clutter the vineyard is billed for.
        val step = ScoutPhotoUpload.nextStep(
            photoId = photoId,
            storagePath = path,
            uploadedStoragePath = path,
            stillPresentLocally = false,
            rowCommitted = false,
        ) as ScoutPhotoUpload.Step.Cancel

        assertEquals(path, step.orphanedStoragePath)
    }

    @Test
    fun `a committed row is tombstoned rather than hard removed`() {
        val step = ScoutPhotoUpload.nextStep(
            photoId = photoId,
            storagePath = path,
            uploadedStoragePath = path,
            stillPresentLocally = false,
            rowCommitted = true,
        ) as ScoutPhotoUpload.Step.Cancel

        assertNull(
            "an object a row still references is retained as evidence",
            step.orphanedStoragePath,
        )
    }

    // --- Deletion planning by progress -------------------------------------

    @Test
    fun `deleting a local-only photograph just removes the bytes`() {
        val plan = ScoutPhotoUpload.planDeletion(
            localPath = "local/photo-1.jpg",
            isQueued = false,
            uploadedStoragePath = null,
            rowCommitted = false,
        )

        assertEquals(
            ScoutPhotoUpload.Deletion.LocalOnly("local/photo-1.jpg"),
            plan,
        )
    }

    @Test
    fun `deleting a queued photograph cancels before removing the bytes`() {
        val plan = ScoutPhotoUpload.planDeletion(
            localPath = "local/photo-1.jpg",
            isQueued = true,
            uploadedStoragePath = null,
            rowCommitted = false,
        )

        assertEquals(ScoutPhotoUpload.Deletion.Queued("local/photo-1.jpg"), plan)
    }

    @Test
    fun `deleting an object-uploaded metadata-pending photograph removes the orphan`() {
        val plan = ScoutPhotoUpload.planDeletion(
            localPath = "local/photo-1.jpg",
            isQueued = true,
            uploadedStoragePath = path,
            rowCommitted = false,
        ) as ScoutPhotoUpload.Deletion.ObjectUploadedPending

        assertEquals(path, plan.orphanedStoragePath)
    }

    @Test
    fun `deleting a fully uploaded photograph soft-deletes and retains the object`() {
        val plan = ScoutPhotoUpload.planDeletion(
            localPath = "local/photo-1.jpg",
            isQueued = false,
            uploadedStoragePath = path,
            rowCommitted = true,
        ) as ScoutPhotoUpload.Deletion.FullyUploaded

        assertEquals(path, plan.storagePath)
    }
}
