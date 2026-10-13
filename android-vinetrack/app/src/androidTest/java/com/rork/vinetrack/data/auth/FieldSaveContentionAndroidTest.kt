package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.PendingPhotoCaptureJournal
import com.rork.vinetrack.data.PendingPhotoRepository
import com.rork.vinetrack.data.PendingWriteRepository
import com.rork.vinetrack.data.PinCreateSync
import com.rork.vinetrack.data.PinRepository
import com.rork.vinetrack.data.model.Trip
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real repositories and disk, isolated from installation data and all network services. */
@RunWith(AndroidJUnit4::class)
class FieldSaveContentionAndroidTest {
    private lateinit var context: LocalContext
    private lateinit var root: File
    private var previousObserver: ((String) -> Unit)? = null

    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.filesDir, "field-contention-${UUID.randomUUID()}").also { check(it.mkdirs()) }
        context = LocalContext(base, root, "field_contention_${UUID.randomUUID()}_")
        previousObserver = CleanExitDiagnostics.observer
        SessionStore(context).save("synthetic-access", "synthetic-refresh", "account-A", null)
    }

    @After fun cleanup() {
        CleanExitDiagnostics.observer = previousObserver
        if (::context.isInitialized) context.names.forEach { context.base.deleteSharedPreferences(context.prefix + it) }
        if (::root.isInitialized) {
            check(root.name.startsWith("field-contention-"))
            root.deleteRecursively()
        }
    }

    @Test fun revocationDuringDeferralRejectsOriginalTripPhotoAndPinWithoutWriting() {
        val session = SessionStore(context)
        val trips = ActiveTripStore(context)
        val photos = PendingPhotoRepository(context)
        val pins = PendingWriteRepository(context)
        val trip = Trip("original", "vineyard", isActive = true, tripTitle = "original-intent")
        contend(session, listOf(
            { assertTrue(runCatching { trips.saveDurably("account-A", "vineyard", trip) }.exceptionOrNull() is FieldAccessRevoked) },
            { assertTrue(runCatching { photos.enqueue("pin", "vineyard", byteArrayOf(1, 2, 3)) }.exceptionOrNull() is FieldAccessRevoked) },
            { assertTrue(runCatching { PinCreateSync(pins).enqueue(PinRepository.PinInput("pin", "vineyard", createdBy = "account-A")) }.exceptionOrNull() is FieldAccessRevoked) },
        ), beforeUnlock = { session.clear() })
        assertTrue(session.retentionGuard.isLocked)
        assertNull(trips.load())
        assertTrue(photos.list().isEmpty())
        assertTrue(PendingWriteRepository(context).list().isEmpty())
        assertFalse(File(root, "pending_pin_photos").exists())
        assertTrue(runCatching { session.save("B-access", "B-refresh", "account-B", null) }.isFailure)
    }

    @Test fun signOutRefusesAcceptedDeferredSaveAndOriginalOperationCompletesDurably() {
        val session = SessionStore(context)
        val access = requireNotNull(session.accountAccess())
        val trips = ActiveTripStore(context)
        val originalSession = context.getSharedPreferences("vinetrack_session", 0).all.toMap()
        val trip = Trip("accepted", "vineyard", isActive = true, pathPoints = listOf(com.rork.vinetrack.data.model.CoordinatePoint(-33.4, 149.7)))
        contend(session, listOf({ assertTrue(trips.saveDurably("account-A", "vineyard", trip)) }), beforeUnlock = {
            assertNull(session.cleanExit(access))
            assertTrue(session.cleanExitRefusal.contains("completing"))
            assertEquals(originalSession, context.getSharedPreferences("vinetrack_session", 0).all)
        })
        assertTrue(session.isAccountAccessCurrent(access))
        val retained = requireNotNull(ActiveTripStore(context).load())
        assertEquals("account-A", retained.ownerUserId)
        assertEquals(trip, retained.trip)
        assertNull(session.cleanExit(access))
        assertEquals(retained, ActiveTripStore(context).load())
    }

    @Test fun photoDeferralDoesNotHoldRepositoryMonitorNeededByAdmissionHolder() {
        val session = SessionStore(context)
        val photos = PendingPhotoRepository(context)
        val bytes = byteArrayOf(9, 8, 7, 6)
        contend(session, listOf({ photos.enqueue("pin", "vineyard", bytes) }), beforeUnlock = {
            synchronized(photos) { assertTrue(photos.list().isEmpty()) }
        })
        val photo = PendingPhotoRepository(context).list().single()
        assertArrayEquals(bytes, File(photo.localPath).readBytes())
    }

    @Test fun coordinatedTankStartSurvivesContentionWithActualSnapshotAndSingleMarker() {
        val session = SessionStore(context)
        val trips = ActiveTripStore(context)
        val actuals = com.rork.vinetrack.data.SprayTankActualStore(context)
        val pending = PendingWriteRepository(context)
        val sync = com.rork.vinetrack.data.TripTankSync(null, pending, trips)
        val source = Trip("trip", "vineyard", isActive = true, tripTitle = "preserved-metadata", pathPoints = listOf(com.rork.vinetrack.data.model.CoordinatePoint(-33.0, 149.0)))
        assertTrue(trips.saveDurably("account-A", "vineyard", source))
        val intended = source.copy(tankSessions = listOf(com.rork.vinetrack.data.model.TankSession("session-1", 1, startTime = "2026-10-12T01:00:00Z", startRow = 1.5)), activeTankNumber = 1)
        val actual = com.rork.vinetrack.data.model.SprayTankActual("actual-1", "vineyard", "spray", "trip", "session-1", 1, waterVolumeL = 123.45, chemicals = emptyList(), confirmedAt = "2026-10-12T01:00:00Z", confirmedBy = "account-A")
        val coordinator = com.rork.vinetrack.data.StartTankCommitCoordinator(context, trips, actuals, pending, sync, canEstablishOperation = { true })
        contend(session, listOf({ assertTrue(coordinator.commit("account-A", "vineyard", source, intended, actual)) }))
        assertEquals(intended, ActiveTripStore(context).load()?.trip)
        assertEquals(listOf(actual), com.rork.vinetrack.data.SprayTankActualStore(context).pending())
        val marker = PendingWriteRepository(context).list().single()
        assertEquals(com.rork.vinetrack.data.model.PendingEntityType.TRIP_TANK, marker.entityType)
        assertEquals("trip", marker.clientId)
        assertNull(coordinator.recover())
        assertEquals(listOf(marker), PendingWriteRepository(context).list())
    }

    @Test fun workTaskHeaderDraftAndMaterialWritesStayDurableAfterContention() {
        val session = SessionStore(context)
        val pending = PendingWriteRepository(context)
        val header = com.rork.vinetrack.data.WorkTaskCreateSync(com.rork.vinetrack.data.WorkTaskRepository(session), pending)
        val materials = com.rork.vinetrack.data.material.WorkTaskMaterialStore(context)
        val line = com.rork.vinetrack.data.material.WorkTaskMaterial("line", "task", "vineyard", materialName = "Original material", quantityRaw = "2.125", unitCostRaw = "4.75", notes = "frozen-notes")
        val drafts = com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context)
        val draft = com.rork.vinetrack.data.model.WorkTaskPlanningDraft("task", "vineyard", "account-A", date = "2026-10-12T00:00:00Z", taskType = "pruning", blockIds = setOf("block"), notes = "exact-draft")
        contend(session, listOf(
            { header.enqueue("task", "vineyard", "block", "Original block", "2026-10-12T00:00:00Z", "pruning", 2.25, "original-task-notes", "2026-10-12T00:00:00Z") },
            { assertTrue(materials.saveTaskMaterials(listOf(line))) },
            { drafts.save(draft) },
        ))
        assertEquals(listOf(line), com.rork.vinetrack.data.material.WorkTaskMaterialStore(context).loadTaskMaterials())
        assertEquals(draft, com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context).load("account-A", "vineyard", "task"))
        val marker = PendingWriteRepository(context).list().single()
        val payload = com.rork.vinetrack.data.SupabaseClient.json.decodeFromString<com.rork.vinetrack.data.WorkTaskCreateSync.Payload>(marker.payloadJson)
        assertEquals("task", payload.id)
        assertEquals("vineyard", payload.vineyardId)
        assertEquals("original-task-notes", payload.notes)
        assertEquals(2.25, payload.durationHours, 0.0)
    }

    @Test fun mainThreadTimeoutIsExplicitBoundedAndSameIntentCanStillBeSaved() {
        val session = SessionStore(context)
        val access = requireNotNull(session.accountAccess())
        val trips = ActiveTripStore(context)
        val original = Trip("trip", "vineyard", isActive = true, tripTitle = "original")
        assertTrue(trips.saveDurably("account-A", "vineyard", original))
        val before = context.getSharedPreferences("vinetrack_active_trip", 0).all.toMap()
        val intended = original.copy(tripTitle = "exact-unsaved-intent")
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>(null)
        val holder = Thread {
            try { assertTrue(session.withAccountAccess(access) { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }) }
            catch (error: Throwable) { failure.set(error) }
        }
        holder.start()
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        try {
            val outcome = AtomicReference<Throwable?>(null)
            val started = android.os.SystemClock.elapsedRealtime()
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                outcome.set(runCatching { trips.saveDurably("account-A", "vineyard", intended) }.exceptionOrNull())
            }
            assertTrue(outcome.get() is FieldSaveBusy)
            assertTrue(android.os.SystemClock.elapsedRealtime() - started < 1_000L)
            assertEquals(before, context.getSharedPreferences("vinetrack_active_trip", 0).all)
        } finally { release.countDown(); holder.join(3_000) }
        assertFalse(holder.isAlive)
        assertNull(failure.get())
        assertTrue(trips.saveDurably("account-A", "vineyard", intended))
        assertEquals(intended, ActiveTripStore(context).load()?.trip)
    }

    @Test fun interruptedJpegWriteRetainsExactJournalAndRecoversBytesAndMetadata() {
        val photos = PendingPhotoRepository(context)
        val directory = File(root, "pending_pin_photos")
        val bytes = byteArrayOf(11, 22, 33, 44, 55)
        var obstructed: File? = null
        CleanExitDiagnostics.observer = { if (it == "field.photo.intent.durable") {
            val capture = PendingPhotoCaptureJournal(directory).pending().single().second
            obstructed = File(capture.attachment.localPath).also { check(it.mkdirs()); File(it, "test-obstruction").writeBytes(byteArrayOf(99)) }
        } }
        assertTrue(runCatching { photos.enqueue("pin", "vineyard", bytes) }.isFailure)
        CleanExitDiagnostics.observer = previousObserver
        assertTrue(photos.list().isEmpty())
        val retained = PendingPhotoCaptureJournal(directory).pending().single().second
        assertEquals("account-A", retained.ownerUserId)
        assertArrayEquals(bytes, retained.jpeg)
        check(requireNotNull(obstructed).deleteRecursively())
        val recovered = PendingPhotoRepository(context).list().single()
        assertEquals(retained.attachment, recovered)
        assertArrayEquals(bytes, File(recovered.localPath).readBytes())
        assertEquals(recovered, PendingPhotoRepository(context).list().single())
        assertTrue(PendingPhotoCaptureJournal(directory).pending().isEmpty())
    }

    @Test fun interruptedMetadataCannotOverwriteNewerCaptureOnRecreation() {
        val raw = context.getSharedPreferences("vinetrack_pending_photos", 0)
        var failMetadata = false
        val prefs = object : SharedPreferences by raw {
            override fun edit(): SharedPreferences.Editor {
                val editor = raw.edit()
                return object : SharedPreferences.Editor by editor {
                    override fun commit(): Boolean = if (failMetadata) false else editor.commit()
                }
            }
        }
        val faulty = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                if (name == "vinetrack_pending_photos") prefs else context.getSharedPreferences(name, mode)
        }
        val photos = PendingPhotoRepository(faulty)
        val first = photos.enqueue("pin", "vineyard", byteArrayOf(1))
        failMetadata = true
        assertTrue(runCatching { photos.enqueue("pin", "vineyard", byteArrayOf(2)) }.isFailure)
        assertEquals(first, photos.list().single())
        assertArrayEquals(byteArrayOf(1), File(first.localPath).readBytes())
        assertEquals(1, PendingPhotoCaptureJournal(File(root, "pending_pin_photos")).pending().size)
        failMetadata = false
        val newest = photos.enqueue("pin", "vineyard", byteArrayOf(3))
        val recreated = PendingPhotoRepository(faulty)
        assertEquals(listOf(newest), recreated.list())
        assertArrayEquals(byteArrayOf(3), File(newest.localPath).readBytes())
        assertTrue(PendingPhotoCaptureJournal(File(root, "pending_pin_photos")).pending().isEmpty())
    }

    @Test fun failedMetadataWithUpdatedPreferenceMemoryStillRequiresDurableRecommit() {
        val raw = context.getSharedPreferences("vinetrack_pending_photos", 0)
        var fail = false
        var memoryValue: String? = null
        val cached = object : SharedPreferences by raw {
            override fun getString(key: String?, fallback: String?): String? =
                if (key == "pending_photos_json" && memoryValue != null) memoryValue else raw.getString(key, fallback)
            override fun edit(): SharedPreferences.Editor {
                val editor = raw.edit()
                var pending: String? = null
                return object : SharedPreferences.Editor by editor {
                    override fun putString(key: String?, value: String?): SharedPreferences.Editor {
                        if (key == "pending_photos_json") pending = value
                        editor.putString(key, value)
                        return this
                    }
                    override fun commit(): Boolean {
                        if (fail) { memoryValue = pending; return false }
                        val committed = editor.commit()
                        if (committed) memoryValue = null
                        return committed
                    }
                }
            }
        }
        val faulty = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                if (name == "vinetrack_pending_photos") cached else context.getSharedPreferences(name, mode)
        }
        val photos = PendingPhotoRepository(faulty)
        val original = photos.enqueue("pin", "vineyard", byteArrayOf(1))
        val durableBefore = raw.all.toMap()
        fail = true
        assertTrue(runCatching { photos.enqueue("pin", "vineyard", byteArrayOf(2)) }.isFailure)
        assertEquals(durableBefore, raw.all)
        assertNotNull(memoryValue)
        assertEquals(original, photos.list().single())
        val intent = PendingPhotoCaptureJournal(File(root, "pending_pin_photos")).pending().single().second
        fail = false
        assertEquals(intent.attachment, PendingPhotoRepository(faulty).list().single())
        assertEquals(intent.attachment, PendingPhotoRepository(context).list().single())
        assertArrayEquals(byteArrayOf(2), File(intent.attachment.localPath).readBytes())
        assertTrue(PendingPhotoCaptureJournal(File(root, "pending_pin_photos")).pending().isEmpty())
    }

    @Test fun earlierSessionPhotoJournalCannotBeReboundToCurrentSameAccount() {
        val photos = PendingPhotoRepository(context)
        val original = photos.enqueue("pin", "vineyard", byteArrayOf(1))
        val directory = File(root, "pending_pin_photos")
        val old = original.copy(id = "old-operation", revision = "old-revision", localPath = File(directory, "old.jpg").absolutePath)
        val epoch = SessionStore(context).retentionGuard.identityEpoch.value
        val file = PendingPhotoCaptureJournal(directory).retain("account-A", epoch - 1L, old, byteArrayOf(2))
        val before = context.getSharedPreferences("vinetrack_pending_photos", 0).all.toMap()
        val bytes = file.readBytes()
        assertTrue(runCatching { PendingPhotoRepository(context) }.isFailure)
        assertEquals(before, context.getSharedPreferences("vinetrack_pending_photos", 0).all)
        assertArrayEquals(bytes, file.readBytes())
        assertArrayEquals(byteArrayOf(1), File(original.localPath).readBytes())
        assertFalse(File(old.localPath).exists())
    }

    @Test fun corruptInterruptedPhotoIntentRefusesRecoveryWithoutDiscardingEvidence() {
        val photos = PendingPhotoRepository(context)
        val first = photos.enqueue("pin", "vineyard", byteArrayOf(1, 2))
        val directory = File(root, "pending_pin_photos")
        val pending = first.copy(id = "interrupted", revision = "interrupted-revision", localPath = File(directory, "interrupted.jpg").absolutePath)
        val journal = PendingPhotoCaptureJournal(directory).retain("account-A", SessionStore(context).retentionGuard.identityEpoch.value, pending, byteArrayOf(3, 4))
        journal.writeBytes(byteArrayOf(0, 0, 0))
        val before = context.getSharedPreferences("vinetrack_pending_photos", 0).all.toMap()
        assertTrue(runCatching { PendingPhotoRepository(context) }.isFailure)
        assertEquals(before, context.getSharedPreferences("vinetrack_pending_photos", 0).all)
        assertArrayEquals(byteArrayOf(1, 2), File(first.localPath).readBytes())
        assertArrayEquals(byteArrayOf(0, 0, 0), journal.readBytes())
    }

    @Test fun signedOutUnfinishedJournalNeverReplaysOrDiscardsOriginalAccountEvidence() {
        val session = SessionStore(context)
        val photos = PendingPhotoRepository(context)
        val original = photos.enqueue("pin", "vineyard", byteArrayOf(1, 2))
        val directory = File(root, "pending_pin_photos")
        val unfinished = original.copy(id = "unfinished", revision = "unfinished-revision",
            localPath = File(directory, "unfinished.jpg").absolutePath)
        val journal = PendingPhotoCaptureJournal(directory).retain("account-A",
            session.retentionGuard.identityEpoch.value, unfinished, byteArrayOf(3, 4))
        val metadata = context.getSharedPreferences("vinetrack_pending_photos", 0).all.toMap()
        val envelope = journal.readBytes()
        assertNull(session.cleanExit(requireNotNull(session.accountAccess())))
        session.clear() // Simulate lost/rejected credentials, NOT a permitted clean exit.
        assertFalse(session.hasSession)
        assertTrue(runCatching { PendingPhotoRepository(context) }.exceptionOrNull() is FieldAccessRevoked)
        assertArrayEquals(envelope, journal.readBytes())
        assertArrayEquals(byteArrayOf(1, 2), File(original.localPath).readBytes())
        assertEquals(metadata, context.getSharedPreferences("vinetrack_pending_photos", 0).all)
        assertFalse(File(unfinished.localPath).exists())
        assertTrue(runCatching { session.save("B-access", "B-refresh", "account-B", null) }.isFailure)
        assertArrayEquals(envelope, journal.readBytes())
    }

    @Test fun signedOutCorruptPhotoJournalRemainsProtectedWithoutMetadataReplacement() {
        val session = SessionStore(context)
        val directory = File(root, "pending_pin_photos").also { check(it.mkdirs()) }
        val evidence = File(directory, "unreadable.capture").also { it.writeBytes(byteArrayOf(0, 0, 0)) }
        val metadata = context.getSharedPreferences("vinetrack_pending_photos", 0)
        check(metadata.edit().putString("pending_photos_json", "unreadable-original-metadata").commit())
        val before = metadata.all.toMap()
        assertNull(session.cleanExit(requireNotNull(session.accountAccess())))
        session.clear()
        assertTrue(runCatching { PendingPhotoRepository(context) }.exceptionOrNull() is FieldAccessRevoked)
        assertArrayEquals(byteArrayOf(0, 0, 0), evidence.readBytes())
        assertEquals(before, metadata.all)
        assertTrue(session.retentionGuard.isLocked)
    }

    @Test fun signedOutUnlistablePhotoLocationIsNotTreatedAsAnEmptyDirectory() {
        val session = SessionStore(context)
        val evidence = File(root, "pending_pin_photos").also { it.writeBytes(byteArrayOf(8, 9)) }
        assertNull(evidence.listFiles())
        assertNull(session.cleanExit(requireNotNull(session.accountAccess())))
        session.clear()
        val metadata = context.getSharedPreferences("vinetrack_pending_photos", 0).all.toMap()
        assertTrue(runCatching { PendingPhotoRepository(context) }.exceptionOrNull() is FieldAccessRevoked)
        assertArrayEquals(byteArrayOf(8, 9), evidence.readBytes())
        assertEquals(metadata, context.getSharedPreferences("vinetrack_pending_photos", 0).all)
        assertTrue(session.retentionGuard.isLocked)
    }

    /** Holder runs actual session serialisation; workers must reach admission before its controlled release. */
    private fun contend(session: SessionStore, saves: List<() -> Unit>, beforeUnlock: () -> Unit = {}) {
        val entered = CountDownLatch(1)
        val waiting = CountDownLatch(saves.size)
        val inspect = CountDownLatch(1)
        val release = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>(null)
        val failures = java.util.concurrent.CopyOnWriteArrayList<Throwable>()
        val done = CountDownLatch(saves.size)
        CleanExitDiagnostics.observer = { if (it == "field.commit.waiting") waiting.countDown() }
        val holder = Thread {
            try { session.retentionGuard.serialized {
                entered.countDown()
                check(waiting.await(2, TimeUnit.SECONDS))
                beforeUnlock()
                inspect.countDown()
                check(release.await(2, TimeUnit.SECONDS))
            } } catch (error: Throwable) { failure.set(error); inspect.countDown() }
        }
        val workers = saves.map { save -> Thread {
            try { save() } catch (error: Throwable) { failures.add(error) } finally { done.countDown() }
        } }
        try {
            holder.start()
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            workers.forEach(Thread::start)
            assertTrue(inspect.await(3, TimeUnit.SECONDS))
            assertEquals("Premature success before admission", saves.size.toLong(), done.count)
        } finally {
            release.countDown()
            holder.join(3_000)
            workers.forEach { it.join(6_000) }
            CleanExitDiagnostics.observer = previousObserver
        }
        assertFalse("Admission holder deadlocked", holder.isAlive)
        assertTrue("Field save worker deadlocked", workers.none(Thread::isAlive))
        assertNull(failure.get())
        assertTrue("Field operation failed: ${failures.map { it.javaClass.simpleName }}", failures.isEmpty())
        assertEquals(0L, done.count)
    }

    private class LocalContext(val base: Context, private val root: File, val prefix: String) : ContextWrapper(base) {
        val names = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = root
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
