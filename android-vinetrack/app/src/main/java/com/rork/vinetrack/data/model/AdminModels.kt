package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Platform-level System Admin models, mirroring the iOS `SupabaseAdminRepository`
 * and `SupabaseSystemAdminRepository` DTOs. These power the Android Admin
 * Dashboard + System Admin tools. Every field name matches the `admin_*` /
 * `*_system_admin*` / `*_system_feature_flag*` RPC payloads exactly.
 *
 * Access is gated server-side: only active rows in `public.system_admins` can
 * read these surfaces (the RPCs enforce it). Vineyard owner/manager roles do
 * NOT grant access here.
 */

// MARK: - Engagement / scale

@Serializable
data class AdminEngagementSummary(
    @SerialName("total_users") val totalUsers: Int = 0,
    @SerialName("total_vineyards") val totalVineyards: Int = 0,
    @SerialName("total_pins") val totalPins: Int = 0,
    @SerialName("total_spray_records") val totalSprayRecords: Int = 0,
    @SerialName("total_work_tasks") val totalWorkTasks: Int = 0,
    @SerialName("signed_in_last_7_days") val signedInLast7Days: Int = 0,
    @SerialName("signed_in_last_30_days") val signedInLast30Days: Int = 0,
    @SerialName("new_users_last_30_days") val newUsersLast30Days: Int = 0,
    @SerialName("pending_invitations") val pendingInvitations: Int = 0,
)

@Serializable
data class AdminPlatformScale(
    @SerialName("total_hectares_under_management") val totalHectaresUnderManagement: Double = 0.0,
    @SerialName("total_vineyards") val totalVineyards: Int = 0,
    @SerialName("total_active_paddocks") val totalActivePaddocks: Int = 0,
    @SerialName("total_paddocks_with_area") val totalPaddocksWithArea: Int = 0,
    @SerialName("average_hectares_per_vineyard") val averageHectaresPerVineyard: Double = 0.0,
)

// MARK: - Browser rows

@Serializable
data class AdminUserRow(
    val id: String,
    val email: String = "",
    @SerialName("full_name") val fullName: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("last_sign_in_at") val lastSignInAt: String? = null,
    @SerialName("vineyard_count") val vineyardCount: Int = 0,
    @SerialName("owned_count") val ownedCount: Int = 0,
    @SerialName("block_count") val blockCount: Int? = 0,
) {
    val displayName: String
        get() = fullName?.trim()?.takeIf { it.isNotEmpty() } ?: email
}

@Serializable
data class AdminVineyardRow(
    val id: String,
    val name: String = "",
    @SerialName("owner_id") val ownerId: String? = null,
    @SerialName("owner_email") val ownerEmail: String? = null,
    @SerialName("owner_full_name") val ownerFullName: String? = null,
    val country: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("member_count") val memberCount: Int = 0,
    @SerialName("pending_invites") val pendingInvites: Int = 0,
) {
    val ownerDisplay: String
        get() = ownerFullName?.trim()?.takeIf { it.isNotEmpty() } ?: (ownerEmail ?: "\u2014")
}

@Serializable
data class AdminUserVineyardRow(
    val id: String,
    val name: String = "",
    val role: String? = null,
    @SerialName("is_owner") val isOwner: Boolean = false,
    val country: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("member_count") val memberCount: Int = 0,
)

@Serializable
data class AdminInvitationRow(
    val id: String,
    val email: String = "",
    val role: String = "",
    val status: String = "",
    @SerialName("vineyard_id") val vineyardId: String? = null,
    @SerialName("vineyard_name") val vineyardName: String? = null,
    @SerialName("invited_by") val invitedBy: String? = null,
    @SerialName("invited_by_email") val invitedByEmail: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("expires_at") val expiresAt: String? = null,
)

@Serializable
data class AdminPinRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String? = null,
    @SerialName("vineyard_name") val vineyardName: String? = null,
    val title: String = "",
    val category: String? = null,
    val status: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("is_completed") val isCompleted: Boolean = false,
)

@Serializable
data class AdminSprayRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String? = null,
    @SerialName("vineyard_name") val vineyardName: String? = null,
    @SerialName("spray_reference") val sprayReference: String? = null,
    @SerialName("operation_type") val operationType: String? = null,
    val date: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

@Serializable
data class AdminWorkTaskRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String? = null,
    @SerialName("vineyard_name") val vineyardName: String? = null,
    @SerialName("task_type") val taskType: String? = null,
    @SerialName("paddock_name") val paddockName: String? = null,
    val date: String? = null,
    @SerialName("duration_hours") val durationHours: Double? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

// MARK: - Billing grants / internal unlimited access

