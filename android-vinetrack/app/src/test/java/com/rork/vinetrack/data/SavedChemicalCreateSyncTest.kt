package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalSearchV2Duplicate
import com.rork.vinetrack.data.chemical.ChemicalResistanceState
import com.rork.vinetrack.data.chemical.MasterChemicalV2
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.chemical.resistanceAvailability
import kotlinx.serialization.decodeFromString
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

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

    @Test fun backendResistanceStateSurvivesInsertAndUnresolvedSnapshotBlocksRotation() {
        val lookup = Json { ignoreUnknownKeys = true }.decodeFromString<ChemicalInfoService.ChemicalStructuredLookup>(
            """{"product_name":"CropSure Beast 200 Herbicide","product_category":"herbicide",
            "resistance_classification_state":"classified","active_ingredients":[{"name":"Glufosinate-ammonium",
            "activity_group":{"scheme":"hrac","code":"10"}}]}"""
        )
        val intel = lookup.intelligence()
        assertEquals(ChemicalResistanceState.CLASSIFIED, intel.resistanceClassificationState)
        assertEquals(listOf("10"), intel.activityGroupCodes)
        val body = repository.prepareCreate("vineyard", input.copy(intelligence = intel), "beast-id", "2026-09-27T00:00:00Z")
        assertEquals(ChemicalResistanceState.CLASSIFIED, body.resistanceClassificationState)
        assertEquals("classified", Json.encodeToString(SavedChemicalRepository.ChemicalInsert.serializer(), body)
            .substringAfter("\"resistance_classification_state\":\"").substringBefore('"'))
        val unresolved = ChemicalLineSnapshot.capture(intel.copy(resistanceClassificationState = ChemicalResistanceState.UNRESOLVED), "10")!!
        assertEquals(ChemicalIntelligenceAvailability.UNAVAILABLE, unresolved.resistanceAvailability)
        assertFalse(unresolved.resistanceAvailability.permitsCleanResult)
    }

    @Test fun masterRPCStateSurvivesSelectionAndSavedPayload() {
        val fixtures = listOf(
            Triple("classified", "10", ChemicalResistanceState.CLASSIFIED),
            Triple("unresolved", "10", ChemicalResistanceState.UNRESOLVED),
            Triple("not_applicable", "", ChemicalResistanceState.NOT_APPLICABLE),
        )
        fixtures.forEach { (state, group, expected) ->
            val groups = if (group.isEmpty()) "[]" else "[\"$group\"]"
            val scheme = if (group.isEmpty()) "not_applicable" else "hrac"
            val actives = if (group.isEmpty()) "[]" else """[{"name":"Glufosinate-ammonium","activity_group":{"scheme":"hrac","code":"10"}}]"""
            val response = """{"id":"10000000-0000-4000-8000-000000000256",
                "registration_country":"AU","registration_scheme":"apvma","registration_number":"90143",
                "registered_product_name":"Master fixture","product_category":"herbicide",
                "active_ingredients":$actives,"activity_groups":$groups,
                "activity_group_scheme":"$scheme","resistance_classification_state":"$state",
                "registered_uses":[],"viticulture_rates":{"per_hectare":[],"per_100_litres":[]},
                "has_viticulture_evidence":true,"verification_status":"verified",
                "source_kind":"official_register","review_status":"approved","catalogue_version":1,"search_rank":1} """
            val master = Json { ignoreUnknownKeys = true }.decodeFromString<MasterChemicalV2>(response)
            assertEquals(if (group.isEmpty()) emptyList<String>() else listOf(group), master.activityGroups)
            assertEquals(expected, master.resistanceClassificationState)
            val intel = master.intelligence
            assertEquals(expected, intel.resistanceClassificationState)
            assertEquals(if (group.isEmpty()) emptyList<String>() else listOf(group), intel.activityGroupCodes)
            val body = repository.prepareCreate("vineyard", input.copy(intelligence = intel), "master-id", "2026-09-27T00:00:00Z")
            assertEquals(expected, body.resistanceClassificationState)
            assertEquals(state, Json.encodeToString(SavedChemicalRepository.ChemicalInsert.serializer(), body)
                .substringAfter("\"resistance_classification_state\":\"").substringBefore('"'))
        }
    }

    @Test fun internationalFoundInputManualRateSurvivesOfflineSaveAndRestart() {
        for (country in listOf("AU", "NZ", "FR", "US", "ZA", "")) {
            val rate = com.rork.vinetrack.data.chemical.ChemicalLabelRate(basis = com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "L")
            val defaults = com.rork.vinetrack.data.chemical.ChemicalSearchV2OperationalDefaults.storedDefaults(listOf(rate), "2026-10-01T00:00:00Z")
            val intel = com.rork.vinetrack.data.chemical.ChemicalIntelligence(registration = com.rork.vinetrack.data.chemical.ChemicalRegistration(countryCode = country, registrant = "Supplier"), productCategory = "biostimulant")
            val original = coordinator().save("vineyard", input.copy(name = "Seaweed $country", intelligence = intel, defaultRates = defaults, entrySource = "label_lookup"))
            val reopened = coordinator().rows("owner", "vineyard").first { it.id == original.id }
            assertEquals(defaults, reopened.defaultRates)
            assertEquals("manual", reopened.defaultRates?.perHectare?.entryMethod)
            assertEquals(emptyList<String>(), reopened.defaultRates?.perHectare?.rateIds)
            assertEquals("Supplier", reopened.storedIntelligence?.registration?.registrant)
            assertEquals("label_lookup", reopened.entrySource)
            assertEquals(null, reopened.masterChemicalId)
        }
    }

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

    @Test fun offlineChemicalAndLabelPhotoRestartTogetherWithSameUuid() {
        val root = Files.createTempDirectory("chemical-label-together").toFile()
        try {
            val photoStore = object : ChemicalLabelPhotoStoring {
                var rows: List<ChemicalLabelAttachment> = emptyList()
                override fun load(): List<ChemicalLabelAttachment> = rows
                override fun save(rows: List<ChemicalLabelAttachment>) { this.rows = rows }
            }
            val chemical = coordinator().save("vineyard", input)
            val attachment = ChemicalLabelPhotoRepository(root, photoStore)
                .enqueue("owner", chemical.vineyardId, chemical.id, byteArrayOf(1, 2, 3))
            val resumedChemical = coordinator().rows("owner", "vineyard").single()
            val resumedPhoto = ChemicalLabelPhotoRepository(root, photoStore).list().single()
            assertEquals(chemical.id, resumedChemical.id)
            assertEquals(resumedChemical.id, resumedPhoto.chemicalId)
            assertEquals(attachment.id, resumedPhoto.id)
            assertEquals(chemical.id, PendingWriteRepository(pendingStore).list().single().clientId)
            assertTrue(File(resumedPhoto.localPath).exists())
        } finally { root.deleteRecursively() }
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
        }, find = { id -> if (calls >= 2 && id == localRow.id) localRow else null })
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
