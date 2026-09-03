package com.rork.vinetrack.data

import com.rork.vinetrack.data.ripeness.CivilDate
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap.LatLng
import com.rork.vinetrack.data.ripeness.ElRipenessSeason
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import kotlin.math.abs

/**
 * Equivalence test against the shipped Portal E-L Ripeness Heatmap, driven by
 * the canonical contract package (`el-ripeness-heatmap-fixture.json` +
 * `el-ripeness-heatmap-expected.json`, contract **v1.1.0**).
 *
 * The same fixture drives `ELRipenessHeatmapContractTests` on iOS. Both suites
 * must agree with the Portal and therefore with each other.
 *
 * ## What 1.1.0 changed, and what this suite now pins
 *
 * 1. **Vintage is the shared [VintageResolver]** — the mirror of the database
 *    `resolve_vintage_year` (SQL 119). A 1 January season start resolves to the
 *    observation's own calendar year. There is no second Vintage implementation.
 * 2. **Full IEEE-754 precision throughout.** The expected file now publishes
 *    `*_full_precision` siblings for every value that drives a calculation;
 *    those are asserted exactly, and the six-decimal display copies to 1e-6.
 *    No rounded value is ever fed back into a calculation.
 * 3. **The two northern records are `wrong_vineyard`**, not a date error — both
 *    carry valid dates and resolve to a valid Vintage under their own vineyard's
 *    1 January season settings.
 */
class ElRipenessHeatmapContractTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private fun load(name: String): JsonObject {
        val stream = javaClass.classLoader!!.getResourceAsStream("portal-contracts/$name")
            ?: error("missing contract resource: $name")
        return json.parseToJsonElement(stream.bufferedReader().use { it.readText() }).jsonObject
    }

    private val fixture: JsonObject by lazy { load("el-ripeness-heatmap-fixture.json") }
    private val expected: JsonObject by lazy { load("el-ripeness-heatmap-expected.json") }

    // ---- JSON helpers ----

    private fun JsonObject.arr(key: String): JsonArray = this[key]!!.jsonArray
    private fun JsonObject.obj(key: String): JsonObject = this[key]!!.jsonObject
    private fun JsonObject.str(key: String): String = this[key]!!.jsonPrimitive.content
    private fun JsonObject.strOrNull(key: String): String? =
        this[key]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
    private fun JsonObject.dbl(key: String): Double = this[key]!!.jsonPrimitive.content.toDouble()
    private fun JsonObject.dblOrNull(key: String): Double? =
        this[key]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content?.toDouble()
    private fun JsonObject.int(key: String): Int = this[key]!!.jsonPrimitive.content.toInt()
    private fun JsonObject.intOrNull(key: String): Int? =
        this[key]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content?.toInt()
    private fun JsonObject.bool(key: String): Boolean = this[key]!!.jsonPrimitive.content.toBoolean()
    private fun JsonObject.ids(key: String): List<String> = arr(key).map { it.jsonPrimitive.content }

    private fun approx(message: String, expectedValue: Double, actual: Double, tolerance: Double = 1e-6) {
        assertTrue(
            "$message: expected $expectedValue, got $actual (delta ${abs(expectedValue - actual)})",
            abs(expectedValue - actual) <= tolerance,
        )
    }

    // ---- Fixture -> domain ----

    private val southVineyardId = "vy-fixture-south"

    /**
     * Canonical assignment signal from a fixture `placement` block, exactly as
     * contract section 10 derives it: a placement row can only revoke or
     * confirm; absence of any signal falls back to `paddock_id`.
     */
    private fun explicitAssigned(placement: JsonObject?): Boolean? {
        if (placement == null) return null
        val flag = placement["is_location_assigned"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content?.toBoolean()
        val warning = placement.strOrNull("location_warning_code")
        val hasSignal = flag != null || !warning.isNullOrEmpty()
        if (!hasSignal) return null
        return flag == true && warning != "unassigned_location"
    }

    /**
     * EVERY fixture record, including the two that belong to another vineyard.
     * Scoping is the core's job (`selectedVineyardId`), not the test's — that is
     * what lets `wrong_vineyard` be asserted as a real outcome.
     */
    private fun rawRecords(): List<ElRipenessHeatmap.RawRecord> =
        fixture.arr("observations").map { it.jsonObject }
            .map { o ->
                ElRipenessHeatmap.RawRecord(
                    id = o.str("id"),
                    vineyardId = o.strOrNull("vineyard_id"),
                    paddockId = o.strOrNull("paddock_id"),
                    stageCode = o.strOrNull("growth_stage_code"),
                    latitude = o.dblOrNull("latitude"),
                    longitude = o.dblOrNull("longitude"),
                    date = o.strOrNull("date"),
                    deletedAt = o.strOrNull("deleted_at"),
                )
            }

    private fun assignedById(): Map<String, Boolean> =
        fixture.arr("observations").map { it.jsonObject }
            .mapNotNull { o ->
                explicitAssigned(o["placement"]?.jsonObject)?.let { o.str("id") to it }
            }.toMap()

    private fun blocks(): List<ElRipenessHeatmap.BlockInput> =
        fixture.arr("blocks").map { it.jsonObject }.map { b ->
            ElRipenessHeatmap.BlockInput(
                id = b.str("id"),
                name = b.strOrNull("name"),
                polygon = b.arr("polygon_points").map { p ->
                    LatLng(p.jsonObject.dbl("lat"), p.jsonObject.dbl("lng"))
                },
            )
        }

    /** Season-filtered observations for the southern fixture vineyard, Vintage 2026. */
    private fun seasonObservations(): List<ElRipenessHeatmap.Observation> {
        val all = ElRipenessHeatmap.toObservations(rawRecords(), assignedById(), southVineyardId)
        return ElRipenessSeason.filterToVintage(all, 2026, 7, 1)
    }

    // ---- Section 0: constants ----

    @Test
    fun `constants match the contract`() {
        val c = expected.obj("constants")
        assertEquals(c.dbl("EL_MIN"), ElRipenessHeatmap.EL_MIN, 0.0)
        assertEquals(c.dbl("EL_MAX"), ElRipenessHeatmap.EL_MAX, 0.0)
        assertEquals(c.dbl("IDW_POWER"), ElRipenessHeatmap.IDW_POWER, 0.0)
        assertEquals(c.dbl("RECENCY_HALF_LIFE_DAYS"), ElRipenessHeatmap.RECENCY_HALF_LIFE_DAYS, 0.0)
        assertEquals(c.dbl("RECENCY_MAX_AGE_DAYS"), ElRipenessHeatmap.RECENCY_MAX_AGE_DAYS, 0.0)
        assertEquals(c.dbl("RECENCY_TAPER_DAYS"), ElRipenessHeatmap.RECENCY_TAPER_DAYS, 0.0)
        assertEquals(c.int("GRID_RESOLUTION"), ElRipenessHeatmap.GRID_RESOLUTION)
        assertEquals(c.dbl("MAX_ALPHA"), ElRipenessHeatmap.MAX_ALPHA, 0.0)
        assertEquals(c.dbl("MIN_ALPHA_FACTOR"), ElRipenessHeatmap.MIN_ALPHA_FACTOR, 0.0)
        assertEquals(c.dbl("HALO_FRACTION"), ElRipenessHeatmap.HALO_FRACTION, 0.0)
        assertEquals(c.dbl("GRADIENT_FRACTION"), ElRipenessHeatmap.GRADIENT_FRACTION, 0.0)
        assertEquals(c.dbl("ZERO_DISTANCE_EPSILON_D2"), ElRipenessHeatmap.ZERO_DISTANCE_EPSILON_D2, 0.0)

        val stops = c.arr("EL_COLOUR_STOPS").map { it.jsonObject }
        assertEquals(stops.size, ElRipenessHeatmap.colourStops.size)
        stops.forEachIndexed { i, s ->
            val mine = ElRipenessHeatmap.colourStops[i]
            assertEquals(s.dbl("el"), mine.el, 0.0)
            assertEquals(s.obj("rgb").int("r"), mine.rgb.r)
            assertEquals(s.obj("rgb").int("g"), mine.rgb.g)
            assertEquals(s.obj("rgb").int("b"), mine.rgb.b)
            assertEquals(s.str("hex"), mine.rgb.hex)
        }
    }

    // ---- Section 1: E-L parsing ----

    @Test
    fun `every E-L parsing case matches, including the E-L 47 exclusion`() {
        for (case in expected.arr("el_parsing").map { it.jsonObject }) {
            val raw = case["input"]
            val input: String? = when {
                raw == null || raw is JsonNull -> null
                else -> (raw as JsonPrimitive).content
            }
            val want = case.dblOrNull("parsed")
            val got = ElRipenessHeatmap.parseElStage(input)
            if (want == null) {
                assertNull("parseElStage(${input ?: "null"}) must be excluded", got)
            } else {
                assertNotNull("parseElStage(${input}) must parse", got)
                approx("parseElStage($input)", want, got!!, 1e-12)
            }
        }
    }

    @Test
    fun `E-L 47 is excluded and never clamped to 43`() {
        assertNull(ElRipenessHeatmap.parseElStage("E-L 47"))
        assertNull(ElRipenessHeatmap.parseElStage("47"))
        assertNull(ElRipenessHeatmap.parseElStage("44"))
        assertNull(ElRipenessHeatmap.parseElStage("43.0000001"))
        assertEquals(43.0, ElRipenessHeatmap.parseElStage("43"))
    }

    // ---- Section 2: colour scale ----

    @Test
    fun `colour scale matches at every published stop`() {
        for (case in expected.arr("colour_scale").map { it.jsonObject }) {
            val el = case.dbl("el")
            val rgb = ElRipenessHeatmap.elColour(el)
            assertEquals("R at E-L $el", case.obj("rgb").int("r"), rgb.r)
            assertEquals("G at E-L $el", case.obj("rgb").int("g"), rgb.g)
            assertEquals("B at E-L $el", case.obj("rgb").int("b"), rgb.b)
            assertEquals("hex at E-L $el", case.str("hex"), rgb.hex)
        }
    }

    // ---- Section 3: recency ----

    @Test
    fun `recency weights match to ten decimal places`() {
        for (case in expected.arr("recency").map { it.jsonObject }) {
            val age = case.dbl("ageDays")
            approx("recencyWeight($age)", case.dbl("weight"), ElRipenessHeatmap.recencyWeight(age), 1e-10)
        }
    }

    @Test
    fun `the taper only engages after day 70 and zero lands exactly on day 84`() {
        assertTrue(ElRipenessHeatmap.recencyWeight(70) > ElRipenessHeatmap.recencyWeight(71))
        assertEquals(0.0, ElRipenessHeatmap.recencyWeight(84), 0.0)
        assertEquals(0.0, ElRipenessHeatmap.recencyWeight(85), 0.0)
        assertTrue(ElRipenessHeatmap.recencyWeight(83) > 0)
    }

    @Test
    fun `day arithmetic is whole-day and ignores time and timezone entirely`() {
        assertEquals(0, ElRipenessHeatmap.daysBetween("2026-01-10T23:59:59Z", "2026-01-10T00:00:00Z"))
        assertEquals(1, ElRipenessHeatmap.daysBetween("2026-01-10T23:00:00Z", "2026-01-11T01:00:00Z"))
        assertEquals(84, ElRipenessHeatmap.daysBetween("2025-11-02T00:00:00Z", "2026-01-25T00:00:00Z"))
        assertEquals(0, ElRipenessHeatmap.daysBetween("not-a-date", "2026-01-25"))
    }

    // ---- Section 4: vintage ----

    @Test
    fun `vintage assignment matches every published configuration`() {
        for (case in expected.arr("vintage_assignment").map { it.jsonObject }) {
            val m = case.int("season_start_month")
            val d = case.int("season_start_day")
            val date = case.str("date")
            assertEquals(
                "${case.str("config")} @ $date",
                case.int("vintage"),
                ElRipenessSeason.vintageForDayKey(date, m, d),
            )
        }
    }

    @Test
    fun `season ranges match, including the 1 January boundary`() {
        for (case in expected.arr("season_ranges").map { it.jsonObject }) {
            val range = ElRipenessSeason.seasonRangeForVintage(case.int("m"), case.int("d"), case.int("vintage"))
            assertEquals(case.str("startISO"), range.startIso)
            assertEquals(case.str("endISO"), range.endIso)
        }
    }

    @Test
    fun `missing season settings fall back to 1 July`() {
        val s = ElRipenessSeason.normaliseSeasonSettings(null, null)
        assertEquals(7, s.month)
        assertEquals(1, s.day)
        assertEquals(7, ElRipenessSeason.normaliseSeasonSettings(13, 5).month)
        assertEquals(1, ElRipenessSeason.normaliseSeasonSettings(7, 0).day)
        assertEquals(29, ElRipenessSeason.normaliseSeasonSettings(2, 31).day)
        assertEquals(30, ElRipenessSeason.normaliseSeasonSettings(4, 31).day)
    }

    // ---- Section 10: normalisation and assignment ----

    @Test
    fun `observation normalisation matches the contract record by record`() {
        val raw = rawRecords().associateBy { it.id }
        val included = ElRipenessHeatmap
            .toObservations(rawRecords(), assignedById(), southVineyardId)
            .associateBy { it.id }

        for (case in expected.arr("observation_normalisation").map { it.jsonObject }) {
            val id = case.str("id")
            val shouldInclude = case.bool("included_in_observations")
            val record = raw[id] ?: error("fixture is missing $id")

            assertEquals("$id owning vineyard", case.str("vineyard_id"), record.vineyardId)
            assertEquals("$id inclusion", shouldInclude, included[id] != null)

            // Vintage is resolved under the record's OWN vineyard's season
            // settings, which is why a wrong-vineyard record still has a valid one.
            val (sm, sd) = case.str("season_settings_used").split("/").map { it.toInt() }
            val date = ElRipenessHeatmap.observationDate(record)
            if (date != null) {
                assertEquals(
                    "$id vintage under ${case.str("season_settings_used")}",
                    case.int("vintage"),
                    ElRipenessSeason.vintageForDayKey(date, sm, sd),
                )
            }

            if (!shouldInclude) {
                val reason = ElRipenessHeatmap.exclusionReason(record, southVineyardId)
                assertNotNull("$id must have an exclusion reason", reason)
                assertEquals("$id exclusion reason", case.str("excluded_reason"), reason!!.wire)
                continue
            }

            val obs = included.getValue(id)
            approx("$id parsed E-L", case.dbl("parsed_el"), obs.el, 1e-12)
            assertEquals("$id assigned", case.bool("assigned"), obs.assigned)
            assertEquals("$id resolved block", case.strOrNull("resolved_paddock_id"), obs.paddockId)
        }
    }

    @Test
    fun `the northern records are wrong_vineyard, not a date error`() {
        val raw = rawRecords().associateBy { it.id }
        for (id in listOf("obs-n1-north", "obs-n2-north")) {
            val record = raw.getValue(id)
            assertNotNull("$id carries a valid date", ElRipenessHeatmap.observationDate(record))
            assertEquals(
                "$id is excluded by scoping, not by its date",
                ElRipenessHeatmap.ExclusionReason.WRONG_VINEYARD,
                ElRipenessHeatmap.exclusionReason(record, southVineyardId),
            )
            // Under its OWN vineyard it is a perfectly good observation.
            assertNull(
                "$id is valid within its own vineyard",
                ElRipenessHeatmap.exclusionReason(record, "vy-fixture-north"),
            )
        }
    }

    @Test
    fun `no_observation_date is used only when all three timestamps are absent`() {
        val dated = ElRipenessHeatmap.RawRecord(
            id = "x", vineyardId = southVineyardId, paddockId = "BLOCK_A",
            stageCode = "23", latitude = -34.5, longitude = 138.5, date = "2026-01-25",
        )
        assertNull(ElRipenessHeatmap.exclusionReason(dated, southVineyardId))
        assertEquals(
            ElRipenessHeatmap.ExclusionReason.NO_OBSERVATION_DATE,
            ElRipenessHeatmap.exclusionReason(dated.copy(date = null), southVineyardId),
        )
        // Falls back through completed_at and created_at before giving up.
        assertNull(
            ElRipenessHeatmap.exclusionReason(
                dated.copy(date = null, completedAt = "2026-01-25T04:00:00Z"), southVineyardId,
            ),
        )
        assertNull(
            ElRipenessHeatmap.exclusionReason(
                dated.copy(date = null, createdAt = "2026-01-25T04:00:00Z"), southVineyardId,
            ),
        )
    }

    // ---- Vintage authority: the shared resolver, and only the shared resolver ----

    @Test
    fun `heatmap vintage is the shared VintageResolver, never a second rule`() {
        for (case in expected.arr("vintage_assignment").map { it.jsonObject }) {
            val m = case.int("season_start_month")
            val d = case.int("season_start_day")
            val date = CivilDate.parse(case.str("date"))!!
            assertEquals(
                "${case.str("config")} @ ${case.str("date")} must come from VintageResolver",
                VintageResolver.vintageYear(LocalDate.of(date.year, date.month, date.day), m, d),
                ElRipenessSeason.vintageForDate(date, m, d),
            )
        }
    }

    @Test
    fun `a 1 January season start makes the Vintage the calendar year`() {
        // The SQL 119 rule. 2026-02-15 under a 1 Jan start is Vintage 2026 — an
        // implementation that answers 2027 is non-conformant (contract 1.1.0 s4).
        assertEquals(2025, ElRipenessSeason.vintageForDayKey("2025-12-31T00:00:00Z", 1, 1))
        assertEquals(2026, ElRipenessSeason.vintageForDayKey("2026-01-01T00:00:00Z", 1, 1))
        assertEquals(2026, ElRipenessSeason.vintageForDayKey("2026-02-15", 1, 1))
        assertEquals(2026, ElRipenessSeason.vintageForDayKey("2026-12-31", 1, 1))
        assertEquals(2027, ElRipenessSeason.vintageForDayKey("2027-01-01", 1, 1))
    }

    @Test
    fun `an assigned Vintage range always contains the observation date`() {
        // The invariant contract 1.1.0 s4 states explicitly. Exhaustive over every
        // season start and a full two-year span of dates.
        var day = CivilDate.parse("2025-01-01")!!
        val end = CivilDate.parse("2027-01-01")!!
        while (day < end) {
            for ((m, d) in listOf(1 to 1, 2 to 29, 7 to 1, 11 to 1, 12 to 31)) {
                val vintage = ElRipenessSeason.vintageForDate(day, m, d)
                val range = ElRipenessSeason.seasonRangeForVintage(m, d, vintage)
                assertTrue(
                    "${day.iso} (start $m/$d, Vintage $vintage) must fall inside ${range.startIso}..${range.endIso}",
                    day.iso >= range.startIso && day.iso <= range.endIso,
                )
            }
            day = day.adding(1)
        }
    }

    @Test
    fun `a revoked placement leaves a visible but unassigned observation`() {
        val obs = ElRipenessHeatmap.toObservations(rawRecords(), assignedById())
            .first { it.id == "obs-u1-unassigned" }
        assertTrue("still a normalised, visible pin", obs.el == 25.0)
        assertTrue("placement revoked the assignment", !obs.assigned)
        assertNull("and with it the block identity", obs.paddockId)
    }

    @Test
    fun `placement can only revoke or confirm, never relocate`() {
        // No signal at all -> fall back to paddock_id.
        assertEquals(true to "BLOCK_A", ElRipenessHeatmap.resolveAssignment(null, "BLOCK_A"))
        assertEquals(false to null, ElRipenessHeatmap.resolveAssignment(null, null))
        // Confirmed -> keeps the record's own block.
        assertEquals(true to "BLOCK_A", ElRipenessHeatmap.resolveAssignment(true, "BLOCK_A"))
        // Revoked -> drops the block entirely.
        assertEquals(false to null, ElRipenessHeatmap.resolveAssignment(false, "BLOCK_A"))
        // Confirmed but no block -> still unassigned.
        assertEquals(false to null, ElRipenessHeatmap.resolveAssignment(true, null))
    }

    // ---- Sections 7 and 9: modes and medians ----

    @Test
    fun `block mode selection matches the truth table`() {
        for (case in expected.arr("block_mode_selection").map { it.jsonObject }) {
            val mode = ElRipenessHeatmap.blockHeatMode(
                influencing = case.int("influencing"),
                hasPolygon = case.bool("has_polygon"),
                totalObservations = case.int("total"),
            )
            assertEquals(
                "influencing=${case.int("influencing")} polygon=${case.bool("has_polygon")}",
                case.str("mode"), mode.wire,
            )
        }
    }

    @Test
    fun `medians match, odd even and empty`() {
        for (case in expected.arr("median_cases").map { it.jsonObject }) {
            val values = case.arr("values").map { it.jsonPrimitive.content.toDouble() }
            val want = case.dblOrNull("median")
            val got = ElRipenessHeatmap.medianStage(values)
            if (want == null) assertNull(got) else approx("median of $values", want, got!!, 1e-12)
        }
    }

    @Test
    fun `E-L display formatting matches`() {
        assertEquals("E-L 25", ElRipenessHeatmap.formatEl(25.0))
        assertEquals("E-L 12.5", ElRipenessHeatmap.formatEl(12.5))
        assertEquals("E-L 23.5", ElRipenessHeatmap.formatEl(23.5))
        assertEquals("—", ElRipenessHeatmap.formatEl(null))
    }

    // ---- Per-date model ----

    @Test
    fun `status counts match at every timeline date`() {
        val obs = seasonObservations()
        for (pd in expected.arr("per_date").map { it.jsonObject }) {
            val date = pd.str("date")
            val model = ElRipenessHeatmap.buildHeatModel(obs, blocks(), date)

            assertEquals("$date recorded", pd.int("recorded_observations_available"), model.qualifying.size)
            assertEquals("$date influencing", pd.int("influencing_observations"), model.influencing.size)
            assertEquals("$date stale", pd.int("stale_observations"), model.stale.size)
            assertEquals("$date unassigned", pd.ids("unassigned_ids"), model.unassigned.map { it.id })

            val median = pd.dblOrNull("typical_recorded_stage")
            if (median == null) assertNull(model.medianEl) else approx("$date median", median, model.medianEl!!)
            assertEquals("$date median display", pd.str("typical_recorded_stage_display"), ElRipenessHeatmap.formatEl(model.medianEl))
        }
    }

    @Test
    fun `the recorded total counts an unassigned pin that is in neither partition`() {
        // 2026-01-25: 14 recorded = 11 influencing + 2 stale + 1 unassigned.
        // Both partitions are computed over ASSIGNED observations only, so a
        // revoked pin is counted once in the total and never again. The totals
        // are not meant to balance.
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-01-25")
        assertEquals(14, model.qualifying.size)
        assertEquals(11, model.influencing.size)
        assertEquals(2, model.stale.size)
        assertEquals(listOf("obs-u1-unassigned"), model.unassigned.map { it.id })
        assertEquals(
            "the residual record is the revoked placement, not a miscount",
            14, model.influencing.size + model.stale.size + model.unassigned.size,
        )
    }

    @Test
    fun `per block mode ids median geometry and recency weights match`() {
        val obs = seasonObservations()
        for (pd in expected.arr("per_date").map { it.jsonObject }) {
            val date = pd.str("date")
            val model = ElRipenessHeatmap.buildHeatModel(obs, blocks(), date)
            val byId = model.blocks.associateBy { it.paddockId }

            for (eb in pd.arr("blocks").map { it.jsonObject }) {
                val id = eb.str("paddock_id")
                val block = byId[id] ?: error("missing block $id")
                val tag = "$date/$id"

                assertEquals("$tag mode", eb.str("mode"), block.mode.wire)
                assertEquals("$tag observations", eb.ids("observation_ids"), block.observations.map { it.id })
                assertEquals("$tag influencing", eb.ids("influencing_ids"), block.influencing.map { it.id })
                assertEquals("$tag stale", eb.ids("stale_ids"), block.stale.map { it.id })

                val median = eb.dblOrNull("median_el")
                if (median == null) assertNull("$tag median", block.medianEl)
                else approx("$tag median", median, block.medianEl!!)
                assertEquals("$tag median display", eb.str("median_display"), ElRipenessHeatmap.formatEl(block.medianEl))

                val diag = eb.dblOrNull("polygon_diagonal_deg")
                if (diag == null) assertNull("$tag diagonal", block.diagonal)
                else approx("$tag diagonal", diag, block.diagonal!!, 5e-7)

                val maxInf = eb.dblOrNull("max_influence_deg")
                if (maxInf == null) assertNull("$tag maxInfluence", block.maxInfluenceDeg)
                else approx("$tag maxInfluence (display)", maxInf, block.maxInfluenceDeg!!, 1e-6)

                // The value that actually drove the calculation — no rounding.
                val maxInfFull = eb.dblOrNull("max_influence_deg_full_precision")
                if (maxInfFull == null) assertNull("$tag maxInfluence full", block.maxInfluenceDeg)
                else approx("$tag maxInfluence (full precision)", maxInfFull, block.maxInfluenceDeg!!, 1e-12)

                assertEquals("$tag grid present", eb.bool("grid_present"), block.grid != null)
                if (eb.bool("grid_present")) {
                    val res = eb.arr("grid_resolution").map { it.jsonPrimitive.content.toInt() }
                    assertEquals("$tag grid rows", res[0], block.grid!!.size)
                    assertEquals("$tag grid cols", res[1], block.grid!![0].size)
                    val gb = eb.obj("grid_bounds")
                    approx("$tag minLat", gb.dbl("minLat"), block.gridBounds!!.minLat, 1e-9)
                    approx("$tag maxLat", gb.dbl("maxLat"), block.gridBounds.maxLat, 1e-9)
                    approx("$tag minLng", gb.dbl("minLng"), block.gridBounds.minLng, 1e-9)
                    approx("$tag maxLng", gb.dbl("maxLng"), block.gridBounds.maxLng, 1e-9)
                } else {
                    assertNull("$tag weight grid", block.weightGrid)
                    assertNull("$tag grid bounds", block.gridBounds)
                }

                val weights = eb.arr("recency_weights").map { it.jsonObject }
                assertEquals("$tag weight count", weights.size, block.points.size)
                weights.forEachIndexed { i, w ->
                    val o = block.influencing[i]
                    assertEquals("$tag weight id", w.str("id"), o.id)
                    assertEquals("$tag age", w.int("age_days"), ElRipenessHeatmap.daysBetween(o.dateIso, date))
                    approx("$tag weight", w.dbl("weight"), block.points[i].w, 1e-10)
                }
            }
        }
    }

    @Test
    fun `sample points match for inside-polygon, IDW value, colour and alpha`() {
        val obs = seasonObservations()
        for (pd in expected.arr("per_date").map { it.jsonObject }) {
            val date = pd.str("date")
            val model = ElRipenessHeatmap.buildHeatModel(obs, blocks(), date)
            val byId = model.blocks.associateBy { it.paddockId }

            for (sp in pd.arr("sample_points").map { it.jsonObject }) {
                val block = byId[sp.str("block")] ?: error("missing block")
                val tag = "$date/${sp.str("id")}"
                val lat = sp.dbl("lat")
                val lng = sp.dbl("lng")

                val inside = ElRipenessHeatmap.pointInPolygon(LatLng(lat, lng), block.polygon)
                assertEquals("$tag inside polygon", sp.bool("inside_polygon"), inside)

                val radius = block.maxInfluenceDeg ?: Double.POSITIVE_INFINITY
                val sample = if (!inside) ElRipenessHeatmap.CellSample.EMPTY
                else ElRipenessHeatmap.evaluateCell(lat, lng, block.points, radius)

                val wantEl = sp.dblOrNull("idw_el")
                if (wantEl == null) assertNull("$tag idw", sample.value)
                else approx("$tag idw (display)", wantEl, sample.value!!, 1e-6)

                val wantElFull = sp.dblOrNull("idw_el_full_precision")
                if (wantElFull == null) assertNull("$tag idw full", sample.value)
                else approx("$tag idw (full precision)", wantElFull, sample.value!!, 1e-12)

                val wantRgb = sp["rgb"]?.takeIf { it !is JsonNull }?.jsonObject
                if (wantRgb == null) {
                    assertNull("$tag rgb", sample.value)
                } else {
                    val rgb = ElRipenessHeatmap.elColour(sample.value!!)
                    assertEquals("$tag R", wantRgb.int("r"), rgb.r)
                    assertEquals("$tag G", wantRgb.int("g"), rgb.g)
                    assertEquals("$tag B", wantRgb.int("b"), rgb.b)
                    assertEquals("$tag hex", sp.str("hex"), rgb.hex)
                }

                assertEquals(
                    "$tag alpha",
                    sp.int("alpha_0_255"),
                    ElRipenessHeatmap.alpha255(sample.value, sample.weight),
                )

                assertSampleWeight(tag, sp, block, sample, lat, lng)
            }
        }
    }

    /**
     * Pins `cell_weight` at BOTH published precisions. 1.1.0 regenerated these
     * from full-precision intermediates, so the full-precision sibling must match
     * exactly and the six-decimal display copy to within 1e-6.
     */
    private fun assertSampleWeight(
        tag: String,
        sp: JsonObject,
        @Suppress("UNUSED_PARAMETER") block: ElRipenessHeatmap.BlockHeat,
        sample: ElRipenessHeatmap.CellSample,
        @Suppress("UNUSED_PARAMETER") lat: Double,
        @Suppress("UNUSED_PARAMETER") lng: Double,
    ) {
        val want = sp.dblOrNull("cell_weight")
        if (want == null) {
            assertNull("$tag weight", sample.weight)
            assertNull("$tag weight full", sp.dblOrNull("cell_weight_full_precision"))
            return
        }
        approx("$tag cell weight (display)", want, sample.weight!!, 1e-6)

        val wantFull = sp.dblOrNull("cell_weight_full_precision")
        assertNotNull("$tag must publish a full-precision cell weight", wantFull)
        approx("$tag cell weight (full precision)", wantFull!!, sample.weight, 1e-12)
    }

    @Test
    fun `rounded display values are never fed back into a calculation`() {
        // Contract 1.1.0 s12a. Re-running a sparse cell through the ROUNDED radius
        // must give a different answer than the shipped path — proving the shipped
        // path is the full-precision one.
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-01-25")
        val blockC = model.blocks.first { it.paddockId == "BLOCK_C" }
        val full = blockC.maxInfluenceDeg!!
        val rounded = ElRipenessHeatmap.jsRound(full * 1e6) / 1e6
        assertTrue("the fixture radius must actually have digits past 1e-6", abs(full - rounded) > 0.0)

        val viaFull = ElRipenessHeatmap.evaluateCell(-34.5058, 138.5042, blockC.points, full).weight
        val viaRounded = ElRipenessHeatmap.evaluateCell(-34.5058, 138.5042, blockC.points, rounded).weight
        if (viaFull != null && viaRounded != null) {
            assertTrue(
                "a rounded radius must not reproduce the full-precision weight",
                abs(viaFull - viaRounded) > 0.0,
            )
        }
    }

    // ---- Block isolation ----

    @Test
    fun `adjacent blocks never share observations across the shared edge`() {
        val iso = expected.obj("block_isolation")
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), iso.str("date"))
        val a = model.blocks.first { it.paddockId == "BLOCK_A" }.influencing.map { it.id }
        val b = model.blocks.first { it.paddockId == "BLOCK_B" }.influencing.map { it.id }

        assertEquals(iso.ids("block_a_influencing_ids"), a)
        assertEquals(iso.ids("block_b_influencing_ids"), b)
        assertTrue("influencing sets must be disjoint", a.intersect(b.toSet()).isEmpty())
    }

    @Test
    fun `a block only ever interpolates from its own observations`() {
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-01-25")
        val blockA = model.blocks.first { it.paddockId == "BLOCK_A" }
        // 0.00001 deg west of the shared edge: still Block A's own surface.
        val sample = ElRipenessHeatmap.evaluateCell(
            -34.5020, 138.50399, blockA.points, blockA.maxInfluenceDeg ?: Double.POSITIVE_INFINITY,
        )
        approx("Block A at the shared edge", 33.092982, sample.value!!)
        assertTrue(
            "Block B's E-L 35 pin must not bleed across",
            blockA.influencing.none { it.id.startsWith("obs-b") },
        )
    }

    // ---- Zero-distance and geometry rules ----

    @Test
    fun `a zero-distance hit takes the exact value and stops the loop`() {
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-01-25")
        val blockA = model.blocks.first { it.paddockId == "BLOCK_A" }
        val sample = ElRipenessHeatmap.evaluateCell(-34.5020, 138.5020, blockA.points, Double.POSITIVE_INFINITY)
        assertEquals("obs-a2's exact E-L, unblended", 23.0, sample.value!!, 0.0)
        approx("and obs-a2's own recency weight", ElRipenessHeatmap.recencyWeight(5), sample.weight!!, 1e-12)
    }

    @Test
    fun `a halo clips hard at its rim`() {
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-01-25")
        val blockC = model.blocks.first { it.paddockId == "BLOCK_C" }
        assertEquals(ElRipenessHeatmap.Mode.HALO, blockC.mode)
        // Inside the polygon but beyond 0.22 x diagonal -> nothing is painted.
        val far = ElRipenessHeatmap.evaluateCell(-34.5062, 138.5038, blockC.points, blockC.maxInfluenceDeg!!)
        assertNull("beyond the rim", far.value)
        assertEquals(0, ElRipenessHeatmap.alpha255(far.value, far.weight))
    }

    @Test
    fun `stale-only blocks paint nothing and report no median`() {
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-04-30")
        for (id in listOf("BLOCK_B", "BLOCK_C", "BLOCK_F")) {
            val block = model.blocks.first { it.paddockId == id }
            assertEquals("$id mode", ElRipenessHeatmap.Mode.STALE, block.mode)
            assertNull("$id grid", block.grid)
            assertNull("$id median", block.medianEl)
            assertEquals("—", ElRipenessHeatmap.formatEl(block.medianEl))
        }
    }

    @Test
    fun `a polygon-less block keeps its observations but never paints`() {
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-01-25")
        val blockE = model.blocks.first { it.paddockId == "BLOCK_E" }
        assertEquals(ElRipenessHeatmap.Mode.NO_POLYGON, blockE.mode)
        assertEquals(listOf("obs-e1"), blockE.observations.map { it.id })
        assertNull(blockE.grid)
        assertNull(blockE.gridBounds)
        // It still counts toward the map-level influencing total.
        assertTrue(model.influencing.any { it.id == "obs-e1" })
    }

    @Test
    fun `a future observation is hidden entirely and returns later`() {
        val obs = seasonObservations()
        val atJan = ElRipenessHeatmap.buildHeatModel(obs, blocks(), "2026-01-25")
        assertTrue("hidden at 25 Jan", atJan.qualifying.none { it.id == "obs-a6-future" })

        val atApr = ElRipenessHeatmap.buildHeatModel(obs, blocks(), "2026-04-30")
        val blockA = atApr.blocks.first { it.paddockId == "BLOCK_A" }
        assertEquals("it alone drives the surface later", listOf("obs-a6-future"), blockA.influencing.map { it.id })
        assertEquals(ElRipenessHeatmap.Mode.HALO, blockA.mode)
    }

    @Test
    fun `an exactly-84-day-old observation contributes nothing`() {
        val model = ElRipenessHeatmap.buildHeatModel(seasonObservations(), blocks(), "2026-01-25")
        val blockA = model.blocks.first { it.paddockId == "BLOCK_A" }
        assertTrue("still a visible historical pin", blockA.observations.any { it.id == "obs-a5-day84" })
        assertTrue("but stale", blockA.stale.any { it.id == "obs-a5-day84" })
        assertTrue("and never influencing", blockA.influencing.none { it.id == "obs-a5-day84" })
    }

    @Test
    fun `historical playback makes a stale observation influencing again`() {
        val obs = seasonObservations()
        val later = ElRipenessHeatmap.buildHeatModel(obs, blocks(), "2026-01-25")
        assertTrue(later.blocks.first { it.paddockId == "BLOCK_A" }.stale.any { it.id == "obs-a5-day84" })

        val earlier = ElRipenessHeatmap.buildHeatModel(obs, blocks(), "2026-01-08")
        assertTrue(
            "moving the timeline back restores its influence",
            earlier.blocks.first { it.paddockId == "BLOCK_A" }.influencing.any { it.id == "obs-a5-day84" },
        )
    }

    @Test
    fun `civil dates round-trip without timezone drift`() {
        val d = CivilDate.parse("2026-01-01")!!
        assertEquals("2025-12-31", d.adding(-1).iso)
        assertEquals("2026-12-31", CivilDate.parse("2027-01-01")!!.adding(-1).iso)
        assertEquals("2024-02-29", CivilDate.parse("2024-03-01")!!.adding(-1).iso)
        assertNull(CivilDate.parse("nonsense"))
    }
}
