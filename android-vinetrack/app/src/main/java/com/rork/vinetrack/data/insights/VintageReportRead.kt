package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

@Serializable internal data class VintageReportRead(val report: VintageReportPointer? = null, val revisions: List<VintageReportRevisionMetadata>, val requests: List<VintageReportRequest>)
