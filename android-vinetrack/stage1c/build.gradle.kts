import java.security.MessageDigest
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

fun pinnedValue(name: String): String {
    val value = providers.gradleProperty(name).orNull ?: ""
    require(value.isEmpty() || value.matches(Regex("[a-f0-9]{64}"))) { "Invalid Stage 1C pin" }
    return "\"$value\""
}

val primitives = listOf("IsolationDisk.kt", "RawEvidenceVault.kt", "ClosedEvidenceSet.kt", "ReviewedBusinessInventory.kt")
val primitiveRoot = rootProject.file("app/src/main/java/com/rork/vinetrack/data/isolation")
val reuse = tasks.register<Copy>("reuseFrozenPreservationSources") {
    from(primitiveRoot) { include(primitives) }
    into(layout.buildDirectory.dir("generated/stage1b/com/rork/vinetrack/data/isolation"))
}
val hash = MessageDigest.getInstance("SHA-256")
(primitives.map { primitiveRoot.resolve(it) } + fileTree("src/main").files.sortedBy { it.path } + file("build.gradle.kts"))
    .forEach { hash.update(it.readBytes()) }
val sourceDigest = hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }

android {
    namespace = "com.rork.vinetrack.stage1c"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.rork.vinetrack.stage1c"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "stage1c-preparation-1"
        buildConfigField("boolean", "FIELD_STORAGE_ISOLATION_ACTIVATED", "false")
        // Execution is intentionally impossible in this preparation build.
        buildConfigField("boolean", "DEVICE_TRIAL_EXECUTION_APPROVED", "false")
        buildConfigField("String", "DEVICE_PIN", pinnedValue("stage1cDevicePin"))
        buildConfigField("String", "PREFLIGHT_PIN", pinnedValue("stage1cPreflightPin"))
        buildConfigField("String", "SOURCE_DIGEST", "\"$sourceDigest\"")
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    sourceSets.getByName("main").java.srcDir(layout.buildDirectory.dir("generated/stage1b"))
}
kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_11) } }

androidComponents {
    beforeVariants(selector().withBuildType("release")) { it.enable = false }
}
tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }.configureEach { dependsOn(reuse) }

dependencies {
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.material3)
}
