package com.rork.vinetrack.data.chemical

import kotlinx.serialization.Serializable

@Serializable
data class CatalogueDiscoveryContext(val jobId: String, val userId: String, val vineyardId: String,
    val query: String, val country: String, val inputKind: String, val photoPath: String?, val startedAt: Long)
