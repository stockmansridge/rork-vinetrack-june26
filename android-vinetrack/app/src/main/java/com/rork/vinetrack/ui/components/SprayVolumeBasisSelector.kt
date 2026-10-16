package com.rork.vinetrack.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayCarrierRegionalFormat

/** Reflows rather than compressing three rate labels and a checkmark into narrow segments. */
@Composable
fun SprayVolumeBasisSelector(
    bases: List<SprayCarrierBasis>,
    selected: SprayCarrierBasis,
    format: SprayCarrierRegionalFormat,
    onSelect: (SprayCarrierBasis) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val horizontal = maxWidth >= (bases.size * 132).dp && LocalDensity.current.fontScale <= 1.2f
            val option: @Composable (SprayCarrierBasis, Modifier) -> Unit = { basis, itemModifier ->
                val isSelected = selected == basis
                OutlinedButton(
                    onClick = { onSelect(basis) },
                    modifier = itemModifier.heightIn(min = 48.dp).semantics { this.selected = isSelected },
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = if (isSelected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface,
                        contentColor = if (isSelected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface,
                    ),
                    border = BorderStroke(1.dp, if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
                ) {
                    if (isSelected) {
                        Icon(Icons.Default.Check, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(if (basis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME) "Total water" else format.carrierBasisLabel(basis), Modifier.weight(1f))
                }
            }
            if (horizontal) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                bases.forEach { option(it, Modifier.weight(1f)) }
            } else Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                bases.forEach { option(it, Modifier.fillMaxWidth()) }
            }
        }
        if (SprayCarrierBasis.MANUAL_TOTAL_VOLUME in bases) Text(
            "Total water: manually enter the full spray volume for the selected area, rather than a rate per area or row length.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
