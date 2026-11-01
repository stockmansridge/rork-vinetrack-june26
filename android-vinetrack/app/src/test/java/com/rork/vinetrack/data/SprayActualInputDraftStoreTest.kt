package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import org.junit.Assert.*
import org.junit.Test

class SprayActualInputDraftStoreTest {
    private val draft = SprayActualInputDraft("review:" + "a".repeat(64), "owner", "vineyard", mapOf("water" to "300", "chemical:0" to "0.75"))
    private fun actual() = SprayTankActual("actual", "vineyard", "record", "trip", "session", 1, 300.0,
        listOf(SprayTankActualChemical("actual-chemical", "chemical", null, "Product", 750.0, "Kg")), "2026-11-01T01:00:00Z", "owner")

    @Test fun oldCacheLoadsAndDraftSurvivesRecordAndSyncWrites() {
        var bytes: String? = """{"records":[],"pendingIds":[]}"""
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        assertTrue(store.hasReadableSyncEvidence())
        assertTrue(store.saveInputDraft(draft))
        val actual = actual()
        assertTrue(store.save(actual))
        assertTrue(store.markSyncedIfCurrent(actual))
        assertTrue(store.mergeRemote(listOf(actual.copy(clientUpdatedAt = "2026-11-01T02:00:00Z"))))
        val restarted = SprayTankActualStore({ bytes }, { bytes = it; true })
        assertEquals(draft, restarted.inputDraft("owner", "vineyard", draft.key))
        assertNull(restarted.inputDraft("other-owner", "vineyard", draft.key))
        assertNull(restarted.inputDraft("owner", "other-vineyard", draft.key))
    }

    @Test fun failedWriteKeepsPreviousEnteredValues() {
        var bytes: String? = null
        var fail = false
        val store = SprayTankActualStore({ bytes }, { if (fail) false else { bytes = it; true } })
        assertTrue(store.saveInputDraft(draft))
        fail = true
        assertFalse(store.saveInputDraft(draft.copy(text = mapOf("water" to "450"))))
        assertEquals(draft, store.inputDraft("owner", "vineyard", draft.key))
    }

    @Test fun staleAcknowledgementCannotClearNewerEdit() {
        var bytes: String? = null
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        assertTrue(store.saveInputDraft(draft))
        val newer = draft.copy(text = draft.text + ("water" to "310"))
        assertTrue(store.saveInputDraft(newer))
        assertFalse(store.clearInputDraft(draft))
        assertEquals(newer, store.inputDraft("owner", "vineyard", draft.key))
        assertTrue(store.clearInputDraft(newer))
        assertNull(store.inputDraft("owner", "vineyard", draft.key))
    }

    @Test fun exactTripDraftAndMalformedIdentitiesAreDistinguished() {
        var bytes: String? = null
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        val exact = draft.copy(key = "tank:trip:tank", tripId = "trip", tankId = "tank", sprayRecordId = "record")
        assertTrue(store.saveInputDraft(exact))
        assertFalse(store.saveInputDraft(exact.copy(tankId = null)))
        assertFalse(store.saveInputDraft(exact.copy(key = "tank:another:tank")))
        assertFalse(store.saveInputDraft(draft.copy(key = "review:invalid")))
        assertFalse(store.saveInputDraft(draft.copy(ownerUserId = "")))
    }

    @Test fun malformedCacheIsPreservedWhenNewInputCannotBeSafelyMerged() {
        val original = """{"records":"broken","pendingIds":[]}"""
        var bytes: String? = original
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        assertFalse(store.saveInputDraft(draft))
        assertEquals(original, bytes)
    }
}
