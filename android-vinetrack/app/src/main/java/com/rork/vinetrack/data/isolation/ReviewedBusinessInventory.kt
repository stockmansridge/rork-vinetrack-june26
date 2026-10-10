package com.rork.vinetrack.data.isolation

import java.io.File

/** Candidate source allowlist for trials. Unknown locations stop inventory, rather than copying possible secrets. */
internal object ReviewedBusinessInventory {
    val businessPreferences: Set<String> = setOf(
        "vinetrack_pending_writes", "vinetrack_pending_photos", "vinetrack_active_trip",
        "vinetrack_spray_tank_actuals", "vinetrack_start_tank_journal", "vinetrack_chemical_label_photos",
        "vinetrack_manual_spray_operations_v1", "vinetrack_manual_spray_drafts_v1",
        "vinetrack_work_task_materials", "vinetrack_paired_growth_capture", "vinetrack_pin_capture_evidence",
        "vinetrack_recovery_snapshots_v2", "vinetrack_local_planning", "vinetrack_domain_cache",
        "vinetrack_irrigation", "vineyard_insights_preview", "vinetrack_pruning", "vinetrack_fertiliser",
        "vinetrack_saved_chemicals_local", "resistance_plans", "vinetrack_map_alignment",
        "vinetrack_operational_tools", "vinetrack_button_templates",
    )
    private val excludedPreferences = setOf(
        "vinetrack_session", "vinetrack_biometric", "vinetrack_entitlement", "vinetrack_telemetry",
        "admin_performance_capture", "release_reminders", "chemical_catalogue_discovery",
    )
    private val businessDirectories = setOf(
        "pending_pin_photos", "pin_photo_display_cache", "pending_chemical_label_photos", "scout_photos",
        "vintage-reports", "vintage-report-exports", "canopy_reference_images", "ripeness-heatmap", "vineyard_logos",
    )
    private val evidenceFiles = setOf(
        "pin_capture_evidence_recovery_v2.json", "pin_capture_evidence_recovery_v2.json.bak",
        "pin_capture_evidence_recovery_v2.json.new",
    )

    /** Raw XML, including backups, is copied without opening SharedPreferences or AtomicFile. */
    fun sources(preferences: File, files: File): List<RawEvidenceSource> {
        val result = mutableListOf<RawEvidenceSource>()
        children(preferences).forEach { file ->
            val name = file.name.removeSuffix(".bak").removeSuffix(".xml")
            check(file.name == "$name.xml" || file.name == "$name.xml.bak") { "Unreviewed preference file" }
            when (name) {
                in businessPreferences -> result += RawEvidenceSource("sharedpref/${file.name}", file)
                in excludedPreferences -> Unit
                else -> error("Unreviewed preferences; inventory review required")
            }
        }
        children(files).forEach { file ->
            when {
                file.name in evidenceFiles -> result += RawEvidenceSource("files/${file.name}", file)
                file.name in businessDirectories && file.isDirectory -> collect(file, "files/${file.name}", result)
                else -> error("Unreviewed file location; inventory review required")
            }
        }
        return result
    }

    private fun collect(directory: File, identity: String, result: MutableList<RawEvidenceSource>) {
        check(directory.absoluteFile == directory.canonicalFile) { "Linked business directory" }
        children(directory).forEach { file ->
            if (file.isDirectory) collect(file, "$identity/${file.name}", result)
            else result += RawEvidenceSource("$identity/${file.name}", file)
        }
    }

    private fun children(directory: File): List<File> {
        if (!directory.exists()) return emptyList()
        check(directory.isDirectory && directory.absoluteFile == directory.canonicalFile) { "Invalid source directory" }
        return checkNotNull(directory.listFiles()) { "Cannot inventory original evidence" }.toList()
    }
}
