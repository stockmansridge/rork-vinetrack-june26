package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.ui.screens.blockGddTotal
import com.rork.vinetrack.ui.screens.blockVarietyRecognised
import com.rork.vinetrack.ui.screens.computeRows
import com.rork.vinetrack.ui.screens.computeVarietySeries
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.util.TimeZone

class OptimalRipenessFinalParityTest {
    private val utc = TimeZone.getTimeZone("UTC")
    private val start = Instant.parse("2026-09-01T00:00:00Z").toEpochMilli()
    private val end = Instant.parse("2026-09-06T00:00:00Z").toEpochMilli()

    @Test
    fun `hub detail tile and chip share identical block total`() {
        val fixture = fixture(Paddock("b1", "v1", "North", budburstDate = "2026-09-01"))
        val hub = fixture.hub()
        val detail = fixture.detail()
        val tile = fixture.surface()
        val chip = fixture.surface()
        assertEquals(hub, detail, 0.0)
        assertEquals(hub, tile, 0.0)
        assertEquals(hub, chip, 0.0)
    }

    @Test
    fun `explicit Season Start and Budburst work on every surface`() {
        val season = fixture(Paddock("season", "v1", "Season", resetModeOverride = "seasonStart"))
        val budburst = fixture(Paddock("bud", "v1", "Bud", budburstDate = "2026-09-03", resetModeOverride = "budburst"))
        assertAllEqual(season)
        assertAllEqual(budburst)
        assertEquals(50.0, season.hub(), 0.0)
        assertEquals(30.0, budburst.hub(), 0.0)
    }

    @Test
    fun `missing Flowering and Veraison stay incomplete on every surface`() {
        listOf("flowering", "veraison").forEach { mode ->
            val fixture = fixture(Paddock(mode, "v1", mode, resetModeOverride = mode))
            val row = fixture.hubRow()
            assertNull(row.resetDateMs)
            assertFalse(row.hasGddValue)
            assertTrue(fixture.detailSeries().isEmpty())
            assertNull(fixture.surfaceNullable())
        }
    }

    @Test
    fun `block reset and GDD BEDD overrides win everywhere`() {
        val gdd = fixture(Paddock("gdd", "v1", "GDD", floweringDate = "2026-09-03", resetModeOverride = "flowering", calculationModeOverride = "gdd"))
        val bedd = fixture(Paddock("bedd", "v1", "BEDD", floweringDate = "2026-09-03", resetModeOverride = "flowering", calculationModeOverride = "bedd"))
        assertAllEqual(gdd)
        assertAllEqual(bedd)
        assertEquals(30.0, gdd.hub(), 0.0)
        assertTrue(bedd.hub() < gdd.hub())
    }

