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
    @Test fun populatedPruningAndYieldRecoverTogetherWithoutReplacingBytes() = runBlocking {
        val session = populated()
        val json = Json { encodeDefaults = true }
        val season = "00000000-0000-4000-8000-0000000000e5"
        val block = "00000000-0000-4000-8000-0000000000f6"
        val server = PruningSyncRepository.SeasonRow(season, vineyard, block, seasonYear = 2026)
        val prefs = fixture.getSharedPreferences("vinetrack_pruning", 0)
        check(prefs.edit().putString("setups_v2_$vineyard", json.encodeToString(listOf(server.toModel()))).commit())
        val settings = PruningYieldSettings(season, vineyard, block, bunchesPerBud = 1.7)
        val settingsPrefs = fixture.getSharedPreferences("vinetrack_pruning_yield_settings", 0)
        check(settingsPrefs.edit().putString("settings_$vineyard", json.encodeToString(listOf(settings))).commit())
        val before = cacheSnapshot(); val pruningBefore = prefs.all.toMap(); val settingsBefore = settingsPrefs.all.toMap()
        session.clear()
        val epoch = session.retentionGuard.identityEpoch.value
        val proof = PruningRecoveryVerifier.verify(owner, epoch, session.pruningRecoverySnapshot(owner, epoch), setOf(vineyard),
            get = { path -> when (path.substringBefore('?')) {
                "pruning_seasons" -> json.encodeToJsonElement(listOf(server))
                "pruning_yield_settings" -> json.encodeToJsonElement(listOf(settings))
                else -> error("Unexpected network read")
            } }, rpc = { _, _ -> error("Unexpected RPC") })
        assertTrue(session.restoreOriginal("replacement-access", "replacement-refresh", AppUser(owner), setOf(vineyard), epoch, proof))
        assertEquals(before, cacheSnapshot()); assertEquals(pruningBefore, prefs.all); assertEquals(settingsBefore, settingsPrefs.all)
        assertFalse(SessionStore(fixture).retentionGuard.isLocked)
        assertEquals(12.0, DomainCacheStore(fixture).loadYieldSessions(vineyard).single().sampleSites.single().bunchCountEntry!!.bunchesPerVine, 0.0)
        assertNull(ActiveTripStore(fixture).load())
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
