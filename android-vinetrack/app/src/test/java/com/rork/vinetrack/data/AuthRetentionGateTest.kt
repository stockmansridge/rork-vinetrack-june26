package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.AuthRetentionGuard
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/** Persisted auth admission tests, not full ViewModel or Android process lifecycle certification. */
class AuthRetentionGateTest {
    @Test fun voluntarySignOutRefusesBeforeAnyDestructiveCleanup() {
        val root = Files.createTempDirectory("auth-retention").toFile()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val original = PinCreateSync(queue).enqueue(PinRepository.PinInput("pin", "vineyard-A"))
            val photos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            val photo = photos.enqueue("pin", "vineyard-A", RetentionReviewTest.jpeg())
            val writesBefore = File(root, "writes").readBytes()
            val photoBefore = File(root, "photos").readBytes()
            val bytesBefore = File(photo.localPath).readBytes()
            val guard = AuthRetentionGuard({ false }, { error("No hold needed for a refused sign-out") })
            for (trigger in listOf("user", "account-switch", "biometric-lock")) {
                if (guard.canSignOut()) { queue.clearAll(); photos.clearAll() }
                assertFalse(trigger, guard.isLocked)
                assertArrayEquals(writesBefore, File(root, "writes").readBytes())
                assertArrayEquals(photoBefore, File(root, "photos").readBytes())
                assertArrayEquals(bytesBefore, File(photo.localPath).readBytes())
            }
            assertEquals(listOf(original), PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list())
        } finally { root.deleteRecursively() }
    }

    @Test fun rejectedAuthRetainsOriginalRowsAndJpegAcrossGuardRecreationAndBlocksBothAccounts() {
        val root = Files.createTempDirectory("auth-retention").toFile()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val original = PinCreateSync(queue).enqueue(PinRepository.PinInput("pin", "vineyard-A"))
            requireNotNull(queue.claimReplay(original))
            val photos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            val photo = photos.enqueue("pin", "vineyard-A", RetentionReviewTest.jpeg())
            val writesBefore = File(root, "writes").readBytes()
            val photosBefore = File(root, "photos").readBytes()
            val jpegBefore = File(photo.localPath).readBytes()
            val latch = File(root, "auth-lock")
            val guard = AuthRetentionGuard({ latch.exists() }, { commitReviewBytes(latch, byteArrayOf(1)); true })
            var credentialsRemoved = false
            assertTrue(guard.rejectSession {
                assertTrue(guard.isLocked)
                assertTrue(latch.exists())
                credentialsRemoved = true
            })
            assertTrue(credentialsRemoved)
            val restarted = AuthRetentionGuard({ latch.exists() }, { error("No rebaseline") })
            for (account in listOf("account-A", "account-B")) {
                var businessConstructed = false
                try {
                    restarted.requireUnlocked()
                    businessConstructed = true
                    PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
                    fail("$account entered locked retained state")
                } catch (_: IllegalStateException) { }
                assertFalse(businessConstructed)
            }
            assertArrayEquals(writesBefore, File(root, "writes").readBytes())
            assertArrayEquals(photosBefore, File(root, "photos").readBytes())
            assertArrayEquals(jpegBefore, File(photo.localPath).readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun failedLockCommitRevokesRuntimeButNeverClearsCredentials() {
        val guard = AuthRetentionGuard({ false }, { false })
        var cleared = false
        assertFalse(guard.rejectSession { cleared = true })
        assertTrue(guard.isLocked)
        assertFalse(cleared)
        try { guard.requireUnlocked(); fail("Admission after failed persistence") } catch (_: IllegalStateException) { }
    }

    @Test fun unreadableLockCannotBecomeUnlocked() {
        val guard = AuthRetentionGuard({ error("Malformed lock") }, { false })
        assertTrue(guard.isLocked)
    }

    @Test fun thrownCommitKeepsRecoveryHeldWithoutCleanup() {
        val guard = AuthRetentionGuard({ false }, { error("Disk error") })
        assertFalse(guard.rejectSession { fail("Credential removal before durable hold") })
        assertTrue(guard.isLocked)
    }

    @Test fun repeatedRejectionNeverUnlocksOrAuthorisesSignOut() {
        var held = false
        val guard = AuthRetentionGuard({ held }, { held = true; true })
        repeat(2) { assertTrue(guard.rejectSession { assertTrue(held) }) }
        assertTrue(guard.isLocked)
        assertFalse(guard.canSignOut())
    }
}
