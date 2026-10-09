package com.rork.vinetrack.data.insights

/** Local display state; no state transition initiates a paid request automatically. */
data class VintageReportUiState(val cache: VintageReportCache = VintageReportCache(), val busy: Boolean = false, val message: String? = null) {
    val current: VintageReportRevision? get() = cache.revisions.firstOrNull { it.id == cache.currentID }
}
