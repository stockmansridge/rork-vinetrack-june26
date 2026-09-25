package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrowthStageRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

class DiseaseGrowthStagePolicyTest {
    private val vineyard = "11111111-1111-1111-1111-111111111111"
    private val blockA = "22222222-2222-2222-2222-222222222222"
    private val blockB = "33333333-3333-3333-3333-333333333333"
    private val now = Instant.parse("2026-09-25T12:00:00Z").toEpochMilli()
    private val season = SeasonWindow.containing(LocalDate.of(2026, 9, 25), 7, 1)

    private fun row(id: String, block: String, code: String, observed: String, updated: String = observed,
                    pin: String? = null, deleted: String? = null) = GrowthStageRecord(
        id = id, vineyardId = vineyard, paddockId = block, pinId = pin, stageCode = code,
        stageLabel = code, variety = "Shiraz", observedAt = observed, updatedAt = updated, deletedAt = deleted,
    )

    private fun resolve(rows: List<GrowthStageRecord>, pending: Set<String> = emptySet()): List<DiseaseBlockStage> =
        DiseaseGrowthStagePolicy.resolve(rows, vineyard, season, ZoneOffset.UTC, now, pending)

    private fun weather(model: DiseaseModel = DiseaseModel.BOTRYTIS, severity: DiseaseSeverity = DiseaseSeverity.MEDIUM) =
        DiseaseRiskAssessment(model, severity, "Risk", "24 wet hours", emptyList())

    @Test fun missingAndLastVintageKeepWeather() {
        val base = weather()
        assertEquals(base, DiseaseGrowthStagePolicy.adjust(base, emptyList()))
        assertFalse(DiseaseGrowthStagePolicy.changed(base, DiseaseGrowthStagePolicy.adjust(base, emptyList())))
        val old = row("old", blockA, "EL19", "2025-06-30T12:00:00Z", "2026-09-25T09:00:00Z")
        assertTrue(resolve(listOf(old)).isEmpty())
        assertEquals("No current-season observation", DiseaseGrowthStagePolicy.stageText(resolve(listOf(old))))
    }

    @Test fun deletedLatestAndEditedOldObservationCannotWin() {
        val old = row("old", blockA, "EL19", "2025-06-30T12:00:00Z", "2026-09-25T09:00:00Z")
        val first = row("first", blockA, "EL12", "2026-09-10T12:00:00Z")
        val latest = row("latest", blockA, "EL25", "2026-09-20T12:00:00Z", deleted = "2026-09-21T00:00:00Z")
        assertEquals(listOf(12), resolve(listOf(old, first, latest)).map { it.el })
        assertEquals(listOf(12), resolve(listOf(first, latest.copy(deletedAt = null)), setOf("latest")).map { it.el })
    }

    @Test fun latestByObservedTimeAndMirroredPairedPinCountOnce() {
        val pin = "same-pin"
        val first = row("first", blockA, "EL12", "2026-09-10T12:00:00Z", pin = pin)
        val latest = row("latest", blockA, "EL19", "2026-09-20T12:00:00Z", pin = pin)
        assertEquals(listOf(19), resolve(listOf(latest, first)).map { it.el })
        // The repository contains canonical rows only; a linked pin is not another row.
        assertEquals(1, resolve(listOf(latest)).size)
    }

    @Test fun mixedBlocksAndParityFixture() {
        val early = row("early", blockA, "EL12", "2026-09-10T12:00:00Z")
        val flowering = row("flower", blockB, "EL19", "2026-09-20T12:00:00Z")
        val mixed = resolve(listOf(flowering, early))
        assertEquals(2, mixed.size)
        assertEquals("EL12–EL19", DiseaseGrowthStagePolicy.stageText(mixed))
        assertEquals(DiseaseSeverity.MEDIUM, DiseaseGrowthStagePolicy.adjust(weather(), mixed).severity)
        assertEquals(DiseaseSeverity.LOW, DiseaseGrowthStagePolicy.adjust(weather(), resolve(listOf(early))).severity)
        assertEquals(DiseaseSeverity.MEDIUM, DiseaseGrowthStagePolicy.adjust(weather(), resolve(listOf(flowering))).severity)
        val late = resolve(listOf(row("late", blockA, "EL33", "2026-09-20T12:00:00Z")))
        assertEquals(DiseaseSeverity.MEDIUM, DiseaseGrowthStagePolicy.adjust(weather(), late).severity)
        assertEquals(DiseaseSeverity.MEDIUM, DiseaseGrowthStagePolicy.adjust(weather(DiseaseModel.DOWNY_MILDEW), late).severity)
        assertEquals(DiseaseSeverity.MEDIUM, DiseaseGrowthStagePolicy.adjust(weather(DiseaseModel.POWDERY_MILDEW), late).severity)
        assertEquals(DiseaseSeverity.HIGH, DiseaseGrowthStagePolicy.adjust(weather(DiseaseModel.DOWNY_MILDEW, DiseaseSeverity.HIGH), mixed).severity)
        assertTrue(DiseaseGrowthStagePolicy.changed(weather(), DiseaseGrowthStagePolicy.adjust(weather(), resolve(listOf(early)))))
    }

    @Test fun currentAndSevenDayUseSameHeldStage() {
        val stages = resolve(listOf(row("early", blockA, "EL12", "2026-09-10T12:00:00Z")))
        val today = System.currentTimeMillis()
        val hours = (0..35).map { offset ->
            WeatherHour(today - (35 - offset) * 3_600_000L, 20.0, 19.0, 95.0, 1.0)
        }
        val base = DiseaseRiskCalculator.assess(hours, today).first { it.model == DiseaseModel.BOTRYTIS }
        val final = DiseaseGrowthStagePolicy.adjust(base, stages)
        assertEquals(DiseaseSeverity.HIGH, base.severity)
        assertEquals(DiseaseSeverity.MEDIUM, final.severity)
        val weatherOnly = computeDailyDiseaseScores(hours)
        val adjusted = computeDailyDiseaseScores(hours, stages)
        assertEquals(7, adjusted.size)
        assertTrue(weatherOnly.zip(adjusted).any { (before, after) -> before.botrytis > after.botrytis })
    }
}
