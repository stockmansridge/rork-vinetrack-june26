package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * Best-effort, throttled client telemetry heartbeat (SQL 154), mirroring the
 * iOS `ClientTelemetryService`.
 *
 * Reports safe, installation-scoped device/app metadata to the
 * `record_my_client_activity` RPC so the System Admin User Activity page can
 * show real usage (App / Platform / Device / OS) instead of "Unknown".
 *
 * Privacy rules:
 * * The client instance ID is a random UUID generated once per installation
 *   and stored in SharedPreferences — never a hardware identifier, never the
 *   Android advertising ID.
 * * Only manufacturer + model, Android version, app version/build and the
 *   Phone/Tablet family are reported. No IMEI/serial/MAC/location/IP.
 * * Telemetry is best-effort: failures are swallowed and never block login
 *   or normal app use. Throttled to once per 15 minutes unless the metadata
 *   signature (version, vineyard, OS) materially changes.
 */
class ClientTelemetryRepository(app: Application, private val session: SessionStore) {

    private val appContext: Application = app
    private val prefs: SharedPreferences =
        app.getSharedPreferences("vinetrack_telemetry", Context.MODE_PRIVATE)

    /**
     * Random per-installation identifier. Survives sign-out (the same
     * installation used by a new account creates a separate user/client
     * association server-side); reset only on reinstall.
     */
    private val clientInstanceId: String
        get() {
            prefs.getString(KEY_CLIENT_ID, null)?.let { return it }
            val id = UUID.randomUUID().toString()
            prefs.edit().putString(KEY_CLIENT_ID, id).apply()
            return id
        }

    /**
     * Send a heartbeat if due. Safe to call from any auth/foreground/
     * vineyard-change hook — internal throttling prevents over-reporting.
     * Never throws to the caller when wrapped in runCatching at the call
     * site; failures leave the throttle untouched so the next trigger
     * retries conservatively.
     */
    suspend fun reportActivity(vineyardId: String?) = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) return@withContext
        val token = session.accessToken ?: return@withContext

        val packageInfo = runCatching {
            appContext.packageManager.getPackageInfo(appContext.packageName, 0)
        }.getOrNull()
        val versionName = packageInfo?.versionName ?: "0.0"
        val buildCode = packageInfo?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.longVersionCode.toString()
            else @Suppress("DEPRECATION") it.versionCode.toString()
        } ?: "0"
        val osVersion = Build.VERSION.RELEASE ?: ""

        val signature = listOf(versionName, buildCode, osVersion, vineyardId ?: "-")
            .joinToString("|")
        val lastSignature = prefs.getString(KEY_LAST_SIGNATURE, null)
        val lastSentAt = prefs.getLong(KEY_LAST_SENT_AT, 0L)
        val now = System.currentTimeMillis()
        if (signature == lastSignature && now - lastSentAt < MIN_INTERVAL_MS) return@withContext

        val isTablet = appContext.resources.configuration.smallestScreenWidthDp >= 600
        // "Samsung SM-S938B" / "Google Pixel 9 Pro" — manufacturer title-cased,
        // deduped when the model already includes it (contract-tested helper).
        val model = ClientDeviceMetadata.formatModel(Build.MANUFACTURER, Build.MODEL)

        val body = ClientDeviceMetadata.buildHeartbeatPayload(
            clientInstanceId = clientInstanceId,
            deviceFamily = if (isTablet) "Tablet" else "Phone",
            deviceModel = model,
            osVersion = osVersion,
            appVersion = versionName,
            appBuild = buildCode,
            vineyardId = vineyardId,
        )

        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("record_my_client_activity")
        ) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (response.status.isSuccess()) {
            prefs.edit()
                .putString(KEY_LAST_SIGNATURE, signature)
                .putLong(KEY_LAST_SENT_AT, now)
                .apply()
        }
    }

    /**
     * Clears user-linked throttle state on sign-out so the next account's
     * first heartbeat is sent immediately. The installation ID is kept.
     */
    fun clearUserCache() {
        prefs.edit()
            .remove(KEY_LAST_SIGNATURE)
            .remove(KEY_LAST_SENT_AT)
            .apply()
    }

    private companion object {
        const val KEY_CLIENT_ID = "telemetry_client_instance_id"
        const val KEY_LAST_SIGNATURE = "telemetry_last_signature"
        const val KEY_LAST_SENT_AT = "telemetry_last_sent_at"
        const val MIN_INTERVAL_MS = 15L * 60L * 1000L
    }
}
