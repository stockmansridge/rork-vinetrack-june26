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
 * Returns an empty string when nothing is found so the APK always compiles.
 */
val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

fun resolveBuildConfigValue(vararg keys: String): String {
    for (key in keys) {
        System.getenv(key)?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        (project.findProperty(key) as? String)?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        localProperties.getProperty(key)?.takeIf { it.isNotBlank() }?.let { return it.trim() }
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
        versionCode = 1
        versionName = "1.0"

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
    }

    signingConfigs {
        create("rorkPlayUpload") {
            storeFile = file("/home/user/rork-app/android-vinetrack/app/play-upload-key.jks")
            storePassword = "rork-play-upload"
            keyAlias = "upload"
            keyPassword = "rork-play-upload"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("rorkPlayUpload")
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
    debugImplementation(libs.androidx.ui.tooling)
    testImplementation(libs.junit)
}
