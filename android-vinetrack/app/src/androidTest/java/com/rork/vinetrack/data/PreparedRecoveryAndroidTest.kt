package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Pin
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Frozen first evidence, nonblocking competing captures and original-incarnation commits. */
class PreparedRecoveryAndroidTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefix = "prepared_recovery_${UUID.randomUUID()}_"
    private val names = mutableSetOf<String>()
    private val root = File(base.cacheDir, prefix)
    private val context = object : ContextWrapper(base) {
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int) =
            base.getSharedPreferences(prefix + name, mode).also { synchronized(names) { names.add(name) } }
        override fun getFilesDir() = root.apply { mkdirs() }
    }
    private val owner = "33333333-3333-4333-8333-333333333333"
    private val vineyard = UUID.randomUUID().toString()

    @After fun cleanup() {
        names.forEach { base.deleteSharedPreferences(prefix + it) }
        root.deleteRecursively()
    }

    @Test fun frozenEvidenceSurvivesSourceChangesAndCompetingCaptureFailsClosed() = runBlocking {
        withTimeout(10_000) {
            val session = SessionStore(context)
            session.save("synthetic", "synthetic", owner, null)
            val cache = DomainCacheStore(context)
            cache.savePins(vineyard, listOf(Pin("original", vineyard)), 1)
            val frozen = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val capture = async(Dispatchers.Main, start = CoroutineStart.DEFAULT) {
                RecoverySnapshotStore.captureBeforeMutationPrepared(context, vineyard) {
                    frozen.complete(Unit); release.await()
                }
            }
            frozen.await()
            withContext(Dispatchers.Main) {
                // A replay/export caller cannot pass the preservation gate on
                // preference memory while the first worker owns the capture.
                assertFalse(RecoverySnapshotStore.captureBeforeMutation(context, vineyard).isPreserved)
            }
            cache.savePins(vineyard, listOf(Pin("newer", vineyard)), 2)
            release.complete(Unit)
            assertTrue(capture.await().isPreserved)
            assertEquals(listOf("original"), RecoverySnapshotStore(context).load(vineyard)!!.cachedPins.map { it.id })
            assertEquals(listOf("newer"), cache.loadPins(vineyard).map { it.id })
        }
    }

    @Test fun preparedSnapshotWaitsBeforeStorageForSameAccountContention() = runBlocking {
        val session = SessionStore(context)
        session.save("synthetic", "synthetic", owner, null)
        DomainCacheStore(context).savePins(vineyard, listOf(Pin("retained-original", vineyard)), 1)
        val held = java.util.concurrent.CountDownLatch(1)
        val attempted = java.util.concurrent.CountDownLatch(1)
        val holderFailure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
        val previous = com.rork.vinetrack.data.auth.CleanExitDiagnostics.observer
        val prefs = context.getSharedPreferences("vinetrack_recovery_snapshots_v2", Context.MODE_PRIVATE)
        com.rork.vinetrack.data.auth.CleanExitDiagnostics.observer = {
            if (held.count == 0L && (it == "field.commit.waiting" || it == "field.commit.contended")) attempted.countDown()
        }
        // Coordinate the real lock boundary, not Compose's scheduler or a timed UI retry.
        val holder = Thread {
            try {
                session.retentionGuard.serialized {
                    held.countDown()
                    check(attempted.await(3, java.util.concurrent.TimeUnit.SECONDS))
                    check(prefs.all.isEmpty()) { "Snapshot published before admission" }
                }
            } catch (failure: Throwable) { holderFailure.set(failure) }
        }
        try {
            val result = withContext(Dispatchers.Main) {
                RecoverySnapshotStore.captureBeforeMutationPrepared(context, vineyard) {
                    holder.start()
                    check(held.await(3, java.util.concurrent.TimeUnit.SECONDS))
                }
            }
            holder.join(4_000)
            assertFalse("Authority holder deadlocked", holder.isAlive)
            assertNull(holderFailure.get())
            assertTrue("Same-account contention must not discard prepared preservation", result.isPreserved)
            assertEquals(listOf("retained-original"), RecoverySnapshotStore(context).load(vineyard)!!.cachedPins.map { it.id })
            assertFalse(session.retentionGuard.isLocked)
        } finally {
            attempted.countDown()
            holder.join(4_000)
            com.rork.vinetrack.data.auth.CleanExitDiagnostics.observer = previous
        }
    }

    @Test fun rejectedAccountTransitionRevokesPreparedCommit() = runBlocking {
        withTimeout(10_000) {
            val session = SessionStore(context)
            session.save("synthetic", "synthetic", owner, null)
            val frozen = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val capture = async(Dispatchers.Main) {
                RecoverySnapshotStore.captureBeforeMutationPrepared(context, vineyard) {
                    frozen.complete(Unit); release.await()
                }
            }
            frozen.await()
            // Ordinary account admission intentionally rejects this transition
            // and revokes the old incarnation. Do not bypass retention policy.
            assertTrue(runCatching { session.save("other", "other", "44444444-4444-4444-8444-444444444444", null) }.isFailure)
            assertTrue(session.retentionGuard.isLocked)
            release.complete(Unit)
            assertFalse(capture.await().isPreserved)
            assertNull(RecoverySnapshotStore(context).load(vineyard))
        }
    }

    @Test fun corruptOriginalRemainsUnchangedAndBlocksPreparedCapture() = runBlocking {
        SessionStore(context).save("synthetic", "synthetic", owner, null)
        val prefs = context.getSharedPreferences("vinetrack_recovery_snapshots_v2", Context.MODE_PRIVATE)
        check(prefs.edit().putString("snapshot_$vineyard", "{unreadable").commit())
        val result = withContext(Dispatchers.Main) {
            RecoverySnapshotStore.captureBeforeMutationPrepared(context, vineyard)
        }
        assertFalse(result.isPreserved)
        assertEquals("{unreadable", prefs.getString("snapshot_$vineyard", null))
    }
}
