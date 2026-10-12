package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.material.WorkTaskMaterial
import com.rork.vinetrack.data.spray.VineyardSprayTarget
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** Read-only, fail-closed validation of the existing cache contract, not authorship evidence. */
internal object CleanExitCacheContract {
    private val json = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private data class Group(val data: String, val timestamp: String, val serializer: KSerializer<*>, val scoped: Boolean = true)
    private fun <T> group(data: String, timestamp: String, serializer: KSerializer<T>, scoped: Boolean = true) =
        Group(data, timestamp, ListSerializer(serializer), scoped)
    private val groups = listOf(
        group("vineyards_json", "vineyards_synced_at", Vineyard.serializer(), false),
        group("paddocks_", "paddocks_at_", Paddock.serializer()),
        group("pins_", "pins_at_", Pin.serializer()),
        group("trips_", "trips_at_", Trip.serializer()),
        group("growth_", "growth_at_", GrowthStageRecord.serializer()),
        group("worktask_", "worktask_at_", WorkTask.serializer()),
        group("worktask_labour_", "worktask_labour_at_", WorkTaskLabourLine.serializer()),
        group("worktask_machine_", "worktask_machine_at_", WorkTaskMachineLine.serializer()),
        group("work_task_machines_vineyard_", "work_task_machines_vineyard_at_", WorkTaskMachineLine.serializer()),
        group("work_task_materials_vineyard_", "work_task_materials_vineyard_at_", WorkTaskMaterial.serializer()),
        group("trip_cost_allocations_", "trip_cost_allocations_at_", TripCostAllocation.serializer()),
        group("maintenance_", "maintenance_at_", MaintenanceLog.serializer()),
        group("yield_", "yield_at_", HistoricalYieldRecord.serializer()),
        group("damage_", "damage_at_", DamageRecord.serializer()),
        group("yield_session_", "yield_session_at_", YieldEstimationSession.serializer()),
        group("fuel_", "fuel_at_", TractorFuelLog.serializer()),
        group("spray_", "spray_at_", SprayRecord.serializer()),
        group("spray_job_templates_", "spray_job_templates_at_", SprayRecord.serializer()),
        group("spray_targets_", "spray_targets_at_", VineyardSprayTarget.serializer()),
        group("worker_types_", "worker_types_at_", OperatorCategory.serializer()),
        group("picking_", "picking_at_", PickingRecord.serializer()),
        group("clone_catalog_json", "clone_catalog_synced_at", CloneCatalogEntry.serializer(), false),
        group("rootstock_catalog_json", "rootstock_catalog_synced_at", RootstockCatalogEntry.serializer(), false),
        group("vineyard_clones_", "vineyard_clones_at_", VineyardCloneRow.serializer()),
        group("vineyard_rootstocks_", "vineyard_rootstocks_at_", VineyardRootstockRow.serializer()),
    ).sortedByDescending { it.data.length }

    fun validate(values: Map<String, *>) {
        if (values.isEmpty()) return
        val known = mutableSetOf("cache_owner_user_id", "spray_target_outbox")
        values["spray_target_outbox"]?.let {
            check(it is String && (json.parseToJsonElement(it) as? JsonArray)?.isEmpty() == true)
        }
        val contentKeys = values.keys - known
        if (contentKeys.isNotEmpty()) check((values["cache_owner_user_id"] as? String)?.isNotBlank() == true)
        values["cache_owner_user_id"]?.let { check(it is String && it.isNotBlank()) }
        for ((key, raw) in values) {
            if (key in known || groups.any { if (it.scoped) key.startsWith(it.timestamp) else key == it.timestamp }) continue
            val group = groups.firstOrNull { if (it.scoped) key.startsWith(it.data) && !key.startsWith(it.timestamp) else key == it.data }
                ?: continue
            val suffix = if (group.scoped) key.removePrefix(group.data).also { check(it.isNotBlank()) } else ""
            val timestampKey = group.timestamp + suffix
            check(raw is String && values[timestampKey] is Long && (values[timestampKey] as Long) > 0L)
            val rows = json.decodeFromString(group.serializer, raw) as List<*>
            rows.forEach { row ->
                when (row) {
                    is Trip -> check(row.id.isNotBlank() && row.vineyardId == suffix && !row.isActive)
                    is Pin -> check(row.id.isNotBlank() && row.vineyardId == suffix)
                    is Paddock -> check(row.id.isNotBlank() && row.vineyardId == suffix)
                }
            }
            known.add(key)
            known.add(timestampKey)
        }
        check(values.keys.all { it in known })
    }

    /**
     * Preserve scoped snapshots, not a claim that each row is server-synchronised. CREATE and
     * preference UPDATE writers commit to the shared outbox before overlaying the snapshot.
     * Any retained outbox row (including unreadable/unknown operations) therefore prevents exit.
     */
    fun validateSavedChemicals(values: Map<String, *>, pending: Map<String, *>) {
        check(pending.keys.all { it == "pending_writes_json" })
        pending.values.forEach { raw ->
            check(raw is String && (json.parseToJsonElement(raw) as? JsonArray)?.isEmpty() == true)
        }
        val serializer = ListSerializer(SavedChemical.serializer())
        values.forEach { (key, raw) ->
            val scope = key.split('|')
            check(scope.size == 2)
            val (account, vineyard) = scope
            check(account.isNotBlank() && java.util.UUID.fromString(account).toString() == account.lowercase(java.util.Locale.ROOT))
            check(vineyard.isNotBlank() && vineyard == vineyard.trim() && vineyard.none { it.isISOControl() })
            check(raw is String)
            val encoded = json.parseToJsonElement(raw) as? JsonArray ?: error("Invalid chemical snapshot")
            val rows = json.decodeFromJsonElement(serializer, encoded)
            // Some legacy field codecs are permissive. Require lossless canonical store round-trip
            // so malformed/unknown nested content cannot disappear during classification.
            check(json.encodeToJsonElement(serializer, rows) == encoded)
            check(rows.map { it.id }.distinct().size == rows.size)
            rows.forEach { row ->
                check(row.id.isNotBlank() && row.id == row.id.trim() && row.vineyardId == vineyard)
                check(row.vineyardPreferredRate?.isValid != false)
            }
        }
    }

