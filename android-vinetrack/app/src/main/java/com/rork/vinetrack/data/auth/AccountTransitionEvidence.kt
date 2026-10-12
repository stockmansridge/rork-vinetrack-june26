package com.rork.vinetrack.data.auth

import android.content.Context
import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.model.SprayTankActual
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray

/** Strict inspection at the existing admission boundary; never repairs, deletes or adopts evidence. */
internal class AccountTransitionEvidence(private val context: Context) {
    private val codec = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private val recordCodec = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Serializable private data class ActualCache(
        val records: List<SprayTankActual> = emptyList(),
        val pendingIds: Set<String> = emptySet(),
    )

    data class Assessment(val vineyards: Set<String>)
    var failureCategory: String = "retained state"
        private set

    fun inspect(original: String? = null): Assessment? = runCatching {
        failureCategory = "file dependencies"
        inspectLocations()
        val vineyards = mutableSetOf<String>()
        businessPreferences.forEach { name ->
            failureCategory = name
            val values = context.getSharedPreferences(name, Context.MODE_PRIVATE).all
            when (name) {
                "vinetrack_active_trip" -> {
                    check(values.keys.all { it == "active_trip_snapshot_json" })
                    values["active_trip_snapshot_json"]?.let { raw ->
                        check(original != null && raw is String)
                        val snapshot = recordCodec.decodeFromString(ActiveTripStore.Snapshot.serializer(), raw)
                        check(snapshot.ownerUserId == original && snapshot.vineyardId.isNotBlank() &&
                            snapshot.trip.id.isNotBlank() && snapshot.trip.vineyardId == snapshot.vineyardId)
                        vineyards.add(snapshot.vineyardId)
                    }
                }
                "vinetrack_spray_tank_actuals" -> {
                    check(values.keys.all { it == "cache" })
                    values["cache"]?.let { raw ->
                        check(raw is String)
                        val cache = codec.decodeFromString(ActualCache.serializer(), raw)
                        check(cache.records.map { it.id }.distinct().size == cache.records.size)
                        check(cache.pendingIds.all { id -> cache.records.any { it.id == id } })
                        if (original == null) check(cache.records.isEmpty() && cache.pendingIds.isEmpty())
                        else cache.records.forEach { actual ->
                            check(actual.id.isNotBlank() && actual.vineyardId.isNotBlank() &&
                                actual.confirmedBy == original && actual.correctionVersion == 0L &&
                                actual.lastCorrectedAt == null && actual.clientUpdatedAt == actual.confirmedAt)
                            vineyards.add(actual.vineyardId)
                        }
                    }
                }
                in emptyArrayKeys -> {
                    check(values.keys.all { it in emptyArrayKeys.getValue(name) })
                    values.values.forEach { raw ->
                        check(raw is String)
                        val array = codec.parseToJsonElement(raw) as? JsonArray
                        check(array != null && array.isEmpty())
                    }
                }
                else -> check(values.isEmpty())
            }
        }
        Assessment(vineyards)
    }.getOrNull()

    private fun inspectLocations() {
        // Android may expose its own data root through /data/user/0 -> /data/data aliases.
        // Anchor the trusted Context roots once; still reject links beneath those roots.
        val preferences = File(File(context.applicationInfo.dataDir).canonicalFile, "shared_prefs")
        if (preferences.exists()) {
            check(preferences.isDirectory && preferences.canonicalFile == preferences.absoluteFile)
            checkNotNull(preferences.listFiles()).forEach { file ->
                val name = file.name.removeSuffix(".bak").removeSuffix(".xml")
                if (name.startsWith("vinetrack_") || name in businessPreferences) {
                    check(name in businessPreferences || name in excludedPreferences)
                    // A backup/interrupted preference replacement is uncertain, not an empty store.
                    check(file.name == "$name.xml")
                }
            }
        }
        val filesRoot = context.filesDir.canonicalFile
        if (filesRoot.exists()) checkNotNull(filesRoot.listFiles()).forEach { file ->
            // These mirrors contain shared public chemical/guide material, not private field work.
            if (file.name !in sharedDirectories) check(noLeafFiles(file))
        }
        listOf("camera-captures").forEach { name -> check(noLeafFiles(File(context.cacheDir.canonicalFile, name))) }
    }

    private fun noLeafFiles(file: File): Boolean {
        if (!file.exists()) return true
        if (file.absoluteFile != file.canonicalFile || !file.isDirectory) return false
        return checkNotNull(file.listFiles()).all(::noLeafFiles)
    }

    private companion object {
        val emptyArrayKeys = mapOf(
            "vinetrack_pending_writes" to setOf("pending_writes_json"),
            "vinetrack_pending_photos" to setOf("pending_photos_json", "completed_photo_cache_json"),
            "vinetrack_pin_capture_evidence" to setOf("pin_capture_evidence_json"),
            "vinetrack_chemical_label_photos" to setOf("attachments"),
        )
        val businessPreferences = setOf(
            "vinetrack_pending_writes", "vinetrack_pending_photos", "vinetrack_active_trip",
            "vinetrack_spray_tank_actuals", "vinetrack_start_tank_journal", "vinetrack_chemical_label_photos",
            "vinetrack_manual_spray_operations_v1", "vinetrack_manual_spray_drafts_v1",
            "vinetrack_work_task_materials", "vinetrack_paired_growth_capture", "vinetrack_pin_capture_evidence",
            "vinetrack_recovery_snapshots_v2", "vinetrack_local_planning", "vinetrack_domain_cache",
            "vinetrack_irrigation", "vineyard_insights_preview", "vinetrack_pruning", "vinetrack_fertiliser",
            "vinetrack_saved_chemicals_local", "resistance_plans", "vinetrack_map_alignment",
            "vinetrack_operational_tools", "vinetrack_button_templates", "vinetrack_yield_determination",
            "vinetrack_pruning_yield_settings", "vinetrack_region_settings", "vinetrack_map", "vinetrack_operations",
            "vinetrack_canopy_rates", "vinetrack_gdd_settings", "vinetrack_bunch_weights", "vinetrack_app_prefs",
            "vinetrack_home", "vinetrack_onboarding", "vinetrack_setup_wizard", PhotoCaptureReceipt.PREFERENCES,
        )
        val excludedPreferences = setOf(
            "vinetrack_session", "vinetrack_biometric", "vinetrack_entitlement", "vinetrack_telemetry",
            "vinetrack_shared_grape_catalog",
        )
        val sharedDirectories = setOf("canopy_reference_images", "master-label-thumbnails")
    }
}
