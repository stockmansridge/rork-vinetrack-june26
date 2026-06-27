package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.AreaUnit
import com.rork.vinetrack.data.DistanceSystem
import com.rork.vinetrack.data.FuelUnit
import com.rork.vinetrack.data.RegionCountry
import com.rork.vinetrack.data.RegionCurrency
import com.rork.vinetrack.data.RegionDateFormat
import com.rork.vinetrack.data.RegionSettings
import com.rork.vinetrack.data.RegionSettingsRepository
import com.rork.vinetrack.data.RegionSettingsStore
import com.rork.vinetrack.data.SprayRateAreaUnit
import com.rork.vinetrack.data.TerminologyRegion
import com.rork.vinetrack.data.VolumeUnit
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * Vineyard-level "Region & Units" settings, mirroring the iOS
 * `RegionUnitsSettingsView`. These control how vineyard records are *displayed
 * and exported* — they never rewrite stored records. Values are read from and
 * saved back to the shared `vineyards` row through the
 * `get_vineyard_region_settings` / `set_vineyard_region_settings` RPCs.
 *
 * Editing is owner/manager only; staff and operators see a read-only view (the
 * server RPC also enforces this). Any missing value falls back to AU defaults.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RegionUnitsSettingsScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val store = remember { RegionSettingsStore(context) }
    val repo = remember { RegionSettingsRepository(SessionStore(context)) }
    val vineyardId = state.selectedVineyardId
    val canEdit = state.currentRole == "owner" || state.currentRole == "manager"

    var working by remember { mutableStateOf(store.load(vineyardId)) }
    var isSaving by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var pendingCountry by remember { mutableStateOf<RegionCountry?>(null) }

    // Pull authoritative server values when the screen opens, so settings saved
    // on another device or the web portal are reflected immediately.
    LaunchedEffect(vineyardId) {
        if (vineyardId == null) return@LaunchedEffect
        runCatching { repo.get(vineyardId) }.getOrNull()?.let { remote ->
            store.save(vineyardId, remote)
            if (!isSaving && pendingCountry == null) working = remote
        }
    }

    fun save() {
        if (!canEdit || vineyardId == null || isSaving) return
        isSaving = true
        scope.launch {
            try {
                val result = repo.set(vineyardId, working)
                store.save(vineyardId, result)
                working = result
                saved = true
            } catch (e: Exception) {
                errorMessage = e.message ?: "Couldn't save region settings."
            } finally {
                isSaving = false
            }
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Region & Units") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = {
                    if (canEdit) {
                        if (isSaving) {
                            CircularProgressIndicator(modifier = Modifier.size(22.dp).padding(end = 12.dp), strokeWidth = 2.dp)
                        } else {
                            TextButton(onClick = { save() }) { Text("Save", fontWeight = FontWeight.SemiBold) }
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            VineyardCard {
                Text(
                    "Region and unit settings control how vineyard records are displayed and exported. Changing these settings does not rewrite existing spray, fuel, task, maintenance, equipment, or costing records.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            // Country
            PickerSection(
                title = "Country",
                footer = "Changing the country suggests recommended defaults for that region. You can apply them or keep your current choices.",
            ) {
                RegionCountry.entries.forEachIndexed { index, country ->
                    PickerRow(
                        label = country.displayName,
                        selected = working.countryCode == country.code,
                        enabled = canEdit,
                        onClick = {
                            if (country.code != working.countryCode) pendingCountry = country
                        },
                    )
                    if (index < RegionCountry.entries.lastIndex) RowDividerThin(vine.cardBorder)
                }
            }

            // Currency
            PickerSection(title = "Currency") {
                RegionCurrency.entries.forEachIndexed { index, c ->
                    PickerRow(
                        label = c.label,
                        selected = working.currencyCode == c.code,
                        enabled = canEdit,
                        onClick = { working = working.copy(currencyCode = c.code) },
                    )
                    if (index < RegionCurrency.entries.lastIndex) RowDividerThin(vine.cardBorder)
                }
            }

            // Units
            PickerSection(title = "Units") {
                OptionRow("Area", AreaUnit.entries.map { it.raw to it.label }, working.areaUnit, canEdit) {
                    working = working.copy(areaUnit = it)
                }
                RowDividerThin(vine.cardBorder)
                OptionRow("Volume", VolumeUnit.entries.map { it.raw to it.label }, working.volumeUnit, canEdit) {
                    working = working.copy(volumeUnit = it)
                }
                RowDividerThin(vine.cardBorder)
                OptionRow("Distance", DistanceSystem.entries.map { it.raw to it.label }, working.distanceUnit, canEdit) {
                    working = working.copy(distanceUnit = it)
                }
                RowDividerThin(vine.cardBorder)
                OptionRow("Fuel", FuelUnit.entries.map { it.raw to it.label }, working.fuelUnit, canEdit) {
                    working = working.copy(fuelUnit = it)
                }
                RowDividerThin(vine.cardBorder)
                OptionRow("Spray Rate Area", SprayRateAreaUnit.entries.map { it.raw to it.label }, working.sprayRateAreaUnit, canEdit) {
                    working = working.copy(sprayRateAreaUnit = it)
                }
            }

            // Date format
            PickerSection(
                title = "Date Format",
                footer = "Timezone is managed under Vineyard Location and is shared across the organisation.",
            ) {
                RegionDateFormat.entries.forEachIndexed { index, f ->
                    PickerRow(
                        label = f.label,
                        selected = working.dateFormat == f.raw,
                        enabled = canEdit,
                        onClick = { working = working.copy(dateFormat = f.raw) },
                    )
                    if (index < RegionDateFormat.entries.lastIndex) RowDividerThin(vine.cardBorder)
                }
            }

            // Terminology
            PickerSection(title = "Terminology") {
                TerminologyRegion.entries.forEachIndexed { index, t ->
                    PickerRow(
                        label = t.label,
                        selected = working.terminologyRegion == t.raw,
                        enabled = canEdit,
                        onClick = { working = working.copy(terminologyRegion = t.raw) },
                    )
                    if (index < TerminologyRegion.entries.lastIndex) RowDividerThin(vine.cardBorder)
                }
            }

            if (!canEdit) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Lock, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                    Text(
                        "Only vineyard owners and managers can change region and unit settings.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }
        }
    }

    // Country-change confirmation: offer recommended defaults or keep choices.
    pendingCountry?.let { country ->
        AlertDialog(
            onDismissRequest = { pendingCountry = null },
            title = { Text("Apply recommended defaults?") },
            text = {
                Text("Set currency, units, date format and terminology to the recommended defaults for ${country.displayName}? Your current choices will be replaced. Choose \"Keep Current Settings\" to change only the country.")
            },
            confirmButton = {
                TextButton(onClick = {
                    working = country.recommendedPreset.copy(timezone = working.timezone)
                    pendingCountry = null
                }) { Text("Apply Defaults") }
            },
            dismissButton = {
                TextButton(onClick = {
                    working = working.copy(countryCode = country.code)
                    pendingCountry = null
                }) { Text("Keep Current Settings") }
            },
        )
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = { Text("Couldn't Save") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { errorMessage = null }) { Text("OK") } },
        )
    }

    if (saved) {
        LaunchedEffect(Unit) {
            kotlinx.coroutines.delay(1500)
            saved = false
        }
    }
}

@Composable
private fun PickerSection(
    title: String,
    footer: String? = null,
    content: @Composable () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionHeader(title, onLight = true)
        VineyardCard { content() }
        footer?.let { Text(it, fontSize = 11.sp, color = vine.textSecondary) }
    }
}

@Composable
private fun PickerRow(
    label: String,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (enabled) it.clickable { onClick() } else it }
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            color = if (enabled) vine.textPrimary else vine.textSecondary,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            modifier = Modifier.weight(1f),
        )
        if (selected) {
            Icon(Icons.Filled.Check, contentDescription = "Selected", tint = VineColors.Success, modifier = Modifier.size(20.dp))
        }
    }
}

/** A compact inline cycle-through row for two-option unit choices. */
@Composable
private fun OptionRow(
    title: String,
    options: List<Pair<String, String>>,
    selectedRaw: String,
    enabled: Boolean,
    onSelect: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(modifier = Modifier.padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 13.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEach { (raw, label) ->
                val isSelected = raw == selectedRaw
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (isSelected) VineColors.Primary.copy(alpha = 0.15f) else vine.appBackground)
                        .let { if (enabled) it.clickable { onSelect(raw) } else it }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    Text(
                        label,
                        fontSize = 13.sp,
                        color = if (isSelected) VineColors.Primary else vine.textSecondary,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    )
                }
            }
        }
    }
}

@Composable
private fun RowDividerThin(color: androidx.compose.ui.graphics.Color) {
    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(color))
}
