package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.PruningSyncRepository
import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Populated production codecs and server projections, not an empty-key-count fixture. */
class PruningRecoveryVerifierTest {
    private val owner = "00000000-0000-4000-8000-0000000000a1"
    private val vineyard = "00000000-0000-4000-8000-0000000000b1"
    private val block = "00000000-0000-4000-8000-0000000000c1"
    private val season = "00000000-0000-4000-8000-0000000000d1"
    private val entry = "00000000-0000-4000-8000-0000000000e1"
    private val json = Json { encodeDefaults = true }
    private val setup = PruningBlockSetup(season, vineyard, block, seasonYear = 2026, serverRevision = 2)
    private val seasonRow = PruningSyncRepository.SeasonRow(season, vineyard, block, seasonYear = 2026, serverRevision = 2)
    private val settings = PruningYieldSettings(entry, vineyard, block, bunchesPerBud = 1.7, serverRevision = 3)
    private fun snapshot(setupValue: PruningBlockSetup = setup) = PruningRecoveryVerifier.Snapshot(mapOf(
        "vinetrack_pruning" to mapOf("setups_v2_$vineyard" to json.encodeToString(listOf(setupValue))),
        "vinetrack_pruning_yield_settings" to mapOf("settings_$vineyard" to json.encodeToString(listOf(settings))),
    ))
    private suspend fun get(path: String): JsonElement = when (path.substringBefore('?')) {
        "pruning_seasons" -> json.encodeToJsonElement(listOf(seasonRow))
        "pruning_yield_settings" -> json.encodeToJsonElement(listOf(settings))
        "vineyards" -> buildJsonArray { add(buildJsonObject { put("id", vineyard); put("timezone", "Australia/Sydney") }) }
        else -> error("Unexpected recovery read")
    }
    private fun verify(snapshot: PruningRecoveryVerifier.Snapshot = snapshot(), permitted: Set<String> = setOf(vineyard)) = runBlocking {
        PruningRecoveryVerifier.verify(owner, 7, snapshot, permitted, ::get) { _, _ -> error("No RPC expected") }
    }
    @Test fun populatedSetupsAndYieldSettingsNeedNoWritesOrDiscard() {
        val before = snapshot(); val proof = verify(before)
        before.values.forEach { (name, values) -> assertEquals(setOf(vineyard), proof.inspect(name, values, owner, 7)) }
        assertEquals(before, snapshot())
    }
    @Test fun locallyModifiedSetupIsNotAttributedByAccountOrMembership() {
        assertTrue(runCatching { verify(snapshot(setup.copy(notes = "unsynced work"))) }.exceptionOrNull() is EvidenceContractFailure)
    }
    @Test fun wrongOriginalAccountCannotUseProof() {
        val values = snapshot(); val proof = verify(values)
        assertTrue(runCatching { proof.inspect("vinetrack_pruning", values.values.getValue("vinetrack_pruning"), block, 7) }.isFailure)
    }
    @Test fun changedEpochCannotUseProof() {
        val values = snapshot(); val proof = verify(values)
        assertTrue(runCatching { proof.inspect("vinetrack_pruning", values.values.getValue("vinetrack_pruning"), owner, 8) }.isFailure)
    }
    @Test fun changedBytesBetweenReadAndAdmissionCannotUseProof() {
        val proof = verify()
        assertTrue(runCatching { proof.inspect("vinetrack_pruning", snapshot(setup.copy(notes = "new edit")).values.getValue("vinetrack_pruning"), owner, 7) }.isFailure)
        assertTrue(runCatching { proof.inspect("vinetrack_pruning", emptyMap<String, String>(), owner, 7) }.isFailure)
    }
    @Test fun revokedMembershipRemainsLocked() {
        assertTrue(runCatching { verify(permitted = emptySet()) }.exceptionOrNull() is EvidenceContractFailure)
    }
    @Test fun unknownVersionAndMalformedRowsRemainProtected() {
        for (value in listOf(mapOf("setups_v1_$vineyard" to "[]"), mapOf("setups_v2_$vineyard" to "not json"),
            mapOf("setups_v2_$vineyard" to "[{}]"))) {
            assertTrue(runCatching { verify(PruningRecoveryVerifier.Snapshot(mapOf("vinetrack_pruning" to value))) }.isFailure)
        }
    }
    @Test fun uppercaseIdentityInPopulatedSetupDoesNotChangeValues() {
        val upper = setup.copy(id = season.uppercase(), vineyardId = vineyard.uppercase(), paddockId = block.uppercase())
        verify(snapshot(upper))
    }
    @Test fun duplicateRecordsRemainProtected() {
        val raw = json.encodeToString(listOf(setup, setup))
        assertTrue(runCatching { verify(PruningRecoveryVerifier.Snapshot(mapOf("vinetrack_pruning" to mapOf("setups_v2_$vineyard" to raw)))) }.isFailure)
    }
    @Test fun emptyKnownArraysCanBeAssessedButPopulatedRowsNeedServerProof() {
        assertEquals(setOf(vineyard), PruningRecoveryVerifier.inspectWithoutProof("vinetrack_pruning", mapOf("entries_v2_$vineyard" to "[]")))
        assertTrue(runCatching { PruningRecoveryVerifier.inspectWithoutProof("vinetrack_pruning", snapshot().values.getValue("vinetrack_pruning")) }.isFailure)
    }
    @Test fun populatedEntryAndLabourUseRealServerProjections() = runBlocking {
        val row = PruningSyncRepository.EntryRow(entry, vineyard, season, block, entryDate = "2026-08-10", createdBy = owner,
            createdAt = "2026-08-10T00:00:00Z", updatedAt = "2026-08-10T00:00:00Z", notes = "field evidence")
        val segment = PruningSyncRepository.SegmentRow("00000000-0000-4000-8000-0000000000f1", season,
            rowNumber = 1, segmentNumber = 2, completed = true, pruningEntryId = entry)
        val recorded = row.toModel(listOf(PruningSegment(1, 2)), 2026, java.time.ZoneId.of("Australia/Sydney"))
        val labour = PruningActivityLabourLine(entry, entry, vineyard, workerCount = 2, hoursPerWorker = 3.0)
        val snap = PruningRecoveryVerifier.Snapshot(mapOf("vinetrack_pruning" to mapOf(
            "entries_v2_$vineyard" to json.encodeToString(listOf(recorded)),
            "activity_labour_v1_$vineyard" to json.encodeToString(listOf(labour)))))
        PruningRecoveryVerifier.verify(owner, 7, snap, setOf(vineyard), { path -> when (path.substringBefore('?')) {
            "pruning_entries" -> json.encodeToJsonElement(listOf(row))
            "pruning_row_segments" -> json.encodeToJsonElement(listOf(segment))
            "pruning_activity_labour_lines" -> json.encodeToJsonElement(listOf(labour))
            else -> get(path)
        } }) { _, _ -> error("No RPC expected") }
    }
    @Test fun acknowledgedPopulatedActivityStillRequiresExactBusinessFields() = runBlocking {
        val canonical = PruningActivityCanonical(activity = PruningActivityCanonical.CanonicalActivity(
            id = entry, vineyardId = vineyard, entryDate = "2026-08-10", workerOrCrew = "Crew", method = "spur", notes = "Saved", seasonYear = 2026), allocations = listOf(
            PruningActivityCanonical.CanonicalAllocation(id = season, paddockId = block, blockName = "Block A",
                pruningSeasonId = season, seasonYear = 2026, estimatedVines = 60,
                segments = listOf(PruningActivityCanonical.CanonicalSegment(row = 1, segment = 2))),
            PruningActivityCanonical.CanonicalAllocation(id = "00000000-0000-4000-8000-0000000000d2",
                paddockId = "00000000-0000-4000-8000-0000000000c2", blockName = "Block B",
                pruningSeasonId = season, seasonYear = 2026, estimatedVines = 40,
                segments = listOf(PruningActivityCanonical.CanonicalSegment(row = 9, segment = 1)))))
        val cached = PruningAllocationEditor.adoptCanonical(PruningActivityDraft(entry, vineyard, "2026-08-10"), canonical, java.time.ZoneId.of("Australia/Sydney"))
        for ((candidate, expected) in listOf(cached to true, cached.copy(notes = "local edit") to false,
            cached.copy(serverAcknowledged = false) to false)) {
            val snap = PruningRecoveryVerifier.Snapshot(mapOf("vinetrack_pruning" to mapOf("activities_v1_$vineyard" to json.encodeToString(listOf(candidate)))))
            val result = runCatching { PruningRecoveryVerifier.verify(owner, 7, snap, setOf(vineyard), ::get) { name, args ->
                assertEquals("get_pruning_activity", name); assertEquals(entry, args["p_activity_id"]?.jsonPrimitive?.content)
                json.encodeToJsonElement(canonical)
            } }
            assertEquals(expected, result.isSuccess)
        }
    }
}
