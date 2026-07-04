package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.NSWSeedError
import com.rork.vinetrack.data.SoilProfileRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.BackendSoilProfile
import com.rork.vinetrack.data.model.IrrigationSoilClass
import com.rork.vinetrack.data.model.NSWSeedSoilSuggestion
import com.rork.vinetrack.data.model.SoilClassDefault
import com.rork.vinetrack.data.model.SoilProfileUpsert
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Android parity for the iOS `SoilProfileEditorSheet`. Manual soil profile
 * editor for a paddock (or the vineyard-level fallback used by Whole Vineyard
 * mode). Pre-fills values from the selected soil class, computes derived
 * root-zone capacity / readily available water, and — for Australian vineyards
 * editing a specific block — offers an "Fetch soil from NSW SEED" lookup that
 * persists through the same upsert RPC.
 *
 * Writes go through [SoilProfileRepository], matching the iOS RPC contract.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SoilProfileEditorSheet(
    vineyardId: String,
    paddockId: String?,
    paddockName: String,
    vineyardCountry: String?,
    canEdit: Boolean,
    onSaved: (BackendSoilProfile?) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val repo = remember { SoilProfileRepository(SessionStore(context)) }
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    val isVineyardLevel = paddockId == null
    val isAustralian = remember(vineyardCountry) {
        val c = vineyardCountry?.trim()?.lowercase().orEmpty()
        c == "au" || c == "aus" || c == "australia"
    }
    val showNSWSeed = canEdit && !isVineyardLevel && isAustralian

    var defaults by remember { mutableStateOf<List<SoilClassDefault>>(emptyList()) }
    var existing by remember { mutableStateOf<BackendSoilProfile?>(null) }

    var selectedClass by remember { mutableStateOf(IrrigationSoilClass.Unknown) }
    var awcText by remember { mutableStateOf("") }
    var rootDepthText by remember { mutableStateOf("") }
    var depletionText by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }

    var isLoading by remember { mutableStateOf(true) }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var showDeleteConfirm by remember { mutableStateOf(false) }

    var isFetchingSeed by remember { mutableStateOf(false) }
    var seedMessage by remember { mutableStateOf<String?>(null) }
    var seedError by remember { mutableStateOf<String?>(null) }
    var seedSuggestion by remember { mutableStateOf<NSWSeedSoilSuggestion?>(null) }
    var appliedSeed by remember { mutableStateOf<NSWSeedSoilSuggestion?>(null) }
    var manualEditsSinceSeed by remember { mutableStateOf(false) }

    fun currentDefault(): SoilClassDefault? =
        defaults.firstOrNull { it.irrigationSoilClass == selectedClass.raw }

    fun labelFor(cls: IrrigationSoilClass): String =
        defaults.firstOrNull { it.irrigationSoilClass == cls.raw }?.label ?: cls.fallbackLabel

    val orderedClasses: List<IrrigationSoilClass> = remember(defaults) {
        if (defaults.isEmpty()) IrrigationSoilClass.entries.toList()
        else defaults.sortedBy { it.sortOrder }.mapNotNull { it.soilClass }
    }

    fun applyDefaultsForClass(fillEmptyOnly: Boolean = false) {
        val def = currentDefault() ?: return
        if (!fillEmptyOnly || awcText.isBlank()) awcText = fmt0(def.defaultAwcMmPerM)
        if (!fillEmptyOnly || rootDepthText.isBlank()) rootDepthText = fmt2(def.defaultRootDepthM)
        if (!fillEmptyOnly || depletionText.isBlank()) depletionText = fmt0(def.defaultAllowedDepletionPercent)
    }

    fun applyExistingOrDefaults() {
        val e = existing
        if (e != null) {
            selectedClass = e.typedSoilClass ?: IrrigationSoilClass.Unknown
            awcText = e.availableWaterCapacityMmPerM?.let { fmt0(it) } ?: ""
            rootDepthText = e.effectiveRootDepthM?.let { fmt2(it) } ?: ""
            depletionText = e.managementAllowedDepletionPercent?.let { fmt0(it) } ?: ""
            notes = e.manualNotes ?: ""
            if (awcText.isBlank() || rootDepthText.isBlank() || depletionText.isBlank()) {
                applyDefaultsForClass(fillEmptyOnly = true)
            }
        } else {
            selectedClass = IrrigationSoilClass.Unknown
            applyDefaultsForClass()
        }
    }

    LaunchedEffect(vineyardId, paddockId) {
        isLoading = true
        errorMessage = null
        try {
            defaults = repo.fetchSoilClassDefaults()
            existing = if (paddockId != null) {
                repo.fetchPaddockSoilProfile(paddockId)
            } else {
                repo.fetchVineyardDefaultSoilProfile(vineyardId)
            }
            applyExistingOrDefaults()
        } catch (e: Exception) {
            errorMessage = "Failed to load soil profile: ${e.message ?: "Unknown error"}"
        } finally {
            isLoading = false
        }
    }

    val rootZoneCapacity: Double? = run {
        val awc = parseOrNull(awcText)
        val depth = parseOrNull(rootDepthText)
        if (awc != null && depth != null && awc > 0 && depth > 0) awc * depth else null
    }
    val readilyAvailable: Double? = run {
        val rzc = rootZoneCapacity
        val depl = parseOrNull(depletionText)
        if (rzc != null && depl != null && depl > 0) rzc * (depl / 100.0) else null
    }

    fun upsertFor(suggestion: NSWSeedSoilSuggestion?): SoilProfileUpsert {
        val s = suggestion
        return if (s != null) {
            SoilProfileUpsert(
                paddockId = paddockId,
                vineyardId = if (paddockId == null) vineyardId else null,
                irrigationSoilClass = selectedClass.raw,
                availableWaterCapacityMmPerM = parseOrNull(awcText),
                effectiveRootDepthM = parseOrNull(rootDepthText),
                managementAllowedDepletionPercent = parseOrNull(depletionText),
                soilLandscape = s.soilLandscape,
                soilLandscapeCode = s.soilLandscapeCode ?: s.sourceFeatureId,
                australianSoilClassification = s.australianSoilClassification,
                australianSoilClassificationCode = s.australianSoilClassificationCode,
                landSoilCapability = s.landSoilCapability,
                landSoilCapabilityClass = s.landSoilCapabilityClass,
                soilDescription = s.sourceName,
                confidence = s.confidence,
                isManualOverride = false,
                manualNotes = notes.trim().ifBlank { null },
                source = "nsw_seed",
                sourceProvider = "nsw_seed",
                sourceDataset = s.sourceDataset ?: "SoilsNearMe_Combined",
                sourceFeatureId = s.sourceFeatureId,
                sourceName = s.sourceName,
                countryCode = s.countryCode ?: "AU",
                regionCode = s.regionCode ?: "NSW",
                modelVersion = s.modelVersion ?: SoilProfileUpsert.CURRENT_MODEL_VERSION,
            )
        } else {
            SoilProfileUpsert(
                paddockId = paddockId,
                vineyardId = if (paddockId == null) vineyardId else null,
                irrigationSoilClass = selectedClass.raw,
                availableWaterCapacityMmPerM = parseOrNull(awcText),
                effectiveRootDepthM = parseOrNull(rootDepthText),
                managementAllowedDepletionPercent = parseOrNull(depletionText),
                confidence = "manual",
                isManualOverride = true,
                manualNotes = notes.trim().ifBlank { null },
                source = "manual",
                sourceProvider = "manual",
            )
        }
    }

    fun save() {
        if (!canEdit) return
        scope.launch {
            isSaving = true
            errorMessage = null
            try {
                val seed = appliedSeed
                val payload = if (seed != null && !manualEditsSinceSeed) upsertFor(seed) else upsertFor(null)
                val saved = repo.upsertSoilProfile(payload)
                onSaved(saved)
                sheetState.hide()
                onDismiss()
            } catch (e: Exception) {
                errorMessage = e.message ?: "Failed to save soil profile."
            } finally {
                isSaving = false
            }
        }
    }

    fun deleteProfile() {
        if (!canEdit) return
        scope.launch {
            try {
                if (paddockId != null) repo.deleteSoilProfile(paddockId)
                else repo.deleteVineyardDefaultSoilProfile(vineyardId)
                existing = null
                onSaved(null)
                sheetState.hide()
                onDismiss()
            } catch (e: Exception) {
                errorMessage = e.message ?: "Failed to reset soil profile."
            }
        }
    }

    fun fetchFromSeed() {
        if (!canEdit || paddockId == null || isFetchingSeed) return
        scope.launch {
            isFetchingSeed = true
            seedError = null
            seedMessage = null
            seedSuggestion = null
            try {
                val result = repo.lookupNSWSeedSoil(vineyardId, paddockId, persist = true)
                if (result.found && result.suggestion != null) {
                    val s = result.suggestion
                    seedSuggestion = s
                    IrrigationSoilClass.fromRaw(s.irrigationSoilClass)?.let {
                        selectedClass = it
                        applyDefaultsForClass()
                    }
                    appliedSeed = s
                    manualEditsSinceSeed = false
                } else {
                    seedMessage = result.message
                        ?: "No NSW SEED soil match found at this block's centroid."
                }
            } catch (e: NSWSeedError) {
                seedError = e.message
            } catch (e: Exception) {
                seedError = "NSW SEED lookup failed: ${e.message ?: "Unknown error"}"
            } finally {
                isFetchingSeed = false
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = vine.appBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 680.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Header
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    if (isVineyardLevel) "Whole Vineyard Soil" else "Soil Profile",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) { Text("Close") }
            }

            if (isLoading) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    Box(Modifier.size(10.dp))
                    Text("Loading soil profile…", fontSize = 14.sp, color = vine.textSecondary)
                }
            } else {
                // Soil class
                SectionLabel("Soil class")
                var expanded by remember { mutableStateOf(false) }
                ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { if (canEdit) expanded = it }) {
                    OutlinedTextField(
                        value = labelFor(selectedClass),
                        onValueChange = {},
                        readOnly = true,
                        enabled = canEdit,
                        label = { Text("Class") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        orderedClasses.forEach { cls ->
                            DropdownMenuItem(
                                text = { Text(labelFor(cls)) },
                                onClick = {
                                    if (appliedSeed != null) manualEditsSinceSeed = true
                                    selectedClass = cls
                                    applyDefaultsForClass()
                                    expanded = false
                                },
                            )
                        }
                    }
                }
                currentDefault()?.description?.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
                if (!canEdit) {
                    Text(
                        "Read-only: only Owner or Manager can edit the soil profile.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }

                // Soil water values
                SectionLabel("Soil water values")
                ValueField("Available water (mm/m)", awcText, canEdit, "e.g. 150") {
                    if (appliedSeed != null) manualEditsSinceSeed = true
                    awcText = it
                }
                ValueField("Effective root depth (m)", rootDepthText, canEdit, "e.g. 0.6") {
                    if (appliedSeed != null) manualEditsSinceSeed = true
                    rootDepthText = it
                }
                ValueField("Allowed depletion (%)", depletionText, canEdit, "e.g. 45") {
                    if (appliedSeed != null) manualEditsSinceSeed = true
                    depletionText = it
                }
                Text(
                    "Defaults are pre-filled from the selected soil class. Override with your own observations where possible.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )

                // Derived
                if (rootZoneCapacity != null || readilyAvailable != null) {
                    SectionLabel("Derived")
                    rootZoneCapacity?.let { DerivedRow("Root-zone capacity", fmt0(it) + " mm") }
                    readilyAvailable?.let { DerivedRow("Readily available water", fmt0(it) + " mm") }
                }

                // Notes
                SectionLabel("Notes")
                OutlinedTextField(
                    value = notes,
                    onValueChange = { notes = it },
                    enabled = canEdit,
                    label = { Text("Site-specific notes (optional)") },
                    minLines = 2,
                    maxLines = 5,
                    modifier = Modifier.fillMaxWidth(),
                )

                // NSW SEED
                if (showNSWSeed) {
                    HorizontalDivider(color = vine.cardBorder)
                    SectionLabel("NSW SEED soil lookup")
                    OutlinedButton(
                        onClick = { fetchFromSeed() },
                        enabled = !isFetchingSeed && !isSaving,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (isFetchingSeed) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Filled.Download, contentDescription = null, modifier = Modifier.size(18.dp))
                        }
                        Box(Modifier.size(8.dp))
                        Text(if (isFetchingSeed) "Fetching from NSW SEED…" else "Fetch soil from NSW SEED")
                    }
                    Text(
                        "Estimates the soil profile from the NSW SEED Soil Landscapes layer using your block centroid. The NSW SEED API key stays on the server.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                    seedMessage?.let { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
                    seedError?.let {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(15.dp))
                            Box(Modifier.size(6.dp))
                            Text(it, fontSize = 12.sp, color = VineColors.Warning)
                        }
                    }
                    seedSuggestion?.let { s -> SeedSuggestionCard(s) { seedSuggestion = null } }
                }

                // Reset
                if (existing != null && canEdit) {
                    HorizontalDivider(color = vine.cardBorder)
                    OutlinedButton(
                        onClick = { showDeleteConfirm = true },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.DeleteOutline, contentDescription = null, tint = VineColors.VineRed, modifier = Modifier.size(18.dp))
                        Box(Modifier.size(8.dp))
                        Text("Reset soil profile", color = VineColors.VineRed)
                    }
                }

                Text(
                    "Soil information is estimated and may not reflect site-specific vineyard soil conditions. Adjust soil class and water-holding values using your own soil knowledge where needed.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )

                errorMessage?.let {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(16.dp))
                        Box(Modifier.size(6.dp))
                        Text(it, fontSize = 12.sp, color = VineColors.Warning)
                    }
                }

                // Save
                androidx.compose.material3.Button(
                    onClick = { save() },
                    enabled = canEdit && !isSaving && !isLoading,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (isSaving) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                        Box(Modifier.size(8.dp))
                        Text("Save")
                    }
                }
            }
        }
    }

    if (showDeleteConfirm) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Reset soil profile for $paddockName?") },
            text = { Text("This clears the saved soil profile and reverts to soil-class defaults.") },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirm = false
                    deleteProfile()
                }) { Text("Reset", color = VineColors.VineRed) }
            },
            dismissButton = { TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    val vine = LocalVineColors.current
    Text(
        text.uppercase(Locale.getDefault()),
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        color = vine.textSecondary,
    )
}