    @Test
    fun `vineyard timezone controls every surface regardless of device timezone`() {
        val original = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("America/Los_Angeles"))
            val auckland = TimeZone.getTimeZone("Pacific/Auckland")
            val fixture = fixture(Paddock("b1", "v1", "North", budburstDate = "2026-09-01"), auckland)
            assertAllEqual(fixture)
        } finally {
            TimeZone.setDefault(original)
        }
    }

    @Test
    fun `refresh identity ignores wall clock milliseconds and coverage uses earliest block`() {
        val request = OptimalRipenessWeatherRequest(
            "v1", -33.28, 149.10, utc, start,
            listOf(
                Paddock("later", "v1", "Later", budburstDate = "2026-09-16"),
                Paddock("earlier", "v1", "Earlier", budburstDate = "2026-09-01"),
            ),
            GddResetMode.BUDBURST,
        )
        val first = OptimalRipenessWeatherCoordinator.refreshIdentity(request, "davis:s1", start, end + 1)
        val second = OptimalRipenessWeatherCoordinator.refreshIdentity(request, "davis:s1", start, end + 999)
        val earlierSeason = OptimalRipenessWeatherCoordinator.refreshIdentity(request, "davis:s1", start - 86_400_000L, end + 999)
        assertEquals(first, second)
        assertFalse(first == earlierSeason)
        assertEquals(start, request.paddocks.mapNotNull { it.resetDateMs(it.effectiveResetMode(request.globalResetMode), request.seasonStartMs) }.minOrNull())
    }

    @Test
    fun `allocation snapshots resolve through the same presentation contract as Block Details`() {
        val builtIn = PaddockVarietyAllocation(varietyKey = "chardonnay", percent = 100.0)
        val named = PaddockVarietyAllocation(name = "Shiraz", percent = 100.0)
        val idOnly = PaddockVarietyAllocation(varietyId = "variety-1", percent = 100.0)
        val catalog = listOf(GrapeVarietyRow("variety-1", "v1", "pinot_noir", "Pinot Noir"))

        assertTrue(blockVarietyRecognised(Paddock("b1", "v1", "North", varietyAllocations = listOf(builtIn)), emptyList()))
        assertTrue(blockVarietyRecognised(Paddock("b2", "v1", "South", varietyAllocations = listOf(named)), emptyList()))
        assertTrue(blockVarietyRecognised(Paddock("b3", "v1", "East", varietyAllocations = listOf(idOnly)), catalog))
    }

    @Test
    fun `unrelated cached weather is unavailable rather than a genuine zero`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, mapOf("20260801" to DailyTemp(20.0, 10.0)))
        val block = Paddock("b1", "v1", "North", budburstDate = "2026-09-01")

        val calculation = calculateOptimalRipenessBlock(
            service, key, -33.28, block, start, GddResetMode.BUDBURST,
            GddCalculationMode.GDD, utc, end,
        )

        assertFalse(calculation.hasValue)
        assertEquals(0.0, calculation.total, 0.0)
    }

    @Test
    fun `partial in-window weather remains calculable and is marked incomplete`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, mapOf("20260903" to DailyTemp(20.0, 10.0)))
        val block = Paddock("b1", "v1", "North", budburstDate = "2026-09-01")

        val calculation = calculateOptimalRipenessBlock(
            service, key, -33.28, block, start, GddResetMode.BUDBURST,
            GddCalculationMode.GDD, utc, end,
        )

        assertTrue(calculation.hasValue)
        assertTrue(calculation.isIncomplete)
        assertTrue(calculation.total > 0.0)
    }

    @Test
    fun `startup owns one coordinator and UI surfaces construct no weather repositories`() {
        val root = File("src/main/java/com/rork/vinetrack")
        val app = File(root, "ui/AppViewModel.kt").readText()
        val coordinator = File(root, "data/OptimalRipenessWeatherCoordinator.kt").readText()
        val surfaces = listOf(
            File(root, "ui/screens/OptimalRipenessScreen.kt"),
            File(root, "ui/screens/VarietyGDDDetailScreen.kt"),
            File(root, "ui/screens/RipenessSurfaces.kt"),
        ).joinToString("\n") { it.readText() }
        assertTrue(app.contains("prepareOptimalRipenessWeather(vineyardId)"))
        assertTrue(app.contains("refreshIfNeeded(isOnline = true)"))
        assertTrue(app.contains("refreshIfNeeded(isOnline = _ui.value.isOnline)"))
        assertTrue(coordinator.contains("DailyWeatherCacheStore(appContext)"))
        assertTrue(coordinator.contains("private var refreshJob: Job?"))
        assertFalse(surfaces.contains("OptimalRipenessWeatherRepository("))
        assertFalse(surfaces.contains("DavisWeatherLinkRepository("))
        assertFalse(surfaces.contains("VineyardWeatherIntegrationRepository("))
    }

    private fun assertAllEqual(fixture: Fixture) {
        assertEquals(fixture.hub(), fixture.detail(), 0.0)
        assertEquals(fixture.hub(), fixture.surface(), 0.0)
    }

    private fun fixture(block: Paddock, zone: TimeZone = utc): Fixture {
        val service = DegreeDayService(timeZone = zone)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, (1..5).associate { day -> "2026090$day" to DailyTemp(30.0, 10.0) })
        return Fixture(service, key, block, zone)
    }

    private inner class Fixture(
        val service: DegreeDayService,
        val key: String,
        val block: Paddock,
        val zone: TimeZone,
    ) {
        fun hubRow() = computeRows(service, key, -33.28, listOf(block), emptyList(), false, end, start, GddResetMode.BUDBURST, GddCalculationMode.BEDD, zone).rows.single()
        fun hub(): Double = hubRow().total
        fun detailSeries() = computeVarietySeries(service, key, -33.28, listOf(block), start, GddResetMode.BUDBURST, GddCalculationMode.BEDD, zone, end)
        fun detail(): Double = detailSeries().single().total
        fun surfaceNullable() = blockGddTotal(service, key, -33.28, block, start, GddResetMode.BUDBURST, GddCalculationMode.BEDD, zone, end)
        fun surface(): Double = requireNotNull(surfaceNullable()).first
    }
}
