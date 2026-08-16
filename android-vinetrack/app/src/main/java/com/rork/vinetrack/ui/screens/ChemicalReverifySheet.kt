package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.chemical.ChemicalEditOutcome
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceChange
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiff
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalReverification
import com.rork.vinetrack.data.chemical.ChemicalReverifyFlow
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.ChemicalConflictCard
import com.rork.vinetrack.ui.components.ChemicalIdentityView
import com.rork.vinetrack.ui.components.ChemicalLabelledLine
import com.rork.vinetrack.ui.components.ChemicalVerificationBadge
import com.rork.vinetrack.ui.components.ChemicalVerificationEvidenceView
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * Where a re-verification has got to.
 *
 * Deliberately four states and no more: an operator asked one question and gets
 * one of four answers. Anything that looks like a wizard step here would be a
 * step they should not have to take, because the product identity is already
 * known before the screen opens.
 */
private sealed interface ReverifyPhase {
    data object Checking : ReverifyPhase

    /**
     * Nothing about the product moved. [refreshed] is the evidence-only update to
     * store, or null when there is no structured record to refresh — a no-change
     * result must not materialise a legacy seed as the record's first structured
     * write.
     */
    data class Current(
        val candidate: ChemicalIntelligence,
        val refreshed: ChemicalIntelligence?,
    ) : ReverifyPhase

    /**
     * Something moved. The [outcome] is reconciled ONCE and both previewed and
     * written, so the operator accepts exactly what they were shown.
     */
    data class Changes(
        val candidate: ChemicalIntelligence,
        val diff: ChemicalIntelligenceDiff,
        val outcome: ChemicalEditOutcome,
    ) : ReverifyPhase

    data class Failed(val message: String) : ReverifyPhase
}

