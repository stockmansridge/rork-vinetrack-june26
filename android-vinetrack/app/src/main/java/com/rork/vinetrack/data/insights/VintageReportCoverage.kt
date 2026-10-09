package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

@Serializable data class VintageReportCoverage(
    val vineyard_name: String? = null, val timezone: String? = null, val season_start: String, val season_end: String,
    val report_through: String? = null, val season_to_date: Boolean? = null, val not_started: Boolean? = null,
    val coverage: Map<String, Int> = emptyMap(), val gaps: List<String> = emptyList(),
)
