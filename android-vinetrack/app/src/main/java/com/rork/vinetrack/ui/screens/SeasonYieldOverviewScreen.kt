package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SeasonYieldProjection
import com.rork.vinetrack.data.VintageResolver
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.LocalDate

/**
 * Yield Overview — the vintage's canonical seasonal estimate, mirroring the iOS
 * `SeasonYieldOverviewView`.
 *
 * Every figure comes from `get_season_yield_base_overview` (sql/221), the single
 * base-estimate authority. Damage is layered on top per block by
 * `SeasonYieldDamage` and is OFF by default.
 *
 * An incomplete estimate shows "—", never `0 t`, and names the blocks that still
 * need configuring.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeasonYieldOverviewScreen(
    vm: AppViewModel,
    state: AppUiState,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current

    val currentVintage = remember(state.seasonStartMonth, state.seasonStartDay) {
        VintageResolver.vintageYear(LocalDate.now(), state.seasonStartMonth, state.seasonStartDay)
    }
    var selectedVintage by remember(currentVintage) { mutableStateOf(currentVintage) }
    var infoBlock by remember { mutableStateOf<SeasonYieldProjection.BlockRow?>(null) }

    LaunchedEffect(selectedVintage, state.selectedVineyardId) {
        vm.loadSeasonYieldOverview(selectedVintage)
    }

    val overview = state.seasonYieldOverview?.takeIf { state.seasonYieldVintage == selectedVintage }
    val projection = remember(overview, state.damageRecords, state.seasonYieldApplyDamage) {
        overview?.let {
            SeasonYieldProjection.make(
                overview = it,
                damageRecords = SeasonYieldProjection.damageRecords(
                    records = state.damageRecords,
                    vineyardId = it.vineyardId,
                    vintage = it.vintage,
                    seasonStartMonth = state.seasonStartMonth,
                    seasonStartDay = state.seasonStartDay,
                ),
                applyDamage = state.seasonYieldApplyDamage,
            )
        }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Yield Overview") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))

            VintagePicker(
                current = currentVintage,
                selected = selectedVintage,
                onSelect = { selectedVintage = it },
            )

            when {
                projection != null -> {
                    TotalCard(projection)
                    DamageToggle(
                        applyDamage = state.seasonYieldApplyDamage,
                        hasExcluded = projection.hasExcludedDamageRecords,
                        onToggle = { vm.setSeasonYieldApplyDamage(it) },
                    )
                    if (!projection.isEstimateComplete) SeasonYieldIncompleteCard(projection)
                    SeasonYieldVarietySection(projection)
                    SeasonYieldBlockSection(projection) { infoBlock = it }
                }
                state.seasonYieldLoading -> VineyardCard {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text(
                            "Loading the seasonal estimate…",
                            color = vine.textSecondary,
                            fontSize = 13.sp,
                        )
                    }
                }
                else -> VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            "Estimate unavailable",
                            color = VineColors.Orange,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 15.sp,
                        )
                        Text(
                            state.seasonYieldError
                                ?: "Pull down to load the seasonal estimate for this vintage.",
                            color = vine.textSecondary,
                            fontSize = 13.sp,
                        )
                    }
                }
            }
        }
    }

    infoBlock?.let { block ->
        SeasonYieldBlockInfoDialog(
            block = block,
            damageApplied = projection?.damageApplied == true,
            onDismiss = { infoBlock = null },
        )
    }
}

// ---- Vintage ---------------------------------------------------------------

@Composable
private fun VintagePicker(current: Int, selected: Int, onSelect: (Int) -> Unit) {
    val vine = LocalVineColors.current
    val options = remember(current) {
        listOf(current + 1, current, current - 1, current - 2).filter { it > 0 }
    }
    Row(
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEach { vintage ->
            val isSelected = vintage == selected
            Text(
                text = if (vintage == current) "$vintage · Current" else "$vintage",
                color = if (isSelected) Color.White else vine.textSecondary,
                fontSize = 12.sp,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (isSelected) VineColors.LeafGreen else vine.cardBackground)
                    .clickable { onSelect(vintage) }
                    .padding(horizontal = 14.dp, vertical = 7.dp),
            )
        }
    }
}

// ---- Total -----------------------------------------------------------------

@Composable
private fun TotalCard(projection: SeasonYieldProjection.Result) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                if (projection.damageApplied) "Estimated crop (damage applied)" else "Estimated crop",
                color = vine.textSecondary,
                fontSize = 12.sp,
            )
            Text(
                seasonTonnesText(projection.displayTotalTonnes),
                color = if (projection.displayTotalTonnes == null) vine.textSecondary else vine.textPrimary,
                fontSize = 34.sp,
                fontWeight = FontWeight.Bold,
            )
            val base = projection.totalBaseTonnes
            val adjusted = projection.totalAdjustedTonnes
            if (projection.damageApplied && base != null && adjusted != null && base > adjusted) {
                Text(
                    "${seasonTonnesText(base - adjusted)} removed by recorded damage (base ${seasonTonnesText(base)})",
                    color = VineColors.Orange,
                    fontSize = 12.sp,
                )
            }
            Text(
                "${projection.blocksWithEstimates}/${projection.blocksTotal} blocks · " +
                    seasonYieldSourceLabel(projection.estimateSource),
                color = vine.textSecondary,
                fontSize = 12.sp,
            )
            Text(
                "Calculated ${projection.calculatedAt?.take(16)?.replace('T', ' ') ?: "never"}",
                color = vine.textSecondary,
                fontSize = 11.sp,
            )
        }
    }
}

// ---- Damage ----------------------------------------------------------------

@Composable
private fun DamageToggle(applyDamage: Boolean, hasExcluded: Boolean, onToggle: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        "Apply recorded damage",
                        color = vine.textPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "Area-weighted: each record reduces the block by its mapped area × its intensity. The base estimate is always kept.",
                        color = vine.textSecondary,
                        fontSize = 11.sp,
                    )
                }
                Switch(checked = applyDamage, onCheckedChange = onToggle)
            }
            if (hasExcluded) {
                Text(
                    "Some damage records have no valid mapped area and were excluded.",
                    color = VineColors.Orange,
                    fontSize = 11.sp,
                )
            }
        }
    }
}
