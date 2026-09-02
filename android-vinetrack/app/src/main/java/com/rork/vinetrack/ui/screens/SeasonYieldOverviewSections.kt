package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SeasonYieldProjection
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Yield Overview body sections.
 *
 * Split out of `SeasonYieldOverviewScreen` because this module compiles Kotlin
 * against a fixed ~2 GB heap on the build container — several large composables
 * in one file is what tips `compileDebugKotlin`/`compileReleaseKotlin` into GC
 * thrash.
 */

/**
 * Why the crop total is "—". Spelled out, and naming the blocks, so the user
 * can tell "we don't know your crop yet" from "you have no crop".
 */
@Composable
internal fun SeasonYieldIncompleteCard(projection: SeasonYieldProjection.Result) {
    val vine = LocalVineColors.current
    val known = if (projection.damageApplied) {
        projection.knownAdjustedTonnes
    } else {
        projection.knownBaseTonnes
    }
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                "Estimate incomplete",
                color = VineColors.Orange,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                "The crop total stays \"—\" until every active block has an estimate. " +
                    "${seasonTonnesText(known)} is known so far.",
                color = vine.textSecondary,
                fontSize = 12.sp,
            )
            val missing = projection.blocksMissingEstimateNames
            if (missing.isNotEmpty()) {
                Text(
                    "Needs setting up: ${missing.joinToString(", ")}",
                    color = vine.textPrimary,
                    fontSize = 12.sp,
                )
            }
        }
    }
}

/** Canonical per-variety totals, damage applied per block then aggregated. */
@Composable
internal fun SeasonYieldVarietySection(projection: SeasonYieldProjection.Result) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("By Variety", color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        if (projection.varieties.isEmpty()) {
            VineyardCard {
                Text(
                    "No variety estimates for this vintage yet.",
                    color = vine.textSecondary,
                    fontSize = 13.sp,
                )
            }
        } else {
            projection.varieties.forEach { variety -> VarietyRow(projection, variety) }
        }
    }
}

@Composable
private fun VarietyRow(
    projection: SeasonYieldProjection.Result,
    variety: SeasonYieldProjection.VarietyRow,
) {
    val vine = LocalVineColors.current
    val tonnes = if (projection.damageApplied) variety.adjustedTonnes else variety.baseTonnes
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    variety.displayName,
                    color = vine.textPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                if (!variety.isEstimateComplete) {
                    val known = if (projection.damageApplied) {
                        variety.knownAdjustedTonnes
                    } else {
                        variety.knownBaseTonnes
                    }
                    Text(
                        "${seasonTonnesText(known)} known so far",
                        color = vine.textSecondary,
                        fontSize = 11.sp,
                    )
                }
            }
            Text(
                seasonTonnesText(tonnes),
                color = if (tonnes == null) vine.textSecondary else vine.textPrimary,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

/** Every ACTIVE block, including ones with no estimate yet. */
@Composable
internal fun SeasonYieldBlockSection(
    projection: SeasonYieldProjection.Result,
    onInfo: (SeasonYieldProjection.BlockRow) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("By Block", color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        if (projection.blocks.isEmpty()) {
            VineyardCard {
                Text("This vineyard has no blocks yet.", color = vine.textSecondary, fontSize = 13.sp)
            }
        } else {
            projection.blocks.forEach { block ->
                BlockRowCard(projection.damageApplied, block, onInfo)
            }
        }
    }
}

@Composable
private fun BlockRowCard(
    damageApplied: Boolean,
    block: SeasonYieldProjection.BlockRow,
    onInfo: (SeasonYieldProjection.BlockRow) -> Unit,
) {
    val vine = LocalVineColors.current
    val tonnes = if (damageApplied) block.adjustedTonnes else block.baseTonnes
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    block.name,
                    color = vine.textPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    seasonTonnesText(tonnes),
                    color = if (tonnes == null) vine.textSecondary else vine.textPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                )
                // The info button: estimate source, calculation date, pruning
                // inputs, damage adjustment and warnings for THIS block.
                IconButton(onClick = { onInfo(block) }, modifier = Modifier.size(44.dp)) {
                    Icon(
                        Icons.Filled.Info,
                        contentDescription = "Estimate details for ${block.name}",
                        tint = VineColors.LeafGreen,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            val parts = buildList {
                add(seasonHectaresText(block.areaHectares))
                add(seasonYieldSourceLabel(block.estimateSource))
                if (damageApplied && block.damage.damageLossFraction > 0) {
                    add("${seasonPercentText(block.damage.damageLossFraction)} damage")
                }
            }
            Text(parts.joinToString(" · "), color = vine.textSecondary, fontSize = 11.sp)
            if (!block.hasEstimates) {
                Text(
                    "No estimate yet — save the Pruning Yield Calculator for this block.",
                    color = VineColors.Orange,
                    fontSize = 11.sp,
                )
            } else if (!block.isEstimateComplete) {
                Text(
                    "Missing inputs — tap the info button for details.",
                    color = VineColors.Orange,
                    fontSize = 11.sp,
                )
            }
        }
    }
}
