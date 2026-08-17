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

        // JAXB, for exactly the same reason and with exactly the same failure mode.
        //
        // AGP parses the SDK repository XML through JAXB (com.android.tools:repository
        // and com.android.tools:sdk-common both require it), and
        // com.android.tools.build:gradle:8.13.2 declares it as
        //
        //     org.glassfish.jaxb:jaxb-runtime:2.3.2  <scope>runtime</scope>
        //
        // A *runtime*-scoped transitive is never needed to LOAD the plugin, so a
        // classpath missing it configures cleanly and only dies later, when AGP
        // actually parses SDK metadata — which the `bundleRelease` path does and the
        // plain `assembleRelease` path can skip entirely, having already cached what it
        // needs. That is why the APK build is green while the AAB export failed on a
        // bare `NoClassDefFoundError: com/sun/xml/bind/v2/runtime/JaxBeanInfo`
        // (that class ships inside jaxb-runtime, despite its com.sun package name —
        // it is the Glassfish RI relocated, not a JDK class, so no JDK version supplies
        // it: JAXB was removed from the JDK in 11 and this build targets Java 11).
        //
        // Only mavenCentral serves it — verified: dl.google.com returns 404 for
        // org/glassfish/jaxb/jaxb-runtime/2.3.2 while repo1.maven.org returns 200 —
        // and google() is the repository AGP's own jar comes from. Declaring the graph
        // here promotes it from "transitive artifact that has to survive resolution" to
        // a first-class requirement of the root buildscript classpath, which every
        // subproject buildscript (and thus AGP) inherits.
        //
        // Every version below is pinned to the one AGP 8.13.2 ALREADY resolves, so this
        // cannot shift AGP's dependency graph — it only guarantees the artifacts are
        // present. The transitives are listed explicitly rather than left to
        // jaxb-runtime's own POM because they are the same class of runtime-scoped
        // artifact that went missing in the first place, and jaxb-runtime is useless
        // without them (istack and txw2 are referenced from its hot paths).
        classpath("org.glassfish.jaxb:jaxb-runtime:2.3.2")
        classpath("org.glassfish.jaxb:txw2:2.3.2")
        classpath("jakarta.xml.bind:jakarta.xml.bind-api:2.3.2")
        classpath("jakarta.activation:jakarta.activation-api:1.2.1")
        classpath("com.sun.istack:istack-commons-runtime:3.0.8")
        classpath("org.jvnet.staxex:stax-ex:1.8.1")
        classpath("com.sun.xml.fastinfoset:FastInfoset:1.2.16")
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
