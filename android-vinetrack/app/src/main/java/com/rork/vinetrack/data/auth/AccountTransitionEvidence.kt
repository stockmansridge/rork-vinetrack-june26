package com.rork.vinetrack.data.auth

import android.content.Context
import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.model.SprayTankActual
import java.io.File
import java.io.DataInputStream
import java.io.FileInputStream
import android.system.Os
import android.system.OsConstants
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

    fun inspect(original: String? = null): Assessment? = assess(original, cleanExit = false)

    /** Clean exit may retain read caches but never unfinished operations. */
    fun inspectCleanExit(): Assessment? = assess(original = null, cleanExit = true)

    private fun assess(original: String?, cleanExit: Boolean): Assessment? = runCatching {
        failureCategory = "file dependencies"
        inspectLocations()
        val vineyards = mutableSetOf<String>()
        businessPreferences.forEach { name ->
            failureCategory = name
            val values = context.getSharedPreferences(name, Context.MODE_PRIVATE).all
            when {
                name in CleanExitCacheContract.devicePreferences -> CleanExitCacheContract.validatePreferences(name, values)
                name == "vinetrack_write_holds" -> {
                    check(values.keys.all { it == "holds" })
                    values["holds"]?.let { raw ->
                        check(raw is String)
                        val holds = codec.decodeFromString<kotlin.collections.Map<String, String>>(raw)
                        holds.forEach { (key, reason) ->
                            val scope = key.split(':')
                            check(scope.size == 2 && scope.all { it.isNotBlank() } &&
                                reason in setOf("VT_READ_ONLY", "READ_ONLY_TRIAL_EXPIRED"))
                            check(java.util.UUID.fromString(scope[0]).toString() == scope[0])
                            if (!cleanExit) { check(scope[0] == original); vineyards.add(scope[1]) }
                        }
                    }
                }
                name == "vinetrack_domain_cache" -> if (cleanExit) CleanExitCacheContract.validate(values)
                    else if (values.isNotEmpty()) vineyards.addAll(CleanExitCacheContract.recoveryScopes(values, checkNotNull(original)))
                name == "vinetrack_saved_chemicals_local" -> {
                    val pending = context.getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE).all
                    if (cleanExit) CleanExitCacheContract.validateSavedChemicals(values, pending)
                    else if (values.isNotEmpty()) vineyards.addAll(CleanExitCacheContract.chemicalRecoveryScopes(values, pending, checkNotNull(original)))
                }
                !cleanExit && name == "vinetrack_local_planning" -> vineyards.addAll(
                    RetainedPlanningContract.inspect(values, original),
                )
                name == "vinetrack_recovery_snapshots_v2" -> values.forEach { (key, raw) ->
                    check(key.startsWith("snapshot_") && raw is String)
                    val snapshot = codec.decodeFromString(com.rork.vinetrack.data.RecoverySnapshotStore.Snapshot.serializer(), raw)
                    check(snapshot.formatVersion == 3 && key == "snapshot_${snapshot.vineyardId}" && snapshot.vineyardId.isNotBlank())
                    check(snapshot.pendingWrites.isEmpty() && snapshot.captureEvidence.isEmpty() && snapshot.activeTrip == null &&
                        snapshot.cachedPins.isEmpty() && snapshot.cachedTrips.isEmpty() && snapshot.excludedOrUnreadable.isEmpty())
                    check(snapshot.source == "before_vineyard_load_refresh_or_replay" && snapshot.sourceStatuses.size == 5 &&
                        snapshot.sourceStatuses.map { it.source }.toSet() == setOf("pending_writes", "pin_capture_evidence", "cached_pins", "cached_trips", "active_trip") &&
                        snapshot.sourceStatuses.all { it.status == "read" && it.itemCount == 0 })
                }
                name == "vinetrack_active_trip" -> {
                    check(values.keys.all { it == "active_trip_snapshot_json" })
                    values["active_trip_snapshot_json"]?.let { raw ->
                        check(original != null && raw is String)
                        val snapshot = recordCodec.decodeFromString(ActiveTripStore.Snapshot.serializer(), raw)
                        check(snapshot.ownerUserId == original && snapshot.vineyardId.isNotBlank() &&
                            snapshot.trip.id.isNotBlank() && snapshot.trip.vineyardId == snapshot.vineyardId)
                        vineyards.add(snapshot.vineyardId)
                    }
                }
                name == "vinetrack_spray_tank_actuals" -> {
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
                name in emptyArrayKeys -> {
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
            when {
                file.name == "profileInstalled" -> validateProfileMarker(file, filesRoot)
                file.name !in sharedDirectories -> check(noLeafFiles(file))
            }
        }
        listOf("camera-captures").forEach { name -> check(noLeafFiles(File(context.cacheDir.canonicalFile, name))) }
    }

    /** AndroidX ProfileVerifier Cache schema 1: two ints and two longs, never business evidence. */
    private fun validateProfileMarker(file: File, filesRoot: File) {
        check(file.absoluteFile == File(filesRoot, "profileInstalled") && file.canonicalFile == file.absoluteFile)
        val before = Os.lstat(file.path)
        check(OsConstants.S_ISREG(before.st_mode) && before.st_size == 24L && before.st_nlink == 1L)
        // NOFOLLOW and descriptor identity prevent a link/replacement between inspection and reading.
        val descriptor = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        DataInputStream(FileInputStream(descriptor)).use { input ->
            val opened = Os.fstat(descriptor)
            check(OsConstants.S_ISREG(opened.st_mode) && opened.st_dev == before.st_dev &&
                opened.st_ino == before.st_ino && opened.st_size == 24L && opened.st_nlink == 1L)
            check(input.readInt() == 1)
            // Only these results are persisted; the other error codes return before cache publication.
            check(input.readInt() in setOf(0, 1, 2, 3, 5 shl 16))
            val packageUpdate = input.readLong()
            check(packageUpdate > 0L && packageUpdate <= context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime)
            check(input.readLong() >= 0L && input.read() == -1)
            val after = Os.lstat(file.path)
            check(OsConstants.S_ISREG(after.st_mode) && after.st_dev == opened.st_dev &&
                after.st_ino == opened.st_ino && after.st_size == opened.st_size && after.st_mtime == opened.st_mtime)
        }
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
            "vinetrack_legacy_spray_saves_v1",
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
            "vinetrack_home", "vinetrack_onboarding", "vinetrack_setup_wizard", "vinetrack_write_holds", PhotoCaptureReceipt.PREFERENCES,
        )
        val excludedPreferences = setOf(
            "vinetrack_session", "vinetrack_biometric", "vinetrack_entitlement", "vinetrack_telemetry",
            "vinetrack_shared_grape_catalog",
        )
        val sharedDirectories = setOf("canopy_reference_images", "master-label-thumbnails")
    }
}
