package com.rork.vinetrack.data.ripeness

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Pure, deterministic mirror of the shipped VineTrack Portal E-L Ripeness
 * Heatmap calculation (cross-platform contract v1.0.0).
 *
 * Every rule here is a direct transcription of the contract's Appendix A
 * reference implementation. It is free of UI, storage and networking so it can
 * be pinned by the shared fixture on both platforms. The Swift mirror
 * `ELRipeness` must stay numerically identical.
 *
 * Deliberate quirks reproduced verbatim (they are contract, not accident):
 * - JavaScript `Number()` parsing semantics, including hexadecimal literals.
 * - Day arithmetic on the ISO string's own date component, with **no**
 *   timezone conversion.
 * - Distance in "cosine-corrected degrees" using the *cell* latitude, while the
 *   bounding-box diagonal uses the box's `minLat`.
 * - E-L 47 is excluded, never clamped to E-L 43.
 */
object ElRipenessHeatmap {

    // ---- Constants (contract section 0) ----

    const val EL_MIN = 1.0
    const val EL_MAX = 43.0
    const val RECENCY_HALF_LIFE_DAYS = 21.0
    const val RECENCY_MAX_AGE_DAYS = 84.0
    const val RECENCY_TAPER_DAYS = 14.0
    const val IDW_POWER = 2.0
    const val GRID_RESOLUTION = 48
    const val MAX_ALPHA = 0.72
    const val MIN_ALPHA_FACTOR = 0.12
    const val HALO_FRACTION = 0.22
    const val GRADIENT_FRACTION = 0.35
    const val ZERO_DISTANCE_EPSILON_D2 = 1e-14

    /** JavaScript `Number.EPSILON`, used only to avoid divide-by-zero on horizontal edges. */
    private const val JS_EPSILON = 2.220446049250313e-16

    // ---- Colour ----

    data class Rgb(val r: Int, val g: Int, val b: Int) {
        val hex: String get() = String.format("#%02x%02x%02x", r, g, b)
    }

    data class ColourStop(val el: Double, val rgb: Rgb, val label: String)

    val colourStops: List<ColourStop> = listOf(
        ColourStop(1.0, Rgb(220, 38, 38), "EL 1 — dormant"),
        ColourStop(12.0, Rgb(234, 129, 24), "EL 12 — early development"),
        ColourStop(23.0, Rgb(234, 199, 24), "EL 23 — mid-season"),
        ColourStop(35.0, Rgb(132, 204, 22), "EL 35 — advanced"),
        ColourStop(43.0, Rgb(22, 143, 60), "EL 43 — harvest ripe"),
    )

    /** ECMAScript `Math.round`: half-up toward +infinity (not away-from-zero). */
    fun jsRound(value: Double): Double = floor(value + 0.5)

    fun clamp(n: Double, lo: Double, hi: Double): Double = min(hi, max(lo, n))

    /**
     * Piecewise linear interpolation in non-linear sRGB 8-bit space. No
     * linear-light conversion, no HSL, no Lab — plain channel mixing on the
     * stored 0–255 values, exactly as the Portal ships it.
     */
    fun elColour(el: Double): Rgb {
        val v = clamp(el, EL_MIN, EL_MAX)
        val first = colourStops.first()
        if (v <= first.el) return first.rgb
        for (i in 1 until colourStops.size) {
            val prev = colourStops[i - 1]
            val cur = colourStops[i]
            if (v <= cur.el) {
                val t = (v - prev.el) / (cur.el - prev.el)
                return Rgb(
                    jsRound(prev.rgb.r + (cur.rgb.r - prev.rgb.r) * t).toInt(),
                    jsRound(prev.rgb.g + (cur.rgb.g - prev.rgb.g) * t).toInt(),
                    jsRound(prev.rgb.b + (cur.rgb.b - prev.rgb.b) * t).toInt(),
                )
            }
        }
        return colourStops.last().rgb
    }

