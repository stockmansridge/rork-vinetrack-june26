package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.rork.vinetrack.data.SeasonYieldProjection
import com.rork.vinetrack.data.model.SeasonYieldSourceInputs
import com.rork.vinetrack.data.model.SeasonYieldWarningCopy
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale

/**
 * Everything behind one block's number: where the estimate came from, when it
 * was calculated, the exact pruning inputs the server used, the damage
 * adjustment and every warning.
 *
 * Kept in its own file, and split into small sections, because the Kotlin
 * compile for this module runs in-process on a fixed 4 GB heap — one very large
 * composable is what tips `compileReleaseKotlin` into GC thrash.
 */
@Composable
fun SeasonYieldBlockInfoDialog(
    block: SeasonYieldProjection.BlockRow,
    damageApplied: Boolean,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(vine.cardBackground)
                .padding(20.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(block.name, color = vine.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold)

            EstimateSection(block)
            DamageSection(block, damageApplied)
            block.sourceInputs?.let { PruningInputsSection(it) }
            PlantingGroupsSection(block, damageApplied)
            WarningsSection(block)

            TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) { Text("Done") }
        }
    }
}

@Composable
private fun EstimateSection(block: SeasonYieldProjection.BlockRow) {
    SeasonInfoHeading("Estimate")
    SeasonInfoRow("Source", seasonYieldSourceLabel(block.estimateSource))
    SeasonInfoRow("Calculated", block.calculatedAt?.take(16)?.replace('T', ' ') ?: "Never")
    SeasonInfoRow("Block area", seasonHectaresText(block.areaHectares))
    SeasonInfoRow("Base estimate", seasonTonnesText(block.baseTonnes))
    if (block.baseTonnes == null) {
        SeasonInfoRow("Known so far", seasonTonnesText(block.knownBaseTonnes))
    }
    SeasonInfoRow(
        "Status",
        when {
            !block.hasEstimates -> "Not estimated yet"
            block.isEstimateComplete -> "Complete"
            else -> "Missing inputs"
        },
    )
}

@Composable
private fun DamageSection(block: SeasonYieldProjection.BlockRow, damageApplied: Boolean) {
    val vine = LocalVineColors.current
    val damage = block.damage
    SeasonInfoHeading("Damage adjustment")
    SeasonInfoRow("Applied to totals", if (damageApplied) "Yes" else "No (base figures shown)")
    SeasonInfoRow("Damage records used", damage.eligibleRecordCount.toString())
    if (damage.excludedRecordCount > 0) {
        SeasonInfoRow("Excluded (no valid area)", damage.excludedRecordCount.toString())
    }
    SeasonInfoRow("Damaged area", seasonHectaresText(damage.mappedAreaHectares))
    SeasonInfoRow("Effective loss area", seasonHectaresText(damage.effectiveLossHectares))
    SeasonInfoRow("Loss fraction", seasonPercentText(damage.damageLossFraction))
    SeasonInfoRow("Remaining yield", seasonPercentText(damage.remainingYieldMultiplier))
    if (damageApplied) {
        SeasonInfoRow("Adjusted estimate", seasonTonnesText(block.adjustedTonnes))
    }
    Text(
        "Loss = mapped area × intensity ÷ block area, capped at 100%.",
        color = vine.textSecondary,
        fontSize = 11.sp,
    )
}

