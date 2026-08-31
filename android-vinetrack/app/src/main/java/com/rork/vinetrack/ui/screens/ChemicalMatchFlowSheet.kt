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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateDisplay
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateGroup
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateOption
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateSelection
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalJurisdiction
import com.rork.vinetrack.data.chemical.ChemicalLookupAdvisory
import com.rork.vinetrack.data.chemical.ChemicalRateGate
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalServerDefaultRateOptions
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.ChemicalVineyardScope
import com.rork.vinetrack.data.chemical.formatChemicalNumber
import com.rork.vinetrack.data.chemical.viticultural
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.ChemicalActiveIngredientRow
import com.rork.vinetrack.ui.components.ChemicalConflictCard
import com.rork.vinetrack.ui.components.ChemicalGroupSummaryLine
import com.rork.vinetrack.ui.components.ChemicalIdentityView
import com.rork.vinetrack.ui.components.ChemicalCompactRegisteredUsesView
import com.rork.vinetrack.ui.components.ChemicalLabelledLine
import com.rork.vinetrack.ui.components.ChemicalPill
import com.rork.vinetrack.ui.components.ChemicalVerificationBadge
import com.rork.vinetrack.ui.components.ChemicalVerificationEvidenceView
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * The operator-facing **Search → Review → Save** workflow — the Android mirror
 * of the iOS `ChemicalMatchFlowView`.
 *
 * # Why this is two screens and not four
 *
 * This flow used to run Search → Matched Product → Verify Chemical → Confirm.
 * For the ordinary case that was four screens to answer one question — "is this
 * the product on my drum?" — and the middle two were read-only, so an operator
 * who could see the answer was wrong had nowhere to fix it. iOS collapsed to
 * Search → Review → Save; the Portal reads the same way; Android was the
 * outlier, and a grower moving between a phone and the office met two different
 * registration processes for one product.
 *
 * Nothing was thrown away to get here. Every section the old VERIFY and CONFIRM
 * steps rendered is still rendered — identity, chemistry, activity groups,
 * grapevine uses and rates, compliance, documents, verification evidence and
 * the default-rate decision — they are simply one scrollable Review instead of
 * three gated pages. The parsers, resolver and write payload are untouched.
 *
 * # It collects evidence; it never sets trust
 *
 * Identifying a product and trusting a product are separate acts. Everything
 * here submits what it found to [ChemicalIntelligence.resolvedVerificationStatus],
 * and that computed value is what is displayed and saved — which is why there
 * is no "mark as verified" button anywhere in this file.
 */
