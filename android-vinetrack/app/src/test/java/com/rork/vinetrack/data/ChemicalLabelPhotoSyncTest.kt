package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ChemicalLabelPhotoSyncTest {
    private class MemoryStore : ChemicalLabelPhotoStoring {
        private var saved: List<ChemicalLabelAttachment> = emptyList()
        override fun load(): List<ChemicalLabelAttachment> = saved
        override fun save(rows: List<ChemicalLabelAttachment>) { saved = rows }
    }

    @Test fun offlineRestartRetainsFileAndSameChemicalIdentity() {
        val root = Files.createTempDirectory("label-restart").toFile()
        try {
            val store = MemoryStore()
            val bytes = byteArrayOf(0x01, 0x02, 0x03)
            val original = ChemicalLabelPhotoRepository(root, store).enqueue("owner", "vineyard", "chemical", bytes)
            val restarted = ChemicalLabelPhotoRepository(root, store)
            assertEquals(original, restarted.list().single())
            assertEquals("chemical", restarted.list().single().chemicalId)
            assertArrayEquals(bytes, File(restarted.list().single().localPath).readBytes())
            assertTrue(original.remotePath.startsWith("vineyard/chemical/"))
        } finally { root.deleteRecursively() }
    }

    @Test fun reconnectWaitsForParentAndThenUploadsOnceWithSameUuid() = runBlocking {
        val root = Files.createTempDirectory("label-reconnect").toFile()
        try {
            val store = MemoryStore()
            val photos = ChemicalLabelPhotoRepository(root, store)
            val pending = PendingWriteRepository(InMemoryPendingWriteStore())
            val marker = pending.enqueue(PendingEntityType.SAVED_CHEMICAL, PendingOpType.CREATE, "{}", "chemical")
            val att = photos.enqueue("owner", "vineyard", "chemical", byteArrayOf(1, 2))
            var calls = 0
            var parentReads = 0
            val sync = ChemicalLabelPhotoSync(photos, pending, SavedChemicalRepository(), { "owner" },
                findParent = { parentReads++; SavedChemical(id = it, vineyardId = "vineyard") },
                upload = { row, bytes ->
                    calls++
                    assertEquals("chemical", row.chemicalId)
                    assertEquals(att.id, row.id)
                    assertArrayEquals(byteArrayOf(1, 2), bytes)
                })
            sync.replayAll()
            assertEquals(0, parentReads)
            assertEquals(0, calls)
            assertTrue(File(att.localPath).exists())
            pending.remove(marker.id)
            ChemicalLabelPhotoSync(ChemicalLabelPhotoRepository(root, store), pending, SavedChemicalRepository(), { "owner" },
                findParent = { parentReads++; SavedChemical(id = it, vineyardId = "vineyard") },
                upload = { row, bytes -> calls++; assertEquals(att.remotePath, row.remotePath); assertArrayEquals(byteArrayOf(1, 2), bytes) })
                .replayAll()
            assertEquals(1, calls)
            assertTrue(ChemicalLabelPhotoRepository(root, store).list().isEmpty())
            assertFalse(File(att.localPath).exists())
            sync.replayAll()
            assertEquals(1, calls)
        } finally { root.deleteRecursively() }
    }

    @Test fun uploadFailureKeepsPhotoAndRestartCanRetry() = runBlocking {
        val root = Files.createTempDirectory("label-failure").toFile()
        try {
            val store = MemoryStore()
            val pending = PendingWriteRepository(InMemoryPendingWriteStore())
            val photos = ChemicalLabelPhotoRepository(root, store)
            val att = photos.enqueue("owner", "vineyard", "chemical", byteArrayOf(9))
            ChemicalLabelPhotoSync(photos, pending, SavedChemicalRepository(), { "owner" },
                findParent = { SavedChemical(id = it, vineyardId = "vineyard") },
                upload = { _, _ -> error("offline") }).replayAll()
            val recovered = ChemicalLabelPhotoRepository(root, store)
            assertEquals(ChemicalLabelAttachment.FAILED, recovered.list().single().status)
            assertEquals(att.chemicalId, recovered.list().single().chemicalId)
            assertTrue(File(att.localPath).exists())
            ChemicalLabelPhotoSync(recovered, pending, SavedChemicalRepository(), { "owner" },
                findParent = { SavedChemical(id = it, vineyardId = "vineyard") },
                upload = { _, _ -> }).replayAll()
            assertTrue(recovered.list().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun interruptedUploadAndOtherAccountNeverLosePhoto() = runBlocking {
        val root = Files.createTempDirectory("label-account").toFile()
        try {
            val store = MemoryStore()
            val photos = ChemicalLabelPhotoRepository(root, store)
            val att = photos.enqueue("owner", "vineyard", "chemical", byteArrayOf(9))
            photos.update(att.id) { it.copy(status = ChemicalLabelAttachment.IN_PROGRESS) }
            val recovered = ChemicalLabelPhotoRepository(root, store)
            assertEquals(ChemicalLabelAttachment.FAILED, recovered.list().single().status)
            var called = false
            ChemicalLabelPhotoSync(recovered, PendingWriteRepository(InMemoryPendingWriteStore()), SavedChemicalRepository(), { "different" },
                findParent = { called = true; null }, upload = { _, _ -> called = true }).replayAll()
            assertFalse(called)
            assertTrue(File(att.localPath).exists())
            recovered.clearAll()
            assertFalse(File(att.localPath).exists())
        } finally { root.deleteRecursively() }
    }
}
