package com.rork.vinetrack.data

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.ui.components.SprayPlanningCards
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Synthetic inline-controls and replay admission tests; no live-service calls. */
class SprayPlanningAndroidTest {
    @get:Rule val compose = createComposeRule()
    private var transport: io.ktor.client.HttpClient? = null

    @org.junit.Before fun installNoNetworkFallback() {
        transport = io.ktor.client.HttpClient(io.ktor.client.engine.mock.MockEngine {
            error("Planning acceptance must not reach transport; no live fallback")
        })
        SupabaseClient.installInstrumentationTransport(transport)
    }

    @org.junit.After fun removeSyntheticTransport() {
        SupabaseClient.installInstrumentationTransport(null)
        transport?.close()
    }

    @Test fun configurationAndFullTankControlsProduceLiveResultsWithoutOperationalApproval() {
        val fmt = RegionFormatter()
        compose.setContent {
            var pass by remember { mutableStateOf<SprayPassConfiguration?>(null) }
            var method by remember { mutableStateOf(SprayPlanningMethod.BY_AREA) }
            var specification by remember { mutableStateOf(SprayFullTankSpecification.TARGET_AREA) }
            var tank by remember { mutableStateOf("") }
            var area by remember { mutableStateOf("") }
            var rate by remember { mutableStateOf("") }
            val intent = SprayPlanningIntent(pass, method, specification, tank.toDoubleOrNull(), area.toDoubleOrNull(), rate.toDoubleOrNull())
            MaterialTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    SprayPlanningCards(pass, { pass = it }, method, { method = it }, specification, { specification = it },
                        tank, { tank = it }, area, { area = it }, rate, { rate = it }, fmt,
                        intent.resolve(10.0, 2.8, 500.0))
                }
            }
        }
        compose.onNodeWithText("Standard Pass").assertIsNotSelected()
        compose.onNodeWithText("Over-Row").performClick().assertIsSelected()
        compose.onNodeWithContentDescription("Over-row boom with four heads treating both sides of two rows").assertExists()
        compose.onNodeWithText("Full Tank").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithText("Intended tank volume (L)").performScrollTo().performTextInput("1500")
        compose.onNodeWithText("Planned area (ha)").performScrollTo().performTextInput("3")
        compose.onNodeWithText("Planned area: ${fmt.formatArea(3.0)}").performScrollTo().assertExists()
        compose.onNodeWithText("Controller travel: ${fmt.formatVolumePer100Length(28.0)}").performScrollTo().assertExists()
        compose.onNodeWithText("Intended water: ${fmt.formatVolume(1500.0)}").performScrollTo().assertExists()
        compose.onNodeWithText("Application rate: ${fmt.formatVolumePerArea(500.0)}").performScrollTo().assertExists()
        compose.onNodeWithText("Standard Pass").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithContentDescription("Standard sprayer between two rows, treating adjacent half faces").assertExists()
        compose.onNodeWithText("Controller travel: ${fmt.formatVolumePer100Length(14.0)}").performScrollTo().assertExists()
        compose.onNodeWithText("Calibrated rate").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithText("Calibrated rate (${fmt.volumePerAreaUnit})").performScrollTo().performTextInput("500")
        compose.onNodeWithText("Planned area: ${fmt.formatArea(3.0)}").performScrollTo().assertExists()
        compose.onNodeWithText("Target area").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithText("Planned area (ha)").assertTextContains("3")
        compose.onNodeWithText(SprayPlanningOperationalGate.MIGRATION_MESSAGE).performScrollTo().assertExists()
    }

    @Test fun realPreferenceRecreationPreservesPlanningTypingIdentityAndBlockedRetryState() = runBlocking {
        kotlinx.coroutines.withTimeout(20_000) {
            val base = InstrumentationRegistry.getInstrumentation().targetContext
            val prefix = "spray_planning_${java.util.UUID.randomUUID()}_"
            val names = linkedSetOf<String>()
            val context = object : android.content.ContextWrapper(base) {
                override fun getApplicationContext(): android.content.Context = this
                override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences {
                    names.add(name)
                    return base.getSharedPreferences(prefix + name, mode)
                }
            }
            try {
                val owner = "22222222-2222-4222-8222-222222222222"
                val session = com.rork.vinetrack.data.auth.SessionStore(context)
                session.save("synthetic-access", "synthetic-refresh", owner, null)
                val intent = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.FULL_TANK,
                    SprayFullTankSpecification.TARGET_AREA, 1500.0, 3.0,
                    inputProvenance = SprayPlanningInputProvenance("1,500", "3.00", "28.00", "litres", "hectares", "100m_travel", "NZ"))
                val geometry = SprayApplicationSnapshot(grossAreaHa = 10.0, planningIntent = intent,
                    planningResolution = intent.resolve(10.0, 2.8, 500.0))
                val json = Json { encodeDefaults = true }
                val payload = SprayRecordUpdateSync.Payload("original-planning", "2026-10-13", "2026-10-13",
                    notes = "Retained notes", applicationGeometry = geometry, clientUpdatedAt = "original-revision")
                val bytes = json.encodeToString(SprayRecordUpdateSync.Payload.serializer(), payload)
                val pending = PendingWriteRepository(PendingWriteStore(context))
                val original = pending.enqueue(PendingEntityType.SPRAY_RECORD, PendingOpType.UPDATE, bytes, payload.id)
                pending.incrementAttempt(original.id)
                pending.incrementAttempt(original.id)
                val before = PendingWriteRepository(PendingWriteStore(context)).list().single()
                assertEquals(payload, json.decodeFromString(SprayRecordUpdateSync.Payload.serializer(), before.payloadJson))
                assertEquals(intent.inputProvenance, json.decodeFromString(SprayRecordUpdateSync.Payload.serializer(), before.payloadJson).applicationGeometry?.planningIntent?.inputProvenance)
                var publications = 0
                val reopened = PendingWriteRepository(PendingWriteStore(context))
                SprayRecordUpdateSync(reopened).replayAll { publications++ }
                val blocked = PendingWriteRepository(PendingWriteStore(context)).list().single()
                assertTrue(blocked.updatedAt >= before.updatedAt)
                assertEquals(before.copy(updatedAt = blocked.updatedAt, status = PendingWriteStatus.BLOCKED,
                    lastError = SprayPlanningOperationalGate.MIGRATION_MESSAGE), blocked)
                SprayRecordUpdateSync(PendingWriteRepository(PendingWriteStore(context))).replayAll { publications++ }
                assertEquals(blocked, PendingWriteRepository(PendingWriteStore(context)).list().single())
                assertEquals(0, publications)
                val concentrated = SprayRecordRepository.SprayInput(date = "2026-10-13", startTime = "2026-10-13",
                    temperature = null, windSpeed = null, windDirection = null, humidity = null, sprayReference = null,
                    notes = null, numberOfFansJets = null, averageSpeed = null, equipmentType = null, tractor = null,
                    tractorGear = null, machineId = null, sprayEquipmentId = null, operationType = null, tripId = null,
                    tanks = listOf(SprayTank(id = "tank", concentrationFactor = 1.426,
                        chemicals = listOf(SprayChemical("line", name = "Unverified concentrate", ratePer100L = 100.0)))))
                assertTrue(runCatching { SprayRecordUpdateSync(reopened).enqueue("must-not-enqueue", concentrated, "revision") }.exceptionOrNull() is IllegalStateException)
                assertEquals(listOf(blocked), PendingWriteRepository(PendingWriteStore(context)).list())
            } finally {
                names.forEach { base.deleteSharedPreferences(prefix + it) }
            }
        }
    }

    @Test fun createReplayBlocksUndeployedPlanningAndPreservesOriginalPayload() = runBlocking {
        val snapshot = SprayApplicationSnapshot(planningIntent = SprayPlanningIntent(configuration = SprayPassConfiguration.OVER_ROW))
        val payload = SprayRecordCreateSync.Payload("original", "vineyard", "2026-10-12", "2026-10-12", applicationGeometry = snapshot, clientUpdatedAt = "original-revision")
        val json = Json { encodeDefaults = true }
        val bytes = json.encodeToString(SprayRecordCreateSync.Payload.serializer(), payload)
        val disk = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(disk)
        val queued = pending.enqueue(PendingEntityType.SPRAY_RECORD, PendingOpType.CREATE, bytes, "original")
        val repository = SprayRecordRepository(com.rork.vinetrack.data.auth.SessionStore(InstrumentationRegistry.getInstrumentation().targetContext))
        var published = false
        SprayRecordCreateSync(repository, pending).replayAll { published = true }
        val restored = PendingWriteRepository(disk).list().single()
        assertFalse(published)
        assertEquals(queued.id, restored.id)
        assertEquals(bytes, restored.payloadJson)
        assertEquals(PendingWriteStatus.BLOCKED, restored.status)
        assertEquals(0, restored.attemptCount)
    }

    @Test fun clearedPlanningSurvivesFileStoreRecreationAndReplayKeepsExactBytes() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = java.io.File.createTempFile("spray-clear-preview-", ".json", context.cacheDir)
        val json = Json { encodeDefaults = true }
        val serializer = kotlinx.serialization.builtins.ListSerializer(PendingWrite.serializer())
        fun fileStore(): PendingWriteStoring = object : PendingWriteStoring {
            override fun load(): List<PendingWrite> = if (file.length() == 0L) emptyList() else json.decodeFromString(serializer, file.readText())
            override fun save(writes: List<PendingWrite>): Boolean {
                java.io.FileOutputStream(file).use { stream ->
                    stream.write(json.encodeToString(serializer, writes).toByteArray())
                    stream.fd.sync()
                }
                return true
            }
            override fun clear(): Boolean = save(emptyList())
        }
        try {
            val snapshot = SprayApplicationSnapshot(grossAreaHa = 10.0, planningIntent = SprayPlanningIntent(configuration = SprayPassConfiguration.OVER_ROW)).clearingPlanning()
            val payload = SprayRecordUpdateSync.Payload("original", "2026-10-13", "2026-10-13", notes = "Unrelated notes", applicationGeometry = snapshot, clientUpdatedAt = "original-revision")
            val bytes = json.encodeToString(SprayRecordUpdateSync.Payload.serializer(), payload)
            // Seed pre-existing evidence only; ordinary enqueue must remain disabled.
            val original = PendingWriteRepository(fileStore()).enqueue(PendingEntityType.SPRAY_RECORD, PendingOpType.UPDATE, bytes, "original")
            val reopened = PendingWriteRepository(fileStore())
            val restoredPayload = json.decodeFromString(SprayRecordUpdateSync.Payload.serializer(), reopened.list().single().payloadJson)
            assertEquals(true, restoredPayload.applicationGeometry?.planningFieldsCleared)
            assertEquals("Unrelated notes", restoredPayload.notes)
            var published = false
            SprayRecordUpdateSync(reopened).replayAll { published = true }
            val retained = PendingWriteRepository(fileStore()).list().single()
            assertFalse(published)
            assertEquals(original.id, retained.id)
            assertEquals(bytes, retained.payloadJson)
            assertEquals(PendingWriteStatus.BLOCKED, retained.status)
            assertEquals(0, retained.attemptCount)
            assertEquals(SprayPlanningOperationalGate.MIGRATION_MESSAGE, retained.lastError)
        } finally { file.delete() }
    }

    @Test fun concentrateReplayBlocksEvenWithoutNewConfiguration() = runBlocking {
        val tank = SprayTank(id = "tank", concentrationFactor = 2.0, chemicals = listOf(SprayChemical("chemical", ratePer100L = 100.0)))
        val payload = SprayRecordUpdateSync.Payload("original", "2026-10-12", "2026-10-12", tanks = listOf(tank), clientUpdatedAt = "original-revision")
        val json = Json { encodeDefaults = true }
        val bytes = json.encodeToString(SprayRecordUpdateSync.Payload.serializer(), payload)
        val disk = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(disk)
        pending.enqueue(PendingEntityType.SPRAY_RECORD, PendingOpType.UPDATE, bytes, "original")
        var published = false
        SprayRecordUpdateSync(pending).replayAll { published = true }
        val restored = PendingWriteRepository(disk).list().single()
        assertFalse(published)
        assertEquals(bytes, restored.payloadJson)
        assertEquals(PendingWriteStatus.BLOCKED, restored.status)
        assertEquals(SprayPlanningOperationalGate.CONCENTRATE_MESSAGE, restored.lastError)
    }
}
