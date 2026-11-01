package com.rork.vinetrack.ui

import com.rork.vinetrack.data.TripOccurrencePlanner
import org.junit.Assert.*
import org.junit.Test

/** Tight regression for a held legacy Save-for-Later versus a NEW path-qualified start. */
class IndependentQualifiedSprayStartTest {
    private val vineyard = "e0000000-0000-4000-8000-000000000010"
    private val blockA = "e0000000-0000-4000-8000-000000000011"
    private val blockB = "e0000000-0000-4000-8000-000000000012"

    private fun candidate(block: String, label: Double) =
        TripOccurrencePlanner.Candidate(vineyard, block, "Block", label, emptyList())

    private val planned = SprayJobRowPlan(
        trackingPattern = "sequential",
        rowSequence = listOf(35.5, 36.5, 37.5),
        totalTanks = 1,
        candidates = listOf(candidate(blockA, 35.5), candidate(blockB, 36.5), candidate(blockA, 37.5)),
    )
    private fun independent(plan: SprayJobRowPlan? = planned, parent: String? = null,
                            savedRecordId: String? = null, programJobId: String? = null,
                            blocks: List<String> = listOf(blockA, blockB), vineyardId: String = vineyard) =
        IndependentQualifiedSprayStart.isSeparateNewOperation(parent, savedRecordId, programJobId, vineyardId, blocks, plan)

    @Test fun newBoundPathRouteDoesNotDependOnUnreadableUnrelatedLegacyJournal() {
        assertTrue(independent())
        assertTrue(independent(blocks = listOf(blockA, blockB, blockA)))
    }

    @Test fun parentLinkedRequestNeverSkipsLegacyRecovery() {
        assertFalse(independent(parent = "e0000000-0000-4000-8000-000000000099"))
        assertFalse(independent(savedRecordId = "e0000000-0000-4000-8000-000000000098"))
        assertFalse(independent(programJobId = "e0000000-0000-4000-8000-000000000097"))
    }

    @Test fun freeDriveAndMissingPlanRemainFailClosed() {
        assertFalse(independent(plan = null))
        assertFalse(independent(planned.copy(rowSequence = emptyList(), candidates = emptyList())))
        assertFalse(independent(planned.copy(trackingPattern = "freeDrive")))
        assertFalse(independent(blocks = emptyList()))
    }

    @Test fun incorrectCandidateBindingDoesNotSkipLegacyRecovery() {
        assertFalse(independent(planned.copy(candidates = planned.candidates.dropLast(1))))
        assertFalse(independent(planned.copy(candidates = planned.candidates.reversed())))
        assertFalse(independent(planned.copy(candidates = planned.candidates.map { it.copy(vineyardId = "foreign") })))
        assertFalse(independent(planned.copy(candidates = planned.candidates.map { it.copy(blockId = "foreign") })))
        assertFalse(independent(blocks = listOf(blockA)))
        assertFalse(independent(blocks = listOf(blockA, blockB, "other-block")))
        assertFalse(independent(vineyardId = "foreign"))
        assertFalse(independent(planned.copy(rowSequence = listOf(35.5, Double.NaN, 37.5))))
    }
}
