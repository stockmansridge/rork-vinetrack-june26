package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
import com.rork.vinetrack.data.spray.SprayProgramTerminology
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.data.spray.SprayTargetTag
import com.rork.vinetrack.data.spray.SprayTargetVocabulary
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Spray Program parity (Part B) — the Android mirrors of the iOS
 * `SprayTargetVocabulary`, portal Program Step decode rules, custom-target
 * persistence and the shared Program terminology.
 *
 * Test sources are deliberately not inputs to `assembleRelease`, so extending
 * this suite never invalidates the release build cache.
 */
class SprayProgramParityTest {

    // ---- Target vocabulary ----

    @Test
    fun `wording slugs deterministically and case-insensitively`() {
        assertEquals("eutypa_dieback", SprayTargetVocabulary.identifier("Eutypa Dieback"))
        assertEquals("eutypa_dieback", SprayTargetVocabulary.identifier("  EUTYPA   DIEBACK  "))
        assertEquals(
            "light_brown_apple_moth_lbam",
            SprayTargetVocabulary.identifier("Light Brown Apple Moth (LBAM)"),
        )
        assertNull(SprayTargetVocabulary.identifier("  --  "))
    }

    @Test
    fun `hand-typed wording that names a built-in resolves to the built-in`() {
        // Typing "powdery mildew" must not create a second Powdery Mildew the
        // calculator then fails to recognise.
        val tag = SprayTargetVocabulary.tagFromWording("powdery mildew")
        assertEquals(SprayTarget.POWDERY_MILDEW, tag?.builtIn)
        assertFalse(tag!!.isCustom)
    }

    @Test
    fun `legacy wording splits conservatively`() {
        // Commas separate targets...
        assertEquals(
            listOf("Eutypa Dieback", "Botryosphaeria Dieback"),
            SprayTargetVocabulary.wordings("Eutypa Dieback, Botryosphaeria Dieback"),
        )
        // ...but "/" does NOT: "Nutrition / Biostimulant" is one target's own
        // name, and splitting it would invent two targets that do not exist.
        assertEquals(
            listOf("Nutrition / Biostimulant"),
            SprayTargetVocabulary.wordings("Nutrition / Biostimulant"),
        )
    }

    @Test
    fun `structured identifiers are authoritative and keep custom targets`() {
        val tags = SprayTargetVocabulary.tags(
            identifiers = listOf("powdery_mildew", "eutypa_dieback"),
            wording = "Powdery Mildew · Eutypa Dieback",
        )
        assertEquals(2, tags.size)
        assertEquals(SprayTarget.POWDERY_MILDEW, tags[0].builtIn)
        // The custom target survives with the step's own verbatim wording.
        assertTrue(tags[1].isCustom)
        assertEquals("eutypa_dieback", tags[1].identifier)
        assertEquals("Eutypa Dieback", tags[1].label)
    }

    @Test
    fun `a step written before the contract loads from its wording alone`() {
        val tags = SprayTargetVocabulary.tags(
            identifiers = emptyList(),
            wording = "Eutypa Dieback, Botryosphaeria Dieback",
        )
        assertEquals(2, tags.size)
        assertTrue(tags.all { it.isCustom })
        assertEquals(listOf("eutypa_dieback", "botryosphaeria_dieback"), tags.map { it.identifier })
    }

    @Test
    fun `normalisation orders built-ins first and de-duplicates`() {
        val tags = SprayTargetVocabulary.normalised(
            listOf(
                SprayTargetTag(identifier = "eutypa_dieback", label = "Eutypa Dieback"),
                SprayTargetTag(SprayTarget.BOTRYTIS),
                SprayTargetTag(SprayTarget.POWDERY_MILDEW),
                SprayTargetTag(SprayTarget.BOTRYTIS),
            ),
        )
        // Built-ins in presentation order, then customs in added order — so
        // two operators who tapped the same targets write the same array.
        assertEquals(
            listOf("powdery_mildew", "botrytis", "eutypa_dieback"),
            SprayTargetVocabulary.identifiers(tags),
        )
    }

    @Test
    fun `an unknown identifier is de-slugged for display never dropped`() {
        val tag = SprayTargetVocabulary.tagForIdentifier("black_spot")
        assertEquals("Black Spot", tag?.label)
        assertTrue(tag!!.isCustom)
    }

    // ---- Snapshot: custom targets are recorded, not noise ----

