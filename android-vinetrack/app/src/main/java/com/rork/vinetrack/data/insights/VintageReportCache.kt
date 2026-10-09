package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

@Serializable data class VintageReportCache(
    val revisions: List<VintageReportRevision> = emptyList(), val currentID: String? = null,
    val history: List<VintageReportRevisionMetadata> = emptyList(),
    val coverage: VintageReportCoverage? = null, val pending: VintageReportCommand? = null, val request: VintageReportRequest? = null,
)