@Composable
private fun PruningInputsSection(inputs: SeasonYieldSourceInputs) {
    val vine = LocalVineColors.current
    SeasonInfoHeading("Pruning inputs")
    SeasonInfoRow("Prune method", inputs.pruneMethod?.replaceFirstChar { it.uppercase() } ?: "—")
    if (inputs.pruneMethod == "cane") {
        SeasonInfoRow("Canes per vine", seasonNumberText(inputs.canesPerVine, 2))
        SeasonInfoRow("Buds per cane", seasonNumberText(inputs.budsPerCane, 2))
    } else {
        SeasonInfoRow("Spurs per vine", seasonNumberText(inputs.spursPerVine, 2))
        SeasonInfoRow("Buds per spur", seasonNumberText(inputs.budsPerSpur, 2))
    }
    SeasonInfoRow("Buds per vine", seasonNumberText(inputs.budsPerVine, 2))
    SeasonInfoRow("Bunches per bud", seasonNumberText(inputs.bunchesPerBud, 2))
    SeasonInfoRow(
        "Bunch weight",
        inputs.bunchWeightGrams?.let { String.format(Locale.getDefault(), "%.0f g", it) } ?: "—",
    )
    SeasonInfoRow("Vines per ha", seasonNumberText(inputs.vinesPerHa, 0))
    SeasonInfoRow("Vine count", seasonNumberText(inputs.vineCount, 0))
    SeasonInfoRow("Vine count basis", seasonVineCountBasisLabel(inputs.vineCountBasis))
    inputs.formula?.let { Text(it, color = vine.textSecondary, fontSize = 11.sp) }

    val groupCount = inputs.allocationGroupCount ?: 0
    if (groupCount > 0) {
        SeasonInfoHeading("Variety allocations")
        SeasonInfoRow("Planting groups", groupCount.toString())
        SeasonInfoRow(
            "Allocated",
            inputs.allocationPercentTotalOriginal
                ?.let { String.format(Locale.getDefault(), "%.1f%%", it) } ?: "—",
        )
        if (inputs.allocationPercentNormalized == true) {
            Text(
                "Allocations exceeded 100% and were scaled back proportionally, so the groups still sum to the block estimate.",
                color = vine.textSecondary,
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun PlantingGroupsSection(block: SeasonYieldProjection.BlockRow, damageApplied: Boolean) {
    if (block.groups.isEmpty()) return
    val vine = LocalVineColors.current
    SeasonInfoHeading("Planting groups")
    block.groups.forEach { group ->
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(group.displayName, color = vine.textPrimary, fontSize = 13.sp)
                Text(
                    String.format(Locale.getDefault(), "%.1f%% of block", group.allocationPercent),
                    color = vine.textSecondary,
                    fontSize = 11.sp,
                )
            }
            Text(
                seasonTonnesText(if (damageApplied) group.adjustedTonnes else group.baseTonnes),
                color = if (group.baseTonnes == null) vine.textSecondary else vine.textPrimary,
                fontSize = 13.sp,
            )
        }
    }
}

@Composable
private fun WarningsSection(block: SeasonYieldProjection.BlockRow) {
    val warnings = block.warnings.distinct().sorted()
    if (warnings.isEmpty()) return
    SeasonInfoHeading("Warnings")
    warnings.forEach { code ->
        Text(SeasonYieldWarningCopy.text(code), color = VineColors.Orange, fontSize = 12.sp)
    }
}

@Composable
private fun SeasonInfoHeading(title: String) {
    val vine = LocalVineColors.current
    Spacer(Modifier.height(6.dp))
    Text(
        title.uppercase(),
        color = vine.textSecondary,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
    )
}

@Composable
private fun SeasonInfoRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Text(value, color = vine.textPrimary, fontSize = 13.sp)
    }
}

// ---- Formatting ------------------------------------------------------------
//
// The single place the incomplete-estimate dash is produced. A withheld total
// must never render as `0 t`: zero is a measured answer, "—" is an honest one.

internal fun seasonTonnesText(value: Double?): String =
    if (value == null || !value.isFinite()) "—" else String.format(Locale.getDefault(), "%.2f t", value)

internal fun seasonHectaresText(value: Double?): String =
    if (value == null || !value.isFinite()) "—" else String.format(Locale.getDefault(), "%.2f ha", value)

internal fun seasonPercentText(fraction: Double?): String =
    if (fraction == null || !fraction.isFinite()) {
        "—"
    } else {
        String.format(Locale.getDefault(), "%.1f%%", fraction * 100)
    }

internal fun seasonNumberText(value: Double?, decimals: Int): String =
    if (value == null || !value.isFinite()) {
        "—"
    } else {
        String.format(Locale.getDefault(), "%.${decimals}f", value)
    }

/** Human label for `season_yield_estimates.estimate_source`. */
internal fun seasonYieldSourceLabel(source: String): String = when (source) {
    "manual" -> "Manual entry"
    "bunch_count" -> "Bunch Count Trip"
    "pruning", "pruning_calculator" -> "Pruning Yield Calculator"
    "none" -> "Not estimated"
    else -> source.replace('_', ' ').replaceFirstChar { it.uppercase() }
}

internal fun seasonVineCountBasisLabel(basis: String?): String = when (basis) {
    "block_vine_count_override" -> "Block vine count override"
    "block_area_x_vines_per_ha" -> "Block area × vines/ha"
    null, "" -> "—"
    else -> basis.replace('_', ' ').replaceFirstChar { it.uppercase() }
}
