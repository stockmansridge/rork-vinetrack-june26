package com.rork.vinetrack.data

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Pure helpers for the client telemetry heartbeat (SQL 154) so the exact
 * payload contract is unit-testable without Android framework classes.
 *
 * Canonical values for this app: `p_app_type = "android"`,
 * `p_platform = "android"`, `p_os_name = "Android"`. Only product-support
 * metadata is involved — never IMEI/serial/MAC/advertising IDs or location.
 */
object ClientDeviceMetadata {

    /** Canonical app/platform pair accepted by `record_my_client_activity`. */
    const val APP_TYPE: String = "android"
    const val PLATFORM: String = "android"
    const val OS_NAME: String = "Android"

    /**
     * Human-useful manufacturer + model, e.g. "Samsung SM-S938B" or
     * "Google Pixel 9 Pro". Title-cases the manufacturer and drops it when
     * the model already starts with it (avoids "samsung samsung ...").
     * Control characters are stripped and the result is length-limited to
     * mirror the server-side sanitiser.
     */
    fun formatModel(manufacturer: String?, model: String?, max: Int = 80): String {
        val mfr = manufacturer?.trim().orEmpty()
        val mdl = model?.trim().orEmpty()
        val combined = when {
            mfr.isEmpty() && mdl.isEmpty() -> "Android Device"
            mdl.isEmpty() -> titleCase(mfr)
            mfr.isEmpty() -> mdl
            mdl.startsWith(mfr, ignoreCase = true) ->
                mdl.replaceFirstChar { it.uppercaseChar() }
            else -> "${titleCase(mfr)} $mdl"
        }
        return sanitise(combined, max)
    }

    /**
     * Builds the exact RPC body for `record_my_client_activity`.
     * `p_vineyard_id` is omitted entirely when no vineyard is selected.
     */
    fun buildHeartbeatPayload(
        clientInstanceId: String,
        deviceFamily: String,
        deviceModel: String,
        osVersion: String,
        appVersion: String,
        appBuild: String,
        vineyardId: String?,
    ): JsonObject = buildJsonObject {
        put("p_client_instance_id", clientInstanceId)
        put("p_app_type", APP_TYPE)
        put("p_platform", PLATFORM)
        put("p_device_family", deviceFamily)
        put("p_device_model", deviceModel)
        put("p_os_name", OS_NAME)
        put("p_os_version", osVersion)
        put("p_app_version", appVersion)
        put("p_app_build", appBuild)
        if (vineyardId != null) put("p_vineyard_id", vineyardId)
    }

    /** Trim, strip control characters and length-limit (server parity). */
    fun sanitise(value: String, max: Int = 80): String =
        value.replace(Regex("\\p{Cntrl}+"), " ").trim().take(max)

    private fun titleCase(value: String): String =
        value.split(' ').joinToString(" ") { word ->
            word.replaceFirstChar { c -> if (c.isLowerCase()) c.titlecase() else c.toString() }
        }
}
