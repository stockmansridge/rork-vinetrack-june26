package com.rork.vinetrack.data.ripeness

import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Heatmap-specific normalisation layer over `v_growth_stage_observations`.
 *
 * Mirrors the Swift `ELRipenessObservationAdapter` exactly. It exists so the
 * Ripeness Heatmap can merge three sources of the same growth-stage
 * observation — canonical remote rows, the offline cache, and records the
 * operator has just written but which have not yet round-tripped — into the
 * single ordered [ElRipenessHeatmap.RawRecord] list the contract core expects.
 *
 * It deliberately does **not** touch the Growth Stage Summary path. The Summary
 * report keeps reading `state.growthRecords` exactly as it always has; this is
 * a parallel read path with its own cache.
 *
 * Rules it enforces (contract v1.1.0):
 * * Dedupe by stable record ID — never by coordinate, date or block.
 * * A pending local edit outranks a remote row, which outranks a cached row.
 * * Assignment is revoke-only over `paddock_id`. Block identity is never
 *   inferred from GPS.
 * * The field-capture date is preserved by formatting local timestamps in the
 *   vineyard's own timezone, so the contract's day-key slice yields the day the
 *   observation was actually recorded.
 */
object ElRipenessObservationAdapter {

    /** Where a raw record came from. Drives dedupe precedence. */
    enum class Origin {
        /** Freshly fetched from `v_growth_stage_observations`. */
        REMOTE,

        /** Replayed from the on-disk offline cache. */
        CACHED,

        /** A local growth-stage record that has not yet reached the server. */
        PENDING_LOCAL,
    }

    /**
     * A raw record tagged with its origin and placement signal.
     *
     * [placementAssigned] is the resolved `pin_placements` signal, or `null`
     * when the source carries no placement row at all. `null` means "no
     * signal", which the contract treats as *not revoked* — it is not the same
     * as `false`.
     */
    data class SourceRecord(
        val record: ElRipenessHeatmap.RawRecord,
        val origin: Origin,
        val placementAssigned: Boolean? = null,
    )

    /** Higher wins a dedupe collision. */
    fun precedence(origin: Origin): Int = when (origin) {
        Origin.CACHED -> 0
        Origin.REMOTE -> 1
        Origin.PENDING_LOCAL -> 2
    }

    /**
     * Deduplicates by stable record ID, keeping the highest-precedence copy.
     *
     * First-seen order is preserved so the IDW zero-distance tie-break stays
     * deterministic: a later, higher-precedence duplicate replaces the earlier
     * entry **in place** rather than moving to the end of the list.
     */
    fun merge(sources: List<SourceRecord>): List<SourceRecord> {
        val order = ArrayList<String>(sources.size)
        val byId = LinkedHashMap<String, SourceRecord>(sources.size)

        for (source in sources) {
            val id = source.record.id
            val existing = byId[id]
            if (existing != null) {
                if (precedence(source.origin) > precedence(existing.origin)) {
                    byId[id] = source
                }
            } else {
                byId[id] = source
                order.add(id)
            }
        }
        return order.mapNotNull { byId[it] }
    }

    /** Full pipeline: merge, then run the contract normalisation. */
    fun observations(
        sources: List<SourceRecord>,
        selectedVineyardId: String?,
    ): List<ElRipenessHeatmap.Observation> {
        val merged = merge(sources)
        val assignedById = HashMap<String, Boolean>()
        for (source in merged) {
            source.placementAssigned?.let { assignedById[source.record.id] = it }
        }
        return ElRipenessHeatmap.toObservations(
            merged.map { it.record },
            assignedById = assignedById,
            selectedVineyardId = selectedVineyardId,
        )
    }

    // ---- Local records ----

    /**
     * ISO-8601 in a fixed timezone. The contract slices the first 10 characters
     * without any conversion, so the string must already carry the
     * vineyard-local calendar day.
     */
    fun isoString(epochMs: Long, timeZone: TimeZone): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)
        formatter.timeZone = timeZone
        return formatter.format(Date(epochMs))
    }

    /**
     * Converts a locally-held growth-stage record into a pending raw record.
     *
     * Returns `null` for anything that is not a usable growth-stage
     * observation. The coordinate uses the record's own saved location, which
     * is the column that syncs to `v_growth_stage_observations`.
     */
    fun pendingRecord(
        record: GrowthStageRecord,
        timeZone: TimeZone,
    ): SourceRecord? {
        if (record.stageCode.isBlank()) return null
        val observedIso = record.observedAt?.takeIf { it.isNotBlank() }
            ?: record.observedEpochMs?.let { isoString(it, timeZone) }
        return SourceRecord(
            record = ElRipenessHeatmap.RawRecord(
                id = record.id.lowercase(),
                vineyardId = record.vineyardId.lowercase(),
                paddockId = record.paddockId?.lowercase(),
                stageCode = record.stageCode,
                latitude = record.latitude,
                longitude = record.longitude,
                date = observedIso,
                completedAt = null,
                createdAt = record.createdAt,
                deletedAt = record.deletedAt,
            ),
            origin = Origin.PENDING_LOCAL,
            // A locally-written growth record carries an explicit block or
            // none; there is no separate placement row to consult yet, so the
            // signal is only ever a revocation when the block is absent.
            placementAssigned = null,
        )
    }

    /** All pending local growth-stage observations for a vineyard. */
    fun pendingRecords(
        records: List<GrowthStageRecord>,
        vineyardId: String?,
        timeZone: TimeZone,
    ): List<SourceRecord> = records
        .filter { vineyardId == null || it.vineyardId.equals(vineyardId, ignoreCase = true) }
        .mapNotNull { pendingRecord(it, timeZone) }

    // ---- Blocks ----

    /**
     * Block polygons for the heat surface. Blocks with fewer than three points
     * are still returned — the contract renders them in `no_polygon` mode
     * rather than hiding them, so the operator can see the block exists but has
     * no boundary.
     */
    fun blockInputs(paddocks: List<Paddock>): List<ElRipenessHeatmap.BlockInput> =
        paddocks.map { paddock ->
            ElRipenessHeatmap.BlockInput(
                id = paddock.id.lowercase(),
                name = paddock.name,
                polygon = (paddock.polygonPoints ?: emptyList()).map {
                    ElRipenessHeatmap.LatLng(it.latitude, it.longitude)
                },
            )
        }
}
