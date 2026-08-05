package com.rork.vinetrack.data.model

import java.time.LocalDate
import java.util.Locale
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
 *
 * ## Parent authority and conflicts
 *
 * Resolution order for every parent field is:
 *
 *  1. the CANONICAL `pruning_activities` parent, when one was supplied;
 *  2. otherwise the first allocation, in canonical order, that recorded a value.
 *
 * Step 2 exists for legacy projected rows, where only the mirror carries the
 * value. It is a fallback, never a merge: if two allocations of one activity
 * disagree on the worker, the Work Task, the labour or the timing, that is
 * corrupt data — an incompletely reconciled sync or a stale mirror — and one of
 * the two values is wrong. The model still has to return something, but it
 * records a [PruningActivityParentConflict] so the disagreement is visible in
 * diagnostics instead of being silently resolved by sort order.
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
    /**
     * True when a canonical `pruning_activities` parent supplied these values.
     * False means they were reconstructed from the allocation mirror.
     */
    val resolvedFromCanonicalParent: Boolean = false,
    /**
     * True when the allocations (or the canonical parent and its mirror)
     * disagreed on at least one parent field. The chosen value is still
     * returned, but it must not be trusted without checking the portal.
     */
    val hasContextConflict: Boolean = false,
)

/**
 * A canonical `pruning_activities` parent record.
 *
 * When the caller can supply this — the activity row itself rather than its
 * allocation mirror — it OUTRANKS every allocation for the fields it fills.
 * Fields left null fall back to the allocations as before, so a partially
 * populated canonical parent is still useful.
 */
data class PruningActivityParentSource(
    val activityId: String,
    val worker: String? = null,
    val method: String? = null,
    val workTaskId: String? = null,
    val workTaskTitle: String? = null,
    val workTaskStatus: String? = null,
    val startTime: String? = null,
    val finishTime: String? = null,
    val operationalHours: Double? = null,
    val durationHours: Double? = null,
    val personHours: Double? = null,
    val labourCost: Double? = null,
    val notes: String? = null,
)

/** The parent fields whose disagreement is worth reporting. */
enum class PruningActivityParentField(val label: String) {
    WORKER("Worker"),
    METHOD("Method"),
    WORK_TASK("Work Task"),
    WORK_TASK_TITLE("Work Task title"),
    WORK_TASK_STATUS("Work Task status"),
    START_TIME("Start time"),
    FINISH_TIME("Finish time"),
    OPERATIONAL_HOURS("Operational hours"),
    DURATION_HOURS("Duration"),
    PERSON_HOURS("Person-hours"),
    LABOUR_COST("Labour cost"),
}

/** Where the value that WON came from. */
enum class PruningActivityConflictResolution {
    /** The canonical `pruning_activities` parent decided it. */
    CANONICAL_PARENT,

    /**
     * No canonical parent was available, so the first allocation carrying a
     * value decided it. This is a guess and is reported as such.
     */
    FIRST_ALLOCATION,
}

/**
 * One parent field on which the sources disagreed.
 *
 * A conflict is DIAGNOSTIC. It never changes the exported figures — the report
 * still has to render something — but it says plainly that the underlying
 * records are inconsistent, which is the difference between a stale mirror
 * quietly winning and a data problem someone can go and fix.
 */
