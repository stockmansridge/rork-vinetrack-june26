package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.SprayJobTemplateRepository

/** Vineyard-scoped active tractor options for calculator and Program Step pickers. */
object SprayTractorOptions {
    fun activeForVineyard(
        tractors: List<SprayJobTemplateRepository.SprayTractor>,
        vineyardId: String,
    ): List<SprayJobTemplateRepository.SprayTractor> = tractors
        .filter { it.vineyardId == vineyardId && it.deletedAt == null }
        .distinctBy { it.id }
        .sortedBy { it.displayName.lowercase() }

    /** Accepts only a UUID present in the canonical tractor feed; machine ids cannot cross over. */
    fun selectedId(
        requestedId: String?,
        options: List<SprayJobTemplateRepository.SprayTractor>,
    ): String? = requestedId?.takeIf { id -> options.any { it.id == id } }
}
