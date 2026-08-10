import com.android.build.api.variant.HasUnitTestBuilder
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

/**
 * Resolves a build-time config value from, in priority order:
 *   1. The build environment (System.getenv) — how the Rork CI passes EXPO_PUBLIC_* values.
 *   2. Gradle project properties (-P flags / gradle.properties).
 *   3. local.properties on the build machine.
 *   4. The Rork-managed Config.kt constants (populated with the project's
 *      public environment values), so keys that must land in the merged
 *      AndroidManifest (e.g. the Google Maps key) always resolve at build time.
 * Returns an empty string when nothing is found so the APK always compiles.
 */
val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

val rorkConfigKtText: String = file("src/main/java/com/rork/vinetrack/Config.kt")
    .takeIf { it.exists() }
    ?.readText()
    ?: ""

fun configKtValue(key: String): String =
    Regex("const val $key\\s*=\\s*\"([^\"]*)\"")
        .find(rorkConfigKtText)
        ?.groupValues?.get(1)
        ?.trim()
        ?: ""

fun resolveBuildConfigValue(vararg keys: String): String {
    for (key in keys) {
        System.getenv(key)?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        (project.findProperty(key) as? String)?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        localProperties.getProperty(key)?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        configKtValue(key).takeIf { it.isNotBlank() }?.let { return it }
    }
    return ""
}

android {
    namespace = "com.rork.vinetrack"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.rork.vinetrack"
        minSdk = 24
        targetSdk = 36
        versionCode = 6
        versionName = "0.0.6"

        val supabaseUrl = resolveBuildConfigValue(
            "SUPABASE_URL",
            "EXPO_PUBLIC_SUPABASE_URL",
        )
        val supabaseAnonKey = resolveBuildConfigValue(
            "SUPABASE_ANON_KEY",
            "EXPO_PUBLIC_SUPABASE_ANON_KEY",
        )
        buildConfigField("String", "SUPABASE_URL", "\"$supabaseUrl\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"$supabaseAnonKey\"")

        val mapsApiKey = resolveBuildConfigValue(
            "GOOGLE_MAPS_API_KEY",
            "EXPO_PUBLIC_GOOGLE_MAPS_API_KEY",
            "ANDROID_MAPS_API_KEY",
        )
        buildConfigField("String", "MAPS_API_KEY", "\"$mapsApiKey\"")
        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey

        // Google OAuth WEB client ID (public value) used by Credential Manager
        // as the serverClientId so the returned ID token is accepted by
        // Supabase's id_token grant. Never a secret.
        val googleWebClientId = resolveBuildConfigValue(
            "GOOGLE_WEB_CLIENT_ID",
            "EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID",
        )
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"$googleWebClientId\"")

        // RevenueCat Android public SDK key (goog_…). A PUBLIC client key —
        // never the secret API key. Mirrors iOS AppConfig.revenueCatIOSAPIKey.
        val revenueCatAndroidKey = resolveBuildConfigValue(
            "REVENUECAT_ANDROID_API_KEY",
            "EXPO_PUBLIC_REVENUECAT_ANDROID_API_KEY",
        )
        buildConfigField("String", "REVENUECAT_ANDROID_API_KEY", "\"$revenueCatAndroidKey\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Debug signing for normal APK/device builds. Rork injects the
            // persistent project upload key automatically when exporting an
            // AAB for Play Console — never hardcode a keystore here (an
            // absolute sandbox path breaks the export build environment).
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // lint-vital forks its own multi-hundred-MB analysis JVM and AGP schedules it
    // concurrently with mergeDexRelease during `bundleRelease`. On the constrained
    // AAB export machine that overlap is what pushes the build over the memory
    // ceiling and kills the daemon. Correctness checks already run via `test` and
    // the Kotlin compiler, so release lint is not the gate here.
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

androidComponents {
    // The unit tests are pure JVM and already run against the debug variant
    // (identical bytecode) — building them AGAIN for release adds no coverage
    // but drags `releaseUnitTestRuntimeClasspath` → `generateReleaseLintModel`
    // → LintModelWriterTask into the AAB export, which fails on the export
    // machine's constrained/cold lint classpath (missing VariantInputs class).
    // Disabling release unit tests removes that whole task chain.
    //
    // Safe cast: any exception thrown inside this callback surfaces during
    // AGP's afterEvaluate, where the export machine can't even load AGP's
    // crash reporter (PluginCrashReporter) — producing a masked
    // "Failed to notify project evaluation listener" configuration failure.
    beforeVariants(selector().withBuildType("release")) { variantBuilder ->
        (variantBuilder as? HasUnitTestBuilder)?.enableUnitTest = false
    }
}

// The AAB export pipeline invokes `testReleaseUnitTest` by name. With the
// release unit-test variant disabled above, provide that task name as an alias
// that runs the IDENTICAL pure-JVM test suite against the debug variant — same
// bytecode, full coverage, and none of the release lint-model task chain that
// broke the export machine.
//
// Registered in afterEvaluate WITH an existence check: AGP creates its own
// variant tasks during ITS afterEvaluate (which runs first because the plugin
// is applied before this script body). An eager top-level register of the same
// name collides with AGP's registration whenever the variant disabling above
// does not apply, and that collision throws inside project evaluation — the
// exact masked configuration failure seen on the AAB export machine.
afterEvaluate {
    if (tasks.findByName("testReleaseUnitTest") == null) {
        tasks.register("testReleaseUnitTest") {
            group = "verification"
            description =
                "Alias: runs the unit tests against the debug variant (release unit tests are disabled)."
            dependsOn("testDebugUnitTest")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.android)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.serialization.json)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.koin.androidx.compose)
    implementation(libs.maps.compose)
    implementation(libs.play.services.location)
    implementation(libs.androidx.exifinterface)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.fragment.ktx)
    implementation(libs.androidx.credentials)
    implementation(libs.androidx.credentials.play.services)
    implementation(libs.googleid)
    implementation(libs.revenuecat.purchases)
    debugImplementation(libs.androidx.ui.tooling)
    testImplementation(libs.junit)
}
