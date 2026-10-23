package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Host boundary tests, NOT release-APK/Application/handset cold-launch certification. */
class RetainedStartupTest {
    private val json = Json { encodeDefaults = true }
    private fun identity(authenticated: Boolean = true, online: Boolean = true, main: Boolean = true,
                         user: String? = "owner", vineyard: String? = "vineyard", readable: Boolean = true) =
        StartupReplayAdmission.identity(authenticated, online, main, user, vineyard, setOf("vineyard"), 1, readable)
    private fun evidence() = PinCaptureEvidenceStore.Evidence(
        pinId = "pin-original", vineyardId = "vineyard", tripId = "trip-original", buttonName = "Repair", mode = "Repair",
        latitude = -33.0, longitude = 149.0, fixTimeEpochMs = 1, accuracyMetres = 1.0,
        observationTimeIso = "2026-10-14T00:00:00Z", headingDegrees = null, paddockId = null,
        pinRowNumber = null, pinSide = null, snappedLatitude = null, snappedLongitude = null,
        alongRowDistanceMetres = null, snappedToRow = false, captureUserId = "owner")
    private fun encode(row: PinCaptureEvidenceStore.Evidence = evidence()) =
        json.encodeToString(ListSerializer(PinCaptureEvidenceStore.Evidence.serializer()), listOf(row))
    private fun read(raw: String?, files: List<File> = emptyList()) = PinCaptureEvidenceStore.readForRecovery {
        PinCaptureEvidenceStore.readRetainedEvidence(raw, files)
    }

    @Test fun immediateOnlineWithPersistedIdentityBeforeRestoreNeverAdmitsReplay() {
        assertNull(identity(authenticated = false, main = false))
        assertNull(identity(authenticated = false)) // token + cached vineyard are not restored authority
    }

    @Test fun restoredSessionMustResolveAuthorisedRouteBeforeReplay() {
        assertNull(identity(main = false)) // restoring, biometric lock, loading, paywall, restricted
        assertNull(identity(vineyard = "unrelated"))
        assertNotNull(identity())
    }

    @Test fun malformedPendingWritesAreHeldWithoutReplacingOriginalBytes() {
        val raw = "[{\"id\":\"original\","
        val result = PendingWriteStore.decodeForRecovery(raw)
        assertNotNull(result.issue)
        var saves = 0
        val repository = PendingWriteRepository(object : PendingWriteStoring {
            override fun load(): List<PendingWrite> { check(result.issue == null); return result.items }
            override fun save(writes: List<PendingWrite>): Boolean { saves++; return true }
            override fun clear(): Boolean = error("clear forbidden")
        })
        assertNotNull(repository.readIssue.value)
        assertNull(identity(readable = repository.readIssue.value == null))
        assertEquals(0, saves)
        assertEquals("[{\"id\":\"original\",", raw)
    }

    @Test fun malformedPinEvidenceIsHeldAtSafeBoundaryAndNotEmptyAuthority() {
        val raw = "[{\"pinId\":"
        val result = read(raw)
        assertNotNull(result.issue)
        assertNull(identity(readable = result.issue == null))
        assertTrue(runCatching { PinCaptureEvidenceStore.readRetainedEvidence(raw, emptyList()) }.isFailure)
        assertEquals("[{\"pinId\":", raw)
    }

    @Test fun newerPinSchemaIsHeldAndOriginalAtomicFilesRemainByteIdentical() {
        val dir = Files.createTempDirectory("startup-newer-pin").toFile()
        try {
            val newer = encode().replace("\"pinId\":", "\"futureAuthority\":17,\"pinId\":")
            val files = listOf(File(dir, "evidence"), File(dir, "evidence.bak"), File(dir, "evidence.new"))
            files.forEach { it.writeText(newer) }
            val before = files.map { it.readBytes().toList() }
            assertNotNull(read(encode(), files).issue)
            assertEquals(before, files.map { it.readBytes().toList() })
        } finally { dir.deleteRecursively() } // synthetic fixture only
    }

