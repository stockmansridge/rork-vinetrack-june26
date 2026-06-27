package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Alert severity tier. Mirrors the iOS `AlertSeverity`. Ordered info <
 * warning < critical so the highest severity can drive aggregate badges.
 */
enum class AlertSeverity(val raw: String, val rank: Int) {
    Info("info", 0),
    Warning("warning", 1),
    Critical("critical", 2);

    companion object {
        fun fromRaw(raw: String?): AlertSeverity =
            entries.firstOrNull { it.raw == raw } ?: Info
    }
}

/** Alert category. Mirrors the iOS `AlertType` raw values 1:1. */
enum class AlertType(val raw: String) {
    IrrigationNeeded("irrigation_needed"),
    AgedPins("aged_pins"),
    WeatherRisk("weather_risk"),
    SprayJobDue("spray_job_due"),
    SyncIssue("sync_issue"),
    DiseaseDownyMildew("disease_downy_mildew"),
    DiseasePowderyMildew("disease_powdery_mildew"),
    DiseaseBotrytis("disease_botrytis"),
    RainStarted("rain_started"),
    Rain24hSummary("rain_24h_summary"),
    RainTodayThresholdExceeded("rain_today_threshold_exceeded"),
    WorkTaskOverdue("work_task_overdue"),
    ManyOpenPins("many_open_pins"),
    ForecastSetupMissingGeometry("forecast_setup_missing_geometry"),
    CostingSetupIncomplete("costing_setup_incomplete");

    companion object {
        fun fromRaw(raw: String?): AlertType? = entries.firstOrNull { it.raw == raw }
    }
}

/** Tap action target. Mirrors the iOS `AlertAction`. */
enum class AlertAction(val raw: String) {
    OpenIrrigationAdvisor("open_irrigation_advisor"),
    OpenPins("open_pins"),
    OpenSprayProgram("open_spray_program"),
    OpenSprayRecord("open_spray_record"),
    OpenWeather("open_weather"),
    OpenDiseaseRisk("open_disease_risk"),
    OpenWorkTasks("open_work_tasks"),
    OpenPaddocks("open_paddocks"),
    OpenCostReports("open_cost_reports");

    companion object {
        fun fromRaw(raw: String?): AlertAction? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * A vineyard alert row from `vineyard_alerts`. Reads the same shared Supabase
 * table iOS writes to, so alerts generated on any client surface here.
 */
@Serializable
data class BackendAlert(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("alert_type") val alertType: String,
    val severity: String = "info",
    val title: String = "",
    val message: String = "",
    @SerialName("related_table") val relatedTable: String? = null,
    @SerialName("related_id") val relatedId: String? = null,
    @SerialName("paddock_id") val paddockId: String? = null,
    val action: String? = null,
    @SerialName("dedup_key") val dedupKey: String = "",
    @SerialName("generated_for_date") val generatedForDate: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("expires_at") val expiresAt: String? = null,
    @SerialName("created_by") val createdBy: String? = null,
) {
    val typedSeverity: AlertSeverity get() = AlertSeverity.fromRaw(severity)
    val typedAlertType: AlertType? get() = AlertType.fromRaw(alertType)
    val typedAction: AlertAction? get() = AlertAction.fromRaw(action)
}

/** Per-user read/dismiss status from `vineyard_alert_user_status`. */
@Serializable
data class BackendAlertUserStatus(
    @SerialName("alert_id") val alertId: String,
    @SerialName("user_id") val userId: String = "",
    @SerialName("read_at") val readAt: String? = null,
    @SerialName("dismissed_at") val dismissedAt: String? = null,
)

/** An alert joined with the caller's read/dismiss status. */
data class AlertWithStatus(
    val alert: BackendAlert,
    val status: BackendAlertUserStatus?,
) {
    val id: String get() = alert.id
    val isRead: Boolean get() = status?.readAt != null
    val isDismissed: Boolean get() = status?.dismissedAt != null
}
