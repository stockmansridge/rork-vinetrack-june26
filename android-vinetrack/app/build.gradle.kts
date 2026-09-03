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
        // v3.0.0 release — keep versionCode monotonically increasing.
        versionCode = 8
        versionName = "3.0.0"

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
    // AGP routes every exception thrown from a project-evaluation callback
    // through its own crash reporter (CrashReporting$afterEvaluate). When the
    // export machine cannot load that reporter class, the REAL exception is
    // discarded and replaced by a bare
    // `NoClassDefFoundError: com/android/build/gradle/internal/crash/PluginCrashReporter`,
    // leaving nothing to debug. So this callback is written to be incapable of
    // throwing: the cast is safe, and any surprise (e.g. this AGP version
    // renaming the unit-test builder interface) degrades to a warning and the
    // release unit-test variant simply stays enabled.
    beforeVariants(selector().withBuildType("release")) { variantBuilder ->
        runCatching {
            (variantBuilder as? HasUnitTestBuilder)?.enableUnitTest = false
        }.onFailure { error ->
            logger.warn(
                "VineTrack: could not disable the release unit-test variant " +
                    "(${error.javaClass.simpleName}: ${error.message}). Continuing with it enabled.",
            )
        }
    }
}

// The AAB export pipeline invokes `testReleaseUnitTest` by name. With the
// release unit-test variant disabled above, provide that task name as an alias
// that runs the IDENTICAL pure-JVM test suite against the debug variant — same
// bytecode, full coverage, and none of the release lint-model task chain that
// broke the export machine.
//
// The guard MUST satisfy two independent constraints at once:
//
//  1. TIMING — it has to run inside `afterEvaluate`. AGP creates its variant
//     tasks during ITS afterEvaluate, so a top-level check runs too early and
//     always sees the name as free. It would then register unconditionally and
//     collide with AGP's own task on any machine where the disabling above did
//     not take effect, throwing `Cannot add task 'testReleaseUnitTest' as a
//     task with that name already exists` from inside project evaluation —
//     which AGP funnels through its crash reporter, surfacing on the export
//     machine as the masked `PluginCrashReporter` NoClassDefFoundError with the
//     real cause destroyed. Our afterEvaluate is registered while this script
//     body runs, i.e. after AGP's, so AGP's runs first and this sees the truth.
//
//  2. LAZINESS — it must not call `tasks.findByName(...)`, which forces EAGER
//     realization of every task in the project just to test one name. `tasks.names`
//     answers the same question without realizing anything, and `register`
//     stays lazy, so the alias is configured only if actually requested.
//
// Both properties together mean this can no longer throw during evaluation,
// whether or not the release unit-test variant was successfully disabled.
afterEvaluate {
    if ("testReleaseUnitTest" !in tasks.names) {
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
    testImplementation(libs.kotlinx.coroutines.test)
}
