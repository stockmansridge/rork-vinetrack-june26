package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

/** Immutable saved revision with independent reporting and collection dates. */
@Serializable data class VintageReportRevision(
    val id: String, val revision: Int, val operation_id: String, val action: String,
    val created_at: String, val report_through: String, val collected_at: String,
    val evidence: VintageReportCoverage, val content: VintageReportContent,
)
