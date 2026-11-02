package com.rork.vinetrack.data.spray

import android.content.Context
import com.rork.vinetrack.data.auth.FieldStoreAccess

/**
 * This policy observes original retained operation evidence; it never
 * changes the queue, codecs, retry or ACK rules.
 */
internal enum class ManualSprayReviewStatus {
    REVIEW_ONLY,
    SUBMITTING,
    SAVED_LOCALLY_PENDING_CONFIRMATION,
    VERIFICATION_REQUIRED,
    SERVER_CONFIRMED,
}

internal fun manualSprayReviewStatus(
    serverConfirmed: Boolean,
    hasRetainedSave: Boolean,
    hasSubmissionMarker: Boolean,
    inFlight: Boolean = false,
): ManualSprayReviewStatus = when {
    serverConfirmed -> ManualSprayReviewStatus.SERVER_CONFIRMED
    inFlight -> ManualSprayReviewStatus.SUBMITTING
    hasRetainedSave -> ManualSprayReviewStatus.SAVED_LOCALLY_PENDING_CONFIRMATION
    hasSubmissionMarker -> ManualSprayReviewStatus.VERIFICATION_REQUIRED
    else -> ManualSprayReviewStatus.REVIEW_ONLY
}

internal fun manualSprayReviewStatusLabel(status: ManualSprayReviewStatus): String = when (status) {
    ManualSprayReviewStatus.REVIEW_ONLY -> "Review only — not yet saved"
    ManualSprayReviewStatus.SUBMITTING -> "Saving original manual spray — do not close"
    ManualSprayReviewStatus.SAVED_LOCALLY_PENDING_CONFIRMATION -> "Saved on device — awaiting server confirmation"
    ManualSprayReviewStatus.VERIFICATION_REQUIRED -> "Submission status unknown — verification required"
    ManualSprayReviewStatus.SERVER_CONFIRMED -> "Completed — server confirmed"
}

internal fun ManualSprayReviewStatus.canOfferSave(): Boolean =
    this == ManualSprayReviewStatus.REVIEW_ONLY

/**
 * Local-only submission-intent marker. One new manual draft per vineyard is
 * supported in the existing UI. Preserve intent after background replay
 * removes the pending queue entry, until a matching save response is seen.
 *
 * The account is included in the key to avoid cross-account suppression.
 * This is not a server ACK or permission to discard the original queue.
 */
internal class ManualSpraySubmissionGuard(context: Context) {
    private val prefs = FieldStoreAccess(context).preferences(
        context.applicationContext.getSharedPreferences(
            "vinetrack_manual_spray_submission_guard_v1", Context.MODE_PRIVATE
        )
    )

    private fun legacyKey(ownerId: String, vineyardId: String) = "$ownerId|$vineyardId"
    private fun key(ownerId: String, vineyardId: String, manualEntryId: String) =
        "$ownerId|$vineyardId|$manualEntryId"

    /** Observe only this exact application, never every spray in the vineyard. */
    fun submittedId(ownerId: String?, vineyardId: String, manualEntryId: String): String? {
        if (ownerId.isNullOrBlank() || manualEntryId.isBlank() || vineyardId.isBlank()) return null
        val active = prefs.getString(key(ownerId, vineyardId, manualEntryId), null)
            ?: prefs.getString(legacyKey(ownerId, vineyardId), null)
        return active?.takeIf { it == manualEntryId }
    }

    fun mark(ownerId: String?, vineyardId: String, manualEntryId: String): Boolean {
        if (ownerId.isNullOrBlank() || vineyardId.isBlank() || manualEntryId.isBlank()) return false
        // Other applications have *different* identities and cannot block
        // this one. Unknown original attempts remain in the preferences file.
        return prefs.edit().putString(key(ownerId, vineyardId, manualEntryId), manualEntryId).commit() &&
            submittedId(ownerId, vineyardId, manualEntryId) == manualEntryId
    }

    fun clearIfMatching(ownerId: String?, vineyardId: String, manualEntryId: String) {
        if (ownerId.isNullOrBlank() || submittedId(ownerId, vineyardId, manualEntryId) != manualEntryId) return
        val edit = prefs.edit().remove(key(ownerId, vineyardId, manualEntryId))
        if (prefs.getString(legacyKey(ownerId, vineyardId), null) == manualEntryId) {
            edit.remove(legacyKey(ownerId, vineyardId))
        }
        edit.commit()
    }
}
