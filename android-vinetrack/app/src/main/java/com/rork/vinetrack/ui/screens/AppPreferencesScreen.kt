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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rork.vinetrack.data.AppPreferences
import com.rork.vinetrack.data.AppPreferencesStore
import com.rork.vinetrack.data.DisplayMode
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale
import java.util.TimeZone

/**
 * Device-local app preferences — appearance/display mode, in-field trip & row
 * tracking, auto photo prompt, AI suggestions and timezone. Mirrors the iOS
 * `PreferencesHubView`. Display Mode drives the app theme live; everything is
 * persisted on this device only via [AppPreferencesStore].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppPreferencesScreen(
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { AppPreferencesStore(context) }
    var prefs by remember { mutableStateOf(store.load()) }
    var showTimezonePicker by remember { mutableStateOf(false) }

    fun update(transform: (AppPreferences) -> AppPreferences) {
        val next = transform(prefs)
        prefs = next
        store.save(next)
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Preferences") },
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
            // Appearance
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Appearance", onLight = true)
                VineyardCard {
                    Text("Display Mode", color = vine.textPrimary, fontWeight = FontWeight.Medium)
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        DisplayMode.entries.forEach { mode ->
                            ModeChip(
                                label = mode.label,
                                selected = prefs.displayMode == mode,
                                modifier = Modifier.weight(1f),
                                onClick = { update { it.copy(displayMode = mode) } },
                            )
                        }
                    }
                }
            }

            // Trip & Row Tracking
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Trip & Row Tracking", onLight = true)
                VineyardCard {
                    ToggleRowPref(
                        label = "Row Tracking",
                        subtitle = "Show in-field row guidance during an active trip.",
                        value = prefs.rowTrackingEnabled,
                        onChange = { v -> update { it.copy(rowTrackingEnabled = v) } },
                    )
                    RowDividerPref(vine.cardBorder)
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Tracking Interval", color = vine.textPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                        Text(String.format(Locale.US, "%.1f s", prefs.rowTrackingInterval), color = vine.textSecondary, fontWeight = FontWeight.SemiBold)
                    }
                    Slider(
                        value = prefs.rowTrackingInterval.toFloat(),
                        onValueChange = { v -> update { it.copy(rowTrackingInterval = roundHalf(v)) } },
                        valueRange = 0.5f..10.0f,
                        steps = 18,
                    )
                    RowDividerPref(vine.cardBorder)
                    ToggleRowPref(
                        label = "Keep screen awake during trips",
                        subtitle = "May use more battery while a trip is running.",
                        value = prefs.keepScreenAwake,
                        onChange = { v -> update { it.copy(keepScreenAwake = v) } },
                    )
                }
                Text(
                    "Controls how often GPS samples are recorded during an active trip and whether row guidance is shown in-field.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            // Photos
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Photos", onLight = true)
                VineyardCard {
                    ToggleRowPref(
                        label = "Auto Photo Prompt",
                        subtitle = "Prompt to attach a photo after dropping repair or growth pins.",
                        value = prefs.autoPhotoPrompt,
                        onChange = { v -> update { it.copy(autoPhotoPrompt = v) } },
                    )
                }
            }

            // AI Suggestions
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("AI Suggestions", onLight = true)
                VineyardCard {
                    ToggleRowPref(
                        label = "Enable AI Suggestions",
                        subtitle = "Optional helper suggestions across the app.",
                        value = prefs.aiSuggestionsEnabled,
                        onChange = { v -> update { it.copy(aiSuggestionsEnabled = v) } },
                    )
                }
                Text(
                    "AI suggestions are optional and must be checked against current product labels, permits, SDS, and local regulations before use.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            // Regional
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Regional", onLight = true)
                VineyardCard {
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable { showTimezonePicker = true }.padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(Icons.Filled.Public, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(20.dp))
                        Text("Timezone", color = vine.textPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                        Text(
                            prefs.timezone,
                            color = vine.textSecondary,
                            fontSize = 13.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }

    if (showTimezonePicker) {
        TimezonePickerDialog(
            selected = prefs.timezone,
            onSelect = { id -> update { it.copy(timezone = id) }; showTimezonePicker = false },
            onDismiss = { showTimezonePicker = false },
        )
    }
}

private fun roundHalf(value: Float): Double = (Math.round(value * 2f) / 2.0).coerceIn(0.5, 10.0)

@Composable
private fun ModeChip(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) VineColors.Primary else vine.cardBorder.copy(alpha = 0.4f))
            .clickable { onClick() }
            .padding(vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (selected) androidx.compose.ui.graphics.Color.White else vine.textPrimary,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            fontSize = 14.sp,
        )
    }
}

@Composable
private fun ToggleRowPref(label: String, subtitle: String, value: Boolean, onChange: (Boolean) -> Unit) {
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

@Composable
private fun RowDividerPref(color: androidx.compose.ui.graphics.Color) {
    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(color))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimezonePickerDialog(selected: String, onSelect: (String) -> Unit, onDismiss: () -> Unit) {
    val vine = LocalVineColors.current
    var query by remember { mutableStateOf("") }
    val all = remember { TimeZone.getAvailableIDs().toList().sorted() }
    val filtered = remember(query) {
        if (query.isBlank()) all
        else all.filter { it.contains(query, ignoreCase = true) }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(vine.appBackground)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Timezone", color = vine.textPrimary, fontWeight = FontWeight.Bold, fontSize = 20.sp, modifier = Modifier.weight(1f))
                Text("Done", color = VineColors.Primary, fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable { onDismiss() }.padding(8.dp))
            }
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                singleLine = true,
                placeholder = { Text("Search timezones") },
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            )
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(filtered, key = { it }) { id ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(id) }
                            .padding(vertical = 12.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(id, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        if (id == selected) {
                            Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(18.dp))
                        }
                    }
                }
            }
        }
    }
}
