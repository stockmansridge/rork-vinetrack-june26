package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.filled.Adjust
import androidx.compose.material.icons.filled.Help
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.ChemicalActiveIngredientRow
import com.rork.vinetrack.ui.components.ChemicalConflictCard
import com.rork.vinetrack.ui.components.ChemicalGroupSummaryLine
import com.rork.vinetrack.ui.components.ChemicalIdentityView
import com.rork.vinetrack.ui.components.ChemicalLabelRatesView
import com.rork.vinetrack.ui.components.ChemicalLabelledLine
import com.rork.vinetrack.ui.components.ChemicalPill
import com.rork.vinetrack.ui.components.ChemicalRegisteredUsesView
import com.rork.vinetrack.ui.components.ChemicalVerificationBadge
import com.rork.vinetrack.ui.components.ChemicalVerificationEvidenceView
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * The operator-facing Search → Match → Verify → Confirm workflow — the Android
 * mirror of the iOS `ChemicalMatchFlowView`.
 *
 * The whole point of this flow is that identifying a product and trusting a
 * product are separate acts. The wizard collects EVIDENCE; it never sets the
 * trust level itself. Every screen submits what it found to
 * [ChemicalIntelligence.resolvedVerificationStatus], and that computed value is
 * what gets displayed and saved — which is why there is no "mark as verified"
 * button anywhere in this file.
 */
