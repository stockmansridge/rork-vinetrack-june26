package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.AlertPreferences
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale

/**
 * Per-vineyard alert & notification preferences, mirroring the iOS
 * `AlertSettingsView`. Owner/manager only — the editor is read-only for other
 * roles (writes are also enforced server-side via RLS).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlertSettingsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onOpenWeatherData: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val canEdit = state.currentRole == "owner" || state.currentRole == "manager"

    LaunchedEffect(state.selectedVineyardId) {
        if (state.alertPreferences?.vineyardId != state.selectedVineyardId) {
            vm.loadAlertPreferences()
        }
    }

    // Local editable draft; seeded from loaded prefs.
    var draft by remember(state.alertPreferences?.vineyardId) {
        mutableStateOf(state.alertPreferences)
    }
    LaunchedEffect(state.alertPreferences) {
        if (draft == null) draft = state.alertPreferences
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Alerts & Notifications") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    val current = draft
                    if (canEdit && current != null) {
                        TextButton(
                            onClick = { vm.saveAlertPreferences(current) {} },
                            enabled = !state.alertPrefsBusy,
                        ) {
                            if (state.alertPrefsBusy) {
                                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            } else {
                                Text("Save", fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        val prefs = draft
        if (prefs == null) {
            Box(modifier = Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Pins
            AlertSection("Pins", "Aged pin alerts track unresolved repair and growth pins. Notified when pins remain unresolved longer than the threshold.") {
                ToggleRow("Aged pin alerts", prefs.agedPinAlertsEnabled, canEdit) {
                    draft = prefs.copy(agedPinAlertsEnabled = it)
                }
                StepperRow(
                    "Age threshold",
                    "${prefs.agedPinDays} days",
                    enabled = canEdit && prefs.agedPinAlertsEnabled,
                    onDec = { draft = prefs.copy(agedPinDays = (prefs.agedPinDays - 1).coerceIn(1, 60)) },
                    onInc = { draft = prefs.copy(agedPinDays = (prefs.agedPinDays + 1).coerceIn(1, 60)) },
                )
            }

            // Irrigation
            AlertSection("Irrigation", "Irrigation alerts use forecast ET, forecast rain and your configured irrigation data to estimate deficit over the forecast window.") {
                ToggleRow("Irrigation alerts", prefs.irrigationAlertsEnabled, canEdit) {
                    draft = prefs.copy(irrigationAlertsEnabled = it)
                }
                StepperRow(
                    "Forecast window",
                    "${prefs.irrigationForecastDays} days",
                    enabled = canEdit && prefs.irrigationAlertsEnabled,
                    onDec = { draft = prefs.copy(irrigationForecastDays = (prefs.irrigationForecastDays - 1).coerceIn(1, 14)) },
                    onInc = { draft = prefs.copy(irrigationForecastDays = (prefs.irrigationForecastDays + 1).coerceIn(1, 14)) },
                )
                NumberRow("Deficit threshold (mm)", prefs.irrigationDeficitThresholdMm, canEdit && prefs.irrigationAlertsEnabled) {
                    draft = prefs.copy(irrigationDeficitThresholdMm = it)
                }
            }

            // Weather
            AlertSection("Weather", "Weather alerts use forecast rain, wind, heat and frost thresholds. Tapping a weather alert opens the Irrigation Advisor.") {
                ToggleRow("Weather alerts", prefs.weatherAlertsEnabled, canEdit) {
                    draft = prefs.copy(weatherAlertsEnabled = it)
                }
                val wEnabled = canEdit && prefs.weatherAlertsEnabled
                NumberRow("Rain (mm)", prefs.rainAlertThresholdMm, wEnabled) { draft = prefs.copy(rainAlertThresholdMm = it) }
                NumberRow("Wind (km/h)", prefs.windAlertThresholdKmh, wEnabled) { draft = prefs.copy(windAlertThresholdKmh = it) }
                NumberRow("Frost below (\u00B0C)", prefs.frostAlertThresholdC, wEnabled) { draft = prefs.copy(frostAlertThresholdC = it) }
                NumberRow("Heat above (\u00B0C)", prefs.heatAlertThresholdC, wEnabled) { draft = prefs.copy(heatAlertThresholdC = it) }
            }

            // Spray
            AlertSection("Spray", "Reminders for scheduled spray records due today or tomorrow.") {
                ToggleRow("Spray job reminders", prefs.sprayJobRemindersEnabled, canEdit) {
                    draft = prefs.copy(sprayJobRemindersEnabled = it)
                }
            }

            // Disease risk
            AlertSection("Disease risk", "Disease alerts use forecast humidity, dew point, rainfall and temperature with an estimated wetness proxy (rain, RH \u2265 90%, or temperature within 2\u00B0C of dew point). They are not a substitute for measured leaf wetness; if a measured sensor is added later, it can override the proxy per vineyard.") {
                ToggleRow("Disease risk alerts", prefs.diseaseAlertsEnabled, canEdit) {
                    draft = prefs.copy(diseaseAlertsEnabled = it)
                }
                val dEnabled = canEdit && prefs.diseaseAlertsEnabled
                ToggleRow("Downy mildew", prefs.diseaseDownyEnabled, dEnabled) { draft = prefs.copy(diseaseDownyEnabled = it) }
                ToggleRow("Powdery mildew", prefs.diseasePowderyEnabled, dEnabled) { draft = prefs.copy(diseasePowderyEnabled = it) }
                ToggleRow("Botrytis", prefs.diseaseBotrytisEnabled, dEnabled) { draft = prefs.copy(diseaseBotrytisEnabled = it) }
                if (onOpenWeatherData != null) WeatherSourceRow(onClick = onOpenWeatherData)
            }

            // Push
            AlertSection("Push", "Push notifications are coming later. In-app alerts are active and update on app launch and pull to refresh.") {
                ToggleRow("Push notifications", prefs.pushEnabled, enabled = false) {}
            }

            if (!canEdit) {
                Text(
                    "Only the vineyard owner or manager can change alert preferences.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
            state.alertPrefsError?.let {
                Text(it, fontSize = 12.sp, color = VineColors.Destructive)
            }
        }
    }
}

@Composable
private fun AlertSection(title: String, footer: String, content: @Composable () -> Unit) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionHeader(title, onLight = true)
        VineyardCard { content() }
        Text(footer, fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun WeatherSourceRow(onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Filled.WbSunny,
            contentDescription = null,
            tint = VineColors.Warning,
            modifier = Modifier.size(20.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text("Weather source", fontSize = 14.sp, color = vine.textPrimary)
            Text("Forecast source & sensors", fontSize = 12.sp, color = vine.textSecondary)
        }
        Text("Manage", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
    }
}

@Composable
private fun ToggleRow(label: String, value: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = if (enabled) vine.textPrimary else vine.textSecondary, modifier = Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = if (enabled) onChange else null, enabled = enabled)
    }
}

@Composable
private fun StepperRow(label: String, value: String, enabled: Boolean, onDec: () -> Unit, onInc: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(label, color = if (enabled) vine.textPrimary else vine.textSecondary)
            Text(value, fontSize = 12.sp, color = vine.textSecondary)
        }
        IconButton(onClick = onDec, enabled = enabled) { Text("\u2212", fontSize = 20.sp, color = vine.textPrimary) }
        IconButton(onClick = onInc, enabled = enabled) { Text("+", fontSize = 20.sp, color = vine.textPrimary) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NumberRow(label: String, value: Double, enabled: Boolean, onChange: (Double) -> Unit) {
    val vine = LocalVineColors.current
    var text by remember(value) { mutableStateOf(formatNum(value)) }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = if (enabled) vine.textPrimary else vine.textSecondary, modifier = Modifier.weight(1f))
        OutlinedTextField(
            value = text,
            onValueChange = {
                text = it
                it.replace(",", ".").trim().toDoubleOrNull()?.let(onChange)
            },
            enabled = enabled,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.width(96.dp),
        )
    }
}

private fun formatNum(v: Double): String =
    if (v == v.toLong().toDouble()) v.toLong().toString()
    else String.format(Locale.US, "%.1f", v)
