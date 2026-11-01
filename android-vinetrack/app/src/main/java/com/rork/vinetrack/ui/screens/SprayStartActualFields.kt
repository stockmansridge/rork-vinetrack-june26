package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.spray.SprayStartActualAmounts
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.components.SprayGuidedFormat
import com.rork.vinetrack.ui.components.SprayInfoHelp

/** Actual entry is available before route setup. Suggested amounts are never field defaults. */
@Composable
internal fun SprayStartActualFields(
    tanks: List<SprayTank>,
    draft: Map<String, String>,
    onDraftChange: (Map<String, String>) -> Unit,
    enabled: Boolean = true,
) {
    val tank = SprayStartActualAmounts.firstTank(tanks) ?: return
    val region = LocalRegionFormatter.current
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Tank ${tank.tankNumber} — Actual amounts added", fontWeight = FontWeight.Bold)
        SprayInfoHelp("Actual amounts", "Enter the water and each chemical you actually put in this tank. Calculated amounts are a guide. Your entries are saved separately with the spray record when you start. Record later tanks when you mix them.")
        Text("Calculated water: ${region.formatVolume(tank.waterVolume)}")
        OutlinedTextField(
            value = draft["water"].orEmpty(),
            onValueChange = { onDraftChange(draft + ("water" to it)) },
            label = { Text("Actual water (${region.volumeUnitAbbreviation})") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 60.dp),
        )
        tank.chemicals.forEachIndexed { index, chemical ->
            HorizontalDivider()
            Text(chemical.name, fontWeight = FontWeight.SemiBold)
            val planned = if (chemical.quantityBasis == "display") chemical.volumePerTank
                else chemicalUnitFromBase(chemical.unit, chemical.volumePerTank)
            Text("Calculated: ${SprayGuidedFormat.quantity(planned, chemical.unit)}")
            OutlinedTextField(
                value = draft["chemical:$index"].orEmpty(),
                onValueChange = { onDraftChange(draft + ("chemical:$index" to it)) },
                label = { Text("Actual ${chemical.name} (${chemical.unit})") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 60.dp),
            )
            if (SprayStartActualAmounts.number(draft["chemical:$index"].orEmpty()) == 0.0)
                Text("This product will be recorded as not added.")
        }
        if (tanks.size > 1) Text("Enter actual amounts for later tanks when you mix them.")
    }
}
