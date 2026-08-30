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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Adjust
import androidx.compose.material.icons.filled.Help
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Schedule
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
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateGroup
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateOption
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateSelection
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalJurisdiction
import com.rork.vinetrack.data.chemical.ChemicalLookupAdvisory
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.formatChemicalNumber
import com.rork.vinetrack.data.chemical.viticultural
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
    /**
     * Master catalogue reference when the structured lookup was served from an
     * APPROVED master row (sql/199). Null on AI-sourced lookups.
     */
    var masterMatch by remember {
        mutableStateOf<ChemicalInfoService.ChemicalMasterMatch?>(null)
    }
    /** Set when matching a legacy record onto a materially different product. */
    var identityWarning by remember { mutableStateOf<String?>(null) }
    /** Verbatim `form_type` from the structured lookup. Null until resolved. */
    var lookupFormType by remember { mutableStateOf<String?>(null) }
    /**
     * The vineyard default-rate decision for the resolved product (A7). Built
     * fresh from each lookup's grapevine uses; a selection never edits the
     * registered label rates themselves.
     */
    var defaultSelection by remember { mutableStateOf<ChemicalDefaultRateSelection?>(null) }
    /** Operator-typed exact-dose text per basis (label bands only). */
    var doseTexts by remember { mutableStateOf<Map<ChemicalDefaultRateBasis, String>>(emptyMap()) }
    /** Rejection message per basis when a typed dose is outside the band. */
    var doseErrors by remember { mutableStateOf<Map<ChemicalDefaultRateBasis, String>>(emptyMap()) }

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
        // One request at a time: a duplicate tap must never fire a second
        // search, and no country means no jurisdiction (fail closed).
        if (!ChemicalLookupAdvisory.canStartSearch(query, searching, countryCode)) return
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
        lookupFormType = null
        defaultSelection = null
        doseTexts = emptyMap()
        doseErrors = emptyMap()
        scope.launch {
            try {
                // A register candidate carries its registration number;
                // passing it makes the strict resolver verify THAT exact
                // identity (name↔number re-checked server-side), which also
                // disambiguates same-name pack registrations.
                val lookup = service.lookupStructured(
                    result.name,
                    countryCode,
                    result.registrationNumber,
                )
                // Jurisdiction gate: a payload registered in another country —
                // or a master row keyed to one — is refused OUTRIGHT, exactly
                // like a failed lookup. Foreign label rates, WHP, re-entry
                // statements and uses must never be convertible, saveable or
                // linkable here.
                val rejection = ChemicalJurisdiction.rejectionReason(lookup, countryCode)
                if (rejection != null) {
                    masterMatch = null
                    intelligence = null
                    structuredError = rejection
                    return@launch
                }
                // Master-served lookups carry the catalogue reference the
                // saved record retains (sql/199). AI-sourced lookups carry none.
                masterMatch = if (lookup.isMasterMatch) lookup.master else null
                val intel = lookup.intelligence()
                intelligence = intel
                lookupFormType = lookup.formType
                // Vineyard state is not recorded on Android profiles, so the
                // jurisdiction step is skipped — a weaker answer, never a
                // wrong one. The only-registered-rate rule still recommends.
                defaultSelection = ChemicalDefaultRateSelection(
                    plan = ChemicalDefaultRate.plan(
                        grapevineUses = intel.registeredUses.viticultural(),
                        jurisdiction = null,
                    ),
                )
            } catch (e: Exception) {
                // No silent downgrade to the old AI shape: treating an
                // unstructured answer as if it were verified evidence is the
                // exact failure this stage exists to prevent.
                masterMatch = null
                intelligence = null
                structuredError = e.message
                    ?: "Structured lookup is unavailable. Retry, or enter the product manually."
            } finally {
                loadingStructured = false
            }
        }
    }

    /**
     * Intentionally leave the selected product and search again (A3) — the
     * equivalent of the iOS "Change Product". Returns to the register search
     * with the typed query and results intact, clearing everything derived
     * from the abandoned selection, including any default rate chosen for the
     * old product. Nothing is saved until the operator confirms a product.
     */
    fun changeProduct() {
        selected = null
        intelligence = null
        masterMatch = null
        structuredError = null
        identityWarning = null
        lookupFormType = null
        defaultSelection = null
        doseTexts = emptyMap()
        doseErrors = emptyMap()
        duplicateOf = null
        step = MatchStep.SEARCH
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
                        // No vineyard country -> no jurisdiction -> fail closed.
                        // The hint above says what to set; searching a guessed
                        // national register would verify the wrong label.
                        enabled = ChemicalLookupAdvisory.canStartSearch(query, searching, countryCode),
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

                    // A2: searches legitimately take time while VineTrack
                    // checks current registration and label information — say
                    // so up front, and switch to the active wording while a
                    // request is running.
                    ChemicalLookupAdvisoryNotice(isSearching = searching)

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
                        // A1: while the lookup is in flight, the only honest
                        // content is "we are checking". Unresolved-identity
                        // warnings and empty authoritative fields must not
                        // render until an answer actually arrives — and a slow
                        // lookup is never treated as a failed one.
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
                        ChemicalLookupAdvisoryNotice(isSearching = true)
                    } else if (intelligence != null) {
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
                        // The registered identity is never editable in place:
                        // leaving it is an intentional act that returns to the
                        // register search.
                        OutlinedButton(onClick = { changeProduct() }) {
                            Text("Change Product")
                        }
                        Button(
                            onClick = { step = MatchStep.VERIFY },
                            enabled = intelligence != null && !loadingStructured,
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
                        // The label-source flag only ever changes the WORDING of
                        // a label-parsed zero-day withholding period ("not
                        // required when used as directed"); it never invents or
                        // alters a value. Derived from the payload's own cited
                        // sources.
                        ChemicalRegisteredUsesView(
                            intel.registeredUses,
                            hasManufacturerLabelSource = intel.verification.sources.any {
                                it.kind == ChemicalDataSourceKind.MANUFACTURER_LABEL
                            },
                        )

                        HorizontalDivider()
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { step = MatchStep.MATCH }) { Text("Back") }
                            OutlinedButton(onClick = { changeProduct() }) {
                                Text("Change Product")
                            }
                            Button(onClick = {
                                // Duplicate prevention keys off registration
                                // identity, never name similarity: two products can
                                // share a name and be different registrations, and
                                // the same registration is the same product however
                                // it was typed.
                                duplicateOf = ChemicalStoreMatching.findByRegistrationIdentity(
                                    chemicals = state.savedChemicals,
                                    registration = intel.registration,
                                    excludingId = existing?.id,
                                )
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
                        masterMatch?.let { master ->
                            ChemicalLabelledLine(
                                "Source",
                                "Master catalogue · rev ${master.masterRevision}",
                            )
                        }
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

                        // A7: the vineyard's operational default, chosen from
                        // the registered grapevine rates. The authoritative
                        // label rates on the record are never altered by it.
                        defaultSelection?.let { selection ->
                            if (intel.registeredUses.viticultural().isNotEmpty()) {
                                HorizontalDivider()
                                DefaultRatesSection(
                                    selection = selection,
                                    doseTexts = doseTexts,
                                    doseErrors = doseErrors,
                                    onSelect = { option, basis ->
                                        defaultSelection = selection.selecting(option, basis)
                                        doseTexts = doseTexts - basis
                                        doseErrors = doseErrors - basis
                                    },
                                    onDoseTextChange = { basis, text ->
                                        doseTexts = doseTexts + (basis to text)
                                    },
                                    onSetDose = { basis ->
                                        val raw = doseTexts[basis].orEmpty().trim()
                                            .replace(',', '.')
                                        val option = selection.resolvedOption(basis)
                                        if (raw.isEmpty()) {
                                            defaultSelection = selection.clearingValue(basis)
                                            doseErrors = doseErrors - basis
                                        } else {
                                            val updated = raw.toDoubleOrNull()
                                                ?.let { selection.settingValue(it, basis) }
                                            if (updated != null) {
                                                defaultSelection = updated
                                                doseErrors = doseErrors - basis
                                            } else {
                                                val bounds = option?.authorisedBounds
                                                doseErrors = doseErrors + (
                                                    basis to if (bounds != null) {
                                                        "The label registers " +
                                                            formatChemicalNumber(bounds.first) +
                                                            "–" +
                                                            formatChemicalNumber(bounds.second) +
                                                            " ${option.rate.unit}. Enter a rate " +
                                                            "within it."
                                                    } else {
                                                        "Enter a rate the label registers."
                                                    }
                                                    )
                                            }
                                        }
                                    },
                                    onResetDose = { basis ->
                                        defaultSelection = selection.clearingValue(basis)
                                        doseTexts = doseTexts - basis
                                        doseErrors = doseErrors - basis
                                    },
                                )
                            }
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
                                            ChemicalStoreMatching.inputFor(
                                                dup, productName, intel, masterMatch,
                                                formTypeRaw = lookupFormType,
                                                defaults = defaultSelection,
                                            ),
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
                                    val input = ChemicalStoreMatching.inputFor(
                                        existing, productName, intel, masterMatch,
                                        formTypeRaw = lookupFormType,
                                        defaults = defaultSelection,
                                    )
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
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = { step = MatchStep.VERIFY }) { Text("Back") }
                            TextButton(onClick = { changeProduct() }) { Text("Change Product") }
                        }
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

/**
 * A2: the bold VineTrack-green advisory that a chemical search can take time.
 *
 * Deliberately NOT a warning — nothing has gone wrong, so no amber or red.
 * The clock (idle) or spinner (active) carries the meaning alongside the
 * text, so colour is never the only signal, and the wording change is
 * announced to accessibility services via a polite live region. No fake
 * percentages, no invented completion times, and a slow lookup is never
 * auto-failed into manual entry.
 */
@Composable
internal fun ChemicalLookupAdvisoryNotice(isSearching: Boolean) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VineColors.BrandTrack.copy(alpha = 0.12f))
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (isSearching) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = VineColors.BrandTrack,
                )
            } else {
                Icon(
                    Icons.Filled.Schedule,
                    contentDescription = null,
                    tint = VineColors.BrandTrack,
                    modifier = Modifier.size(16.dp),
                )
            }
            Text(
                ChemicalLookupAdvisory.text(isSearching),
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = VineColors.BrandTrack,
            )
        }
        if (!isSearching) {
            Text(
                ChemicalLookupAdvisory.REPEAT_HINT_TEXT,
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
    }
}

