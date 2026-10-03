package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalStorePresentation
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SavedChemicalReconciliationTest {
    private val repository = SavedChemicalRepository()
    private val outbox = PendingWriteRepository(InMemoryPendingWriteStore())
    private val snapshots = mutableMapOf<String, List<SavedChemical>>()
    private val local = object : SavedChemicalLocalStoring {
        override fun load(userId: String, vineyardId: String) = snapshots["$userId|$vineyardId"].orEmpty()
        override fun save(userId: String, vineyardId: String, rows: List<SavedChemical>): Boolean {
            snapshots["$userId|$vineyardId"] = rows
            return true
        }
    }
    private val input = SavedChemicalRepository.ChemicalInput(
        name = "Offline chemical", unit = "Litres", ratePerHa = 2.0, rates = emptyList(),
        activeIngredient = null, chemicalGroup = null, use = null, problem = null, manufacturer = null,
        notes = null, modeOfAction = null, labelUrl = null, productUrl = null, purchase = null,
    )

    @Test fun completeIdSetRepairsStaleRowsAndRepeatedRefreshAndRestartDoNotResurrect() {
        val remote = (0 until 12).map { SavedChemical(id = UUID.randomUUID().toString(), vineyardId = "vineyard", name = "Same name") }
        val archived = SavedChemical(id = UUID.randomUUID().toString(), vineyardId = "vineyard", name = "Same name", deletedAt = "2026-10-02T00:00:00Z", isActive = true)
        val missing = SavedChemical(id = UUID.randomUUID().toString(), vineyardId = "vineyard", name = "Historical snapshot", ratePerHa = 2.0)
        local.save("owner", "vineyard", remote + archived.copy(deletedAt = null) + missing)
        val sync = SavedChemicalCreateSync(repository, outbox, local, { "owner" })
        val repaired = sync.mergeRemote("owner", "vineyard", remote + archived)
        assertEquals(remote.map { it.id }.toSet(), ChemicalStorePresentation.active(repaired).map { it.id }.toSet())
        assertFalse(repaired.first { it.id == archived.id }.isActive)
        assertFalse(repaired.first { it.id == missing.id }.isActive)
        assertEquals(missing.name, repaired.first { it.id == missing.id }.name)
        assertEquals(missing.ratePerHa, repaired.first { it.id == missing.id }.ratePerHa)
        assertTrue(outbox.list().isEmpty())
        val restarted = SavedChemicalCreateSync(repository, outbox, local, { "owner" })
        assertEquals(repaired, restarted.rows("owner", "vineyard"))
        assertTrue(restarted.rows("other-account", "vineyard").isEmpty())
        repeat(3) {
            assertEquals(remote.map { it.id }.toSet(), ChemicalStorePresentation.active(restarted.mergeRemote("owner", "vineyard", remote + archived)).map { it.id }.toSet())
        }
    }

    @Test fun genuineOfflineCreateStaysVisibleAndUploadsExactId() = runBlocking {
        var uploads = 0
        val sync = SavedChemicalCreateSync(repository, outbox, local, { "owner" }, upload = { body ->
            uploads++
            repository.localCreate(body)
        }, findById = { null })
        val created = sync.save("vineyard", input)
        val merged = sync.mergeRemote("owner", "vineyard", emptyList())
        assertEquals(setOf(created.id), ChemicalStorePresentation.active(merged).map { it.id }.toSet())
        assertEquals(created.id, outbox.list().single().clientId)
        sync.replayAll()
        assertEquals(1, uploads)
        assertTrue(outbox.list().isEmpty())
        sync.mergeRemote("owner", "vineyard", emptyList())
        sync.replayAll()
        assertEquals(1, uploads)
        assertTrue(ChemicalStorePresentation.active(sync.rows("owner", "vineyard")).isEmpty())
    }

    @Test fun serverTombstoneOverridesEvenAnUnacknowledgedCreate() = runBlocking {
        var uploads = 0
        val sync = SavedChemicalCreateSync(repository, outbox, local, { "owner" }, upload = {
            uploads++
            repository.localCreate(it)
        }, findById = { null })
        val created = sync.save("vineyard", input)
        val tombstone = created.copy(deletedAt = "2026-10-02T00:00:00Z", isActive = true)
        val merged = sync.mergeRemote("owner", "vineyard", listOf(tombstone))
        assertFalse(merged.single().isActive)
        assertTrue(outbox.list().isEmpty())
        sync.replayAll()
        assertEquals(0, uploads)
        assertTrue(ChemicalStorePresentation.active(sync.rows("owner", "vineyard")).isEmpty())
    }

    @Test fun archiveOfAppOnlyPendingCreateCancelsReplayAndSurvivesRestart() = runBlocking {
        var uploads = 0
        val sync = SavedChemicalCreateSync(repository, outbox, local, { "owner" }, upload = {
            uploads++
            repository.localCreate(it)
        }, findById = { null })
        val created = sync.save("vineyard", input)
        sync.archiveLocal("owner", "vineyard", created.id)
        sync.replayAll()
        assertEquals(0, uploads)
        assertTrue(outbox.list().isEmpty())
        assertTrue(ChemicalStorePresentation.active(sync.rows("owner", "vineyard")).isEmpty())
        assertEquals(created.name, sync.rows("owner", "vineyard").single().name)
        val restarted = SavedChemicalCreateSync(repository, outbox, local, { "owner" })
        assertFalse(restarted.rows("owner", "vineyard").single().isActive)
    }

    @Test fun notFoundIsSuccessButUnrecognizedArchiveResponseIsNot() {
        assertTrue(SavedChemicalRepository.ArchiveResult(false, "not_found").isReconciled())
        assertTrue(SavedChemicalRepository.ArchiveResult(true).isReconciled())
        assertFalse(SavedChemicalRepository.ArchiveResult(false, "permission_denied").isReconciled())
        val stale = SavedChemical(id = UUID.randomUUID().toString(), vineyardId = "vineyard", name = "Stale")
        local.save("owner", "vineyard", listOf(stale))
        val sync = SavedChemicalCreateSync(repository, outbox, local, { "owner" })
        sync.removeLocal("owner", "vineyard", stale.id)
        assertTrue(sync.rows("owner", "vineyard").isEmpty())
    }

    @Test fun singleConfirmedEditCannotAcknowledgeUnrelatedOfflineCreate() {
        val sync = SavedChemicalCreateSync(repository, outbox, local, { "owner" })
        val offline = sync.save("vineyard", input)
        val remoteEdit = SavedChemical(id = UUID.randomUUID().toString(), vineyardId = "vineyard", name = "Updated notes")
        sync.acceptRemoteRow("owner", remoteEdit)
        assertEquals(offline.id, outbox.list().single().clientId)
        assertEquals(setOf(offline.id, remoteEdit.id), sync.rows("owner", "vineyard").map { it.id }.toSet())
    }

    @Test fun malformedOrOtherVineyardResponseCannotRetireLocalData() {
        val stale = SavedChemical(id = UUID.randomUUID().toString(), vineyardId = "vineyard", name = "Stale")
        local.save("owner", "vineyard", listOf(stale))
        val sync = SavedChemicalCreateSync(repository, outbox, local, { "owner" })
        assertThrows(IllegalArgumentException::class.java) {
            sync.mergeRemote("owner", "vineyard", listOf(stale.copy(vineyardId = "another-vineyard")))
        }
        assertEquals(listOf(stale), sync.rows("owner", "vineyard"))
    }
}