    fun validatePreferences(name: String, values: Map<String, *>) {
        values.forEach { (key, value) ->
            val valid = when (name) {
                "vinetrack_app_prefs" -> when (key) {
                    "display_mode" -> value in setOf("System", "Light", "Dark")
                    "row_tracking_enabled", "auto_photo_prompt", "ai_suggestions_enabled", "keep_screen_awake" -> value is Boolean
                    "row_tracking_interval" -> value is Float && value.isFinite() && value > 0
                    "timezone" -> value is String && value.isNotBlank()
                    else -> false
                }
                "vinetrack_map" -> when (key) {
                    "style" -> value in setOf("Hybrid", "Satellite", "Normal", "Terrain")
                    "overview_3d", "show_pins", "show_row_lines", "show_block_labels" -> value is Boolean
                    else -> false
                }
                "vinetrack_home" -> when (key) {
                    "info_card_dismissed" -> value is Boolean
                    "dismissed_notice_ids_v1" -> value is Set<*> && value.all { it is String }
                    else -> false
                }
                "vinetrack_onboarding" -> key == "onboarding_completed_v1" && value is Boolean
                "vinetrack_setup_wizard" -> key == "setup_wizard_enabled" && value is Boolean
                "vinetrack_irrigation" -> key in setOf("kc", "efficiency_percent", "rain_effectiveness_percent", "replacement_percent", "soil_buffer_mm") && value is Float && value.isFinite()
                "vinetrack_canopy_rates" -> key in canopyKeys && value is Float && value.isFinite()
                "vinetrack_gdd_settings" -> when (key) {
                    "calculation_mode" -> value in setOf("gdd", "bedd")
                    "reset_mode" -> value in setOf("seasonStart", "budburst", "flowering", "veraison")
                    else -> false
                }
                "vinetrack_bunch_weights" -> key.startsWith("bw_") && key.length > 3 && value is Float && value.isFinite() && value > 0
                "vinetrack_operations" -> when {
                    key in setOf("el_confirmation_enabled", "fill_timer_enabled") -> value is Boolean
                    key == "fuel_cost_per_litre" -> value is Float && value.isFinite()
                    key == "samples_per_hectare" -> value is Int && value >= 0
                    key == "enabled_growth_stage_codes" -> value is String && value.split('\u001F').filter { it.isNotBlank() }.all { code -> GrowthStage.allStages.any { it.code == code } }
                    key.startsWith("season_start_month_") -> key.length > "season_start_month_".length && value is Int && value in 1..12 && values.containsKey(key.replaceFirst("month_", "day_"))
                    key.startsWith("season_start_day_") -> key.length > "season_start_day_".length && value is Int && value in 1..31 && values.containsKey(key.replaceFirst("day_", "month_"))
                    key.startsWith("season_migration_decided_") -> key.length > "season_migration_decided_".length && value is Boolean
                    else -> false // Unresolved legacy global season values are not a read cache.
                }
                "vinetrack_region_settings" -> value is String && key.substringBefore("__").isNotBlank() && key.contains("__") && when (key.substringAfter("__")) {
                    "country", "currency" -> value.isNotBlank()
                    "timezone" -> value.isNotBlank()
                    "area" -> value in setOf("hectares", "acres")
                    "volume", "fuel" -> value in setOf("litres", "gallons")
                    "distance" -> value in setOf("metric", "imperial")
                    "spray_rate_area" -> value in setOf("hectare", "acre")
                    "date_format" -> value in setOf("DD/MM/YYYY", "MM/DD/YYYY", "YYYY-MM-DD")
                    "terminology" -> value in setOf("au_nz", "us", "uk", "za")
                    "sugar_unit" -> value in setOf("", "brix", "baume")
                    else -> false
                }
                "vinetrack_operational_tools" -> {
                    check(key.startsWith("layout_") && key.length > 7 && value is String)
                    val obj = json.parseToJsonElement(value) as? JsonObject
                    obj != null && obj.keys == setOf("visible", "hidden", "pending") &&
                        (obj["pending"] as? JsonPrimitive)?.booleanOrNull == false &&
                        listOf("visible", "hidden").all { field ->
                            (obj[field] as? JsonArray)?.all { it is JsonPrimitive && it.isString } == true
                        }
                }
                else -> false
            }
            check(valid)
        }
    }

    private val canopyKeys = listOf("small", "medium", "large", "full").flatMap { size ->
        listOf("${size}_low", "${size}_high", "sprawl_${size}_low", "sprawl_${size}_high")
    }.toSet()

    val devicePreferences = setOf("vinetrack_app_prefs", "vinetrack_map", "vinetrack_home", "vinetrack_onboarding", "vinetrack_setup_wizard",
        "vinetrack_irrigation", "vinetrack_canopy_rates", "vinetrack_gdd_settings", "vinetrack_bunch_weights", "vinetrack_operations", "vinetrack_region_settings", "vinetrack_operational_tools")
}
