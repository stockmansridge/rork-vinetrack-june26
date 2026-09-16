package com.rork.vinetrack.data.mapalignment

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The safety boundary: saved Map Alignment data must not be able to reach a
 * production map.
 *
 * This phase is Save / Resume / Review only. A stored draft or a saved
 * field-test calibration is evidence collected on one device by one System
 * Admin; deciding whether any normal map should act on it is a separate, later
 * product decision. Until that decision is made, the guarantee has to be
 * structural rather than a promise in a comment — so this is a source audit
 * over the real files.
 *
 * A source audit cannot prove runtime behaviour. What it does prove is that no
 * production renderer even has a reference through which storage could reach
 * it, which is the property that would be silently lost in a refactor.
 */
class MapAlignmentProductionIsolationTest {

    private fun sourceRoot(): File {
        val candidates = listOf(
            File("src/main/java/com/rork/vinetrack"),
            File("app/src/main/java/com/rork/vinetrack"),
            File("android-vinetrack/app/src/main/java/com/rork/vinetrack"),
        )
        return candidates.firstOrNull(File::isDirectory)
            ?: error("Source root not found (cwd=${File(".").absolutePath})")
    }

    private fun kotlinSources(): List<File> =
        sourceRoot().walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    /**
     * The file with documentation removed.
     *
     * These files DESCRIBE what they deliberately avoid — "no SQL table,
     * Supabase table, RPC, outbox..." — so a naive text search finds the very
     * words the rule forbids. The audit must read code, not prose, or it would
     * fail on its own explanation of why it passes.
     */
    private fun codeOnly(file: File): String = file.readText()
        .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
        .lineSequence()
        .filterNot { it.trimStart().startsWith("//") }
        .joinToString("\n")

    /**
     * Files that legitimately know about local Map Alignment storage.
     *
     * Several of these only reference it from documentation, which is fine and
     * intentional — the point of this list is that the set stays small and
     * deliberate, so a production file acquiring a reference is noticed.
     */
    private val storageOwners = setOf(
        "MapAlignmentLocalStore.kt",
        "MapAlignmentRecordStore.kt",
        "MapAlignmentStoredState.kt",
        "MapAlignmentSaveFlow.kt",
        // Explains why leaving is no longer destructive. Documentation only.
        "MapAlignmentExitGuard.kt",
        // The System Admin wizard is the only screen that may read or write it.
        "MapAlignmentWizardScreen.kt",
    )

    /**
     * Production map renderers and the features named as off-limits: normal
     * vineyard maps, Block Overview, Pins, routes, Spray Trips, Follow Me,
     * boundary setup/editing, heatmaps and camera targeting.
     */
    private fun productionMapSources(): List<File> = kotlinSources().filter { file ->
        val name = file.name
        if (name.startsWith("MapAlignment")) return@filter false
        name.contains("Map") ||
            name.contains("Pins") ||
            name.contains("Block") ||
            name.contains("Route") ||
            name.contains("Spray") ||
            name.contains("Trip") ||
            name.contains("Heatmap") ||
            name.contains("Boundary") ||
            name.contains("FollowMe")
    }

    @Test
    fun `the local draft store is referenced only by its owners and the admin wizard`() {
        val referencing = kotlinSources()
            .filter { codeOnly(it).contains("MapAlignmentLocalStore") }
            .map { it.name }
            .toSet()

        assertTrue(
            "Unexpected files read or write the local Map Alignment store: " +
                "${referencing - storageOwners}. Local field-test storage must not spread " +
                "into production code.",
            (referencing - storageOwners).isEmpty(),
        )
    }

    @Test
    fun `only the wizard constructs the store`() {
        // Documentation references are harmless; an actual instance is not.
        // Exactly one screen may hold one, and it is the System Admin wizard.
        val constructing = kotlinSources()
            .filterNot { it.name == "MapAlignmentLocalStore.kt" } // its own declaration
            .filter { codeOnly(it).contains("MapAlignmentLocalStore(") }
            .map { it.name }
            .toSet()

        assertEquals(setOf("MapAlignmentWizardScreen.kt"), constructing)
    }

