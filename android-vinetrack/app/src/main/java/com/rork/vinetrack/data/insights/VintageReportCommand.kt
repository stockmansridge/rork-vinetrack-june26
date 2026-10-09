package com.rork.vinetrack.data.insights

import kotlinx.serialization.Serializable

/** Exact durable client intent; baseline and operation identity never automatically rebase. */
@Serializable data class VintageReportCommand(val action: String, val operation: String, val expected: String?, val through: String, val narrative: String? = null)
