package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors

/** Raw post-to-post results. Never guesses tonnes or overwrites the active
 * source chosen for the same block/vintage by another counting method.
 */
@Composable
internal fun PanelCountSummary(session: YieldEstimationSession) {
    val vine = LocalVineColors.current
    val byBlock = session.sampleSites.filter { it.panelCountEntry != null }
        .groupBy { it.paddockId.lowercase() }
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Panel Count · Recorded Observations", fontWeight = FontWeight.Bold, color = vine.textPrimary)
            if (byBlock.isEmpty()) {
                Text("No post-to-post panels have been recorded.", color = vine.textSecondary)
            } else {
                byBlock.forEach { (_, samples) ->
                    val measurements = samples.mapNotNull { it.panelCountEntry?.measurement }
                    val totalBunches = measurements.sumOf { it.totalBunches.toLong() }
                    val planted = measurements.sumOf { it.plantedPositions.toLong() }
                    val fruiting = measurements.sumOf { it.fruitingVines.toLong() }
                    val missing = measurements.sumOf { it.missingPositions.toLong() }
                    val nonproductive = measurements.sumOf { it.nonproductiveVines.toLong() }
                    Text(samples.first().paddockName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    Text("${samples.size} panels · ${totalBunches} bunches · ${planted} planted positions",
                        color = vine.textPrimary)
                    Text("${fruiting} fruiting · ${missing} missing · ${nonproductive} nonproductive",
                        color = vine.textSecondary)
                    if (planted > 0) {
                        Text("${"%.2f".format(totalBunches.toDouble() / planted)} bunches per planted position",
                            color = vine.textPrimary)
                    }
                }
            }
            Text("This is a separate method-specific observation. It is not automatically selected as the current Yield Estimate, and no unverified tonnage is calculated.",
                color = vine.textSecondary)
        }
    }
}
