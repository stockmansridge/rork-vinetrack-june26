package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayProgramSort
import com.rork.vinetrack.data.spray.SprayResumeSection
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
        tripId: String? = null,
        endTime: String? = null,
        product: String? = null,
    ): SprayRecord = SprayRecord(
        id = id,
        vineyardId = "vy-1",
        tripId = tripId,
        sprayReference = name,
        isTemplate = isTemplate,
        templateGrowthStageCode = stageCode,
        targets = targets,
        notes = notes,
        endTime = endTime,
        tanks = product?.let { listOf(SprayTank(id = "tank-$id", chemicals = listOf(SprayChemical(id = "chemical-$id", name = it)))) },
    )

    private fun trip(id: String, isActive: Boolean): Trip = Trip(
        id = id,
        vineyardId = "vy-1",
        isActive = isActive,
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
    fun `canonical E-L sequence sorts numerically including EL2 before EL12`() {
        val stages = listOf(41, 12, 1, 35, 2, 32, 4, 31, 9, 27, 17, 25, 19, 20)
            .map { stage -> step("el-$stage", "Stage $stage", stageCode = "EL$stage") }

        assertEquals(
            listOf(1, 2, 4, 9, 12, 17, 19, 20, 25, 27, 31, 32, 35, 41),
            SprayProgramLanding.sort(stages, SprayProgramSort.EL_ASC).map { SprayProgramLanding.elStageNumber(it) },
        )
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
    fun `same-stage ordering is stable by name then id`() {
        val steps = listOf(
            step("z-id", "Bravo", stageCode = "EL12"),
            step("b-id", "Alpha", stageCode = "EL12"),
            step("a-id", "Alpha", stageCode = "EL12"),
        )

        assertEquals(
            listOf("a-id", "b-id", "z-id"),
            SprayProgramLanding.sort(steps, SprayProgramSort.EL_ASC).map { it.id },
        )
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
    fun `resume sections put in-progress first and exclude completed history`() {
        val active = step("active", "Active spray", isTemplate = false, tripId = "trip-active")
        val completed = step(
            "completed",
            "Completed spray",
            isTemplate = false,
            tripId = "trip-completed",
            endTime = "2026-09-01T10:00:00Z",
        )
        val program = step("program", "Budburst", stageCode = "EL4")

        val sections = SprayProgramLanding.resumeSections(
            localRecords = listOf(completed, program, active),
            portalTemplates = emptyList(),
            trips = listOf(trip("trip-active", true), trip("trip-completed", false)),
        )

        assertEquals(SprayResumeSection.Kind.IN_PROGRESS, sections.first().kind)
        assertEquals(listOf("active"), sections.first().records.map { it.id })
        assertEquals(SprayResumeSection.Kind.PROGRAM_STAGE, sections[1].kind)
        assertEquals(listOf("program"), sections[1].records.map { it.id })
        assertFalse(sections.flatMap { it.records }.any { it.id == "completed" })
    }

    @Test
    fun `resume sections preserve numeric groups and put unknown stages last`() {
        val sections = SprayProgramLanding.resumeSections(
            localRecords = listOf(
                step("unknown", "Unknown"),
                step("twelve", "Twelve", stageCode = "EL12"),
                step("two", "Two", stageCode = "EL2"),
            ),
            portalTemplates = emptyList(),
            trips = emptyList(),
        )

        assertEquals(listOf("EL2", "EL12", "Other Program Steps"), sections.map { it.title })
        assertEquals(SprayResumeSection.Kind.UNKNOWN_STAGE, sections.last().kind)
    }

    @Test
    fun `resume search matches Program Step name`() {
        val result = SprayProgramLanding.resumeSections(
            listOf(step("match", "Flowering protectant", stageCode = "EL19"), step("other", "Dormant oil", stageCode = "EL1")),
            emptyList(),
            emptyList(),
            query = "flowering",
        )
        assertEquals(listOf("match"), result.flatMap { it.records }.map { it.id })
        assertEquals("EL19", result.single().title)
    }

    @Test
    fun `resume search matches E-L stage without destroying grouping`() {
        val result = SprayProgramLanding.resumeSections(
            listOf(step("two", "Early", stageCode = "EL2"), step("twelve", "Later", stageCode = "EL12")),
            emptyList(),
            emptyList(),
            query = "E-L 12",
        )
        assertEquals(listOf("EL12"), result.map { it.title })
        assertEquals(listOf("twelve"), result.single().records.map { it.id })
    }

    @Test
    fun `resume search matches E-L stage label`() {
        val result = SprayProgramLanding.resumeSections(
            listOf(step("stage-label", "Protectant", stageCode = "EL12")),
            emptyList(),
            emptyList(),
            query = "5 leaves separated",
        )
        assertEquals(listOf("stage-label"), result.flatMap { it.records }.map { it.id })
    }

    @Test
    fun `resume search matches target wording`() {
        val result = SprayProgramLanding.resumeSections(
            listOf(step("target", "Protectant", stageCode = "EL17", targets = listOf("powdery_mildew"))),
            emptyList(),
            emptyList(),
            query = "powdery",
        )
        assertEquals(listOf("target"), result.flatMap { it.records }.map { it.id })
    }

    @Test
    fun `resume search matches product name`() {
        val result = SprayProgramLanding.resumeSections(
            listOf(step("product", "Protectant", stageCode = "EL17", product = "Sulphur 800")),
            emptyList(),
            emptyList(),
            query = "sulphur",
        )
        assertEquals(listOf("product"), result.flatMap { it.records }.map { it.id })
    }

    @Test
    fun `Program Step selection preserves calculator prefill identity`() {
        val programStep = step("prefill-step", "Prefill", stageCode = "EL9")
        assertEquals("prefill-step", SprayProgramLanding.calculatorPrefillId(programStep))
    }

    @Test
    fun `stage badge label prefers the canonical code`() {
        assertEquals("EL12", SprayProgramLanding.elStageLabel(step("a", "x", stageCode = "el12")))
        assertEquals("EL9", SprayProgramLanding.elStageLabel(step("b", "EL 9 shoots")))
        assertNull(SprayProgramLanding.elStageLabel(step("c", "no stage here")))
    }
}
