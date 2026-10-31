package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.RetainedPlanningContract
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class RetainedPlanningContractTest {
    private val author = "11111111-1111-4111-8111-111111111111"
    private val json = Json { encodeDefaults = true }
    private fun draft() = WorkTaskPlanningDraft(null, "vineyard", author, date = "2026-11-05", taskType = "pruning",
        assignmentName = "Greg Horner", durationText = "1", notes = "Need bamboo and loose tie onto it", creationId = "original")
    private fun intent() = WorkTaskWriteContract.planning(draft(), "original", LocalDate.parse("2026-11-05"),
        Instant.parse("2026-10-31T12:00:00Z"), null, "", 0.0)
    private fun values(): MutableMap<String, String> {
        val draft = draft()
        val intent = intent()
        return mutableMapOf(draft.persistenceKey to json.encodeToString(WorkTaskPlanningDraft.serializer(), draft),
            intent.persistenceKey to json.encodeToString(WorkTaskWriteIntent.serializer(), intent),
            "${intent.persistenceKey}-lifecycle" to json.encodeToString(TaskWriteRecovery.serializer(), TaskWriteRecovery(intent)))
    }
    @Test fun originalDraftAndUncertainIntentAreReadOnlyAdmissionNotAcknowledgement() {
        val values = values()
        val before = values.toMap()
        assertEquals(setOf("vineyard"), RetainedPlanningContract.inspect(values, author))
        assertEquals(before, values)
        val state = json.decodeFromString(TaskWriteRecovery.serializer(), values.getValue("${intent().persistenceKey}-lifecycle"))
        assertEquals(TaskWritePhase.UNKNOWN, state.phase)
        assertFalse(state.original.acknowledged)
        assertNull(state.confirmed)
    }
    @Test fun originalByteHistoryKeyIsValidatedWithoutRewriting() {
        val intent = intent()
        val raw = json.encodeToString(WorkTaskWriteIntent.serializer(), intent)
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
        assertEquals(setOf("vineyard"), RetainedPlanningContract.inspect(mapOf("${intent.persistenceKey}-history-$hash" to raw), author))
        assertTrue(runCatching { RetainedPlanningContract.inspect(mapOf("${intent.persistenceKey}-history-wrong" to raw), author) }.isFailure)
    }
    @Test fun foreignMalformedUnknownAndConflictingLifecycleRemainHeld() {
        val values = values()
        assertTrue(runCatching { RetainedPlanningContract.inspect(values, "22222222-2222-4222-8222-222222222222") }.isFailure)
        assertTrue(runCatching { RetainedPlanningContract.inspect(values, null) }.isFailure)
        assertTrue(runCatching { RetainedPlanningContract.inspect(values + (draft().persistenceKey to "unreadable"), author) }.isFailure)
        assertTrue(runCatching { RetainedPlanningContract.inspect(values + ("unreviewed-key" to "{}"), author) }.isFailure)
        val conflict = TaskWriteRecovery(intent().copy(taskId = "replacement"))
        assertTrue(runCatching { RetainedPlanningContract.inspect(values + ("${intent().persistenceKey}-lifecycle" to
            json.encodeToString(TaskWriteRecovery.serializer(), conflict)), author) }.isFailure)
        val mismatched = intent().copy(payload = JsonObject(intent().payload + ("vineyard_id" to JsonPrimitive("foreign"))))
        assertTrue(runCatching { RetainedPlanningContract.inspect(mapOf(mismatched.persistenceKey to
            json.encodeToString(WorkTaskWriteIntent.serializer(), mismatched)), author) }.isFailure)
    }
}
