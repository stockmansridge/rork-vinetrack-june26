package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PickingRecord
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.data.model.canonicalVarietyName
import com.rork.vinetrack.data.model.damageFactor
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

/**
 * Vintage-driven Yield Report logic, shared by the Reports screen and mirrored
 * on iOS (`YieldVintageReport.swift`) so both platforms pin the same rules:
 *
 *  * CURRENT vintage → the Yield Estimate per Block comes from the LATEST
 *    COMPLETED Bunch Count Trip for that Block in that vintage. Sessions are
 *    never summed or averaged — the newest completed observation wins.
 *  * PAST vintages → Actual Yield per Block + Variety: Detailed Picking Log
 *    totals supersede Basic actuals for the same combination (sql/180 rule,
 *    never added on top).
 *  * Damage adjustment is presentation-time: the base estimate is always kept
 *    and the trip's `applyDamage` flag chooses which figure is displayed.
 */
object YieldVintageReport {

    /** One current-vintage estimate row (per Block, from the latest completed trip). */
    data class EstimateRow(
        val paddockId: String,
        val blockName: String,
        val varietyLabel: String,
        val areaHectares: Double,
        /** Raw bunch-count estimate, no damage applied. Always preserved. */
        val baseTonnes: Double,
        /** Base × current effective damage factor for the block. */
        val adjustedTonnes: Double,
        val damageFactor: Double,
        val applyDamage: Boolean,
        val averageBunchesPerVine: Double,
        val samplesRecorded: Int,
        val samplesTotal: Int,
        val sessionId: String,
        val completedAt: String?,
    ) {
        val displayTonnes: Double get() = if (applyDamage) adjustedTonnes else baseTonnes
        val tonnesPerHectare: Double? get() = if (areaHectares > 0) displayTonnes / areaHectares else null
    }

    /** One past-vintage actual row (per Block + Variety). */
    data class ActualRow(
        val paddockId: String,
        val blockName: String,
        val varietyName: String,
        val tonnes: Double,
        val areaHectares: Double,
        /** Matching estimate for the same combination, for variance drilldown. */
        val estimatedTonnes: Double?,
        /** true = Detailed Picking Log total, false = Basic manual actual. */
        val fromDetailed: Boolean,
    ) {
        val varianceTonnes: Double? get() = estimatedTonnes?.let { tonnes - it }
        val tonnesPerHectare: Double? get() = if (areaHectares > 0) tonnes / areaHectares else null
    }

