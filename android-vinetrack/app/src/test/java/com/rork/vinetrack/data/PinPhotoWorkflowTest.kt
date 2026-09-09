package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CompletedPhotoCacheEntry
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PendingPhotoEntityKind
import com.rork.vinetrack.data.model.PendingPhotoStatus
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.GrowthStageRecord
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PinPhotoWorkflowTest {
    @Test
    fun `revision paths prevent older capture overwriting newer bytes`() {
        val first = PinPhotoRepository.pinStoragePath("vineyard", "pin", "revision-a")
        val second = PinPhotoRepository.pinStoragePath("vineyard", "pin", "revision-b")
        assertNotEquals(first, second)
        assertTrue(first.endsWith("photo-revision-a.jpg"))
        assertTrue(second.endsWith("photo-revision-b.jpg"))
    }

    @Test
    fun `photo replay waits for both linked parents`() {
        val linked = attachment(kind = PendingPhotoEntityKind.LINKED_GROWTH)
        assertTrue(PinPhotoSync.shouldWaitForParent(linked, setOf("pin-1"), emptySet()))
        assertTrue(PinPhotoSync.shouldWaitForParent(linked, emptySet(), setOf("growth-1")))
        assertFalse(PinPhotoSync.shouldWaitForParent(linked, emptySet(), emptySet()))
    }

    @Test
    fun `interrupted upload recovers after repository recreation and clears only after reference and cache`() = runTest {
        val root = Files.createTempDirectory("pending-photo").toFile()
        val retained = File(root, "retained.jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val store = MemoryPhotoStore(
            rows = mutableListOf(attachment(localPath = retained.absolutePath, status = PendingPhotoStatus.IN_PROGRESS)),
        )
        val repository = PendingPhotoRepository(root, store)
        assertEquals(PendingPhotoStatus.FAILED, repository.list().single().status)

        val objects = ObjectGateway()
        val pins = PinGateway()
        PinPhotoSync(objects, pins, GrowthGateway(), repository) { emptyList() }.replayAll { _, _ -> }

        assertEquals(1, objects.uploadCount)
        assertEquals("uploaded/revision-1.jpg", pins.referencedPath)
        assertTrue(repository.list().isEmpty())
        assertNotNull(repository.displaySource("pin-1", pins.referencedPath, pins.lastIdentity).localPath)
    }

    @Test
    fun `confirmed upload path survives failed reference and resumes without reupload`() = runTest {
        val root = Files.createTempDirectory("pending-photo-reference").toFile()
        val retained = File(root, "retained.jpg").apply { writeBytes(byteArrayOf(4, 5, 6)) }
        val store = MemoryPhotoStore(
            rows = mutableListOf(
                attachment(
                    localPath = retained.absolutePath,
                    status = PendingPhotoStatus.IN_PROGRESS,
                    uploadedPath = "already-uploaded.jpg",
                ),
            ),
        )
        val firstRepository = PendingPhotoRepository(root, store)
        val objects = ObjectGateway()
        val pins = PinGateway(failures = 1)
        PinPhotoSync(objects, pins, GrowthGateway(), firstRepository) { emptyList() }.replayAll { _, _ -> }
        assertEquals(0, objects.uploadCount)
        assertEquals("already-uploaded.jpg", firstRepository.list().single().uploadedPath)

        val relaunched = PendingPhotoRepository(root, store)
        PinPhotoSync(objects, pins, GrowthGateway(), relaunched) { emptyList() }.replayAll { _, _ -> }
        assertEquals(0, objects.uploadCount)
        assertEquals("already-uploaded.jpg", pins.referencedPath)
        assertTrue(relaunched.list().isEmpty())
    }

    @Test
    fun `pending local photo renders independent of remote identity and completed cache becomes stale`() {
        val root = Files.createTempDirectory("photo-display").toFile()
        val store = MemoryPhotoStore()
        val repository = PendingPhotoRepository(root, store)
        repository.enqueue("pin-1", "vineyard-1", byteArrayOf(7, 8))
        val pending = repository.displaySource("pin-1", "remote.jpg", "remote|2")
        assertTrue(pending.isPending)
        assertNotNull(pending.localPath)

        val work = repository.list().single()
        repository.promoteToDisplayCache(work, "remote.jpg", "remote|1")
        repository.remove(work.id)
        val stale = repository.displaySource("pin-1", "remote.jpg", "remote|2")
        assertTrue(stale.isStaleCompletedCache)
        assertNotNull(stale.localPath)
    }

    @Test(expected = IllegalStateException::class)
    fun `retention metadata failure is not reported as success`() {
        val root = Files.createTempDirectory("photo-persistence-failure").toFile()
        val store = MemoryPhotoStore(failSaves = true)
        PendingPhotoRepository(root, store).enqueue("pin-1", "vineyard-1", byteArrayOf(1))
    }

    @Test
    fun `photo only replacement preserves unrelated evidence paths`() {
        assertEquals(
            listOf("revision.jpg", "evidence.jpg"),
            PinPhotoSync.replacingOwnedPhoto(listOf("old.jpg", "evidence.jpg"), "revision.jpg"),
        )
    }

    @Test
    fun `linked delete payload retains both identities and snapshots`() {
        val payload = GrowthRecordDeleteSync.Payload(
            growthRecordId = "growth-1",
            vineyardId = "vineyard-1",
            pinId = "pin-1",
        )
        assertEquals("vineyard-1", payload.vineyardId)
        assertEquals("pin-1", payload.pinId)
        assertEquals("growth-1", payload.growthRecordId)
    }

    private fun attachment(
        kind: String = PendingPhotoEntityKind.PIN,
        localPath: String = "/tmp/photo.jpg",
        status: String = PendingPhotoStatus.PENDING,
        uploadedPath: String? = null,
    ): PendingPhotoAttachment = PendingPhotoAttachment(
        id = "attachment-1",
        clientPinId = "pin-1",
        entityKind = kind,
        growthRecordId = if (kind == PendingPhotoEntityKind.PIN) null else "growth-1",
        revision = "revision-1",
        vineyardId = "vineyard-1",
        localPath = localPath,
        createdAt = 1,
        updatedAt = 1,
        status = status,
        uploadedPath = uploadedPath,
    )
}

