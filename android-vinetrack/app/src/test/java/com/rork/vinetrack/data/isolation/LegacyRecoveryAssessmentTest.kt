package com.rork.vinetrack.data.isolation

import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.ChemicalLabelAttachment
import com.rork.vinetrack.data.model.Trip
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class LegacyRecoveryAssessmentTest {
    private val json = Json { encodeDefaults = true }

    @Test fun explicitOriginalTripOwnerIdentifiesOnlyItsExactSnapshot() {
        val raw = json.encodeToString(ActiveTripStore.Snapshot("A", "shared", Trip("trip", "shared", isActive = true), 123))
        assertEquals(LegacyRecoveryAssessment.VerifiedCandidate("A", "shared"), LegacyRecoveryReviewer.activeTrip(raw))
        assertEquals(LegacyRecoveryAssessment.Unknown,
            LegacyRecoveryReviewer.authorlessOperation("{\"pinId\":\"trip\",\"creator\":\"A\",\"vineyard\":\"shared\"}"))
    }

    @Test fun exactLabelOwnerDoesNotAttributeOtherPhotosOrChemicalEdits() {
        val raw = json.encodeToString(ChemicalLabelAttachment("id", "A", "chemical", "shared", "/old.jpg", "path", 123))
        assertEquals(LegacyRecoveryAssessment.VerifiedCandidate("A", "shared"), LegacyRecoveryReviewer.chemicalLabel(raw))
        assertEquals(LegacyRecoveryAssessment.Unknown, LegacyRecoveryReviewer.authorlessOperation("{\"chemicalId\":\"chemical\"}"))
    }

    @Test fun conflictingOriginalAndBackupOwnersRemainConflictingEvenWithinSharedVineyard() {
        assertEquals(LegacyRecoveryAssessment.Conflicting, LegacyRecoveryReviewer.combineOriginalEvidence(listOf(
            LegacyRecoveryAssessment.VerifiedCandidate("A", "shared"), LegacyRecoveryAssessment.VerifiedCandidate("B", "shared"))))
    }

    @Test fun conflictingTripVineyardIsNotApprovedByOriginalOwnerTag() {
        val raw = json.encodeToString(ActiveTripStore.Snapshot("A", "one", Trip("trip", "two"), 123))
        assertEquals(LegacyRecoveryAssessment.Conflicting, LegacyRecoveryReviewer.activeTrip(raw))
    }

    @Test fun corruptEvidenceAndUnknownEvidencePreventCandidatePromotion() {
        val candidate = LegacyRecoveryAssessment.VerifiedCandidate("A", "shared")
        assertEquals(LegacyRecoveryAssessment.CorruptedPreserved, LegacyRecoveryReviewer.activeTrip("{incomplete"))
        assertEquals(LegacyRecoveryAssessment.CorruptedPreserved, LegacyRecoveryReviewer.combineOriginalEvidence(listOf(candidate, LegacyRecoveryAssessment.CorruptedPreserved)))
        assertEquals(LegacyRecoveryAssessment.Unknown, LegacyRecoveryReviewer.combineOriginalEvidence(listOf(candidate, LegacyRecoveryAssessment.Unknown)))
    }

    @Test fun matchingHashOrCurrentAccountCannotChangeAuthorlessClassification() {
        val raw = "{\"pinId\":\"pin\",\"isCompleted\":true}"
        val hash = IsolationDisk.digest(raw.toByteArray())
        assertEquals(64, hash.length)
        assertEquals(LegacyRecoveryAssessment.Unknown, LegacyRecoveryReviewer.authorlessOperation(raw))
        assertEquals(LegacyRecoveryAssessment.Unknown, LegacyRecoveryReviewer.combineOriginalEvidence(emptyList()))
    }
}
