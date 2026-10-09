package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

/** Lightweight history entry, separate from on-demand immutable report content. */
@Serializable data class VintageReportRevisionMetadata(
    val id: String, val revision: Int, val operation_id: String, val action: String,
    val created_at: String, val report_through: String, val collected_at: String,
) {
    constructor(saved: VintageReportRevision) : this(saved.id, saved.revision, saved.operation_id, saved.action, saved.created_at, saved.report_through, saved.collected_at)
}