/**
 * A7: the per-basis vineyard default-rate chooser shown on the Confirm step.
 *
 * Mirrors the iOS "Default Rates" editor section: the registered label rates
 * are the authority and are never edited here — this only records which
 * registered option the vineyard doses by, and (for a label band) the exact
 * authorised figure.
 */
@Composable
private fun DefaultRatesSection(
    selection: ChemicalDefaultRateSelection,
    doseTexts: Map<ChemicalDefaultRateBasis, String>,
    doseErrors: Map<ChemicalDefaultRateBasis, String>,
    onSelect: (ChemicalDefaultRateOption, ChemicalDefaultRateBasis) -> Unit,
    onDoseTextChange: (ChemicalDefaultRateBasis, String) -> Unit,
    onSetDose: (ChemicalDefaultRateBasis) -> Unit,
    onResetDose: (ChemicalDefaultRateBasis) -> Unit,
) {
    val vine = LocalVineColors.current
    SectionLabel("Default rates")
    selection.plan.groups.forEach { group ->
        DefaultRateGroupCard(
            group = group,
            selection = selection,
            doseText = doseTexts[group.basis].orEmpty(),
            doseError = doseErrors[group.basis],
            onSelect = { onSelect(it, group.basis) },
            onDoseTextChange = { onDoseTextChange(group.basis, it) },
            onSetDose = { onSetDose(group.basis) },
            onResetDose = { onResetDose(group.basis) },
        )
    }
    // Pinned copy shared with iOS — including the honest no-state footnote
    // when the label conditions rates by state and no vineyard state exists
    // anywhere in the current backend contract (it never guesses one).
    Text(
        com.rork.vinetrack.data.chemical.ChemicalDefaultRateCopy.footer(selection.plan),
        fontSize = 11.sp,
        color = vine.textSecondary,
    )
}

