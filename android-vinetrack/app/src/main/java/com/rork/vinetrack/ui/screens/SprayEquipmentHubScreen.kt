package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Intermediate "Spray & Equipment" hub, mirroring the iOS `SprayEquipmentHubView`.
 * It presents four drill-in rows (Spray Management, Equipment & Tractors,
 * Chemicals, Saved Inputs), each pushing to its dedicated screen. This restores
 * the navigation layer that Android previously skipped by jumping straight into
 * the Spray Management hub.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayEquipmentHubScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenFuelLog: (() -> Unit)? = null,
) {
    var sub by rememberSaveable { mutableStateOf<String?>(null) }

    when (sub) {
        "spray" -> {
            BackHandler { sub = null }
            SprayManagementScreen(
                vm, state, modifier,
                onBack = { sub = null },
                onOpenFuelLog = { onOpenFuelLog?.invoke() },
            )
        }
        "equipment" -> {
            BackHandler { sub = null }
            EquipmentScreen(
                vm, state, modifier,
                onBack = { sub = null },
                onOpenFuelLog = { onOpenFuelLog?.invoke() },
            )
        }
        "chemicals" -> {
            BackHandler { sub = null }
            ChemicalsScreen(vm, state, modifier, onBack = { sub = null })
        }
        "inputs" -> {
            BackHandler { sub = null }
            SavedInputsScreen(vm, state, modifier, onBack = { sub = null })
        }
        else -> SprayEquipmentHub(
            state = state,
            modifier = modifier,
            onBack = onBack,
            onOpenSpray = { sub = "spray" },
            onOpenEquipment = { sub = "equipment" },
            onOpenChemicals = { sub = "chemicals" },
            onOpenInputs = { sub = "inputs" },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayEquipmentHub(
    state: AppUiState,
    modifier: Modifier,
    onBack: (() -> Unit)?,
    onOpenSpray: () -> Unit,
    onOpenEquipment: () -> Unit,
    onOpenChemicals: () -> Unit,
    onOpenInputs: () -> Unit,
) {
    val vine = LocalVineColors.current

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray & Equipment") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item(key = "header") {
                SectionHeader("Spray & Equipment", onLight = true)
            }
            item(key = "card") {
                VineyardCard {
                    HubRow(
                        title = "Spray Management",
                        subtitle = "Presets and programs",
                        icon = Icons.Filled.WaterDrop,
                        tint = VineColors.Cyan,
                        onClick = onOpenSpray,
                    )
                    HubDivider()
                    HubRow(
                        title = "Equipment & Tractors",
                        subtitle = "Sprayers, tractors, fuel",
                        icon = Icons.Filled.Build,
                        tint = VineColors.EarthBrown,
                        onClick = onOpenEquipment,
                    )
                    HubDivider()
                    HubRow(
                        title = "Chemicals",
                        subtitle = "Saved chemical library",
                        icon = Icons.Filled.Science,
                        tint = VineColors.Purple,
                        onClick = onOpenChemicals,
                    )
                    HubDivider()
                    HubRow(
                        title = "Saved Inputs",
                        subtitle = "Seed, fertiliser & inputs library",
                        icon = Icons.Filled.Grass,
                        tint = VineColors.LeafGreen,
                        onClick = onOpenInputs,
                    )
                }
            }
        }
    }
}

@Composable
private fun HubDivider() {
    val vine = LocalVineColors.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .size(0.5.dp)
            .background(vine.cardBorder),
    )
}

@Composable
private fun HubRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    tint: Color,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(20.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                fontSize = 16.sp,
            )
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
        )
    }
}
