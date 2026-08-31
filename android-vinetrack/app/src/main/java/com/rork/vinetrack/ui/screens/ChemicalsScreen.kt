package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateDisplay
import com.rork.vinetrack.data.chemical.ChemicalEditOutcome
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalJurisdiction
import com.rork.vinetrack.data.chemical.ChemicalJurisdictionSuitability
import com.rork.vinetrack.data.chemical.ChemicalManualEntry
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalReverification
import com.rork.vinetrack.data.chemical.ChemicalReverifyFlow
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSaveViolation
import com.rork.vinetrack.data.chemical.ChemicalSaveViolationCode
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.chemical.ChemicalVineyardScope
import com.rork.vinetrack.data.chemical.clearedDefaultRates
import com.rork.vinetrack.data.chemical.legacyGroupProjection
import com.rork.vinetrack.data.chemical.viticultural
import com.rork.vinetrack.ui.components.ChemicalJurisdictionChip
import com.rork.vinetrack.ui.components.ChemicalJurisdictionMismatchBanner
import com.rork.vinetrack.ui.components.ChemicalCompactRegisteredUsesView
import com.rork.vinetrack.ui.components.ChemicalVerificationBadge
import com.rork.vinetrack.ui.components.ChemicalStoreFilter
import com.rork.vinetrack.ui.components.chemicalVerificationTint
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.ProductCategories
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitToBase
import java.util.UUID
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Brand colour for the spray chemicals surface (matches the Spray tool). */
private val ChemTint: Color = VineColors.Info

/** Chemical display units, mirroring the iOS `ChemicalUnit` raw values. */
private val chemicalUnits: List<String> = listOf("Litres", "mL", "Kg", "g")

