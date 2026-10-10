package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class PinReconciliationCorrectionTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val local = Pin("local", "A", title = "offline", latitude = -34.123456789,
        longitude = 138.987654321, drivingRowNumber = 19.5, photoPath = "retained-photo")
    private val unrelated = Pin("unrelated", "A", title = "old")
    private fun write(entity: String, op: String, id: String, payload: String) =
        PendingWrite("operation-$id-$entity-$op", entity, op, payload, id, 1, 1)
    private fun edit(id: String = local.id) = write(PendingEntityType.PIN_EDIT, PendingOpType.UPDATE, id,
        json.encodeToString(PinEditSync.Payload.serializer(), PinEditSync.Payload(id, title = "edited", clientUpdatedAt = "capture")))

    @Test fun pendingEditRetainsOnlyItsDeletedRemoteTarget() {
        val remote = Pin("fresh", "A", title = "server update")
        val result = PendingPinReadOverlay.reconcile(listOf(remote), listOf(local, unrelated), listOf(edit()), "A")
        assertEquals(setOf("local", "fresh"), result.rows.map { it.id }.toSet())
        assertEquals("edited", result.rows.single { it.id == "local" }.title)
        assertEquals(local.latitude, result.rows.single { it.id == "local" }.latitude)
        assertEquals(local.photoPath, result.rows.single { it.id == "local" }.photoPath)
        assertEquals(setOf("local"), result.protectedRecordIds)
        assertTrue(result.unresolvedWriteIds.isEmpty())
    }

    @Test fun unknownOwnershipDoesNotHideIndependentServerUpdatesOrDeletions() {
        val unknown = write(PendingEntityType.CUSTOM_PIN, PendingOpType.CREATE, "unknown", "{}")
        val remote = local.copy(title = "server")
        val result = PendingPinReadOverlay.reconcile(listOf(remote), listOf(local, unrelated), listOf(unknown), "A")
        assertEquals(listOf(remote), result.rows)
        assertEquals(setOf(unknown.id), result.unresolvedWriteIds)
        assertTrue(result.protectedRecordIds.isEmpty())
        assertEquals("{}", unknown.payloadJson)
    }

    @Test fun undecodableKnownIntentProtectsOnlyExactLocalRecord() {
        val broken = write(PendingEntityType.PIN_EDIT, PendingOpType.UPDATE, local.id, "bad json")
        val result = PendingPinReadOverlay.reconcile(emptyList(), listOf(local, unrelated), listOf(broken), "A")
        assertEquals(listOf(local), result.rows)
        assertEquals(setOf(broken.id), result.unresolvedWriteIds)
        assertEquals(listOf(local), result.cacheRows)
    }

    @Test fun conflictingIdentityDoesNotApplyDeletionOrGuessOwnership() {
        val conflict = write(PendingEntityType.PIN, PendingOpType.DELETE, local.id, "{\"pinId\":\"unrelated\"}")
        val result = PendingPinReadOverlay.reconcile(listOf(unrelated), listOf(local), listOf(conflict), "A")
        assertEquals(setOf("local", "unrelated"), result.rows.map { it.id }.toSet())
        assertEquals(setOf(conflict.id), result.unresolvedWriteIds)
    }

    @Test fun createThenDependentEditCompletionAndDeleteUseFrozenCaptureOwnership() {
        val input = PinRepository.PinInput(id = "created", vineyardId = "A", latitude = local.latitude,
            longitude = local.longitude, drivingRowNumber = 19.5, createdAt = "captured")
        val create = write(PendingEntityType.PIN, PendingOpType.CREATE, "created",
            json.encodeToString(PinRepository.PinInput.serializer(), input))
        val completion = write(PendingEntityType.PIN, PendingOpType.UPDATE, "created",
            json.encodeToString(PinCompletionSync.Payload.serializer(), PinCompletionSync.Payload("created", true)))
        val result = PendingPinReadOverlay.reconcile(emptyList(), emptyList(), listOf(create, edit("created"), completion), "A")
        val pin = result.rows.single()
        assertEquals("edited", pin.title)
        assertTrue(pin.isCompleted)
        assertEquals(local.latitude, pin.latitude)
        assertEquals(19.5, pin.drivingRowNumber)
        assertEquals("captured", pin.createdAt)
        assertTrue(result.unresolvedWriteIds.isEmpty())
        val delete = write(PendingEntityType.PIN, PendingOpType.DELETE, "created", "{\"pinId\":\"created\"}")
        assertTrue(PendingPinReadOverlay.reconcile(emptyList(), emptyList(), listOf(create, edit("created"), completion, delete), "A").rows.isEmpty())
    }

    @Test fun queuedCustomAndManualCreatesReconstructWithoutExistingState() {
        val custom = CustomPinCreateParams("custom", "A", "custom title", "point", latitude = local.latitude,
            longitude = local.longitude, drivingRowNumber = 19.5, clientUpdatedAt = "captured")
        val manual = ManualIssueCreateParams("manual", "A", "manual title", "point", latitude = local.latitude,
            longitude = local.longitude, clientUpdatedAt = "captured")
        val writes = listOf(
            write(PendingEntityType.CUSTOM_PIN, PendingOpType.CREATE, "custom", json.encodeToString(CustomPinSync.QueuedOp.serializer(),
                CustomPinSync.QueuedOp(CustomPinSync.QueuedOp.KIND_PIN_CREATE, pinParams = custom))),
            write(PendingEntityType.MANUAL_ISSUE, PendingOpType.CREATE, "manual", json.encodeToString(ManualIssueSync.QueuedOp.serializer(),
                ManualIssueSync.QueuedOp(ManualIssueSync.QueuedOp.KIND_CREATE, createParams = manual))))
        val result = PendingPinReadOverlay.reconcile(emptyList(), emptyList(), writes, "A")
        assertEquals(setOf("custom", "manual"), result.rows.map { it.id }.toSet())
        assertTrue(result.rows.all { it.latitude == local.latitude && it.createdAt == "captured" })
        assertTrue(result.unresolvedWriteIds.isEmpty())
        assertTrue(PendingPinReadOverlay.reconcile(listOf(unrelated), emptyList(), writes, "B").rows.isEmpty())
    }

    @Test fun productionEnvelopesFromOtherVineyardDoNotSuppressRemoteDeletion() {
        val p = CustomPinCreateParams("custom", "B", "other", "point", clientUpdatedAt = "capture")
        val custom = write(PendingEntityType.CUSTOM_PIN, PendingOpType.CREATE, p.id,
            json.encodeToString(CustomPinSync.QueuedOp.serializer(), CustomPinSync.QueuedOp(CustomPinSync.QueuedOp.KIND_PIN_CREATE, pinParams = p)))
        val manual = write(PendingEntityType.MANUAL_ISSUE, PendingOpType.UPDATE, "other",
            json.encodeToString(ManualIssueSync.QueuedOp.serializer(), ManualIssueSync.QueuedOp(ManualIssueSync.QueuedOp.KIND_STATUS, status = "completed")))
        val result = PendingPinReadOverlay.reconcile(emptyList(), listOf(local, Pin("other", "B")), listOf(custom, manual), "A")
        assertTrue(result.rows.isEmpty())
        assertTrue(result.unresolvedWriteIds.isEmpty())
    }

    @Test fun remoteDeletionAndPendingIntentSurviveSerialisedRestart() {
        val writes = listOf(edit())
        val result = PendingPinReadOverlay.reconcile(emptyList(), listOf(local, unrelated), writes, "A")
        val persistedRows = json.encodeToString(ListSerializer(Pin.serializer()), result.cacheRows)
        val queue = json.encodeToString(ListSerializer(PendingWrite.serializer()), writes)
        repeat(3) {
            val restored = json.decodeFromString(ListSerializer(Pin.serializer()), persistedRows)
            val restoredQueue = json.decodeFromString(ListSerializer(PendingWrite.serializer()), queue)
            val restarted = PendingPinReadOverlay.reconcile(restored, emptyList(), restoredQueue, "A")
            assertEquals(listOf(local.copy(title = "edited", clientUpdatedAt = "capture")), restarted.rows)
            assertEquals(writes, restoredQueue)
            assertEquals(local.photoPath, restarted.rows.single().photoPath)
        }
    }

    @Test fun delayedResponseUsesLatestCreateAndDeleteIntent() = runBlocking {
        val response = CompletableDeferred<List<Pin>>()
        val pending = mutableListOf<PendingWrite>()
        val refresh = async(start = CoroutineStart.UNDISPATCHED) {
            PendingPinReadOverlay.reconcile(response.await(), listOf(local, unrelated), pending.toList(), "A")
        }
        pending += write(PendingEntityType.PIN, PendingOpType.DELETE, local.id, "{\"pinId\":\"local\"}")
        val input = PinRepository.PinInput("new", "A", latitude = local.latitude, longitude = local.longitude)
        pending += write(PendingEntityType.PIN, PendingOpType.CREATE, "new", json.encodeToString(PinRepository.PinInput.serializer(), input))
        response.complete(listOf(local, unrelated.copy(title = "updated")))
        val result = refresh.await()
        assertEquals(setOf("new", "unrelated"), result.rows.map { it.id }.toSet())
        assertEquals("updated", result.rows.single { it.id == "unrelated" }.title)
        assertEquals(2, pending.size)
    }

    @Test fun retryTimestampsAndLaterEditsCannotResurrectPendingDeletion() {
        val input = PinRepository.PinInput("local", "A", latitude = local.latitude, longitude = local.longitude)
        val create = write(PendingEntityType.PIN, PendingOpType.CREATE, local.id,
            json.encodeToString(PinRepository.PinInput.serializer(), input)).copy(createdAt = 1, updatedAt = 100)
        val delete = write(PendingEntityType.PIN, PendingOpType.DELETE, local.id,
            "{\"pinId\":\"local\"}").copy(createdAt = 2, updatedAt = 2)
        val completion = write(PendingEntityType.PIN, PendingOpType.UPDATE, local.id,
            "{\"pinId\":\"local\",\"isCompleted\":true}").copy(createdAt = 3, updatedAt = 3)
        val laterEdit = edit().copy(createdAt = 4, updatedAt = 200)
        val writes = listOf(delete, laterEdit, completion, create)
        val result = PendingPinReadOverlay.reconcile(emptyList(), listOf(local, unrelated), writes, "A")
        assertTrue(result.rows.isEmpty())
        assertTrue(result.unresolvedWriteIds.isEmpty())
        assertEquals(listOf(local), result.cacheRows)
        assertEquals(100L, create.updatedAt)
    }

    @Test fun blankVineyardCreateCannotEstablishDependentOwnership() {
        val create = write(PendingEntityType.PIN, PendingOpType.CREATE, "unknown",
            json.encodeToString(PinRepository.PinInput.serializer(), PinRepository.PinInput("unknown", "")))
        val edit = edit("unknown")
        val result = PendingPinReadOverlay.reconcile(listOf(unrelated), emptyList(), listOf(create, edit), "A")
        assertEquals(listOf(unrelated), result.rows)
        assertEquals(setOf(create.id, edit.id), result.unresolvedWriteIds)
    }

    @Test fun duplicateIdentityAcrossVineyardsCannotAuthoriseAnOverlay() {
        val result = PendingPinReadOverlay.reconcile(listOf(local.copy(title = "remote")),
            listOf(local, local.copy(vineyardId = "B")), listOf(edit()), "A")
        assertEquals(listOf(local), result.rows)
        assertEquals(setOf(edit().id), result.unresolvedWriteIds)
    }
}