private enum class MatchStep { SEARCH, REVIEW }

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
    /**
     * "Yes, check for updates" from the pre-research duplicate decision.
     *
     * Hands the record the operator already owns back to the host so it can be
     * RE-VERIFIED through its own registration identity. Deliberately not the
     * edit form: the operator asked whether the stored information is current,
     * which is a question only a re-check can answer.
     */
    onCheckForUpdates: (SavedChemical) -> Unit = {},
    /**
     * Raised when this flow CREATED a new saved chemical, immediately before it
     * closes.
     *
     * [onDismiss] cannot answer "did anything get written?" — a successful save
     * and a cancelled search both arrive through it. A caller that must act on
     * the new product (the Spray Calculator appends it to the open mix) would
     * otherwise have to infer creation from a side effect, and would go on
     * waiting for a product after the operator had backed out.
     *
     * Deliberately NOT raised when an existing record is updated: no new
     * product exists, so there is nothing for a caller to pick up.
     */
    onCreated: () -> Unit = {},
) {
    val vine = LocalVineColors.current
    val uriHandler = LocalUriHandler.current
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

    // ---- Pre-research duplicate decision (item 5) ----
    /**
     * Same-name records found in the operator's OWN store, shown before any
     * network call. Non-empty means the decision is on screen and no research
     * has run.
     */
    var samePrompt by remember { mutableStateOf<List<SavedChemical>>(emptyList()) }
    /**
     * Set once the operator has deliberately said "this is a different
     * product", so the decision is asked once per session rather than on
     * every re-search of the same name.
     */
    var duplicateDecision by remember {
        mutableStateOf<ChemicalStoreMatching.Decision?>(null)
    }

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

    /**
     * The ONLY route to a remote search (item 5).
     *
     * The operator's own Chemical Store is consulted FIRST, offline, and a
     * same-name record stops the flow before a single request is issued. The
     * old order — research, then notice the duplicate on the confirm screen —
     * spent the expensive call and the operator's wait before telling them
     * they already owned the product, and left a half-built record on screen
     * if they backed out of it.
     *
     * Declining costs exactly nothing: no lookup, no write.
     */
    fun attemptSearch() {
        if (!ChemicalLookupAdvisory.canStartSearch(query, searching, countryCode)) return
        if (duplicateDecision == null) {
            val matches = ChemicalStoreMatching.findByProductName(
                chemicals = state.savedChemicals,
                query = query,
                // A legacy record being re-matched is not a duplicate of itself.
                excludingId = existing?.id,
            )
            if (matches.isNotEmpty()) {
                samePrompt = matches
                return
            }
        }
        runSearch()
    }

    fun loadStructured(result: ChemicalInfoService.ChemicalSearchResult) {
        loadingStructured = true
        structuredError = null
        lookupFormType = null
        defaultSelection = null
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
                // Duplicate prevention on registration IDENTITY still runs —
                // it is a different question from the name check above, and it
                // is the only one that can prove two records are one product.
                duplicateOf = ChemicalStoreMatching.findByRegistrationIdentity(
                    chemicals = state.savedChemicals,
                    registration = intel.registration,
                    excludingId = existing?.id,
                )
                // Vineyard state is not recorded on Android profiles, so the
                // jurisdiction step is skipped — a weaker answer, never a
                // wrong one. The only-registered-rate rule still recommends.
                //
                // The options come from the SERVER's `default_rate_options`,
                // never from re-grouping `registered_uses` here. The device
                // contributes only the recommendation badge; the amounts and
                // the `option_key`/`rate_ids` identities are the register's.
                //
                // A server that sends no block yields an empty plan, and the
                // rate gate then offers the corrective actions. That is the
                // intended fail-closed outcome, not a gap to fill locally.
                defaultSelection = ChemicalDefaultRateSelection(
                    plan = ChemicalDefaultRate.plan(
                        serverOptions = lookup.defaultRateOptions
                            ?: ChemicalServerDefaultRateOptions(),
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
                when {
                    samePrompt.isNotEmpty() -> "Already in your Chemical Store"
                    step == MatchStep.SEARCH ->
                        if (existing == null) "Add Chemical" else "Match & Verify"
                    else -> "Review Chemical"
                },
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            if (samePrompt.isNotEmpty()) {
                // The decision, BEFORE any research. Nothing on this screen
                // issues a request or writes a record.
                SameNameDecision(
                    matches = samePrompt,
                    onCheckForUpdates = { chemical ->
                        samePrompt = emptyList()
                        duplicateDecision =
                            ChemicalStoreMatching.Decision.CheckForUpdates(chemical)
                        // No lookup is issued here. Re-verification owns the
                        // identity-keyed re-check, and it writes nothing until
                        // the operator saves.
                        onCheckForUpdates(chemical)
                    },
                    onKeepAsIs = {
                        // Zero research calls, zero writes, and the stored row
                        // untouched. The operator answered the question; there
                        // is nothing further to do, so the flow closes rather
                        // than dropping them back into a search they did not
                        // ask for.
                        samePrompt = emptyList()
                        duplicateDecision = ChemicalStoreMatching.Decision.KeepAsIs
                        onDismiss()
                    },
                )
            } else when (step) {
                MatchStep.SEARCH -> {
                    SectionLabel("Search for product")
                    OutlinedTextField(
                        value = query,
                        onValueChange = {
                            query = it
                            // A retyped name is a new question: the previous
                            // "different product" answer must not carry over
                            // and suppress the check for the new name.
                            duplicateDecision = null
                        },
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
                        onClick = { attemptSearch() },
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
                            OutlinedButton(onClick = { attemptSearch() }) { Text("Try Again") }
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
                                step = MatchStep.REVIEW
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

                MatchStep.REVIEW -> {
                    if (loadingStructured) {
                        // A1: while the lookup is in flight, the only honest
                        // content is "we are checking". Unresolved-identity
                        // warnings and empty authoritative fields must not
                        // render until an answer actually arrives — and a slow
                        // lookup is never treated as a failed one.
                        // ONE message. This used to show a spinner line
                        // ("Looking up product details…") AND the green
                        // advisory panel underneath, which read as two
                        // separate things happening and made the wait feel
                        // like a stall rather than one job in progress.
                        ChemicalEnrichmentNotice()
                    }

                    structuredError?.let { message ->
                        WarningLine(message)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = {
                                selected?.let { loadStructured(it) }
                            }) { Text("Try Again") }
                            OutlinedButton(onClick = onEnterManually) { Text("Enter Manually") }
                        }
                    }

                    val intel = intelligence
                    if (intel != null && !loadingStructured) {
                        val resolved = intel.resolvedVerificationStatus
                        val productName = intel.registration?.registeredProductName
                            ?: selected?.name ?: query
                        // What the STORE will hold: grapevine directions plus
                        // product-level rates. The review shows exactly this,
                        // so nothing is displayed that will not be saved and
                        // nothing is saved that was not displayed.
                        val operational = ChemicalVineyardScope.operationalUses(intel.registeredUses)

                        ChemicalConflictCard(intel.verification.conflicts)

                        // ---- Identity ----
                        SectionLabel("Identity")
                        ChemicalIdentityView(
                            productName = productName,
                            registration = intel.registration,
                            productCategory = intel.productCategory,
                        )
                        // Identity strength is decided by whether a register and a
                        // number are actually present — never by how confident the
                        // lookup felt.
                        val registration = intel.registration
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
                        ChemicalStoreMatching.formDescription(lookupFormType)
                            .takeIf { it.isNotEmpty() }
                            ?.let {
                                ChemicalLabelledLine("Formulation", lookupFormType.orEmpty())
                            }
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

                        // ---- Chemistry ----
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
                            SectionLabel("Activity groups")
                            ChemicalGroupSummaryLine(intel.activityGroups)
                            Text(
                                "Derived from the active ingredients above.",
                                fontSize = 11.sp,
                                color = vine.textSecondary,
                            )
                        }

                        // ---- The save contract, measured BEFORE anything is
                        // rendered that depends on it ----
                        //
                        // Evaluated here rather than beside the Save button so
                        // the reason a save is blocked can be shown next to the
                        // control that fixes it. It used to be computed after
                        // the entire registered-use list, which is why the
                        // explanation appeared only at the very bottom: an
                        // operator had to scroll past every target to find out
                        // why Add to Chemical Store was greyed out.
                        val gate = ChemicalSaveContract.evaluate(
                            productName = productName,
                            productCategory = intel.productCategory,
                            intelligence = ChemicalVineyardScope.scoped(intel),
                            defaults = defaultSelection,
                        )
                        val baseline = remember(existing?.id, countryCode) {
                            ChemicalSaveContract.baselineViolationCodes(existing, countryCode)
                        }
                        val blocking = ChemicalSaveContract.blockingViolations(gate, baseline)

                        // ---- Registered rate: BEFORE the target list ----
                        //
                        // The rate is what the operator came to see. It sat
                        // underneath a list that can run to dozens of weeds,
                        // so the most important line on the screen was the
                        // last thing they could reach.
                        HorizontalDivider()
                        val rateGate = ChemicalRateGate.decide(
                            selection = defaultSelection,
                            grapevineUses = intel.registeredUses.viticultural(),
                        )
                        when (rateGate) {
                            ChemicalRateGate.Decision.RegisteredRateStated -> {
                                RegisteredRateSection(intel.registeredUses.viticultural())
                            }

                            ChemicalRateGate.Decision.NoCanonicalRate -> {
                                NoCanonicalRatePanel(
                                    onRetry = { selected?.let { loadStructured(it) } },
                                    labelUrl = intel.registration?.let {
                                        it.regulatorLabelUrl
                                            ?: it.labelReference
                                            ?: it.primaryLabelUrl
                                    },
                                    onOpenLabel = { url -> uriHandler.openUri(url) },
                                    onEnterManually = onEnterManually,
                                    onChangeProduct = { changeProduct() },
                                )
                            }

                            ChemicalRateGate.Decision.NotApplicable -> Unit
                        }

                        // The blocking reasons sit HERE, beside the control
                        // that resolves them, not after the target list.
                        if (blocking.isNotEmpty()) {
                            SaveBlockedNotice(blocking.map { it.message })
                        }

                        // ---- Grapevine use targets, compact ----
                        //
                        // The registered rate is stated ONCE, in the Registered
                        // rate section above. The label-rates block that used to
                        // repeat it here is gone, and so are the full per-target
                        // crop/rate/WHP/re-entry/restrictions cards: one printed
                        // direction arrives as dozens of rows differing only in
                        // target, and rendering the same legal text for each
                        // buried the decision the operator came to make. The
                        // compact list shows target names only — the COMPLETE
                        // registered_uses data is saved unchanged.
                        HorizontalDivider()
                        ChemicalCompactRegisteredUsesView(operational)
                        // NOTE: no other-crop disclosure here, deliberately.
                        //
                        // This label may register macadamias, cereals and
                        // citrus. None of it is this vineyard's operational
                        // data, none of it is saved, and listing it in the
                        // customer review made an operator scroll past crops
                        // they do not grow to reach the grapevine rate they
                        // came for. The vineyard-only WRITE boundary is
                        // unchanged; this is only about what is shown.

                        // ---- Documents and evidence ----
                        HorizontalDivider()
                        SectionLabel("Documents and evidence")
                        ChemicalLabelledLine(
                            "Official label",
                            intel.registration?.labelReference?.takeIf { it.isNotBlank() }
                                ?: "Not supplied",
                        )
                        ChemicalLabelledLine(
                            "Product page",
                            intel.registration?.manufacturerProductUrl?.takeIf { it.isNotBlank() }
                                ?: "Not supplied",
                        )
                        masterMatch?.let { master ->
                            ChemicalLabelledLine(
                                "Source",
                                "Master catalogue · rev ${master.masterRevision}",
                            )
                        }
                        ChemicalVerificationEvidenceView(intel.verification, resolved)
                        Text(resolved.detail, fontSize = 11.sp, color = vine.textSecondary)

                        // ---- Save ----
                        // `gate`, `baseline` and `blocking` were measured before
                        // the Default rate section so the explanation could be
                        // rendered beside the control that fixes it.
                        HorizontalDivider()

                        duplicateOf?.let { dup ->
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
                                        if (saving || blocking.isNotEmpty()) return@Button
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
                                    enabled = !saving && blocking.isEmpty(),
                                    modifier = Modifier.fillMaxWidth(),
                                ) { Text("Update existing record") }
                            }
                        }

                        if (duplicateOf == null) {
                            Button(
                                onClick = {
                                    if (saving) return@Button
                                    // The contract is re-checked here, not
                                    // inherited from the button: a save path
                                    // that trusts its own button writes
                                    // whatever a future caller forgets to gate.
                                    if (ChemicalSaveContract.blockingViolations(
                                            ChemicalSaveContract.evaluate(
                                                productName = productName,
                                                productCategory = intel.productCategory,
                                                intelligence = ChemicalVineyardScope.scoped(intel),
                                                defaults = defaultSelection,
                                            ),
                                            baseline,
                                        ).isNotEmpty()
                                    ) {
                                        return@Button
                                    }
                                    saving = true
                                    val input = ChemicalStoreMatching.inputFor(
                                        existing, productName, intel, masterMatch,
                                        formTypeRaw = lookupFormType,
                                        defaults = defaultSelection,
                                    )
                                    if (existing == null) {
                                        vm.createSavedChemical(input) { ok ->
                                            saving = false
                                            if (ok) {
                                                onCreated()
                                                onDismiss()
                                            }
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
                                enabled = !saving && blocking.isEmpty(),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(
                                    if (existing == null) "Add to Chemical Store"
                                    else "Save Chemical",
                                )
                            }
                        }

                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            // The registered identity is never editable in place:
                            // leaving it is an intentional act that returns to the
                            // register search.
                            TextButton(onClick = { changeProduct() }) { Text("Change Product") }
                            TextButton(onClick = onEnterManually) { Text("Enter Manually") }
                        }
                        // NOTE: the sentence about legacy Active Ingredient and
                        // Chemical Group columns being "kept in step for
                        // compatibility" was removed from here deliberately. It
                        // described VineTrack's storage layout, which is not a
                        // fact an operator can act on, and it occupied the space
                        // where the actual outcome of pressing Save belongs.
                    }
                }
            }

            Spacer(Modifier.height(4.dp))
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    }

    LaunchedEffect(Unit) {
        // A prefilled name is a re-match of a record the operator already owns,
        // so the same-name check would always fire on itself — `existing` is
        // excluded from it, and the search runs as before.
        if (prefillQuery.trim().isNotEmpty() && results.isEmpty()) attemptSearch()
    }
}

/**
 * The same-name decision, shown BEFORE any chemical research runs.
 *
 * # One question, two answers
 *
 * The operator already owns this product, so the only useful thing to ask is
 * whether what VineTrack holds is still current. Both answers are cheap: "No"
 * costs nothing at all, and "Yes" spends the lookup on re-checking the record
 * they already have rather than on building a second copy of it.
 *
 * The old "This is a different product — search the register" escape hatch is
 * gone. It sat as a peer of the other options and let a duplicate chemical be
 * created in a single tap, and a duplicated chemical in a resistance context is
 * a duplicated chemistry — two records that rotate independently and warn
 * about nothing. A genuinely different registration is still reachable; it is
 * simply reached by looking at the stored product first.
 */
@Composable
private fun SameNameDecision(
    matches: List<SavedChemical>,
    onCheckForUpdates: (SavedChemical) -> Unit,
    onKeepAsIs: () -> Unit,
) {
    val vine = LocalVineColors.current
    matches.forEach { chemical ->
        Text(
            ChemicalStoreMatching.sameNameQuestion(chemical.displayName),
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = vine.textPrimary,
        )
        val subtitle = listOfNotNull(
            chemical.activeIngredient.takeIf { it.isNotBlank() },
            chemical.manufacturer.takeIf { it.isNotBlank() },
        ).joinToString(" · ")
        if (subtitle.isNotEmpty()) {
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(VineColors.Info.copy(alpha = 0.08f))
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Button(
                onClick = { onCheckForUpdates(chemical) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(ChemicalStoreMatching.CHECK_FOR_UPDATES_ACTION) }
            OutlinedButton(
                onClick = onKeepAsIs,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(ChemicalStoreMatching.KEEP_AS_IS_ACTION) }
        }
    }
    Text(
        "Nothing has been looked up and nothing has been changed. Checking for " +
            "updates re-checks the product you already have — it never adds a " +
            "second copy, and your saved chemical is only changed if you save it.",
        fontSize = 11.sp,
        color = vine.textSecondary,
    )
}

/**
 * The remaining requirements, in the contract's own words.
 *
 * Shown instead of a disabled button with no explanation: an operator who
 * cannot save deserves to know precisely which registered fact is missing.
 */
/**
 * The fail-closed rate panel: what happened, and four real ways forward.
 *
 * # Why this exists
 *
 * When the label yields no canonical rate option, the product genuinely cannot
 * be added as a label-checked chemical. The screen used to say so and stop —
 * a disabled Save, an instruction to "enter the rate from the label", and no
 * field to enter it into. Every route out of that state required the operator
 * to guess that backing out and starting again was allowed.
 *
 * Each action below is a real move, and none of them writes anything:
 *
 * ```text
 * Retry label details  re-runs enrichment for the SAME registration
 * Open official label  opens the eLabel so they can read it themselves
 * Enter manually       leaves the structured flow, plainly Not checked
 * Change product       returns to register selection, discarding the draft
 * ```
 *
 * There is deliberately no rate field. A number typed here would carry no
 * `option_key` and no `rate_ids`, so nothing could ever show it corresponded to
 * a printed direction — it would be an operator's guess wearing the appearance
 * of a label-checked rate.
 */
@Composable
private fun NoCanonicalRatePanel(
    onRetry: () -> Unit,
    labelUrl: String?,
    onOpenLabel: (String) -> Unit,
    onEnterManually: () -> Unit,
    onChangeProduct: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VineColors.Warning.copy(alpha = 0.10f))
            .padding(12.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        SectionLabel("Default rate")
        Text(
            ChemicalRateGate.NO_CANONICAL_RATE_MESSAGE,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = VineColors.Warning,
        )
        Text(
            ChemicalRateGate.MANUAL_FALLBACK_NOTICE,
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
        // Retry first: a label that failed to parse once often succeeds on a
        // second pass, and it is the only action that keeps the operator on
        // the product they already chose.
        Button(onClick = onRetry, modifier = Modifier.fillMaxWidth()) {
            Text(ChemicalRateGate.ACTION_RETRY)
        }
        labelUrl?.takeIf { it.isNotBlank() }?.let { url ->
            OutlinedButton(
                onClick = { onOpenLabel(url) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(ChemicalRateGate.ACTION_OPEN_LABEL) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onEnterManually) {
                Text(ChemicalRateGate.ACTION_ENTER_MANUALLY)
            }
            TextButton(onClick = onChangeProduct) {
                Text(ChemicalRateGate.ACTION_CHANGE_PRODUCT)
            }
        }
    }
}

@Composable
private fun SaveBlockedNotice(messages: List<String>) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VineColors.Warning.copy(alpha = 0.10f))
            .padding(12.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            "Before this can be saved",
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            color = VineColors.Warning,
        )
        messages.forEach { message ->
            Text("• $message", fontSize = 12.sp, color = vine.textSecondary)
        }
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
 * The ONE thing shown while the label is being read.
 *
 * The review step used to render a spinner line ("Looking up product details…")
 * AND the green advisory panel underneath it. Two panels for one job reads as
 * two separate things happening, and when neither finishes quickly it looks
 * like the screen has stalled rather than that one piece of work is running.
 *
 * A heading that names the work, a sentence that says what is being read and
 * how long it can take, and nothing else. No percentage and no estimated
 * finish: both would be invented, and a progress bar that sticks at 90% is a
 * worse lie than an honest wait. Cancel stays available above this — it is the
 * sheet's own dismiss, and is never taken away.
 */
@Composable
private fun ChemicalEnrichmentNotice() {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VineColors.BrandTrack.copy(alpha = 0.12f))
            .padding(horizontal = 12.dp, vertical = 12.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = VineColors.BrandTrack,
            )
            Text(
                ChemicalLookupAdvisory.ENRICHMENT_TITLE,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                color = VineColors.BrandTrack,
            )
        }
        Text(
            ChemicalLookupAdvisory.ENRICHMENT_BODY,
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
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
 * What the label registers on grapevines, STATED and not asked.
 *
 * # Why there is no rate control here any more
 *
 * This was a per-basis chooser with an exact-dose field, and adding a product
 * could not be finished until a single figure was typed into it. CHATEAU
 * registers `560–700 g/ha`; the operator was being asked what they were
 * applying with no block, growth stage or carrier volume in front of them, and
 * the only cheap answer was whichever endpoint the screen made easiest to tap.
 *
 * A range is a complete record of the registration, so it is enough to save.
 * The band travels intact on `registered_uses` to the Spray Calculator —
 * including when planning a Program Step — where the applied dose is chosen
 * once, against a real spray.
 *
 * Nothing here writes `default_rates`, and nothing here mints an `option_key`,
 * a `rate_id` or a `direction_id`: those are the server's to issue.
 */
@Composable
private fun RegisteredRateSection(grapevineUses: List<ChemicalRegisteredUse>) {
    val vine = LocalVineColors.current
    val lines = remember(grapevineUses) { registeredRateLines(grapevineUses) }
    SectionLabel("Registered rate")
    if (lines.isEmpty()) {
        Text(
            "No registered grapevine rate was read from this label.",
            fontSize = 13.sp,
            color = vine.textSecondary,
        )
    } else {
        lines.forEach { line ->
            Text(
                line,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
            )
        }
    }
    Text(
        "The registered label rate is saved with this chemical. Choose the exact " +
            "rate being applied when planning each spray.",
        fontSize = 11.sp,
        color = vine.textSecondary,
    )
}

/**
 * One line per distinct usable registered grapevine rate, in label order.
 *
 * A band is named as a band — `Registered label range: 560–700 g/ha` — so it
 * can never be read as a dose somebody chose. Delegates to the shared
 * projection so this review and the Chemical Store card state the SAME line
 * from the same rule.
 */
private fun registeredRateLines(uses: List<ChemicalRegisteredUse>): List<String> =
    ChemicalDefaultRateDisplay.registeredRateSummaries(uses)
