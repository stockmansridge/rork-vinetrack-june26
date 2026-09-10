package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CompletedPhotoCacheEntry
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PendingPhotoEntityKind
import com.rork.vinetrack.data.model.PendingPhotoStatus
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.ui.screens.synthesizeGrowthPins
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
        PinPhotoSync(objects, pins, GrowthGateway(), repository) { emptyList() }.replayAll { }

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
        PinPhotoSync(objects, pins, GrowthGateway(), firstRepository) { emptyList() }.replayAll { }
        assertEquals(0, objects.uploadCount)
        assertEquals("already-uploaded.jpg", firstRepository.list().single().uploadedPath)

        val relaunched = PendingPhotoRepository(root, store)
        PinPhotoSync(objects, pins, GrowthGateway(), relaunched) { emptyList() }.replayAll { }
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
    fun `standalone growth photo uses authoritative identity in synthesized list and detail presentation`() {
        val growth = growthRecord(id = "growth-standalone", pinId = null, syncVersion = 7)
        val synthetic = synthesizeGrowthPins(emptyList(), listOf(growth)).single()
        assertEquals(growth.clientUpdatedAt, synthetic.clientUpdatedAt)
        assertEquals(growth.updatedAt, synthetic.updatedAt)
        assertEquals(growth.syncVersion, synthetic.syncVersion)

        val presentation = resolvePhotoPresentation(synthetic.id, emptyList(), listOf(growth))
        assertEquals(growth.id, presentation.entityId)
        assertEquals(growth.photoPaths?.first(), presentation.remotePath)
        assertEquals(PinPhotoSync.growthRemoteIdentity(growth, "same.jpg"), presentation.remoteIdentity)
    }

    @Test
    fun `linked growth without local pin representation uses growth photo identity`() {
        val growth = growthRecord(id = "growth-linked", pinId = "missing-pin", syncVersion = 4)
        val synthetic = synthesizeGrowthPins(emptyList(), listOf(growth)).single()
        val presentation = resolvePhotoPresentation(synthetic.id, emptyList(), listOf(growth))

        assertEquals("missing-pin", synthetic.id)
        assertEquals("growth-linked", presentation.entityId)
        assertEquals(PinPhotoSync.growthRemoteIdentity(growth, "same.jpg"), presentation.remoteIdentity)
    }

    @Test
    fun `open display changes immediately from pending capture A to replacement B`() {
        val root = Files.createTempDirectory("photo-replacement").toFile()
        val repository = PendingPhotoRepository(root, MemoryPhotoStore())
        val target = PinPresentationTarget("vineyard-1", "pin-1", null, PinPresentationTarget.Kind.PIN)
        val first = repository.enqueue(target, byteArrayOf(1))
        assertEquals(first.revision, repository.displaySource("pin-1", null, null).localRevision)

        val second = repository.enqueue(target, byteArrayOf(2))
        val display = repository.displaySource("pin-1", null, null)
        assertEquals(second.revision, display.localRevision)
        assertEquals(listOf<Byte>(2), File(requireNotNull(display.localPath)).readBytes().toList())
        assertFalse(repository.isCurrent(first.id, first.revision))
    }

    @Test
    fun `delayed download A cannot replace or obscure pending B`() {
        val root = Files.createTempDirectory("photo-delayed-download").toFile()
        val repository = PendingPhotoRepository(root, MemoryPhotoStore())
        val target = PinPresentationTarget("vineyard-1", "pin-1", null, PinPresentationTarget.Kind.PIN)
        val pendingB = repository.enqueue(target, byteArrayOf(9))

        val result = runCatching {
            repository.cacheRemoteDisplay("pin-1", "a.jpg", "a|1", byteArrayOf(1))
        }
        assertTrue(result.isFailure)
        val display = repository.displaySource("pin-1", "a.jpg", "a|1")
        assertEquals(pendingB.revision, display.localRevision)
        assertEquals(listOf<Byte>(9), File(requireNotNull(display.localPath)).readBytes().toList())
    }

    @Test
    fun `same path replacement with changed version metadata invalidates and refreshes cache`() {
        val root = Files.createTempDirectory("photo-same-path").toFile()
        val repository = PendingPhotoRepository(root, MemoryPhotoStore())
        val original = growthRecord(syncVersion = 1)
        val replacement = original.copy(syncVersion = 2, updatedAt = "2026-09-10T01:00:00Z")
        val firstIdentity = PinPhotoSync.growthRemoteIdentity(original, "same.jpg")
        val secondIdentity = PinPhotoSync.growthRemoteIdentity(replacement, "same.jpg")

        repository.cacheRemoteDisplay(original.id, "same.jpg", firstIdentity, byteArrayOf(1))
        assertTrue(repository.displaySource(original.id, "same.jpg", secondIdentity).isStaleCompletedCache)
        repository.cacheRemoteDisplay(original.id, "same.jpg", secondIdentity, byteArrayOf(2))
        val refreshed = repository.displaySource(original.id, "same.jpg", secondIdentity)
        assertFalse(refreshed.isStaleCompletedCache)
        assertEquals(listOf<Byte>(2), File(requireNotNull(refreshed.localPath)).readBytes().toList())
    }

    @Test
    fun `confirmed upload metadata and completed cache identity agree`() = runTest {
        val root = Files.createTempDirectory("photo-confirmation").toFile()
        val repository = PendingPhotoRepository(root, MemoryPhotoStore())
        val retained = repository.enqueue(
            PinPresentationTarget("vineyard-1", null, "growth-1", PinPresentationTarget.Kind.STANDALONE_GROWTH),
            byteArrayOf(3, 4),
        )
        var confirmation: PhotoUploadConfirmation? = null

        PinPhotoSync(ObjectGateway(), PinGateway(), GrowthGateway(), repository) { emptyList() }
            .replayAll { confirmation = it }

        val confirmed = requireNotNull(confirmation)
        assertEquals(retained.revision, confirmed.attachment.revision)
        assertEquals(
            PinPhotoSync.growthRemoteIdentity(requireNotNull(confirmed.growthRecord), confirmed.path),
            confirmed.remoteIdentity,
        )
        val cached = repository.displaySource("growth-1", confirmed.path, confirmed.remoteIdentity)
        assertFalse(cached.isStaleCompletedCache)
        assertNotNull(cached.localPath)
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

    private fun growthRecord(
        id: String = "growth-1",
        pinId: String? = null,
        syncVersion: Long = 2,
    ): GrowthStageRecord = GrowthStageRecord(
        id = id,
        vineyardId = "vineyard-1",
        pinId = pinId,
        stageCode = "EL12",
        latitude = -33.0,
        longitude = 149.0,
        photoPaths = listOf("same.jpg"),
        clientUpdatedAt = "2026-09-10T00:00:00Z",
        updatedAt = "2026-09-10T00:00:00Z",
        syncVersion = syncVersion,
    )

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