/**
 * Re-verify Chemical — re-checking a product VineTrack has ALREADY identified.
 *
 * The Android mirror of iOS `ChemicalReverifyFlowView`, following the same route:
 * Chemical record → Re-verify Chemical → Checking → Current OR Review Changes →
 * Update/Cancel.
 *
 * Nothing in this file decides anything. Eligibility comes from
 * [ChemicalReverification.isOffered], the lookup key from
 * [ChemicalReverification.Plan], the comparison from [ChemicalIntelligenceDiffer]
 * and the written result from [ChemicalReverification.apply] — which routes
 * through the reconciler, so the trust level is COMPUTED and there is no "Mark
 * Verified" button anywhere.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChemicalReverifySheet(
    vm: AppViewModel,
    state: AppUiState,
    chemical: SavedChemical,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val service = remember { ChemicalInfoService() }

    var phase by remember { mutableStateOf<ReverifyPhase>(ReverifyPhase.Checking) }
    var saving by remember { mutableStateOf(false) }

    val countryCode: String = remember(state.selectedVineyardId, state.vineyards) {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(
                state.vineyards.firstOrNull { it.id == state.selectedVineyardId }?.country,
            ),
        )
    }

    val plan = remember(chemical, countryCode) {
        ChemicalReverification.plan(chemical, countryCode)
    }

    /** What the Chemical Store currently DISPLAYS for this product. */
    val currentIntelligence: ChemicalIntelligence? = remember(chemical) {
        ChemicalReverifyFlow.currentIntelligence(chemical)
    }

    /**
     * One lookup, keyed on the strongest identity the record holds.
     *
     * Classification is delegated to [ChemicalReverifyFlow] so this sheet holds no
     * rule of its own — the same code path the tests assert on.
     */
    fun run() {
        phase = ReverifyPhase.Checking
        scope.launch {
            try {
                val candidate = service
                    .lookupStructured(plan.lookupQuery, plan.countryCode)
                    .intelligence()
                phase = when (
                    val result = ChemicalReverifyFlow.resolve(
                        chemical = chemical,
                        candidate = candidate,
                        at = Instant.now().toString(),
                    )
                ) {
                    is ChemicalReverifyFlow.Result.Current ->
                        ReverifyPhase.Current(result.candidate, result.refreshed)
                    is ChemicalReverifyFlow.Result.Changes ->
                        ReverifyPhase.Changes(result.candidate, result.diff, result.outcome)
                    is ChemicalReverifyFlow.Result.Unusable ->
                        ReverifyPhase.Failed(result.reason)
                }
            } catch (e: Exception) {
                // A failed lookup is not new evidence about the product, so the
                // record keeps the verification it already earned.
                phase = ReverifyPhase.Failed(
                    e.message
                        ?: "The lookup is unavailable. Check your connection and try again.",
                )
            }
        }
    }

    /** Persist an accepted update through the reconciled outcome. */
    fun accept(outcome: ChemicalEditOutcome) {
        if (saving) return
        saving = true
        vm.updateSavedChemical(
            chemical.id,
            ChemicalReverifyFlow.acceptedInput(chemical, outcome),
        ) { ok ->
            saving = false
            if (ok) onDismiss()
        }
    }

    /** Close a no-change result, storing refreshed evidence when there is any. */
    fun confirmCurrent(refreshed: ChemicalIntelligence?) {
        if (refreshed == null) {
            onDismiss()
            return
        }
        if (saving) return
        saving = true
        vm.updateSavedChemical(
            chemical.id,
            ChemicalReverifyFlow.confirmedInput(chemical, refreshed),
        ) { ok ->
            saving = false
            if (ok) onDismiss()
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "Re-verify Chemical",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            when (val current = phase) {
                is ReverifyPhase.Checking -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                        )
                        Text(
                            "Checking current product information…",
                            fontSize = 15.sp,
                            color = vine.textPrimary,
                        )
                    }
                    Text(
                        "Your saved chemical is not changed until you accept an update.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )

                    HorizontalDivider()
                    ReverifySectionLabel("Checking against")
                    ChemicalLabelledLine(
                        "Product",
                        plan.productName.ifBlank { "Unnamed" },
                    )
                    if (plan.countryCode.isNotBlank()) {
                        ChemicalLabelledLine("Country", plan.countryCode)
                    }
                    plan.registrationNumber?.takeIf { it.isNotBlank() }?.let {
                        ChemicalLabelledLine("Registration", it)
                    }
                    plan.registrant?.takeIf { it.isNotBlank() }?.let {
                        ChemicalLabelledLine("Registrant", it)
                    }
                    Text(plan.strength.detail, fontSize = 11.sp, color = vine.textSecondary)
                }

                is ReverifyPhase.Current -> {
                    val shown = current.refreshed ?: currentIntelligence
                    val resolved = shown?.resolvedVerificationStatus
                        ?: chemical.verificationStatus

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(
                            Icons.Filled.CheckCircle,
                            contentDescription = null,
                            tint = VineColors.Success,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            "Chemical information is current",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.Success,
                        )
                    }
                    Text(
                        "The register still reports the same chemistry, registration and " +
                            "label information VineTrack already holds.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )

                    HorizontalDivider()
                    ReverifySectionLabel("Product identity")
                    ChemicalIdentityView(
                        productName = shown?.registration?.registeredProductName
                            ?: chemical.displayName,
                        registration = shown?.registration,
                        productCategory = shown?.productCategory.orEmpty(),
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            "Verification",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.width(96.dp),
                        )
                        ChemicalVerificationBadge(resolved)
                    }
                    Text(resolved.detail, fontSize = 11.sp, color = vine.textSecondary)

                    current.refreshed?.let { refreshed ->
                        HorizontalDivider()
                        ReverifySectionLabel("Verification details")
                        ChemicalVerificationEvidenceView(refreshed.verification, resolved)
                        // Be explicit that only provenance moved. A check date is
                        // not a product change and must not read like one.
                        Text(
                            "Only the record of when this was last checked and which sources " +
                                "were consulted has been updated. No chemistry, rate or " +
                                "registered use was changed.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }

                    ChemicalConflictCard(current.candidate.verification.conflicts)

                    HorizontalDivider()
                    Button(
                        onClick = { confirmCurrent(current.refreshed) },
                        enabled = !saving,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text(if (current.refreshed == null) "Close" else "Done") }
                }

                is ReverifyPhase.Changes -> {
                    // Conflicts come from the RECONCILED outcome, not the raw
                    // candidate: that is the set including the reference-table
                    // cross-check plus the lookup's own unresolved disagreements,
                    // and it is the set the record will actually carry.
                    val conflicts = current.outcome.intelligence.verification.conflicts
                    val resolved = current.outcome.resolvedStatus

                    if (conflicts.isEmpty()) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(
                                Icons.Filled.Sync,
                                contentDescription = null,
                                tint = VineColors.Info,
                                modifier = Modifier.size(18.dp),
                            )
                            Text(
                                "Updated information found",
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.Info,
                            )
                        }
                        Text(
                            "Review what has changed before updating this chemical.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    } else {
                        // Identity matching is not the same as agreement. A
                        // conflicted candidate must never open with a green
                        // confirmation.
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(
                                Icons.Filled.Warning,
                                contentDescription = null,
                                tint = VineColors.Destructive,
                                modifier = Modifier.size(18.dp),
                            )
                            Text(
                                "Needs review",
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.Destructive,
                            )
                        }
                        Text(
                            "The re-check returned information that disagrees with the " +
                                "reference classification. Review it before updating.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }

                    if (current.diff.hasResistanceCriticalChanges) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(
                                Icons.Filled.Science,
                                contentDescription = null,
                                tint = VineColors.Warning,
                                modifier = Modifier.size(14.dp),
                            )
                            Text(
                                "Includes resistance-critical changes",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.Warning,
                            )
                        }
                    }

                    ChemicalConflictCard(conflicts)

                    // Chemistry first, registry housekeeping last — the order
                    // comes from the domain's own displayOrder, not from here.
                    current.diff.populatedSections.forEach { section ->
                        val sectionChanges = current.diff.changesIn(section)
                        HorizontalDivider()
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            ReverifySectionLabel(section.label)
                            if (sectionChanges.any { it.isResistanceCritical }) {
                                Text(
                                    "RESISTANCE",
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = VineColors.Warning,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(50))
                                        .background(VineColors.Warning.copy(alpha = 0.14f))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                )
                            }
                        }
                        sectionChanges.forEach { ChangeRow(it) }
                    }

                    HorizontalDivider()
                    ReverifySectionLabel("Verification details")
                    ChemicalVerificationEvidenceView(
                        current.outcome.intelligence.verification,
                        resolved,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            "After updating",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.width(96.dp),
                        )
                        ChemicalVerificationBadge(resolved)
                    }
                    // The status is computed from the merged evidence. Say so, so
                    // nobody reads the badge as something this screen chose.
                    Text(
                        "${resolved.detail} This status is derived from the evidence behind " +
                            "each value — it is not set by accepting this update.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )

                    HorizontalDivider()
                    Button(
                        onClick = { accept(current.outcome) },
                        enabled = !saving,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Update Chemical") }
                    Text(
                        "Updating changes this Chemical Store record only. Completed spray " +
                            "records keep the chemical information that was captured at the " +
                            "time they were applied.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }

                is ReverifyPhase.Failed -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(
                            Icons.Filled.WifiOff,
                            contentDescription = null,
                            tint = VineColors.Warning,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            "Could not re-verify",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.Warning,
                        )
                    }
                    Text(current.message, fontSize = 12.sp, color = vine.textSecondary)
                    // A failed lookup is not evidence about the product. It must
                    // never cost a record the verification it already earned.
                    Text(
                        "This chemical has not been changed. A failed check is not new " +
                            "information about the product, so its current verification " +
                            "status stands.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )

                    HorizontalDivider()
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            "Current status",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.width(96.dp),
                        )
                        ChemicalVerificationBadge(chemical.verificationStatus)
                    }

                    HorizontalDivider()
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { run() }) { Text("Try Again") }
                        OutlinedButton(onClick = onDismiss) { Text("Cancel") }
                    }
                }
            }

            Spacer(Modifier.height(4.dp))
            // Cancel is always available and always writes nothing.
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    }

    LaunchedEffect(chemical.id) { run() }
}

