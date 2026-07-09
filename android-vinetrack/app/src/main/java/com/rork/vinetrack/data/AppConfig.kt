package com.rork.vinetrack.data

import android.util.Log
import com.rork.vinetrack.BuildConfig
import com.rork.vinetrack.Config

/**
 * Centralised configuration, mirroring the iOS `AppConfig`.
 * Reads build-injected `EXPO_PUBLIC_*` values from [Config], falling back to
 * the public Supabase project URL used by VineTrack.
 */
object AppConfig {

    private const val DEFAULT_SUPABASE_URL = "https://tbafuqwruefgkbyxrxyb.supabase.co"

    /**
     * Guaranteed Android-only fallback for the public Supabase config. Used only
     * when both the Rork build-injected [Config] and Gradle [BuildConfig] fail to
     * land in the compiled APK. These are PUBLIC values:
     *  - The Supabase project URL is public.
     *  - The anon/public key is safe to ship in a client (it is RLS-gated).
     * The service-role key is NEVER referenced here.
     */
    private const val FALLBACK_SUPABASE_URL = "https://tbafuqwruefgkbyxrxyb.supabase.co"
    private const val FALLBACK_SUPABASE_ANON_KEY =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRiYWZ1cXdydWVmZ2tieXhyeHliIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcyOTY0NDcsImV4cCI6MjA5Mjg3MjQ0N30.tvOzn1ketbd0zYJWDujh_DGcWVDeitJaoVWw3aqtuRw"

    /**
     * Google OAuth WEB client ID — a public identifier (not a secret), safe to
     * ship in the client just like the Supabase anon key. Used as the
     * Credential Manager serverClientId; must be listed in the Supabase Google
     * provider's authorized client IDs.
     */
    private const val FALLBACK_GOOGLE_WEB_CLIENT_ID =
        "529457473857-la1vk1ibirs5if7dj3n5lap2u8admgmi.apps.googleusercontent.com"

    val supabaseUrl: String
        get() = resolve("SUPABASE_URL", "EXPO_PUBLIC_SUPABASE_URL")
            ?.trimEnd('/')
            ?: DEFAULT_SUPABASE_URL

    val supabaseAnonKey: String
        get() = resolve("SUPABASE_ANON_KEY", "EXPO_PUBLIC_SUPABASE_ANON_KEY") ?: ""

    val isSupabaseConfigured: Boolean
        get() = supabaseAnonKey.isNotBlank()

    /**
     * Google OAuth WEB client ID (a public identifier, not a secret) used as
     * the Credential Manager serverClientId. Must also be listed in the
     * Supabase Google provider's authorized client IDs so the id_token grant
     * accepts tokens minted for it.
     */
    val googleWebClientId: String
        get() = resolve("GOOGLE_WEB_CLIENT_ID", "EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID") ?: ""

    val isGoogleSignInConfigured: Boolean
        get() = googleWebClientId.isNotBlank()

    /**
     * RevenueCat Android public SDK key (goog_…). A PUBLIC client key, safe to
     * ship in the APK — mirrors iOS `AppConfig.revenueCatIOSAPIKey`. Empty when
     * not configured; the subscription service degrades gracefully.
     */
    val revenueCatAndroidApiKey: String
        get() = resolve("REVENUECAT_ANDROID_API_KEY", "EXPO_PUBLIC_REVENUECAT_ANDROID_API_KEY") ?: ""

    val isRevenueCatConfigured: Boolean
        get() = revenueCatAndroidApiKey.isNotBlank()

    /**
     * Emits a safe, one-line diagnostic about the runtime Supabase config.
     * Never prints the key itself — only presence flags, the resolved URL,
     * and the anon key length so we can confirm the build-injected values are
     * actually reaching the APK at runtime.
     */
    fun logDiagnostics() {
        if (!BuildConfig.DEBUG) return
        val url = supabaseUrl
        val key = supabaseAnonKey
        val masked = if (key.length >= 8) {
            "${key.take(4)}…${key.takeLast(4)}"
        } else {
            "(too short to mask)"
        }
        Log.i(
            TAG,
            "Supabase config — URL present: ${url.isNotBlank()} (\"$url\"), " +
                "anon key present: ${key.isNotBlank()}, anon key length: ${key.length}, " +
                "anon key preview: $masked",
        )
    }

