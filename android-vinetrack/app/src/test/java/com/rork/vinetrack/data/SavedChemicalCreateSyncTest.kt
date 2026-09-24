package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalSearchV2Duplicate
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedChemicalCreateSyncTest {
    private val repository = SavedChemicalRepository()
    private val pendingStore = InMemoryPendingWriteStore()
    private val local = object : SavedChemicalLocalStoring {
        val rows = mutableMapOf<String, List<SavedChemical>>()
        override fun load(userId: String, vineyardId: String): List<SavedChemical> = rows["$userId|$vineyardId"].orEmpty()
        override fun save(userId: String, vineyardId: String, rows: List<SavedChemical>): Boolean {
            this.rows["$userId|$vineyardId"] = rows
            return true
        }
    }
    private val input = SavedChemicalRepository.ChemicalInput(
        name = "Example Fungicide", unit = "Litres", ratePerHa = 2.0, rates = emptyList(),
        activeIngredient = "Example active", chemicalGroup = "3", use = "Grapevines", problem = "Mildew",
        manufacturer = "Grower", notes = "Keep cool", modeOfAction = null, labelUrl = "https://example.org/label",
        productUrl = null, purchase = null, productCategory = "fungicide", productForm = "liquid",
        entrySource = "manual_v2",
    )

    private fun coordinator(
        upload: suspend (SavedChemicalRepository.ChemicalInsert) -> SavedChemical = { throw IllegalStateException("offline") },
        find: suspend (String) -> SavedChemical? = { null },
    ) = SavedChemicalCreateSync(repository, PendingWriteRepository(pendingStore), local, { "owner" }, upload, find)

    @Test fun offlineSaveSurvivesRestartAndSavedFirstSearchUsesSameObject() = runBlocking {
        val original = coordinator().save("vineyard", input)
        val marker = PendingWriteRepository(pendingStore).list().single()
        val payload = Json { ignoreUnknownKeys = true }.decodeFromString(
            SavedChemicalCreateSync.Payload.serializer(), marker.payloadJson)
        val body = payload.insert
        assertEquals("owner", payload.ownerId)
        assertEquals(PendingEntityType.SAVED_CHEMICAL, marker.entityType)
        assertEquals(original.id, marker.clientId)
        assertEquals(original.id, body.id)
        assertEquals(original.entrySource, body.entrySource)
        assertEquals("customer_entered", body.entrySource)
        assertEquals(original.rates, body.rates)
        assertEquals(original.productCategory, body.productCategory)
        assertEquals(original.labelUrl, body.labelUrl)
        assertTrue(body.clientUpdatedAt.isNotBlank())
        assertFalse(marker.payloadJson.contains("access_token"))
        assertEquals(original, ChemicalSearchV2Duplicate.localMatches("Example Fungicide", coordinator().rows("owner", "vineyard")).single())
        coordinator().replayAll()
        assertEquals(PendingWriteStatus.FAILED, PendingWriteRepository(pendingStore).list().single().status)
        assertEquals(original, ChemicalSearchV2Duplicate.localMatches("Example Fungicide", coordinator().rows("owner", "vineyard")).single())
        assertTrue(coordinator().rows("another owner", "vineyard").isEmpty())
    }

    @Test fun acknowledgementLossAnd409ReconcileOnlySameUuid() = runBlocking {
        var calls = 0
        val offline = coordinator()
        val localRow = offline.save("vineyard", input)
        val afterRestart = coordinator(upload = { body ->
            calls++
            assertEquals(localRow.id, body.id)
            if (calls == 1) throw IllegalStateException("ack lost")
            throw BackendError.Server(409, "duplicate key")
        }, find = { id -> if (id == localRow.id) localRow else null })
        afterRestart.replayAll()
        assertEquals(PendingWriteStatus.FAILED, PendingWriteRepository(pendingStore).list().single().status)
        var synced: SavedChemical? = null
        afterRestart.replayAll { synced = it }
        assertEquals(localRow.id, synced?.id)
        assertTrue(PendingWriteRepository(pendingStore).list().isEmpty())
        afterRestart.replayAll()
        assertEquals(2, calls)
        assertEquals(localRow.id, afterRestart.rows("owner", "vineyard").single().id)
    }

    @Test fun unrelated409CannotClearTheCreateMarker() = runBlocking {
        val sync = coordinator(upload = { throw BackendError.Server(409, "unrelated conflict") }, find = { null })
        val saved = sync.save("vineyard", input)
        sync.replayAll()
        assertEquals(PendingWriteStatus.BLOCKED, PendingWriteRepository(pendingStore).list().single().status)
        assertEquals(saved, sync.rows("owner", "vineyard").single())
    }
}
