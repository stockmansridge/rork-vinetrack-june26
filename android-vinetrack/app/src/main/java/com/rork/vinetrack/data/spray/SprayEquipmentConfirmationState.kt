package com.rork.vinetrack.data.spray

/** Operator-controlled confirmation for the complete Equipment and path selection. */
data class SprayEquipmentConfirmationState(
    val confirmedSignature: String? = null,
) {
    fun isConfirmed(selection: SprayEquipmentSelection): Boolean =
        confirmedSignature == selection.signature && selection.sprayEquipmentId != null

    fun confirm(selection: SprayEquipmentSelection): SprayEquipmentConfirmationState =
        if (selection.sprayEquipmentId == null) this else copy(confirmedSignature = selection.signature)
}

/** Every input whose change invalidates Equipment confirmation. */
data class SprayEquipmentSelection(
    val selectedBlockIds: List<String>,
    val sprayEquipmentId: String?,
    val tractorId: String?,
    val fansJets: String,
    val trackingPattern: String,
    val startPath: Double?,
    val directionHigherFirst: Boolean?,
) {
    val signature: String
        get() = listOf(
            selectedBlockIds.joinToString(","),
            sprayEquipmentId.orEmpty(),
            tractorId.orEmpty(),
            fansJets.trim(),
            trackingPattern,
            startPath?.toString().orEmpty(),
            directionHigherFirst?.toString().orEmpty(),
        ).joinToString("|")
}
