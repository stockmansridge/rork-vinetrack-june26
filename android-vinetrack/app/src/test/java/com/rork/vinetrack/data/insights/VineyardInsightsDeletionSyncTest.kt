package com.rork.vinetrack.data.insights

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VineyardInsightsDeletionSyncTest {
    private class MemoryStore : InsightsKeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String): String? = values[key]
        override fun write(key: String, value: String): Boolean { values[key] = value; return true }
        override fun remove(key: String): Boolean { values.remove(key); return true }
    }

    private class Files : ScoutPhotoFiles {
        val values = mutableSetOf<String>()
        override fun relativePath(vineyardId: String, observationId: String, photoId: String) = "$vineyardId/$observationId/$photoId.jpg"
        override fun storagePath(vineyardId: String, observationId: String, photoId: String) = relativePath(vineyardId, observationId, photoId)
        override fun write(jpeg: ByteArray, vineyardId: String, observationId: String, photoId: String): String = relativePath(vineyardId, observationId, photoId).also(values::add)
        override fun read(relativePath: String): ByteArray? = if (relativePath in values) byteArrayOf(1) else null
        override fun exists(relativePath: String) = relativePath in values
        override fun remove(relativePath: String) { values.remove(relativePath) }
        override fun clearForSignOut() { values.clear() }
    }

    private class Api : VineyardInsightsSyncApi {
        val deletions = mutableListOf<VineyardInsightsSyncApi.DeletionRow>()
        val cleanup = mutableListOf<VineyardInsightsSyncApi.PhotoCleanupRow>()
        val removed = mutableListOf<String>()
        val completed = mutableListOf<String>()
        val failed = mutableListOf<String>()
        var failRemoval = false
        var blockedNoteRows: List<VineyardInsightsSyncApi.NoteRow>? = null
        val notesFetchStarted = CompletableDeferred<Unit>()
        val releaseNotesFetch = CompletableDeferred<Unit>()
        override suspend fun fetchDeletions(vineyardId: String, deletedAtIso: String?) = deletions.filter { it.vineyardId == vineyardId }
        override suspend fun claimPhotoCleanup(vineyardId: String, limit: Int) = cleanup.filter { it.vineyardId == vineyardId }
        override suspend fun acknowledgePhotoCleanup(id: String, leaseToken: String) { completed += id }
        override suspend fun failPhotoCleanup(id: String, leaseToken: String, error: String) { failed += id }
        override suspend fun removePhotoObject(path: String) { if (failRemoval) error("offline"); removed += path }
        override suspend fun pushVisit(visit: VineyardInsightsSyncApi.VisitUpsert, assessments: List<VineyardInsightsSyncApi.AssessmentUpsert>, observations: List<VineyardInsightsSyncApi.ObservationUpsert>) = VineyardInsightsSyncApi.VisitRow(id = visit.id, vineyardId = visit.vineyardId, clientUpdatedAt = visit.clientUpdatedAt, clientRevisionId = visit.clientRevisionId, syncVersion = 1)
        override suspend fun pushPhotoRow(photo: VineyardInsightsSyncApi.PhotoUpsert) = Unit
        override suspend fun uploadPhotoBytes(path: String, jpeg: ByteArray) = path
        override suspend fun hardDeleteVisit(id: String, vineyardId: String, operationId: String, atIso: String) = Unit
        override suspend fun softDeletePhoto(id: String, atIso: String) = Unit
        override suspend fun fetchVisits(vineyardId: String, sinceIso: String?) = emptyList<VineyardInsightsSyncApi.VisitRow>()
        override suspend fun fetchAssessments(vineyardId: String, visitIds: List<String>) = emptyList<VineyardInsightsSyncApi.AssessmentRow>()
        override suspend fun fetchObservations(vineyardId: String, assessmentIds: List<String>) = emptyList<VineyardInsightsSyncApi.ObservationRow>()
        override suspend fun fetchPhotos(vineyardId: String, observationIds: List<String>) = emptyList<VineyardInsightsSyncApi.PhotoRow>()
        override suspend fun fetchNotes(vineyardId: String, sinceIso: String?): List<VineyardInsightsSyncApi.NoteRow> {
            val rows = blockedNoteRows ?: return emptyList()
            notesFetchStarted.complete(Unit)
            releaseNotesFetch.await()
            return rows
        }
        override suspend fun upsertNote(args: VineyardInsightsSyncApi.UpsertNoteArgs) = null
        override suspend fun hardDeleteNote(id: String, vineyardId: String, operationId: String, atIso: String) = Unit
        override suspend fun upsertNoteType(args: VineyardInsightsSyncApi.UpsertNoteTypeArgs) = Unit
    }

    @Test fun `blocked pull completing after generation invalidation cannot repopulate records`() = runBlocking {
        val store = VineyardInsightsStore(MemoryStore())
        val api = Api()
        api.blockedNoteRows = listOf(
            VineyardInsightsSyncApi.NoteRow(
                id = "late", vineyardId = "v1", noteDate = "2026-09-19",
                vintageYear = 2027, noteTypeId = "00000000-0000-0000-0000-000000000240",
                noteTypeLabel = "Frost",
            ),
        )
        var generationIsCurrent = true
        val worker = VineyardInsightsSyncWorker(store, Files(), api, { "now" }) { generationIsCurrent }
        val pull = launch { worker.pull("v1") }
        api.notesFetchStarted.await()
        generationIsCurrent = false
        store.clearForSignOut()
        api.releaseNotesFetch.complete(Unit)
        pull.join()
        assertTrue(store.loadNotes().isEmpty())
        assertTrue(store.loadVisits().isEmpty())
    }

    private fun note(id: String, vineyard: String) = VintageNote(
        id = id, vineyardId = vineyard, noteDateIso = "2026-01-01", vintageYear = 2026,
        noteTypeId = null, noteTypeLabelSnapshot = "Frost", notes = "note",
        observedByUserId = null, observerNameSnapshot = null, createdAtIso = "2026-01-01T00:00:00Z",
        updatedAtIso = "2026-01-01T00:00:00Z", clientUpdatedAtIso = "2026-01-01T00:00:00Z",
    )

    @Test fun `marker removes exact note cancels stale upsert and survives restart`() = runBlocking {
        val raw = MemoryStore(); val store = VineyardInsightsStore(raw); val api = Api()
        store.saveNote(note("n1", "v1")); store.saveNote(note("n2", "v1"))
        store.enqueue("n1", "v1", VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE, VineyardInsightsStore.QueuedOperation.Operation.UPSERT, "2026-01-01T00:00:00Z")
        api.deletions += VineyardInsightsSyncApi.DeletionRow("a", "v1", "vintage_note", "n1", "2026-02-01T00:00:00Z")
        VineyardInsightsSyncWorker(store, Files(), api) { "2026-03-01T00:00:00Z" }.pullDeletions("v1")
        val restarted = VineyardInsightsStore(raw)
        assertEquals(listOf("n2"), restarted.loadNotes().map { it.id })
        assertTrue(restarted.loadQueue().isEmpty())
        assertTrue(restarted.isDeleted("v1", "vintage_note", "n1"))
    }

    @Test fun `equal timestamp markers use ledger id tie breaker idempotently`() = runBlocking {
        val store = VineyardInsightsStore(MemoryStore()); val api = Api(); val worker = VineyardInsightsSyncWorker(store, Files(), api) { "now" }
        api.deletions += VineyardInsightsSyncApi.DeletionRow("a", "v1", "vintage_note", "n1", "2026-02-01T00:00:00Z")
        api.deletions += VineyardInsightsSyncApi.DeletionRow("b", "v1", "vintage_note", "n2", "2026-02-01T00:00:00Z")
        worker.pullDeletions("v1"); worker.pullDeletions("v1")
        assertEquals("b", store.deletionCursor("v1")?.ledgerId)
        assertTrue(store.isDeleted("v1", "vintage_note", "n1"))
        assertTrue(store.isDeleted("v1", "vintage_note", "n2"))
    }

    @Test fun `marker and cursor are isolated by vineyard`() = runBlocking {
        val store = VineyardInsightsStore(MemoryStore()); val api = Api()
        store.saveNote(note("same", "v2"))
        api.deletions += VineyardInsightsSyncApi.DeletionRow("a", "v1", "vintage_note", "same", "2026-02-01T00:00:00Z")
        VineyardInsightsSyncWorker(store, Files(), api) { "now" }.pullDeletions("v1")
        assertEquals("v2", store.loadNotes().single().vineyardId)
        assertTrue(store.deletionCursor("v2") == null)
    }

    @Test fun `stale ordinary pull cannot recreate consumed id`() {
        val store = VineyardInsightsStore(MemoryStore()); val api = Api(); val worker = VineyardInsightsSyncWorker(store, Files(), api) { "now" }
        store.consumeDeletion("v1", "vintage_note", "n1")
        worker.applyNoteRow(VineyardInsightsSyncApi.NoteRow(id="n1", vineyardId="v1", noteDate="2026-01-01", vintageYear=2026))
        assertTrue(store.loadNotes().isEmpty())
    }

    @Test fun `photo cleanup failure is retained and restart retries`() = runBlocking {
        val raw = MemoryStore(); val store = VineyardInsightsStore(raw); val api = Api(); api.failRemoval = true
        store.enqueuePhoto(VineyardInsightsStore.QueuedPhoto("p1", "v1", "visit", "obs", "local", "v1/obs/p1.jpg", false, "now"))
        store.consumeDeletion("v1", "scout_visit", "visit")
        VineyardInsightsSyncWorker(store, Files(), api) { "now" }.processLocalObjectCleanup("v1")
        assertEquals(1, VineyardInsightsStore(raw).loadObjectCleanup().single().attemptCount)
        api.failRemoval = false
        VineyardInsightsSyncWorker(VineyardInsightsStore(raw), Files(), api) { "now" }.processLocalObjectCleanup("v1")
        assertTrue(VineyardInsightsStore(raw).loadObjectCleanup().isEmpty())
        assertEquals(listOf("v1/obs/p1.jpg"), api.removed)
    }

    @Test fun `server cleanup acknowledges only successful object removal`() = runBlocking {
        val store = VineyardInsightsStore(MemoryStore()); val api = Api()
        api.cleanup += VineyardInsightsSyncApi.PhotoCleanupRow("q1", "v1", "visit", "p1", "v1/obs/p1.jpg", "lease")
        val worker = VineyardInsightsSyncWorker(store, Files(), api) { "now" }
        api.failRemoval = true; worker.processServerPhotoCleanup("v1")
        assertTrue("q1" in api.failed); assertFalse("q1" in api.completed)
        api.failRemoval = false; worker.processServerPhotoCleanup("v1")
        assertTrue("q1" in api.completed)
    }
}
