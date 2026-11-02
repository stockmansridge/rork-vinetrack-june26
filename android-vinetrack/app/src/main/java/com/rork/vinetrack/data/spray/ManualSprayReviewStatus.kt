package com.rork.vinetrack.data.spray

/**
 * Operator-facing state of a MANUAL spray submission.
 *
 * Reviewing a form is not completion. A durably queued operation is not
 * backend confirmation. The stored payload, original operation identity,
 * retry policy and server acknowledgement remain owned by the coordinator.
 */
internal enum class ManualSprayReviewStatus {
    REVIEW_ONLY,
    SAVED_LOCALLY_PENDING_CONFIRMATION,
    SERVER_CONFIRMED,
}

internal fun manualSprayReviewStatusLabel(status: ManualSprayReviewStatus): String = when (status) {
    ManualSprayReviewStatus.REVIEW_ONLY -> "Review only — not yet saved"
    ManualSprayReviewStatus.SAVED_LOCALLY_PENDING_CONFIRMATION -> "Saved on device — awaiting server confirmation"
    ManualSprayReviewStatus.SERVER_CONFIRMED -> "Completed — server confirmed"
}
