package com.rork.vinetrack.data.reporting

import com.rork.vinetrack.data.spray.SprayApplicationSnapshot

/** Display only: recorded intent, never inferred from products or current geometry. */
data class SprayApplicationReportFields(val targets: String, val sprayHead: String, val ground: String, val mode: String) {
    val values: List<String> get() = listOf(targets, sprayHead, ground, mode)
    companion object {
        val headers: List<String> = listOf("Disease/pest targets", "Spray-head application location", "Ground application location", "Application mode")
        fun from(snapshot: SprayApplicationSnapshot?): SprayApplicationReportFields {
            val entries = snapshot?.targets.orEmpty().map { it.label } + snapshot?.customTargets.orEmpty()
            return SprayApplicationReportFields(
                if (snapshot?.targets == null && snapshot?.customTargets == null) "Not recorded"
                else entries.joinToString("; ").ifEmpty { "None recorded" },
                snapshot?.sprayHeadTarget?.label ?: "Not recorded",
                snapshot?.groundTarget?.label ?: "Not recorded",
                snapshot?.applicationMode?.raw?.replace('_', ' ')?.replaceFirstChar { it.uppercase() } ?: "Not recorded",
            )
        }
    }
}
