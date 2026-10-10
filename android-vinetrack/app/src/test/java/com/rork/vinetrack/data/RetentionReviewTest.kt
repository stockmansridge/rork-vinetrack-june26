package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionDecision
import com.rork.vinetrack.data.auth.SessionDecisions
import com.rork.vinetrack.data.auth.SessionValidity
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.insights.PairedGrowthCaptureCoordinator
import com.rork.vinetrack.data.insights.PairedGrowthCaptureJournal
import com.rork.vinetrack.data.insights.PairedGrowthCaptureJournalStore
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Characterises current defects, not acceptance of the required retention contract.
 * Uses production repositories/coordinators and forced disk commits through their storage seams.
 * Child JVM termination is real process termination, but is not Android application termination.
 */
class RetentionReviewTest {
    private fun directory(): File = Files.createTempDirectory("retention-review").toFile()

    @Test(timeout = 20000) fun signOutCleanupDeletesPersistedWorkAndJpegForEverySharedCleanupTrigger() {
        // Source review establishes these triggers all call AppViewModel.signOut; this invokes
        // its actual repository cleanup methods, not the Android ViewModel or auth transport.
        for (trigger in listOf("user", "runtime-auth-rejected", "account-switch-via-sign-out", "biometric-lock")) {
            val root = directory()
            try {
                val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
                val original = PinCreateSync(queue).enqueue(PinRepository.PinInput("pin", "vineyard-A", notes = trigger))
                val photos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
                val attachment = photos.enqueue("pin", "vineyard-A", jpeg())
                assertEquals(listOf(original), PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list())
                assertNotNull(Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java)
                    .invoke(null, File(attachment.localPath)))
                queue.clearAll()
                photos.clearAll()
                assertTrue(trigger, PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list().isEmpty())
                assertTrue(trigger, PendingPhotoRepository(root, ReviewPhotoDisk(root)).list().isEmpty())
                assertFalse(trigger, File(attachment.localPath).exists())
            } finally { root.deleteRecursively() }
        }
    }

    @Test(timeout = 10000) fun offlineAndUnreachableAuthenticationDoNotSelectSignOut() {
        assertEquals(SessionDecision.KeepOffline, SessionDecisions.onUnauthorized(false, null))
        assertEquals(SessionDecision.KeepOffline, SessionDecisions.onUnauthorized(true, SessionValidity.Unreachable))
        assertEquals(SessionDecision.KeepOnline, SessionDecisions.onUnauthorized(true, SessionValidity.Valid))
        assertEquals(SessionDecision.SignOut, SessionDecisions.onUnauthorized(true, SessionValidity.Rejected))
    }

    @Test(timeout = 10000) fun interruptedOfflineWorkThenDestructiveReauthenticationCannotRestoreIt() {
        val root = directory()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val original = PinCreateSync(queue).enqueue(PinRepository.PinInput("pin", "vineyard-A"))
            requireNotNull(queue.claimReplay(original))
            val photos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            val attachment = photos.enqueue("pin", "vineyard-A", jpeg())
            photos.updateStatusIfCurrent(attachment, PendingPhotoStatus.IN_PROGRESS)
            val relaunched = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val relaunchedPhotos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            assertEquals(original.payloadJson, relaunched.list().single().payloadJson)
            assertEquals(PendingPhotoStatus.FAILED, relaunchedPhotos.list().single().status)
            relaunched.clearAll()
            relaunchedPhotos.clearAll()
            assertTrue(PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list().isEmpty())
            assertFalse(File(attachment.localPath).exists())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun photoClearPersistenceFailureDeletesBytesButLeavesPersistedMetadata() {
        val root = directory()
        try {
            val store = ReviewPhotoDisk(root)
            val photos = PendingPhotoRepository(root, store)
            val original = photos.enqueue("pin", "vineyard-A", jpeg())
            store.failClear = true
            try { photos.clearAll(); fail("Expected metadata commit failure") } catch (_: IllegalStateException) { }
            assertEquals(listOf(original), PendingPhotoRepository(root, ReviewPhotoDisk(root)).list())
            assertFalse(File(original.localPath).exists())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun pendingRowsAndPhotosHaveNoDurableAccountBindingAfterRestart() {
        val root = directory()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            queue.configureReplayScope { PendingWriteRepository.ReplayScope("account-A", 1) }
            val original = PinCreateSync(queue).enqueue(PinRepository.PinInput("pin", "vineyard-A"))
            val photos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            photos.configureReplayScope { PendingWriteRepository.ReplayScope("account-A", 1) }
            val attachment = photos.enqueue("pin", "vineyard-A", jpeg())
            val other = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            other.configureReplayScope { PendingWriteRepository.ReplayScope("account-B", 2) }
            // Demonstrates the repository boundary, not a claim that another account's UI
            // completed a live upload. Preservation/RLS alone cannot prove original authorship.
            assertEquals(listOf(original), other.list())
            assertNotNull(other.claimReplay(original, other.freezeReplayVersions(other.list())))
            val otherPhotos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            otherPhotos.configureReplayScope { PendingWriteRepository.ReplayScope("account-B", 2) }
            assertArrayEquals(jpeg(), otherPhotos.latestFile("pin")!!.readBytes())
            assertTrue(otherPhotos.updateStatusIfCurrent(attachment, PendingPhotoStatus.IN_PROGRESS))
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun allAuditedGenericClaimsRemainStrandedExceptWorkTaskHeaders() {
        val root = directory()
        try {
            val types = listOf(PendingEntityType.PIN, PendingEntityType.PIN_EDIT,
                PendingEntityType.CUSTOM_PIN, PendingEntityType.MANUAL_ISSUE,
                PendingEntityType.TRIP_START, PendingEntityType.TRIP_METADATA,
                PendingEntityType.TRIP_SEEDING, PendingEntityType.TRIP_GPS,
                PendingEntityType.TRIP_ROW, PendingEntityType.TRIP_ROW_PLAN,
                PendingEntityType.TRIP_TANK, PendingEntityType.TRIP_END,
                PendingEntityType.TRIP, PendingEntityType.TRIP_LABOUR, PendingEntityType.WORK_TASK)
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val claims = types.map { type -> requireNotNull(queue.claimReplay(queue.enqueue(type,
                PendingOpType.UPDATE, """{"vineyard_id":"vineyard-A","authored":"$type"}""", type))) }
            val restarted = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            for (claim in claims.filter { it.entityType != PendingEntityType.WORK_TASK }) {
                assertEquals(claim, restarted.list().single { it.id == claim.id })
                assertNull(restarted.claimReplay(claim))
                assertFalse(restarted.resetFailedRowForRetry(claim.id))
            }
            assertEquals(PendingWriteStatus.FAILED, restarted.list().single { it.entityType == PendingEntityType.WORK_TASK }.status)
            assertEquals(1, restarted.resetFailedForRetry())
            assertEquals(14, restarted.list().count { it.status == PendingWriteStatus.IN_PROGRESS })
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 60000) fun abruptProcessDeathBeforeRequestStrandsRealRoutePayload() = processCase("before-request")
    @Test(timeout = 60000) fun abruptProcessDeathWhileRequestSuspendsStrandsRealRoutePayload() = processCase("suspended")
    @Test(timeout = 60000) fun abruptProcessDeathAfterServerAcceptanceStrandsRealRoutePayload() = processCase("server-accepted")
    @Test(timeout = 60000) fun failedAcknowledgementPersistenceThenProcessDeathStrandsRoutePayload() = processCase("ack-save-failed")

    private fun processCase(point: String) = runBlocking {
        val root = directory()
        try {
            val classpath = reviewClasspath()
            val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").absolutePath,
                "-Djava.awt.headless=true", "-cp", classpath,
                "com.rork.vinetrack.data.RetentionReviewProcess", root.absolutePath, point)
                .redirectErrorStream(true).redirectOutput(File(root, "child.log")).start()
            if (!child.waitFor(25, TimeUnit.SECONDS)) {
                child.destroyForcibly(); fail("Bounded child termination timed out")
            }
            assertEquals(File(root, "child.log").readText(), 73, child.exitValue())
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val claim = queue.list().single()
            assertEquals(PendingWriteStatus.IN_PROGRESS, claim.status)
            val payload = Json.decodeFromString(TripRowPlanSync.Payload.serializer(), claim.payloadJson)
            assertEquals(listOf(2.5, 1.5), payload.target.sequence)
            assertEquals("trip", payload.tripId)
            assertEquals(0, claim.attemptCount)
            assertEquals(0, queue.resetFailedForRetry())
            var probes = 0
            TripRowPlanSync(queue, { probes++; reviewTrip() }) { _, _ -> error("Stranded row unexpectedly sent") }
                .replayAll { error("Stranded row unexpectedly published") }
            assertEquals(0, probes)
            assertEquals(claim, queue.list().single())
            assertEquals(point in listOf("server-accepted", "ack-save-failed"), File(root, "server-accepted").exists())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun accountChangeDuringRequestRetainsClaimButRestartCannotRetry() = runBlocking {
        val root = directory()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            var scope = PendingWriteRepository.ReplayScope("account-A", 1)
            queue.configureReplayScope { scope }
            val started = CompletableDeferred<Unit>()
            val reply = CompletableDeferred<Trip>()
            var callbacks = 0
            val sync = TripRowPlanSync(queue, { reviewTrip() }) { _, _ -> started.complete(Unit); reply.await() }
            sync.enqueue(reviewTrip(), reviewTrip().copy(rowSequence = listOf(2.5, 1.5)))
            val replay = async { sync.replayAll { callbacks++ } }
            started.await()
            scope = PendingWriteRepository.ReplayScope("account-B", 2)
            reply.complete(reviewTrip().copy(rowSequence = listOf(2.5, 1.5)))
            replay.await()
            assertEquals(0, callbacks)
            val restarted = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            assertEquals(PendingWriteStatus.IN_PROGRESS, restarted.list().single().status)
            assertEquals(0, restarted.resetFailedForRetry())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun vineyardSelectionIsNotPartOfRepositoryClaimScope() {
        val root = directory()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            queue.configureReplayScope { PendingWriteRepository.ReplayScope("account-A", 1) }
            val original = PinCreateSync(queue).enqueue(PinRepository.PinInput("pin", "vineyard-A"))
            val claim = requireNotNull(queue.claimReplay(original))
            // Same-account selection changes deliberately do not change ReplayScope.
            // Caller vineyard/publication checks remain required; this is not cross-account authorisation.
            assertTrue(queue.isCurrent(claim))
            assertTrue(queue.removeIfCurrent(claim))
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun photoRestartRecoversExactRevisionUploadedPathAndJpeg() {
        val root = directory()
        try {
            val photos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            val original = photos.enqueue("pin", "vineyard-A", jpeg())
            assertTrue(photos.updateStatusIfCurrent(original, PendingPhotoStatus.IN_PROGRESS))
            assertTrue(photos.recordUploadedPath(original.id, original.revision, "vineyard-A/pin/revision.jpg"))
            val interrupted = photos.list().single()
            val recovered = PendingPhotoRepository(root, ReviewPhotoDisk(root)).list().single()
            assertEquals(interrupted.copy(status = recovered.status, lastError = recovered.lastError, updatedAt = recovered.updatedAt), recovered)
            assertEquals(PendingPhotoStatus.FAILED, recovered.status)
            assertArrayEquals(jpeg(), File(recovered.localPath).readBytes())
            assertEquals(0, recovered.attemptCount)
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun failedClaimPersistenceLeavesOriginalRetryableBytesUntouched() {
        val root = directory()
        try {
            val store = ReviewWriteDisk(File(root, "writes"))
            val queue = PendingWriteRepository(store)
            val original = PinCreateSync(queue).enqueue(PinRepository.PinInput("pin", "vineyard-A"))
            store.failSave = true
            assertNull(queue.claimReplay(original))
            assertEquals(listOf(original), PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun pinCreateTreatsUnverifiedForeignKey409AsAcknowledgement() = runBlocking {
        val root = directory()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val sync = PinCreateSync(queue) { throw BackendError.Server(409, """{"code":"23503","message":"foreign key violation"}""") }
            sync.enqueue(PinRepository.PinInput("pin", "vineyard-A"))
            var callbacks = 0
            sync.replayAll { callbacks++ }
            assertEquals(0, callbacks)
            assertTrue(PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun completionReplacementLosesOriginalWhenRemovalCommitsButEnqueueFails() {
        val root = directory()
        try {
            val disk = ReviewWriteDisk(File(root, "writes"))
            var saves = 0
            val failing = object : PendingWriteStoring {
                override fun load() = disk.load()
                override fun clear() = disk.clear()
                override fun save(writes: List<PendingWrite>): Boolean {
                    saves++
                    return if (saves == 3) false else disk.save(writes)
                }
            }
            val queue = PendingWriteRepository(failing)
            val sync = PinCompletionSync(queue) { id, value -> Pin(id, "vineyard-A", isCompleted = value) }
            sync.enqueue("pin", true)
            try { sync.enqueue("pin", false); fail("Expected replacement save failure") } catch (_: IllegalStateException) { }
            assertTrue(PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun tankMarkerReplacementLosesOriginalWhenRemovalCommitsButEnqueueFails() {
        val root = directory()
        try {
            val disk = ReviewWriteDisk(File(root, "writes"))
            var saves = 0
            val failing = object : PendingWriteStoring {
                override fun load() = disk.load()
                override fun clear() = disk.clear()
                override fun save(writes: List<PendingWrite>): Boolean {
                    saves++
                    return if (saves == 3) false else disk.save(writes)
                }
            }
            val storage = object : ActiveTripSnapshotStorage {
                override fun read(): String? = null
                override fun write(value: String) { }
                override fun remove() { }
            }
            val sync = TripTankSync(null, PendingWriteRepository(failing), ActiveTripStore(storage))
            sync.enqueue(reviewTrip())
            try { sync.enqueue(reviewTrip().copy(activeTankNumber = 2)); fail("Expected replacement save failure") } catch (_: IllegalStateException) { }
            assertTrue(PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun routePlanAtomicReplacementRetainsOriginalWhenSaveFails() {
        val root = directory()
        try {
            val disk = ReviewWriteDisk(File(root, "writes"))
            val queue = PendingWriteRepository(disk)
            val sync = TripRowPlanSync(queue, { reviewTrip() }) { _, _ -> reviewTrip() }
            sync.enqueue(reviewTrip(), reviewTrip().copy(rowSequence = listOf(2.5, 1.5)))
            val original = queue.list().single()
            disk.failSave = true
            try { sync.enqueue(reviewTrip(), reviewTrip().copy(rowSequence = listOf(3.5))); fail("Expected commit failure") } catch (_: IllegalStateException) { }
            assertEquals(listOf(original), PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun realStartReplyPublishesOldMetadataBesideNewerPendingScalarEdit() = runBlocking {
        val root = directory()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val fetched = CompletableDeferred<Unit>()
            val reply = CompletableDeferred<Trip>()
            var local = reviewTrip().copy(tripTitle = "old title", startEngineHours = 100.0)
            val sync = TripStartSync(queue, { fetched.complete(Unit); reply.await() }) { _, _ -> error("Existing row should not activate") }
            sync.enqueue(local)
            val replay = async { sync.replayAll { server -> local = TripStartReconciliation.reconcile(server, local) } }
            fetched.await()
            local = local.copy(tripTitle = "new local title", startEngineHours = 200.0)
            val newer = queue.enqueue(PendingEntityType.TRIP_METADATA, PendingOpType.UPDATE,
                """{"tripId":"trip","tripTitle":"new local title","startEngineHours":200.0}""", "trip")
            reply.complete(reviewTrip().copy(tripTitle = "old title", startEngineHours = 100.0))
            replay.await()
            assertEquals("old title", local.tripTitle)
            assertEquals(100.0, local.startEngineHours)
            assertEquals(listOf(newer), PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun realStartCancellationDoesNotConsumeReplacement() = runBlocking {
        val root = directory()
        try {
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            val fetched = CompletableDeferred<Unit>()
            val sync = TripStartSync(queue, { fetched.complete(Unit); awaitCancellation() }) { _, _ -> error("Cancelled") }
            sync.enqueue(reviewTrip())
            val replay = launch { sync.replayAll { error("Cancelled start published") } }
            fetched.await()
            val replacement = sync.enqueue(reviewTrip().copy(tripTitle = "replacement"))
            replay.cancelAndJoin()
            assertEquals(listOf(replacement), PendingWriteRepository(ReviewWriteDisk(File(root, "writes"))).list())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 60000) fun abruptPhotoProcessDeathRecoversRevisionAndUploadedPath() {
        for (point in listOf("photo-suspended", "photo-server-accepted")) {
            val root = directory()
            try {
                val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").absolutePath,
                    "-Djava.awt.headless=true", "-cp", reviewClasspath(),
                    "com.rork.vinetrack.data.RetentionReviewProcess", root.absolutePath, point)
                    .redirectErrorStream(true).redirectOutput(File(root, "child.log")).start()
                if (!child.waitFor(25, TimeUnit.SECONDS)) { child.destroyForcibly(); fail("Photo child timed out") }
                assertEquals(File(root, "child.log").readText(), 73, child.exitValue())
                val recovered = PendingPhotoRepository(root, ReviewPhotoDisk(root)).list().single()
                assertEquals(PendingPhotoStatus.FAILED, recovered.status)
                assertEquals("vineyard-A/photo-revision.jpg", recovered.uploadedPath)
                assertEquals("vineyard-A", recovered.vineyardId)
                assertArrayEquals(jpeg(), File(recovered.localPath).readBytes())
                assertEquals(0, recovered.attemptCount)
                assertEquals(point == "photo-server-accepted", File(root, "server-accepted").exists())
            } finally { root.deleteRecursively() }
        }
    }

    @Test(timeout = 10000) fun tankReplayCanUseOtherAccountsPersistedActiveSnapshot() = runBlocking {
        val root = directory()
        try {
            val snapshotFile = File(root, "active")
            fun snapshots() = ActiveTripStore(object : ActiveTripSnapshotStorage {
                override fun read(): String? = if (snapshotFile.exists()) snapshotFile.readText() else null
                override fun write(value: String) = commitReviewBytes(snapshotFile, value.toByteArray())
                override fun remove() { snapshotFile.delete() }
            })
            val local = reviewTrip().copy(tankSessions = listOf(TankSession("session", 1,
                startTime = "2026-10-10T00:00:00Z")), activeTankNumber = 1)
            assertTrue(snapshots().claimIfAvailable("account-A", "vineyard-A", local))
            val queue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            TripTankSync(null, queue, snapshots()).enqueue(local)
            val otherQueue = PendingWriteRepository(ReviewWriteDisk(File(root, "writes")))
            otherQueue.configureReplayScope { PendingWriteRepository.ReplayScope("account-B", 2) }
            var sends = 0
            var publications = 0
            val sync = TripTankSync(null, otherQueue, snapshots(), { reviewTrip() }, { _, sessions, active, filling, number ->
                sends++
                reviewTrip().copy(tankSessions = sessions, activeTankNumber = active,
                    isFillingTank = filling, fillingTankNumber = number)
            })
            sync.replayAll(otherQueue.freezeReplayVersions(otherQueue.list())) { publications++ }
            assertEquals("account-A", snapshots().load()!!.ownerUserId)
            assertEquals(1, sends)
            assertEquals(1, publications)
            assertTrue(otherQueue.list().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun tankActualAcknowledgementHasNoAccountIncarnationBoundary() {
        val root = directory()
        try {
            val file = File(root, "actuals")
            fun actuals() = SprayTankActualStore({ if (file.exists()) file.readText() else null },
                { commitReviewBytes(file, it.toByteArray()); true })
            val original = SprayTankActual("actual", "vineyard-A", "spray", "trip", "session", 1,
                chemicals = emptyList(), confirmedAt = "2026-10-10T00:00:00Z", confirmedBy = "account-A")
            assertTrue(actuals().save(original))
            // Recreated store exposes pending records irrespective of current identity.
            // AppViewModel's upsert-success callback has no captured-account check either.
            val otherIncarnation = actuals()
            assertEquals(listOf(original), otherIncarnation.pending())
            assertTrue(otherIncarnation.markSyncedIfCurrent(original))
            assertTrue(actuals().pending().isEmpty())
            assertEquals(listOf(original), actuals().load())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun legacyPairedGrowthJournalCanBeReusedByNextAccountAfterRestart() {
        val root = directory()
        try {
            val file = File(root, "paired-growth")
            fun disk(): PairedGrowthCaptureJournalStore = object : PairedGrowthCaptureJournalStore {
                private val json = Json { encodeDefaults = true }
                private val serializer = ListSerializer(PairedGrowthCaptureJournal.serializer())
                override fun load(): List<PairedGrowthCaptureJournal> = if (file.exists())
                    json.decodeFromString(serializer, file.readText()) else emptyList()
                override fun save(journal: PairedGrowthCaptureJournal): Boolean {
                    val next = load().filterNot { it.operationId == journal.operationId } + journal
                    commitReviewBytes(file, json.encodeToString(serializer, next).toByteArray())
                    return true
                }
                override fun remove(operationId: String): Boolean {
                    commitReviewBytes(file, json.encodeToString(serializer,
                        load().filterNot { it.operationId == operationId }).toByteArray())
                    return true
                }
            }
            val recordedByA = PairedGrowthCaptureJournal(
                operationId = "operation-A", pinId = "pin-A", growthRecordId = "growth-A",
                vineyardId = "shared-vineyard", stageCode = "EL35", observedAtIso = "2026-10-10T00:00:00Z",
                originatingFeature = "growth", createdAtMillis = 1L, updatedAtMillis = 1L,
            )
            assertEquals(recordedByA, PairedGrowthCaptureCoordinator(disk()).beginOrReuse(recordedByA))
            val originalBytes = file.readBytes()
            val nextAccountsCapture = recordedByA.copy(operationId = "operation-B", pinId = "pin-B",
                growthRecordId = "growth-B", createdAtMillis = 2L, updatedAtMillis = 2L)
            // This production coordinator has no account argument. The fixture labels the
            // two capture sessions; it does not simulate login or assert UI reachability.
            assertEquals(recordedByA, PairedGrowthCaptureCoordinator(disk()).beginOrReuse(nextAccountsCapture))
            assertArrayEquals(originalBytes, file.readBytes())
            assertEquals(listOf(recordedByA), disk().load())
            val differentVineyard = nextAccountsCapture.copy(vineyardId = "other-vineyard")
            assertEquals(differentVineyard, PairedGrowthCaptureCoordinator(disk()).beginOrReuse(differentVineyard))
            assertEquals(listOf(recordedByA, differentVineyard), disk().load())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun chemicalLabelClearDeletesAnotherOwnersPersistedAttachmentAndJpeg() {
        val root = directory()
        try {
            val file = File(root, "labels")
            fun disk(): ChemicalLabelPhotoStoring = object : ChemicalLabelPhotoStoring {
                private val json = Json { encodeDefaults = true }
                private val serializer = ListSerializer(ChemicalLabelAttachment.serializer())
                override fun load(): List<ChemicalLabelAttachment> = if (file.exists())
                    json.decodeFromString(serializer, file.readText()) else emptyList()
                override fun save(attachments: List<ChemicalLabelAttachment>) {
                    commitReviewBytes(file, json.encodeToString(serializer, attachments).toByteArray())
                }
            }
            val original = ChemicalLabelPhotoRepository(root, disk())
                .enqueue("account-A", "shared-vineyard", "chemical-A", jpeg())
            val recreated = ChemicalLabelPhotoRepository(root, disk())
            assertEquals(listOf(original), recreated.list())
            assertArrayEquals(jpeg(), File(original.localPath).readBytes())
            // clearAll has no principal parameter despite each attachment carrying ownerId.
            recreated.clearAll()
            assertTrue(ChemicalLabelPhotoRepository(root, disk()).list().isEmpty())
            assertFalse(File(original.localPath).exists())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun unreadableActiveTripEvidenceCanBeOverwrittenByNewClaim() {
        val root = directory()
        try {
            val file = File(root, "active-trip")
            val originalBytes = "{\"owner_user_id\":\"account-A\",\"trip\":{\"id\":\"unfinished-A\"".toByteArray()
            commitReviewBytes(file, originalBytes)
            val storage = object : ActiveTripSnapshotStorage {
                override fun read(): String? = if (file.exists()) file.readText() else null
                override fun write(raw: String) { commitReviewBytes(file, raw.toByteArray()) }
                override fun writeDurably(raw: String): Boolean { write(raw); return true }
                override fun remove() { file.delete() }
            }
            val recreated = ActiveTripStore(storage)
            assertNull(recreated.load())
            assertArrayEquals(originalBytes, file.readBytes())
            assertFalse(recreated.hasActiveClaim())
            assertTrue(recreated.claimIfAvailable("account-B", "other-vineyard",
                reviewTrip().copy(id = "new-trip-B", vineyardId = "other-vineyard")))
            assertFalse(originalBytes.contentEquals(file.readBytes()))
            assertEquals("account-B", ActiveTripStore(storage).load()?.ownerUserId)
        } finally { root.deleteRecursively() }
    }

    companion object {
        fun jpeg(): ByteArray = ByteArrayOutputStream().use { bytes ->
            // Android's compile bootclasspath omits java.desktop; host runtime supplies it.
            val imageClass = Class.forName("java.awt.image.BufferedImage")
            val image = imageClass.getConstructor(Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType).newInstance(2, 2, 1)
            val encoded = Class.forName("javax.imageio.ImageIO").getMethod("write",
                Class.forName("java.awt.image.RenderedImage"), String::class.java, java.io.OutputStream::class.java)
                .invoke(null, image, "jpg", bytes) as Boolean
            check(encoded)
            bytes.toByteArray()
        }
    }
}

internal fun reviewClasspath(): String = buildSet {
    addAll(System.getProperty("java.class.path").split(File.pathSeparator))
    var loader: ClassLoader? = RetentionReviewTest::class.java.classLoader
    while (loader != null) {
        (loader as? java.net.URLClassLoader)?.getURLs()?.filter { it.protocol == "file" }
            ?.forEach { add(File(it.toURI()).absolutePath) }
        loader = loader.parent
    }
}.joinToString(File.pathSeparator)

internal fun reviewTrip() = Trip("trip", "vineyard-A", isActive = true,
    trackingPattern = "sequential", rowSequence = listOf(1.5, 2.5))

internal fun commitReviewBytes(file: File, bytes: ByteArray) {
    FileOutputStream(file).use { output -> output.write(bytes); output.fd.sync() }
}

internal class ReviewWriteDisk(private val file: File) : PendingWriteStoring {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PendingWrite.serializer())
    var failSave: Boolean = false
    override fun load(): List<PendingWrite> = if (file.exists()) json.decodeFromString(serializer, file.readText()) else emptyList()
    override fun save(writes: List<PendingWrite>): Boolean {
        if (failSave) return false
        commitReviewBytes(file, json.encodeToString(serializer, writes).toByteArray())
        return true
    }
    override fun clear(): Boolean = !file.exists() || file.delete()
}

internal class ReviewPhotoDisk(private val root: File) : PendingPhotoStoring {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PendingPhotoAttachment.serializer())
    private val cacheSerializer = ListSerializer(CompletedPhotoCacheEntry.serializer())
    var failClear: Boolean = false
    override fun load(): List<PendingPhotoAttachment> = File(root, "photos").let {
        if (it.exists()) json.decodeFromString(serializer, it.readText()) else emptyList()
    }
    override fun save(attachments: List<PendingPhotoAttachment>) =
        commitReviewBytes(File(root, "photos"), json.encodeToString(serializer, attachments).toByteArray())
    override fun loadCompletedCache(): List<CompletedPhotoCacheEntry> = File(root, "cache").let {
        if (it.exists()) json.decodeFromString(cacheSerializer, it.readText()) else emptyList()
    }
    override fun saveCompletedCache(entries: List<CompletedPhotoCacheEntry>) =
        commitReviewBytes(File(root, "cache"), json.encodeToString(cacheSerializer, entries).toByteArray())
    override fun clear() {
        check(!failClear) { "Injected disk clear failure" }
        File(root, "photos").delete()
        File(root, "cache").delete()
    }
}

/** A test-only process that exits without coroutine cancellation or finally cleanup. */
object RetentionReviewProcess {
    @JvmStatic fun main(args: Array<String>) = runBlocking {
        val root = File(args[0])
        val point = args[1]
        if (point.startsWith("photo-")) {
            val photos = PendingPhotoRepository(root, ReviewPhotoDisk(root))
            photos.enqueue("pin", "vineyard-A", RetentionReviewTest.jpeg())
            val objects = object : PinPhotoObjectGateway {
                override suspend fun upload(vineyardId: String, pinId: String, jpeg: ByteArray, revision: String?) = "vineyard-A/photo-revision.jpg"
                override suspend fun uploadAtPath(path: String, jpeg: ByteArray) = path
                override fun growthStoragePath(vineyardId: String, recordId: String, revision: String?) = "growth.jpg"
            }
            val references = object : PinPhotoReferenceGateway {
                override suspend fun updatePhotoPath(id: String, photoPath: String?): Pin {
                    if (point == "photo-server-accepted") commitReviewBytes(File(root, "server-accepted"), "accepted".toByteArray())
                    Runtime.getRuntime().halt(73)
                    error("Unreachable")
                }
            }
            val growth = object : GrowthPhotoReferenceGateway {
                override suspend fun updatePhotoPaths(id: String, paths: List<String>?): GrowthStageRecord = error("Not growth")
            }
            PinPhotoSync(objects, references, growth, photos) { emptyList() }.replayAll { error("Must terminate before acknowledgement") }
            error("Photo child failed to halt")
        }
        val store = ReviewWriteDisk(File(root, "writes"))
        val queue = PendingWriteRepository(store)
        val sync = TripRowPlanSync(queue, { reviewTrip() }) { _, _ ->
            if (point == "suspended") Runtime.getRuntime().halt(73)
            commitReviewBytes(File(root, "server-accepted"), "accepted".toByteArray())
            if (point == "server-accepted") Runtime.getRuntime().halt(73)
            store.failSave = true
            reviewTrip().copy(rowSequence = listOf(2.5, 1.5))
        }
        sync.enqueue(reviewTrip(), reviewTrip().copy(rowSequence = listOf(2.5, 1.5)))
        if (point == "before-request") {
            check(queue.claimReplay(queue.list().single()) != null)
            Runtime.getRuntime().halt(73)
        }
        sync.replayAll { error("Failed save must not publish") }
        check(point == "ack-save-failed")
        check(queue.list().single().status == PendingWriteStatus.IN_PROGRESS)
        Runtime.getRuntime().halt(73)
    }
}
