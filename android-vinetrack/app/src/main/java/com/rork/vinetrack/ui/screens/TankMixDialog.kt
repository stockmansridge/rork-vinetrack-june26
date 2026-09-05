package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.TankRowApplication
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.NumberFormat
import java.util.Locale

internal data class TankControlInteractionState(
    val isEndConfirmationPresented: Boolean = false,
) {
    fun tapStart(action: () -> Unit) = action()

    fun tapEnd(): TankControlInteractionState = copy(isEndConfirmationPresented = true)

    fun cancelEnd(): TankControlInteractionState = copy(isEndConfirmationPresented = false)

    fun confirmEnd(action: () -> Unit): TankControlInteractionState {
        if (!isEndConfirmationPresented) return this
        action()
        return copy(isEndConfirmationPresented = false)
    }

    fun tapStatus(action: () -> Unit) = action()
}

internal enum class PlannedTankProgress(val label: String) {
    CURRENT("Current"),
    NEXT("Next"),
    COMPLETED("Completed"),
}

/** Read-only ordering and progress derived from a Spray Record's frozen tank plan. */
internal data class TankMixPresentation(
    val tanks: List<SprayTank>,
    val selectedTankNumber: Int?,
    val activeTankNumber: Int?,
    val nextTankNumber: Int?,
    val completedTankNumbers: Set<Int>,
) {
    val isAvailable: Boolean get() = tanks.isNotEmpty()
    val isPlanComplete: Boolean get() = isAvailable && nextTankNumber == null

    fun progress(tank: SprayTank): PlannedTankProgress? = when {
        tank.tankNumber == activeTankNumber -> PlannedTankProgress.CURRENT
        tank.tankNumber in completedTankNumbers -> PlannedTankProgress.COMPLETED
        activeTankNumber == null && tank.tankNumber == nextTankNumber -> PlannedTankProgress.NEXT
        else -> null
    }

    fun isPartial(tank: SprayTank): Boolean {
        val largestVolume = tanks.maxOfOrNull { it.waterVolume } ?: return false
        return tank.id == tanks.lastOrNull()?.id && largestVolume > 0 && tank.waterVolume < largestVolume
    }

    companion object {
        fun linkedRecord(tripId: String, records: List<SprayRecord>): SprayRecord? =
            records.firstOrNull { it.tripId == tripId }

        fun from(record: SprayRecord?, trip: Trip): TankMixPresentation {
            val sortedTanks = record?.tanks.orEmpty().sortedWith(compareBy<SprayTank> { it.tankNumber }.thenBy { it.id })
            val plannedNumbers = sortedTanks.mapTo(mutableSetOf()) { it.tankNumber }
            val validSessions = trip.tankSessions.filter { it.tankNumber > 0 && it.tankNumber in plannedNumbers }
            val completed = validSessions.filterNot { it.isOpen }.mapTo(mutableSetOf()) { it.tankNumber }
            val active = validSessions
                .filter { it.isOpen }
                .maxWithOrNull(compareBy<com.rork.vinetrack.data.model.TankSession> { it.startEpochMs ?: Long.MIN_VALUE }.thenBy { it.id })
                ?.tankNumber
            val next = sortedTanks.firstOrNull { it.tankNumber !in completed }?.tankNumber
            return TankMixPresentation(
                tanks = sortedTanks,
                selectedTankNumber = active ?: next ?: sortedTanks.lastOrNull()?.tankNumber,
                activeTankNumber = active,
                nextTankNumber = next,
                completedTankNumbers = completed,
            )
        }
    }
}

