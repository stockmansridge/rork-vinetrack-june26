package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayProgramSort
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Spray Program landing rules — merge, phenological sort and search — the
 * Android mirror of the iOS `SprayProgramCatalog`.
 *
 * Test sources are deliberately not inputs to `assembleRelease`, so extending
 * this suite never invalidates the release build cache.
 */
class SprayProgramLandingTest {

    private fun step(
        id: String,
        name: String,
        stageCode: String? = null,
        isTemplate: Boolean = true,
        targets: List<String>? = null,
        notes: String? = null,
    ): SprayRecord = SprayRecord(
        id = id,
        vineyardId = "vy-1",
        sprayReference = name,
        isTemplate = isTemplate,
        templateGrowthStageCode = stageCode,
        targets = targets,
        notes = notes,
    )

    @Test
    fun `EL sorting is numeric, never alphabetical`() {
        val steps = listOf(
            step("a", "Late", stageCode = "EL31"),
            step("b", "Early", stageCode = "EL7"),
            step("c", "Mid", stageCode = "EL12"),
        )
        val sorted = SprayProgramLanding.sort(steps, SprayProgramSort.EL_ASC)
        // Alphabetical would read EL12 < EL31 < EL7 — phenological order must not.
        assertEquals(listOf("b", "c", "a"), sorted.map { it.id })
    }

    @Test
    fun `steps with no resolvable stage sink to the bottom in both directions`() {
        val steps = listOf(
            step("unknown", "Copper Clean-up"),
            step("staged", "Budburst", stageCode = "EL4"),
        )
        assertEquals(listOf("staged", "unknown"), SprayProgramLanding.sort(steps, SprayProgramSort.EL_ASC).map { it.id })
        // An unknown stage is not a low stage — it must not float to the top
        // of a reversed list either.
        assertEquals(listOf("staged", "unknown"), SprayProgramLanding.sort(steps, SprayProgramSort.EL_DESC).map { it.id })
    }

    @Test
    fun `stage is read from the canonical code first, then the step's own text`() {
        assertEquals(12, SprayProgramLanding.elStageNumber(step("a", "Anything", stageCode = "EL12")))
        assertEquals(18, SprayProgramLanding.elStageNumber(step("b", "E-L 18 Flowering")))
        // "Model 3" must not read as a stage.
        assertNull(SprayProgramLanding.elStageNumber(step("c", "Model 3 clean-up")))
    }

    @Test
    fun `merge dedupes by id and local wins`() {
        val local = listOf(
            step("shared", "Local copy"),
            step("local-only", "Local step"),
            step("operational", "Applied spray", isTemplate = false),
        )
        val portal = listOf(
            step("shared", "Portal copy"),
            step("portal-only", "Portal step"),
        )
        val merged = SprayProgramLanding.mergedProgramSteps(local, portal)
        assertEquals(listOf("shared", "local-only", "portal-only"), merged.map { it.id })
        // A record the device owns is never shadowed by a read-mapped copy.
        assertEquals("Local copy", merged.first { it.id == "shared" }.sprayReference)
        // Operational records never appear in the Program.
        assertFalse(merged.any { it.id == "operational" })
    }

    @Test
    fun `program search matches stage numbers and target wording`() {
        val s = step(
            "a",
            "Flowering protectant",
            stageCode = "EL18",
            targets = listOf("powdery_mildew", "eutypa_dieback"),
        )
        // "EL 18" written differently still matches — stage NUMBERS compare.
        assertTrue(SprayProgramLanding.programStepMatches(s, "e-l 18"))
        assertTrue(SprayProgramLanding.programStepMatches(s, "Eutypa"))
        assertTrue(SprayProgramLanding.programStepMatches(s, "powdery"))
        assertFalse(SprayProgramLanding.programStepMatches(s, "EL 31"))
        // Library wording is honoured when supplied.
        assertTrue(
            SprayProgramLanding.programStepMatches(
                s,
                "LBAM",
                labels = mapOf("eutypa_dieback" to "Eutypa (LBAM trial)"),
            ),
        )
    }

    @Test
    fun `stage badge label prefers the canonical code`() {
        assertEquals("EL12", SprayProgramLanding.elStageLabel(step("a", "x", stageCode = "el12")))
        assertEquals("EL9", SprayProgramLanding.elStageLabel(step("b", "EL 9 shoots")))
        assertNull(SprayProgramLanding.elStageLabel(step("c", "no stage here")))
    }
}
