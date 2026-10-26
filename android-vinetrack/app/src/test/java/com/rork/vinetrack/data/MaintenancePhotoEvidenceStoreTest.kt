package com.rork.vinetrack.data

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class MaintenancePhotoEvidenceStoreTest {
    private val owner = "44444444-4444-4444-8444-444444444444"
    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val log = "33333333-3333-4333-8333-333333333333"

    @Test fun restartKeepsOriginalBytesTimestampIdentityAndRealReceipt() {
        val root = Files.createTempDirectory("maintenance-evidence").toFile()
        try {
            val store = MaintenancePhotoEvidenceStore(root)
            val entry = store.stage(owner, vineyard, log, byteArrayOf(1, 2, 3))
            val path = "$vineyard/maintenance/$log/photo.jpg"
            val receipt = store.recordReceipt(entry, path)
            val before = root.walkTopDown().filter { it.isFile }.associate { it.relativeTo(root).path to it.readBytes().toList() }
            val restored = MaintenancePhotoEvidenceStore(root)
            val retry = restored.stage(owner, vineyard, log, byteArrayOf(9, 9, 9))
            assertEquals(receipt, retry)
            assertArrayEquals(byteArrayOf(1, 2, 3), restored.bytes(retry))
            assertEquals(before, root.walkTopDown().filter { it.isFile }.associate { it.relativeTo(root).path to it.readBytes().toList() })
            restored.complete(retry)
            assertFalse(root.walkTopDown().any { it.isFile })
        } finally { root.deleteRecursively() }
    }

    @Test fun writableOtherAccountOrVineyardDoesNotReplaceOriginalEvidence() {
        val root = Files.createTempDirectory("maintenance-isolation").toFile()
        try {
            val store = MaintenancePhotoEvidenceStore(root)
            val original = store.stage(owner, vineyard, log, byteArrayOf(4, 5))
            val other = "22222222-2222-4222-8222-222222222222"
            val otherVineyard = store.stage(owner, other, log, byteArrayOf(6))
            val otherAccount = store.stage(other, vineyard, log, byteArrayOf(7))
            assertArrayEquals(byteArrayOf(4, 5), store.bytes(original))
            assertArrayEquals(byteArrayOf(6), store.bytes(otherVineyard))
            assertArrayEquals(byteArrayOf(7), store.bytes(otherAccount))
            try { store.recordReceipt(original, "$other/maintenance/$log/photo.jpg"); fail("Wrong-scope receipt accepted") }
            catch (_: IllegalStateException) { }
            assertEquals(original, store.stage(owner, vineyard, log, byteArrayOf(8)))
        } finally { root.deleteRecursively() }
    }

    @Test fun invalidObjectOwnershipFailsClosedWithoutPathTraversal() {
        for (path in listOf("$vineyard/maintenance/../photo.jpg", "$vineyard/maintenance/$log/photo.jpg?other=1", "/$vineyard/maintenance/$log/photo.jpg", "$vineyard/pins/$log/photo.jpg")) {
            try { MaintenanceWriteScope.objectOwner(path); fail("Malformed path admitted: $path") }
            catch (_: VineyardWriteAuthority.Restricted) { }
        }
        assertEquals(vineyard to log, MaintenanceWriteScope.objectOwner("$vineyard/maintenance/$log/photo.jpg"))
    }
}