/**
 * Spray chemicals library — the saved products reused across spray records.
 * Owners/managers can add, edit, and archive chemicals (including the
 * owner/manager-only cost per unit); other members get a read-only list with
 * pricing hidden, matching the iOS `ChemicalsManagementView` financial gating.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChemicalsScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"
    // Cost editing/visibility mirrors the spray form's canViewFinancials gate.
    val canViewFinancials = canManage

    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<SavedChemical?>(null) }
    var pendingDelete by remember { mutableStateOf<SavedChemical?>(null) }
    var search by remember { mutableStateOf("") }
    /**
     * Null = "All". Filters on the RESOLVED status, never on display text.
     *
     * A customer-facing filter rather than a raw status: "Not checked" covers
     * both `needs_match` and `unverified`, which are one fact to an operator.
     */
    var verificationFilter by remember { mutableStateOf<ChemicalStoreFilter?>(null) }
    /** Non-null when running the Search → Match → Verify → Confirm wizard. */
    var matchingNew by remember { mutableStateOf(false) }
    var matching by remember { mutableStateOf<SavedChemical?>(null) }
    /** Non-null when re-checking an already-identified product. */
    var reverifying by remember { mutableStateOf<SavedChemical?>(null) }
    /**
     * The accepted-but-unsaved result of a re-check.
     *
     * Non-null means the operator has reviewed differences and chosen to use
     * them, and the merged record is now open in the ordinary editor awaiting
     * their explicit Save. Nothing has been written at this point.
     */
    var reverifyDraft by remember { mutableStateOf<ChemicalReverifyFlow.Draft?>(null) }

    /** The country a re-check would be keyed on, from the vineyard profile. */
    val countryCode: String = remember(state.selectedVineyardId, state.vineyards) {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(
                state.vineyards.firstOrNull { it.id == state.selectedVineyardId }?.country,
            ),
        )
    }

    // Counts come from each record's resolved verification status, so a stale
    // stored status can never inflate the "Verified" tally.
    val statusCounts: Map<ChemicalVerificationStatus, Int> =
        remember(state.savedChemicals) {
            state.savedChemicals.groupingBy { it.verificationStatus }.eachCount()
        }
    val needsAttentionCount: Int = remember(statusCounts) {
        ChemicalStoreFilter.needsAttention.sumOf { statusCounts[it] ?: 0 }
    }

    val filteredChemicals = remember(state.savedChemicals, search, verificationFilter) {
        state.savedChemicals.filter { chem ->
            val matchesSearch = search.isBlank() ||
                chem.displayName.contains(search.trim(), true) ||
                chem.manufacturer.contains(search.trim(), true)
            val matchesStatus = verificationFilter?.matches(chem.verificationStatus) ?: true
            matchesSearch && matchesStatus
        }
    }
    // Surfaced when the backend refuses a permanent delete because the chemical
    // is referenced by a record. Offers "Archive instead".
    var inUseChem by remember { mutableStateOf<SavedChemical?>(null) }
    var inUseMessage by remember { mutableStateOf("") }

    /**
     * Whether a chemical is referenced by any spray record on this device,
     * mirroring iOS `isSavedChemicalInUseLocally`. When in use, only Archive is
     * offered (the backend would reject a permanent delete anyway).
     */
    fun isInUseLocally(chem: SavedChemical): Boolean =
        state.sprayRecords.any { record ->
            record.tanks.orEmpty().any { tank ->
                tank.chemicals.any { it.savedChemicalId == chem.id }
            }
        }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Chemicals") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    // Adding a chemical starts with matching it to a registered
                    // product rather than with a blank form, so structured
                    // intelligence is the default path and manual entry the
                    // deliberate fallback.
                    onClick = { matchingNew = true },
                    containerColor = ChemTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add chemical") }
            }
        },
    ) { padding ->
        if (state.savedChemicals.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.Science,
                title = "No Chemicals",
                message = if (canManage) {
                    "Add chemicals to quickly select them in spray records."
                } else {
                    "The vineyard owner or manager hasn't added any saved chemicals yet."
                },
                actionLabel = if (canManage) "Add chemical" else null,
                onAction = if (canManage) ({ matchingNew = true }) else null,
                modifier = Modifier.fillMaxSize().padding(padding),
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (!canManage) {
                    item(key = "locked-note") {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Filled.Lock, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                            Text(
                                "Setup data is managed by vineyard owners and managers.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
                item(key = "search") {
                    OutlinedTextField(
                        value = search,
                        onValueChange = { search = it },
                        placeholder = { Text("Search chemicals...") },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (needsAttentionCount > 0) {
                    item(key = "needs-attention") {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(VineColors.Warning.copy(alpha = 0.10f))
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(
                                Icons.Filled.Science,
                                contentDescription = null,
                                tint = VineColors.Warning,
                                modifier = Modifier.size(16.dp),
                            )
                            Text(
                                // "needs verification" reads as a verdict on the
                                // chemical. What is actually true is duller: these
                                // records need someone to look at them.
                                if (needsAttentionCount == 1) {
                                    "1 chemical needs attention"
                                } else {
                                    "$needsAttentionCount chemicals need attention"
                                },
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                color = VineColors.Warning,
                            )
                        }
                    }
                }
                item(key = "verification-filters") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        VerificationFilterPill(
                            label = "All",
                            count = state.savedChemicals.size,
                            selected = verificationFilter == null,
                            tint = ChemTint,
                        ) { verificationFilter = null }
                        // One pill per thing the operator can act on. Conflict
                        // still stands alone — lumping it in with unchecked
                        // records would hide the one case that needs a human —
                        // but the two "nobody has checked this" statuses share
                        // a single pill instead of rendering twice with the
                        // same label and different counts.
                        ChemicalStoreFilter.entries.forEach { filter ->
                            VerificationFilterPill(
                                label = filter.label,
                                count = filter.statuses.sumOf { statusCounts[it] ?: 0 },
                                selected = verificationFilter == filter,
                                tint = chemicalVerificationTint(filter.tintStatus),
                            ) {
                                verificationFilter =
                                    if (verificationFilter == filter) null else filter
                            }
                        }
                    }
                }
                if (filteredChemicals.isEmpty()) {
                    item(key = "no-match") {
                        Text(
                            "No chemicals match your search.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(vertical = 12.dp),
                        )
                    }
                }
                items(filteredChemicals, key = { it.id }) { chem ->
                    ChemicalRow(
                        chemical = chem,
                        canManage = canManage,
                        canViewFinancials = canViewFinancials,
                        // Eligibility is the domain's call, never the UI's.
                        // Duplicating the rule here would let the button and the
                        // behaviour drift apart, and the interesting case — a
                        // legacy record holding a registration number but never
                        // matched — is exactly the one a hand-written check gets
                        // wrong.
                        canReverify = ChemicalReverification.isOffered(chem, countryCode),
                        vineyardCountry = countryCode,
                        onEdit = { if (canManage) editing = chem },
                        onDelete = { if (canManage) pendingDelete = chem },
                        onMatchVerify = { if (canManage) matching = chem },
                        onReverify = { if (canManage) reverifying = chem },
                    )
                }
            }
        }
    }

    if (matchingNew) {
        ChemicalMatchFlowSheet(
            vm = vm,
            state = state,
            existing = null,
            prefillQuery = "",
            onDismiss = { matchingNew = false },
            onEnterManually = { matchingNew = false; creating = true },
            // "Yes, check for updates" RE-VERIFIES the record the operator
            // already owns. Deliberately not the edit form: they asked whether
            // the stored information is still current, and only a re-check
            // against the register can answer that. No lookup has run yet, and
            // re-verification writes nothing until they save.
            onCheckForUpdates = { chem -> matchingNew = false; reverifying = chem },
        )
    }
    matching?.let { chem ->
        // Legacy cleanup: the wizard opens pre-filled with the name the grower
        // already uses and updates THIS record on confirm.
        ChemicalMatchFlowSheet(
            vm = vm,
            state = state,
            existing = chem,
            prefillQuery = chem.displayName,
            onDismiss = { matching = null },
            onEnterManually = { matching = null; editing = chem },
            onCheckForUpdates = { found -> matching = null; reverifying = found },
        )
    }
    reverifying?.let { chem ->
        ChemicalReverifySheet(
            state = state,
            chemical = chem,
            onDismiss = { reverifying = null },
            // The re-check itself writes nothing. Accepting an update produces
            // an in-memory draft that opens in the ordinary editor, where one
            // explicit Save performs the single database update.
            onUseUpdatedInformation = { draft ->
                reverifying = null
                reverifyDraft = draft
            },
        )
    }
    reverifyDraft?.let { draft ->
        ChemicalFormSheet(
            vm = vm,
            existing = draft.chemical,
            canViewFinancials = canViewFinancials,
            onDismiss = { reverifyDraft = null },
            state = state,
            // Carried explicitly: opened on the draft, the editor's own
            // "has the chemistry changed?" test would compare the draft
            // against itself and omit the intelligence columns entirely.
            pendingIntelligence = draft.intelligence,
            staleDefaultBases = draft.staleDefaultBases,
        )
    }
    if (creating) {
        ChemicalFormSheet(
            vm = vm,
            existing = null,
            canViewFinancials = canViewFinancials,
            onDismiss = { creating = false },
            state = state,
        )
    }
    editing?.let { chem ->
        ChemicalFormSheet(
            vm = vm,
            existing = chem,
            canViewFinancials = canViewFinancials,
            onDismiss = { editing = null },
            state = state,
        )
    }
    pendingDelete?.let { chem ->
        val inUse = isInUseLocally(chem)
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(if (inUse) "Archive ${chem.displayName}?" else "Delete or archive ${chem.displayName}?") },
            text = {
                Text(
                    if (inUse) {
                        "Archive this chemical? It will be hidden from active chemical lists but kept for historical records."
                    } else {
                        "Archive hides this chemical but keeps it for historical records. Delete Permanently removes it entirely — only available because it has not been used in any spray records on this device. This cannot be undone."
                    }
                )
            },
            confirmButton = {
                Column {
                    TextButton(onClick = {
                        vm.deleteSavedChemical(chem.id) {}
                        pendingDelete = null
                    }) { Text("Archive Chemical") }
                    if (!inUse) {
                        TextButton(onClick = {
                            val target = chem
                            pendingDelete = null
                            vm.hardDeleteSavedChemical(target.id) { outcome ->
                                if (outcome is SavedChemicalRepository.HardDeleteOutcome.InUse) {
                                    inUseChem = target
                                    inUseMessage = outcome.message
                                }
                            }
                        }) { Text("Delete Permanently", color = VineColors.Destructive) }
                    }
                }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }

    // Backend rejected a permanent delete (chemical referenced by a record).
    inUseChem?.let { chem ->
        AlertDialog(
            onDismissRequest = { inUseChem = null },
            title = { Text("Cannot Delete") },
            text = { Text(inUseMessage) },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteSavedChemical(chem.id) {}
                    inUseChem = null
                }) { Text("Archive Instead") }
            },
            dismissButton = { TextButton(onClick = { inUseChem = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ChemicalRow(
    chemical: SavedChemical,
    canManage: Boolean,
    canViewFinancials: Boolean,
    canReverify: Boolean,
    vineyardCountry: String,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onMatchVerify: () -> Unit,
    onReverify: () -> Unit,
) {
    val vine = LocalVineColors.current
    val fmt = LocalRegionFormatter.current
    val status = chemical.verificationStatus
    VineyardCard(modifier = if (canManage) Modifier.clickable { onEdit() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        chemical.displayName,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                        fontSize = 16.sp,
                    )
                    ChemicalVerificationBadge(status, compact = true)
                }
                // A verified FOREIGN registration must never read as verified
                // for this vineyard: its label facts belong to another country's
                // law. Identity and chemistry still stand — only label authority
                // is marked as not applicable here.
                val suitability = ChemicalJurisdiction.suitability(chemical, vineyardCountry)
                if (suitability is ChemicalJurisdictionSuitability.Mismatch) {
                    ChemicalJurisdictionChip(
                        suitability.registrationCountry,
                        suitability.vineyardCountry,
                    )
                }
                // Active ingredient leads the subtitle (matches iOS ChemicalDetailRow);
                // manufacturer follows when present.
                val subtitle = buildList {
                    chemical.activeIngredient.takeIf { it.isNotBlank() }?.let { add(it) }
                    chemical.manufacturer.takeIf { it.isNotBlank() }?.let { add(it) }
                }.joinToString(" · ")
                if (subtitle.isNotEmpty()) {
                    Text(subtitle, fontSize = 13.sp, color = vine.textSecondary)
                }
                // Category / group / target-problem chips. The group chip is
                // DERIVED from structured actives whenever they exist; the legacy
                // free-text column is only a fallback for records that have not
                // been matched yet.
                val structuredGroups = chemical.resolvedIntelligence.activityGroups
                val groupChip = if (structuredGroups.isNotEmpty()) {
                    structuredGroups.legacyGroupProjection()
                } else {
                    chemical.chemicalGroup.takeIf { it.isNotBlank() }
                }
                val chips = buildList {
                    chemical.productCategory.takeIf { it.isNotBlank() }?.let { add(ProductCategories.label(it)) }
                    groupChip?.takeIf { it.isNotBlank() }?.let { add(it) }
                    chemical.problem.takeIf { it.isNotBlank() }?.let { add(it) }
                    chemical.modeOfAction.takeIf { it.isNotBlank() }?.let { add("MOA $it") }
                }
                if (chips.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        chips.take(3).forEach { ChemChip(it) }
                    }
                }
                // The OPERATIONAL rate line.
                //
                // `default_rates` is the only thing that may be shown as this
                // vineyard's confirmed rate. The legacy `rates`/`rate_per_ha`
                // columns are still rendered for a genuinely legacy record,
                // clearly marked as such, but a structured product with no
                // confirmed default says so instead of borrowing a number
                // nobody agreed to. Units come from inside each default slot
                // — never `chemical.unit`, which is the INVENTORY unit and
                // would print a 560 g/ha default as "560 Kg/ha".
                val confirmedLine = ChemicalDefaultRateDisplay.line(chemical)
                if (confirmedLine != null) {
                    Text(
                        confirmedLine,
                        fontSize = 13.sp,
                        color = if (ChemicalDefaultRateDisplay.needsConfirmation(chemical)) {
                            VineColors.Warning
                        } else {
                            vine.textSecondary
                        },
                        fontWeight = if (ChemicalDefaultRateDisplay.needsConfirmation(chemical)) {
                            FontWeight.Medium
                        } else {
                            FontWeight.Normal
                        },
                    )
                } else {
                    // Legacy/manual record: no structured intelligence at all,
                    // so its own stored numbers remain the best answer there is.
                    val legacyLines = buildList {
                        chemical.ratePerHaDisplay?.takeIf { it > 0 }
                            ?.let {
                                add(
                                    "${trimNum(fmt.sprayRateValue(it))} " +
                                        "${chemical.unit}/${fmt.sprayRateAreaAbbreviation}",
                                )
                            }
                        chemical.ratePer100LDisplay?.takeIf { it > 0 }
                            ?.let { add("${trimNum(it)} ${chemical.unit}/100L") }
                    }
                    if (legacyLines.isNotEmpty()) {
                        Text(
                            legacyLines.joinToString("  ·  ") + "  ·  manually entered",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
                if (canViewFinancials) {
                    val cost = chemical.costPerUnit
                    Text(
                        if (cost != null && cost > 0) "${formatChemCurrency(cost)} / ${chemical.unit}" else "No cost set",
                        fontSize = 13.sp,
                        color = if (cost != null && cost > 0) ChemTint else vine.textSecondary,
                        fontWeight = FontWeight.Medium,
                    )
                }
                // Re-verify for records VineTrack can already identify;
                // Match & Verify for the ones it cannot. A legacy product with
                // nothing but a typed name has no identity to re-check, so the
                // domain sends it to Match & Verify rather than quietly running a
                // fresh brand-name search under a re-verification label.
                if (canManage && canReverify) {
                    TextButton(
                        onClick = onReverify,
                        contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp),
                    ) {
                        Text(
                            "Re-verify Chemical",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = ChemTint,
                        )
                    }
                } else if (canManage && status != ChemicalVerificationStatus.VERIFIED &&
                    status != ChemicalVerificationStatus.PARTIALLY_VERIFIED
                ) {
                    TextButton(
                        onClick = onMatchVerify,
                        contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp),
                    ) {
                        Text(
                            "Match & Verify",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = ChemTint,
                        )
                    }
                }
            }
            if (canManage) {
                IconButton(onClick = onDelete) {
                    Icon(Icons.Filled.Delete, contentDescription = "Archive chemical", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

/** Verification filter pill with a live count derived from resolved statuses. */
@Composable
private fun VerificationFilterPill(
    label: String,
    count: Int,
    selected: Boolean,
    tint: Color,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selected) tint.copy(alpha = 0.18f) else vine.cardBackground)
            .clickable { onClick() }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            label,
            fontSize = 12.sp,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
            color = if (selected) tint else vine.textSecondary,
        )
        Text(
            count.toString(),
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            color = if (selected) tint else vine.textSecondary,
        )
    }
}

/** Small capsule used for chemical group / problem / MOA metadata. */
@Composable
private fun ChemChip(text: String) {
    val vine = LocalVineColors.current
    Text(
        text,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        color = ChemTint,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(ChemTint.copy(alpha = 0.12f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

/** Form types and the unit set each implies, mirroring iOS `ChemicalFormType`. */
private val liquidUnits: List<String> = listOf("Litres", "mL")
private val solidUnits: List<String> = listOf("Kg", "g")
private fun unitsForForm(form: String): List<String> = if (form == "Solid") solidUnits else liquidUnits
private fun formForUnit(unit: String): String = if (unit == "Kg" || unit == "g") "Solid" else "Liquid"

/** iOS `formatRate`: blank for 0, no decimals for integers, else up to 3 decimals (trailing zeros trimmed). */
private fun formatRate(value: Double): String = when {
    value == 0.0 -> ""
    value % 1.0 == 0.0 -> "%.0f".format(value)
    else -> "%.3f".format(value).trimEnd('0').trimEnd('.')
}

/**
 * Full add/edit chemical form (all fields + register search). Shared with the
 * spray calculator's "Add New Chemical to List" button so both entry points
 * use the identical Settings form — matching iOS behaviour.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChemicalFormSheet(
    vm: AppViewModel,
    existing: SavedChemical?,
    canViewFinancials: Boolean,
    onDismiss: () -> Unit,
    /**
     * Needed only to offer Re-verify Chemical, which requires the vineyard's
     * country. Optional so callers that add a brand-new product — which can never
     * be re-verified — do not have to supply it.
     */
    state: AppUiState? = null,
    /**
     * Reconciled intelligence this form MUST write on Save.
     *
     * Set only when the form was opened on a re-verification draft. The
     * editor's own change test compares the draft against itself and finds
     * nothing, so without this the accepted update would be reviewed and then
     * silently not saved.
     */
    pendingIntelligence: ChemicalIntelligence? = null,
    /**
     * Bases whose stored default cites a registered rate the refreshed label
     * no longer carries. Save is blocked until the operator confirms a rate
     * again or clears the slot — never silently repointed.
     */
    staleDefaultBases: List<ChemicalDefaultRateBasis> = emptyList(),
    /** Raised when a re-verification started from inside this form is accepted. */
    onReverifyDraft: (ChemicalReverifyFlow.Draft) -> Unit = {},
    /**
     * Raised when this form CREATED a new saved chemical, immediately before it
     * closes.
     *
     * [onDismiss] fires for a successful save and for a cancel alike, so a
     * caller waiting on a new product cannot tell the two apart without this.
     * Not raised for an update: no new product exists to hand anybody.
     */
    onCreated: () -> Unit = {},
) {
    val vine = LocalVineColors.current
    val uriHandler = LocalUriHandler.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val isEdit = existing != null
    // The record a re-verification is running against. Usually [existing], but
    // the register search can surface a DIFFERENT stored product with the same
    // name, and "check for updates" must then re-verify that one rather than
    // the record this form happens to be editing.
    var reverifyTarget by remember { mutableStateOf<SavedChemical?>(null) }

    val existingPerHaId = existing?.rates?.firstOrNull { it.basis == CHEMICAL_RATE_PER_HECTARE }?.id
    val existingPer100LId = existing?.rates?.firstOrNull { it.basis == CHEMICAL_RATE_PER_100L }?.id

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var formType by remember { mutableStateOf(formForUnit(existing?.unit ?: "Litres")) }
    var unit by remember { mutableStateOf(existing?.unit?.takeIf { it in chemicalUnits } ?: "Litres") }
    var activeIngredient by remember { mutableStateOf(existing?.activeIngredient ?: "") }
    var chemicalGroup by remember { mutableStateOf(existing?.chemicalGroup ?: "") }
    var use by remember { mutableStateOf(existing?.use ?: "") }
    var problem by remember { mutableStateOf(existing?.problem ?: "") }
    var manufacturer by remember { mutableStateOf(existing?.manufacturer ?: "") }
    var modeOfAction by remember { mutableStateOf(existing?.modeOfAction ?: "") }
    // Both legacy scalars fall back to the structured registration that research
    // established. Records saved before those URLs were projected into the
    // legacy columns genuinely HOLD the documents; without the fallback the
    // field would read empty and be written back empty.
    var labelUrl by remember {
        mutableStateOf(
            existing?.labelUrl?.takeIf { it.isNotBlank() }
                ?: existing?.storedIntelligence?.registration?.labelReference.orEmpty(),
        )
    }
    var productUrl by remember {
        mutableStateOf(
            existing?.productUrl?.takeIf { it.isNotBlank() }
                ?: existing?.storedIntelligence?.registration?.manufacturerProductUrl.orEmpty(),
        )
    }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var ratePerHa by remember { mutableStateOf(existing?.ratePerHaDisplay?.let { formatRate(it) } ?: "") }
    var ratePer100L by remember { mutableStateOf(existing?.ratePer100LDisplay?.let { formatRate(it) } ?: "") }
    // The CONFIRMED operational default (sql/214) as this form will leave it.
    //
    // Held separately from the legacy rate boxes above because the two answer
    // different questions: those are compatibility numbers, this is the
    // decision a human made about what the vineyard pours.
    var defaultRatesDraft by remember(existing?.id) {
        mutableStateOf(existing?.defaultRates)
    }
    // Whether the operator TOUCHED the default in this session.
    //
    // Null `defaultRates` on the write means "leave the stored value alone",
    // so an untouched edit must send null however the draft happens to read.
    // Without this flag, opening a chemical to fix its price and pressing Save
    // would rewrite — or silently erase — a rate confirmation made on another
    // device.
    var defaultRatesEdited by remember(existing?.id) { mutableStateOf(false) }
    var trackPurchase by remember { mutableStateOf(existing?.purchase != null) }
    var containerSize by remember { mutableStateOf(existing?.purchase?.containerSizeML?.takeIf { it > 0 }?.let { formatRate(it) } ?: "") }
    var containerUnit by remember { mutableStateOf(existing?.purchase?.containerUnit?.takeIf { it in chemicalUnits } ?: (existing?.unit ?: "Litres")) }
    var cost by remember { mutableStateOf(existing?.purchase?.costDollars?.takeIf { it > 0 }?.let { formatRate(it) } ?: "") }
    // Unified product-library fields (sql/111). Fertiliser inputs only appear
    // when a fertiliser/nutrient category is selected.
    var category by remember { mutableStateOf(existing?.productCategory ?: "") }
    var packSizeText by remember { mutableStateOf(existing?.packSize?.let { formatRate(it) } ?: "") }
    var packPriceText by remember { mutableStateOf(existing?.pricePerPack?.let { formatRate(it) } ?: "") }
    var densityText by remember { mutableStateOf(existing?.density?.let { formatRate(it) } ?: "") }
    var nText by remember { mutableStateOf(existing?.nitrogenPercent?.let { formatRate(it) } ?: "") }
    var pText by remember { mutableStateOf(existing?.phosphorusPercent?.let { formatRate(it) } ?: "") }
    var kText by remember { mutableStateOf(existing?.potassiumPercent?.let { formatRate(it) } ?: "") }
    var oxideBasis by remember { mutableStateOf(existing?.analysisBasis == "oxide") }
    var organicCertified by remember { mutableStateOf(existing?.organicCertified ?: false) }
    var inventoryText by remember { mutableStateOf(existing?.inventoryQuantity?.let { formatRate(it) } ?: "") }
    var applicationNotes by remember { mutableStateOf(existing?.applicationNotes ?: "") }
    var categoryMenu by remember { mutableStateOf(false) }
    var unitMenu by remember { mutableStateOf(false) }
    var containerUnitMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    // The ONE research entry point this form offers: the same register search
    // and matching flow Add Chemical uses. There is no second lookup here.
    var showRegisterSearch by remember { mutableStateOf(false) }
    var showChemistryEditor by remember { mutableStateOf(false) }
    // The country a manual entry defaults to, from the vineyard profile. Applied
    // only when the record does not already name one, so an imported product's
    // own country is never overwritten on open.
    val manualCountry = ChemicalRegistration.normaliseCountry(
        ChemicalInfoService.resolveCountry(
            state?.vineyards?.firstOrNull { it.id == state.selectedVineyardId }?.country,
        ),
    )
    // The structured chemistry the operator is authoring. This replaces the three
    // free-text chemistry boxes this form used to carry. Held here rather than
    // inside the editor sheet so the edits survive that sheet closing and are
    // written by this form's own Save, keeping one Save button for the product.
    var chemistryDraft by remember(existing?.id) {
        mutableStateOf(ChemicalManualEntry.draft(existing, manualCountry))
    }

    /**
     * The save-contract violations the record ALREADY had when this form opened.
     *
     * # Why a baseline exists rather than a flat rule
     *
     * The mandatory contract must stop a NEW chemical entering the store
     * unusable. Applied flatly it would also strand every legacy record: a
     * pre-Chemical-Intelligence product has no structured grapevine use and no
     * structured rate, so an operator opening one to fix a typo or update a
     * price would find Save permanently disabled — and would lose the edit. A
     * record that cannot be saved cannot be repaired, which makes the data
     * worse rather than better.
     *
     * So the rule is "never make it worse": a violation blocks Save only if the
     * record did not already have it. A legacy chemical stays editable and can
     * be brought up to contract a field at a time; a compliant chemical can
     * never be edited INTO non-compliance; and a brand-new chemical has an
     * empty baseline, so the full contract applies. Identical to the iOS
     * `ChemicalReviewSession.baselineViolationCodes`, measured the same way at
     * the same moment.
     */
    val baselineViolationCodes: Set<ChemicalSaveViolationCode> = remember(existing?.id) {
        ChemicalSaveContract.baselineViolationCodes(existing, manualCountry)
    }

    // Keep unit/container-unit valid when the form type flips.
    fun applyFormType(newForm: String) {
        formType = newForm
        val units = unitsForForm(newForm)
        if (unit !in units) unit = units.first()
        if (containerUnit !in units) containerUnit = units.first()
    }

    /**
     * What this edit does to the record's trust, re-derived from the evidence
     * model as the operator types.
     *
     * Null when nothing resistance-critical has moved — which is the common case
     * and the reason editing a price or a note never disturbs a verified product.
     * Only records that actually HOLD structured intelligence are reconciled: a
     * pure legacy record already resolves to Needs Match on read, so there is no
     * false trust there to protect.
     */
    val editOutcome: ChemicalEditOutcome? = remember(existing?.id, chemistryDraft) {
        // A record whose chemistry section was never opened has nothing structured
        // to write, and must be saved without touching the intelligence columns —
        // otherwise editing a price on a legacy chemical would materialise its
        // free-text seed as its first structured write.
        val proposed = ChemicalManualEntry.proposedIntelligence(
            chemistryDraft,
            existing?.storedIntelligence,
        )
        if (proposed.isEmpty) {
            null
        } else {
            val resolved = ChemicalManualEntry.outcome(chemistryDraft, existing?.storedIntelligence)
            // An unchanged structured record must not be rewritten by the act of
            // saving a note: identical intelligence means nothing to store.
            if (existing?.storedIntelligence == resolved.intelligence) null else resolved
        }
    }

    fun save() {
        if (saving) return
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return
        // The CONTRACT decides, not the button. The button is disabled for the
        // same reason, but a save path that trusts its own button is a save
        // path that writes whatever a future caller forgets to gate — which is
        // exactly how this form came to accept a name and nothing else.
        //
        // The stale-default bases are passed here TOO, computed exactly as the
        // button computes them. They were previously omitted from this call,
        // so the button disabled itself over a stale rate while the write
        // function it guarded evaluated a contract in which that rate was
        // fine. Any caller reaching save() another way — an IME action, a
        // future keyboard shortcut, a recomposition race — would have written
        // a default citing a registered rate the label no longer carries.
        val unresolvedStaleBases = staleDefaultBases.filter {
            defaultRatesDraft?.slot(it) != null
        }
        val gate = ChemicalSaveContract.evaluate(
            productName = trimmedName,
            productCategory = category,
            // Vineyard-scoped, like the rendered evaluation: the contract must
            // judge the grapevine record the operator was actually shown.
            intelligence = ChemicalVineyardScope.scoped(
                ChemicalManualEntry.proposedIntelligence(
                    chemistryDraft,
                    existing?.storedIntelligence,
                ),
            ),
            staleDefaultBases = unresolvedStaleBases,
        )
        if (gate.violations.any { it.code !in baselineViolationCodes }) return
        saving = true
        val perHaDisplay = ratePerHa.toDoubleSafe() ?: 0.0
        val per100LDisplay = ratePer100L.toDoubleSafe() ?: 0.0
        val rates = buildList {
            if (perHaDisplay > 0) add(
                ChemicalRate(
                    id = existingPerHaId ?: UUID.randomUUID().toString(),
                    label = "Per Ha",
                    value = chemicalUnitToBase(unit, perHaDisplay),
                    basis = CHEMICAL_RATE_PER_HECTARE,
                ),
            )
            if (per100LDisplay > 0) add(
                ChemicalRate(
                    id = existingPer100LId ?: UUID.randomUUID().toString(),
                    label = "Per 100L",
                    value = chemicalUnitToBase(unit, per100LDisplay),
                    basis = CHEMICAL_RATE_PER_100L,
                ),
            )
        }
        // Owners/managers author purchase data; others keep the existing snapshot
        // so editing other details never clears pricing (mirrors iOS save()).
        val purchase: ChemicalPurchase? = if (!canViewFinancials) {
            existing?.purchase
        } else if (trackPurchase) {
            val cs = containerSize.toDoubleSafe() ?: 0.0
            val costValue = cost.toDoubleSafe() ?: 0.0
            if (cs > 0 || costValue > 0) {
                ChemicalPurchase(
                    brand = manufacturer.trim(),
                    activeIngredient = activeIngredient.trim(),
                    chemicalGroup = chemicalGroup.trim(),
                    labelUrl = labelUrl.trim(),
                    costDollars = costValue,
                    containerSizeML = cs,
                    containerUnit = containerUnit,
                )
            } else null
        } else null
        // Legacy scalars are now OUTPUTS of the structured record. They are
        // rewritten only when there is structured chemistry to derive them from, so
        // a record that has never been structured keeps its original text and is
        // not blanked by the act of saving it.
        val structured = editOutcome?.intelligence
            ?: pendingIntelligence
            ?: existing?.storedIntelligence?.takeIf {
                !ChemicalManualEntry.proposedIntelligence(
                    chemistryDraft,
                    existing.storedIntelligence,
                ).isEmpty
            }
        val legacyActive = structured?.legacyActiveIngredient?.ifBlank { null }
            ?: activeIngredient.trim().ifBlank { null }
        val legacyGroup = structured?.legacyChemicalGroup?.ifBlank { null }
            ?: chemicalGroup.trim().ifBlank { null }
        val input = SavedChemicalRepository.ChemicalInput(
            name = trimmedName,
            unit = unit,
            ratePerHa = perHaDisplay,
            rates = rates,
            activeIngredient = legacyActive,
            chemicalGroup = legacyGroup,
            use = use.trim().ifBlank { null },
            problem = problem.trim().ifBlank { null },
            manufacturer = manufacturer.trim().ifBlank { null },
            notes = notes.trim().ifBlank { null },
            // Mode of action is no longer an editable chemistry input — the group is
            // structured per active now — so whatever the record already held is
            // carried through untouched rather than dropped.
            modeOfAction = modeOfAction.trim().ifBlank { null },
            labelUrl = labelUrl.trim().ifBlank { null },
            productUrl = productUrl.trim().ifBlank { null },
            purchase = purchase,
            productCategory = category,
            productForm = if (formType == "Solid") "solid" else "liquid",
            packSize = packSizeText.toDoubleSafe(),
            packUnit = if (formType == "Solid") "kg" else "L",
            // Owners/managers author pack pricing; others keep the existing value.
            pricePerPack = if (canViewFinancials) packPriceText.toDoubleSafe() else existing?.pricePerPack,
            density = densityText.toDoubleSafe(),
            nitrogenPercent = nText.toDoubleSafe(),
            phosphorusPercent = pText.toDoubleSafe(),
            potassiumPercent = kText.toDoubleSafe(),
            analysisBasis = if (oxideBasis) "oxide" else "elemental",
            organicCertified = organicCertified,
            inventoryQuantity = inventoryText.toDoubleSafe(),
            inventoryUnit = if (inventoryText.toDoubleSafe() != null) "packs" else (existing?.inventoryUnit ?: ""),
            applicationNotes = applicationNotes.trim(),
            // Re-resolved intelligence when resistance-critical text changed, so a
            // hand-edited group cannot leave a stale `verified` status behind.
            // Null on an unrelated edit, and `explicitNulls = false` then OMITS
            // the structured columns rather than blanking them.
            //
            // Vineyard-scoped on the way out, exactly like the research path:
            // whichever route a use arrived by, the stored operational set is
            // grapevine directions plus product-level rates and nothing else.
            // The re-verification draft's reconciled intelligence, when this
            // form was opened on one. Without the fallback the editor's own
            // change test compares the draft against itself, finds nothing
            // moved, and omits the very columns the operator just accepted.
            intelligence = (editOutcome?.intelligence ?: pendingIntelligence)
                ?.let { ChemicalVineyardScope.scoped(it) },
            // Omitted from the write unless the operator actually changed it.
            // An ordinary edit — a price, a pack size, a note — must never
            // rewrite or erase a rate confirmation, including one made on
            // another device.
            defaultRates = if (defaultRatesEdited) defaultRatesDraft else null,
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (isEdit) {
            vm.updateSavedChemical(existing!!.id, input, cb)
        } else {
            vm.createSavedChemical(input) { ok ->
                saving = false
                if (ok) {
                    onCreated()
                    onDismiss()
                }
            }
        }
    }

    if (showChemistryEditor) {
        ChemicalManualEditorSheet(
            draft = chemistryDraft,
            existing = existing?.storedIntelligence,
            onDraftChange = { chemistryDraft = it },
            onDismiss = { showChemistryEditor = false },
        )
    }

    reverifyTarget?.let { target ->
        if (state != null) {
            // Closing this form after a re-verification is not cosmetic. These
            // fields were captured from the record when the sheet opened, so a
            // Save afterwards would write the pre-check values straight back
            // over the update the operator just accepted.
            ChemicalReverifySheet(
                state = state,
                chemical = target,
                onDismiss = { reverifyTarget = null; onDismiss() },
                // This form holds field values captured when it opened, so it
                // closes and hands the draft to the host rather than trying to
                // merge an update into stale on-screen state.
                onUseUpdatedInformation = { draft ->
                    reverifyTarget = null
                    onReverifyDraft(draft)
                    onDismiss()
                },
            )
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (isEdit) "Edit chemical" else "New chemical",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            // Re-run the product lookup from inside the editor.
            //
            // This is NOT a second pipeline. It opens the SAME register search
            // that Add Chemical opens, resolves through the same resolver and
            // maps through the same matching code. What stood here before was
            // "Search with AI": a second, differently named research action
            // that could only ever fill descriptive free text, and that iOS
            // has never had. Two research entry points behaving differently is
            // how an operator ends up believing a product was researched when
            // only its blurb was.
            if (state != null) {
                OutlinedButton(
                    onClick = { showRegisterSearch = true },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(
                        Icons.Filled.Search,
                        contentDescription = null,
                        tint = ChemTint,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(8.dp))
                    // Same two titles iOS uses, chosen the same way.
                    Text(
                        if (name.trim().isEmpty()) "Search for this product"
                        else "Search the register again",
                    )
                }
                Text(
                    "Looks this product up on the official register and reviews what " +
                        "it finds before anything is written. Confirming a match there " +
                        "saves the product and closes this form, so finish any edits " +
                        "here first.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }

            SectionLabel("Product")
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Chemical / product name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            // Re-verify Chemical, or an honest explanation of why it is not
            // available. Both the eligibility and the reason come from
            // ChemicalReverification, so this action can never appear on a record
            // the flow would refuse to run on.
            if (existing != null && state != null) {
                val reverifyCountry = ChemicalRegistration.normaliseCountry(
                    ChemicalInfoService.resolveCountry(
                        state.vineyards
                            .firstOrNull { it.id == state.selectedVineyardId }?.country,
                    ),
                )
                SectionLabel("Chemical intelligence")
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
                    ChemicalVerificationBadge(existing.verificationStatus)
                }
                // Registration identity vs the CURRENT vineyard's jurisdiction.
                // The record keeps its own country — it is never re-keyed — but
                // a foreign label must never read as valid vineyard guidance.
                val formSuitability = ChemicalJurisdiction.suitability(existing, reverifyCountry)
                if (formSuitability is ChemicalJurisdictionSuitability.Mismatch) {
                    ChemicalJurisdictionMismatchBanner(
                        formSuitability.registrationCountry,
                        formSuitability.vineyardCountry,
                    )
                }
                if (ChemicalReverification.isOffered(existing, reverifyCountry)) {
                    OutlinedButton(
                        onClick = { reverifyTarget = existing },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(
                            Icons.Filled.Sync,
                            contentDescription = null,
                            tint = ChemTint,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.size(8.dp))
                        Text("Re-verify Chemical")
                    }
                    Text(
                        "Re-checks this product against the register using the registration " +
                            "details VineTrack already holds. Nothing is changed until you " +
                            "review and accept it.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                } else {
                    ChemicalReverification.unavailableReason(existing, reverifyCountry)?.let {
                        Text(it, fontSize = 11.sp, color = vine.textSecondary)
                    }
                }
            }
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                listOf("Liquid", "Solid").forEachIndexed { index, f ->
                    SegmentedButton(
                        selected = formType == f,
                        onClick = { applyFormType(f) },
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = 2),
                    ) { Text(f) }
                }
            }
            UnitDropdown(
                label = "Unit",
                value = unit,
                options = unitsForForm(formType),
                expanded = unitMenu,
                onExpandedChange = { unitMenu = it },
                onSelect = { unit = it; unitMenu = false },
                modifier = Modifier.fillMaxWidth(),
            )
            CategoryDropdown(
                value = category,
                expanded = categoryMenu,
                onExpandedChange = { categoryMenu = it },
                onSelect = { category = it; categoryMenu = false },
            )
            Text(
                "Fertiliser and nutrient categories unlock pack, N-P-K and inventory fields used by the Fertiliser Calculator.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            if (ProductCategories.isFertiliser(category)) {
                SectionLabel("Pack & inventory")
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text("Organic certified", fontSize = 15.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    Switch(checked = organicCertified, onCheckedChange = { organicCertified = it })
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = packSizeText,
                        onValueChange = { packSizeText = it.numericFilter() },
                        label = { Text(if (formType == "Solid") "Pack size (kg)" else "Pack size (L)") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                    if (canViewFinancials) {
                        OutlinedTextField(
                            value = packPriceText,
                            onValueChange = { packPriceText = it.numericFilter() },
                            label = { Text("Price per pack ($)") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (formType != "Solid") {
                        OutlinedTextField(
                            value = densityText,
                            onValueChange = { densityText = it.numericFilter() },
                            label = { Text("Density (kg/L)") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.weight(1f),
                        )
                    }
                    OutlinedTextField(
                        value = inventoryText,
                        onValueChange = { inventoryText = it.numericFilter() },
                        label = { Text("Stock on hand (packs)") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                }

                SectionLabel("Nutrient analysis (%)")
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = nText,
                        onValueChange = { nText = it.numericFilter() },
                        label = { Text("N") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = pText,
                        onValueChange = { pText = it.numericFilter() },
                        label = { Text("P") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = kText,
                        onValueChange = { kText = it.numericFilter() },
                        label = { Text("K") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Oxide label values (P\u2082O\u2085 / K\u2082O)", fontSize = 14.sp, color = vine.textPrimary)
                        Text(
                            "Record which basis the label uses \u2014 mixing them up causes major rate errors.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                    Switch(checked = oxideBasis, onCheckedChange = { oxideBasis = it })
                }

                OutlinedTextField(
                    value = applicationNotes,
                    onValueChange = { applicationNotes = it },
                    label = { Text("Application notes (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // ---- Active ingredients ----
            // This is what replaced the `Active ingredient` and `Chemical group`
            // boxes. It shows each active with its own group, the derived
            // product-level summary, and how many label rates and uses are on
            // record, then hands off to the structured editor for the real work.
            val structuredActives = chemistryDraft.actives.filter { it.name.isNotBlank() }
            val groupSummary = ChemicalManualEntry.groupSummary(chemistryDraft)
            val labelRateCount = chemistryDraft.productRates.size +
                chemistryDraft.uses.sumOf { it.rates.size }
            SectionLabel("Active ingredients")
            if (structuredActives.isEmpty()) {
                Text(
                    "No active ingredients recorded",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
            } else {
                structuredActives.forEach { active ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                active.name,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                color = vine.textPrimary,
                            )
                            if (active.concentrationText.isNotBlank()) {
                                Text(
                                    "${active.concentrationText} ${active.concentrationUnit?.label.orEmpty()}",
                                    fontSize = 11.sp,
                                    color = vine.textSecondary,
                                )
                            }
                        }
                        val code = ChemicalActivityGroup.normaliseCode(active.groupCode)
                        val scheme = active.scheme
                        if (scheme != null &&
                            scheme != ChemicalActivityGroupScheme.NOT_APPLICABLE &&
                            code.isNotEmpty()
                        ) {
                            ChemChip("${scheme.label} $code")
                        } else {
                            Text("No group", fontSize = 11.sp, color = vine.textSecondary)
                        }
                    }
                }
            }
            if (groupSummary.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Product groups",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        groupSummary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                }
            }
            if (labelRateCount > 0 || chemistryDraft.uses.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Label rates & uses",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        "$labelRateCount rate${if (labelRateCount == 1) "" else "s"} · " +
                            "${chemistryDraft.uses.size} use" +
                            if (chemistryDraft.uses.size == 1) "" else "s",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
            }
            OutlinedButton(
                onClick = { showChemistryEditor = true },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(
                    Icons.Filled.Science,
                    contentDescription = null,
                    tint = ChemTint,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.size(8.dp))
                Text(
                    if (structuredActives.isEmpty()) "Enter chemistry & identity"
                    else "Edit chemistry & identity",
                )
            }
            // A legacy record's free-text chemistry, shown read-only so the
            // operator can see what the old columns hold while they restate it as
            // structure. Nothing calculates from these strings.
            if (structuredActives.isEmpty() &&
                (activeIngredient.isNotBlank() || chemicalGroup.isNotBlank())
            ) {
                Text("Recorded as text", fontSize = 11.sp, color = vine.textSecondary)
                Text(
                    listOf(activeIngredient, chemicalGroup)
                        .filter { it.isNotBlank() }
                        .joinToString(" · "),
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
            Text(
                "Each active ingredient carries its own resistance group, so a two-active " +
                    "product belongs to both groups independently. Anything you enter " +
                    "yourself stays unverified until Match & Verify or Re-verify confirms it.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            // ---- Registered uses & safety ----
            //
            // The crop, the target, the label's rate, the withholding period,
            // the re-entry rule and the label's restrictions — the facts an
            // operator opens a chemical to check before they spray it.
            //
            // This section was MISSING. Android researched all of it, saved all
            // of it and round-tripped all of it correctly, then showed the
            // operator "6 rates · 4 uses" and nothing else. The withholding
            // period was two taps deep inside "Edit chemistry & identity", a
            // button that reads like an authoring tool rather than the place
            // your harvest interval lives — and the re-entry rule and the
            // restriction text had no read surface on this screen at all. iOS
            // has shown these inline the whole time, so the same saved record
            // answered a compliance question on one phone and not the other.
            //
            // Rendered from the live draft rather than the stored row so it
            // stays truthful while the chemistry sheet is being edited, and
            // through the SAME component the match and re-verify flows use —
            // which is what keeps "Not stated" phrased identically everywhere
            // instead of becoming a second opinion about a missing value.
            //
            // VINEYARD-SCOPED before anything reads it. The Chemical Store is a
            // vineyard record: peaches, citrus, turf and cereals on the same
            // approved label are not directions this operator may act on, and
            // an editor that renders them invites exactly the mistake of
            // reading a macadamia withholding period as a grape one. Scoping
            // here rather than at each render point means the save contract
            // below is evaluated against the same grapevine set the operator
            // was shown — a contract judged on rows the screen never displayed
            // is a contract about a different record.
            //
            // `scoped` keeps product-level rate carriers, which claim no crop
            // at all, so a label quoting one rate for the whole drum is not
            // lost. It is idempotent, so re-scoping an already-scoped record
            // changes nothing.
            val displayIntelligence = remember(chemistryDraft, existing?.id) {
                ChemicalVineyardScope.scoped(
                    ChemicalManualEntry.proposedIntelligence(
                        chemistryDraft,
                        existing?.storedIntelligence,
                    ),
                )
            }

            // The mandatory save contract, re-measured as the operator types.
            //
            // Same rules, same messages and same order as the iOS editor and
            // the edge function's `save_contract.ts`, because a record one
            // client refuses must not be a record another client writes.
            // A stale slot is one whose cited registered rate has vanished from
            // the refreshed label. Clearing the default resolves it; nothing
            // here ever picks a replacement.
            val unresolvedStaleBases = staleDefaultBases.filter {
                defaultRatesDraft?.slot(it) != null
            }
            val saveEvaluation = remember(
                name,
                category,
                displayIntelligence,
                unresolvedStaleBases,
            ) {
                ChemicalSaveContract.evaluate(
                    productName = name,
                    productCategory = category,
                    intelligence = displayIntelligence,
                    staleDefaultBases = unresolvedStaleBases,
                )
            }
            // What THIS edit would add, versus what the record arrived with.
            val blockingViolations =
                ChemicalSaveContract.blockingViolations(saveEvaluation, baselineViolationCodes)
            val carriedOverViolations =
                ChemicalSaveContract.carriedOverViolations(saveEvaluation, baselineViolationCodes)

            // Already scoped above; asked again so this render site states its
            // own rule rather than depending on an upstream one staying true.
            val displayUses = ChemicalVineyardScope.operationalUses(
                displayIntelligence.registeredUses,
            )
            if (displayUses.isNotEmpty()) {
                SectionLabel("Grapevine uses & safety")
                // The registered rate, stated ONCE at the top — then the
                // compact target list. The full per-target crop/rate/WHP/
                // re-entry/restrictions cards repeated the same printed
                // direction dozens of times; the COMPLETE registered_uses
                // data is stored unchanged.
                ChemicalDefaultRateDisplay.registeredRateSummaries(displayUses)
                    .forEach { line ->
                        Text(
                            line,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                    }
                ChemicalCompactRegisteredUsesView(displayUses)
            }

            SectionLabel("Details")
            // States the trust consequence of a resistance-critical correction
            // without blocking it. Absent unless verification actually falls.
            editOutcome?.warning?.let { warning ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(VineColors.Warning.copy(alpha = 0.12f))
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        "Verification will be updated",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    Text(warning, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
            OutlinedTextField(
                value = use,
                onValueChange = { use = it },
                label = { Text("Use (e.g. Fungicide)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = problem,
                onValueChange = { problem = it },
                label = { Text("Target problem (e.g. Powdery Mildew)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = manufacturer,
                onValueChange = { manufacturer = it },
                label = { Text("Manufacturer") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            UrlField(
                label = "Official label URL",
                value = labelUrl,
                onValueChange = { labelUrl = it },
                onOpen = { resolveUrl(labelUrl)?.let { runCatching { uriHandler.openUri(it) } } },
            )
            UrlField(
                label = "Product page URL",
                value = productUrl,
                onValueChange = { productUrl = it },
                onOpen = { resolveUrl(productUrl)?.let { runCatching { uriHandler.openUri(it) } } },
            )
            // The MANUFACTURER-hosted label, when research established one that
            // is a genuinely different document from the two fields above.
            //
            // All three link concepts have always persisted on Android inside
            // the structured registration; only this one had no read surface,
            // so a label the resolver found and validated arrived on device and
            // was never shown. It is read-only on purpose: which document is
            // the manufacturer's label is something the register lookup
            // establishes, and a typed URL is not evidence of that.
            val manufacturerLabelUrl = displayIntelligence.registration
                ?.manufacturerLabelUrl
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                // Never render the same document twice under two names.
                ?.takeIf { it != labelUrl.trim() && it != productUrl.trim() }
            manufacturerLabelUrl?.let { url ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Manufacturer label", fontSize = 12.sp, color = vine.textSecondary)
                        Text(url, fontSize = 12.sp, color = vine.textPrimary, maxLines = 2)
                    }
                    resolveUrl(url)?.let { opened ->
                        IconButton(onClick = { runCatching { uriHandler.openUri(opened) } }) {
                            Icon(
                                Icons.AutoMirrored.Filled.OpenInNew,
                                contentDescription = "Open manufacturer label",
                                tint = ChemTint,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
            Text(
                "Use the label URL only for the official product label. Product pages are for manufacturer info and are never shown as the label.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            SectionLabel("Rates")

            // A STRUCTURED product's operational rate is its confirmed
            // default, and only that. The legacy boxes below stay editable for
            // compatibility but must never be presented as the authority —
            // `rate_per_ha` has no link back to a registered direction, so a
            // number typed there proves nothing about what the label permits.
            val isStructuredRecord = existing != null &&
                ChemicalDefaultRateDisplay.isStructured(existing)
            if (isStructuredRecord) {
                val confirmedSlots = ChemicalDefaultRateDisplay.slotDisplays(defaultRatesDraft)
                if (confirmedSlots.isNotEmpty()) {
                    Text(
                        "Confirmed rate for this vineyard",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = vine.textSecondary,
                    )
                    Text(
                        confirmedSlots.joinToString("  ·  "),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    TextButton(
                        onClick = {
                            // An explicit clear writes an EMPTY v1 contract, not
                            // a null. Null would be omitted from the request
                            // entirely and the old default would survive the
                            // very act of clearing it.
                            defaultRatesDraft = clearedDefaultRates()
                            defaultRatesEdited = true
                        },
                        contentPadding = PaddingValues(0.dp),
                    ) { Text("Clear confirmed rate", fontSize = 13.sp) }
                    Text(
                        "Clearing asks for the rate to be confirmed again before this " +
                            "product is used in a spray.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                } else {
                    // A usable registered grapevine rate or range is a complete
                    // record of what the label permits: state it plainly. The
                    // confirmation prompt survives only when the registration
                    // carries no usable rate at all.
                    val registeredLine = existing?.let {
                        ChemicalDefaultRateDisplay.registeredRateLine(it)
                    }
                    if (registeredLine != null) {
                        Text(
                            registeredLine,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        Text(
                            "The registered label rate is saved with this chemical. Choose " +
                                "the exact rate being applied when planning each spray.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    } else {
                        Text(
                            ChemicalDefaultRateDisplay.CONFIRMATION_REQUIRED,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.Warning,
                        )
                        Text(
                            "Use “Search the register again” above to review this product's " +
                                "registered rates and confirm the one this vineyard uses.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = ratePerHa,
                    onValueChange = { ratePerHa = it.numericFilter() },
                    label = { Text("Rate/ha") },
                    suffix = { Text("$unit/ha", fontSize = 12.sp, color = vine.textSecondary) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = ratePer100L,
                    onValueChange = { ratePer100L = it.numericFilter() },
                    label = { Text("Rate/100L") },
                    suffix = { Text("$unit/100L", fontSize = 12.sp, color = vine.textSecondary) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }
            Text(
                if (isStructuredRecord) {
                    "Kept for older app versions only. Spray calculations use the " +
                        "confirmed rate above."
                } else {
                    "Enter either or both. The spray calculator lets the operator pick " +
                        "which basis to use per job."
                },
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            if (canViewFinancials) {
                SectionLabel("Purchase tracking")
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text("Track purchase info", fontSize = 15.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    Switch(checked = trackPurchase, onCheckedChange = { trackPurchase = it })
                }
                if (trackPurchase) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(
                            value = containerSize,
                            onValueChange = { containerSize = it.numericFilter() },
                            label = { Text("Container size") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.weight(1f),
                        )
                        UnitDropdown(
                            label = "Unit",
                            value = containerUnit,
                            options = unitsForForm(formType),
                            expanded = containerUnitMenu,
                            onExpandedChange = { containerUnitMenu = it },
                            onSelect = { containerUnit = it; containerUnitMenu = false },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    OutlinedTextField(
                        value = cost,
                        onValueChange = { cost = it.numericFilter() },
                        label = { Text("Cost") },
                        placeholder = { Text("0.00") },
                        prefix = { Text("$") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        "Used to calculate chemical cost in spray reports. Visible to owners and managers only.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            SectionLabel("Notes")
            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                minLines = 3,
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(4.dp))
            // What is still missing, said as the next action rather than as an
            // error. Save stays disabled until these are cleared, so the button
            // and the contract can never disagree about what "ready" means.
            if (blockingViolations.isNotEmpty()) {
                ChemicalSaveIssueNotice(
                    title = "Before this can be saved",
                    violations = blockingViolations,
                    tint = VineColors.Warning,
                )
            }
            // Faults the record ARRIVED with. Guidance, never a block: a legacy
            // product that cannot be saved cannot be repaired.
            if (carriedOverViolations.isNotEmpty()) {
                ChemicalSaveIssueNotice(
                    title = "Still to complete on this product",
                    violations = carriedOverViolations,
                    tint = ChemTint,
                )
            }
            Button(
                onClick = { save() },
                enabled = !saving && name.trim().isNotEmpty() && blockingViolations.isEmpty(),
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (isEdit) "Save changes" else "Add chemical")
            }
        }
    }

    if (showRegisterSearch && state != null) {
        // The one authoritative matching workflow, opened with whatever the
        // operator has typed as its starting query.
        //
        // Closing this form when the flow closes is deliberate, and is the
        // same rule Re-verify already follows here: the flow writes the record
        // itself, while this form still holds the field values captured when
        // it opened. Leaving it open would let a Save afterwards put the
        // pre-match values straight back over the match just accepted.
        ChemicalMatchFlowSheet(
            vm = vm,
            state = state,
            existing = existing,
            prefillQuery = name,
            onDismiss = { showRegisterSearch = false; onDismiss() },
            // "I could not find it" returns to exactly where they were: this
            // form, with everything they had already typed still in it.
            onEnterManually = { showRegisterSearch = false },
            // The register search found a DIFFERENT stored product with this
            // name. "Check for updates" re-verifies that record; this form
            // closes rather than leaving two editors open on two records.
            // Nothing was looked up and nothing was written.
            onCheckForUpdates = { found ->
                showRegisterSearch = false
                reverifyTarget = found
            },
        )
    }
}

/**
 * Unmet save-contract requirements, phrased as the next action.
 *
 * Deliberately renders whatever the contract returned rather than composing its
 * own wording: the operator must read the same sentence on Android that they
 * read on iPhone, because the two are describing the same rule.
 */
@Composable
private fun ChemicalSaveIssueNotice(
    title: String,
    violations: List<ChemicalSaveViolation>,
    tint: Color,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        violations.forEach {
            Text("\u2022 ${it.message}", fontSize = 12.sp, color = vine.textSecondary)
        }
    }
}

/** Small grey section header used inside the chemical form. */
@Composable
private fun SectionLabel(text: String) {
    val vine = LocalVineColors.current
    Text(text.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
}

/** Unified product-category dropdown (keys from [ProductCategories], sql/111). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CategoryDropdown(
    value: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onSelect: (String) -> Unit,
) {
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = onExpandedChange, modifier = Modifier.fillMaxWidth()) {
        OutlinedTextField(
            value = if (value.isBlank()) "Uncategorised" else ProductCategories.label(value),
            onValueChange = {},
            readOnly = true,
            label = { Text("Category") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { onExpandedChange(false) }) {
            DropdownMenuItem(text = { Text("Uncategorised") }, onClick = { onSelect("") })
            ProductCategories.all.forEach { (key, label) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { onSelect(key) })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UnitDropdown(
    label: String,
    value: String,
    options: List<String>,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = onExpandedChange, modifier = modifier) {
        OutlinedTextField(
            value = value,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { onExpandedChange(false) }) {
            options.forEach { o ->
                DropdownMenuItem(text = { Text(o) }, onClick = { onSelect(o) })
            }
        }
    }
}

/** URL text field with a trailing open-in-browser button when the URL is valid. */
@Composable
private fun UrlField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    onOpen: () -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        trailingIcon = {
            if (resolveUrl(value) != null) {
                IconButton(onClick = onOpen) {
                    Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = "Open $label", tint = ChemTint, modifier = Modifier.size(20.dp))
                }
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

/** Normalise a typed URL to an openable https link, or null when invalid. */
private fun resolveUrl(raw: String): String? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return null
    val withScheme = if (trimmed.startsWith("http://", true) || trimmed.startsWith("https://", true)) {
        trimmed
    } else {
        "https://$trimmed"
    }
    val host = withScheme.substringAfter("://").substringBefore("/")
    return if (host.contains(".")) withScheme else null
}

/** Compact currency label (e.g. "$50", "$42.50") for chemical costs. */
private fun formatChemCurrency(value: Double): String {
    val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
    return "$$rounded"
}

private fun trimNum(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString()
    else "%.3f".format(value).trimEnd('0').trimEnd('.')

private fun String.numericFilter(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.toDoubleSafe(): Double? = replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()
