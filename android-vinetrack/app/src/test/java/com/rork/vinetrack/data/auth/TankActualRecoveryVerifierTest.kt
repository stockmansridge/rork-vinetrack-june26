package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.SprayTankActualChemical
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TankActualRecoveryVerifierTest {
    private val owner = "00000000-0000-4000-8000-0000000000a1"
    private val scope = "00000000-0000-4000-8000-0000000000b2"
    private val codec = Json { encodeDefaults = true }
    private val history = SprayTankActual("history", scope, "spray", "trip", "session", 1, 343.8,
        listOf(SprayTankActualChemical("line", name = "Product", actualAmountBase = 700.0, unit = "Kg")),
        "2026-11-01T00:00:00Z", "00000000-0000-4000-8000-0000000000c3",
        "2026-11-01T01:00:00Z", 2, "2026-11-01T01:00:00Z")
    private fun values(rows: List<SprayTankActual> = listOf(history), pending: List<String> = emptyList()) = mapOf("cache" to buildJsonObject {
        put("records", codec.encodeToJsonElement(ListSerializer(SprayTankActual.serializer()), rows))
        put("pendingIds", JsonArray(pending.map(::JsonPrimitive)))
        put("inputDrafts", JsonArray(emptyList()))
    }.toString())
    private fun response(rows: List<SprayTankActual>) = codec.encodeToJsonElement(ListSerializer(SprayTankActual.serializer()), rows)
    private fun refuses(rule: String, block: () -> Unit) {
        val failure = runCatching(block).exceptionOrNull()
        assertTrue("Expected safe refusal, got ${failure?.javaClass?.simpleName}", failure is EvidenceContractFailure)
        assertEquals(rule, (failure as EvidenceContractFailure).diagnostic.rule)
    }
    @Test fun sharedCorrectedHistoryRequiresExactServerProofWithoutChangingCache() = runBlocking {
        val retained = values(); val before = retained.toMap()
        refuses("ACTUAL_SERVER_VERIFICATION_REQUIRED") { TankActualRecoveryVerifier.inspectWithoutProof(retained, owner) }
        val proof = TankActualRecoveryVerifier.verify(owner, 7, retained, setOf(scope)) { path ->
            assertTrue(path.startsWith("spray_tank_actuals?select=${TankActualRecoveryVerifier.COLUMNS}&"))
            assertTrue(path.endsWith("&deleted_at=is.null&limit=2"))
            response(listOf(history.copy(confirmedAt = "2026-11-01T00:00:00+00:00")))
        }
        assertEquals(setOf(scope), proof.inspect(retained, owner, 7)); assertEquals(before, retained)
    }
    @Test fun changedEpochOwnerOrPreferenceMapInvalidatesProof() = runBlocking {
        val retained = values()
        val proof = TankActualRecoveryVerifier.verify(owner, 7, retained, setOf(scope)) { response(listOf(history)) }
        refuses("ACTUAL_RECOVERY_EVIDENCE_CHANGED") { proof.inspect(retained, owner, 8) }
        refuses("ACTUAL_RECOVERY_EVIDENCE_CHANGED") { proof.inspect(retained, "other", 7) }
        refuses("ACTUAL_RECOVERY_EVIDENCE_CHANGED") { proof.inspect(retained + ("unknown" to "private"), owner, 7) }
    }
    @Test fun missingDuplicateOrConflictingServerRowsNeverGrantAdmission() = runBlocking {
        for (rows in listOf(emptyList(), listOf(history, history))) {
            refuses("ACTUAL_SERVER_HISTORY_NOT_VERIFIED") { runBlocking {
                TankActualRecoveryVerifier.verify(owner, 7, values(), setOf(scope)) { response(rows) }
            } }
        }
        for (row in listOf(history.copy(waterVolumeL = 344.0), history.copy(confirmedBy = owner), history.copy(correctionVersion = 1))) {
            refuses("ACTUAL_SERVER_HISTORY_MISMATCH") { runBlocking {
                TankActualRecoveryVerifier.verify(owner, 7, values(), setOf(scope)) { response(listOf(row)) }
            } }
        }
    }
    @Test fun currentMembershipRequiredBeforeAnyHistoryRequest() {
        refuses("ACTUAL_VINEYARD_ACCESS_REFUSED") { runBlocking {
            TankActualRecoveryVerifier.verify(owner, 7, values(), emptySet()) { error("Must not read") }
        } }
    }
    @Test fun pendingConfirmationHasIndependentAuthorshipAndNeverNeedsHistoryRequest() = runBlocking {
        val original = history.copy(confirmedBy = owner, correctionVersion = 0, lastCorrectedAt = null, clientUpdatedAt = history.confirmedAt)
        val retained = values(listOf(original), listOf(original.id))
        val proof = TankActualRecoveryVerifier.verify(owner, 7, retained, setOf(scope)) { error("Pending must not be acknowledged") }
        assertEquals(setOf(scope), proof.inspect(retained, owner, 7))
        refuses("ACTUAL_PENDING_OWNER_MISMATCH") { TankActualRecoveryVerifier.inspectWithoutProof(values(listOf(original.copy(confirmedBy = history.confirmedBy)), listOf(original.id)), owner) }
        refuses("ACTUAL_PENDING_EDIT_REQUIRES_REVIEW") { TankActualRecoveryVerifier.inspectWithoutProof(values(listOf(history.copy(confirmedBy = owner)), listOf(history.id)), owner) }
    }
    @Test fun duplicateLocalRowsAndOrphanPendingIdsRemainHeld() {
        refuses("ACTUAL_AMBIGUOUS_IDENTITY") { TankActualRecoveryVerifier.inspectWithoutProof(values(listOf(history,history)), owner) }
        refuses("ACTUAL_AMBIGUOUS_IDENTITY") { TankActualRecoveryVerifier.inspectWithoutProof(values(pending = listOf("missing")), owner) }
    }
    @Test fun unknownLocalAndServerFieldsStayProtected() {
        val local = values().getValue("cache").replace("\"records\":", "\"unknown\":true,\"records\":")
        refuses("ACTUAL_INVALID_LOCAL_SCHEMA") { TankActualRecoveryVerifier.inspectWithoutProof(mapOf("cache" to local), owner) }
        refuses("ACTUAL_SERVER_RESPONSE_SCHEMA") { runBlocking {
            TankActualRecoveryVerifier.verify(owner, 7, values(), setOf(scope)) {
                JsonArray(listOf(JsonObject(codec.encodeToJsonElement(SprayTankActual.serializer(), history).jsonObject + ("unknown" to JsonPrimitive(true)))))
            }
        } }
    }
    @Test fun invalidTimestampsHaveFixedLocalOrServerDiagnostics() {
        refuses("ACTUAL_LOCAL_TIMESTAMP_SCHEMA") { TankActualRecoveryVerifier.inspectWithoutProof(values(listOf(history.copy(confirmedAt = "PRIVATE"))), owner) }
        refuses("ACTUAL_SERVER_TIMESTAMP_SCHEMA") { runBlocking {
            TankActualRecoveryVerifier.verify(owner, 7, values(), setOf(scope)) { response(listOf(history.copy(confirmedAt = "PRIVATE"))) }
        } }
    }
}
