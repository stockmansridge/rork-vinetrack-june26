package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.chemical.ChemicalSnapshotCapture
import com.rork.vinetrack.data.chemical.SprayConfirmedRateSeeding
import com.rork.vinetrack.data.chemical.SpraySelectableRate
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayProductRateBasis

/** Save-time input assembly shared by the calculator and recovery regressions. No dose calculation lives here. */
object SprayCalculatorInputBuilder {
    data class Product(
        val chemicalId: String,
        val basis: SprayProductRateBasis,
        val appliedRate: Double,
        val unit: String,
        val isOverride: Boolean,
        val selectedRate: SpraySelectableRate?,
        val isOperationalPreference: Boolean,
    )

    /** Capture one clock for the application and its chemical evidence, then use the existing tank builder. */
    fun build(
        metadata: SprayRecordRepository.SprayInput,
        capturedAt: String,
        products: List<Product>,
        library: List<SavedChemical>,
        buildTanks: (Map<String, ChemicalLineSnapshot>) -> List<SprayTank>,
    ): SprayRecordRepository.SprayInput {
        val snapshots = products.mapNotNull { line ->
            val chemical = library.firstOrNull { it.id == line.chemicalId }
            val captured = ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId = line.chemicalId, productName = null, library = library, capturedAt = capturedAt,
            ).snapshot
            val snapshot = if (chemical == null) captured else SprayConfirmedRateSeeding.snapshotWithProvenance(
                base = captured, chemical = chemical, basis = line.basis, appliedRate = line.appliedRate,
                unit = line.unit, isOverride = line.isOverride, capturedAt = capturedAt,
                selectedRate = line.selectedRate, isOperationalPreference = line.isOperationalPreference,
            )
            snapshot?.let { line.chemicalId to it }
        }.toMap()
        return metadata.copy(date = capturedAt, startTime = capturedAt, tanks = buildTanks(snapshots))
    }
}
