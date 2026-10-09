package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

@Serializable data class VintageReportRequestInput(val action: String, val through: String, val expected: String? = null, val content: VintageReportNarrative? = null)