@Composable
private fun ValueField(
    label: String,
    value: String,
    enabled: Boolean,
    placeholder: String,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        enabled = enabled,
        singleLine = true,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun DerivedRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = 14.sp, color = vine.textPrimary)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
    }
}

@Composable
private fun SeedSuggestionCard(s: NSWSeedSoilSuggestion, onClear: () -> Unit) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
        SeedRow("Soil landscape", s.sourceName ?: s.soilLandscape)
        SeedRow("SALIS code", s.soilLandscapeCode ?: s.sourceFeatureId)
        SeedRow("Australian Soil Classification", s.australianSoilClassification)
        s.landSoilCapability?.let { lsc ->
            val text = s.landSoilCapabilityClass?.let { "$lsc (class $it)" } ?: lsc
            SeedRow("Land and Soil Capability", text)
        }
        IrrigationSoilClass.fromRaw(s.irrigationSoilClass)?.let {
            SeedRow("Suggested irrigation class", it.fallbackLabel)
        }
        s.confidence?.takeIf { it.isNotBlank() }?.let {
            SeedRow("Confidence", it.replaceFirstChar { c -> c.uppercase() })
        }
        if (s.matchedKeywords.isNotEmpty()) {
            SeedRow("Matched terms", s.matchedKeywords.joinToString(", "))
        }
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = onClear) {
                Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.size(16.dp))
                Box(Modifier.size(4.dp))
                Text("Dismiss")
            }
        }
        Text(
            s.disclaimer
                ?: "Soil information is estimated from NSW SEED mapping and may not reflect site-specific vineyard soil conditions.",
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun SeedRow(label: String, value: String?) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(
            value?.takeIf { it.isNotBlank() } ?: "Not available",
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = if (value.isNullOrBlank()) vine.textSecondary else vine.textPrimary,
        )
    }
}

private fun parseOrNull(text: String): Double? {
    val cleaned = text.replace(",", ".").trim()
    if (cleaned.isEmpty()) return null
    return cleaned.toDoubleOrNull()
}

private fun fmt0(value: Double): String = String.format(Locale.US, "%.0f", value)
private fun fmt2(value: Double): String = String.format(Locale.US, "%.2f", value)
