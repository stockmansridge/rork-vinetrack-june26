package com.rork.vinetrack.data.model

import java.time.LocalDate
import kotlin.math.round

/**
 * SHARED CONTRACT — the ALLOCATED labour model for pruning activities.
 *
 * Anything changed here must be mirrored in `PruningActivityAllocationModel.swift`.
 *
 * ## Why this exists
 *
 * A pruning activity is ONE piece of work covering MANY blocks. The
 * authoritative activity values — worker, method, Work Task, start, finish,
 * person-hours, cost — belong to the PARENT ACTIVITY. `pruning_entries` is the
 * allocation table and stores a legacy MIRROR of some of those values on the
 * `allocation_index = 0` row.
 *
 * That mirror must never be treated as the source of truth for a report:
 *
 *  * Filtering to a block that the activity touched as its SECOND allocation
 *    would blank the labour, the worker and the Work Task, even though the
 *    activity plainly has them.
 *  * Summing a per-allocation copy of the parent's person-hours counts the same
 *    labour once per block.
 *
 * So this model resolves each parent ONCE from ALL of its canonical
 * allocations, then divides the parent's labour proportionally across them.
 *
 * ## Allocation maths
 *
 *     share            = allocation row equivalents / FULL activity row equivalents
 *     allocated hours  = parent person-hours × share
 *     allocated cost   = parent labour cost   × share
 *
 * The denominator is always the FULL canonical activity, never the filtered
 * subset. Filtering a two-block activity to one block must not hand 100% of the
 * cost to the surviving block.
 *
 * ## Rounding
 *
 * Allocated values are produced by CUMULATIVE rounding: each allocation's value
 * is the difference between successive rounded running totals. The final
 * running total is the rounded parent total, so summing every allocation
 * reconciles to the parent EXACTLY — the rounding remainder lands on the last
 * canonical allocation, deterministically, on both platforms.
 *
 * ## Labour authority
 *
 * Unchanged from [WorkTaskLabourCosting]: summed Work Task labour lines win
 * outright and the legacy activity value is the fallback used only when the
 * task has no lines. This model divides whichever value won; it never combines
 * the two and never re-derives labour from elapsed duration.
 */

/**
 * The authoritative values of ONE pruning activity, resolved from all of its
 * allocations rather than from the legacy primary-allocation mirror.
 */
data class PruningActivityParent(
    val activityId: String,
    /** Work Task title when linked, else a method-derived name. Never a UUID. */
    val label: String,
    val date: LocalDate?,
    val dateIso: String,
    val method: String,
    val worker: String?,
    val workTaskId: String?,
    val workTaskTitle: String?,
    val workTaskStatus: String?,
    val startTime: String?,
    val finishTime: String?,
    /** The activity's own recorded operational hours — NOT person-hours. */
    val operationalHours: Double?,
    /** Elapsed start→finish duration. Never multiplied by the crew size. */
    val durationHours: Double?,
    /** RESOLVED authoritative person-hours for the WHOLE activity. */
    val personHours: Double?,
    /** Whole-activity labour cost; null when not recorded or not permitted. */
    val labourCost: Double?,
    val notes: String?,
    val isReversed: Boolean,
    /** How many allocations the activity has in total, before any filtering. */
    val allocationCount: Int,
    /** The FULL activity's row equivalents — the allocation-share denominator. */
    val rowEquivalents: Double,
)

/** One allocation's proportional slice of its parent activity. */
data class PruningActivityAllocationShare(
    val allocationId: String,
    val activityId: String,
    /** 1-based position within the FULL canonical activity. */
    val allocationNumber: Int,
    val fullAllocationCount: Int,
    /** 0..1 fraction of the full activity's row equivalents. */
    val share: Double,
    /** parent person-hours × share, or null when the parent has none. */
    val personHours: Double?,
    /** parent labour cost × share, or null when absent / not permitted. */
    val labourCost: Double?,
)

/**
 * Parents and allocation shares for a set of CANONICAL (unfiltered) report
 * rows. Build this from the full row set, then look up the filtered rows
 * against it so every figure keeps its whole-activity context.
 */
