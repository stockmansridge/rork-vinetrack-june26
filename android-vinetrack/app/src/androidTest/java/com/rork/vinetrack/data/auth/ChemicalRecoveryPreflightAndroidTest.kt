package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.*
import com.rork.vinetrack.data.model.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Isolated, synthetic preferences. Never points recovery tests at a user's installation. */
@RunWith(AndroidJUnit4::class)
class ChemicalRecoveryPreflightAndroidTest {
    private lateinit var fixture: Fixture
    private lateinit var root: File
    private val owner = "00000000-0000-4000-8000-0000000000a1"
    private val vineyard = "00000000-0000-4000-8000-0000000000b2"
    private val other = "00000000-0000-4000-8000-0000000000c3"
    private val codec = Json { encodeDefaults = true }
    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.cacheDir, "chemical-recovery-${UUID.randomUUID()}").also { check(it.mkdir()) }
        fixture = Fixture(base, root, "chemical_recovery_${UUID.randomUUID()}_")
    }
    @After fun cleanup() {
        if (!::fixture.isInitialized) return
        check(root.name.startsWith("chemical-recovery-") && fixture.prefix.startsWith("chemical_recovery_"))
        check(root.canonicalPath.startsWith(fixture.base.cacheDir.canonicalPath + File.separator))
        fixture.names.forEach { fixture.base.deleteSharedPreferences(fixture.prefix + it) }
        check(root.deleteRecursively())
    }
    private fun prefs(name: String) = fixture.getSharedPreferences(name, 0)
    private fun snapshot() = fixture.names.filter { it != "vinetrack_session" }.associateWith { prefs(it).all.toMap() }
    private fun unchanged(before: Map<String, Map<String, *>>) = before.forEach { (name, values) -> assertEquals(name, values, prefs(name).all) }
    private fun populate(): SessionStore {
        val session = SessionStore(fixture)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        DomainCacheStore(fixture).apply {
            setOwner(owner)
            saveTrips(vineyard, listOf(Trip("cached-trip", vineyard, isActive = true, operatorUserId = other)), 1L)
            check(saveYieldSessions(vineyard, listOf(YieldEstimationSession(
                "00000000-0000-4000-8000-0000000000d4", vineyard.uppercase(), "2026-11-01T00:00:00Z",
                sampleSites = listOf(SampleSite("sample", "block", "Block", 1, -33.0, 149.0, 1,
                    BunchCountEntry(12.0, "2026-11-01T00:00:00Z", owner))))), 1L))
        }
        check(SavedChemicalLocalStore(fixture).save(owner, vineyard,
            listOf(SavedChemical("synthetic-product", vineyard, name = "Synthetic product", ratePerHa = 1.5))))
        // Actual historical writer shape: remove only a later nullable field, not identity or quantity.
        val chemicals = prefs("vinetrack_saved_chemicals_local")
        val raw = chemicals.getString("$owner|$vineyard", null)!!
        val old = JsonArray(codec.parseToJsonElement(raw).jsonArray.map { JsonObject(it.jsonObject - "vineyard_preferred_rate") })
        check(chemicals.edit().putString("$owner|$vineyard", old.toString()).commit())
        check(SprayTankActualStore(fixture).save(SprayTankActual(
            id = "actual", vineyardId = vineyard, sprayRecordId = "spray", tripId = "original-trip",
            tankSessionId = "tank-session", tankNumber = 1, waterVolumeL = 343.8,
            chemicals = listOf(SprayTankActualChemical("line", name = "Synthetic product", actualAmountBase = 700.0, unit = "Kg")),
            confirmedAt = "2026-11-01T00:00:00Z", confirmedBy = owner)))
        check(prefs("vinetrack_operations").edit().putBoolean("fill_timer_enabled", true).commit())
        check(prefs("vinetrack_operational_tools").edit().putString("layout_$vineyard",
            """{"visible":["spray"],"hidden":["yield"],"pending":false}""").commit())
        return session
    }
    @Test fun populatedChemicalsYieldPruningAndActualsRecoverTogetherAndSurviveReopen() = runBlocking {
        val session = populate()
        val season = "00000000-0000-4000-8000-0000000000e5"
        val block = "00000000-0000-4000-8000-0000000000f6"
        val server = PruningSyncRepository.SeasonRow(season, vineyard, block, seasonYear = 2026)
        check(prefs("vinetrack_pruning").edit().putString("setups_v2_$vineyard", codec.encodeToString(listOf(server.toModel()))).commit())
        val before = snapshot()
        session.clear()
        val epoch = session.retentionGuard.identityEpoch.value
        val proof = PruningRecoveryVerifier.verify(owner, epoch, session.pruningRecoverySnapshot(owner, epoch), setOf(vineyard),
            get = { path -> when (path.substringBefore('?')) {
                "pruning_seasons" -> codec.encodeToJsonElement(listOf(server))
                else -> error("Unexpected synthetic recovery read")
            } }, rpc = { _, _ -> error("Unexpected RPC") })
        assertTrue(session.restoreOriginal("replacement-access", "replacement-refresh", AppUser(owner), setOf(vineyard), epoch, proof))
        unchanged(before)
        assertTrue(SessionStore(fixture).hasSession)
        assertFalse(SessionStore(fixture).retentionGuard.isLocked)
        assertEquals(1.5, SavedChemicalLocalStore(fixture).load(owner, vineyard).single().ratePerHa!!, 0.0)
        assertEquals(343.8, SprayTankActualStore(fixture).load().single().waterVolumeL!!, 0.0)
        assertNull(ActiveTripStore(fixture).load())
    }
    @Test fun multipleStoresAreReportedTogetherWithoutGrantingAccessOrChangingBytes() {
        val session = populate()
        check(prefs("vinetrack_saved_chemicals_local").edit().putString("$owner|$vineyard", "PRIVATE_CHEMICAL_SENTINEL").commit())
        check(prefs("vinetrack_fertiliser").edit().putString("private-key", "PRIVATE_OTHER_SENTINEL").commit())
        session.clear()
        val before = snapshot()
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        val blockers = inspector.failureDiagnostics
        assertTrue(blockers.any { it.category == "vinetrack_saved_chemicals_local" && it.rule == "CHEMICAL_JSON_SCHEMA" })
        assertTrue(blockers.any { it.category == "vinetrack_fertiliser" })
        assertEquals(blockers.first(), inspector.failureDiagnostic)
        val report = RecoveryDiagnostics.format("RETAINED_EVIDENCE", inspector.failureDiagnostic, blockers)
        listOf(owner, vineyard, "PRIVATE_CHEMICAL_SENTINEL", "PRIVATE_OTHER_SENTINEL", "private-key").forEach { assertFalse(report.contains(it)) }
        unchanged(before)
        assertTrue(session.retentionGuard.isLocked); assertFalse(session.hasSession)
    }
    @Test fun wrongAccountAndRevokedMembershipRemainBlockedWithAllStoresPopulated() {
        val session = populate(); session.clear(); val before = snapshot()
        assertTrue(runCatching { session.restoreOriginal("a", "r", AppUser(other), setOf(vineyard)) }.isFailure)
        assertTrue(runCatching { session.restoreOriginal("a", "r", AppUser(owner), emptySet()) }.isFailure)
        unchanged(before)
        assertTrue(session.retentionGuard.isLocked); assertFalse(session.hasSession)
    }
    @Test fun unsafeLocationsStopBeforePreferenceContentInspection() {
        val file = File(fixture.filesDir, "unreviewed-private-file")
        file.writeText("PRIVATE_FILE_SENTINEL")
        fixture.names.clear()
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals(1, inspector.failureDiagnostics.size)
        assertTrue(fixture.names.isEmpty())
        assertEquals("PRIVATE_FILE_SENTINEL", file.readText())
    }
    private class Fixture(val base: Context, val root: File, val prefix: String): ContextWrapper(base) {
        val names = linkedSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = File(root, "files").also { check(it.mkdirs() || it.isDirectory) }
        override fun getCacheDir(): File = File(root, "cache").also { check(it.mkdirs() || it.isDirectory) }
        override fun getApplicationInfo(): ApplicationInfo = ApplicationInfo(base.applicationInfo).apply { dataDir = root.path }
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name); return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
