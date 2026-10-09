package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

/** Provider-independent saved content used by screen, PDF and Word. */
@Serializable data class VintageReportContent(val narrative: String, val timeline: List<String>, val appendix: List<String>)
