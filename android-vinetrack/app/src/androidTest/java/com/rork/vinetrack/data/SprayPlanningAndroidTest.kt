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
                        intent.resolve(10.0, 2.8, 1000.0))
                }
            }
        }
        compose.onNodeWithText("Standard Pass").assertIsNotSelected()
        compose.onNodeWithText("Over-Row").performClick().assertIsSelected()
        compose.onNodeWithContentDescription("Over-row boom with four heads treating both sides of two rows").assertExists()
        compose.onNodeWithText("Full Tank").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithText("Intended tank volume (L)").performScrollTo().performTextInput("1000")
        compose.onNodeWithText("Planned area (ha)").performScrollTo().performTextInput("2")
        compose.onNodeWithText("Planned area: ${fmt.formatArea(2.0)}").performScrollTo().assertExists()
        compose.onNodeWithText("Controller travel: ${fmt.formatVolumePer100Length(28.0)}").performScrollTo().assertExists()
        compose.onNodeWithText(SprayPlanningOperationalGate.MIGRATION_MESSAGE).performScrollTo().assertExists()
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
