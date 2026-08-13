package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Per-day, per-worker-TYPE labour line belonging to a pruning ACTIVITY — backs
 * `public.pruning_activity_labour_lines` (sql/190), which mirrors
 * `work_task_labour_lines` (sql/050) column for column.
 *
 * Ownership rule this type carries (SQL 190 §2):
 *
 *  * Labour is **PRUNING-OWNED**. A linked Work Task never receives a copy — it
 *    resolves *through* to these rows, so both objects report the SAME number
 *    from the SAME record and summing the two modules counts the job once.
 *  * Labour belongs to the ACTIVITY and is counted ONCE no matter how many
 *    blocks that activity covers. These lines are never apportioned to
 *    allocations.
 *
 * [id] is CLIENT-generated: it is the offline idempotency key, so replaying a
 * queued create can never duplicate a line.
 */
@Serializable
data class PruningActivityLabourLine(
    val id: String,
    @SerialName("pruning_activity_id") val pruningActivityId: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("work_date") val workDate: String? = null,
    /** Optional link to the shared worker-type catalogue (`worker_type_id`). */
    @SerialName("worker_type_id") val operatorCategoryId: String? = null,
    /** A worker CATEGORY ("Contractor"), never a person — same rule as SQL 050. */
    @SerialName("worker_type") val workerType: String = "",
    @SerialName("worker_count") val workerCount: Int = 1,
    @SerialName("hours_per_worker") val hoursPerWorker: Double = 0.0,
    /** null means "no rate entered", which is NOT the same as a rate of zero. */
    @SerialName("hourly_rate") val hourlyRate: Double? = null,
    @SerialName("total_hours") val totalHours: Double? = null,
    @SerialName("total_cost") val totalCost: Double? = null,
    val notes: String = "",
    /** Stable display order within the activity. Never used for costing. */
    @SerialName("line_index") val lineIndex: Int = 0,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    /**
     * `worker_count × hours_per_worker`, preferring the DB-generated value.
     */
    val resolvedHours: Double
        get() {
            val stored = totalHours
            if (stored != null && stored.isFinite() && stored >= 0) return stored
            return workerCount.coerceAtLeast(0).toDouble() * hoursPerWorker.coerceAtLeast(0.0)
        }

    /** True when this line carries a rate and therefore contributes to cost. */
    val isRated: Boolean get() = hourlyRate?.isFinite() == true
}
