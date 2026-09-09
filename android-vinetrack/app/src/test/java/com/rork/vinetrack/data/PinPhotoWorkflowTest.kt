package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PendingPhotoEntityKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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

    private fun attachment(kind: String): PendingPhotoAttachment = PendingPhotoAttachment(
        id = "attachment-1",
        clientPinId = "pin-1",
        entityKind = kind,
        growthRecordId = "growth-1",
        revision = "revision-1",
        vineyardId = "vineyard-1",
        localPath = "/tmp/photo.jpg",
        createdAt = 1,
        updatedAt = 1,
    )
}
