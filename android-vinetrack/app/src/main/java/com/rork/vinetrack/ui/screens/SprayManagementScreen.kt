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
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Central Spray Management hub, mirroring the iOS `SprayManagementSettingsView`
 * information architecture. Owners/managers manage spray setup from one place;
 * other members see the same hub with read-only sub-screens. Entries that are
 * not yet implemented on Android show a "Coming soon" affordance rather than a
 * dead link.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayManagementScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenFuelLog: (() -> Unit)? = null,
) {
    // Self-contained sub-navigation: only Chemicals is implemented on Android.
    var sub by rememberSaveable { mutableStateOf<String?>(null) }

    when (sub) {
        "chemicals" -> {
            BackHandler { sub = null }
            ChemicalsScreen(vm, state, modifier, onBack = { sub = null })
        }
        "operators" -> {
            BackHandler { sub = null }
            OperatorCategoriesScreen(vm, state, modifier, onBack = { sub = null })
        }
        "equipment" -> {
            BackHandler { sub = null }
            EquipmentScreen(
                vm, state, modifier,
                onBack = { sub = null },
                onOpenFuelLog = { onOpenFuelLog?.invoke() },
            )
        }
        "inputs" -> {
            BackHandler { sub = null }
            SavedInputsScreen(vm, state, modifier, onBack = { sub = null })
        }
        "presets" -> {
            BackHandler { sub = null }
            SprayPresetsScreen(vm, state, modifier, onBack = { sub = null })
        }
        "canopy" -> {
            BackHandler { sub = null }
            CanopyWaterRatesScreen(modifier, onBack = { sub = null })
        }
        else -> SprayManagementHub(
            state = state,
            modifier = modifier,
            onBack = onBack,
            onOpenChemicals = { sub = "chemicals" },
            onOpenOperators = { sub = "operators" },
            onOpenEquipment = { sub = "equipment" },
            onOpenPresets = { sub = "presets" },
            onOpenCanopy = { sub = "canopy" },
            onOpenInputs = { sub = "inputs" },
        )
    }
}

