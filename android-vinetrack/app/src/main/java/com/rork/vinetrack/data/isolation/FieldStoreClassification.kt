package com.rork.vinetrack.data.isolation

/** Current-source classifications, not ownership grants. Mixed stores take the highest retention requirement. */
internal enum class FieldStoreClass { BUSINESS_CRITICAL, RECOVERABLE_CACHE, CREDENTIAL_SENSITIVE, UNRELATED_SDK }

internal object FieldStoreClassification {
    private val critical = setOf(
        "vinetrack_pending_writes", "vinetrack_pending_photos", "vinetrack_active_trip", "vinetrack_spray_tank_actuals",
        "vinetrack_start_tank_journal", "vinetrack_chemical_label_photos", "vinetrack_manual_spray_operations_v1",
        "vinetrack_manual_spray_drafts_v1", "vinetrack_work_task_materials", "vinetrack_paired_growth_capture",
        "vinetrack_pin_capture_evidence", "vinetrack_recovery_snapshots_v2", "vinetrack_local_planning",
        "vinetrack_domain_cache", "vinetrack_irrigation", "vineyard_insights_preview", "vinetrack_pruning",
        "vinetrack_fertiliser", "vinetrack_saved_chemicals_local", "resistance_plans", "vinetrack_map_alignment",
        "vinetrack_operational_tools", "vinetrack_button_templates", "vinetrack_yield_determination",
        "vinetrack_pruning_yield_settings", "vinetrack_operations", "vinetrack_canopy_rates", "vinetrack_gdd_settings",
        "vinetrack_bunch_weights", "vinetrack_app_prefs",
    )
    private val cache = setOf(
        "vinetrack_region_settings", "vinetrack_map", "vinetrack_home", "vinetrack_onboarding",
        "vinetrack_setup_wizard", "vinetrack_shared_grape_catalog", "optimal_ripeness_cache_v1",
        "optimal_ripeness_source_v1", "optimal_ripeness_daily_weather_v2", "master_front_label_v1",
        "vinetrack_entitlement", "admin_performance_capture", "release_reminders", "chemical_catalogue_discovery",
    )
    private val credentials = setOf("vinetrack_session", "vinetrack_biometric")
    // Application telemetry includes an installation ID used by alignment, but contains no field-work author proof.
    private val sdk = setOf("vinetrack_telemetry")
    val preferences: Map<String, FieldStoreClass> = buildMap {
        critical.forEach { put(it, FieldStoreClass.BUSINESS_CRITICAL) }
        cache.forEach { put(it, FieldStoreClass.RECOVERABLE_CACHE) }
        credentials.forEach { put(it, FieldStoreClass.CREDENTIAL_SENSITIVE) }
        sdk.forEach { put(it, FieldStoreClass.UNRELATED_SDK) }
    }

    val directories: Map<String, FieldStoreClass> = mapOf(
        "pending_pin_photos" to FieldStoreClass.BUSINESS_CRITICAL,
        "pin_photo_display_cache" to FieldStoreClass.BUSINESS_CRITICAL,
        "pending_chemical_label_photos" to FieldStoreClass.BUSINESS_CRITICAL,
        "scout_photos" to FieldStoreClass.BUSINESS_CRITICAL,
        "vintage-reports" to FieldStoreClass.BUSINESS_CRITICAL,
        "vintage-report-exports" to FieldStoreClass.BUSINESS_CRITICAL,
        "canopy_reference_images" to FieldStoreClass.RECOVERABLE_CACHE,
        "ripeness-heatmap" to FieldStoreClass.RECOVERABLE_CACHE,
        "vineyard_logos" to FieldStoreClass.RECOVERABLE_CACHE,
        "master-label-thumbnails" to FieldStoreClass.RECOVERABLE_CACHE,
        "cache/camera-captures" to FieldStoreClass.BUSINESS_CRITICAL,
        "cache/exports" to FieldStoreClass.RECOVERABLE_CACHE,
    )
}
