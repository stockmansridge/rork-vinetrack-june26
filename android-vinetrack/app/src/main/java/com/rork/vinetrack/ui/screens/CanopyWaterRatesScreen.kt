package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.RestartAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.CanopyWaterRatesStore
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale

/**
 * VSP Canopy Water Rates editor. Mirrors the iOS `CalculationSettingsView`:
 * eight litres-per-100m values (small/medium/large/full × low/high density)
 * used to derive the recommended water rate (L/ha) from row spacing.
 *
 * Like iOS, this is on-device-only preference data via [CanopyWaterRatesStore]
 * — there is no shared backend table, so there is no role gating (it matches
 * the iOS calculator settings, which any signed-in user can adjust locally).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CanopyWaterRatesScreen(modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { CanopyWaterRatesStore(context) }

    val saved = remember { store.load() }
    var smallLow by remember { mutableStateOf(numText(saved.smallLow)) }
    var smallHigh by remember { mutableStateOf(numText(saved.smallHigh)) }
    var mediumLow by remember { mutableStateOf(numText(saved.mediumLow)) }
    var mediumHigh by remember { mutableStateOf(numText(saved.mediumHigh)) }
    var largeLow by remember { mutableStateOf(numText(saved.largeLow)) }
    var largeHigh by remember { mutableStateOf(numText(saved.largeHigh)) }
    var fullLow by remember { mutableStateOf(numText(saved.fullLow)) }
    var fullHigh by remember { mutableStateOf(numText(saved.fullHigh)) }

    var savedConfirmation by remember { mutableStateOf<String?>(null) }
    var showResetDialog by remember { mutableStateOf(false) }

    fun current(): CanopyWaterRates = CanopyWaterRates(
        smallLow = parseRate(smallLow),
        smallHigh = parseRate(smallHigh),
        mediumLow = parseRate(mediumLow),
        mediumHigh = parseRate(mediumHigh),
        largeLow = parseRate(largeLow),
        largeHigh = parseRate(largeHigh),
        fullLow = parseRate(fullLow),
        fullHigh = parseRate(fullHigh),
    )

    fun persist() {
        store.save(current())
        savedConfirmation = "Saved"
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Calculation Settings") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = {
                    TextButton(onClick = { persist() }) { Text("Save") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                Text(
                    "These values represent litres per 100m of row for each canopy size and density combination. They are used to calculate the recommended water rate (L/ha) based on your row spacing.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
            }

            canopySection(
                title = "Small Canopy",
                description = "up to 0.5m × 0.5m",
                low = smallLow, onLow = { smallLow = it },
                high = smallHigh, onHigh = { smallHigh = it },
            )
            canopySection(
                title = "Medium Canopy",
                description = "up to 1m × 1m",
                low = mediumLow, onLow = { mediumLow = it },
                high = mediumHigh, onHigh = { mediumHigh = it },
            )
            canopySection(
                title = "Large Canopy",
                description = "Wires Up - 1.5m × 0.5m",
                low = largeLow, onLow = { largeLow = it },
                high = largeHigh, onHigh = { largeHigh = it },
            )
            canopySection(
                title = "Full Canopy",
                description = "Wires Up - 2m × 0.5m",
                low = fullLow, onLow = { fullLow = it },
                high = fullHigh, onHigh = { fullHigh = it },
            )

            item { SectionHeader("Example Calculation", onLight = true) }
            item {
                VineyardCard {
                    val rowSpacing = 2.8
                    val per100m = parseRate(mediumLow)
                    val perHa = CanopyWaterRates.litresPerHa(per100m, rowSpacing)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Medium / Low Density", fontSize = 12.sp, color = vine.textSecondary)
                            Text(
                                "${fmt(per100m)} L/100m",
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                            )
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("@ 2.8m row spacing", fontSize = 12.sp, color = vine.textSecondary)
                            Text(
                                "${fmt(perHa)} L/ha",
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Bold,
                                color = VineColors.DarkGreen,
                            )
                        }
                    }
                }
            }
            item {
                Text(
                    "L/ha = (L per 100m) × 100 ÷ Row Spacing (m)",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
            }

            item {
                VineyardCard {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Filled.RestartAlt,
                            contentDescription = null,
                            tint = VineColors.Destructive,
                        )
                        Text(
                            "Reset to Defaults",
                            color = VineColors.Destructive,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier
                                .weight(1f)
                                .clickable { showResetDialog = true },
                        )
                    }
                }
            }

            savedConfirmation?.let { msg ->
                item {
                    Text(
                        msg,
                        fontSize = 13.sp,
                        color = VineColors.DarkGreen,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                    )
                }
            }
        }
    }

    if (showResetDialog) {
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("Reset to Defaults?") },
            text = { Text("This will reset all canopy water rate volumes to their default values.") },
            confirmButton = {
                TextButton(onClick = {
                    val d = CanopyWaterRates.defaults
                    smallLow = numText(d.smallLow); smallHigh = numText(d.smallHigh)
                    mediumLow = numText(d.mediumLow); mediumHigh = numText(d.mediumHigh)
                    largeLow = numText(d.largeLow); largeHigh = numText(d.largeHigh)
                    fullLow = numText(d.fullLow); fullHigh = numText(d.fullHigh)
                    store.save(d)
                    savedConfirmation = "Reset to defaults"
                    showResetDialog = false
                }) { Text("Reset", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { showResetDialog = false }) { Text("Cancel") }
            },
        )
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.canopySection(
    title: String,
    description: String,
    low: String,
    onLow: (String) -> Unit,
    high: String,
    onHigh: (String) -> Unit,
) {
    item(key = "header-$title") { SectionHeader(title, onLight = true) }
    item(key = "card-$title") {
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    RateField(
                        label = "Low Density",
                        value = low,
                        onValueChange = onLow,
                        modifier = Modifier.weight(1f),
                    )
                    RateField(
                        label = "High Density",
                        value = high,
                        onValueChange = onHigh,
                        modifier = Modifier.weight(1f),
                    )
                }
                CanopyDescription(description)
            }
        }
    }
}

@Composable
private fun CanopyDescription(text: String) {
    val vine = LocalVineColors.current
    Text(text, fontSize = 12.sp, color = vine.textSecondary)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RateField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        suffix = { Text("L/100m", fontSize = 12.sp) },
        singleLine = true,
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
            keyboardType = KeyboardType.Decimal,
        ),
        modifier = modifier,
    )
}

private fun parseRate(text: String): Double = text.trim().replace(',', '.').toDoubleOrNull() ?: 0.0

private fun fmt(value: Double): String = String.format(Locale.US, "%.0f", value)

/** Renders a stored Double as an editable string, dropping a trailing ".0". */
private fun numText(value: Double): String {
    if (value == value.toLong().toDouble()) return value.toLong().toString()
    return value.toString()
}