/**
 * One change, in the shape an operator reads: what it is, then current, then
 * updated. Resistance-critical rows carry the emphasis.
 */
@Composable
private fun ChangeRow(change: ChemicalIntelligenceChange) {
    val vine = LocalVineColors.current
    val tint: Color = if (change.isResistanceCritical) VineColors.Warning else vine.textSecondary
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                change.title,
                fontSize = 14.sp,
                fontWeight = if (change.isResistanceCritical) FontWeight.Bold
                else FontWeight.Medium,
                color = vine.textPrimary,
            )
            Text(
                change.kind.label,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                color = tint,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(tint.copy(alpha = 0.12f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        change.currentValue?.let { ValueLine("Current", it, emphasised = false) }
        change.candidateValue?.let {
            ValueLine("Updated", it, emphasised = change.isResistanceCritical)
        }
    }
}

@Composable
private fun ValueLine(title: String, value: String, emphasised: Boolean) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            title,
            fontSize = 12.sp,
            color = vine.textSecondary,
            modifier = Modifier.width(66.dp),
        )
        Text(
            value,
            fontSize = 12.sp,
            fontWeight = if (emphasised) FontWeight.Bold else FontWeight.Medium,
            color = if (emphasised) VineColors.Warning else vine.textPrimary,
        )
    }
}

@Composable
private fun ReverifySectionLabel(text: String) {
    Text(
        text.uppercase(),
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = LocalVineColors.current.textSecondary,
    )
}
