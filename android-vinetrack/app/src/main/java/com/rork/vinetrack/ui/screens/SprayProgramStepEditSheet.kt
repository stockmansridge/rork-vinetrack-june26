package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SprayJobTemplateRepository
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.sprayOperationTypes
import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayProgramStepDraft
import com.rork.vinetrack.data.spray.SprayProgramStepWriteMessages
import com.rork.vinetrack.data.spray.SprayProgramTerminology
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.data.spray.SprayTargetLibrary
import com.rork.vinetrack.data.spray.SprayTargetTag
import com.rork.vinetrack.data.spray.SprayTargetVocabulary
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Editor for one reusable Program Step, whichever side of the wire it lives on
 * — the Android mirror of the iOS `SprayProgramStepEditView`.
 *
 * One editing experience, two persistence targets:
 *
 *  * local  -> the existing `spray_records` template path (offline-capable)
 *  * portal -> the existing `public.spray_jobs` row, UPDATED IN PLACE
 *    (online-only; there is no offline mutation queue for the shared row)
 *
 * Deliberately NOT the spray record form: that screen edits an application
 * that happened — date, weather, tanks applied, cost — and none of those
 * concepts exist on reusable configuration.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SprayProgramStepEditSheet(
    vm: AppViewModel,
    state: AppUiState,
    record: SprayRecord,
    isPortal: Boolean,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    val labels = remember(state.sprayTargetLibrary, state.selectedVineyardId) {
        SprayTargetLibrary.labels(state.sprayTargetLibrary, state.selectedVineyardId)
    }
    var draft by remember {
        mutableStateOf(if (isPortal) null else SprayProgramStepDraft.fromLocal(record, labels))
    }
    var tractors by remember { mutableStateOf<List<SprayJobTemplateRepository.SprayTractor>>(emptyList()) }
    var saving by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }
    var showTargetChooser by remember { mutableStateOf(false) }
    var replacingLineKey by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        vm.refreshSprayTargetLibrary()
        vm.fetchSprayTractors { tractors = it }
        if (isPortal) {
            // Start from the row the SERVER currently holds — raw lines
            // included — so every key the draft does not model round-trips
            // verbatim. Offline, fall back to the mapped cache for viewing;
            // the save stays blocked until connected.
            vm.fetchPortalProgramStep(record.id) { row ->
                draft = if (row != null) {
                    SprayProgramStepDraft.fromPortalRow(row, labels)
                } else {
                    SprayProgramStepDraft.fromLocal(record, labels).copy(isPortalManaged = true)
                }
            }
        }
    }

    // Everything this vineyard could reasonably want to reuse: library entries
    // plus the custom targets already used on its own Program Steps.
    val mergedSteps = remember(state.sprayRecords, state.sprayJobTemplates) {
        SprayProgramLanding.mergedProgramSteps(state.sprayRecords, state.sprayJobTemplates)
    }
    val vineyardTags = remember(state.sprayTargetLibrary, state.selectedVineyardId, mergedSteps, labels) {
        SprayTargetLibrary.customTags(
            state.sprayTargetLibrary,
            state.selectedVineyardId,
            observed = SprayTargetLibrary.observedCustomTags(mergedSteps, labels),
        )
    }

    val requiresConnection = isPortal && !state.isOnline

    fun save() {
        val d = draft ?: return
        d.validationError?.let { saveError = it; return }
        if (requiresConnection) {
            saveError = SprayProgramStepWriteMessages.OFFLINE
            return
        }
        saving = true
        if (isPortal) {
            vm.updateProgramStep(record.id, d.portalPayload(state.currentUserId)) { error ->
                saving = false
                if (error == null) onSaved() else saveError = error
            }
        } else {
            vm.updateSprayRecord(record.id, d.toLocalInput(record)) { ok ->
                saving = false
                if (ok) onSaved() else saveError = "Couldn't save the Program Step. Please try again."
            }
        }
    }

    ModalBottomSheet(onDismissRequest = { if (!saving) onDismiss() }, sheetState = sheetState) {
        val current = draft
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                SprayProgramTerminology.EDIT_PROGRAM_STEP,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            if (isPortal) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = vine.textSecondary,
                        modifier = Modifier.size(14.dp),
                    )
                    Text(
                        SprayProgramTerminology.SYNCED_WITH_ADMIN_PORTAL,
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            if (requiresConnection) {
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(VineColors.Warning.copy(alpha = 0.12f))
                        .padding(12.dp),
                ) {
                    Icon(Icons.Filled.WifiOff, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(18.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            SprayProgramStepWriteMessages.OFFLINE,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        Text(
                            "This Program Step is shared with the Admin Portal, so changes are saved " +
                                "straight to the vineyard's program. You can still view it and plan a " +
                                "spray from it offline.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            if (current == null) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    horizontalArrangement = Arrangement.Center,
                ) {
                    CircularProgressIndicator(color = VineColors.Primary)
                }
            } else {
                // MARK: Name
                OutlinedTextField(
                    value = current.name,
                    onValueChange = { draft = current.copy(name = it) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Program Step name") },
                    singleLine = true,
                )
                current.validationError?.let { error ->
                    Text(error, fontSize = 12.sp, color = VineColors.Warning)
                }

                // MARK: Growth stage
                SectionLabelSPE("Growth Stage")
                if (isPortal) {
                    GrowthStagePicker(
                        selectedCode = current.growthStageCode,
                        onSelect = { draft = current.copy(growthStageCode = it) },
                    )
                    Text(
                        "The stage this step is timed for. \u201CNot stated\u201D is a real answer — " +
                            "a step that doesn't name a stage says so.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                } else {
                    Text(
                        SprayProgramLanding.elStageLabel(record) ?: "Not stated",
                        fontSize = 14.sp,
                        color = vine.textSecondary,
                    )
                    Text(
                        "A local Program Step has no stored growth stage; it's read from the step " +
                            "name, e.g. \u201CEL12 Pre-Flowering\u201D.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }

                // MARK: Targets
                SectionLabelSPE("Targets")
                if (current.normalisedTargets.isEmpty()) {
                    Text("No targets on this step yet.", fontSize = 13.sp, color = vine.textSecondary)
                } else {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        current.normalisedTargets.forEach { tag ->
                            TargetChip(tag = tag) { draft = current.removingTarget(tag) }
                        }
                    }
                }
                TextButton(onClick = { showTargetChooser = true }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                    Text("  Add Target")
                }
                Text(
                    "Targets VineTrack recognises prefill the Spray Calculator. Your vineyard's " +
                        "own targets are stored and reusable across Program Steps here.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )

                // MARK: Products
                SectionLabelSPE("Products")
                if (current.products.isEmpty()) {
                    Text("No products on this step yet.", fontSize = 13.sp, color = vine.textSecondary)
                }
                current.products.forEach { product ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(vine.cardBackground)
                            .padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                product.trimmedName.ifEmpty { "Select a product" },
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            TextButton(onClick = { replacingLineKey = product.lineKey }) {
                                Text("Replace Product", fontSize = 12.sp)
                            }
                            IconButton(onClick = {
                                draft = current.copy(products = current.products.filterNot { it.lineKey == product.lineKey })
                            }) {
                                Icon(
                                    Icons.Filled.Delete,
                                    contentDescription = "Remove ${product.trimmedName.ifEmpty { "product" }}",
                                    tint = VineColors.Destructive,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                        val resolved = product.savedChemicalId != null &&
                            state.savedChemicals.any { it.id == product.savedChemicalId }
                        if (!resolved && product.trimmedName.isNotEmpty()) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(13.dp))
                                Text(
                                    "${product.trimmedName} is not in your Chemical Store",
                                    fontSize = 12.sp,
                                    color = VineColors.Warning,
                                )
                            }
                        }
                        // NO rate entry, and no rate basis — a Program Step says
                        // WHICH product, not what dose: the dose depends on the
                        // canopy on the day and is chosen in the Spray
                        // Calculator against today's registered uses. A stored
                        // legacy rate is still shown, read-only, so nothing
                        // looks thrown away.
                        Text(
                            storedRateSummary(product) ?: "Rate set when planning",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
                TextButton(onClick = {
                    val added = com.rork.vinetrack.data.spray.SprayProgramProductDraft()
                    draft = current.copy(products = current.products + added)
                    replacingLineKey = added.lineKey
                }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                    Text("  Add Product")
                }
                Text(
                    "A step sets which products this spray uses. The label rate, carrier volume, " +
                        "tanks and quantities are chosen when you plan the spray against the canopy " +
                        "on the day.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )

                // MARK: Application
                SectionLabelSPE("Application")
                SimpleDropdown(
                    label = "Method",
                    value = current.operationType ?: "Not set",
                    options = sprayOperationTypes,
                    optionLabel = { it },
                    onSelect = { draft = current.copy(operationType = it) },
                )
                SimpleDropdown(
                    label = "Spray unit",
                    value = state.sprayEquipment.firstOrNull { it.id == current.equipmentId }?.name ?: "Not set",
                    options = listOf<String?>(null) + state.sprayEquipment.map { it.id },
                    optionLabel = { id -> id?.let { eid -> state.sprayEquipment.firstOrNull { it.id == eid }?.name } ?: "Not set" },
                    onSelect = { draft = current.copy(equipmentId = it) },
                )
                if (isPortal && tractors.isNotEmpty()) {
                    // Genuine tractors ONLY — `spray_jobs.tractor_id` is a foreign
                    // key into `public.tractors`, so vineyard machines are never
                    // offered here (exactly as on iOS).
                    SimpleDropdown(
                        label = "Tractor",
                        value = tractors.firstOrNull { it.id == current.tractorId }?.displayName
                            ?: if (current.tractorId != null) "Carried from portal" else "Not set",
                        options = listOf<String?>(null) + tractors.map { it.id },
                        optionLabel = { id -> id?.let { tid -> tractors.firstOrNull { it.id == tid }?.displayName } ?: "Not set" },
                        onSelect = { draft = current.copy(tractorId = it) },
                    )
                } else if (current.tractorId != null) {
                    // The saved tractor identity is carried verbatim — shown so
                    // the operator knows it is there, never silently dropped.
                    Text(
                        "Tractor: " + (tractors.firstOrNull { it.id == current.tractorId }?.displayName ?: "carried"),
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }

                // MARK: Notes
                SectionLabelSPE("Notes")
                OutlinedTextField(
                    value = current.notes,
                    onValueChange = { draft = current.copy(notes = it) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Notes") },
                    minLines = 3,
                )

                Text(
                    "A Program Step is reusable configuration. Spray date, weather, tanks, rows " +
                        "sprayed, operator and cost belong to the sprays you record from it.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )

                saveError?.let { error ->
                    Text(error, fontSize = 12.sp, color = VineColors.Destructive)
                }

                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedButton(onClick = onDismiss, enabled = !saving, modifier = Modifier.weight(1f)) {
                        Text("Cancel")
                    }
                    Button(
                        onClick = { save() },
                        enabled = !saving && current.isValid && !requiresConnection,
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                    ) {
                        if (saving) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                        } else {
                            Text("Save")
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (showTargetChooser) {
        val current = draft
        SprayTargetChooserDialog(
            selected = current?.normalisedTargets.orEmpty(),
            vineyardTargets = vineyardTags,
            onSelect = { tag -> draft = draft?.addingTarget(tag) },
            onCreate = { wording ->
                // Onto the step immediately, and into the vineyard's shared
                // library so the next Program Step offers it. The step keeps
                // the tag even if the library write is refused — the step is
                // what states what the spray is for.
                vm.addCustomSprayTarget(wording) { tag ->
                    tag?.let { draft = draft?.addingTarget(it) }
                }
            },
            onDismiss = { showTargetChooser = false },
        )
    }

    replacingLineKey?.let { lineKey ->
        val current = draft
        val line = current?.products?.firstOrNull { it.lineKey == lineKey }
        if (current != null && line != null) {
            SprayProductPickerDialog(
                state = state,
                currentName = line.trimmedName,
                onPick = { chemical ->
                    draft = current.copy(
                        products = current.products.map {
                            if (it.lineKey == lineKey) it.replacedWith(chemical) else it
                        },
                    )
                    replacingLineKey = null
                },
                onKeepTypedName = {
                    if (line.trimmedName.isNotEmpty()) {
                        draft = current.copy(
                            products = current.products.map {
                                if (it.lineKey == lineKey) it.cleared(line.trimmedName) else it
                            },
                        )
                    }
                    replacingLineKey = null
                },
                onDismiss = { replacingLineKey = null },
            )
        } else {
            replacingLineKey = null
        }
    }
}

/** A stored legacy programme rate, shown read-only. Null when there is none. */
private fun storedRateSummary(product: com.rork.vinetrack.data.spray.SprayProgramProductDraft): String? {
    if (product.rate <= 0) return null
    val basis = if (product.basis == com.rork.vinetrack.data.spray.SprayProductRateBasis.PER_100_LITRES) "/100 L" else "/ha"
    val value = if (product.rate % 1.0 == 0.0) product.rate.toInt().toString() else product.rate.toString()
    return "Stored programme rate: $value ${product.unitRaw}$basis — you'll confirm the applied rate when you plan the spray."
}

@Composable
private fun SectionLabelSPE(text: String) {
    val vine = LocalVineColors.current
    Text(
        text.uppercase(),
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = vine.textSecondary,
    )
}

/** One selected target, as an individually removable chip. */
@Composable
private fun TargetChip(tag: SprayTargetTag, onRemove: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(VineColors.Olive.copy(alpha = 0.12f))
            .padding(start = 10.dp, end = 2.dp, top = 4.dp, bottom = 4.dp),
    ) {
        Text(
            tag.label,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = VineColors.Olive,
        )
        IconButton(onClick = onRemove, modifier = Modifier.size(24.dp)) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Remove ${tag.label}",
                tint = VineColors.Olive,
                modifier = Modifier.size(12.dp),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> SimpleDropdown(
    label: String,
    value: String,
    options: List<T>,
    optionLabel: (T) -> String,
    onSelect: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = value,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(optionLabel(option)) },
                    onClick = { onSelect(option); expanded = false },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GrowthStagePicker(selectedCode: String?, onSelect: (String?) -> Unit) {
    // Match on stage NUMBER so "E-L 12" from the portal selects the same row
    // as "EL12" rather than falling out of the picker — mirrors iOS.
    val selectedStage = selectedCode?.let { code ->
        val number = code.filter { it.isDigit() }.take(3)
        GrowthStage.allStages.firstOrNull { it.code.filter { c -> c.isDigit() } == number }
    }
    SimpleDropdown(
        label = "E-L growth stage",
        value = selectedStage?.displayName ?: selectedCode ?: "Not stated",
        options = listOf<String?>(null) + GrowthStage.allStages.map { it.code },
        optionLabel = { code ->
            code?.let { c -> GrowthStage.byCode(c)?.displayName ?: c } ?: "Not stated"
        },
        onSelect = onSelect,
    )
}

/**
 * Picks the targets a Program Step is for — one list, two origins. The
 * operator never has to know whether "Powdery Mildew" is a compiled target and
 * "Eutypa Dieback" is a row their vineyard created: both are targets, both are
 * tapped the same way. Adding a custom target is a first-class action, because
 * the alternative an operator reaches for otherwise is a generic "Other",
 * which throws away the one thing that mattered — which disease.
 */
@Composable
private fun SprayTargetChooserDialog(
    selected: List<SprayTargetTag>,
    vineyardTargets: List<SprayTargetTag>,
    onSelect: (SprayTargetTag) -> Unit,
    onCreate: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    var query by remember { mutableStateOf("") }
    val selectedIdentifiers = selected.map { it.identifier }.toSet()

    val commonMatches = SprayTarget.presentationOrder
        .map { SprayTargetTag(it) }
        .filter { query.isBlank() || it.label.contains(query.trim(), ignoreCase = true) }
    val builtInIdentifiers = SprayTarget.entries.map { it.raw }.toSet()
    val vineyardMatches = vineyardTargets
        .filter { it.identifier !in builtInIdentifiers }
        .filter { query.isBlank() || it.label.contains(query.trim(), ignoreCase = true) }

    // The typed search text, offered as a new target when it is genuinely new
    // — never above an exact match the operator should have tapped instead.
    val creatable = query.trim().takeIf { it.length >= 2 }?.let { trimmed ->
        SprayTargetVocabulary.tagFromWording(trimmed)?.takeIf { tag ->
            tag.identifier !in builtInIdentifiers &&
                vineyardTargets.none { it.identifier == tag.identifier } &&
                tag.identifier !in selectedIdentifiers
        }?.let { trimmed }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Target") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Search or type a target") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                )
                LazyColumn(modifier = Modifier.heightIn(max = 320.dp)) {
                    if (commonMatches.isNotEmpty()) {
                        item { ChooserHeader("Common Targets") }
                        items(commonMatches, key = { "common-${it.identifier}" }) { tag ->
                            ChooserRow(tag, tag.identifier in selectedIdentifiers) { onSelect(tag) }
                        }
                    }
                    if (vineyardMatches.isNotEmpty()) {
                        item { ChooserHeader("This Vineyard") }
                        items(vineyardMatches, key = { "vineyard-${it.identifier}" }) { tag ->
                            ChooserRow(tag, tag.identifier in selectedIdentifiers) { onSelect(tag) }
                        }
                        item {
                            Text(
                                "Targets this vineyard has used before. They stay available here even " +
                                    "when no Program Step is using them.",
                                fontSize = 11.sp,
                                color = vine.textSecondary,
                                modifier = Modifier.padding(vertical = 4.dp),
                            )
                        }
                    }
                    if (creatable != null) {
                        item { HorizontalDivider() }
                        item {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        onCreate(creatable)
                                        onDismiss()
                                    }
                                    .padding(vertical = 10.dp),
                            ) {
                                Icon(Icons.Filled.Add, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(18.dp))
                                Text("Add \u201C$creatable\u201D", color = VineColors.Primary, fontSize = 14.sp)
                            }
                        }
                    }
                    item {
                        Text(
                            "Name the actual target — Eutypa Dieback, Phomopsis, Black Spot, Light " +
                                "Brown Apple Moth. It's saved for this vineyard and offered on every " +
                                "Program Step here.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(top = 6.dp),
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun ChooserHeader(text: String) {
    val vine = LocalVineColors.current
    Text(
        text,
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = vine.textSecondary,
        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp),
    )
}

@Composable
private fun ChooserRow(tag: SprayTargetTag, isSelected: Boolean, onSelect: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !isSelected) { onSelect() }
            .padding(vertical = 10.dp),
    ) {
        Text(
            tag.label,
            fontSize = 14.sp,
            color = if (isSelected) vine.textSecondary else vine.textPrimary,
            modifier = Modifier.weight(1f),
        )
        if (isSelected) {
            Icon(Icons.Filled.Check, contentDescription = "Selected", tint = VineColors.Success, modifier = Modifier.size(16.dp))
        }
    }
}

/** Explicit product replacement — the operator taps a product in the Chemical Store, and THAT identity is written. */
@Composable
private fun SprayProductPickerDialog(
    state: AppUiState,
    currentName: String,
    onPick: (com.rork.vinetrack.data.model.SavedChemical) -> Unit,
    onKeepTypedName: () -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    var query by remember { mutableStateOf("") }
    val matches = state.savedChemicals
        .filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) }
        .sortedBy { it.name.lowercase() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Replace Product") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Search Chemical Store") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                )
                LazyColumn(modifier = Modifier.heightIn(max = 320.dp)) {
                    if (currentName.isNotEmpty()) {
                        item {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { onKeepTypedName() }
                                    .padding(vertical = 10.dp),
                            ) {
                                Text(
                                    "Keep \u201C$currentName\u201D without a product link",
                                    fontSize = 13.sp,
                                    color = vine.textSecondary,
                                )
                            }
                        }
                        item { HorizontalDivider() }
                    }
                    items(matches, key = { it.id }) { chemical ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onPick(chemical) }
                                .padding(vertical = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(chemical.name, fontSize = 14.sp, color = vine.textPrimary)
                            if (chemical.activeIngredient.isNotBlank()) {
                                Text(
                                    chemical.activeIngredient,
                                    fontSize = 11.sp,
                                    color = vine.textSecondary,
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
