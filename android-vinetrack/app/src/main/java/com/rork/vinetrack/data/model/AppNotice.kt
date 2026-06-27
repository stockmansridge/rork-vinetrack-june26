package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * App-wide information notice ("system message") pushed from the backend
 * `app_notices` table and surfaced on the Home screen. Mirrors the iOS
 * `BackendAppNotice` model: multiple active notices can be shown at once,
 * sorted by priority then recency, and each can be dismissed per-device.
 */
@Serializable
data class AppNotice(
    val id: String,
    val title: String,
    val message: String,
    @SerialName("notice_type") val noticeType: String = "info",
    val priority: Int = 0,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("ends_at") val endsAt: String? = null,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    /** Coarse type used for icon + tint, mirroring iOS `AppNoticeType`. */
    val type: AppNoticeType get() = AppNoticeType.from(noticeType)

    /**
     * Whether the notice should currently display based on the active flag,
     * soft-delete state, and optional start/end windows. Mirrors iOS
     * `BackendAppNotice.isCurrentlyVisible`.
     */
    fun isCurrentlyVisible(nowMs: Long = System.currentTimeMillis()): Boolean {
        if (!isActive || deletedAt != null) return false
        startsAt?.let { parseIsoToEpochMs(it)?.let { s -> if (nowMs < s) return false } }
        endsAt?.let { parseIsoToEpochMs(it)?.let { e -> if (nowMs > e) return false } }
        return true
    }

    val createdAtEpochMs: Long get() = createdAt?.let { parseIsoToEpochMs(it) } ?: 0L
}

enum class AppNoticeType {
    INFO, WARNING, SUCCESS, CRITICAL;

    companion object {
        fun from(raw: String): AppNoticeType = when (raw.lowercase()) {
            "warning" -> WARNING
            "success" -> SUCCESS
            "critical" -> CRITICAL
            else -> INFO
        }
    }
}