@Composable
private fun DefaultRateGroupCard(
    group: ChemicalDefaultRateGroup,
    selection: ChemicalDefaultRateSelection,
    doseText: String,
    doseError: String?,
    onSelect: (ChemicalDefaultRateOption) -> Unit,
    onDoseTextChange: (String) -> Unit,
    onSetDose: () -> Unit,
    onResetDose: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            group.basis.label.uppercase(),
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            color = vine.textSecondary,
        )
        if (group.isEmpty) {
            // The label states nothing on this basis — say that, and never
            // invent one by converting from the other basis.
            Text(group.emptyStatement, fontSize = 12.sp, color = vine.textSecondary)
        } else {
            val inForce = selection.resolvedOption(group.basis)
            if (group.requiresChoice && selection.selectedIds[group.basis] == null) {
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        Icons.Filled.PanTool,
                        contentDescription = null,
                        tint = VineColors.Warning,
                        modifier = Modifier.size(14.dp),
                    )
                    Text(
                        "The label registers more than one " +
                            group.basis.label.lowercase() +
                            (selection.plan.jurisdiction?.let { " rate for ${it.displayName}" }
                                ?: " rate") +
                            ". Choose the one this vineyard uses.",
                        fontSize = 12.sp,
                        color = VineColors.Warning,
                    )
                }
            }
            group.options.forEach { option ->
                val isInForce = inForce?.id == option.id
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onSelect(option) },
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    RadioButton(selected = isInForce, onClick = { onSelect(option) })
                    Column(
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                        modifier = Modifier.weight(1f).padding(vertical = 8.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                option.displayRate,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                            )
                            if (option.isLabelRange) {
                                ChemicalPill("label range", VineColors.Olive)
                            }
                            if (option.id == group.recommendedOptionId) {
                                group.recommendation.badge?.let {
                                    ChemicalPill(it, VineColors.Success)
                                }
                            }
                            selection.plan.jurisdiction?.let { j ->
                                if (!option.appliesIn(j)) {
                                    ChemicalPill(
                                        "Not registered for ${j.displayName}",
                                        VineColors.Warning,
                                    )
                                }
                            }
                        }
                        // Every condition keeps its own line — a condition
                        // detached from its number is not a condition.
                        option.conditions.forEach { condition ->
                            Text(
                                condition.summary,
                                fontSize = 10.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
            }
            // Exact-dose entry: only for a label BAND actually in force. The
            // registered range itself is never narrowed — the record keeps
            // the label's own bounds however this vineyard doses inside them.
            if (inForce != null && inForce.isLabelRange) {
                val bounds = inForce.authorisedBounds
                val chosen = selection.values[group.basis]
                if (chosen == null && bounds != null) {
                    Text(
                        "Any rate from ${formatChemicalNumber(bounds.first)} to " +
                            "${formatChemicalNumber(bounds.second)} ${inForce.rate.unit} is " +
                            "registered. Leave it blank to use " +
                            "${formatChemicalNumber(bounds.first)}.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        value = doseText,
                        onValueChange = onDoseTextChange,
                        label = { Text("This vineyard uses") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                    Text(inForce.rate.unit, fontSize = 12.sp, color = vine.textSecondary)
                    TextButton(onClick = onSetDose) { Text("Set") }
                }
                doseError?.let { WarningLine(it) }
                if (chosen != null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            "The registered rate stays ${inForce.displayRate}.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                        TextButton(onClick = onResetDose) { Text("Reset") }
                    }
                }
            }
        }
    }
}