    @Test
    fun `no production map renderer touches the local store or stored records`() {
        val offenders = productionMapSources().filter { file ->
            val text = codeOnly(file)
            text.contains("MapAlignmentLocalStore") ||
                text.contains("MapAlignmentRecordStore") ||
                text.contains("MapAlignmentStoredDraft") ||
                text.contains("MapAlignmentSavedCalibration") ||
                text.contains("MapAlignmentStorage")
        }.map { it.name }

        assertTrue(
            "These production map/feature files reference stored Map Alignment data: " +
                "$offenders. A saved field-test calibration must not be able to move a " +
                "normal vineyard map, Block Overview, pin, route, Spray Trip, Follow Me " +
                "camera, boundary editor or heatmap.",
            offenders.isEmpty(),
        )
    }

    @Test
    fun `the resolver is never fed from local storage`() {
        // The resolver is the one place that decides which alignment applies.
        // Storage must not reach it, or a stored field-test calibration could
        // start moving production geometry without a further product decision.
        val resolverCallers = kotlinSources().filter {
            codeOnly(it).contains("MapAlignmentResolver.resolve")
        }.map { it.name }

        resolverCallers.forEach { name ->
            assertFalse(
                "$name both resolves an alignment and reads local storage",
                name in setOf("MapAlignmentLocalStore.kt", "MapAlignmentRecordStore.kt"),
            )
        }

        val resolver = codeOnly(File(sourceRoot(), "data/mapalignment/MapAlignmentResolver.kt"))
        listOf(
            "MapAlignmentLocalStore",
            "MapAlignmentRecordStore",
            "MapAlignmentStorage",
            "SharedPreferences",
            "Context",
        ).forEach { forbidden ->
            assertFalse(
                "MapAlignmentResolver must stay pure and storage-free, found: $forbidden",
                resolver.contains(forbidden),
            )
        }
    }

    @Test
    fun `no production map renderer resolves an alignment at all in this phase`() {
        val offenders = productionMapSources().filter {
            codeOnly(it).contains("MapAlignmentResolver")
        }.map { it.name }

        assertTrue(
            "These production files consult MapAlignmentResolver: $offenders. This phase is " +
                "Save / Resume / Review only \u2014 no production map may be aligned.",
            offenders.isEmpty(),
        )
    }

    @Test
    fun `local storage performs no network sync or backend write`() {
        listOf(
            "data/mapalignment/MapAlignmentLocalStore.kt",
            "data/mapalignment/MapAlignmentRecordStore.kt",
            "data/mapalignment/MapAlignmentStoredState.kt",
            "data/mapalignment/MapAlignmentSaveFlow.kt",
        ).forEach { relative ->
            val text = codeOnly(File(sourceRoot(), relative))
            listOf(
                "Supabase",
                "supabase",
                "HttpClient",
                "OkHttp",
                "Retrofit",
                "outbox",
                "Outbox",
                ".rpc(",
                "SQLiteDatabase",
                "Room",
            ).forEach { forbidden ->
                assertFalse(
                    "$relative must be local-only, found: $forbidden",
                    text.contains(forbidden),
                )
            }
        }
    }

    @Test
    fun `the wizard writes only through the store abstraction`() {
        val wizard = File(
            sourceRoot(),
            "ui/screens/MapAlignmentWizardScreen.kt",
        ).readText()

        // Storage decisions live in one place; Composables must not reach past
        // it to the preference file, where the version and installation rules
        // would be duplicated and then diverge.
        assertFalse(
            "the wizard must not open SharedPreferences directly",
            wizard.contains("getSharedPreferences"),
        )
        assertTrue(wizard.contains("MapAlignmentLocalStore("))
    }

    @Test
    fun `the saved calibration never claims to be applied to production maps`() {
        val wizard = File(sourceRoot(), "ui/screens/MapAlignmentWizardScreen.kt").readText()

        assertTrue(
            "the System Admin preview badge must remain",
            wizard.contains("System Admin Preview \u2014 not released"),
        )
        assertTrue(
            "the operator must be told saved data is not applied to normal maps",
            wizard.contains("not applied to any vineyard or block map") ||
                wizard.contains("not applied to"),
        )
    }

    @Test
    fun `the feature remains Android-only`() {
        // iOS and Portal are unchanged by this work; nothing here should have
        // created a counterpart anywhere else in the repository.
        val iosCandidates = listOf(File("ios"), File("../ios"), File("../../ios"))
        val ios = iosCandidates.firstOrNull(File::isDirectory) ?: return

        val offenders = ios.walkTopDown()
            .filter { it.isFile && it.extension == "swift" }
            .filter { codeOnly(it).contains("MapAlignment") }
            .map { it.name }
            .toList()

        assertEquals("Map Alignment must not exist on iOS", emptyList<String>(), offenders)
    }
}