    /** Vintage a session belongs to: resolved from completedAt, else createdAt. */
    fun sessionVintage(
        session: YieldEstimationSession,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Int {
        val iso = session.completedAt ?: session.createdAt
        val date = runCatching { Instant.parse(iso).atZone(zone).toLocalDate() }
            .recoverCatching { LocalDate.parse(iso.take(10)) }
            .getOrDefault(LocalDate.now())
        return VintageResolver.vintageYear(date, seasonStartMonth, seasonStartDay)
    }

    /**
     * All vintages worth offering, newest first: the current vintage always
     * leads, then every vintage that has trips, archived records or picks.
     */
    fun availableVintages(
        currentVintage: Int,
        sessions: List<YieldEstimationSession>,
        yieldRecords: List<HistoricalYieldRecord>,
        pickingRecords: List<PickingRecord>,
        seasonStartMonth: Int,
        seasonStartDay: Int,
    ): List<Int> {
        val all = buildSet {
            add(currentVintage)
            sessions.filter { it.isCompleted }
                .forEach { add(sessionVintage(it, seasonStartMonth, seasonStartDay)) }
            yieldRecords.forEach { if (it.year > 0) add(it.year) }
            pickingRecords.forEach { if (it.vintage > 0) add(it.vintage) }
        }
        return all.sortedDescending()
    }

    /**
     * Latest completed trip that recorded sites in [paddockId] for [vintage].
     * The critical rule: newest completed observation wins; older trips remain
     * history and are never merged in.
     */
    fun latestCompletedSessionForBlock(
        sessions: List<YieldEstimationSession>,
        paddockId: String,
        vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int,
    ): YieldEstimationSession? = sessions
        .filter { it.isCompleted }
        .filter { sessionVintage(it, seasonStartMonth, seasonStartDay) == vintage }
        .filter { s -> s.sitesIn(paddockId).any { it.isRecorded } }
        .maxByOrNull { it.completedAt ?: it.createdAt }

    /**
     * Current-vintage estimate rows: one per block, driven by that block's
     * latest completed trip. Damage adjustment respects the trip's
     * [YieldEstimationSession.applyDamage] flag but the base figure is always
     * computed and returned untouched.
     */
    fun estimateRows(
        sessions: List<YieldEstimationSession>,
        paddocks: List<Paddock>,
        damageRecords: List<DamageRecord>,
        vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int,
    ): List<EstimateRow> {
        val rows = mutableListOf<EstimateRow>()
        for (paddock in paddocks) {
            val session = latestCompletedSessionForBlock(
                sessions, paddock.id, vintage, seasonStartMonth, seasonStartDay,
            ) ?: continue
            // Base estimate: damage factor forced to 1.0 so raw counts survive.
            val base = YieldSampleGenerator.calculateYieldEstimates(session, paddocks) { 1.0 }
                .firstOrNull { it.paddockId.equals(paddock.id, ignoreCase = true) }
                ?: continue
            if (base.samplesRecorded == 0) continue
            val factor = damageRecords.damageFactor(paddock.id)
            rows.add(
                EstimateRow(
                    paddockId = paddock.id,
                    blockName = paddock.name,
                    varietyLabel = varietyLabel(paddock),
                    areaHectares = paddock.areaHectares,
                    baseTonnes = base.estimatedYieldTonnes,
                    adjustedTonnes = base.estimatedYieldTonnes * factor,
                    damageFactor = factor,
                    applyDamage = session.applyDamage,
                    averageBunchesPerVine = base.averageBunchesPerVine,
                    samplesRecorded = base.samplesRecorded,
                    samplesTotal = base.samplesTotal,
                    sessionId = session.id,
                    completedAt = session.completedAt,
                ),
            )
        }
        return rows.sortedByDescending { it.displayTonnes }
    }

    /**
     * Past-vintage actual rows per Block + Variety. Detailed Picking Log sums
     * ARE the actual for their combination and supersede a Basic actual for
     * the same Block + Variety + Vintage — never added together.
     */
    fun actualRows(
        vintage: Int,
        paddocks: List<Paddock>,
        yieldRecords: List<HistoricalYieldRecord>,
        pickingRecords: List<PickingRecord>,
    ): List<ActualRow> {
        val paddockById = paddocks.associateBy { it.id.lowercase() }
        val rows = mutableListOf<ActualRow>()

        // Detailed picking totals for this vintage.
        val picksInVintage = pickingRecords.filter { it.vintage == vintage && it.deletedAt == null }
        val detailedKeys = HashSet<Pair<String, String>>()
        picksInVintage
            .groupBy { it.paddockId.lowercase() to canonicalVarietyName(it.varietyName) }
            .forEach { (key, picks) ->
                detailedKeys.add(key)
                val first = picks.first()
                val paddock = paddockById[key.first]
                rows.add(
                    ActualRow(
                        paddockId = first.paddockId,
                        blockName = first.paddockName.ifBlank { paddock?.name ?: "Block" },
                        varietyName = first.varietyName,
                        tonnes = picks.sumOf { it.weightKg } / 1000.0,
                        areaHectares = varietyArea(paddock, first.varietyName),
                        estimatedTonnes = estimateFor(vintage, first.paddockId, first.varietyName, paddock, yieldRecords),
                        fromDetailed = true,
                    ),
                )
            }

        // Basic actuals (historical block results) not superseded by picks.
        yieldRecords.filter { it.year == vintage }.forEach { record ->
            record.blocks.forEach { block ->
                val actual = block.actualYieldTonnes ?: return@forEach
                val paddock = paddockById[block.paddockId.lowercase()]
                val varieties = paddock?.varietyAllocations.orEmpty()
                    .mapNotNull { it.displayName?.takeIf { n -> n.isNotBlank() } }
                    .distinct()
                val variety = if (varieties.size == 1) varieties.first() else ""
                val key = block.paddockId.lowercase() to canonicalVarietyName(variety)
                // Superseded when picks cover the block+variety — also when the
                // block has multiple varieties and ANY of them has picks (a
                // block-level Basic actual cannot be split against them).
                val superseded = key in detailedKeys ||
                    (variety.isEmpty() && detailedKeys.any { it.first == block.paddockId.lowercase() }) ||
                    (varieties.size > 1 && varieties.any {
                        (block.paddockId.lowercase() to canonicalVarietyName(it)) in detailedKeys
                    })
                if (superseded) return@forEach
                rows.add(
                    ActualRow(
                        paddockId = block.paddockId,
                        blockName = block.paddockName,
                        varietyName = variety.ifBlank { varieties.joinToString(" · ") },
                        tonnes = actual,
                        areaHectares = block.areaHectares,
                        estimatedTonnes = block.yieldTonnes.takeIf { it > 0 },
                        fromDetailed = false,
                    ),
                )
            }
        }
        return rows.sortedByDescending { it.tonnes }
    }

    /** Display label for a block's planted varieties. */
    fun varietyLabel(paddock: Paddock?): String = paddock?.varietyAllocations.orEmpty()
        .mapNotNull { it.displayName?.takeIf { n -> n.isNotBlank() } }
        .distinct()
        .joinToString(" · ")
        .ifBlank { "—" }

    private fun varietyArea(paddock: Paddock?, varietyName: String): Double {
        paddock ?: return 0.0
        val allocations = paddock.varietyAllocations.orEmpty()
            .filter { !it.displayName.isNullOrBlank() }
        if (allocations.isEmpty()) return paddock.areaHectares
        val totalPct = allocations.sumOf { it.displayPercent ?: 0.0 }
        val match = allocations.filter {
            canonicalVarietyName(it.displayName!!) == canonicalVarietyName(varietyName)
        }
        if (match.isEmpty()) return 0.0
        val share = if (totalPct > 0) match.sumOf { it.displayPercent ?: 0.0 } / totalPct
        else match.size.toDouble() / allocations.size
        return paddock.areaHectares * share
    }

    /** Estimate for a Block + Variety in a vintage, preferring archived records. */
    private fun estimateFor(
        vintage: Int,
        paddockId: String,
        varietyName: String,
        paddock: Paddock?,
        yieldRecords: List<HistoricalYieldRecord>,
    ): Double? {
        val blocks = yieldRecords.filter { it.year == vintage }
            .flatMap { it.blocks }
            .filter { it.paddockId.equals(paddockId, ignoreCase = true) && it.yieldTonnes > 0 }
        if (blocks.isEmpty()) return null
        val estimate = blocks.sumOf { it.yieldTonnes }
        // Split a whole-block estimate by the variety's allocation share.
        val allocations = paddock?.varietyAllocations.orEmpty()
            .filter { !it.displayName.isNullOrBlank() }
        if (allocations.size <= 1) return estimate
        val totalPct = allocations.sumOf { it.displayPercent ?: 0.0 }
        val match = allocations.filter {
            canonicalVarietyName(it.displayName!!) == canonicalVarietyName(varietyName)
        }
        if (match.isEmpty()) return null
        val share = if (totalPct > 0) match.sumOf { it.displayPercent ?: 0.0 } / totalPct
        else match.size.toDouble() / allocations.size
        return estimate * share
    }
}

/**
 * Bunch Count Trip session helpers — starting trips, resuming drafts and
 * reusing an earlier trip's route so repeated counts through the season
 * revisit comparable sample locations. Mirrored on iOS
 * (`BunchCountTripLogic.swift`).
 */
object BunchCountTripLogic {

