package com.rork.vinetrack.data.insights

import java.time.Instant
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Scout photograph durability.
 *
 * A scouting photograph is evidence of a condition that existed at one moment
 * in one block, and it cannot be retaken later. So these tests hold one line:
 * the bytes reach storage BEFORE an upload is queued, a failed upload is never
 * allowed to look like a lost photograph, and a photograph that could not be
 * written is refused rather than displayed and then quietly lost.
 */
class ScoutPhotoDurabilityTest {

    private val vineyardId = "vineyard-1"
    private val otherVineyardId = "vineyard-2"
    private val blockA = "paddock-a"

    private class MemoryStore : InsightsKeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String): String? = values[key]
        override fun write(key: String, value: String): Boolean {
            values[key] = value
            return true
        }
        override fun remove(key: String): Boolean {
            values.remove(key)
            return true
        }
    }

    private class MemoryPhotoFiles : ScoutPhotoFiles {
        val files = mutableMapOf<String, ByteArray>()
        var failWrites = false

        override fun relativePath(
            vineyardId: String,
            observationId: String,
            photoId: String,
        ): String = "$vineyardId/$observationId/$photoId.jpg"

        override fun storagePath(
            vineyardId: String,
            observationId: String,
            photoId: String,
        ): String = relativePath(vineyardId, observationId, photoId)

        override fun write(
            jpeg: ByteArray,
            vineyardId: String,
            observationId: String,
            photoId: String,
        ): String? {
            if (failWrites) return null
            val path = relativePath(vineyardId, observationId, photoId)
            files[path] = jpeg
            return path
        }

        override fun read(relativePath: String): ByteArray? = files[relativePath]
        override fun exists(relativePath: String): Boolean = files.containsKey(relativePath)
        override fun remove(relativePath: String) { files.remove(relativePath) }
        override fun clearForSignOut() { files.clear() }
    }

    private val raw = MemoryStore()
    private val photoFiles = MemoryPhotoFiles()
    private var clockMillis = 1_757_000_000_000L
    private val store = VineyardInsightsStore(raw)
    private val controller =
        VineyardInsightsController(store, photoFiles) { Instant.ofEpochMilli(clockMillis) }

    private fun jpeg(marker: Byte = 7): ByteArray = byteArrayOf(marker, 2, 3, 4)

    private fun startVisit(vineyard: String = vineyardId): ScoutVisit = controller.startVisit(
        vineyardId = vineyard,
        scoutUserId = "user-1",
        scoutName = "Jonathan",
        seasonStartMonth = 7,
        seasonStartDay = 1,
        date = LocalDate.of(2026, 11, 20),
    )

    private fun openBlock(visit: ScoutVisit): String {
        controller.toggleBlock(visit.id, blockA)
        return controller.visit(visit.id)!!.assessment(blockA)!!.id
    }

    // --- Local-first capture ----------------------------------------------

    @Test
    fun `capture writes the bytes to storage before queueing the upload`() {
        val visit = startVisit()
        val id = openBlock(visit)

        val photo = controller.capturePhoto(
            visit.id, id, ScoutItem.WEEDS, jpeg(), null, "user-1",
        )

        assertNotNull(photo)
        assertNotNull("a local path is recorded", photo!!.localPath)
        assertTrue("the bytes are genuinely on disk", photoFiles.exists(photo.localPath!!))
        assertEquals(1, store.loadPhotoQueue().size)
        assertNull("no server path until it actually uploads", photo.storagePath)
    }

    @Test
    fun `a photograph that could not be written is refused rather than shown`() {
        // Displaying a photograph and losing it later is worse than refusing
        // now: the operator would believe the evidence was captured.
        val visit = startVisit()
        val id = openBlock(visit)
        photoFiles.failWrites = true

        val photo = controller.capturePhoto(
            visit.id, id, ScoutItem.WEEDS, jpeg(), null, "user-1",
        )

        assertNull(photo)
        assertTrue("nothing is queued for a photograph that does not exist", store.loadPhotoQueue().isEmpty())
        assertTrue(
            "no photograph is recorded against the observation",
            controller.visit(visit.id)!!.assessment(blockA)!!.photoCount == 0,
        )
        assertTrue("and the failure is surfaced", controller.lastWriteFailed.value)
    }

    @Test
    fun `several photographs for one item never overwrite one another`() {
        val visit = startVisit()
        val id = openBlock(visit)

        val first = controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(1), null, "u")
        val second = controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(2), null, "u")
        val third = controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(3), null, "u")

        val paths = listOfNotNull(first?.localPath, second?.localPath, third?.localPath)
        assertEquals("each photograph has its own file", 3, paths.distinct().size)
        assertEquals(3, photoFiles.files.size)
        assertEquals(3, store.loadPhotoQueue().size)
        // The distinct bytes prove no file was reused for a later capture.
        assertEquals(1.toByte(), photoFiles.read(first!!.localPath!!)!![0])
        assertEquals(3.toByte(), photoFiles.read(third!!.localPath!!)!![0])
    }

    @Test
    fun `photographs survive a reload from storage`() {
        val visit = startVisit()
        val id = openBlock(visit)
        controller.capturePhoto(visit.id, id, ScoutItem.POWDERY_MILDEW, jpeg(), null, "u")

        val reloaded = VineyardInsightsStore(raw).loadVisits().single()
        val photo = reloaded.assessment(blockA)!!.observation(ScoutItem.POWDERY_MILDEW)!!.photos.single()

        assertNotNull(photo.localPath)
        assertTrue(photoFiles.exists(photo.localPath!!))
    }

    // --- Location honesty --------------------------------------------------

    @Test
    fun `a qualifying fix is the only way coordinates are stored`() {
        val visit = startVisit()
        val id = openBlock(visit)

        val confirmed = controller.capturePhoto(
            visit.id, id, ScoutItem.WEEDS, jpeg(),
            ScoutPhotoFix(-33.2835, 149.0988, 4.2), "u",
        )
        val unavailable = controller.capturePhoto(
            visit.id, id, ScoutItem.WEEDS, jpeg(), null, "u",
        )

        assertEquals(PhotoLocationStatus.GPS_CONFIRMED, confirmed!!.locationStatus)
        assertEquals(-33.2835, confirmed.latitude!!, 1e-9)
        // No stale fix, no last-known position, no block centroid.
        assertEquals(PhotoLocationStatus.UNAVAILABLE, unavailable!!.locationStatus)
        assertNull(unavailable.latitude)
        assertNull(unavailable.longitude)
        assertNull(unavailable.accuracyMetres)
    }

    // --- Deletion ----------------------------------------------------------

    @Test
    fun `deleting a pending photograph also invalidates its queued upload`() {
        // Otherwise a replay already in flight could resurrect a photograph the
        // operator deliberately removed.
        val visit = startVisit()
        val id = openBlock(visit)
        val photo = controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(), null, "u")!!

        val removed = controller.deletePhoto(visit.id, id, ScoutItem.WEEDS, photo.id)

        assertNotNull(removed)
        assertTrue("the queue entry is gone", store.loadPhotoQueue().isEmpty())
        assertFalse("the local bytes are gone", photoFiles.exists(photo.localPath!!))
        assertEquals(0, controller.visit(visit.id)!!.assessment(blockA)!!.photoCount)
    }

    @Test
    fun `deleting one photograph leaves the others and their uploads intact`() {
        val visit = startVisit()
        val id = openBlock(visit)
        val keep = controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(1), null, "u")!!
        val drop = controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(2), null, "u")!!

        controller.deletePhoto(visit.id, id, ScoutItem.WEEDS, drop.id)

        assertEquals(listOf(keep.id), store.loadPhotoQueue().map { it.id })
        assertTrue(photoFiles.exists(keep.localPath!!))
        assertFalse(photoFiles.exists(drop.localPath!!))
    }

    // --- Queue ownership ---------------------------------------------------

    @Test
    fun `a queued photograph keeps the vineyard it was captured in`() {
        // An operator who scouts one vineyard, drives home, switches vineyards
        // and reconnects must not have their morning filed against someone
        // else's business.
        val first = startVisit(vineyardId)
        val firstAssessment = openBlock(first)
        controller.capturePhoto(first.id, firstAssessment, ScoutItem.WEEDS, jpeg(), null, "u")

        controller.openVisit(null)
        val second = startVisit(otherVineyardId)
        controller.toggleBlock(second.id, blockA)
        val secondAssessment = controller.visit(second.id)!!.assessment(blockA)!!.id
        controller.capturePhoto(second.id, secondAssessment, ScoutItem.WEEDS, jpeg(), null, "u")

        val queue = store.loadPhotoQueue()
        assertEquals(2, queue.size)
        assertEquals(
            setOf(vineyardId, otherVineyardId),
            queue.map { it.vineyardId }.toSet(),
        )
        assertEquals(1, queue.count { it.vineyardId == vineyardId })
    }

    @Test
    fun `the queued storage path is scoped by vineyard so the bucket policy authorises it`() {
        // SQL 236 authorises on storage_first_folder_uuid(name), so any other
        // shape would be refused by the bucket rather than silently misfiled.
        val visit = startVisit()
        val id = openBlock(visit)
        val photo = controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(), null, "u")!!
        val entry = store.loadPhotoQueue().single()

        val path = photoFiles.storagePath(entry.vineyardId, entry.observationId, entry.id)

        assertTrue("first folder is the vineyard", path.startsWith("$vineyardId/"))
        assertEquals("$vineyardId/${photo.observationId}/${photo.id}.jpg", path)
    }

    // --- Sign-out ----------------------------------------------------------

    @Test
    fun `sign out removes the photographs as well as the records`() = kotlinx.coroutines.test.runTest {
        // This is unreleased System Admin data and the next person to sign in
        // on the handset may be someone else entirely.
        val visit = startVisit()
        val id = openBlock(visit)
        controller.capturePhoto(visit.id, id, ScoutItem.WEEDS, jpeg(), null, "u")

        controller.clearForSignOut()

        assertTrue(photoFiles.files.isEmpty())
        assertTrue(store.loadPhotoQueue().isEmpty())
        assertTrue(controller.visits.value.isEmpty())
    }
}
