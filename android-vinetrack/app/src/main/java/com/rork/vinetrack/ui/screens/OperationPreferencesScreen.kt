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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import com.rork.vinetrack.data.OperationPrefs
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.DateFormatSymbols
import java.util.Locale

/**
 * Local operation preferences — season boundaries, E-L confirmation, tank fill
 * timer, fuel cost and yield sampling. Mirrors the iOS `OperationPreferencesView`.
 * Everything is persisted on this device only via [OperationPrefsStore].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OperationPreferencesScreen(
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { OperationPrefsStore(context) }
    var prefs by remember { mutableStateOf(store.load()) }

    fun update(transform: (OperationPrefs) -> OperationPrefs) {
        val next = transform(prefs)
        prefs = next
        store.save(next)
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Operation Preferences") },
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
            // Growing season & E-L
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Growing Season & E-L", onLight = true)
                VineyardCard {
                    MonthRow(
                        label = "Season Start Month",
                        month = prefs.seasonStartMonth,
                        onSelect = { m -> update { it.copy(seasonStartMonth = m, seasonStartDay = it.seasonStartDay.coerceAtMost(maxDay(m))) } },
                    )
                    RowDividerOp(vine.cardBorder)
                    StepperRow(
                        label = "Season Start Day",
                        value = prefs.seasonStartDay,
                        range = 1..maxDay(prefs.seasonStartMonth),
                        onChange = { d -> update { it.copy(seasonStartDay = d) } },
                    )
                    RowDividerOp(vine.cardBorder)
                    ToggleRowOp(
                        label = "Confirm E-L Stage",
                        subtitle = "Prompt to confirm the growth stage before logging.",
                        value = prefs.elConfirmationEnabled,
                        onChange = { v -> update { it.copy(elConfirmationEnabled = v) } },
                    )
                }
                Text(
                    "Season boundaries are used by the E-L growth stage report.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            // Spray / tank
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Spray / Tank", onLight = true)
                VineyardCard {
                    ToggleRowOp(
                        label = "Tank Fill Timer",
                        subtitle = "Show Start/Stop Fill timing on spray trips.",
                        value = prefs.fillTimerEnabled,
                        onChange = { v -> update { it.copy(fillTimerEnabled = v) } },
                    )
                    RowDividerOp(vine.cardBorder)
                    NumberFieldRow(
                        label = "Fuel Cost (per L)",
                        value = if (prefs.fuelCostPerLitre <= 0.0) "" else trimNum(prefs.fuelCostPerLitre),
                        keyboardType = KeyboardType.Decimal,
                        onChange = { t -> update { it.copy(fuelCostPerLitre = t.replace(',', '.').toDoubleOrNull()?.coerceAtLeast(0.0) ?: 0.0) } },
                    )
                }
            }

            // Yield estimation
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Yield Estimation", onLight = true)
                VineyardCard {
                    NumberFieldRow(
                        label = "Samples per Hectare",
                        value = if (prefs.samplesPerHectare <= 0) "" else prefs.samplesPerHectare.toString(),
                        keyboardType = KeyboardType.Number,
                        onChange = { t -> update { it.copy(samplesPerHectare = t.filter { c -> c.isDigit() }.toIntOrNull()?.coerceAtLeast(0) ?: 0) } },
                    )
                }
            }
        }
    }
}

private fun maxDay(month: Int): Int = when (month) {
    1, 3, 5, 7, 8, 10, 12 -> 31
    4, 6, 9, 11 -> 30
    2 -> 29
    else -> 31
}

private fun monthName(month: Int): String =
    DateFormatSymbols(Locale.US).months.getOrElse(month - 1) { "" }

private fun trimNum(v: Double): String =
    if (v == v.toLong().toDouble()) v.toLong().toString()
    else String.format(Locale.US, "%.2f", v).trimEnd('0').trimEnd('.')

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MonthRow(label: String, month: Int, onSelect: (Int) -> Unit) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = true }
                .padding(vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, color = vine.textPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            Text(monthName(month), color = VineColors.Primary, fontWeight = FontWeight.SemiBold)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            (1..12).forEach { m ->
                DropdownMenuItem(
                    text = { Text(monthName(m)) },
                    trailingIcon = { if (m == month) Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Success) },
                    onClick = { onSelect(m); expanded = false },
                )
            }
        }
    }
}

@Composable
private fun StepperRow(label: String, value: Int, range: IntRange, onChange: (Int) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = vine.textPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
        IconButton(onClick = { if (value > range.first) onChange(value - 1) }) {
            Icon(Icons.Filled.Remove, contentDescription = "Decrease", tint = if (value > range.first) VineColors.Primary else vine.textSecondary)
        }
        Text(value.toString(), color = vine.textPrimary, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(28.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        IconButton(onClick = { if (value < range.last) onChange(value + 1) }) {
            Icon(Icons.Filled.Add, contentDescription = "Increase", tint = if (value < range.last) VineColors.Primary else vine.textSecondary)
        }
    }
}

@Composable
private fun ToggleRowOp(label: String, subtitle: String, value: Boolean, onChange: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onChange(!value) }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(label, color = vine.textPrimary, fontWeight = FontWeight.Medium)
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Switch(checked = value, onCheckedChange = onChange)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NumberFieldRow(label: String, value: String, keyboardType: KeyboardType, onChange: (String) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, color = vine.textPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            placeholder = { Text("0") },
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            modifier = Modifier.width(110.dp),
        )
    }
}

@Composable
private fun RowDividerOp(color: androidx.compose.ui.graphics.Color) {
    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(color))
}