    private fun snapshotFromTargets(targets: List<String>?): SprayApplicationSnapshot? =
        SprayApplicationSnapshot.fromColumns(
            grossAreaHa = null,
            treatedAreaHa = null,
            applicationMode = null,
            treatedAreaMethod = null,
            bandWidthTotalMetres = null,
            bandWidthLeftMetres = null,
            bandWidthRightMetres = null,
            canonicalRowLengthMetres = null,
            rowSpacingMetres = null,
            geometrySource = null,
            geometryQuality = null,
            carrierVolumeBasis = null,
            totalCarrierLitres = null,
            carrierLitresPerHectare = null,
            diluteLitresPer100m = null,
            appliedLitresPer100m = null,
            concentrationFactor = null,
            targets = targets,
        )

    @Test
    fun `stored identifiers split into built-ins and custom targets`() {
        val snapshot = snapshotFromTargets(listOf("powdery_mildew", "eutypa_dieback"))
        assertNotNull(snapshot)
        assertEquals(listOf(SprayTarget.POWDERY_MILDEW), snapshot!!.targets)
        assertEquals(listOf("eutypa_dieback"), snapshot.customTargets)
        // The combined projection writes back exactly what was stored.
        assertEquals(listOf("powdery_mildew", "eutypa_dieback"), snapshot.targetIdentifiers)
        assertTrue(snapshot.hasRecordedTargets)
    }

    @Test
    fun `an entirely custom selection still reads as recorded`() {
        // Previously these identifiers were dropped and the record read as
        // "nothing targeted" — the exact silence-as-answer failure the
        // Resistance Planner must never inherit.
        val snapshot = snapshotFromTargets(listOf("eutypa_dieback"))
        assertNotNull(snapshot)
        assertEquals(emptyList<SprayTarget>(), snapshot!!.targets)
        assertEquals(listOf("eutypa_dieback"), snapshot.customTargets)
        assertTrue(snapshot.hasRecordedTargets)
    }

    @Test
    fun `never-recorded targets stay null through the projection`() {
        assertNull(snapshotFromTargets(null))
        val empty = SprayApplicationSnapshot()
        assertNull(empty.targetIdentifiers)
        assertFalse(empty.hasRecordedTargets)
    }

    @Test
    fun `a template keeps custom targets as reusable intent`() {
        val snapshot = SprayApplicationSnapshot(
            grossAreaHa = 10.0,
            targets = listOf(SprayTarget.POWDERY_MILDEW),
            customTargets = listOf("eutypa_dieback"),
        )
        val template = snapshot.templateConfiguration()
        assertNotNull(template)
        // Geometry output cleared, target intent kept.
        assertNull(template!!.grossAreaHa)
        assertEquals(listOf(SprayTarget.POWDERY_MILDEW), template.targets)
        assertEquals(listOf("eutypa_dieback"), template.customTargets)
    }

    @Test
    fun `custom targets survive the offline outbox round trip`() {
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
        val snapshot = SprayApplicationSnapshot(
            targets = listOf(SprayTarget.BOTRYTIS),
            customTargets = listOf("eutypa_dieback"),
        )
        val reloaded: SprayApplicationSnapshot = json.decodeFromString(
            json.encodeToString(SprayApplicationSnapshot.serializer(), snapshot),
        )
        assertEquals(snapshot.targets, reloaded.targets)
        assertEquals(snapshot.customTargets, reloaded.customTargets)
    }

    // ---- Portal Program Step chemical lines ----

    @Test
    fun `line units parse into the shared strict units with their basis`() {
        assertEquals("mL" to true, SprayJobTemplateRepository.parseLineUnit("mL/100L"))
        assertEquals("Litres" to false, SprayJobTemplateRepository.parseLineUnit("L/ha"))
        assertEquals("Kg" to false, SprayJobTemplateRepository.parseLineUnit("kg/ha"))
        assertEquals("g" to true, SprayJobTemplateRepository.parseLineUnit("g/100L"))
        // No unit at all falls back to litres, whole-block — the legacy read.
        assertEquals("Litres" to false, SprayJobTemplateRepository.parseLineUnit(null))
    }

    // ---- Terminology ----

    @Test
    fun `the operator-facing vocabulary never says template`() {
        for (label in SprayProgramTerminology.allLabels) {
            assertFalse(
                "\"$label\" must not use the banned word",
                label.lowercase().contains("template"),
            )
        }
        // The words themselves are pinned so both platforms stay aligned.
        assertEquals("Program Step", SprayProgramTerminology.PROGRAM_STEP)
        assertEquals("Plan from Program", SprayProgramTerminology.PLAN_FROM_PROGRAM)
        assertEquals("One-off Spray", SprayProgramTerminology.ONE_OFF_SPRAY)
        assertEquals("Upcoming", SprayProgramTerminology.UPCOMING)
        assertEquals("Download Import CSV", SprayProgramTerminology.DOWNLOAD_IMPORT_CSV)
    }
}