@Composable
internal fun TankMixDialog(
    record: SprayRecord?,
    trip: Trip,
    onDismiss: () -> Unit,
) {
    val presentation = remember(record, trip) { TankMixPresentation.from(record, trip) }
    var selectedTankNumber by remember(record?.id, trip.id) {
        mutableIntStateOf(presentation.selectedTankNumber ?: Int.MIN_VALUE)
    }
    val selectedTank = presentation.tanks.firstOrNull { it.tankNumber == selectedTankNumber }
        ?: presentation.tanks.firstOrNull()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Tank Mix") },
        text = {
            if (selectedTank == null) {
                Text("Tank mix details unavailable on this device.")
            } else {
                TankMixContent(
                    presentation = presentation,
                    selectedTank = selectedTank,
                    selectedTankNumber = selectedTankNumber,
                    onSelectTank = { selectedTankNumber = it },
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun TankMixContent(
    presentation: TankMixPresentation,
    selectedTank: SprayTank,
    selectedTankNumber: Int,
    onSelectTank: (Int) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 560.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            presentation.tanks.forEach { tank ->
                val selected = tank.tankNumber == selectedTankNumber
                if (selected) {
                    Button(
                        onClick = { onSelectTank(tank.tankNumber) },
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Cyan),
                    ) { Text("Tank ${tank.tankNumber}") }
                } else {
                    OutlinedButton(onClick = { onSelectTank(tank.tankNumber) }) {
                        Text("Tank ${tank.tankNumber}")
                    }
                }
            }
        }

        Text(
            "Tank ${selectedTank.tankNumber} of ${presentation.tanks.size}",
            fontSize = 21.sp,
            fontWeight = FontWeight.Bold,
            color = vine.textPrimary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            presentation.progress(selectedTank)?.let { progress ->
                TankStatusBadge(progress.label, progressColor(progress))
            }
            if (presentation.isPartial(selectedTank)) {
                TankStatusBadge("Partial tank", VineColors.Orange)
            }
        }
        Text(
            "Planned amounts",
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
            color = VineColors.LeafGreen,
        )

        Surface(
            color = vine.cardBackground,
            shape = RoundedCornerShape(14.dp),
            tonalElevation = 1.dp,
        ) {
            Column(modifier = Modifier.padding(horizontal = 14.dp)) {
                PlannedDetailRow("Planned water", "${tankMixNumber(selectedTank.waterVolume)} L")
                HorizontalDivider(color = vine.cardBorder)
                PlannedDetailRow("Planned area", "${tankMixNumber(selectedTank.areaPerTank)} ha")
                HorizontalDivider(color = vine.cardBorder)
                PlannedDetailRow("Spray rate", "${tankMixNumber(selectedTank.sprayRatePerHa)} L/ha")
                val factor = if (selectedTank.concentrationFactor > 0) selectedTank.concentrationFactor else 1.0
                if (kotlin.math.abs(factor - 1.0) > 0.000001) {
                    HorizontalDivider(color = vine.cardBorder)
                    PlannedDetailRow("Concentration", "${tankMixNumber(factor)}×")
                }
                if (selectedTank.rowApplications.isNotEmpty()) {
                    HorizontalDivider(color = vine.cardBorder)
                    PlannedDetailRow(
                        "Planned rows",
                        selectedTank.rowApplications.joinToString(", ") { plannedRowRange(it) },
                    )
                }
            }
        }

        Text("Planned chemicals", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        if (selectedTank.chemicals.isEmpty()) {
            Text("No planned chemicals stored for this tank.", color = vine.textSecondary, fontSize = 13.sp)
        } else {
            selectedTank.chemicals.forEach { chemical -> PlannedChemicalCard(chemical) }
        }
    }
}

@Composable
private fun PlannedDetailRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(label, color = vine.textSecondary, fontSize = 14.sp)
        Spacer(Modifier.width(12.dp).weight(1f))
        Text(value, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.End)
    }
}

@Composable
private fun PlannedChemicalCard(chemical: SprayChemical) {
    val vine = LocalVineColors.current
    val formatter = LocalRegionFormatter.current
    val displayAmount = chemicalUnitFromBase(chemical.unit, chemical.volumePerTank)
    val basis = chemical.resolvedRateBasis
    val rateBase = if (basis == SprayProductRateBasis.PER_100_LITRES) chemical.ratePer100L else chemical.ratePerHa
    val displayRate = chemicalUnitFromBase(chemical.unit, rateBase)
    val rateText = when {
        rateBase <= 0 -> null
        basis.isAreaBased -> formatter.formatSprayRate(displayRate, chemical.unit)
        else -> "${tankMixNumber(displayRate)} ${chemical.unit}${basis.rateSuffix}"
    }

    Surface(color = vine.cardBackground, shape = RoundedCornerShape(14.dp), tonalElevation = 1.dp) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Text(
                    chemical.name.ifBlank { "Unnamed chemical" },
                    modifier = Modifier.weight(1f),
                    color = vine.textPrimary,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "${tankMixNumber(displayAmount)} ${chemical.unit}",
                    color = vine.textPrimary,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.End,
                )
            }
            rateText?.let { Text("Application rate: $it", color = vine.textSecondary, fontSize = 12.sp) }
        }
    }
}

@Composable
private fun TankStatusBadge(label: String, color: Color) {
    Text(
        label,
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(50))
            .padding(horizontal = 9.dp, vertical = 5.dp),
        color = color,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
    )
}

private fun progressColor(progress: PlannedTankProgress): Color = when (progress) {
    PlannedTankProgress.CURRENT -> VineColors.Cyan
    PlannedTankProgress.NEXT -> VineColors.LeafGreen
    PlannedTankProgress.COMPLETED -> VineColors.DarkGreen
}

internal fun tankMixNumber(value: Double): String {
    val formatter = NumberFormat.getNumberInstance(Locale.getDefault())
    formatter.maximumFractionDigits = 3
    formatter.minimumFractionDigits = 0
    return formatter.format(value)
}

internal fun plannedRowRange(application: TankRowApplication): String {
    val start = tankMixNumber(application.startRow)
    val end = tankMixNumber(application.endRow)
    return if (application.startRow == application.endRow) "Row $start" else "Rows $start–$end"
}
