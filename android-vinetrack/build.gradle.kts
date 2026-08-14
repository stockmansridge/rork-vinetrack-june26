// AGP decorates its DSL types (DefaultConfig, ShaderOptions, ...) at
// plugin-application time, and those generated classes reference Guava types in
// their constructor signatures. Guava therefore has to be on the plugin
// classpath before `com.android.application` can even be applied.
//
// Guava only ever gets there as a TRANSITIVE dependency of
// com.android.tools.build:gradle, and it is served by exactly one repository:
// dl.google.com returns 404 for com.google.guava:guava (verified against
// 33.3.1-jre), so mavenCentral is the single source. AGP's own jar comes from
// google(), which is why the plugin class loads fine and then dies later on a
// bare `NoClassDefFoundError: com/google/common/collect/Multimap` — the AAB
// export machine ends up with AGP present but its Guava missing from the
// classloader.
//
// Declaring Guava directly here promotes it from "transitive artifact that has
// to survive resolution" to a first-class requirement of the root buildscript
// classpath, which every subproject buildscript (and thus AGP) inherits. Both
// repositories are listed so the lookup is not tied to one host being
// reachable. The version is pinned to the exact one AGP 8.13.2 already
// resolves, so this cannot shift AGP's own dependency graph — it only
// guarantees the artifact is actually present.
buildscript {
    repositories {
        mavenCentral()
        google()
    }
    dependencies {
        classpath("com.google.guava:guava:33.3.1-jre")
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
