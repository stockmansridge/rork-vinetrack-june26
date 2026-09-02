package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SeasonYieldProjection
import com.rork.vinetrack.data.model.GrapeAllocationCalculator
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlin.math.abs

/**
 * Grape Allocation availability card, driven entirely by the canonical
 * seasonal estimate (sql/221).
 *
 * Kept out of `GrapeAllocationScreen` because that screen's body is already
 * very large and this module compiles Kotlin in-process on a fixed 4 GB heap —
 * one oversized composable is what tips codegen into "Couldn't transform method
 * node".
 *
 * When the DB withholds the canonical total (any active block still
 * unconfigured) every figure here shows "—" and no balance is computed:
 * allocating against an invented `0 t` is how a grower over-commits a crop
 * nobody has measured.
 */
@Composable
fun GrapeAllocationSummaryCard(
    summary: GrapeAllocationCalculator.CanonicalSummary,
    projection: SeasonYieldProjection.Result?,
    isLoading: Boolean,
    errorMessage: String?,
    contractedIncome: String?,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AllocationStat("Estimated", summary.estimatedTonnes, VineColors.Indigo, Modifier.weight(1f))
                AllocationStat("Own Use", summary.ownUseTonnes, VineColors.Purple, Modifier.weight(1f))
                AllocationStat("Committed", summary.committedTonnes, VineColors.Orange, Modifier.weight(1f))
            }

            EstimateStatusLine(
                summary = summary,
                projection = projection,
                isLoading = isLoading,
                errorMessage = errorMessage,
            )

            BalanceRow(summary)

            if (contractedIncome != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Contracted Income",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textSecondary,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        contractedIncome,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        color = vine.textPrimary,
                    )
                }
            }
        }
    }
}

/**
 * Why the estimate is "—", or what it is based on when it isn't. The difference
 * between "you have no crop" and "we don't know your crop yet" is always spelled
 * out rather than left to the dash.
 */
@Composable
private fun EstimateStatusLine(
    summary: GrapeAllocationCalculator.CanonicalSummary,
    projection: SeasonYieldProjection.Result?,
    isLoading: Boolean,
    errorMessage: String?,
) {
    val vine = LocalVineColors.current
    when {
        isLoading && projection == null ->
            Text("Loading the seasonal estimate…", fontSize = 11.sp, color = vine.textSecondary)

        errorMessage != null ->
            Text(errorMessage, fontSize = 11.sp, color = VineColors.Orange)

        projection != null && !projection.isEstimateComplete -> Column(
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            val headline = if (projection.blocksMissingEstimates > 0) {
                "${projection.blocksMissingEstimates} of ${projection.blocksTotal} blocks have no estimate yet"
            } else {
                "Some blocks are missing calculator inputs"
            }
            Text(headline, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Orange)
            Text(
                "Allocating needs a complete estimate. " +
                    "${seasonTonnesText(summary.knownEstimatedTonnes)} is known so far — " +
                    "finish the Pruning Yield Calculator for every block.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }

        projection != null -> Text(
            seasonYieldSourceLabel(projection.estimateSource) +
                " · ${projection.blocksTotal} blocks · " +
                if (projection.damageApplied) "damage applied" else "before damage",
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun BalanceRow(summary: GrapeAllocationCalculator.CanonicalSummary) {
    val vine = LocalVineColors.current
    // Unknown supply is never reported as a shortfall — the grower would be
    // chasing a deficit the data cannot support.
    val accent: Color = when {
        summary.isSupplyUnknown -> vine.textSecondary
        summary.isShortfall -> VineColors.Destructive
        else -> VineColors.LeafGreen
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            if (summary.isShortfall || summary.isSupplyUnknown) {
                Icons.Filled.Warning
            } else {
                Icons.Filled.CheckCircle
            },
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            if (summary.isShortfall) "Shortfall" else "Available",
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = accent,
        )
        Spacer(Modifier.weight(1f))
        Text(
            summary.balanceTonnes?.let { seasonTonnesText(abs(it)) } ?: "—",
            fontSize = 17.sp,
            fontWeight = FontWeight.Bold,
            color = if (summary.isSupplyUnknown) vine.textSecondary else accent,
        )
    }
}

@Composable
internal fun AllocationStat(
    label: String,
    tonnes: Double?,
    color: Color,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            seasonTonnesText(tonnes),
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (tonnes == null) vine.textSecondary else color,
        )
        Text(label, fontSize = 10.sp, color = vine.textSecondary)
    }
}
