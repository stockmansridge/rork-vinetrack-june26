package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class OfflineQuickActionsTest {
    private val json = Json { encodeDefaults = true }

    @Test fun verifiedOwnerSupervisorAndOperatorSnapshotsNeverCrossScope() {
        for (role in listOf("owner", "manager", "supervisor", "operator")) {
            val a = QuickActionOfflineSnapshot("user", "A", 3,
                listOf(VineyardMember(vineyardId = "A", userId = "user", role = role)),
                ButtonConfigRepository.LauncherButtons(repair = listOf(LauncherButton(name = "Original", vineyardId = "A"))))
            val reopened = json.decodeFromString<QuickActionOfflineSnapshot>(json.encodeToString(QuickActionOfflineSnapshot.serializer(), a))
            assertEquals(a, reopened)
            assertTrue(reopened.matches("user", "A", 3))
            assertFalse(reopened.matches("other", "A", 3))
            assertFalse(reopened.matches("user", "B", 3))
            assertFalse(reopened.matches("user", "A", 4))
        }
    }

    @Test fun delayedLoadsCannotCrossAccountVineyardReauthenticationOrRoundTripSelection() {
        val original = QuickActionLoadScope("user", "A", 1, 2, 3)
        assertTrue(original.isCurrent(original, true))
        assertFalse(original.isCurrent(original, false))
        for (changed in listOf(original.copy(userId = "other"), original.copy(vineyardId = "B"),
            original.copy(identityEpoch = 2), original.copy(selectionEpoch = 4), original.copy(generation = 5))) {
            assertFalse(original.isCurrent(changed, true))
        }
    }

    @Test fun confirmedEmptyAndUnknownConfigurationStayDistinct() {
        assertNull(QuickActionOfflineSnapshot("user", "A", 1).buttons)
        val confirmedEmpty = QuickActionOfflineSnapshot("user", "A", 1, members = emptyList(),
            buttons = ButtonConfigRepository.LauncherButtons())
        val restored = json.decodeFromString<QuickActionOfflineSnapshot>(json.encodeToString(QuickActionOfflineSnapshot.serializer(), confirmedEmpty))
        assertNotNull(restored.buttons)
        assertTrue(restored.members!!.isEmpty())
    }

    @Test fun twoVineyardPinsKeepOriginalPayloadAcrossRestartAndReplayOnce() = runBlocking {
        val disk = InMemoryPendingWriteStore()
        val initial = PendingWriteRepository(disk)
        val inputs = listOf("A", "B").map { vineyard -> PinRepository.PinInput(
            id = "pin-$vineyard", vineyardId = vineyard, title = "Repair", mode = "Repairs",
            notes = "Retained notes", latitude = -34.0, longitude = 138.0, createdBy = "user",
            locationScope = "point", createdAt = "2026-10-16T08:00:00Z") }
        inputs.forEach { PinCreateSync(initial).enqueue(it) }
        val reopened = PendingWriteRepository(disk)
        reopened.configureReplayScope { PendingWriteRepository.ReplayScope("user", 1) }
        val records = mutableMapOf<String, Pin>()
        var calls = 0
        val sync = PinCreateSync(reopened, createRemote = { input ->
            calls++
            assertEquals(inputs.first { it.id == input.id }, input)
            Pin(input.id!!, input.vineyardId, notes = input.notes, latitude = input.latitude,
                longitude = input.longitude, createdBy = input.createdBy).also { records[it.id] = it }
        })
        sync.replayAll { }
        sync.replayAll { }
        assertEquals(2, calls)
        assertEquals(setOf("pin-A", "pin-B"), records.keys)
        assertTrue(PendingWriteRepository(disk).list().isEmpty())
    }

    @Test fun foreignAccountAndWrongServerIdentityRemainPending() = runBlocking {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        pending.configureReplayScope { PendingWriteRepository.ReplayScope("other", 2) }
        PinCreateSync(pending).enqueue(PinRepository.PinInput("original", "A", createdBy = "user"))
        var calls = 0
        PinCreateSync(pending, createRemote = { calls++; Pin("wrong", "B") }).replayAll { fail("No publication") }
        assertEquals(0, calls)
        assertEquals(PendingWriteStatus.BLOCKED, pending.list().single().status)
        val own = PendingWriteRepository(InMemoryPendingWriteStore())
        own.configureReplayScope { PendingWriteRepository.ReplayScope("user", 1) }
        PinCreateSync(own).enqueue(PinRepository.PinInput("original", "A", createdBy = "user"))
        PinCreateSync(own, createRemote = { Pin("wrong", "B") }).replayAll { fail("No publication") }
        assertEquals("original", own.list().single().clientId)
        assertEquals(PendingWriteStatus.BLOCKED, own.list().single().status)
    }

    @Test fun interruptedPinCreateRestartsWithOriginalIdAndPayload() {
        val disk = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(disk)
        val original = PinCreateSync(pending).enqueue(PinRepository.PinInput("original", "A", createdBy = "user"))
        pending.updateStatus(original.id, PendingWriteStatus.IN_PROGRESS)
        val restored = PendingWriteRepository(disk).list().single()
        assertEquals(original.id, restored.id)
        assertEquals(original.payloadJson, restored.payloadJson)
        assertEquals(PendingWriteStatus.FAILED, restored.status)
    }
}
