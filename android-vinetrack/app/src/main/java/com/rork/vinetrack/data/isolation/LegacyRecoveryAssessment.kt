package com.rork.vinetrack.data.isolation

import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.ChemicalLabelAttachment
import kotlinx.serialization.json.Json

/** Review classification is not an access/adoption/replay permit. Raw evidence remains in the vault. */
internal sealed interface LegacyRecoveryAssessment {
    data class VerifiedCandidate(val account: String, val vineyard: String) : LegacyRecoveryAssessment
    data object Conflicting : LegacyRecoveryAssessment
    data object Unknown : LegacyRecoveryAssessment
    data object CorruptedPreserved : LegacyRecoveryAssessment
}

/** Read-only classification of exact objects with explicit actor provenance. Never extrapolates to their edits. */
internal object LegacyRecoveryReviewer {
    private val json = Json { ignoreUnknownKeys = true }

    fun activeTrip(raw: String): LegacyRecoveryAssessment = try {
        val snapshot = json.decodeFromString<ActiveTripStore.Snapshot>(raw)
        when {
            snapshot.ownerUserId.isBlank() || snapshot.vineyardId.isBlank() -> LegacyRecoveryAssessment.Unknown
            snapshot.trip.vineyardId != snapshot.vineyardId -> LegacyRecoveryAssessment.Conflicting
            else -> LegacyRecoveryAssessment.VerifiedCandidate(snapshot.ownerUserId, snapshot.vineyardId)
        }
    } catch (_: Exception) { LegacyRecoveryAssessment.CorruptedPreserved }

    fun chemicalLabel(raw: String): LegacyRecoveryAssessment = try {
        val attachment = json.decodeFromString<ChemicalLabelAttachment>(raw)
        if (attachment.ownerId.isBlank() || attachment.vineyardId.isBlank()) LegacyRecoveryAssessment.Unknown
        else LegacyRecoveryAssessment.VerifiedCandidate(attachment.ownerId, attachment.vineyardId)
    } catch (_: Exception) { LegacyRecoveryAssessment.CorruptedPreserved }

    fun authorlessOperation(raw: String): LegacyRecoveryAssessment = try {
        json.parseToJsonElement(raw)
        LegacyRecoveryAssessment.Unknown
    } catch (_: Exception) { LegacyRecoveryAssessment.CorruptedPreserved }

    /** Contradictory original/back-up evidence prevents adopting even an otherwise verified candidate. */
    fun combineOriginalEvidence(candidates: List<LegacyRecoveryAssessment>): LegacyRecoveryAssessment {
        if (candidates.isEmpty()) return LegacyRecoveryAssessment.Unknown
        if (candidates.any { it == LegacyRecoveryAssessment.Conflicting }) return LegacyRecoveryAssessment.Conflicting
        val proven = candidates.filterIsInstance<LegacyRecoveryAssessment.VerifiedCandidate>().distinct()
        if (proven.size > 1) return LegacyRecoveryAssessment.Conflicting
        if (candidates.any { it == LegacyRecoveryAssessment.CorruptedPreserved }) return LegacyRecoveryAssessment.CorruptedPreserved
        if (candidates.any { it == LegacyRecoveryAssessment.Unknown }) return LegacyRecoveryAssessment.Unknown
        return proven.singleOrNull() ?: LegacyRecoveryAssessment.Unknown
    }
}
