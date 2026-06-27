package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Map
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
import androidx.compose.runtime.mutableStateMapOf
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
import com.rork.vinetrack.data.BunchWeightDefaultsStore
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlin.math.roundToInt

/**
 * Yield Settings — per-block default average bunch weight (grams), mirroring the
 * iOS `YieldSettingsView`. These values seed yield estimation calculations and
 * are persisted on-device via [BunchWeightDefaultsStore]
 * (matching `AppSettings.defaultBlockBunchWeightsGrams`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun YieldSettingsScreen(state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { BunchWeightDefaultsStore(context) }
    val fmt = state.regionFormatter

    val paddocks = state.paddocks
    val weights = remember { mutableStateMapOf<String, Double>().apply { putAll(store.load()) } }
    var editing by remember { mutableStateOf<Paddock?>(null) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Yield Settings") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                SectionHeader(title = "Bunch Weight per Block", onLight = true)
            }

            if (paddocks.isEmpty()) {
                item {
                    VineyardCard {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Filled.Map, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.width(28.dp))
                            Text("No Blocks", color = vine.textPrimary, fontWeight = FontWeight.SemiBold)
                            Text(
                                "Add blocks in Vineyard Setup to set bunch weights.",
                                color = vine.textSecondary, fontSize = 13.sp,
                            )
                        }
                    }
                }
            } else {
                item {
                    VineyardCard {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            paddocks.forEach { paddock ->
                                BunchWeightRow(
                                    paddock = paddock,
                                    grams = weights[paddock.id] ?: BunchWeightDefaultsStore.DEFAULT_BUNCH_WEIGHT_GRAMS,
                                    areaText = paddock.areaHectares.takeIf { it > 0 }?.let { fmt.formatArea(it) },
                                    onClick = { editing = paddock },
                                )
                            }
                        }
                    }
                }
                item {
                    Text(
                        "Set the average bunch weight (in grams) for each block. These values are used in yield estimation calculations.",
                        color = vine.textSecondary, fontSize = 12.sp,
                    )
                }
            }
        }
    }

    editing?.let { paddock ->
        BunchWeightEditDialog(
            paddock = paddock,
            currentGrams = weights[paddock.id] ?: BunchWeightDefaultsStore.DEFAULT_BUNCH_WEIGHT_GRAMS,
            onDismiss = { editing = null },
            onSave = { grams ->
                store.setWeightGrams(paddock.id, grams)
                weights[paddock.id] = grams
                editing = null
            },
        )
    }
}

@Composable
private fun BunchWeightRow(
    paddock: Paddock,
    grams: Double,
    areaText: String?,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(paddock.name, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            val vines = paddock.effectiveVineCount
            val detail = buildList {
                areaText?.let { add(it) }
                if (vines > 0) add("$vines vines")
            }.joinToString(" • ")
            if (detail.isNotEmpty()) {
                Text(detail, color = vine.textSecondary, fontSize = 12.sp)
            }
        }
        Text(
            "${grams.roundToInt()} g",
            color = VineColors.LeafGreen, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.width(8.dp))
        Icon(Icons.Filled.Edit, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.width(16.dp))
    }
}

@Composable
private fun BunchWeightEditDialog(
    paddock: Paddock,
    currentGrams: Double,
    onDismiss: () -> Unit,
    onSave: (Double) -> Unit,
) {
    var text by remember { mutableStateOf(currentGrams.roundToInt().toString()) }
    val grams = text.toDoubleOrNull()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Bunch Weight") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Enter the default bunch weight in grams for ${paddock.name}.", fontSize = 13.sp)
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it.filter { c -> c.isDigit() || c == '.' } },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = grams != null && grams > 0,
                onClick = { grams?.let { onSave(it) } },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
