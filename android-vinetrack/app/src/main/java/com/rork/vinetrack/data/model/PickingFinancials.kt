package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * One row of the owner/manager-only `get_picking_record_financials` RPC
 * (sql/187). Since 187 the `picking_records` base columns `sold_to`,
 * `price_per_tonne` and `grape_value` are stripped server-side and read back
 * NULL for every role — commercial values live in the RLS-protected
 * `picking_record_financials` companion table and reach clients only through
 * this projection.
 */
@Serializable
data class PickingFinancialRow(
    @SerialName("picking_record_id") val pickingRecordId: String,
    @SerialName("sold_to") val soldTo: String? = null,
    @SerialName("price_per_tonne") val pricePerTonne: Double? = null,
    @SerialName("grape_value") val grapeValue: Double? = null,
)

/**
 * Merge financial projections back into picking records for display. Pure and
 * shared with tests; rows without a matching projection keep their (masked)
 * values so operators simply never see money. Mirrors the iOS
 * `PickingFinancialsMerge`.
 */
fun mergePickingFinancials(
    records: List<PickingRecord>,
    financials: List<PickingFinancialRow>,
): List<PickingRecord> {
    if (financials.isEmpty()) return records
    val byId = financials.associateBy { it.pickingRecordId.lowercase() }
    return records.map { record ->
        val row = byId[record.id.lowercase()] ?: return@map record
        record.copy(
            soldTo = row.soldTo,
            pricePerTonne = row.pricePerTonne,
            grapeValue = row.grapeValue,
        )
    }
}