    private const val TAG = "VineTrackConfig"

    /**
     * A single source-by-source diagnostic snapshot for the on-screen debug panel.
     * Reports presence/length only — never the key itself. Each field is read
     * directly from its source (not via [resolve]) so we can see exactly which
     * layer is or isn't landing in the running APK.
     */
    data class Diagnostics(
        val supabaseUrl: String,
        val supabaseUrlPresent: Boolean,
        val rorkConfigAnonKeyPresent: Boolean,
        val rorkConfigAnonKeyLength: Int,
        val buildConfigAnonKeyPresent: Boolean,
        val buildConfigAnonKeyLength: Int,
        val fallbackAnonKeyPresent: Boolean,
        val fallbackAnonKeyLength: Int,
        val finalAnonKeyPresent: Boolean,
        val finalAnonKeyLength: Int,
    )

    fun diagnostics(): Diagnostics {
        val rorkConfigKey = Config.allValues["EXPO_PUBLIC_SUPABASE_ANON_KEY"]
            ?.trim()
            .orEmpty()
        val buildConfigKey = BuildConfig.SUPABASE_ANON_KEY.trim()
        val fallbackKey = FALLBACK_SUPABASE_ANON_KEY.trim()
        val finalKey = supabaseAnonKey
        val url = supabaseUrl
        return Diagnostics(
            supabaseUrl = url,
            supabaseUrlPresent = url.isNotBlank(),
            rorkConfigAnonKeyPresent = rorkConfigKey.isNotBlank(),
            rorkConfigAnonKeyLength = rorkConfigKey.length,
            buildConfigAnonKeyPresent = buildConfigKey.isNotBlank(),
            buildConfigAnonKeyLength = buildConfigKey.length,
            fallbackAnonKeyPresent = fallbackKey.isNotBlank(),
            fallbackAnonKeyLength = fallbackKey.length,
            finalAnonKeyPresent = finalKey.isNotBlank(),
            finalAnonKeyLength = finalKey.length,
        )
    }

    /**
     * Resolves a value from, in priority order:
     *   1. The Rork build-injected [Config] map (EXPO_PUBLIC_* values).
     *   2. Gradle [BuildConfig] fields injected from the build environment.
     *   3. Explicit Android fallback constants (public values only).
     * Blank/empty strings at any layer are treated as missing so they never
     * block a later layer. This makes config robust whether or not the Rork
     * Config.kt or Gradle BuildConfig injection lands in the compiled APK.
     */
    private fun resolve(vararg keys: String): String? {
        for (key in keys) {
            val value = Config.allValues[key]?.trim()
            if (!value.isNullOrEmpty()) return value
        }
        for (key in keys) {
            val value = buildConfigValue(key)?.trim()
            if (!value.isNullOrEmpty()) return value
        }
        for (key in keys) {
            val value = fallbackValue(key)?.trim()
            if (!value.isNullOrEmpty()) return value
        }
        return null
    }

    private fun fallbackValue(key: String): String? = when (key) {
        "SUPABASE_URL", "EXPO_PUBLIC_SUPABASE_URL" -> FALLBACK_SUPABASE_URL
        "SUPABASE_ANON_KEY", "EXPO_PUBLIC_SUPABASE_ANON_KEY" -> FALLBACK_SUPABASE_ANON_KEY
        "GOOGLE_WEB_CLIENT_ID", "EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID" -> FALLBACK_GOOGLE_WEB_CLIENT_ID
        else -> null
    }

    private fun buildConfigValue(key: String): String? = when (key) {
        "SUPABASE_URL", "EXPO_PUBLIC_SUPABASE_URL" -> BuildConfig.SUPABASE_URL
        "SUPABASE_ANON_KEY", "EXPO_PUBLIC_SUPABASE_ANON_KEY" -> BuildConfig.SUPABASE_ANON_KEY
        "GOOGLE_WEB_CLIENT_ID", "EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID" -> BuildConfig.GOOGLE_WEB_CLIENT_ID
        "REVENUECAT_ANDROID_API_KEY", "EXPO_PUBLIC_REVENUECAT_ANDROID_API_KEY" -> BuildConfig.REVENUECAT_ANDROID_API_KEY
        else -> null
    }
}