    /**
     * Contract section 6. The 0.12 floor applies only to cells that have a
     * value; a null cell is always fully transparent.
     */
    fun alpha255(value: Double?, cellWeight: Double?): Int {
        if (value == null) return 0
        val w = cellWeight ?: 1.0
        return jsRound(255 * MAX_ALPHA * clamp(w, MIN_ALPHA_FACTOR, 1.0)).toInt()
    }

    // ---- E-L parsing (contract section 1) ----

    /**
     * JavaScript `Number(String)` semantics. Returns null for NaN.
     *
     * Accepts decimals, a leading sign, exponent form, `Infinity`, and
     * hexadecimal / octal / binary literals. Rejects internal whitespace and
     * trailing characters. An empty string is 0, matching JavaScript.
     */
    fun jsNumber(raw: String): Double? {
        val s = raw.trim()
        if (s.isEmpty()) return 0.0
        if (s == "Infinity" || s == "+Infinity") return Double.POSITIVE_INFINITY
        if (s == "-Infinity") return Double.NEGATIVE_INFINITY

        // Radix literals carry no sign in JavaScript.
        if (s.length > 2 && s[0] == '0') {
            val radix = when (s[1]) {
                'x', 'X' -> 16
                'o', 'O' -> 8
                'b', 'B' -> 2
                else -> null
            }
            if (radix != null) {
                val digits = s.substring(2)
                return digits.toLongOrNull(radix)?.toDouble()
            }
        }

        if (!isStrictDecimalLiteral(s)) return null
        return s.toDoubleOrNull()
    }