    @Test fun conflictingPinCopiesHoldReplayAndPreserveBothSources() {
        val dir = Files.createTempDirectory("startup-conflict").toFile()
        try {
            val backup = File(dir, "evidence.bak").apply { writeText(encode(evidence().copy(latitude = -34.0))) }
            val original = backup.readBytes().toList()
            val result = read(encode(), listOf(backup))
            assertNotNull(result.issue)
            assertNull(identity(readable = result.issue == null))
            assertEquals(original, backup.readBytes().toList())
        } finally { dir.deleteRecursively() }
    }

    @Test fun authenticatedOfflineKeepsRetainedIdentityWithoutNetworkAdmission() {
        val phase = com.rork.vinetrack.data.auth.SessionDecisions.onConnectivityChange(
            com.rork.vinetrack.data.auth.SessionPhase.AuthenticatedOnline, false)
        assertTrue(phase.isAuthenticated)
        assertNull(identity(authenticated = phase == com.rork.vinetrack.data.auth.SessionPhase.AuthenticatedOnline, online = false))
        assertEquals("trip-original", read(encode()).items.single().tripId)
    }

    @Test fun onlineAfterRestoreRequestsOneBoundedCycleNotOnePerStatePublication() = runBlocking {
        var runs = 0
        val runner = BoundedReplayRunner(this, { _, failure -> throw AssertionError(failure) })
        val completions = mutableListOf<Deferred<Boolean>>()
        flowOf(identity(authenticated = false, main = false), identity(main = false), identity(online = false),
            identity(), identity(), identity()).distinctUntilChanged().collect { admission ->
            if (admission != null) completions += runner.request("automatic") { runs++ }
        }
        assertEquals(1, completions.size)
        assertTrue(completions.single().await())
        assertEquals(1, runs)
    }

    @Test fun restartRetainsPendingWritePinAndActiveTripOriginalIdentities() {
        val writes = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(writes).enqueue(PendingEntityType.TRIP_GPS, PendingOpType.UPDATE,
            "{\"tripId\":\"trip-original\",\"original\":true}", "trip-original")
        val tripStorage = object : ActiveTripSnapshotStorage {
            var raw: String? = null
            override fun read() = raw
            override fun write(value: String) { raw = value }
            override fun remove() = error("remove forbidden")
        }
        val trip = Trip(id = "trip-original", vineyardId = "vineyard", isActive = true,
            pathPoints = listOf(CoordinatePoint(-33.0, 149.0)))
        ActiveTripStore(tripStorage).save("owner", "vineyard", trip)
        val tripBytes = tripStorage.raw
        val pinBytes = encode()
        val restoredPending = PendingWriteRepository(writes).list().single()
        val restoredTrip = ActiveTripStore(tripStorage).load()!!
        val restoredPin = read(pinBytes).items.single()
        assertEquals(pending, restoredPending)
        assertEquals("owner", restoredTrip.ownerUserId)
        assertEquals(trip, restoredTrip.trip)
        assertEquals(restoredPending.clientId, restoredPin.tripId)
        assertEquals("pin-original", restoredPin.pinId)
        assertEquals(tripBytes, tripStorage.raw)
        assertEquals(pinBytes, encode(restoredPin))
        assertNull(identity(authenticated = false, main = false))
    }

    @Test fun freshSignedOutStateCannotReplayEvenWithOnlineTransport() {
        assertNull(identity(authenticated = false, main = false, user = null, vineyard = null))
        assertFalse(com.rork.vinetrack.data.auth.SessionPhase.SignedOut.isAuthenticated)
    }

    @Test fun storageReadFailureIsHeldButCancellationIsNotSwallowed() {
        assertNotNull(PinCaptureEvidenceStore.readForRecovery { throw java.io.IOException("synthetic") }.issue)
        try {
            PinCaptureEvidenceStore.readForRecovery { throw CancellationException("stop") }
            fail("cancellation swallowed")
        } catch (_: CancellationException) { }
    }
}