/** Explains Unit Canopy Row (UCR), mirroring the iOS `UCRInfoSheet`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UcrInfoSheet(onDismiss: () -> Unit) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Unit Canopy Row (UCR)", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "Unit canopy row (UCR) is a method that enables chemical rate adjustments to be made for different canopies or growth stages to achieve consistent chemical doses during the season.",
                fontSize = 15.sp,
                color = vine.textPrimary,
            )
            Text(
                "One UCR is defined as a 1 metre wide \u00d7 1 metre high canopy of 100 metre length.",
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = vine.textPrimary,
            )
            AsyncImage(
                model = "https://r2-pub.rork.com/projects/u8ega94cbdz6azh6dulre/assets/f94c9dd1-9704-4597-aa22-8c6607590ad7.png",
                contentDescription = "UCR diagram",
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 200.dp)
                    .clip(RoundedCornerShape(12.dp)),
            )
            Text(
                "UCR is based on the assumption that 30 litres of spray mixture will thoroughly wet a vine canopy that is 1 metre high by 1 metre wide and 100 metres in length, though in reality this value can vary from 20 to 50L/UCR depending on canopy type and density.",
                fontSize = 15.sp,
                color = vine.textPrimary,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayManagementHub(
    state: AppUiState,
    modifier: Modifier,
    onBack: (() -> Unit)?,
    onOpenChemicals: () -> Unit,
    onOpenOperators: () -> Unit,
    onOpenEquipment: () -> Unit,
    onOpenPresets: () -> Unit,
    onOpenCanopy: () -> Unit,
    onOpenInputs: () -> Unit,
) {
    val vine = LocalVineColors.current
    var showUcrInfo by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray Management") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            section(
                header = "Presets",
                footer = "Manage saved chemicals and tank presets for quick selection in spray records.",
            ) {
                ManagementRow(
                    title = "Spray Presets",
                    subtitle = "Tank presets for quick selection",
                    icon = Icons.Filled.Science,
                    tint = VineColors.LeafGreen,
                    trailing = "${state.savedChemicals.size} chemicals",
                    enabled = true,
                    onClick = onOpenPresets,
                )
            }

            section(
                header = "Data",
                footer = "Manage chemicals and equipment used in spray calculations.",
            ) {
                ManagementRow(
                    title = "Chemicals",
                    subtitle = "Saved products & costs",
                    icon = Icons.Filled.Science,
                    tint = VineColors.Info,
                    trailing = state.savedChemicals.size.toString(),
                    enabled = true,
                    onClick = onOpenChemicals,
                )
                RowDivider()
                ManagementRow(
                    title = "Equipment & Tractors",
                    subtitle = "Tractors, sprayers, machines & fuel",
                    icon = Icons.Filled.Build,
                    tint = VineColors.EarthBrown,
                    trailing = (state.sprayEquipment.size + state.machines.size).let { total -> if (total > 0) total.toString() else "" },
                    enabled = true,
                    onClick = onOpenEquipment,
                )
                RowDivider()
                ManagementRow(
                    title = "Saved Inputs",
                    subtitle = "Seed, fertiliser & costs",
                    icon = Icons.Filled.Grass,
                    tint = VineColors.LeafGreen,
                    trailing = state.savedInputs.size.toString(),
                    enabled = true,
                    onClick = onOpenInputs,
                )
            }

            section(
                header = "Operator Costs",
                footer = "Define operator cost categories and assign them to vineyard users for trip cost calculations.",
            ) {
                ManagementRow(
                    title = "Operator Categories",
                    subtitle = "Cost categories per user",
                    icon = Icons.Filled.Person,
                    tint = VineColors.Orange,
                    trailing = state.operatorCategories.size.toString(),
                    enabled = true,
                    onClick = onOpenOperators,
                )
            }

            item(key = "header-vsp") {
                SectionHeaderWithInfo(
                    title = "VSP Canopy Calculation Settings",
                    onInfo = { showUcrInfo = true },
                )
            }
            item(key = "card-vsp") {
                VineyardCard {
                ManagementRow(
                    title = "Canopy Water Rates",
                    subtitle = "L/100m of row",
                    icon = Icons.Filled.WaterDrop,
                    tint = VineColors.Cyan,
                    trailing = "L/100m",
                    enabled = true,
                    onClick = onOpenCanopy,
                )
                }
            }
            item(key = "footer-vsp") {
                SectionFooter("Configure the indicative water volumes per 100m of row for each canopy size and density.")
            }
        }
    }

    if (showUcrInfo) {
        UcrInfoSheet(onDismiss = { showUcrInfo = false })
    }
}

@Composable
private fun SectionHeaderWithInfo(title: String, onInfo: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SectionHeader(title, onLight = true, modifier = Modifier.weight(1f))
        IconButton(onClick = onInfo) {
            Icon(
                Icons.Filled.Info,
                contentDescription = "About Unit Canopy Row",
                tint = VineColors.Info,
            )
        }
    }
}

/** Renders a labelled section header + card group + footer caption. */
private fun androidx.compose.foundation.lazy.LazyListScope.section(
    header: String,
    footer: String,
    content: @Composable () -> Unit,
) {
    item(key = "header-$header") { SectionHeader(header, onLight = true) }
    item(key = "card-$header") { VineyardCard { content() } }
    item(key = "footer-$header") { SectionFooter(footer) }
}

@Composable
private fun SectionFooter(text: String) {
    val vine = LocalVineColors.current
    Text(
        text = text,
        fontSize = 12.sp,
        color = vine.textSecondary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
    )
}

@Composable
private fun RowDivider() {
    val vine = LocalVineColors.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .size(0.5.dp)
            .background(vine.cardBorder),
    )
}

@Composable
private fun ManagementRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    tint: Color,
    trailing: String,
    enabled: Boolean,
    onClick: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val rowModifier = if (enabled && onClick != null) {
        Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp)
    } else {
        Modifier.fillMaxWidth().padding(vertical = 10.dp)
    }
    Row(
        modifier = rowModifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(tint.copy(alpha = if (enabled) 0.15f else 0.08f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = if (enabled) tint else tint.copy(alpha = 0.5f),
                modifier = Modifier.size(20.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                fontWeight = FontWeight.SemiBold,
                color = if (enabled) vine.textPrimary else vine.textSecondary,
                fontSize = 16.sp,
            )
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Text(
            trailing,
            fontSize = 13.sp,
            color = vine.textSecondary,
            fontWeight = if (trailing == "Soon") FontWeight.Normal else FontWeight.SemiBold,
        )
        if (enabled) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = vine.textSecondary,
            )
        }
    }
}
