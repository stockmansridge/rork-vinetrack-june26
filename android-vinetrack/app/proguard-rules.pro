# VineTrack release ProGuard/R8 rules.
# (sql/200 offline-linkage closeout: work_tasks.pruning_activity_id rides the
# queued create replay — no reflection impact; rules unchanged.)
# (sql/201 Stage 5B: spray_jobs plan provenance + spray_records.spray_job_id
# ride kotlinx-serialized payloads already covered below; rules unchanged.)
# (Planner plan list: navigation/UI only; ResistancePlan already covered by the
# kotlinx-serialization rules below; rules unchanged.)
#
# `app/build.gradle.kts` lists this file in the release build type's
# `proguardFiles(...)`. It was referenced but MISSING from the repo, which left
# the release build type pointing at a non-existent path — a latent failure for
# any build (or AGP version) that resolves those files eagerly, and a guaranteed
# break the moment minification is switched on.
#
# Minification is currently disabled (`isMinifyEnabled = false`), so these rules
# are inert today. They are written to be correct for the libraries this app
# actually uses so that enabling R8 later is a one-line change and not a
# debugging session over obfuscated reflection failures.

# --- Kotlin / coroutines -----------------------------------------------------
-dontwarn kotlinx.coroutines.**
-keepclassmembers class kotlin.Metadata { public <methods>; }

# --- kotlinx.serialization ---------------------------------------------------
# Serializers are looked up reflectively from the companion/`$serializer` types,
# so the generated members must survive shrinking.
-keepattributes *Annotation*, InnerClasses, Signature
-dontnote kotlinx.serialization.**
-keepclassmembers @kotlinx.serialization.Serializable class ** {
    static <1>$Companion Companion;
    *** Companion;
    static **$* *;
}
-keepclasseswithmembers class ** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.rork.vinetrack.data.**$$serializer { *; }

# --- Ktor client -------------------------------------------------------------
-dontwarn io.ktor.**
-keep class io.ktor.client.engine.android.** { *; }
-dontwarn org.slf4j.**

# --- Coil 3 / OkHttp --------------------------------------------------------
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn coil3.**

# --- Koin -------------------------------------------------------------------
-dontwarn org.koin.**

# --- Google Play services / Maps --------------------------------------------
-dontwarn com.google.android.gms.**
-keep class com.google.android.gms.maps.** { *; }

# --- Credential Manager / Google ID sign-in ---------------------------------
-keep class com.google.android.libraries.identity.googleid.** { *; }
-dontwarn androidx.credentials.**

# --- RevenueCat -------------------------------------------------------------
-keep class com.revenuecat.purchases.** { *; }
-dontwarn com.revenuecat.purchases.**

# --- Crash-report readability ----------------------------------------------
-keepattributes SourceFile, LineNumberTable
