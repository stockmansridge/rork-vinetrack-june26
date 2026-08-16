package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.RadioButtonChecked
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rork.vinetrack.data.resistance.ResistanceGroupSignature
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistancePlanChemicalCandidate
import com.rork.vinetrack.data.resistance.ResistancePlanPositionStatus
import com.rork.vinetrack.data.resistance.ResistancePlanProductOption
import com.rork.vinetrack.data.resistance.ResistancePlannedChemistrySource
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.ResistancePlannedProduct
import com.rork.vinetrack.data.resistance.ResistancePlanner
import com.rork.vinetrack.data.resistance.displayLabel
import com.rork.vinetrack.data.resistance.plannerMark
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Chemistry editor for one planned position.
 *
 * GROUP FIRST, PRODUCT SECOND. The operator picks a FRAC group before any brand is
 * offered, because rotation is a property of the mode of action and leading with products
 * invites planning a season around what is in the shed rather than around what the
 * strategy permits. Products appear only once a group is chosen, and only from the
 * vineyard's own Chemical Store.
 *
 * Mirrors `ResistancePlanPositionEditorSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ResistancePlanPositionEditorSheet(
    position: ResistancePlannedPosition,
    positionIndex: Int,
    plannerRequest: ResistancePlanner.Request,
    chemicalCandidates: List<ResistancePlanChemicalCandidate>,
    jurisdiction: ResistanceJurisdiction,
    onDismiss: () -> Unit,
    onSave: (ResistancePlannedPosition) -> Unit,
) {
    val vine = LocalVineColors.current

    var selectedSignature by remember(position.id) {
        mutableStateOf(
            position.componentGroups.takeIf { it.isNotEmpty() }
                ?.let { ResistanceGroupSignature.of(it) },
        )
    }
    var selectedProductIds by remember(position.id) {
        mutableStateOf(position.products.mapNotNull { it.savedChemicalId }.toSet())
    }
    var hasTargetDate by remember(position.id) { mutableStateOf(position.targetDateEpochMs != null) }
    var targetDate by remember(position.id) {
        mutableStateOf(position.targetDateEpochMs ?: System.currentTimeMillis())
    }
    var growthStage by remember(position.id) { mutableStateOf(position.growthStage.orEmpty()) }
    var note by remember(position.id) { mutableStateOf(position.note.orEmpty()) }
    var showDatePicker by remember { mutableStateOf(false) }

    // Real engine evaluations of each group at this position, for these blocks.
    val groupOptions = remember(plannerRequest, positionIndex) {
        ResistancePlanner.groupOptions(positionIndex, plannerRequest)
    }
    val productOptions = remember(selectedSignature, chemicalCandidates, jurisdiction) {
        selectedSignature?.let {
            ResistancePlanner.productOptions(it, chemicalCandidates, jurisdiction)
        } ?: emptyList()
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Scaffold(
            containerColor = vine.appBackground,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            "Spray ${positionIndex + 1} chemistry",
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                    navigationIcon = {
                        TextButton(onClick = onDismiss) { Text("Cancel") }
                    },
                    actions = {
                        TextButton(
                            enabled = selectedSignature != null,
                            onClick = {
                                val signature = selectedSignature ?: return@TextButton
                                onSave(
                                    buildPosition(
                                        position = position,
                                        signature = signature,
                                        chosen = productOptions.filter {
                                            selectedProductIds.contains(it.candidate.savedChemicalId)
                                        },
                                        targetDateEpochMs = targetDate.takeIf { hasTargetDate },
                                        growthStage = growthStage,
                                        note = note,
                                    ),
                                )
                            },
                        ) { Text("Done", fontWeight = FontWeight.SemiBold) }
                    },
                )
            },
        ) { padding ->
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp)
                    .navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Spacer(Modifier.height(4.dp))

                EditorSectionHeader("Recommended next chemistry")
                // Language is deliberately permissive, never prescriptive: these are
                // strategy-compatible options, not a "best product" and not an
                // instruction to spray.
                Text(
                    "Prefer a different effective FRAC group from the recent sequence. The options below are strategy-compatible for the selected blocks at this point in the sequence.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )

                HorizontalDivider(Modifier.padding(vertical = 8.dp), color = vine.cardBorder)

                EditorSectionHeader("Browse by FRAC group")
                if (groupOptions.isEmpty()) {
                    Text(
                        "No strategy-compatible group could be identified for this position. Review the earlier positions in the sequence.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
                groupOptions.forEach { option ->
                    val isSelected = selectedSignature?.key == option.listing.signature.key
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .clickable {
                                // Changing the group invalidates any product chosen for
                                // the old one, so the selection is cleared rather than
                                // silently carried onto chemistry it no longer matches.
                                selectedSignature = option.listing.signature
                                selectedProductIds = emptySet()
                            }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Icon(
                            if (isSelected) Icons.Filled.RadioButtonChecked else Icons.Filled.RadioButtonUnchecked,
                            contentDescription = null,
                            tint = if (isSelected) VineColors.LeafGreen else vine.textSecondary,
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.size(10.dp))
                        Column {
                            Text(
                                option.listing.displayName,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                option.listing.modeOfActionName,
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    option.status.label,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = if (option.status == ResistancePlanPositionStatus.GOOD_FIT) {
                                        VineColors.LeafGreen
                                    } else {
                                        VineColors.Orange
                                    },
                                )
                                if (option.differsFromRecentSequence) {
                                    Spacer(Modifier.size(6.dp))
                                    Text(
                                        "rotates away from recent groups",
                                        fontSize = 11.sp,
                                        color = vine.textSecondary,
                                    )
                                }
                            }
                        }
                    }
                }
                Text(
                    "A FRAC group does not establish registered grape use, disease efficacy or a suitable rate. Always check the product label.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )

                selectedSignature?.let { signature ->
                    HorizontalDivider(Modifier.padding(vertical = 8.dp), color = vine.cardBorder)
                    EditorSectionHeader("${signature.displayLabel} options in Chemical Store")
                    if (productOptions.isEmpty()) {
                        Text(
                            "No product in this vineyard's Chemical Store carries this group. You can still plan the group on its own.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    productOptions.forEach { option ->
                        val id = option.candidate.savedChemicalId
                        val isChecked = selectedProductIds.contains(id)
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable {
                                    selectedProductIds = if (isChecked) {
                                        selectedProductIds - id
                                    } else {
                                        selectedProductIds + id
                                    }
                                }
                                .padding(vertical = 10.dp),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Icon(
                                if (isChecked) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank,
                                contentDescription = null,
                                tint = if (isChecked) VineColors.LeafGreen else vine.textSecondary,
                                modifier = Modifier.size(20.dp),
                            )
                            Spacer(Modifier.size(10.dp))
                            Column {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        option.candidate.productName,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    Spacer(Modifier.size(6.dp))
                                    Text(option.candidate.availability.plannerMark, fontSize = 12.sp)
                                }
                                Text(
                                    option.candidate.groups.displayLabel,
                                    fontSize = 12.sp,
                                    color = vine.textSecondary,
                                )
                                if (!option.isExactSignatureMatch) {
                                    Text(
                                        "Also contains other groups — evaluated as a co-formulation",
                                        fontSize = 11.sp,
                                        color = VineColors.Orange,
                                    )
                                }
                                // Registered-use evidence, stated as evidence. Never
                                // presented as a registration claim the data cannot
                                // support.
                                Text(
                                    option.registeredUseNote,
                                    fontSize = 11.sp,
                                    color = vine.textSecondary,
                                )
                                option.caveat?.let { caveat ->
                                    Row(verticalAlignment = Alignment.Top) {
                                        Icon(
                                            Icons.Filled.Warning,
                                            contentDescription = null,
                                            tint = VineColors.Orange,
                                            modifier = Modifier.size(13.dp),
                                        )
                                        Spacer(Modifier.size(4.dp))
                                        Text(
                                            caveat,
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            color = VineColors.Orange,
                                        )
                                    }
                                }
                            }
                        }
                    }
                    Text(
                        "Optional. A product adds identity and verification state; the resistance result comes from the group structure either way.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }

                HorizontalDivider(Modifier.padding(vertical = 8.dp), color = vine.cardBorder)

                EditorSectionHeader("Timing")
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Target a date", fontSize = 14.sp)
                    Spacer(Modifier.weight(1f))
                    Switch(checked = hasTargetDate, onCheckedChange = { hasTargetDate = it })
                }
                if (hasTargetDate) {
                    TextButton(onClick = { showDatePicker = true }) {
                        Text("Choose target date", fontSize = 13.sp)
                    }
                }
                OutlinedTextField(
                    value = growthStage,
                    onValueChange = { growthStage = it },
                    label = { Text("Growth stage (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                )
                // Stated plainly, because it is a real design decision the operator can
                // see the effects of: reordering changes the warnings, editing a date
                // does not.
                Text(
                    "Optional. The sequence — not the date — drives the resistance result, so positions can be planned by order alone.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )

                EditorSectionHeader("Note")
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it },
                    label = { Text("Planner note (optional)") },
                    minLines = 2,
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                )

                Spacer(Modifier.height(24.dp))
            }
        }
    }

    if (showDatePicker) {
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = targetDate)
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let { targetDate = it }
                    showDatePicker = false
                }) { Text("Set") }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) { Text("Cancel") }
            },
        ) {
            DatePicker(state = pickerState)
        }
    }
}

@Composable
private fun EditorSectionHeader(title: String) {
    val vine = LocalVineColors.current
    Text(
        title.uppercase(),
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        color = vine.textSecondary,
        modifier = Modifier
            .fillMaxWidth()
            .background(androidx.compose.ui.graphics.Color.Transparent),
    )
}

/**
 * Assembles the edited position.
 *
 * A chosen product's OWN signature is used, not the group the operator browsed by.
 * Picking a 7+3 co-formulation from a Group 7 list really is planning 7+3, and evaluating
 * it as bare Group 7 would hide the Group 3 application entirely.
 */
private fun buildPosition(
    position: ResistancePlannedPosition,
    signature: ResistanceGroupSignature,
    chosen: List<ResistancePlanProductOption>,
    targetDateEpochMs: Long?,
    growthStage: String,
    note: String,
): ResistancePlannedPosition = position.copy(
    products = if (chosen.isEmpty()) {
        // Group-only planning: one stipulated product line carrying the chosen group and
        // no brand.
        listOf(
            ResistancePlannedProduct(
                groupCodes = signature.codes,
                source = ResistancePlannedChemistrySource.GROUP,
            ),
        )
    } else {
        chosen.map { option ->
            ResistancePlannedProduct(
                groupCodes = option.candidate.groups.codes,
                source = ResistancePlannedChemistrySource.SAVED_CHEMICAL,
                savedChemicalId = option.candidate.savedChemicalId,
                productName = option.candidate.productName,
                chemicalAvailability = option.candidate.availability,
                registeredForPlannedDisease = option.candidate.registeredForDisease,
            )
        }
    },
    targetDateEpochMs = targetDateEpochMs,
    growthStage = growthStage.takeIf { it.isNotBlank() },
    note = note.takeIf { it.isNotBlank() },
)