    /** Route material recovered from earlier trips for the selected blocks. */
    data class ReusableRoute(
        /** Sites with counts stripped, ORIGINAL site ids preserved, reindexed. */
        val sites: List<SampleSite>,
        val sourceSessionId: String,
    )

    /** The resumable in-progress trip for a vineyard, newest first. */
    fun activeDraft(
        sessions: List<YieldEstimationSession>,
        vineyardId: String?,
    ): YieldEstimationSession? = sessions
        .filter { it.vineyardId.equals(vineyardId ?: "", ignoreCase = true) && !it.isCompleted }
        .maxByOrNull { it.createdAt }

    /** Completed trips for a vineyard, newest first. Preserved forever. */
    fun completedTrips(
        sessions: List<YieldEstimationSession>,
        vineyardId: String?,
    ): List<YieldEstimationSession> = sessions
        .filter { it.vineyardId.equals(vineyardId ?: "", ignoreCase = true) && it.isCompleted }
        .sortedByDescending { it.completedAt ?: it.createdAt }

    /** A brand-new trip session — every trip is its own dated observation. */
    fun startTrip(vineyardId: String, samplesPerHectare: Int): YieldEstimationSession =
        YieldEstimationSession(
            id = UUID.randomUUID().toString(),
            vineyardId = vineyardId,
            createdAt = Instant.now().toString(),
            samplesPerHectare = samplesPerHectare.coerceIn(1, 100),
        )

    /**
     * Recover a reusable route for [selectedPaddockIds] from earlier sessions:
     * for each selected block, the newest session (completed preferred) that
     * generated sites for it contributes those sites with bunch counts
     * STRIPPED but site identity (id, row, coordinates) preserved. Returns
     * null when no selected block has any prior route — callers then proceed
     * straight to route generation without a meaningless prompt.
     */
    fun reusableRoute(
        sessions: List<YieldEstimationSession>,
        selectedPaddockIds: Collection<String>,
        excludeSessionId: String? = null,
    ): ReusableRoute? {
        if (selectedPaddockIds.isEmpty()) return null
        val candidates = sessions
            .filter { it.id != excludeSessionId && it.hasSites }
            .sortedWith(
                compareByDescending<YieldEstimationSession> { it.isCompleted }
                    .thenByDescending { it.completedAt ?: it.createdAt },
            )
        val collected = mutableListOf<SampleSite>()
        var sourceId: String? = null
        for (paddockId in selectedPaddockIds) {
            val source = candidates.firstOrNull { it.sitesIn(paddockId).isNotEmpty() } ?: continue
            if (sourceId == null) sourceId = source.id
            collected.addAll(
                source.sitesIn(paddockId).sortedBy { it.siteIndex }.map {
                    it.copy(bunchCountEntry = null)
                },
            )
        }
        if (collected.isEmpty() || sourceId == null) return null
        val reindexed = collected.mapIndexed { idx, site -> site.copy(siteIndex = idx + 1) }
        return ReusableRoute(sites = reindexed, sourceSessionId = sourceId)
    }
}