    /**
     * `^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$` — deliberately stricter than
     * `toDoubleOrNull`, which would accept "NaN", "1d" and hex-float forms.
     */
    private fun isStrictDecimalLiteral(s: String): Boolean {
        var i = 0
        if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
        var intDigits = 0
        while (i < s.length && s[i] in '0'..'9') { i++; intDigits++ }
        var fracDigits = 0
        if (i < s.length && s[i] == '.') {
            i++
            while (i < s.length && s[i] in '0'..'9') { i++; fracDigits++ }
        }
        if (intDigits == 0 && fracDigits == 0) return false
        if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
            i++
            if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
            var expDigits = 0
            while (i < s.length && s[i] in '0'..'9') { i++; expDigits++ }
            if (expDigits == 0) return false
        }
        return i == s.length
    }

    /**
     * Parses a stored growth-stage code to an E-L value in [1, 43].
     *
     * **E-L 47 returns null.** It is outside the ripeness heat surface and is
     * never clamped to E-L 43; it remains available to the Summary report,
     * which does not use this function.
     */
    fun parseElStage(code: String?): Double? {
        if (code == null) return null
        val s = code.trim()
        if (s.isEmpty()) return null
        val cleaned = (stripElPrefix(s) ?: s).trim()
        val n = jsNumber(cleaned) ?: return null
        if (!n.isFinite()) return null
        if (n < EL_MIN || n > EL_MAX) return null
        return n
    }

    /** Strips only a LEADING E-L prefix: `^e\s*-?\s*l\s*` (case-insensitive). */
    private fun stripElPrefix(s: String): String? {
        var i = 0
        if (i >= s.length || (s[i] != 'e' && s[i] != 'E')) return null
        i++
        while (i < s.length && s[i].isWhitespace()) i++
        if (i < s.length && s[i] == '-') i++
        while (i < s.length && s[i].isWhitespace()) i++
        if (i >= s.length || (s[i] != 'l' && s[i] != 'L')) return null
        i++
        while (i < s.length && s[i].isWhitespace()) i++
        return s.substring(i)
    }

    /**
     * Display formatting: integers as `E-L 23`, non-integers to one decimal,
     * null as an em dash.
     */
    fun formatEl(el: Double?): String {
        if (el == null) return "—"
        return if (el == floor(el) && !el.isInfinite()) "E-L ${el.toInt()}"
        else "E-L ${String.format("%.1f", el)}"
    }

    // ---- Dates and recency (contract section 3) ----

    /**
     * The calendar-day key: the first 10 characters of the ISO string. A pure
     * slice — no timezone conversion is performed at any point.
     */
    fun dayKey(iso: String): String = if (iso.length <= 10) iso else iso.substring(0, 10)

    /**
     * Whole-day difference between two day keys. Both endpoints are treated as
     * start-of-day, so the result is always an integer number of days. There is
     * no elapsed-time or fractional-day component. Unparseable input is 0.
     */
    fun daysBetween(fromIso: String, toIso: String): Int {
        val a = CivilDate.parse(dayKey(fromIso)) ?: return 0
        val b = CivilDate.parse(dayKey(toIso)) ?: return 0
        return b.epochDay() - a.epochDay()
    }

    /**
     * `decay * taper`, zero at and beyond 84 days. The taper only engages after
     * day 70, which is why day 70 is pure exponential decay.
     */
    fun recencyWeight(ageDays: Double): Double {
        val age = max(0.0, ageDays)
        if (age >= RECENCY_MAX_AGE_DAYS) return 0.0
        val decay = 0.5.pow(age / RECENCY_HALF_LIFE_DAYS)
        val taper = clamp((RECENCY_MAX_AGE_DAYS - age) / RECENCY_TAPER_DAYS, 0.0, 1.0)
        return decay * taper
    }

    fun recencyWeight(ageDays: Int): Double = recencyWeight(ageDays.toDouble())

    // ---- Observations ----

    /**
     * A growth-stage record as read from `v_growth_stage_observations` (or the
     * `pins` fallback), before normalisation. Keeps the raw stage code and all
     * three timestamp candidates so the offline cache can re-normalise.
     */
    data class RawRecord(
        val id: String,
        val paddockId: String? = null,
        val stageCode: String? = null,
        val latitude: Double? = null,
        val longitude: Double? = null,
        val date: String? = null,
        val completedAt: String? = null,
        val createdAt: String? = null,
        val deletedAt: String? = null,
    )

    /** A normalised observation that survived every exclusion rule. */
    data class Observation(
        val id: String,
        val paddockId: String?,
        val assigned: Boolean,
        val el: Double,
        val lat: Double,
        val lng: Double,
        val dateIso: String,
    )

    /** Mirrors the `excluded_reason` values in the contract's expected file. */
    enum class ExclusionReason(val wire: String) {
        DELETED("deleted"),
        EL_OUT_OF_RANGE_OR_UNPARSEABLE("el_out_of_range_or_unparseable"),
        MISSING_COORDINATES("missing_coordinates"),
        NO_OBSERVATION_DATE("no_observation_date"),
    }

    /**
     * Observation timestamp precedence: `date` -> `completed_at` ->
     * `created_at`. `updated_at` is **never** used.
     */
    fun observationDate(record: RawRecord): String? =
        record.date?.takeIf { it.isNotEmpty() }
            ?: record.completedAt?.takeIf { it.isNotEmpty() }
            ?: record.createdAt?.takeIf { it.isNotEmpty() }

    /** Exact 0 is an unset sentinel — Null Island is not a vineyard. */
    fun isValidLatitude(value: Double?): Boolean =
        value != null && value.isFinite() && value >= -90 && value <= 90 && value != 0.0

    fun isValidLongitude(value: Double?): Boolean =
        value != null && value.isFinite() && value >= -180 && value <= 180 && value != 0.0

    /**
     * Canonical assignment (contract section 10). `pin_placements` can only
     * ever **revoke** an assignment or confirm it; the block identity itself
     * always comes from `paddock_id`.
     *
     * @param explicitAssigned resolved placement signal, or null when the
     *   placement row carries no signal at all.
     */
    fun resolveAssignment(explicitAssigned: Boolean?, paddockId: String?): Pair<Boolean, String?> {
        val hasBlock = !paddockId.isNullOrEmpty()
        val assigned = if (explicitAssigned == null) hasBlock else explicitAssigned && hasBlock
        return assigned to (if (assigned) paddockId else null)
    }

    /**
     * Normalises raw records into heat observations, dropping everything the
     * contract excludes. Order is preserved — IDW zero-distance hits resolve to
     * the first matching observation in this order.
     */
    fun toObservations(
        records: List<RawRecord>,
        assignedById: Map<String, Boolean> = emptyMap(),
    ): List<Observation> {
        val out = ArrayList<Observation>(records.size)
        for (r in records) {
            if (!r.deletedAt.isNullOrEmpty()) continue
            val el = parseElStage(r.stageCode) ?: continue
            if (!isValidLatitude(r.latitude) || !isValidLongitude(r.longitude)) continue
            val dateIso = observationDate(r) ?: continue
            val (assigned, paddockId) = resolveAssignment(assignedById[r.id], r.paddockId)
            out.add(
                Observation(
                    id = r.id,
                    paddockId = paddockId,
                    assigned = assigned,
                    el = el,
                    lat = r.latitude!!,
                    lng = r.longitude!!,
                    dateIso = dateIso,
                )
            )
        }
        return out
    }

    /**
     * The reason a record was excluded, for diagnostics and contract tests.
     * Evaluated in the same order as [toObservations].
     */
    fun exclusionReason(record: RawRecord): ExclusionReason? {
        if (!record.deletedAt.isNullOrEmpty()) return ExclusionReason.DELETED
        if (parseElStage(record.stageCode) == null) return ExclusionReason.EL_OUT_OF_RANGE_OR_UNPARSEABLE
        if (!isValidLatitude(record.latitude) || !isValidLongitude(record.longitude)) {
            return ExclusionReason.MISSING_COORDINATES
        }
        if (observationDate(record) == null) return ExclusionReason.NO_OBSERVATION_DATE
        return null
    }

    // ---- Filtering and partitioning ----

    /** Inclusive day-key string comparison against the season range. */
    fun filterToVintage(obs: List<Observation>, startIso: String, endIso: String): List<Observation> {
        val s = dayKey(startIso)
        val e = dayKey(endIso)
        return obs.filter { val d = dayKey(it.dateIso); d >= s && d <= e }
    }

    /**
     * Observations that exist at the timeline date. Future observations are
     * hidden completely — not stale, not counted, not rendered.
     */
    fun qualifyingAt(obs: List<Observation>, dateIso: String): List<Observation> {
        val d = dayKey(dateIso)
        return obs.filter { dayKey(it.dateIso) <= d }
    }

    fun isInfluencing(obs: Observation, atDateIso: String): Boolean {
        val age = daysBetween(obs.dateIso, atDateIso)
        return age >= 0 && recencyWeight(age) > 0
    }

    data class Partition(val influencing: List<Observation>, val stale: List<Observation>)

    fun partitionByInfluence(obs: List<Observation>, atDateIso: String): Partition {
        val influencing = ArrayList<Observation>()
        val stale = ArrayList<Observation>()
        for (o in obs) if (isInfluencing(o, atDateIso)) influencing.add(o) else stale.add(o)
        return Partition(influencing, stale)
    }

    /**
     * Ascending numeric median; the mean of the two middle values for an even
     * count. Empty input is null.
     */
    fun medianStage(els: List<Double>): Double? {
        if (els.isEmpty()) return null
        val v = els.sorted()
        val mid = v.size shr 1
        return if (v.size % 2 == 1) v[mid] else (v[mid - 1] + v[mid]) / 2
    }

    @JvmName("medianStageOfObservations")
    fun medianStage(obs: List<Observation>): Double? = medianStage(obs.map { it.el })

    // ---- Geometry (contract section 8) ----

    data class LatLng(val lat: Double, val lng: Double)

    data class Bounds(val minLat: Double, val maxLat: Double, val minLng: Double, val maxLng: Double)

    /**
     * Standard ray-casting / even-odd crossing test. Winding direction is
     * irrelevant; the polygon is implicitly closed. Strict comparisons are
     * reproduced exactly so edge behaviour matches the Portal.
     */
    fun pointInPolygon(pt: LatLng, poly: List<LatLng>): Boolean {
        if (poly.size < 3) return false
        var inside = false
        var j = poly.size - 1
        for (i in poly.indices) {
            val yi = poly[i].lat; val xi = poly[i].lng
            val yj = poly[j].lat; val xj = poly[j].lng
            val denominator = if (yj - yi == 0.0) JS_EPSILON else yj - yi
            if ((yi > pt.lat) != (yj > pt.lat) &&
                pt.lng < ((xj - xi) * (pt.lat - yi)) / denominator + xi
            ) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    fun polygonBounds(poly: List<LatLng>): Bounds? {
        if (poly.isEmpty()) return null
        var minLat = Double.POSITIVE_INFINITY
        var maxLat = Double.NEGATIVE_INFINITY
        var minLng = Double.POSITIVE_INFINITY
        var maxLng = Double.NEGATIVE_INFINITY
        for (p in poly) {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLng = min(minLng, p.lng); maxLng = max(maxLng, p.lng)
        }
        return Bounds(minLat, maxLat, minLng, maxLng)
    }

    /**
     * Bounding-box diagonal in cosine-corrected degrees. Note this uses the
     * box's `minLat`, whereas per-cell distances use the *cell* latitude — both
     * are reproduced exactly as the Portal writes them.
     */
    fun boundsDiagonal(b: Bounds): Double {
        val dLat = b.maxLat - b.minLat
        val dLng = (b.maxLng - b.minLng) * cos(b.minLat * PI / 180)
        return sqrt(dLat * dLat + dLng * dLng)
    }

    // ---- Modes (contract section 7) ----

    enum class Mode(val wire: String) {
        NO_POLYGON("no_polygon"),
        NONE("none"),
        STALE("stale"),
        HALO("halo"),
        GRADIENT("gradient"),
        SURFACE("surface"),
    }

    /** `no_polygon` is evaluated first and wins over every other condition. */
    fun blockHeatMode(influencing: Int, hasPolygon: Boolean, totalObservations: Int): Mode {
        if (!hasPolygon) return Mode.NO_POLYGON
        if (influencing <= 0) return if (totalObservations > 0) Mode.STALE else Mode.NONE
        if (influencing == 1) return Mode.HALO
        if (influencing == 2) return Mode.GRADIENT
        return Mode.SURFACE
    }

    fun maxInfluence(mode: Mode, diagonal: Double): Double = when (mode) {
        Mode.HALO -> diagonal * HALO_FRACTION
        Mode.GRADIENT -> diagonal * GRADIENT_FRACTION
        else -> Double.POSITIVE_INFINITY
    }

    // ---- IDW (contract section 5) ----

    data class WeightedPoint(val lat: Double, val lng: Double, val el: Double, val w: Double)

    data class CellSample(val value: Double?, val weight: Double?) {
        companion object { val EMPTY = CellSample(null, null) }
    }

    /**
     * Evaluates one cell. Longitude is scaled by the cosine of the **cell**
     * latitude; latitude deltas are unscaled. A zero-distance hit
     * (d^2 < 1e-14) breaks immediately and takes that observation's exact value
     * and recency weight, ignoring every later observation.
     */
    fun evaluateCell(
        lat: Double,
        lng: Double,
        points: List<WeightedPoint>,
        maxInfluence: Double,
    ): CellSample {
        var num = 0.0
        var den = 0.0
        var wNum = 0.0
        var nearest = Double.POSITIVE_INFINITY
        var exact: WeightedPoint? = null

        for (p in points) {
            val dLat = lat - p.lat
            val dLng = (lng - p.lng) * cos(lat * PI / 180)
            val d2 = dLat * dLat + dLng * dLng
            nearest = min(nearest, sqrt(d2))
            if (d2 < ZERO_DISTANCE_EPSILON_D2) { exact = p; break }
            val wDist = 1 / sqrt(d2).pow(IDW_POWER)
            val w = wDist * p.w
            num += p.el * w
            den += w
            wNum += p.w * wDist
        }

        if (exact == null && nearest > maxInfluence) return CellSample.EMPTY
        if (exact != null) return CellSample(exact.el, exact.w)
        if (den <= 0) return CellSample.EMPTY

        val falloff = if (maxInfluence.isFinite()) clamp(1 - nearest / maxInfluence, 0.0, 1.0) else 1.0
        val cellW = clamp((wNum / (if (den == 0.0) 1.0 else den)) * falloff, 0.0, 1.0)
        return CellSample(num / den, cellW)
    }

    // ---- Block and map models ----

    data class BlockHeat(
        val paddockId: String,
        val paddockName: String?,
        val polygon: List<LatLng>,
        val observations: List<Observation>,
        val influencing: List<Observation>,
        val stale: List<Observation>,
        val mode: Mode,
        val medianEl: Double?,
        val grid: List<List<Double?>>?,
        val weightGrid: List<List<Double?>>?,
        val gridBounds: Bounds?,
        val diagonal: Double?,
        val maxInfluenceDeg: Double?,
        val points: List<WeightedPoint>,
    )

    data class HeatModel(
        val blocks: List<BlockHeat>,
        val unassigned: List<Observation>,
        val qualifying: List<Observation>,
        val influencing: List<Observation>,
        val stale: List<Observation>,
        val medianEl: Double?,
    )

    data class BlockInput(val id: String, val name: String? = null, val polygon: List<LatLng>)

    fun buildBlockHeat(
        paddockId: String,
        paddockName: String?,
        polygon: List<LatLng>,
        observations: List<Observation>,
        atDateIso: String,
        resolution: Int = GRID_RESOLUTION,
    ): BlockHeat {
        val hasPolygon = polygon.size >= 3
        val split = partitionByInfluence(observations, atDateIso)
        val mode = blockHeatMode(split.influencing.size, hasPolygon, observations.size)
        val points = split.influencing.map { o ->
            WeightedPoint(o.lat, o.lng, o.el, recencyWeight(daysBetween(o.dateIso, atDateIso)))
        }
        val bounds = if (hasPolygon) polygonBounds(polygon) else null
        val diagonal = bounds?.let { boundsDiagonal(it) }

        // `none`, `stale` and `no_polygon` paint nothing at all.
        if (!hasPolygon || split.influencing.isEmpty() || bounds == null || diagonal == null) {
            return BlockHeat(
                paddockId, paddockName, polygon, observations, split.influencing, split.stale,
                mode, medianStage(split.influencing), null, null, null, diagonal, null, points,
            )
        }

        val influence = maxInfluence(mode, diagonal)
        val latStep = (bounds.maxLat - bounds.minLat) / (resolution - 1)
        val lngStep = (bounds.maxLng - bounds.minLng) / (resolution - 1)

        val grid = ArrayList<List<Double?>>(resolution)
        val weightGrid = ArrayList<List<Double?>>(resolution)

        // Row 0 is the SOUTH edge; the rasteriser flips it when drawing.
        for (i in 0 until resolution) {
            val lat = bounds.minLat + latStep * i
            val rowVals = ArrayList<Double?>(resolution)
            val rowW = ArrayList<Double?>(resolution)
            for (j in 0 until resolution) {
                val lng = bounds.minLng + lngStep * j
                if (!pointInPolygon(LatLng(lat, lng), polygon)) {
                    rowVals.add(null); rowW.add(null); continue
                }
                val sample = evaluateCell(lat, lng, points, influence)
                rowVals.add(sample.value)
                rowW.add(sample.weight)
            }
            grid.add(rowVals)
            weightGrid.add(rowW)
        }

        return BlockHeat(
            paddockId, paddockName, polygon, observations, split.influencing, split.stale,
            mode, medianStage(split.influencing), grid, weightGrid, bounds, diagonal,
            if (influence.isFinite()) influence else null, points,
        )
    }

    /**
     * Builds the whole map model for one timeline date.
     *
     * Status counts follow contract section 9: *recorded observations
     * available* counts every qualifying observation **including stale and
     * unassigned ones**, while *influencing* and *stale* are both computed over
     * assigned observations only. An unassigned pin therefore appears in the
     * recorded total but in neither partition — the totals are not meant to
     * balance.
     */
    fun buildHeatModel(
        observations: List<Observation>,
        blocks: List<BlockInput>,
        atDateIso: String,
        blockFilter: String? = null,
        resolution: Int = GRID_RESOLUTION,
    ): HeatModel {
        val filter = blockFilter?.takeIf { it.isNotEmpty() && it != "all" }
        val qualifyingAll = qualifyingAt(observations, atDateIso)
        val qualifying = if (filter != null) qualifyingAll.filter { it.paddockId == filter } else qualifyingAll

        val byBlock = LinkedHashMap<String, MutableList<Observation>>()
        for (o in qualifying) {
            if (!o.assigned || o.paddockId == null) continue
            byBlock.getOrPut(o.paddockId) { ArrayList() }.add(o)
        }

        val wanted = if (filter != null) blocks.filter { it.id == filter } else blocks
        val heat = wanted.map { b ->
            buildBlockHeat(b.id, b.name, b.polygon, byBlock[b.id] ?: emptyList(), atDateIso, resolution)
        }

        val assignedQualifying = qualifying.filter { it.assigned && it.paddockId != null }
        val split = partitionByInfluence(assignedQualifying, atDateIso)

        return HeatModel(
            blocks = heat,
            unassigned = if (filter != null) emptyList() else qualifying.filter { !it.assigned || it.paddockId == null },
            qualifying = qualifying,
            influencing = split.influencing,
            stale = split.stale,
            medianEl = medianStage(split.influencing),
        )
    }
}

/**
 * Timezone-free civil date used for whole-day arithmetic on ISO day keys.
 * Deliberately not `java.time`: the contract requires the stored string's own
 * date component to be treated as the vineyard-local day.
 */
data class CivilDate(val year: Int, val month: Int, val day: Int) : Comparable<CivilDate> {

    val iso: String get() = String.format("%04d-%02d-%02d", year, month, day)

    /** Days from the Unix epoch (Howard Hinnant's civil algorithm). */
    fun epochDay(): Int {
        val y = if (month <= 2) year - 1 else year
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (month + (if (month > 2) -3 else 9)) + 2) / 5 + day - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    fun adding(days: Int): CivilDate = fromEpochDay(epochDay() + days)

    override fun compareTo(other: CivilDate): Int {
        if (year != other.year) return year.compareTo(other.year)
        if (month != other.month) return month.compareTo(other.month)
        return day.compareTo(other.day)
    }

    companion object {
        /** Parses a `YYYY-MM-DD` prefix. Returns null for anything malformed. */
        fun parse(dayKey: String): CivilDate? {
            val parts = dayKey.split("-")
            if (parts.size != 3 || parts[0].length != 4) return null
            val y = parts[0].toIntOrNull() ?: return null
            val m = parts[1].toIntOrNull() ?: return null
            val d = parts[2].toIntOrNull() ?: return null
            if (m < 1 || m > 12 || d < 1 || d > 31) return null
            return CivilDate(y, m, d)
        }

        fun fromEpochDay(epochDay: Int): CivilDate {
            var z = epochDay + 719468
            val era = (if (z >= 0) z else z - 146096) / 146097
            z -= era * 146097
            val yoe = (z - z / 1460 + z / 36524 - z / 146096) / 365
            val y = yoe + era * 400
            val doy = z - (365 * yoe + yoe / 4 - yoe / 100)
            val mp = (5 * doy + 2) / 153
            val d = doy - (153 * mp + 2) / 5 + 1
            val m = mp + (if (mp < 10) 3 else -9)
            return CivilDate(if (m <= 2) y + 1 else y, m, d)
        }
    }
}
