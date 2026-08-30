package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.spray.SprayTargetLibrary
import com.rork.vinetrack.data.spray.SprayTargetTag
import com.rork.vinetrack.data.spray.VineyardSprayTarget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The vineyard spray-target library scoping/merge rules (sql/204) — the
 * Android mirror of the iOS `SprayTargetLibraryService` statics.
 *
 * Test sources are deliberately not inputs to `assembleRelease`, so extending
 * this suite never invalidates the release build cache.
 */
class SprayTargetLibraryTest {

    private val entries = listOf(
        VineyardSprayTarget(id = "1", vineyardId = "vy-a", identifier = "eutypa_dieback", label = "Eutypa Dieback"),
        VineyardSprayTarget(id = "2", vineyardId = "vy-a", identifier = "black_spot", label = "Black Spot", isActive = false),
        VineyardSprayTarget(id = "3", vineyardId = "vy-b", identifier = "phomopsis", label = "Phomopsis"),
    )

    @Test
    fun `a target created for Vineyard A is never offered in Vineyard B`() {
        assertEquals(mapOf("eutypa_dieback" to "Eutypa Dieback"), SprayTargetLibrary.labels(entries, "vy-a"))
        assertEquals(mapOf("phomopsis" to "Phomopsis"), SprayTargetLibrary.labels(entries, "vy-b"))
        assertTrue(SprayTargetLibrary.labels(entries, null).isEmpty())
        val tagsA = SprayTargetLibrary.customTags(entries, "vy-a").map { it.identifier }
        assertEquals(listOf("eutypa_dieback"), tagsA)
    }

    @Test
    fun `inactive rows keep their wording but are not offered`() {
        // Historical sprays never lose meaning (labels read actives only here;
        // the identifier still de-slugs), but the chooser must not offer them.
        val offered = SprayTargetLibrary.customTags(entries, "vy-a").map { it.identifier }
        assertTrue("black_spot" !in offered)
    }

    @Test
    fun `observed identifiers are offered before the library has ever been written`() {
        val steps = listOf(
            SprayRecord(
                id = "step-1",
                vineyardId = "vy-a",
                isTemplate = true,
                targets = listOf("powdery_mildew", "light_brown_apple_moth"),
            ),
        )
        val observed = SprayTargetLibrary.observedCustomTags(steps)
        // The built-in contributes nothing; the vineyard's own word is offered,
        // de-slugged for reading.
        assertEquals(listOf("light_brown_apple_moth"), observed.map { it.identifier })
        assertEquals(listOf("Light Brown Apple Moth"), observed.map { it.label })
    }

    @Test
    fun `a real library entry's wording wins over a de-slugged approximation`() {
        val observed = listOf(SprayTargetTag(identifier = "eutypa_dieback", label = "Eutypa dieback"))
        val merged = SprayTargetLibrary.customTags(entries, "vy-a", observed)
        assertEquals(listOf("Eutypa Dieback"), merged.map { it.label })
        assertEquals(1, merged.size)
    }

    @Test
    fun `built-in targets are never stored or offered as vineyard entries`() {
        val observed = listOf(SprayTargetTag(identifier = "powdery_mildew", label = "Powdery Mildew"))
        val merged = SprayTargetLibrary.customTags(emptyList(), "vy-a", observed)
        assertTrue(merged.isEmpty())
    }
}