data class PruningActivityParentConflict(
    val activityId: String,
    val field: PruningActivityParentField,
    /** Every distinct value seen, canonical parent first when it had one. */
    val values: List<String>,
    val resolution: PruningActivityConflictResolution,
    /** The value the model actually used. */
    val resolvedValue: String?,
) {
    /** Log-ready one-liner. */
    val description: String
        get() {
            // `field` alone would mean this property's backing field, so the
            // conflicting field is referenced explicitly.
            val fieldLabel = this.field.label
            val source = when (resolution) {
                PruningActivityConflictResolution.CANONICAL_PARENT -> " (canonical activity record)"
                PruningActivityConflictResolution.FIRST_ALLOCATION -> " (first allocation — unverified)"
            }
            return "$fieldLabel conflict on activity $activityId: " +
                values.joinToString(" vs ") +
                " — using ${resolvedValue ?: "none"}$source"
        }
}

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
    /**
     * Every parent-context disagreement found while building the model, in
     * activity order. Surfaced in diagnostics — logs, the PDF's data-quality
     * notice — never used to alter a figure.
     */
    val conflicts: List<PruningActivityParentConflict>,
) {
    fun parent(activityId: String): PruningActivityParent? = parentsById[activityId]

    fun parentOf(row: PruningActivityRow): PruningActivityParent? = parentsById[row.activityKey]

    fun share(allocationId: String): PruningActivityAllocationShare? = sharesById[allocationId]

    fun shareOf(row: PruningActivityRow): PruningActivityAllocationShare? = sharesById[row.id]

    val hasConflicts: Boolean get() = conflicts.isNotEmpty()

    fun conflicts(activityId: String): List<PruningActivityParentConflict> =
        conflicts.filter { it.activityId == activityId }

    /** Activity ids with at least one conflicting parent field. */
    val conflictedActivityIds: Set<String>
        get() = conflicts.mapTo(LinkedHashSet()) { it.activityId }

    companion object {
        /** Money and hours are both reported to two decimals. */
        const val DECIMALS: Int = 2

        /**
         * @param canonicalRows every allocation of every activity in scope,
         *   BEFORE the report's filters are applied.
         * @param includeCost false for roles without costing visibility; cost is
         *   then absent from the model itself, not merely hidden when rendered.
         * @param canonicalParents the `pruning_activities` records keyed by
         *   activity id, when the caller has them. These OUTRANK the allocation
         *   mirror. Supplying them is what turns "first allocation wins" from a
         *   resolution rule into a fallback.
         */
        fun build(
            canonicalRows: List<PruningActivityRow>,
            includeCost: Boolean,
            canonicalParents: Map<String, PruningActivityParentSource> = emptyMap(),
        ): PruningActivityAllocationModel {
            val buckets = LinkedHashMap<String, MutableList<PruningActivityRow>>()
            for (row in canonicalRows) {
                buckets.getOrPut(row.activityKey) { mutableListOf() }.add(row)
            }

            val parents = LinkedHashMap<String, PruningActivityParent>()
            val shares = LinkedHashMap<String, PruningActivityAllocationShare>()
            val conflicts = mutableListOf<PruningActivityParentConflict>()

            for ((activityId, rows) in buckets) {
                val ordered = canonicalOrder(rows)
                val resolution = ParentResolution(activityId, ordered, canonicalParents[activityId])
                val parent = resolveParent(activityId, ordered, includeCost, resolution)
                parents[activityId] = parent
                conflicts.addAll(resolution.conflicts)

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

            return PruningActivityAllocationModel(parents, shares, conflicts)
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
         * Resolves the parent: the canonical `pruning_activities` record when
         * the caller supplied one, otherwise the first allocation, in canonical
         * order, that actually recorded a value.
         *
         * The allocation fallback is the correction to the legacy rule. The
         * primary allocation is only a mirror, so a report must not go blank
         * just because the primary was filtered out — the value belongs to the
         * activity, and any allocation that carries it can supply it.
         *
         * Where the sources DISAGREE, [resolution] records a conflict. The
         * export still renders the chosen value, because a blank cell would be a
         * worse answer than a flagged one, but nothing about the disagreement is
         * hidden.
         */
        private fun resolveParent(
            activityId: String,
            ordered: List<PruningActivityRow>,
            includeCost: Boolean,
            resolution: ParentResolution,
        ): PruningActivityParent {
            val head = ordered.first()
            val canonical = resolution.canonical
            val workTaskTitle = resolution.text(PruningActivityParentField.WORK_TASK_TITLE, canonical?.workTaskTitle) {
                it.workTaskTitle
            }
            val method = resolution.text(PruningActivityParentField.METHOD, canonical?.method) { it.method }
                ?: head.method

            return PruningActivityParent(
                activityId = activityId,
                label = label(workTaskTitle, method),
                date = head.date,
                dateIso = head.dateIso,
                method = method,
                worker = resolution.text(PruningActivityParentField.WORKER, canonical?.worker) { it.worker },
                workTaskId = resolution.text(PruningActivityParentField.WORK_TASK, canonical?.workTaskId) {
                    it.workTaskId
                },
                workTaskTitle = workTaskTitle,
                workTaskStatus = resolution.text(
                    PruningActivityParentField.WORK_TASK_STATUS,
                    canonical?.workTaskStatus,
                ) { it.workTaskStatus },
                startTime = resolution.text(PruningActivityParentField.START_TIME, canonical?.startTime) {
                    it.startTime
                },
                finishTime = resolution.text(PruningActivityParentField.FINISH_TIME, canonical?.finishTime) {
                    it.finishTime
                },
                operationalHours = resolution.number(
                    PruningActivityParentField.OPERATIONAL_HOURS,
                    canonical?.operationalHours,
                ) { it.operationalHours },
                durationHours = resolution.number(
                    PruningActivityParentField.DURATION_HOURS,
                    canonical?.durationHours,
                ) { it.durationHours },
                // Every allocation row carries the SAME task-derived person-hours,
                // so the parent total is one of them — never their sum.
                personHours = resolution.number(
                    PruningActivityParentField.PERSON_HOURS,
                    canonical?.personHours,
                ) { it.labourHours },
                labourCost = if (includeCost) {
                    resolution.number(PruningActivityParentField.LABOUR_COST, canonical?.labourCost) { it.labourCost }
                } else {
                    null
                },
                // Notes are free text and legitimately differ per allocation, so
                // they are resolved without conflict reporting.
                notes = canonical?.notes?.trim()?.takeIf { it.isNotEmpty() }
                    ?: ordered.firstNotNullOfOrNull { row ->
                        row.notes?.trim()?.takeIf { it.isNotEmpty() }
                    },
                isReversed = ordered.all { it.isReversed },
                allocationCount = ordered.size,
                rowEquivalents = ordered.sumOf { row ->
                    row.rowEquivalents.takeIf { it.isFinite() && it > 0 } ?: 0.0
                },
                resolvedFromCanonicalParent = canonical != null,
                hasContextConflict = resolution.conflicts.isNotEmpty(),
            )
        }

        /**
         * Picks one value per parent field and records every disagreement.
         *
         * Two allocations of the same activity should never carry different
         * non-null worker, Work Task, labour or timing values. When they do, the
         * data is wrong — a corrupted legacy mirror or a half-applied sync — and
         * choosing quietly by sort order would bury it.
         */
        private class ParentResolution(
            val activityId: String,
            val ordered: List<PruningActivityRow>,
            val canonical: PruningActivityParentSource?,
        ) {
            val conflicts = mutableListOf<PruningActivityParentConflict>()

            fun text(
                field: PruningActivityParentField,
                canonicalValue: String?,
                selector: (PruningActivityRow) -> String?,
            ): String? = resolve(
                field = field,
                canonicalValue = canonicalValue?.trim()?.takeIf { it.isNotEmpty() },
                selector = { row -> selector(row)?.trim()?.takeIf { it.isNotEmpty() } },
                format = { it },
            )

            fun number(
                field: PruningActivityParentField,
                canonicalValue: Double?,
                selector: (PruningActivityRow) -> Double?,
            ): Double? = resolve(
                field = field,
                canonicalValue = canonicalValue?.takeIf { it.isFinite() },
                selector = { row -> selector(row)?.takeIf { it.isFinite() } },
                // Compared at four decimals so float noise is not a "conflict".
                format = { String.format(Locale.US, "%.4f", it) },
            )

            private fun <T : Any> resolve(
                field: PruningActivityParentField,
                canonicalValue: T?,
                selector: (PruningActivityRow) -> T?,
                format: (T) -> String,
            ): T? {
                val recorded = ordered.mapNotNull(selector)
                val chosen = canonicalValue ?: recorded.firstOrNull()
                val distinct = LinkedHashSet<String>()
                canonicalValue?.let { distinct.add(format(it)) }
                recorded.forEach { distinct.add(format(it)) }
                if (distinct.size > 1) {
                    conflicts.add(
                        PruningActivityParentConflict(
                            activityId = activityId,
                            field = field,
                            values = distinct.toList(),
                            resolution = if (canonicalValue != null) {
                                PruningActivityConflictResolution.CANONICAL_PARENT
                            } else {
                                PruningActivityConflictResolution.FIRST_ALLOCATION
                            },
                            resolvedValue = chosen?.let(format),
                        ),
                    )
                }
                return chosen
            }
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