private class MemoryPhotoStore(
    var rows: MutableList<PendingPhotoAttachment> = mutableListOf(),
    var cache: MutableList<CompletedPhotoCacheEntry> = mutableListOf(),
    private val failSaves: Boolean = false,
) : PendingPhotoStoring {
    override fun load(): List<PendingPhotoAttachment> = rows.toList()
    override fun save(attachments: List<PendingPhotoAttachment>) {
        check(!failSaves) { "metadata failure" }
        rows = attachments.toMutableList()
    }
    override fun loadCompletedCache(): List<CompletedPhotoCacheEntry> = cache.toList()
    override fun saveCompletedCache(entries: List<CompletedPhotoCacheEntry>) {
        check(!failSaves) { "cache metadata failure" }
        cache = entries.toMutableList()
    }
    override fun clear() { rows.clear(); cache.clear() }
}

private class ObjectGateway : PinPhotoObjectGateway {
    var uploadCount: Int = 0
    override suspend fun upload(vineyardId: String, pinId: String, jpeg: ByteArray, revision: String?): String {
        uploadCount += 1
        return "uploaded/$revision.jpg"
    }
    override suspend fun uploadAtPath(path: String, jpeg: ByteArray): String {
        uploadCount += 1
        return path
    }
    override fun growthStoragePath(vineyardId: String, recordId: String, revision: String?): String =
        "$vineyardId/growth/$recordId/$revision.jpg"
}

private class PinGateway(private var failures: Int = 0) : PinPhotoReferenceGateway {
    var referencedPath: String? = null
    var lastIdentity: String? = null
    override suspend fun updatePhotoPath(id: String, photoPath: String?): Pin {
        if (failures > 0) { failures -= 1; error("reference failed") }
        referencedPath = photoPath
        val pin = Pin(
            id = id,
            vineyardId = "vineyard-1",
            photoPath = photoPath,
            updatedAt = "2026-09-09T00:00:00Z",
            syncVersion = 2,
        )
        lastIdentity = PinPhotoSync.pinRemoteIdentity(pin, requireNotNull(photoPath))
        return pin
    }
}

private class GrowthGateway : GrowthPhotoReferenceGateway {
    override suspend fun updatePhotoPaths(id: String, paths: List<String>?): GrowthStageRecord =
        GrowthStageRecord(
            id = id,
            vineyardId = "vineyard-1",
            photoPaths = paths,
            updatedAt = "2026-09-09T00:00:00Z",
            syncVersion = 2,
        )
}
