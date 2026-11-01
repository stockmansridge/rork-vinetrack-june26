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
    // SavedChemical's custom codecs preserve unsupported label evidence verbatim.
    // Use the actual store reader, then prove that NO supplied field was lost.
    // This is storage compatibility, not permission to execute an unknown rate.
    private val chemicalJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private data class Group(val data: String, val timestamp: String, val serializer: KSerializer<*>, val scoped: Boolean = true) {
        // Derived only from the fixed declarations below, never from a stored key or value.
        val diagnostic: String get() = "DOMAIN_" + data.removeSuffix("_").removeSuffix("_json").uppercase(java.util.Locale.ROOT)
    }
    private enum class Purpose { CLEAN_EXIT, ORIGINAL_ACCOUNT_RECOVERY }

    /** Keep parser messages, scoped keys and record contents out of copied diagnostics. */
    private inline fun <T> domain(rule: String, count: Int? = null, block: () -> T): T =
        try { block() } catch (failure: EvidenceContractFailure) { throw failure }
        catch (_: Exception) { throw EvidenceContractFailure(RecoveryEvidenceDiagnostic(
            "vinetrack_domain_cache", rule, recordCount = count,
        )) }

    // UUID spelling is not identity. iOS Codable emits uppercase UUID strings;
    // Android cache keys use lowercase. Do not rewrite any retained payload.
    private val uuidPattern = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    internal fun identityKey(value: String): String =
        if (uuidPattern.matches(value)) value.lowercase(java.util.Locale.ROOT) else value
    internal fun sameIdentity(left: String?, right: String): Boolean =
        left != null && identityKey(left) == identityKey(right)

    private fun metadataOnly(key: String): Boolean =
        key == "cache_owner_user_id" || key == "spray_target_outbox"

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
        group("machines_", "machines_at_", VineyardMachine.serializer()),
        group("spray_equipment_", "spray_equipment_at_", SprayEquipment.serializer()),
        group("picking_", "picking_at_", PickingRecord.serializer()),
        group("clone_catalog_json", "clone_catalog_synced_at", CloneCatalogEntry.serializer(), false),
        group("rootstock_catalog_json", "rootstock_catalog_synced_at", RootstockCatalogEntry.serializer(), false),
        group("vineyard_clones_", "vineyard_clones_at_", VineyardCloneRow.serializer()),
        group("vineyard_rootstocks_", "vineyard_rootstocks_at_", VineyardRootstockRow.serializer()),
    ).sortedByDescending { it.data.length }

    /** Voluntary sign-out still refuses active trips; it is not the recovery policy. */
    fun validate(values: Map<String, *>) = validateDomain(values, Purpose.CLEAN_EXIT)

    private fun validateDomain(values: Map<String, *>, purpose: Purpose) {
        if (values.isEmpty()) return
        val known = mutableSetOf("cache_owner_user_id", "spray_target_outbox")
        domain("DOMAIN_TARGET_OUTBOX", values.size) {
            values["spray_target_outbox"]?.let {
                check(it is String && (json.parseToJsonElement(it) as? JsonArray)?.isEmpty() == true)
            }
        }
        domain("DOMAIN_CACHE_OWNER", values.size) {
            val contentKeys = values.keys - known
            if (contentKeys.isNotEmpty()) check((values["cache_owner_user_id"] as? String)?.isNotBlank() == true)
            values["cache_owner_user_id"]?.let { check(it is String && it.isNotBlank()) }
        }
        for ((key, raw) in values) {
            if (key.startsWith("quick_actions_v1_")) {
                domain("DOMAIN_QUICK_ACTIONS_SNAPSHOT") {
                    check(raw is String)
                    val snapshot = json.decodeFromString<com.rork.vinetrack.data.QuickActionOfflineSnapshot>(raw)
                    check(snapshot.userId == values["cache_owner_user_id"] && snapshot.vineyardId.isNotBlank() &&
                        key == "quick_actions_v1_${snapshot.vineyardId}" && snapshot.identityEpoch >= 0 &&
                        snapshot.members.orEmpty().all { it.vineyardId == snapshot.vineyardId })
                }
                known.add(key)
            }
            if (key.startsWith("spray_tractors_")) {
                domain("DOMAIN_SPRAY_TRACTORS_SCHEMA") {
                    check(key.removePrefix("spray_tractors_").isNotBlank() && raw is String)
                    json.decodeFromString(ListSerializer(com.rork.vinetrack.data.SprayJobTemplateRepository.SprayTractor.serializer()), raw)
                }
                known.add(key)
            }
            if (key in known || groups.any { if (it.scoped) key.startsWith(it.timestamp) else key == it.timestamp }) continue
            val group = groups.firstOrNull { if (it.scoped) key.startsWith(it.data) && !key.startsWith(it.timestamp) else key == it.data }
                ?: continue
            val suffix = domain(group.diagnostic + "_KEY_SCOPE") {
                if (group.scoped) key.removePrefix(group.data).also { check(it.isNotBlank()) } else ""
            }
            val source = domain(group.diagnostic + "_VALUE_TYPE") { raw as? String ?: error("Invalid type") }
            val timestampKey = group.timestamp + suffix
            domain(group.diagnostic + "_TIMESTAMP") {
                check(values[timestampKey] is Long && (values[timestampKey] as Long) > 0L)
            }
            val rows = domain(group.diagnostic + "_DECODE_SCHEMA") {
                if (group.data == "spray_job_templates_") {
                    runCatching {
                        json.decodeFromString(ListSerializer(com.rork.vinetrack.data.SprayProgramTemplateCache.serializer()), source)
                            .map { it.record }
                    }.getOrElse { json.decodeFromString(ListSerializer(SprayRecord.serializer()), source) }
                } else json.decodeFromString(group.serializer, source) as List<*>
            }
            rows.forEach { row ->
                domain(group.diagnostic + "_ROW_ID_SCOPE", rows.size) {
                    when (row) {
                        is Trip -> check(row.id.isNotBlank() && sameIdentity(row.vineyardId, suffix))
                        is Pin -> check(row.id.isNotBlank() && sameIdentity(row.vineyardId, suffix))
                        is Paddock -> check(row.id.isNotBlank() && sameIdentity(row.vineyardId, suffix))
                        is SprayRecord -> check(row.id.isNotBlank() && sameIdentity(row.vineyardId, suffix))
                    }
                }
                if (row is Trip && purpose == Purpose.CLEAN_EXIT) {
                    domain("DOMAIN_TRIPS_ACTIVE_ON_CLEAN_EXIT", rows.size) { check(!row.isActive) }
                }
            }
            known.add(key)
            known.add(timestampKey)
        }
        domain("DOMAIN_UNKNOWN_OR_ORPHAN_KEY", values.size) { check(values.keys.all { it in known }) }
    }

    /**
     * Same-principal cache recovery is NOT a sign-out. A cached active Trip is a
     * list snapshot, not an active-device claim, a replay intent or proof of authorship.
     * ActiveTripStore, retained outboxes and live membership retain their own checks.
     * This function reads only; it never starts a trip, rewrites bytes or marks work synced.
     */
    fun recoveryScopes(values: Map<String, *>, original: String): Set<String> {
        if (values.isEmpty()) return emptySet()
        domain("DOMAIN_CACHE_OWNER_MISMATCH", values.size) {
            check(original.isNotBlank() && sameIdentity(values["cache_owner_user_id"] as? String, original))
        }
        validateDomain(values, Purpose.ORIGINAL_ACCOUNT_RECOVERY)
        val scopes = mutableSetOf<String>()
        val tasks = mutableMapOf<String, String>()
        domain("DOMAIN_WORKTASK_PARENT_INDEX") {
            values.filterKeys { it.startsWith("worktask_") && !it.startsWith("worktask_at_") &&
                !it.startsWith("worktask_labour_") && !it.startsWith("worktask_machine_") }.forEach { (key, raw) ->
                json.decodeFromString(ListSerializer(WorkTask.serializer()), raw as String).forEach { task ->
                    check(task.id.isNotBlank() && sameIdentity(task.vineyardId, key.removePrefix("worktask_")))
                    check(tasks.put(identityKey(task.id), identityKey(task.vineyardId)) in setOf(null, identityKey(task.vineyardId)))
                }
            }
        }
        values.forEach { (key, raw) ->
            // In particular, spray_target_outbox must not match the shorter spray_
            // prefix and manufacture a vineyard called "target_outbox".
            if (metadataOnly(key)) return@forEach
            if (key.startsWith("quick_actions_v1_")) {
                scopes.add(key.removePrefix("quick_actions_v1_")); return@forEach
            }
            if (key.startsWith("spray_tractors_")) {
                scopes.add(key.removePrefix("spray_tractors_")); return@forEach
            }
            // Nested timestamp keys must not match a shorter data prefix.
            if (groups.any { if (it.scoped) key.startsWith(it.timestamp) else key == it.timestamp }) return@forEach
            val group = groups.firstOrNull { if (it.scoped) key.startsWith(it.data) && !key.startsWith(it.timestamp) else key == it.data }
                ?: return@forEach
            domain(group.diagnostic + "_RECOVERY_SCOPE") {
                if (group.scoped) {
                    val child = group.data in setOf("worktask_labour_", "worktask_machine_")
                    val suffix = key.removePrefix(group.data)
                    val vineyard = if (child) checkNotNull(tasks[identityKey(suffix)]) else suffix
                    check(vineyard.isNotBlank())
                    scopes.add(identityKey(vineyard))
                    (json.parseToJsonElement(raw as String) as JsonArray).forEach { element ->
                        val encoded = element as? JsonObject ?: error("Invalid cached row")
                        val row = if (group.data == "spray_job_templates_" && "record" in encoded)
                            encoded["record"] as? JsonObject ?: error("Invalid template record") else encoded
                        if (child) check(sameIdentity(row["work_task_id"]?.let { (it as? JsonPrimitive)?.content }, suffix))
                        listOf("vineyard_id", "vineyardId").forEach { field ->
                            row[field]?.let { check(sameIdentity((it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content, vineyard)) }
                        }
                    }
                } else if (key == "vineyards_json") {
                    json.decodeFromString(ListSerializer(Vineyard.serializer()), raw as String).forEach {
                        check(it.id.isNotBlank()); scopes.add(identityKey(it.id))
                    }
                }
            }
        }
        return scopes
    }

    fun chemicalRecoveryScopes(values: Map<String, *>, pending: Map<String, *>, original: String): Set<String> {
        // Recovery admits only audited, explicitly authored operations. Clean exit still
        // requires the entire queue to be empty. Chemical operations remain unsupported.
        RetainedEvidenceContract.queue(pending, original)
        validateSavedChemicals(values, emptyMap<String, Any>())
        return values.keys.mapTo(mutableSetOf()) { key ->
            val scope = key.split('|')
            chemical("CHEMICAL_ORIGINAL_ACCOUNT_MISMATCH") { check(scope[0] == original) }
            scope[1]
        }
    }

    /**
     * Preserve scoped snapshots, not a claim that each row is server-synchronised. CREATE and
     * preference UPDATE writers commit to the shared outbox before overlaying the snapshot.
     * Any retained outbox row (including unreadable/unknown operations) therefore prevents exit.
     */
    private inline fun <T> chemical(rule: String, count: Int? = null, block: () -> T): T =
        try { block() } catch (failure: EvidenceContractFailure) { throw failure }
        catch (_: Exception) { throw EvidenceContractFailure(RecoveryEvidenceDiagnostic(
            "vinetrack_saved_chemicals_local", rule, recordCount = count,
        )) }

    fun validateSavedChemicals(values: Map<String, *>, pending: Map<String, *>) {
        chemical("CHEMICAL_PENDING_WRITES_HELD") {
            check(pending.keys.all { it == "pending_writes_json" })
            pending.values.forEach { raw ->
                check(raw is String && (json.parseToJsonElement(raw) as? JsonArray)?.isEmpty() == true)
            }
        }
        val serializer = ListSerializer(SavedChemical.serializer())
        values.forEach { (key, raw) ->
            val scope = chemical("CHEMICAL_KEY_SCOPE") {
                val parts = key.split('|')
                check(parts.size == 2)
                val (account, vineyard) = parts
                check(account.isNotBlank() && java.util.UUID.fromString(account).toString() == account.lowercase(java.util.Locale.ROOT))
                check(vineyard.isNotBlank() && vineyard == vineyard.trim() && vineyard.none { it.isISOControl() })
                parts
            }
            val encoded = chemical("CHEMICAL_JSON_SCHEMA") {
                check(raw is String)
                json.parseToJsonElement(raw) as? JsonArray ?: error("Invalid chemical snapshot")
            }
            val rows = chemical("CHEMICAL_DECODE_SCHEMA", encoded.size) {
                chemicalJson.decodeFromJsonElement(serializer, encoded)
            }
            // New nullable/default fields do not make an older snapshot invalid.
            // Preserve every supplied field/value: permissive codecs may not discard
            // malformed nested rates. Read only; never rewrite or mark these rows synced.
            chemical("CHEMICAL_SUPPLIED_FIELDS_CHANGED", rows.size) {
                check(RetainedJsonFields.preserves(encoded, chemicalJson.encodeToJsonElement(serializer, rows)))
            }
            chemical("CHEMICAL_DUPLICATE_RECORD_ID", rows.size) {
                check(rows.map { it.id }.distinct().size == rows.size)
            }
            rows.forEach { row ->
                chemical("CHEMICAL_RECORD_SCOPE", rows.size) {
                    check(row.id.isNotBlank() && row.id == row.id.trim() && row.vineyardId == scope[1])
                }
                chemical("CHEMICAL_PREFERRED_RATE_INVALID", rows.size) {
                    check(row.vineyardPreferredRate?.isValid != false)
                }
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
                    // The shared backend/iOS writes AU_NZ/US/UK/ZA; Android also writes
                    // lowercase tokens. Compare only; never migrate stored bytes here.
                    "terminology" -> value.lowercase(java.util.Locale.ROOT) in setOf("au_nz", "us", "uk", "za")
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