/**
 * One manual / internal unlimited-access grant, as returned by
 * `admin_list_manual_unlimited_grants()`. Reporting + management only — never
 * used for client-side entitlement enforcement. Mirrors the iOS
 * `ManualUnlimitedGrant`.
 */
@Serializable
data class ManualUnlimitedGrant(
    @SerialName("subscription_id") val subscriptionId: String,
    @SerialName("owner_user_id") val ownerUserId: String,
    @SerialName("owner_email") val ownerEmail: String? = null,
    @SerialName("owner_full_name") val ownerFullName: String? = null,
    @SerialName("primary_vineyard_id") val primaryVineyardId: String? = null,
    @SerialName("vineyard_name") val vineyardName: String? = null,
    val status: String = "manual",
    @SerialName("unlimited_licences") val unlimitedLicences: Boolean = false,
    @SerialName("manual_grant_reason") val manualGrantReason: String? = null,
    @SerialName("manual_grant_expires_at") val manualGrantExpiresAt: String? = null,
    @SerialName("manual_grant_revoked_at") val manualGrantRevokedAt: String? = null,
    @SerialName("active_licences") val activeLicences: Int = 0,
    @SerialName("is_active") val isActive: Boolean = false,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
) {
    /** Best owner label: full name, else email, else short id. */
    val ownerDisplay: String
        get() {
            ownerFullName?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            ownerEmail?.takeIf { it.isNotEmpty() }?.let { return it }
            return ownerUserId.take(8)
        }
}

// MARK: - System admin management

@Serializable
data class SystemAdminUserRow(
    @SerialName("user_id") val userId: String,
    val email: String? = null,
    @SerialName("is_active") val isActive: Boolean = false,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("created_by") val createdBy: String? = null,
) {
    val displayEmail: String get() = email?.takeIf { it.isNotBlank() } ?: "\u2014"
}

@Serializable
data class SystemFeatureFlagRow(
    val key: String,
    @SerialName("value_type") val valueType: String? = null,
    val category: String? = null,
    val label: String? = null,
    val description: String? = null,
    @SerialName("is_enabled") val isEnabled: Boolean = false,
    @SerialName("updated_at") val updatedAt: String? = null,
) {
    val displayLabel: String
        get() = label?.takeIf { it.isNotEmpty() }
            ?: key.split("_").joinToString(" ") { part ->
                part.replaceFirstChar { it.uppercase() }
            }
}

// MARK: - User login / activity

/** Login-recency tier mirroring the `status` string from `admin_list_user_login_activity()`. */
enum class UserActivityStatus(val raw: String, val label: String) {
    Never("never", "Never logged in"),
    ActiveRecent("active_recent", "Active recently"),
    Active30d("active_30d", "Active last 30 days"),
    Inactive30d("inactive_30d", "Inactive over 30 days"),
    Inactive90d("inactive_90d", "Inactive over 90 days");

    companion object {
        fun from(raw: String?): UserActivityStatus =
            entries.firstOrNull { it.raw == raw } ?: Never
    }
}

@Serializable
data class UserLoginActivityRow(
    @SerialName("user_id") val userId: String,
    val email: String? = null,
    @SerialName("display_name") val displayName: String? = null,
    @SerialName("account_created_at") val accountCreatedAt: String? = null,
    @SerialName("last_sign_in_at") val lastSignInAt: String? = null,
    @SerialName("vineyard_ids") val vineyardIds: List<String>? = null,
    @SerialName("vineyard_names") val vineyardNames: List<String>? = null,
    val roles: List<String>? = null,
    @SerialName("app_platform") val appPlatform: String? = null,
    @SerialName("app_version") val appVersion: String? = null,
    @SerialName("app_build") val appBuild: String? = null,
    @SerialName("device_model") val deviceModel: String? = null,
    @SerialName("os_version") val osVersion: String? = null,
    val status: String? = null,
) {
    val bestName: String
        get() {
            displayName?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            (email ?: "").substringBefore("@").takeIf { it.isNotEmpty() }?.let { return it }
            return email ?: ""
        }

    val displayAppVersion: String?
        get() {
            val v = appVersion?.takeIf { it.isNotEmpty() } ?: return null
            val b = appBuild?.takeIf { it.isNotEmpty() }
            return if (b != null) "$v ($b)" else v
        }

    val displayDevice: String?
        get() = listOfNotNull(
            deviceModel?.takeIf { it.isNotEmpty() },
            osVersion?.takeIf { it.isNotEmpty() },
        ).takeIf { it.isNotEmpty() }?.joinToString(" \u00b7 ")

    val activityStatus: UserActivityStatus get() = UserActivityStatus.from(status)
}
