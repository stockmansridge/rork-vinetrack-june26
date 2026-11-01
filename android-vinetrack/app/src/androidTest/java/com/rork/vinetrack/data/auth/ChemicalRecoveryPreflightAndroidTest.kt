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
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.json
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
    private val season = "00000000-0000-4000-8000-0000000000e5"
    private val block = "00000000-0000-4000-8000-0000000000f6"
    private val entry = "00000000-0000-4000-8000-0000000000d7"
    private val server get() = PruningSyncRepository.SeasonRow(season, vineyard, block, seasonYear = 2026)
    private val settings get() = PruningYieldSettings(season, vineyard, block, bunchesPerBud = 1.7)
    private val entryRow get() = PruningSyncRepository.EntryRow(entry, vineyard, season, block,
        entryDate = "2026-08-10", createdBy = owner, createdAt = "2026-08-10T00:00:00Z",
        updatedAt = "2026-08-10T01:00:00Z", notes = "original entry")
    private val segment get() = PruningSyncRepository.SegmentRow(
        "00000000-0000-4000-8000-0000000000d8", season, rowNumber = 1, segmentNumber = 2,
        completed = true, pruningEntryId = entry)
    private val labour get() = PruningActivityLabourLine(entry, entry, vineyard, workerCount = 2, hoursPerWorker = 3.0)
    private val canonical get() = PruningActivityCanonical(activity = PruningActivityCanonical.CanonicalActivity(
        id = entry, vineyardId = vineyard, entryDate = "2026-08-10", workerOrCrew = "Crew", method = "spur",
        notes = "original activity", seasonYear = 2026, createdBy = owner,
        createdAt = "2026-08-10T00:00:00Z", updatedAt = "2026-08-10T01:00:00Z", isReversed = false))
    private val requests = mutableListOf<Pair<HttpMethod, String>>()
    private var actualHistory: List<SprayTankActual> = emptyList()
    private var historyStatus = HttpStatusCode.OK
    private var historyNetworkFailure = false
    private fun recoveryClient(account: String = owner, member: Boolean = true) = HttpClient(MockEngine { request ->
        val path = request.url.encodedPath.substringAfterLast('/')
        requests.add(request.method to path)
        val body = when (path) {
            "token" -> { assertEquals(HttpMethod.Post, request.method); """{"access_token":"replacement-access","refresh_token":"replacement-refresh"}""" }
            "user" -> """{"id":"$account"}"""
            "vineyard_members" -> if (member) """[{"vineyard_id":"$vineyard","role":"operator"}]""" else "[]"
            "vineyards" -> """[{"id":"$vineyard","timezone":"Australia/Sydney"}]"""
            "pruning_seasons" -> codec.encodeToString(listOf(server))
            "pruning_entries" -> codec.encodeToString(listOf(entryRow))
            "pruning_row_segments" -> codec.encodeToString(listOf(segment))
            "pruning_activity_labour_lines" -> codec.encodeToString(listOf(labour))
            "pruning_yield_settings" -> codec.encodeToString(listOf(settings))
            "get_pruning_activity" -> codec.encodeToString(canonical)
            "spray_tank_actuals" -> {
                assertEquals(TankActualRecoveryVerifier.COLUMNS, request.url.parameters["select"])
                assertEquals("is.null", request.url.parameters["deleted_at"])
                assertEquals("2", request.url.parameters["limit"])
                if (historyNetworkFailure) throw java.io.IOException("PRIVATE_NETWORK_DETAIL")
                codec.encodeToString(actualHistory)
            }
            "logout" -> "{}"
            else -> error("Unexpected recovery request: $path")
        }
        if (path !in setOf("token", "logout", "get_pruning_activity")) assertEquals(HttpMethod.Get, request.method)
        if (path != "token") assertEquals("Bearer replacement-access", request.headers[HttpHeaders.Authorization])
        respond(body, if (path == "spray_tank_actuals") historyStatus else HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
    }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
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
        // Exercise the real writer's preserved label representations, not an empty/simple chemical.
        val writerCodec = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val chemical = writerCodec.decodeFromString(SavedChemical.serializer(), """{
            "id":"synthetic-product","vineyard_id":"$vineyard","name":"Synthetic product","rate_per_ha":1.5,
            "active_ingredients":[{"name":"Synthetic active","concentration_unit":"%"}],
            "registered_uses":[{"crop":"Synthetic crop","target":"powdery_mildew","rates":[]}]
        }""")
        check(SavedChemicalLocalStore(fixture).save(owner, vineyard, listOf(chemical)))
        RegionSettingsStore(fixture).save(vineyard, RegionSettings(terminologyRegion = "AU_NZ", timezone = "Australia/Sydney"))
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
        PruningStore(fixture).apply {
            saveSetups(vineyard, listOf(server.toModel()))
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
        check(SprayTankActualStore(fixture).saveInputDraft(SprayActualInputDraft(
            "tank:original-trip:tank-session", owner, vineyard, mapOf("water" to "343.8", "line" to "0.700"),
            "original-trip", "tank-session", "spray")))
        // Capture original-owner evidence, not the other operator's shared read-cache trip.
        DomainCacheStore(fixture).saveTrips(vineyard, listOf(Trip("original-trip", vineyard, operatorUserId = owner)), 1L)
        check(RecoverySnapshotStore.captureBeforeMutation(fixture, vineyard).isPreserved)
        assertEquals(owner, RecoverySnapshotStore(fixture).load(vineyard)!!.cachedTrips.single().operatorUserId)
        return session
    }
    @Test fun populatedChemicalsYieldPruningAndActualsRecoverTogetherAndSurviveReopen() = runBlocking {
        val session = populate()
        val before = snapshot()
        session.clear()
        assertTrue(AuthRecoveryRepository { recoveryClient() }.recover(session, "synthetic@example.invalid", "synthetic-password"))
        unchanged(before)
        assertTrue(SessionStore(fixture).hasSession)
        assertEquals(owner, SessionStore(fixture).userId)
        assertFalse(SessionStore(fixture).retentionGuard.isLocked)
        assertEquals(1.5, SavedChemicalLocalStore(fixture).load(owner, vineyard).single().ratePerHa!!, 0.0)
        val reopenedActuals = SprayTankActualStore(fixture)
        assertEquals(343.8, reopenedActuals.load().single().waterVolumeL!!, 0.0)
        assertEquals(700.0, reopenedActuals.load().single().chemicals.single().actualAmountBase!!, 0.0)
        assertEquals("original-trip", reopenedActuals.pending().single().tripId)
        assertEquals("0.700", reopenedActuals.inputDraft(owner, vineyard, "tank:original-trip:tank-session")!!.text["line"])
        assertEquals(12.0, DomainCacheStore(fixture).loadYieldSessions(vineyard).single().sampleSites.single().bunchCountEntry!!.bunchesPerVine, 0.0)
        assertEquals(1, PruningStore(fixture).loadEntries(vineyard).size)
        assertEquals(1, PruningStore(fixture).loadActivities(vineyard).size)
        assertEquals(listOf(labour), PruningStore(fixture).loadLabourLines(vineyard))
        assertEquals(listOf(settings), PruningYieldSettingsStore(fixture).load(vineyard))
        assertNotNull(RecoverySnapshotStore(fixture).load(vineyard))
        assertTrue(requests.any { it.second == "user" })
        assertTrue(requests.any { it.second == "vineyard_members" })
        assertTrue(requests.any { it.second == "get_pruning_activity" })
        assertFalse(requests.any { it.second == "logout" })
        unchanged(before)
        assertNull(ActiveTripStore(fixture).load())
    }
    @Test fun serverCorrectedAndSharedHistoryRecoverWithoutBecomingPendingWrites() = runBlocking {
        val session = populate()
        val store = SprayTankActualStore(fixture)
        val original = store.load().single()
        actualHistory = listOf(original.copy(id = "shared-history", tripId = "shared-trip", confirmedBy = other,
            correctionVersion = 2, lastCorrectedAt = "2026-11-01T01:00:00Z", clientUpdatedAt = "2026-11-01T01:00:00Z"))
        check(store.mergeRemote(actualHistory))
        session.clear(); val before = snapshot()
        assertTrue(AuthRecoveryRepository { recoveryClient() }.recover(session, "synthetic@example.invalid", "synthetic-password"))
        unchanged(before)
        assertEquals(listOf(original), SprayTankActualStore(fixture).pending())
        assertEquals(actualHistory.single(), SprayTankActualStore(fixture).load().single { it.id == "shared-history" })
        assertEquals(owner, SessionStore(fixture).userId)
    }
    @Test fun missingConflictingDeniedAndOfflineHistoryPreserveEveryStoreAndCredentials(): Unit = runBlocking {
        val session = populate()
        val store = SprayTankActualStore(fixture)
        val original = store.load().single()
        val historical = original.copy(id = "shared-history", tripId = "shared-trip", confirmedBy = other,
            correctionVersion = 2, lastCorrectedAt = "2026-11-01T01:00:00Z", clientUpdatedAt = "2026-11-01T01:00:00Z")
        check(store.mergeRemote(listOf(historical)))
        session.clear(); val before = snapshot()
        val cases = listOf("ACTUAL_SERVER_HISTORY_NOT_VERIFIED", "ACTUAL_SERVER_HISTORY_MISMATCH",
            "SERVER_ACCESS_REFUSED", "SERVER_REQUEST_NOT_COMPLETED", "SERVER_NETWORK_UNAVAILABLE")
        for ((index, rule) in cases.withIndex()) {
            actualHistory = if (index == 0) emptyList() else listOf(historical.copy(waterVolumeL = 999.0))
            historyStatus = when(index) { 2 -> HttpStatusCode.Forbidden; 3 -> HttpStatusCode.ServiceUnavailable; else -> HttpStatusCode.OK }
            historyNetworkFailure = index == 4
            val failure = runCatching { AuthRecoveryRepository { recoveryClient() }.recover(session, "synthetic@example.invalid", "synthetic-password") }.exceptionOrNull()
            assertTrue(failure is AuthRecoveryFailure)
            assertEquals(rule, (failure as AuthRecoveryFailure).evidence?.rule)
            assertEquals(TankActualRecoveryVerifier.STORE, failure.evidence?.category)
            assertFalse(RecoveryDiagnostics.format(failure.stage.name, failure.evidence).contains("PRIVATE_NETWORK_DETAIL"))
            unchanged(before)
            assertFalse(SessionStore(fixture).hasSession)
            assertTrue(SessionStore(fixture).retentionGuard.isLocked)
            assertEquals(listOf(original), SprayTankActualStore(fixture).pending())
        }
    }
    @Test fun pendingCorrectionIsNotAdoptedAsDownloadedHistory(): Unit = runBlocking {
        val session = populate()
        val store = SprayTankActualStore(fixture)
        val edited = store.load().single().copy(correctionVersion = 1, lastCorrectedAt = "2026-11-01T02:00:00Z", clientUpdatedAt = "2026-11-01T02:00:00Z")
        check(store.save(edited))
        session.clear(); val before = snapshot()
        val failure = runCatching { AuthRecoveryRepository { recoveryClient() }.recover(session, "synthetic@example.invalid", "synthetic-password") }.exceptionOrNull()
        assertEquals("ACTUAL_PENDING_EDIT_REQUIRES_REVIEW", (failure as AuthRecoveryFailure).evidence?.rule)
        assertFalse(requests.any { it.second == "spray_tank_actuals" })
        unchanged(before)
        assertEquals(listOf(edited), SprayTankActualStore(fixture).pending())
        assertTrue(SessionStore(fixture).retentionGuard.isLocked)
        assertFalse(SessionStore(fixture).hasSession)
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
    @Test fun wrongAccountAndRevokedMembershipRemainBlockedWithAllStoresPopulated(): Unit = runBlocking {
        val session = populate(); session.clear(); val before = snapshot()
        val wrong = runCatching { AuthRecoveryRepository { recoveryClient(other) }.recover(session, "synthetic@example.invalid", "synthetic-password") }.exceptionOrNull()
        assertTrue(wrong is AuthRecoveryFailure)
        assertEquals(AuthRecoveryFailure.Stage.IDENTITY, (wrong as AuthRecoveryFailure).stage)
        assertFalse(requests.any { it.second == "pruning_seasons" })
        assertTrue(requests.any { it.second == "logout" })
        unchanged(before)
        assertTrue(session.retentionGuard.isLocked); assertFalse(session.hasSession)
        requests.clear()
        val revoked = runCatching { AuthRecoveryRepository { recoveryClient(member = false) }.recover(session, "synthetic@example.invalid", "synthetic-password") }.exceptionOrNull()
        assertTrue(revoked is AuthRecoveryFailure)
        assertEquals("PRUNING_VINEYARD_ACCESS_REVOKED", (revoked as AuthRecoveryFailure).evidence?.rule)
        assertFalse(requests.any { it.second == "pruning_seasons" })
        assertTrue(requests.any { it.second == "logout" })
        unchanged(before)
        assertTrue(session.retentionGuard.isLocked); assertFalse(session.hasSession)
    }
    @Test fun unknownChemicalStillRefusesIsolatedRecoveryWithEveryStorePopulated(): Unit = runBlocking {
        val session = populate()
        val chemicals = prefs("vinetrack_saved_chemicals_local")
        val old = codec.parseToJsonElement(chemicals.getString("$owner|$vineyard", null)!!).jsonArray
        val unknown = JsonArray(old.map { JsonObject(it.jsonObject + ("future_private_field" to JsonPrimitive("PRIVATE_SENTINEL"))) })
        check(chemicals.edit().putString("$owner|$vineyard", unknown.toString()).commit())
        session.clear()
        val before = snapshot()
        val failure = runCatching {
            AuthRecoveryRepository { recoveryClient() }.recover(session, "synthetic@example.invalid", "synthetic-password")
        }.exceptionOrNull()
        assertTrue(failure is AuthRecoveryFailure)
        assertEquals(AuthRecoveryFailure.Stage.RETAINED_EVIDENCE, (failure as AuthRecoveryFailure).stage)
        assertEquals("vinetrack_saved_chemicals_local", failure.evidence?.category)
        assertTrue(requests.any { it.second == "get_pruning_activity" })
        assertTrue(requests.any { it.second == "logout" })
        unchanged(before)
        assertTrue(SessionStore(fixture).retentionGuard.isLocked)
        assertFalse(SessionStore(fixture).hasSession)
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
