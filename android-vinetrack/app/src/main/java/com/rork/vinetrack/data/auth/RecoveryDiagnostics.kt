package com.rork.vinetrack.data.auth

import com.rork.vinetrack.BuildConfig

/** Only fixed, locally generated metadata is copied. No telemetry or private-data export. */
object RecoveryDiagnostics {
    fun format(stage: String, evidence: RecoveryEvidenceDiagnostic?): String = buildString {
        appendLine("VineTrack Android recovery diagnostics v1")
        appendLine("App version: ${BuildConfig.VERSION_NAME}")
        appendLine("Version code: ${BuildConfig.VERSION_CODE}")
        appendLine("Recovery stage: $stage")
        appendLine("Store/category: ${evidence?.category ?: "not_assessed"}")
        appendLine("Validation rule: ${evidence?.rule ?: "NOT_ASSESSED"}")
        appendLine("Schema version: ${evidence?.schemaVersion ?: "not_available"}")
        appendLine("Relevant record/entry count: ${evidence?.recordCount ?: "not_available"}")
        append("Local read-only assessment only; no identity/access verification, records, credentials, filenames or identifiers included.")
    }
}
