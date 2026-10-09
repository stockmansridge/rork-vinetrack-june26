package com.rork.vinetrack.data.insights

/** Local display state; no state transition initiates a paid request automatically. */
data class VintageReportUiState(val cache: VintageReportCache = VintageReportCache(), val busy: Boolean = false, val message: String? = null, val hasMoreHistory: Boolean = true) {
    val history: List<VintageReportRevisionMetadata> get() = cache.history.ifEmpty { cache.revisions.sortedByDescending { it.revision }.map(::VintageReportRevisionMetadata) }
    val current: VintageReportRevision? get() = cache.revisions.firstOrNull { it.id == cache.currentID }
}
