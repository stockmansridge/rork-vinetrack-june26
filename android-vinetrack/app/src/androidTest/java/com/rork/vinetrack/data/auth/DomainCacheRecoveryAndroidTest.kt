package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.DomainCacheStore
import com.rork.vinetrack.data.model.AppUser
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.PruningSyncRepository
import com.rork.vinetrack.data.PruningStore
import com.rork.vinetrack.data.PruningYieldSettingsStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real stores and admission, isolated synthetic data. No backend or real account is contacted. */
@RunWith(AndroidJUnit4::class)
class DomainCacheRecoveryAndroidTest {
    private lateinit var fixture: Fixture
    private lateinit var root: File
    private val owner = "00000000-0000-0000-0000-0000000000a1"
    private val other = "00000000-0000-0000-0000-0000000000b2"
    private val vineyard = "00000000-0000-4000-8000-0000000000c3"

    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.cacheDir, "domain-recovery-${UUID.randomUUID()}").also { check(it.mkdir()) }
        fixture = Fixture(base, root, "domain_recovery_${UUID.randomUUID()}_")
    }
    @After fun cleanup() {
        if (!::fixture.isInitialized) return
        check(root.name.startsWith("domain-recovery-") && fixture.prefix.startsWith("domain_recovery_"))
        check(root.canonicalPath.startsWith(fixture.base.cacheDir.canonicalPath + File.separator))
        fixture.names.forEach { fixture.base.deleteSharedPreferences(fixture.prefix + it) }
        check(root.deleteRecursively())
    }
    private fun cacheSnapshot() = fixture.getSharedPreferences("vinetrack_domain_cache", 0).all.toMap()
    private fun populated(): SessionStore {
        val session = SessionStore(fixture)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        DomainCacheStore(fixture).apply {
            setOwner(owner)
            // A shared vineyard list can include a trip whose operator is somebody else.
            saveTrips(vineyard, listOf(Trip("cached-active", vineyard, isActive = true, operatorUserId = other)), 1L)
            saveSprayTargetOutbox(emptyList())
            check(saveYieldSessions(vineyard, listOf(YieldEstimationSession(
                "00000000-0000-4000-8000-0000000000d4", vineyard.uppercase(), "2026-10-20T10:00:00Z",
                sampleSites = listOf(SampleSite("sample", "block", "Block", 1, -33.0, 149.0, 1,
                    BunchCountEntry(12.0, "2026-10-20T10:00:00Z", owner))))), 1L))
        }
        return session
    }
    @Test fun actualWriterOutputRecoversWithoutCreatingAnActiveDeviceClaim() {
        val session = populated()
        val before = cacheSnapshot()
        session.clear()
        assertTrue(session.retentionGuard.isLocked)
        assertTrue(session.restoreOriginal("replacement-access", "replacement-refresh", AppUser(owner), setOf(vineyard)))
        assertEquals(before, cacheSnapshot())
        assertEquals(other, DomainCacheStore(fixture).loadTrips(vineyard).single().operatorUserId)
        assertNull(ActiveTripStore(fixture).load())
        assertFalse(ActiveTripStore(fixture).hasActiveClaim())
        assertTrue(SessionStore(fixture).hasSession)
        assertFalse(SessionStore(fixture).retentionGuard.isLocked)
    }
    private val json = Json { encodeDefaults = true }
    private val season = "00000000-0000-4000-8000-0000000000e5"
    private val block = "00000000-0000-4000-8000-0000000000f6"
    private val entry = "00000000-0000-4000-8000-0000000000d7"
    private val seasonRow get() = PruningSyncRepository.SeasonRow(season, vineyard, block, seasonYear = 2026)
    private val settings get() = PruningYieldSettings(season, vineyard, block, bunchesPerBud = 1.7)
    private val entryRow get() = PruningSyncRepository.EntryRow(entry, vineyard, season, block,
        entryDate = "2026-08-10", createdBy = owner, createdAt = "2026-08-10T00:00:00Z",
        updatedAt = "2026-08-10T01:00:00Z", notes = "original entry")
    private val segmentRow get() = PruningSyncRepository.SegmentRow(
        "00000000-0000-4000-8000-0000000000d8", season, rowNumber = 1, segmentNumber = 2,
        completed = true, pruningEntryId = entry)
    private val labour get() = PruningActivityLabourLine(entry, entry, vineyard, workerCount = 2, hoursPerWorker = 3.0)
    private val canonical get() = PruningActivityCanonical(activity = PruningActivityCanonical.CanonicalActivity(
        id = entry, vineyardId = vineyard, entryDate = "2026-08-10", workerOrCrew = "Crew", method = "spur",
        notes = "original activity", seasonYear = 2026, createdBy = owner,
        createdAt = "2026-08-10T00:00:00Z", updatedAt = "2026-08-10T01:00:00Z", isReversed = false))

    /** Populate through actual production writers, not raw preference setup or empty arrays. */
    private fun populatedCombined(): SessionStore = populated().also {
        PruningStore(fixture).apply {
            saveSetups(vineyard, listOf(seasonRow.toModel()))
            saveEntries(vineyard, listOf(entryRow.toModel(listOf(PruningSegment(1, 2)), 2026,
                java.time.ZoneId.of("Australia/Sydney"))))
            saveActivities(vineyard, listOf(PruningAllocationEditor.adoptCanonical(
                PruningActivityDraft(entry, vineyard, "2026-08-10", enteredBy = owner,
                    createdAtMs = java.time.Instant.parse("2026-08-10T00:00:00Z").toEpochMilli(),
                    updatedAtMs = java.time.Instant.parse("2026-08-10T01:00:00Z").toEpochMilli()),
                canonical, java.time.ZoneId.of("Australia/Sydney"))))
            saveLabourLines(vineyard, listOf(labour))
        }
        PruningYieldSettingsStore(fixture).save(vineyard, listOf(settings))
    }
    private fun combinedBytes() = (PruningRecoveryVerifier.stores + "vinetrack_domain_cache").associateWith {
        fixture.getSharedPreferences(it, 0).all.toMap()
    }
    private suspend fun proof(session: SessionStore): PruningRecoveryVerifier.Proof {
        val epoch = session.retentionGuard.identityEpoch.value
        return PruningRecoveryVerifier.verify(owner, epoch, session.pruningRecoverySnapshot(owner, epoch), setOf(vineyard),
            get = { path -> when (path.substringBefore('?')) {
                "pruning_seasons" -> json.encodeToJsonElement(listOf(seasonRow))
                "pruning_entries" -> json.encodeToJsonElement(listOf(entryRow))
                "pruning_row_segments" -> json.encodeToJsonElement(listOf(segmentRow))
                "pruning_activity_labour_lines" -> json.encodeToJsonElement(listOf(labour))
                "pruning_yield_settings" -> json.encodeToJsonElement(listOf(settings))
                "vineyards" -> buildJsonArray { add(buildJsonObject { put("id", vineyard); put("timezone", "Australia/Sydney") }) }
                else -> error("Unexpected recovery read: ${path.substringBefore('?')}")
            } }, rpc = { name, args ->
                assertEquals("get_pruning_activity", name)
                assertEquals(entry, args["p_activity_id"]?.jsonPrimitive?.content)
                json.encodeToJsonElement(canonical)
            })
    }
    @Test fun populatedPruningAndYieldRecoverTogetherWithoutReplacingBytes() = runBlocking {
        val session = populatedCombined()
        val before = combinedBytes()
        session.clear()
        val proof = proof(session)
        assertTrue(session.restoreOriginal("replacement-access", "replacement-refresh", AppUser(owner), setOf(vineyard), pruningProof = proof))
        assertEquals(before, combinedBytes())
        assertFalse(SessionStore(fixture).retentionGuard.isLocked)
        assertEquals(12.0, DomainCacheStore(fixture).loadYieldSessions(vineyard).single().sampleSites.single().bunchCountEntry!!.bunchesPerVine, 0.0)
        assertEquals(1, PruningStore(fixture).loadEntries(vineyard).size)
        assertEquals(1, PruningStore(fixture).loadActivities(vineyard).size)
        assertEquals(listOf(labour), PruningStore(fixture).loadLabourLines(vineyard))
        assertEquals(listOf(settings), PruningYieldSettingsStore(fixture).load(vineyard))
        assertNull(ActiveTripStore(fixture).load())
    }
    @Test fun populatedCombinedProofCannotRestoreWrongAccountOrRevokedAccess() = runBlocking {
        val session = populatedCombined(); val before = combinedBytes()
        session.clear(); val proof = proof(session)
        for ((candidate, permitted) in listOf(AppUser(other) to setOf(vineyard), AppUser(owner) to emptySet())) {
            assertTrue(runCatching { session.restoreOriginal("a", "r", candidate, permitted, pruningProof = proof) }.exceptionOrNull() is AuthRecoveryFailure)
            assertTrue(session.retentionGuard.isLocked); assertFalse(session.hasSession)
            assertEquals(before, combinedBytes())
        }
    }
    @Test fun changedPopulatedSnapshotAndEpochRefuseAdmissionWithoutChangingBytes() = runBlocking {
        val session = populatedCombined(); session.clear(); val epoch = session.retentionGuard.identityEpoch.value
        val proof = proof(session); val before = combinedBytes()
        assertTrue(runCatching { session.restoreOriginal("a", "r", AppUser(owner), setOf(vineyard), epoch + 1, proof) }.exceptionOrNull() is AuthRecoveryFailure)
        assertEquals(before, combinedBytes())
        // Simulate an external obsolete writer, without using a guarded store or changing production admission.
        val raw = fixture.getSharedPreferences("vinetrack_pruning_yield_settings", 0)
        check(raw.edit().putString("settings_$vineyard", json.encodeToString(listOf(settings.copy(bunchesPerBud = 2.1)))).commit())
        val changed = combinedBytes()
        assertTrue(runCatching { session.restoreOriginal("a", "r", AppUser(owner), setOf(vineyard), epoch, proof) }.exceptionOrNull() is AuthRecoveryFailure)
        assertEquals(changed, combinedBytes()); assertTrue(session.retentionGuard.isLocked); assertFalse(session.hasSession)
    }
    @Test fun yieldWriterCannotInterleaveRecoveryOrRebindToRestoredIncarnation() = runBlocking {
        val session = populatedCombined()
        val staleWriter = PruningYieldSettingsStore(fixture)
        val before = combinedBytes(); session.clear(); val proof = proof(session)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>(null)
        val holder = Thread {
            try { session.retentionGuard.serialized {
                entered.countDown(); check(release.await(2, TimeUnit.SECONDS))
                assertEquals(before, combinedBytes())
                assertTrue(session.restoreOriginal("a", "r", AppUser(owner), setOf(vineyard), pruningProof = proof))
            } } catch (error: Throwable) { failure.set(error) }
        }
        try {
            holder.start(); assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(runCatching { staleWriter.save(vineyard, emptyList()) }.exceptionOrNull() is FieldSaveBusy)
            assertEquals(before, combinedBytes())
        } finally { release.countDown(); holder.join(3_000) }
        assertFalse("Recovery admission deadlocked", holder.isAlive); assertNull(failure.get())
        assertTrue(runCatching { staleWriter.save(vineyard, emptyList()) }.exceptionOrNull() is FieldAccessRevoked)
        assertEquals(before, combinedBytes())
        val fresh = PruningYieldSettingsStore(fixture)
        fresh.save(vineyard, listOf(settings.copy(bunchesPerBud = 2.1)))
        assertEquals(2.1, fresh.load(vineyard).single().bunchesPerBud, 0.0)
    }
    @Test fun actualWriterOutputStillPreventsCleanExit() {
        populated()
        val evidence = AccountTransitionEvidence(fixture)
        assertNull(evidence.inspectCleanExit())
        assertEquals("DOMAIN_TRIPS_ACTIVE_ON_CLEAN_EXIT", evidence.failureDiagnostic?.rule)
    }
    @Test fun wrongOriginalAccountIsNotAdmitted() {
        val session = populated()
        val before = cacheSnapshot()
        session.clear()
        val error = runCatching { session.restoreOriginal("a", "r", AppUser(other), setOf(vineyard)) }.exceptionOrNull()
        assertTrue(error is AuthRecoveryFailure)
        assertTrue(session.retentionGuard.isLocked)
        assertFalse(session.hasSession)
        assertEquals(before, cacheSnapshot())
    }
    @Test fun revokedVineyardAccessIsStillRejected() {
        val session = populated()
        val before = cacheSnapshot()
        session.clear()
        val error = runCatching { session.restoreOriginal("a", "r", AppUser(owner), emptySet()) }.exceptionOrNull()
        assertTrue(error is AuthRecoveryFailure)
        assertTrue(session.retentionGuard.isLocked)
        assertFalse(session.hasSession)
        assertEquals(before, cacheSnapshot())
    }
    @Test fun separateForeignActiveClaimRemainsProtected() {
        val session = populated()
        val raw = Json { encodeDefaults = true }.encodeToString(ActiveTripStore.Snapshot.serializer(),
            ActiveTripStore.Snapshot(other, vineyard, Trip("foreign-claim", vineyard, isActive = true), 1L))
        val activePrefs = fixture.getSharedPreferences("vinetrack_active_trip", 0)
        assertTrue(activePrefs.edit().putString("active_trip_snapshot_json", raw).commit())
        session.clear()
        assertTrue(runCatching { session.restoreOriginal("a", "r", AppUser(owner), setOf(vineyard)) }.isFailure)
        assertTrue(session.retentionGuard.isLocked)
        assertEquals(raw, activePrefs.getString("active_trip_snapshot_json", null))
    }
    @Test fun schemaDiagnosticContainsNoRetainedJsonOrIdentifiers() {
        val session = populated()
        val cache = fixture.getSharedPreferences("vinetrack_domain_cache", 0)
        val secret = "PRIVATE_DIAGNOSTIC_SENTINEL"
        assertTrue(cache.edit().putString("trips_$vineyard", secret).commit())
        session.clear()
        val evidence = AccountTransitionEvidence(fixture)
        assertNull(evidence.inspect(owner))
        assertEquals("DOMAIN_TRIPS_DECODE_SCHEMA", evidence.failureDiagnostic?.rule)
        val report = RecoveryDiagnostics.format("RETAINED_EVIDENCE", evidence.failureDiagnostic)
        assertFalse(report.contains(secret)); assertFalse(report.contains(owner)); assertFalse(report.contains(vineyard))
        assertEquals(secret, cache.getString("trips_$vineyard", null))
    }
    private class Fixture(val base: Context, val root: File, val prefix: String): ContextWrapper(base) {
        val names = linkedSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = File(root, "files").also { check(it.mkdirs() || it.isDirectory) }
        override fun getCacheDir(): File = File(root, "cache").also { check(it.mkdirs() || it.isDirectory) }
        override fun getApplicationInfo(): ApplicationInfo = ApplicationInfo(base.applicationInfo).apply { dataDir = root.path }
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
