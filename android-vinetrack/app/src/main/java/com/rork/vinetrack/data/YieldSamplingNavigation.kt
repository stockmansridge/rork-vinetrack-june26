package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SampleSite

/** Route order, never GPS-nearest. Navigation cannot manufacture or modify a measurement. */
object YieldSamplingNavigation {
    fun ordered(sites: List<SampleSite>) = sites.sortedBy { it.siteIndex }
    fun previous(sites: List<SampleSite>, id: String): String? {
        val ordered = ordered(sites)
        return ordered.getOrNull(ordered.indexOfFirst { it.id == id } - 1)?.id
    }
    fun next(sites: List<SampleSite>, id: String, justRecorded: Boolean = false): String? {
        val ordered = ordered(sites)
        val index = ordered.indexOfFirst { it.id == id }
        val candidates = ordered.drop(index + 1) + ordered.take((index + 1).coerceAtLeast(0))
        return candidates.firstOrNull { !it.isRecorded && (!justRecorded || it.id != id) }?.id
            ?: ordered.getOrNull(index + 1)?.id ?: ordered.getOrNull(index)?.id
    }
    fun needsPartialConfirmation(sites: List<SampleSite>) = sites.any { !it.isRecorded }
    fun canFinish(sites: List<SampleSite>) = sites.any { it.isRecorded }
}
