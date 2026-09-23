package com.rork.vinetrack.data

import android.net.Uri
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Shared, read-only policy contract from get_app_release_policy. */
@Serializable
data class AppReleasePolicy(
    val platform: String,
    @SerialName("latest_version") val latestVersion: String,
    @SerialName("latest_build") val latestBuild: Long,
    @SerialName("minimum_supported_version") val minimumSupportedVersion: String,
    @SerialName("minimum_supported_build") val minimumSupportedBuild: Long,
    @SerialName("update_title") val updateTitle: String,
    @SerialName("update_message") val updateMessage: String,
    @SerialName("store_url") val storeUrl: String,
    val active: Boolean,
    @SerialName("updated_at") val updatedAt: String,
) {
    fun decision(installedBuild: Long): ReleaseDecision = when {
        !active || platform != "android" || latestBuild < minimumSupportedBuild ||
            installedBuild < 0 || installedBuild >= latestBuild -> ReleaseDecision.NONE
        installedBuild < minimumSupportedBuild -> ReleaseDecision.REQUIRED
        else -> ReleaseDecision.OPTIONAL
    }

    val displayTitle: String
        get() = safeCopy(updateTitle, "Update available", 100)

    val displayMessage: String
        get() = safeCopy(updateMessage, "A newer version of VineTrack is available.", 800)

    private fun safeCopy(value: String, fallback: String, limit: Int): String {
        val trimmed = value.trim()
        return trimmed.takeIf {
            it.isNotEmpty() && it.length <= limit && it.none { character -> character.isISOControl() && character != '\n' }
        } ?: fallback
    }

    val officialStoreUri: Uri?
        get() {
            val uri = runCatching { Uri.parse(storeUrl) }.getOrNull() ?: return null
            return uri.takeIf {
                it.scheme == "https" && it.host == "play.google.com" &&
                    it.path == "/store/apps/details" && it.getQueryParameter("id") == "com.rork.vinetrack"
            }
        }
}

enum class ReleaseDecision { NONE, OPTIONAL, REQUIRED }
