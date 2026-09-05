package com.rork.vinetrack.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.R
import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.spray.SprayCanopyReferenceImages
import com.rork.vinetrack.data.spray.SprayCanopySelection
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale

/** Shared iOS-parity canopy control used by both foliar carrier bases. */
@Composable
fun SprayCanopySelector(
    selection: SprayCanopySelection,
    rates: CanopyWaterRates,
    isConfirmed: Boolean,
    onSelectionChange: (SprayCanopySelection) -> Unit,
    onConfirm: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = modifier) {
        Text("Canopy Type", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 8.dp)) {
            val choices: List<SprayCalculator.CanopyType?> = listOf(null) + SprayCalculator.CanopyType.entries
            choices.forEachIndexed { index, type ->
                SegmentedButton(
                    selected = selection.type == type,
                    onClick = { onSelectionChange(selection.chooseType(type)) },
                    shape = SegmentedButtonDefaults.itemShape(index, choices.size),
                ) { Text(type?.label ?: "Select", fontSize = 13.sp) }
            }
        }
        if (selection.type == null) {
            Text(
                "Choose the training system for this block before the canopy can recommend a spray volume.",
                fontSize = 11.sp,
                color = VineColors.Warning,
                modifier = Modifier.padding(top = 6.dp),
            )
            return@VineyardCard
        }

        val type = selection.type
        Text(
            "Canopy Size",
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textSecondary,
            modifier = Modifier.padding(top = 14.dp),
        )
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 8.dp)) {
            SprayCalculator.CanopySize.entries.forEachIndexed { index, size ->
                SegmentedButton(
                    selected = selection.size == size,
                    onClick = { onSelectionChange(selection.chooseSize(size)) },
                    shape = SegmentedButtonDefaults.itemShape(index, SprayCalculator.CanopySize.entries.size),
                ) { Text(size.label, fontSize = 13.sp) }
            }
        }
        Text(selection.size.description(type), fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.padding(top = 4.dp))

        Box(
            modifier = Modifier.fillMaxWidth().height(140.dp).padding(top = 8.dp)
                .clip(RoundedCornerShape(8.dp)).background(Color.White).padding(8.dp),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                painter = painterResource(canopyDrawable(type, selection.size)),
                contentDescription = SprayCanopyReferenceImages.accessibilityDescription(type, selection.size),
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxWidth().height(124.dp),
                alpha = if (isConfirmed) 1f else 0.55f,
            )
        }

        Text(
            "Canopy Density",
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textSecondary,
            modifier = Modifier.padding(top = 14.dp),
        )
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 8.dp)) {
            SprayCalculator.CanopyDensity.entries.forEachIndexed { index, density ->
                SegmentedButton(
                    selected = selection.density == density,
                    onClick = { onSelectionChange(selection.chooseDensity(density)) },
                    shape = SegmentedButtonDefaults.itemShape(index, SprayCalculator.CanopyDensity.entries.size),
                ) { Text(density.label, fontSize = 13.sp) }
            }
        }
        Text(selection.density.description, fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.padding(top = 4.dp))

        val band = selection.referenceBand(rates)
        val selectedValue = selection.litresPer100m(rates)
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 14.dp)
                .clip(RoundedCornerShape(10.dp)).background(VineColors.LeafGreen.copy(alpha = 0.10f)).padding(12.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text("Reference band", fontSize = 12.sp, color = vine.textSecondary)
                Text(
                    "${formatRate(band?.low)}–${formatRate(band?.high)} L/100m",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("${selection.density.label} density", fontSize = 12.sp, color = vine.textSecondary)
                Text(
                    "${formatRate(selectedValue)} L/100m",
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    color = VineColors.DarkGreen,
                )
            }
        }

        Button(
            onClick = onConfirm,
            modifier = Modifier.fillMaxWidth().height(48.dp).padding(top = 4.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (isConfirmed) VineColors.LeafGreen.copy(alpha = 0.16f) else VineColors.Orange.copy(alpha = 0.16f),
                contentColor = if (isConfirmed) VineColors.DarkGreen else VineColors.Orange,
            ),
        ) {
            Text(
                if (isConfirmed) "Canopy confirmed" else "Confirm canopy",
                textAlign = TextAlign.Center,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

private fun formatRate(value: Double?): String = value?.let {
    if (it % 1.0 == 0.0) String.format(Locale.US, "%.0f", it) else String.format(Locale.US, "%.1f", it)
} ?: "—"

private fun canopyDrawable(type: SprayCalculator.CanopyType, size: SprayCalculator.CanopySize): Int =
    when (type to size) {
        SprayCalculator.CanopyType.VSP to SprayCalculator.CanopySize.SMALL -> R.drawable.canopy_vsp_small
        SprayCalculator.CanopyType.VSP to SprayCalculator.CanopySize.MEDIUM -> R.drawable.canopy_vsp_medium
        SprayCalculator.CanopyType.VSP to SprayCalculator.CanopySize.LARGE -> R.drawable.canopy_vsp_large
        SprayCalculator.CanopyType.VSP to SprayCalculator.CanopySize.FULL -> R.drawable.canopy_vsp_full
        SprayCalculator.CanopyType.SPRAWL to SprayCalculator.CanopySize.SMALL -> R.drawable.canopy_sprawl_small
        SprayCalculator.CanopyType.SPRAWL to SprayCalculator.CanopySize.MEDIUM -> R.drawable.canopy_sprawl_medium
        SprayCalculator.CanopyType.SPRAWL to SprayCalculator.CanopySize.LARGE -> R.drawable.canopy_sprawl_large
        SprayCalculator.CanopyType.SPRAWL to SprayCalculator.CanopySize.FULL -> R.drawable.canopy_sprawl_full
        else -> error("Unsupported canopy image")
    }