class PruningActivityAllocationModel private constructor(
    private val parentsById: Map<String, PruningActivityParent>,
    private val sharesById: Map<String, PruningActivityAllocationShare>,
) {
    fun parent(activityId: String): PruningActivityParent? = parentsById[activityId]

    fun parentOf(row: PruningActivityRow): PruningActivityParent? = parentsById[row.activityKey]

    fun share(allocationId: String): PruningActivityAllocationShare? = sharesById[allocationId]

    fun shareOf(row: PruningActivityRow): PruningActivityAllocationShare? = sharesById[row.id]

    companion object {
        /** Money and hours are both reported to two decimals. */
        const val DECIMALS: Int = 2

        /**
         * @param canonicalRows every allocation of every activity in scope,
         *   BEFORE the report's filters are applied.
         * @param includeCost false for roles without costing visibility; cost is
         *   then absent from the model itself, not merely hidden when rendered.
         */
        fun build(
            canonicalRows: List<PruningActivityRow>,
            includeCost: Boolean,
        ): PruningActivityAllocationModel {
            val buckets = LinkedHashMap<String, MutableList<PruningActivityRow>>()
            for (row in canonicalRows) {
                buckets.getOrPut(row.activityKey) { mutableListOf() }.add(row)
            }

            val parents = LinkedHashMap<String, PruningActivityParent>()
            val shares = LinkedHashMap<String, PruningActivityAllocationShare>()

            for ((activityId, rows) in buckets) {
                val ordered = canonicalOrder(rows)
                val parent = resolveParent(activityId, ordered, includeCost)
                parents[activityId] = parent

                // Row equivalents are the natural measure of how much of the
                // activity each block represents. When none were recorded the
                // allocations split the labour evenly rather than losing it.
                val recorded = ordered.map { it.rowEquivalents.takeIf { value -> value.isFinite() && value > 0 } ?: 0.0 }
                val weights = if (recorded.sum() > 0) recorded else List(ordered.size) { 1.0 }
                val denominator = weights.sum()

                val hours = allocatedSeries(parent.personHours, weights, denominator)
                val costs = allocatedSeries(parent.labourCost, weights, denominator)

                ordered.forEachIndexed { index, row ->
                    shares[row.id] = PruningActivityAllocationShare(
                        allocationId = row.id,
                        activityId = activityId,
                        allocationNumber = index + 1,
                        fullAllocationCount = ordered.size,
                        share = if (denominator > 0) weights[index] / denominator else 0.0,
                        personHours = hours[index],
                        labourCost = costs[index],
                    )
                }
            }

            return PruningActivityAllocationModel(parents, shares)
        }

        /**
         * The stable allocation order: the server's `allocation_index` first, so
         * the legacy primary leads, then block name, then id. Every derived
         * number — allocation number, share, rounding remainder — depends on
         * this order, so it must be identical on both platforms.
         */
        fun canonicalOrder(rows: List<PruningActivityRow>): List<PruningActivityRow> =
            rows.sortedWith(
                compareBy<PruningActivityRow> { it.allocationIndex }
                    .thenBy { it.blockName.lowercase() }
                    .thenBy { it.id },
            )

        /**
         * Resolves the parent from ALL allocations: the first allocation that
         * actually recorded a value wins.
         *
         * This is the correction to the legacy rule. The primary allocation is
         * only a mirror, so a report must not go blank just because the primary
         * was filtered out — the value belongs to the activity, and any
         * allocation that carries it can supply it.
         */
        private fun resolveParent(
            activityId: String,
            ordered: List<PruningActivityRow>,
            includeCost: Boolean,
        ): PruningActivityParent {
            val head = ordered.first()
            val workTaskTitle = ordered.firstNotNullOfOrNull { row ->
                row.workTaskTitle?.trim()?.takeIf { it.isNotEmpty() }
            }
            val method = ordered.firstNotNullOfOrNull { row ->
                row.method.trim().takeIf { it.isNotEmpty() }
            } ?: head.method

            return PruningActivityParent(
                activityId = activityId,
                label = label(workTaskTitle, method),
                date = head.date,
                dateIso = head.dateIso,
                method = method,
                worker = ordered.firstNotNullOfOrNull { row ->
                    row.worker?.trim()?.takeIf { it.isNotEmpty() }
                },
                workTaskId = ordered.firstNotNullOfOrNull { it.workTaskId },
                workTaskTitle = workTaskTitle,
                workTaskStatus = ordered.firstNotNullOfOrNull { row ->
                    row.workTaskStatus?.trim()?.takeIf { it.isNotEmpty() }
                },
                startTime = ordered.firstNotNullOfOrNull { it.startTime },
                finishTime = ordered.firstNotNullOfOrNull { it.finishTime },
                operationalHours = ordered.firstNotNullOfOrNull { it.operationalHours },
                durationHours = ordered.firstNotNullOfOrNull { it.durationHours },
                // Every allocation row carries the SAME task-derived person-hours,
                // so the parent total is one of them — never their sum.
                personHours = ordered.firstNotNullOfOrNull { it.labourHours },
                labourCost = if (includeCost) ordered.firstNotNullOfOrNull { it.labourCost } else null,
                notes = ordered.firstNotNullOfOrNull { row ->
                    row.notes?.trim()?.takeIf { it.isNotEmpty() }
                },
                isReversed = ordered.all { it.isReversed },
                allocationCount = ordered.size,
                rowEquivalents = ordered.sumOf { row ->
                    row.rowEquivalents.takeIf { it.isFinite() && it > 0 } ?: 0.0
                },
            )
        }

        /**
         * Activity name. There is no free-text activity title in the schema, so
         * the linked Work Task's title is used when there is one and a
         * method-derived label otherwise — never "Activity 3f2a…".
         */
        fun label(workTaskTitle: String?, method: String): String {
            val title = workTaskTitle?.trim()?.takeIf { it.isNotEmpty() }
            if (title != null) return title
            val cleaned = method.trim().takeIf { it.isNotEmpty() } ?: return "Pruning"
            return if (cleaned.contains("prun", ignoreCase = true)) cleaned else "$cleaned pruning"
        }

        /**
         * Splits [total] across [weights] with CUMULATIVE rounding, so the parts
         * always add back up to the rounded total. The remainder falls on the
         * last weight — the same one on iOS and Android.
         */
        private fun allocatedSeries(
            total: Double?,
            weights: List<Double>,
            denominator: Double,
        ): List<Double?> {
            if (total == null || !total.isFinite() || denominator <= 0) {
                return List(weights.size) { null }
            }
            var running = 0.0
            var previous = 0.0
            return weights.map { weight ->
                running += weight
                val cumulative = roundTo(total * (running / denominator), DECIMALS)
                val value = roundTo(cumulative - previous, DECIMALS)
                previous = cumulative
                value
            }
        }

        /** Half-away-from-zero rounding, matching Swift's `rounded()`. */
        fun roundTo(value: Double, decimals: Int): Double {
            if (!value.isFinite()) return value
            var factor = 1.0
            repeat(decimals) { factor *= 10.0 }
            return round(value * factor) / factor
        }
    }
}
