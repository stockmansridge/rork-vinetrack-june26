package com.rork.vinetrack.ui

/**
 * Separates an entirely NEW block-qualified occurrence Trip from the older
 * legacy Save for Later paired-create journal. The latter may contain work
 * that belongs to an earlier, uncertain REST request and must remain intact.
 *
 * This only skips an UNRELATED legacy-journal inspection. It does NOT bypass
 * device-active claims, current-account authority, write admission, durable
 * occurrence creation, linked spray receipt, or exact tank actuals.
 */
internal object IndependentQualifiedSprayStart {
    fun isSeparateNewOperation(
        parentTripId: String?,
        vineyardId: String,
        selectedPaddockIds: List<String>,
        plan: SprayJobRowPlan?,
    ): Boolean {
        if (parentTripId != null || plan == null || plan.trackingPattern == "freeDrive") return false
        if (vineyardId.isBlank() || selectedPaddockIds.isEmpty() || plan.rowSequence.isEmpty()) return false
        if (!plan.rowSequence.all(Double::isFinite) ||
            plan.candidates.size != plan.rowSequence.size ||
            plan.candidates.map { it.label } != plan.rowSequence) return false
        val requestedBlocks = selectedPaddockIds.toSet()
        return plan.candidates.all {
            it.vineyardId == vineyardId && it.blockId in requestedBlocks
        } && requestedBlocks.all { block -> plan.candidates.any { it.blockId == block } }
    }
}
