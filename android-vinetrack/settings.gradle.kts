// Pin AGP's preferences/analytics root to a guaranteed-writable, build-local
// folder BEFORE the Android plugin is ever loaded.
//
// AGP initialises its analytics state (AnalyticsSettings) from ANDROID_USER_HOME
// during project evaluation, and it also materialises the debug keystore there.
// If that location is missing or unwritable, AGP throws from inside its own
// evaluation listener — and because AGP funnels those exceptions through its
// crash reporter, a machine that cannot load PluginCrashReporter reports only a
// bare NoClassDefFoundError with the real cause destroyed.
//
// gradle.properties can express just a hardcoded absolute path (previously
// /tmp), whose writability is not guaranteed on a one-shot build container.
// Resolving it against the checkout — which Gradle demonstrably writes to —
// removes that assumption. Settings scripts are evaluated before any project, so
// this wins over the gradle.properties value while leaving it as a fallback if
// the build-local folder cannot be created for any reason.
run {
    val prefsRoot = rootDir.resolve(".android-home")
    if ((prefsRoot.isDirectory || prefsRoot.mkdirs()) && prefsRoot.canWrite()) {
        System.setProperty("ANDROID_USER_HOME", prefsRoot.absolutePath)
    }
}

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "VineTrack"
include(":app")