private enum class MatchStep { SEARCH, MATCH, VERIFY, CONFIRM }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChemicalMatchFlowSheet(
    vm: AppViewModel,
    state: AppUiState,
    /**
     * Existing chemical being matched (legacy `needs_match` cleanup), or null
     * when adding something new.
     */
    existing: SavedChemical?,
    /**
     * Seeds the search box, so "Match & Verify" on a legacy record starts from
     * the name the grower already uses.
     */
    prefillQuery: String,
    onDismiss: () -> Unit,
    onEnterManually: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val service = remember { ChemicalInfoService() }

    var step by remember { mutableStateOf(MatchStep.SEARCH) }
    var query by remember { mutableStateOf(prefillQuery) }
    var results by remember {
        mutableStateOf<List<ChemicalInfoService.ChemicalSearchResult>>(emptyList())
    }
    var searching by remember { mutableStateOf(false) }
    var searchError by remember { mutableStateOf<String?>(null) }

    var selected by remember { mutableStateOf<ChemicalInfoService.ChemicalSearchResult?>(null) }
    var loadingStructured by remember { mutableStateOf(false) }
    var structuredError by remember { mutableStateOf<String?>(null) }
    var intelligence by remember { mutableStateOf<ChemicalIntelligence?>(null) }
    var saving by remember { mutableStateOf(false) }
    /** Set when the confirmed registration identity already exists in the store. */
    var duplicateOf by remember { mutableStateOf<SavedChemical?>(null) }
    /** Set when matching a legacy record onto a materially different product. */
    var identityWarning by remember { mutableStateOf<String?>(null) }

    /**
     * Country comes from the vineyard profile. The operator already told
     * VineTrack where they farm; asking again on every lookup would be both
     * annoying and a chance to get it wrong, and country is part of product
     * identity rather than a search preference.
     */
    val countryCode: String = remember(state.selectedVineyardId, state.vineyards) {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(
                state.vineyards.firstOrNull { it.id == state.selectedVineyardId }?.country,
            ),
        )
    }

    fun runSearch() {
        val trimmed = query.trim()
        if (trimmed.isEmpty() || searching) return
        searching = true
        searchError = null
        scope.launch {
            try {
                results = service.searchChemicals(trimmed, countryCode)
                if (results.isEmpty()) {
                    searchError =
                        "No products found. Try a different spelling, or enter the product manually."
                }
            } catch (e: Exception) {
                // The typed query is deliberately left intact so a failed lookup
                // never costs the operator their input.
                results = emptyList()
                searchError = e.message
                    ?: "Lookup is unavailable. Check your connection and try again."
            } finally {
                searching = false
            }
        }
    }

    fun loadStructured(result: ChemicalInfoService.ChemicalSearchResult) {
        loadingStructured = true
        structuredError = null
        scope.launch {
            try {
                intelligence = service.lookupStructured(result.name, countryCode).intelligence()
            } catch (e: Exception) {
                // No silent downgrade to the old AI shape: treating an
                // unstructured answer as if it were verified evidence is the
                // exact failure this stage exists to prevent.
                intelligence = null
                structuredError = e.message
                    ?: "Structured lookup is unavailable. Retry, or enter the product manually."
            } finally {
                loadingStructured = false
            }
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
                when (step) {
                    MatchStep.SEARCH -> if (existing == null) "Add Chemical" else "Match & Verify"
                    MatchStep.MATCH -> "Matched Product"
                    MatchStep.VERIFY -> "Verify Chemical"
                    MatchStep.CONFIRM -> "Confirm"
                },
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            when (step) {
                MatchStep.SEARCH -> {
                    SectionLabel("Search for product")
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        label = { Text("Product name") },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        if (countryCode.isBlank()) {
                            "Set your vineyard's country so products can be matched to the " +
                                "right national register."
                        } else {
                            "Searching products registered in $countryCode. An AU and an NZ " +
                                "product with the same name are different registrations."
                        },
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                    Button(
                        onClick = { runSearch() },
                        enabled = query.trim().isNotEmpty() && !searching,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (searching) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = Color.White,
                            )
                            Spacer(Modifier.width(8.dp))
                            Text("Searching…")
                        } else {
                            Text("Search")
                        }
                    }

                    searchError?.let { message ->
                        WarningLine(message)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { runSearch() }) { Text("Try Again") }
                            OutlinedButton(onClick = onEnterManually) { Text("Enter Manually") }
                        }
                    }

                    if (results.isNotEmpty()) {
                        HorizontalDivider()
                        SectionLabel("Select the exact product")
                        results.forEach { result ->
                            SearchResultRow(result, countryCode) {
                                selected = result
                                // A legacy record being re-pointed at a different
                                // registered product is a material identity change,
                                // so say so before it is saved rather than after.
                                identityWarning = existing?.let { chem ->
                                    val old = chem.displayName.trim().lowercase()
                                    val new = result.name.trim().lowercase()
                                    if (old.isNotEmpty() && new.isNotEmpty() && old != new) {
                                        "This will replace “${chem.displayName}” with the " +
                                            "registered product “${result.name}”. Check this is " +
                                            "the same product on your shed shelf."
                                    } else {
                                        null
                                    }
                                }
                                step = MatchStep.MATCH
                                loadStructured(result)
                            }
                        }
                        // A name match is a lead, not an identification.
                        Text(
                            "Product names repeat across manufacturers and countries. " +
                                "Choose the one on your label.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }

                    HorizontalDivider()
                    OutlinedButton(
                        onClick = onEnterManually,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Enter Manually") }
                    Text(
                        "Manually entered products stay Unverified until they are matched to a " +
                            "registered product.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }

                MatchStep.MATCH -> {
                    if (loadingStructured) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                            )
                            Text(
                                "Looking up product details…",
                                fontSize = 13.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }

                    ChemicalIdentityView(
                        productName = intelligence?.registration?.registeredProductName
                            ?: selected?.name ?: query,
                        registration = intelligence?.registration,
                        productCategory = intelligence?.productCategory.orEmpty(),
                    )

                    HorizontalDivider()
                    SectionLabel("Identity status")
                    // Identity strength is decided by whether a register and a
                    // number are actually present — never by how confident the
                    // lookup felt.
                    val registration = intelligence?.registration
                    when {
                        registration?.isAuthoritativeIdentity == true -> StatusLine(
                            "Exact registered identity found",
                            VineColors.Success,
                            Icons.Filled.Verified,
                        )
                        registration != null -> {
                            StatusLine("Likely match", VineColors.Info, Icons.Filled.Adjust)
                            Text(
                                "A registration number could not be confirmed for this product.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                        else -> {
                            StatusLine(
                                "Product identity incomplete",
                                VineColors.Warning,
                                Icons.Filled.Help,
                            )
                            Text(
                                "No national registration was found. This product can be saved, " +
                                    "but it cannot become Verified.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }

                    identityWarning?.let { WarningLine(it) }

                    structuredError?.let { message ->
                        WarningLine(message)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = {
                                selected?.let { loadStructured(it) }
                            }) { Text("Try Again") }
                            OutlinedButton(onClick = onEnterManually) { Text("Enter Manually") }
                        }
                    }

                    HorizontalDivider()
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { step = MatchStep.SEARCH }) {
                            Text("Back to search")
                        }
                        Button(
                            onClick = { step = MatchStep.VERIFY },
                            enabled = intelligence != null,
                        ) { Text("Continue") }
                    }
                }

                MatchStep.VERIFY -> {
                    val intel = intelligence
                    if (intel != null) {
                        val resolved = intel.resolvedVerificationStatus

                        ChemicalConflictCard(intel.verification.conflicts)

                        SectionLabel("Product identity")
                        ChemicalIdentityView(
                            productName = intel.registration?.registeredProductName
                                ?: selected?.name ?: query,
                            registration = intel.registration,
                            productCategory = intel.productCategory,
                        )

                        HorizontalDivider()
                        SectionLabel("Active ingredients")
                        if (intel.activeIngredients.isEmpty()) {
                            WarningLine("No active ingredients were identified.")
                        } else {
                            intel.activeIngredients.forEach { active ->
                                ChemicalActiveIngredientRow(active)
                            }
                        }
                        if (intel.activityGroups.size > 1) {
                            // Say it in words as well as chips: a mixture belongs
                            // to every one of its groups at once, and rotating off
                            // only one of them is exactly how resistance develops.
                            Text(
                                "This is a mixture. All ${intel.activityGroups.size} activity " +
                                    "groups apply independently for resistance purposes.",
                                fontSize = 11.sp,
                                color = vine.textSecondary,
                            )
                        }

                        if (intel.activityGroups.isNotEmpty()) {
                            HorizontalDivider()
                            SectionLabel("Activity groups")
                            ChemicalGroupSummaryLine(intel.activityGroups)
                            Text(
                                "Derived from the active ingredients above.",
                                fontSize = 11.sp,
                                color = vine.textSecondary,
                            )
                        }

                        HorizontalDivider()
                        SectionLabel("Verification")
                        ChemicalVerificationEvidenceView(intel.verification, resolved)
                        Text(resolved.detail, fontSize = 11.sp, color = vine.textSecondary)

                        if (intel.registeredUses.any { it.rates.isNotEmpty() }) {
                            HorizontalDivider()
                            ChemicalLabelRatesView(intel.registeredUses)
                        }

                        HorizontalDivider()
                        SectionLabel("Registered uses")
                        ChemicalRegisteredUsesView(intel.registeredUses)

                        HorizontalDivider()
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { step = MatchStep.MATCH }) { Text("Back") }
                            Button(onClick = {
                                // Duplicate prevention keys off registration
                                // identity, never name similarity: two products can
                                // share a name and be different registrations, and
                                // the same registration is the same product however
                                // it was typed.
                                val key = intel.registration?.identityKey
                                duplicateOf = if (key != null) {
                                    state.savedChemicals.firstOrNull { chem ->
                                        chem.id != existing?.id &&
                                            chem.resolvedIntelligence.registration
                                                ?.identityKey == key
                                    }
                                } else {
                                    null
                                }
                                step = MatchStep.CONFIRM
                            }) { Text("Continue") }
                        }
                    }
                }

                MatchStep.CONFIRM -> {
                    val intel = intelligence
                    if (intel != null) {
                        val resolved = intel.resolvedVerificationStatus
                        val productName = intel.registration?.registeredProductName
                            ?: selected?.name ?: query

                        SectionLabel("Summary")
                        ChemicalLabelledLine("Product", productName)
                        ChemicalLabelledLine(
                            "Country",
                            intel.registration?.countryCode?.takeIf { it.isNotBlank() }
                                ?: countryCode,
                        )
                        ChemicalLabelledLine(
                            "Registration",
                            intel.registration?.displayIdentifier ?: "Not confirmed",
                        )
                        ChemicalLabelledLine(
                            "Actives",
                            intel.activeIngredients.takeIf { it.isNotEmpty() }
                                ?.let { intel.legacyActiveIngredient } ?: "None identified",
                        )
                        ChemicalLabelledLine(
                            "Activity groups",
                            intel.activityGroups.takeIf { it.isNotEmpty() }
                                ?.let { intel.legacyChemicalGroup } ?: "Unknown",
                        )
                        ChemicalLabelledLine(
                            "Registered uses",
                            intel.registeredUses.size.takeIf { it > 0 }?.toString()
                                ?: "Not confirmed",
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

                        identityWarning?.let { WarningLine(it) }

                        duplicateOf?.let { dup ->
                            HorizontalDivider()
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(VineColors.Warning.copy(alpha = 0.08f))
                                    .padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Text(
                                    "Already in Chemical Store",
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = VineColors.Warning,
                                )
                                Text(
                                    "“${dup.displayName}” already has this exact registration " +
                                        "identity. Update that record instead of adding a " +
                                        "second copy.",
                                    fontSize = 12.sp,
                                    color = vine.textSecondary,
                                )
                                Button(
                                    onClick = {
                                        if (saving) return@Button
                                        saving = true
                                        vm.updateSavedChemical(
                                            dup.id,
                                            chemicalInputFrom(dup, productName, intel),
                                        ) { ok ->
                                            saving = false
                                            if (ok) onDismiss()
                                        }
                                    },
                                    enabled = !saving,
                                    modifier = Modifier.fillMaxWidth(),
                                ) { Text("Update existing record") }
                            }
                        }

                        HorizontalDivider()
                        if (duplicateOf == null) {
                            Button(
                                onClick = {
                                    if (saving) return@Button
                                    saving = true
                                    val input = chemicalInputFrom(existing, productName, intel)
                                    if (existing == null) {
                                        vm.createSavedChemical(input) { ok ->
                                            saving = false
                                            if (ok) onDismiss()
                                        }
                                    } else {
                                        // Legacy cleanup updates the SAME record
                                        // rather than creating a near-duplicate.
                                        vm.updateSavedChemical(existing.id, input) { ok ->
                                            saving = false
                                            if (ok) onDismiss()
                                        }
                                    }
                                },
                                enabled = !saving,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(
                                    if (existing == null) "Add to Chemical Store"
                                    else "Save Chemical",
                                )
                            }
                        }
                        TextButton(onClick = { step = MatchStep.VERIFY }) { Text("Back") }
                        Text(
                            "The structured record is saved in full. The older Active Ingredient " +
                                "and Chemical Group fields are kept in step with it for " +
                                "compatibility.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            Spacer(Modifier.height(4.dp))
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    }

    LaunchedEffect(Unit) {
        if (prefillQuery.trim().isNotEmpty() && results.isEmpty()) runSearch()
    }
}

/**
 * Builds the repository input for a confirmed structured record.
 *
 * When [existing] is present every unrelated field is carried across untouched —
 * matching a legacy chemical must not quietly reset its rates, costing or pack
 * data. The legacy `active_ingredient` / `chemical_group` scalars are written as
 * DERIVED mirrors of the structured data so old clients keep rendering something
 * familiar; nothing reads them back for a resistance decision.
 */
private fun chemicalInputFrom(
    existing: SavedChemical?,
    productName: String,
    intel: ChemicalIntelligence,
): SavedChemicalRepository.ChemicalInput {
    val projection = intel.legacyChemicalGroup
    val activeProjection = intel.legacyActiveIngredient
    return SavedChemicalRepository.ChemicalInput(
        name = productName.trim().ifBlank { existing?.name.orEmpty() },
        unit = existing?.unit ?: "Litres",
        ratePerHa = existing?.ratePerHa ?: 0.0,
        rates = existing?.rates ?: emptyList(),
        activeIngredient = activeProjection.ifBlank { existing?.activeIngredient },
        chemicalGroup = projection.ifBlank { existing?.chemicalGroup },
        use = existing?.use,
        problem = existing?.problem,
        manufacturer = intel.registration?.registrant?.takeIf { it.isNotBlank() }
            ?: existing?.manufacturer,
        notes = existing?.notes,
        modeOfAction = existing?.modeOfAction,
        labelUrl = intel.registration?.labelReference?.takeIf { it.isNotBlank() }
            ?: existing?.labelUrl,
        productUrl = existing?.productUrl,
        purchase = existing?.purchase,
        productCategory = intel.productCategory.ifBlank { existing?.productCategory.orEmpty() },
        productForm = existing?.productForm.orEmpty(),
        packSize = existing?.packSize,
        packUnit = existing?.packUnit.orEmpty(),
        pricePerPack = existing?.pricePerPack,
        density = existing?.density,
        nitrogenPercent = existing?.nitrogenPercent,
        phosphorusPercent = existing?.phosphorusPercent,
        potassiumPercent = existing?.potassiumPercent,
        analysisBasis = existing?.analysisBasis ?: "elemental",
        organicCertified = existing?.organicCertified ?: false,
        inventoryQuantity = existing?.inventoryQuantity,
        inventoryUnit = existing?.inventoryUnit.orEmpty(),
        applicationNotes = existing?.applicationNotes.orEmpty(),
        intelligence = intel,
    )
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = LocalVineColors.current.textSecondary,
    )
}

@Composable
private fun StatusLine(text: String, tint: Color, icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        Text(text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = tint)
    }
}

@Composable
private fun WarningLine(message: String) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            tint = VineColors.Warning,
            modifier = Modifier.size(14.dp),
        )
        Text(message, fontSize = 12.sp, color = VineColors.Warning)
    }
}

@Composable
private fun SearchResultRow(
    result: ChemicalInfoService.ChemicalSearchResult,
    countryCode: String,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable { onClick() }
            .padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            result.name,
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textPrimary,
        )
        if (result.brand.isNotBlank()) {
            Text(result.brand, fontSize = 12.sp, color = vine.textSecondary)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (countryCode.isNotBlank()) ChemicalPill(countryCode, VineColors.Info)
            if (result.primaryUse.isNotBlank()) ChemicalPill(result.primaryUse, VineColors.Olive)
        }
        if (result.activeIngredient.isNotBlank()) {
            Text(
                result.activeIngredient,
                fontSize = 11.sp,
                color = vine.textSecondary,
                maxLines = 1,
            )
        }
    }
}
