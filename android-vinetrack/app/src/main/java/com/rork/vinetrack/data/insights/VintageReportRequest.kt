package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

@Serializable data class VintageReportRequest(val operation_id: String, val status: String, val result_revision_id: String? = null, val error_code: String? = null, val input: VintageReportRequestInput? = null)
