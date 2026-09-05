package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Exact shared JSON contract for one confirmed product quantity. */
@Serializable
data class SprayTankActualChemical(
    val id: String,
    val plannedChemicalId: String? = null,
    val savedChemicalId: String? = null,
    val name: String,
    val actualAmountBase: Double,
    val unit: String,
) {
    init {
        require(id.isNotBlank() && actualAmountBase.isFinite() && actualAmountBase >= 0.0)
        require(unit in setOf("Litres", "mL", "Kg", "g"))
    }
}

@Serializable
data class SprayTankActual(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("spray_record_id") val sprayRecordId: String,
    @SerialName("trip_id") val tripId: String,
    @SerialName("tank_session_id") val tankSessionId: String,
    @SerialName("tank_number") val tankNumber: Int,
    @SerialName("water_volume_l") val waterVolumeL: Double,
    val chemicals: List<SprayTankActualChemical>,
    @SerialName("confirmed_at") val confirmedAt: String,
    @SerialName("confirmed_by") val confirmedBy: String,
    @SerialName("client_updated_at") val clientUpdatedAt: String = confirmedAt,
) {
    init {
        require(tankSessionId.isNotBlank() && tankNumber >= 1)
        require(waterVolumeL.isFinite() && waterVolumeL >= 0.0)
    }
}
