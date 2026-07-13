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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Terrain
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.GddCalculationMode
import com.rork.vinetrack.data.GddResetMode
import com.rork.vinetrack.data.GddSettings
import com.rork.vinetrack.data.GddSettingsStore
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale

/**
 * Vineyard Location & Degree-Day Calculation settings, mirroring the iOS
 * "Vineyard Location" section of the setup hub. Edits the active vineyard's
 * latitude / longitude / elevation (persisted to the shared `vineyards` row via
 * the owner/manager-gated `set_vineyard_location` RPC) and the on-device GDD
 * calculation mode (Standard GDD vs BEDD) and reset point.
 *
 * Coordinates and elevation improve degree-day accuracy. Standard GDD is base
 * 10°C; BEDD caps daily temps at 19°C, adds a diurnal-range bonus and applies a
 * day-length factor from latitude. Editing coordinates is owner/manager only.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VineyardLocationScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { GddSettingsStore(context) }
    val vineyard = state.selectedVineyard
    val canEdit = state.currentRole == "owner" || state.currentRole == "manager"

    fun fmt(value: Double?, decimals: Int): String =
        value?.let { String.format(Locale.US, "%.${decimals}f", it) } ?: ""

    var latitude by remember(vineyard?.id) { mutableStateOf(fmt(vineyard?.latitude, 5)) }
    var longitude by remember(vineyard?.id) { mutableStateOf(fmt(vineyard?.longitude, 5)) }
    var elevation by remember(vineyard?.id) { mutableStateOf(fmt(vineyard?.elevationMetres, 0)) }
    var gdd by remember { mutableStateOf(store.load()) }
    var isSaving by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    fun persistGdd(updated: GddSettings) {
        gdd = updated
        store.save(updated)
    }

    fun parseCoord(text: String): Double? = text.trim().replace(",", ".").toDoubleOrNull()

    fun saveLocation() {
        val id = vineyard?.id ?: return
        val lat = parseCoord(latitude)
        val lon = parseCoord(longitude)
        val elev = elevation.trim().replace(Regex("[^0-9.\\-]"), "").toDoubleOrNull()
        if (latitude.isNotBlank() && (lat == null || lat < -90 || lat > 90)) {
            errorText = "Latitude must be between -90 and 90."; return
        }
        if (longitude.isNotBlank() && (lon == null || lon < -180 || lon > 180)) {
            errorText = "Longitude must be between -180 and 180."; return
        }
        errorText = null
        isSaving = true
        saved = false
        vm.updateVineyardLocation(id, lat, lon, elev) { ok ->
            isSaving = false
            if (ok) saved = true else errorText = "Couldn't save the location. Check your connection and role."
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Vineyard Location") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
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
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            if (vineyard == null) {
                VineyardCard {
                    Text("Select a vineyard to edit its location.", color = vine.textSecondary)
                }
                return@Column
            }

            // Coordinates
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Coordinates", onLight = true)
                VineyardCard {
                    CoordField("Latitude", latitude, "-33.29527", "°", canEdit) { latitude = it }
                    RowDivider(vine.cardBorder)
                    CoordField("Longitude", longitude, "148.95614", "°", canEdit) { longitude = it }
                    RowDivider(vine.cardBorder)
                    CoordField("Elevation", elevation, "0", "m", canEdit) { elevation = it }
                }
                Text(
                    "Coordinates and elevation improve degree-day accuracy. " +
                        if (canEdit) "" else "Only owners and managers can change the location.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                errorText?.let {
                    Text(it, fontSize = 12.sp, color = VineColors.Destructive)
                }
                if (canEdit) {
                    Button(
                        onClick = { saveLocation() },
                        enabled = !isSaving,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                    ) {
                        if (isSaving) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = androidx.compose.ui.graphics.Color.White)
                        } else if (saved) {
                            Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text("  Saved")
                        } else {
                            Text("Save Location")
                        }
                    }
                }
            }

            // Calculation mode
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Degree-Day Calculation", onLight = true)
                VineyardCard {
                    GddCalculationMode.entries.forEachIndexed { index, mode ->
                        SelectableRow(
                            title = mode.displayName,
                            subtitle = if (mode == GddCalculationMode.GDD) {
                                "Base 10°C average of daily high and low."
                            } else {
                                "Caps daily temps at 19°C, adds a diurnal-range bonus and a latitude day-length factor."
                            },
                            selected = gdd.calculationMode == mode,
                        ) { persistGdd(gdd.copy(calculationMode = mode)) }
                        if (index < GddCalculationMode.entries.lastIndex) RowDivider(vine.cardBorder)
                    }
                }
            }

            // Reset point
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Reset Point", onLight = true)
                VineyardCard {
                    GddResetMode.entries.forEachIndexed { index, mode ->
                        SelectableRow(
                            title = mode.displayName,
                            subtitle = null,
                            selected = gdd.resetMode == mode,
                        ) { persistGdd(gdd.copy(resetMode = mode)) }
                        if (index < GddResetMode.entries.lastIndex) RowDivider(vine.cardBorder)
                    }
                }
                Text(
                    "Determines when accumulation starts each season. When a block has the chosen " +
                        "phenology date recorded it is used; otherwise the season start applies. " +
                        "Saved on this device only.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun CoordField(
    label: String,
    value: String,
    placeholder: String,
    suffix: String,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f))
        if (enabled) {
            OutlinedTextField(
                value = value,
                onValueChange = onValueChange,
                placeholder = { Text(placeholder, color = vine.textSecondary) },
                suffix = { Text(suffix, color = vine.textSecondary) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.size(width = 170.dp, height = 56.dp),
            )
        } else {
            Text(
                if (value.isBlank()) "Not set" else "$value$suffix",
                color = vine.textSecondary,
                fontWeight = FontWeight.SemiBold,
            )
            Box(Modifier.size(8.dp))
            Icon(Icons.Filled.Lock, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
private fun SelectableRow(
    title: String,
    subtitle: String?,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = vine.textPrimary, fontWeight = FontWeight.SemiBold)
            if (subtitle != null) {
                Text(subtitle, color = vine.textSecondary, fontSize = 12.sp)
            }
        }
        if (selected) {
            Box(Modifier.size(8.dp))
            Icon(Icons.Filled.Check, contentDescription = "Selected", tint = VineColors.Success)
        }
    }
}

@Composable
private fun RowDivider(color: androidx.compose.ui.graphics.Color) {
    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(color))
}
