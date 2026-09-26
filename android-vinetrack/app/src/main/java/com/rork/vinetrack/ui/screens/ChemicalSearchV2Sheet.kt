package com.rork.vinetrack.ui.screens

import android.net.Uri
import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.PinPhotoImageUtil
import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.chemical.ChemicalLabelIdentityOCR
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLabelRateNormalizer
import com.rork.vinetrack.data.chemical.ChemicalManualActiveDraft
import com.rork.vinetrack.data.chemical.ChemicalManualDraft
import com.rork.vinetrack.data.chemical.ChemicalManualEntry
import com.rork.vinetrack.data.chemical.ChemicalManualRateDraft
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.SavedChemicalEntrySource
import com.rork.vinetrack.data.chemical.ChemicalSearchV2Duplicate
import com.rork.vinetrack.data.chemical.ChemicalSearchV2OperationalDefaults
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalEditReconciler
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalDetailsCompleteness
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.MasterChemicalV2
import com.rork.vinetrack.data.chemical.MasterChemicalV2Repository
import com.rork.vinetrack.data.chemical.ViticultureRates
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitToBase
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.components.rememberPhotoCaptureCoordinator
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.UUID

internal object ChemicalSearchV2ManualPrefill {
    fun productName(searchText: String): String = searchText.trim()
}

internal data class ChemicalSearchV2ManualDetails(
    val manufacturer: String = "",
    val registrationNumber: String = "",
    val productCategory: String = "",
    val productForm: String = "",
    val activeIngredient: String = "",
    val concentration: String = "",
    val concentrationUnit: ChemicalConcentrationUnit? = null,
    val activityGroupScheme: ChemicalActivityGroupScheme? = null,
    val activityGroupCode: String = "",
    val labelUrl: String = "",
    val productUrl: String = "",
    val notes: String = "",
    val packSize: String = "",
    val packUnit: String = "",
    val pricePerPack: String = "",
    val inventoryQuantity: String = "",
    val inventoryUnit: String = "",
) {
    fun intelligence(productName: String, rate: ChemicalManualRateDraft): ChemicalIntelligence {
        val names = activeIngredient.split(',').map { it.trim() }.filter { it.isNotEmpty() }
        val actives = names.mapIndexed { index, name ->
            ChemicalManualActiveDraft(
                name = name,
                concentrationText = if (index == 0) concentration else "",
                concentrationUnit = if (index == 0) concentrationUnit else null,
                scheme = if (index == 0) activityGroupScheme else null,
                groupCode = if (index == 0) activityGroupCode else "",
            )
        }
        val hasRegistration = manufacturer.isNotBlank() || registrationNumber.isNotBlank() ||
            labelUrl.isNotBlank() || productUrl.isNotBlank()
        val draft = ChemicalManualDraft(
            productName = productName,
            countryCode = if (hasRegistration) "AU" else "",
            productCategory = productCategory,
            registrant = manufacturer,
            registrationScheme = if (hasRegistration) ChemicalRegistrationScheme.APVMA else null,
            registrationNumber = registrationNumber,
            actives = actives,
            productRates = listOf(rate),
        )
        val base = ChemicalManualEntry.outcome(draft, existing = null).intelligence
        val registration = base.registration?.copy(
            labelReference = labelUrl.trim().takeIf { it.isNotEmpty() },
            regulatorLabelUrl = labelUrl.trim().takeIf { it.isNotEmpty() },
            manufacturerProductUrl = productUrl.trim().takeIf { it.isNotEmpty() },
        )
        return base.copy(registration = registration, registeredUses = emptyList())
    }
}

private data class ChemicalReviewV2Draft(
    val source: String,
    val master: MasterChemicalV2?,
    val intelligence: ChemicalIntelligence,
    val formType: String?,
    val productName: String,
    val unit: String,
    val rate: ChemicalManualRateDraft,
    val viticultureRates: ViticultureRates,
    val selectedRateId: String? = null,
    val automaticRates: Map<ChemicalDefaultRateBasis, ChemicalLabelRate> = emptyMap(),
    val masterMatch: ChemicalInfoService.ChemicalMasterMatch? = null,
    val isManual: Boolean = false,
    val manualDetails: ChemicalSearchV2ManualDetails = ChemicalSearchV2ManualDetails(),
    val enteredLabelRate: ChemicalManualRateDraft? = null,
    val activeCorrections: Map<String, ChemicalManualActiveDraft> = emptyMap(),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChemicalSearchV2Sheet(
    vm: AppViewModel,
    state: AppUiState,
    onDismiss: () -> Unit,
    onOpenExisting: (SavedChemical) -> Unit = {},
    onSaved: (SavedChemical) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val repository = remember { MasterChemicalV2Repository() }
    val externalService = remember { ChemicalInfoService() }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<MasterChemicalV2>>(emptyList()) }
    var onlineCandidates by remember { mutableStateOf<List<ChemicalInfoService.WebV2Candidate>>(emptyList()) }
    var savedMatches by remember { mutableStateOf<List<SavedChemical>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var searchJob by remember { mutableStateOf<Job?>(null) }
    var requestId by remember { mutableStateOf<String?>(null) }
    var review by remember { mutableStateOf<ChemicalReviewV2Draft?>(null) }
    var photoBytes by remember { mutableStateOf<ByteArray?>(null) }
    var externalBusy by remember { mutableStateOf(false) }
    var photoBusy by remember { mutableStateOf(false) }
    var proposedIdentity by remember { mutableStateOf<String?>(null) }
    var photoRegistration by remember { mutableStateOf<String?>(null) }
    var photoProductName by remember { mutableStateOf<String?>(null) }
    var externalJob by remember { mutableStateOf<Job?>(null) }
    var externalRequestId by remember { mutableStateOf<String?>(null) }
    var photoJob by remember { mutableStateOf<Job?>(null) }
    DisposableEffect(Unit) {
        onDispose { externalJob?.cancel(); photoJob?.cancel(); searchJob?.cancel() }
    }

    fun draftRate(rate: ChemicalLabelRate): ChemicalManualRateDraft = ChemicalManualRateDraft(
        label = rate.label,
        basis = rate.basis,
        valueText = rate.value?.toString().orEmpty(),
        minText = rate.minValue?.toString().orEmpty(),
        maxText = rate.maxValue?.toString().orEmpty(),
        unit = rate.unit.ifBlank { "L" },
        rawText = rate.rawText.orEmpty(),
    )

    fun openMaster(master: MasterChemicalV2) {
        ChemicalSearchV2Duplicate.existing(master, master.intelligence, master.registeredProductName, state.savedChemicals)?.let {
            savedMatches = listOf(it)
            results = emptyList()
            return
        }
        val automatic = if (master.viticultureRates.all.size > 1) emptyMap() else ChemicalSearchV2OperationalDefaults.unambiguousRates(master.viticultureRates)
        if (photoRegistration != master.registrationNumber) photoBytes = null
        val selected = automatic[ChemicalDefaultRateBasis.PER_HECTARE]
            ?: automatic[ChemicalDefaultRateBasis.PER_100_LITRES]
        val initial = selected?.let(::draftRate) ?: ChemicalManualRateDraft()
        review = ChemicalReviewV2Draft(
            source = "VineTrack Master", master = master, intelligence = master.intelligence,
            formType = master.formType, productName = master.registeredProductName,
            unit = initial.unit.toDisplayUnit(), rate = initial,
            viticultureRates = master.viticultureRates,
            selectedRateId = selected?.id, automaticRates = automatic,
        )
    }

    fun openManual() {
        review = ChemicalReviewV2Draft(
            source = "Manual — this vineyard",
            master = null,
            intelligence = ChemicalIntelligence(),
            formType = null,
            productName = ChemicalSearchV2ManualPrefill.productName(query),
            unit = "L",
            rate = ChemicalManualRateDraft(),
            viticultureRates = ViticultureRates(),
            isManual = true,
        )
    }

    fun openWebReview(lookup: ChemicalInfoService.ChemicalStructuredLookup, fallbackName: String) {
        val intel = lookup.intelligence()
        val rates = ViticultureRates.fromRegisteredUses(intel.registeredUses)
        val automatic = if (rates.all.size > 1) emptyMap() else ChemicalSearchV2OperationalDefaults.unambiguousRates(rates)
        val selected = automatic[ChemicalDefaultRateBasis.PER_HECTARE]
            ?: automatic[ChemicalDefaultRateBasis.PER_100_LITRES]
        val initial = selected?.let(::draftRate) ?: ChemicalManualRateDraft()
        review = ChemicalReviewV2Draft(
            source = "Product label / web", master = null, intelligence = intel,
            formType = lookup.formType, productName = lookup.productName ?: fallbackName,
            unit = initial.unit.toDisplayUnit(), rate = initial, viticultureRates = rates,
            selectedRateId = selected?.id, automaticRates = automatic,
        )
    }

    fun openOnlineCandidate(candidate: ChemicalInfoService.WebV2Candidate) {
        externalJob?.cancel()
        val token = UUID.randomUUID().toString()
        externalRequestId = token
        externalBusy = true
        message = if (candidate.registrationNumber == null) "Reading product label…" else "Checking official product record…"
        val selectedQuery = query.trim()
        externalJob = scope.launch {
            try {
                val result = externalService.lookupSelectedOnlineCandidate(candidate, selectedQuery)
                if (externalRequestId != token) return@launch
                if (result.detail != null) openWebReview(result.detail, candidate.name)
                else message = "No reliable product source found. Check details or create manually."
            } catch (_: CancellationException) {
            } catch (_: Exception) {
                if (externalRequestId == token) message = "Could not read this product. Try again or create manually."
            } finally {
                if (externalRequestId == token) { externalBusy = false; externalRequestId = null }
            }
        }
    }

    fun runOnlineSearch(trimmed: String, automatically: Boolean = false) {
        if (trimmed.length < 2) return
        val local = ChemicalSearchV2Duplicate.localMatches(trimmed, state.savedChemicals)
        if (local.isNotEmpty()) { savedMatches = local; results = emptyList(); return }
        requestId = null
        searching = false
        externalJob?.cancel()
        val token = UUID.randomUUID().toString()
        externalRequestId = token
        externalBusy = true
        message = if (automatically) "No catalogue match. Searching the official register online…" else "Searching the official register online…"
        onlineCandidates = emptyList()
        externalJob = scope.launch {
            try {
                val response = externalService.lookupOnlineCandidates(trimmed)
                if (externalRequestId != token) return@launch
                onlineCandidates = response.candidates
                response.detail?.let { openWebReview(it, response.candidates.firstOrNull()?.name ?: trimmed) }
                message = if (response.detail != null) null else if (onlineCandidates.isEmpty())
                    "No reliable agricultural source found online. Check the name or create manually."
                else if (automatically) "No catalogue match. Choose an agricultural product found online."
                else "Choose the agricultural product you use."
            } catch (_: CancellationException) {
            } catch (_: Exception) {
                if (externalRequestId == token) message = if (automatically)
                    "No catalogue match. Online search is unavailable; try again or create manually."
                else "Online search is unavailable. Try again or create manually."
            } finally {
                if (externalRequestId == token) { externalBusy = false; externalRequestId = null }
            }
        }
    }

    fun runSearch(searchQuery: String = query) {
        val trimmed = searchQuery.trim()
        if (trimmed.length < 2) return
        searchJob?.cancel()
        requestId = null
        results = emptyList()
        onlineCandidates = emptyList()
        externalRequestId = null
        externalJob?.cancel()
        externalBusy = false
        savedMatches = ChemicalSearchV2Duplicate.localMatches(trimmed, state.savedChemicals)
        if (savedMatches.isNotEmpty()) {
            searching = false
            message = "This chemical is already saved. Use the existing record without creating another copy."
            return
        }
        val token = UUID.randomUUID().toString()
        requestId = token
        searching = true
        message = null
        searchJob = scope.launch {
            try {
                val found = repository.search(trimmed)
                if (requestId != token) return@launch
                results = found
                if (found.isEmpty()) {
                    searching = false
                    runOnlineSearch(trimmed, automatically = true)
                }
            } catch (_: CancellationException) {
            } catch (_: Exception) {
                if (requestId == token) { results = emptyList(); message = "Catalogue search is unavailable. Try again or search online." }
            } finally {
                if (requestId == token) searching = false
            }
        }
    }

    fun acceptPhoto(uri: Uri) {
        photoJob?.cancel()
        photoBusy = true
        photoBytes = null
        photoRegistration = null
        photoProductName = null
        proposedIdentity = null
        message = null
        photoJob = scope.launch {
            try {
                photoBytes = PinPhotoImageUtil.compress(context, uri)
                val evidence = ChemicalLabelIdentityOCR.recognise(context, uri)
                val name = runCatching { externalService.identifyLabel(evidence.text) }.getOrNull()
                photoRegistration = evidence.apvmaNumber
                photoProductName = name
                val identity = ChemicalLabelIdentityOCR.proposedQuery(evidence.apvmaNumber, name)
                if (identity == null) {
                    message = "No confident identity found. Enter the product name to search VineTrack Master."
                } else {
                    proposedIdentity = name ?: "APVMA $identity"
                    query = identity
                    message = "Confirm or edit the search text before searching VineTrack Master."
                }
            } catch (_: CancellationException) {
            } catch (error: Exception) {
                message = "Could not identify the label. Enter a product name or APVMA number to search."
            } finally { photoBusy = false }
        }
    }

    val capture = rememberPhotoCaptureCoordinator(
        onPhoto = { uri -> if (uri != null) acceptPhoto(uri) },
        onError = { message = it },
    )

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add Chemical", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            if (review == null) {
                OutlinedTextField(
                    value = query, onValueChange = {
                        query = it
                        requestId = null
                        searchJob?.cancel()
                        externalRequestId = null
                        externalJob?.cancel()
                        results = emptyList()
                        onlineCandidates = emptyList()
                        savedMatches = emptyList()
                        searching = false
                        externalBusy = false
                        message = null
                    },
                    label = { Text("Product, APVMA number, active or manufacturer") },
                    modifier = Modifier.fillMaxWidth(), singleLine = true,
                )
                Button(onClick = { runSearch() }, enabled = query.trim().length >= 2 && !searching && !externalBusy, modifier = Modifier.fillMaxWidth()) {
                    if (searching) CircularProgressIndicator() else Text("Find Chemical")
                }
                OutlinedButton(onClick = ::openManual, modifier = Modifier.fillMaxWidth()) {
                    Text("Create Manually")
                }
                Text("Checks your Chemical Store, then VineTrack's catalogue. If there is no catalogue match, searches online automatically.", fontSize = 12.sp)
                if (photoBusy) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp)); Text("Identifying product on label…")
                }
                proposedIdentity?.let { proposed ->
                    Text("Product found on label: $proposed", fontWeight = FontWeight.SemiBold)
                    photoRegistration?.let { Text("APVMA $it") }
                    Text("Edit the search text above if needed.", fontSize = 12.sp)
                    Button(onClick = { proposedIdentity = null; runSearch() }, enabled = query.trim().length >= 2) {
                        Text("Search this product")
                    }
                }
                message?.let { Text(it, fontSize = 13.sp) }
                if (savedMatches.isNotEmpty()) {
                    Text("Already in your Chemical Store", fontWeight = FontWeight.SemiBold)
                    savedMatches.forEach { chemical ->
                        Button(onClick = { onSaved(chemical); onDismiss() }, modifier = Modifier.fillMaxWidth()) {
                            Text("Use Chemical — ${chemical.displayName}")
                        }
                    }
                }
                results.forEach { result ->
                    HorizontalDivider()
                    Text(result.registeredProductName, fontWeight = FontWeight.SemiBold)
                    result.registrant?.let { Text(it, fontSize = 13.sp) }
                    Text("APVMA ${result.registrationNumber}", fontSize = 12.sp)
                    if (result.activeIngredients.isNotEmpty()) Text(result.activeIngredients.joinToString { it.name }, fontSize = 12.sp)
                    result.productCategory?.takeIf(String::isNotBlank)?.let { Text(it.replaceFirstChar(Char::uppercase), fontSize = 12.sp) }
                    Button(onClick = { openMaster(result) }) { Text("Use this chemical") }
                }
                if (onlineCandidates.isNotEmpty()) {
                    HorizontalDivider()
                    Text("Agricultural products — choose your product", fontWeight = FontWeight.SemiBold)
                    onlineCandidates.forEach { candidate ->
                        Text(candidate.name, fontWeight = FontWeight.SemiBold)
                        candidate.brand.takeIf(String::isNotBlank)?.let { Text(it, fontSize = 13.sp) }
                        candidate.activeIngredient.takeIf(String::isNotBlank)?.let { Text(it, fontSize = 12.sp) }
                        candidate.productCategory?.takeIf(String::isNotBlank)?.let { Text(it, fontSize = 12.sp) }
                        Button(onClick = { openOnlineCandidate(candidate) }, enabled = !externalBusy) { Text("Use this chemical") }
                    }
                }
                HorizontalDivider()
                TextButton(
                    onClick = { if (!externalBusy) runOnlineSearch(query.trim()) },
                    enabled = query.trim().length >= 2 && !externalBusy,
                ) {
                    if (externalBusy) { CircularProgressIndicator(modifier = Modifier.size(20.dp)); Text("Finding agricultural product…") }
                    else Text("Search online")
                }
                OutlinedButton(onClick = capture.takePhoto, modifier = Modifier.fillMaxWidth()) { Text("Take Photo of Label") }
                OutlinedButton(onClick = capture.chooseFromGallery, modifier = Modifier.fillMaxWidth()) { Text("Choose Label Photo") }
                TextButton(onClick = { externalJob?.cancel(); photoJob?.cancel(); onDismiss() }, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
            } else {
                ChemicalReviewV2(
                    draft = review!!,
                    state = state,
                    vm = vm,
                    photoBytes = photoBytes,
                    onDraft = { review = it },
                    onBack = { review = null },
                    onDone = onDismiss,
                    onOpenExisting = onOpenExisting,
                    onSaved = onSaved,
                )
            }
        }
    }
}

@Composable
private fun ChemicalReviewV2(
    draft: ChemicalReviewV2Draft,
    state: AppUiState,
    vm: AppViewModel,
    photoBytes: ByteArray?,
    onDraft: (ChemicalReviewV2Draft) -> Unit,
    onBack: () -> Unit,
    onDone: () -> Unit,
    onOpenExisting: (SavedChemical) -> Unit,
    onSaved: (SavedChemical) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    var saving by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var duplicate by remember { mutableStateOf<SavedChemical?>(null) }
    var optionalExpanded by remember { mutableStateOf(false) }
    val rateIntel = remember(draft.rate, draft.productName) {
        ChemicalManualEntry.proposedIntelligence(
            ChemicalManualDraft(productName = draft.productName, productRates = listOf(draft.rate)), null,
        )
    }
    val parsedRate = rateIntel.registeredUses.firstOrNull(ChemicalManualEntry::isProductRateCarrier)?.rates?.firstOrNull()
    val effectiveRates = ChemicalSearchV2OperationalDefaults.effectiveRates(
        draft.automaticRates, parsedRate,
    )
    val evaluation = ChemicalSaveContract.evaluateMinimumOperational(
        draft.productName, draft.unit, effectiveRates,
    )
    val enteredLabelRate = draft.enteredLabelRate?.let { rate ->
        ChemicalManualEntry.proposedIntelligence(
            ChemicalManualDraft(productName = draft.productName, productRates = listOf(rate)), null,
        ).registeredUses.firstOrNull(ChemicalManualEntry::isProductRateCarrier)?.rates?.firstOrNull()
    }
    val reviewedIntelligence: ChemicalIntelligence = run {
        val details = draft.manualDetails
        var proposed = if (draft.isManual) details.intelligence(draft.productName, draft.rate) else draft.intelligence
        if (!draft.isManual) {
            if (proposed.productCategory.isBlank()) proposed = proposed.copy(productCategory = details.productCategory.trim())
            if (proposed.activeIngredients.isEmpty() && details.activeIngredient.isNotBlank()) {
                proposed = proposed.copy(activeIngredients = details.activeIngredient.split(',').mapNotNull { name ->
                    name.trim().takeIf(String::isNotEmpty)?.let { ChemicalActiveIngredient(name = it, identitySource = ChemicalDataSourceKind.MANUAL_ENTRY) }
                })
            }
            if (details.labelUrl.isNotBlank() && proposed.registration?.labelReference.isNullOrBlank()) {
                proposed = proposed.copy(registration = (proposed.registration ?: ChemicalRegistration()).copy(labelReference = details.labelUrl.trim()))
            }
        }
        proposed = proposed.copy(activeIngredients = proposed.activeIngredients.map { active ->
            val edit = draft.activeCorrections[active.name] ?: return@map active
            val concentration = edit.concentrationText.replace(',', '.').toDoubleOrNull()
            val enteredGroup = edit.scheme?.takeIf { it != ChemicalActivityGroupScheme.NOT_APPLICABLE }
                ?.let { scheme -> edit.groupCode.takeIf(String::isNotBlank)?.let { ChemicalActivityGroup(scheme, it) } }
            active.copy(
                concentration = if (!active.hasConcentration && concentration != null && edit.concentrationUnit != null) concentration else active.concentration,
                concentrationUnit = if (!active.hasConcentration && concentration != null) edit.concentrationUnit else active.concentrationUnit,
                activityGroup = if (active.activityGroup?.isResistanceRelevant != true) enteredGroup ?: active.activityGroup else active.activityGroup,
            )
        })
        if (enteredLabelRate != null && proposed.registeredUses.filter { it.isViticultural }.flatMap { it.rates }.none(ChemicalSaveContract::isUsable)) {
            proposed = proposed.copy(registeredUses = proposed.registeredUses + ChemicalRegisteredUse(
                crop = "Grapes", targetRaw = "Entered manually from label", rates = listOf(enteredLabelRate),
                provenance = mapOf("rates" to "manual_entry"),
            ))
        }
        if (draft.isManual) proposed else ChemicalEditReconciler.reconcile(draft.intelligence, proposed).intelligence
    }
    val completeness = ChemicalDetailsCompleteness.assess(
        draft.productName, reviewedIntelligence.productCategory,
        draft.manualDetails.productForm.ifBlank { draft.formType.orEmpty() }, reviewedIntelligence,
        draft.manualDetails.labelUrl, effectiveRates.isNotEmpty(),
        reviewedIntelligence.registeredUses.filter { it.isViticultural }.flatMap { it.rates }.any(ChemicalSaveContract::isUsable),
    )
    val registeredRates = draft.viticultureRates.all

    Text(if (draft.isManual) "Add Chemical Manually" else "Review Chemical", fontSize = 22.sp, fontWeight = FontWeight.Bold)
    Text(completeness.title, fontWeight = FontWeight.SemiBold)
    completeness.missingText?.let { Text(it, fontSize = 12.sp) }
    Text("Source: ${if (draft.isManual) "Entered manually" else if (draft.source == "VineTrack Master") "VineTrack Master" else if (reviewedIntelligence.registration?.labelReference.isNullOrBlank()) "Online lookup" else "Product label"}", fontSize = 12.sp)
    OutlinedTextField(
        value = draft.productName,
        onValueChange = { onDraft(draft.copy(productName = it)) },
        label = { Text("Chemical / product name *") },
        modifier = Modifier.fillMaxWidth(),
    )
    if (draft.isManual) {
        Text("Enter the details you have; missing fields can be completed below.", fontSize = 12.sp)
    } else {
        Text("Registrant: ${draft.intelligence.registration?.registrant?.takeIf(String::isNotBlank) ?: "Not found — check label"}")
        val apvmaEvidence = if (draft.source == "Product label / web") {
            draft.intelligence.registration?.registrationNumber?.let { "$it (from label)" } ?: "Not stated on label"
        } else if (draft.intelligence.hasEvidencedRegistration) {
            draft.intelligence.registration?.registrationNumber ?: "—"
        } else "APVMA number not available"
        Text("APVMA: $apvmaEvidence")
        Text("Active ingredients: ${draft.intelligence.activeIngredients.joinToString { it.displayLabelWithGroup }.ifBlank { "Needs confirmation — check label" }}")
        Text("Category: ${draft.intelligence.productCategory.ifBlank { "Not found — check label" }}")
        Text("Product form: ${draft.manualDetails.productForm.ifBlank { draft.formType?.takeIf(String::isNotBlank) ?: "Needs confirmation" }}")
        val label = listOfNotNull(
            draft.intelligence.registration?.manufacturerLabelUrl,
            draft.intelligence.registration?.regulatorLabelUrl,
            draft.intelligence.registration?.labelReference,
        ).firstOrNull { url ->
            runCatching { java.net.URI(url) }.getOrNull()?.let { uri ->
                uri.scheme == "https" && uri.host != null && uri.path.endsWith(".pdf", ignoreCase = true)
            } == true
        }
        if (label != null) {
            TextButton(onClick = { uriHandler.openUri(label) }) { Text("View Label") }
        } else Text("Label not found — check product packaging", fontSize = 12.sp)
        Text(if (draft.source == "Product label / web") "Vineyard label rates" else "Registered vineyard rates", fontWeight = FontWeight.Bold)
        if (registeredRates.isEmpty()) {
            Text("Grapevine use / rate not found — check label.", fontSize = 13.sp)
        }
        if (draft.viticultureRates.perHectare.isNotEmpty()) {
            Text("Per hectare", fontWeight = FontWeight.SemiBold)
            draft.viticultureRates.perHectare.forEach { Text(it.displayRate) }
        }
        if (draft.viticultureRates.per100Litres.isNotEmpty()) {
            Text("Per 100 L", fontWeight = FontWeight.SemiBold)
            draft.viticultureRates.per100Litres.forEach { Text(it.displayRate) }
        }
        if (draft.source == "Product label / web") {
            draft.intelligence.registeredUses.filter { it.isViticultural }.forEach { use ->
                Text("${use.crop} · ${use.targetRaw}", fontWeight = FontWeight.SemiBold)
                use.rates.forEach { rate -> Text(rate.displayRate, fontSize = 13.sp) }
                use.withholdingPeriodDays?.let { Text("Withholding: $it days", fontSize = 12.sp) }
                use.reEntryStatement?.let { Text("Re-entry: $it", fontSize = 12.sp) }
                use.restrictions?.let { Text(it, fontSize = 12.sp) }
            }
        }
    }
    if (!draft.isManual && registeredRates.isNotEmpty()) {
        Text("Choose a registered rate, or edit the operational default below", fontWeight = FontWeight.SemiBold)
        registeredRates.forEach { rate ->
            OutlinedButton(onClick = {
                val basis = ChemicalDefaultRateBasis.of(rate.basis)
                onDraft(draft.copy(
                    rate = ChemicalManualRateDraft(
                        label = rate.label, basis = rate.basis,
                        valueText = rate.value?.toString().orEmpty(),
                        minText = rate.minValue?.toString().orEmpty(), maxText = rate.maxValue?.toString().orEmpty(),
                        unit = rate.unit.ifBlank { "L" }, rawText = rate.rawText.orEmpty(),
                    ),
                    unit = rate.unit.toDisplayUnit(), selectedRateId = rate.id,
                    automaticRates = if (basis == null) emptyMap() else mapOf(basis to rate),
                ))
            }, modifier = Modifier.fillMaxWidth()) { Text(rate.displayRate) }
        }
    }

    Text("Operational Default Rate *", fontWeight = FontWeight.Bold)
    val isRange = draft.rate.basis == ChemicalLabelRateBasis.RANGE_PER_HECTARE || draft.rate.basis == ChemicalLabelRateBasis.RANGE_PER_100_LITRES
    val isPer100 = draft.rate.basis == ChemicalLabelRateBasis.PER_100_LITRES || draft.rate.basis == ChemicalLabelRateBasis.RANGE_PER_100_LITRES
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        listOf(false to "Single rate", true to "Range").forEachIndexed { index, option ->
            SegmentedButton(
                selected = isRange == option.first,
                onClick = {
                    val basis = if (option.first) {
                        if (isPer100) ChemicalLabelRateBasis.RANGE_PER_100_LITRES else ChemicalLabelRateBasis.RANGE_PER_HECTARE
                    } else if (isPer100) ChemicalLabelRateBasis.PER_100_LITRES else ChemicalLabelRateBasis.PER_HECTARE
                    onDraft(draft.copy(rate = draft.rate.copy(basis = basis)))
                },
                shape = SegmentedButtonDefaults.itemShape(index, 2),
            ) { Text(option.second) }
        }
    }
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        listOf(false to "Per hectare", true to "Per 100 L").forEachIndexed { index, option ->
            SegmentedButton(
                selected = isPer100 == option.first,
                onClick = {
                    val basis = if (isRange) {
                        if (option.first) ChemicalLabelRateBasis.RANGE_PER_100_LITRES else ChemicalLabelRateBasis.RANGE_PER_HECTARE
                    } else if (option.first) ChemicalLabelRateBasis.PER_100_LITRES else ChemicalLabelRateBasis.PER_HECTARE
                    onDraft(draft.copy(rate = draft.rate.copy(basis = basis)))
                },
                shape = SegmentedButtonDefaults.itemShape(index, 2),
            ) { Text(option.second) }
        }
    }
    if (isRange) {
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val stacked = maxWidth < 300.dp || LocalDensity.current.fontScale >= 1.4f
            val minimum: @Composable (Modifier) -> Unit = { modifier ->
                OutlinedTextField(
                    draft.rate.minText, { onDraft(draft.copy(rate = draft.rate.copy(minText = it.filterRateChars()))) },
                    label = { Text("Minimum *") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = modifier,
                )
            }
            val maximum: @Composable (Modifier) -> Unit = { modifier ->
                OutlinedTextField(
                    draft.rate.maxText, { onDraft(draft.copy(rate = draft.rate.copy(maxText = it.filterRateChars()))) },
                    label = { Text("Maximum *") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = modifier,
                )
            }
            if (stacked) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                minimum(Modifier.fillMaxWidth()); maximum(Modifier.fillMaxWidth())
            } else Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                minimum(Modifier.weight(1f)); maximum(Modifier.weight(1f))
            }
        }
    } else {
        OutlinedTextField(
            draft.rate.valueText, { onDraft(draft.copy(rate = draft.rate.copy(valueText = it.filterRateChars()))) },
            label = { Text("Rate *") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth(),
        )
    }
    Text("Product / rate unit *")
    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val units = listOf("L", "mL", "Kg", "g")
        val columns = if (maxWidth < 300.dp || LocalDensity.current.fontScale >= 1.4f) 2 else 4
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            units.chunked(columns).forEach { rowUnits ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    rowUnits.forEach { unit ->
                        OutlinedButton(
                            onClick = { onDraft(draft.copy(unit = unit, rate = draft.rate.copy(unit = unit.toRateToken()))) },
                            modifier = Modifier.weight(1f),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp),
                        ) {
                            val label = if (unit == "Kg") "kg" else unit
                            Text(if (draft.unit == unit) "✓ $label" else label)
                        }
                    }
                }
            }
        }
    }
    Text("If rate is not found, check the label and enter the correct vineyard rate here. Rate bases are stored exactly as entered and never converted.", fontSize = 12.sp)
    TextButton(onClick = { optionalExpanded = !optionalExpanded }, modifier = Modifier.fillMaxWidth()) {
        Text(if (optionalExpanded) "Hide missing details" else "Fill missing details")
    }
    if (optionalExpanded) {
            if (draft.isManual) {
                ChemicalManualOptionalDetails(
                    details = draft.manualDetails,
                    onDetails = { onDraft(draft.copy(manualDetails = it)) },
                )
            } else {
                OutlinedTextField(draft.manualDetails.productCategory, { onDraft(draft.copy(manualDetails = draft.manualDetails.copy(productCategory = it))) }, label = { Text("Category") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(draft.manualDetails.productForm, { onDraft(draft.copy(manualDetails = draft.manualDetails.copy(productForm = it))) }, label = { Text("Product form (liquid or solid)") }, modifier = Modifier.fillMaxWidth())
                if (draft.intelligence.activeIngredients.isEmpty()) {
                    OutlinedTextField(draft.manualDetails.activeIngredient, { onDraft(draft.copy(manualDetails = draft.manualDetails.copy(activeIngredient = it))) }, label = { Text("Active ingredient(s), comma separated") }, modifier = Modifier.fillMaxWidth())
                }
                OutlinedTextField(draft.manualDetails.labelUrl, { onDraft(draft.copy(manualDetails = draft.manualDetails.copy(labelUrl = it))) }, label = { Text("Product label link") }, modifier = Modifier.fillMaxWidth())
            }
            reviewedIntelligence.activeIngredients.filter {
                !it.hasConcentration || (!draft.isManual && it.activityGroup?.isResistanceRelevant != true) || draft.activeCorrections.containsKey(it.name)
            }.forEach { active ->
                val edit = draft.activeCorrections[active.name] ?: ChemicalManualActiveDraft(name = active.name)
                fun update(next: ChemicalManualActiveDraft) {
                    onDraft(draft.copy(activeCorrections = draft.activeCorrections + (active.name to next)))
                }
                Text(active.name, fontWeight = FontWeight.SemiBold)
                if (!active.hasConcentration || draft.activeCorrections.containsKey(active.name)) {
                    OutlinedTextField(edit.concentrationText, { update(edit.copy(concentrationText = it.filterRateChars())) }, label = { Text("Active concentration") }, modifier = Modifier.fillMaxWidth())
                    ChemicalConcentrationUnit.entries.forEach { unit ->
                        TextButton(onClick = { update(edit.copy(concentrationUnit = unit)) }) {
                            Text("${if (edit.concentrationUnit == unit) "✓ " else ""}${unit.label}")
                        }
                    }
                }
                if (!draft.isManual && active.activityGroup?.isResistanceRelevant != true) {
                    ChemicalActivityGroupScheme.entries.filter { it != ChemicalActivityGroupScheme.NOT_APPLICABLE }.forEach { scheme ->
                        TextButton(onClick = { update(edit.copy(scheme = scheme)) }) {
                            Text("${if (edit.scheme == scheme) "✓ " else ""}${scheme.label}")
                        }
                    }
                    OutlinedTextField(edit.groupCode, { update(edit.copy(groupCode = it)) }, label = { Text("Group code") }, modifier = Modifier.fillMaxWidth())
                }
            }
            if (draft.enteredLabelRate != null) {
                OutlinedTextField(draft.enteredLabelRate.valueText, { onDraft(draft.copy(enteredLabelRate = draft.enteredLabelRate.copy(valueText = it.filterRateChars()))) }, label = { Text("Vineyard label rate") }, modifier = Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(ChemicalLabelRateBasis.PER_HECTARE to "Per hectare", ChemicalLabelRateBasis.PER_100_LITRES to "Per 100 L").forEach { (basis, title) ->
                        TextButton(onClick = { onDraft(draft.copy(enteredLabelRate = draft.enteredLabelRate.copy(basis = basis))) }) {
                            Text("${if (draft.enteredLabelRate.basis == basis) "✓ " else ""}$title")
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    listOf("L", "mL", "kg", "g").forEach { unit ->
                        TextButton(onClick = { onDraft(draft.copy(enteredLabelRate = draft.enteredLabelRate.copy(unit = unit))) }) {
                            Text("${if (draft.enteredLabelRate.unit == unit) "✓ " else ""}$unit")
                        }
                    }
                }
                Text("This rate was entered manually from your product label; VineTrack has not confirmed the direction.", fontSize = 12.sp)
            } else if ("label rate" in completeness.missing) {
                TextButton(onClick = { onDraft(draft.copy(enteredLabelRate = ChemicalManualRateDraft(basis = draft.rate.basis, unit = draft.rate.unit))) }) { Text("Enter vineyard rate from product label") }
            }
    }
    evaluation.violations.forEach { Text(it.message, color = com.rork.vinetrack.ui.theme.VineColors.Warning, fontSize = 12.sp) }
    duplicate?.let { existing ->
        Text("${existing.displayName} already exists in this vineyard.", color = com.rork.vinetrack.ui.theme.VineColors.Warning)
        OutlinedButton(onClick = { onSaved(existing); onDone() }, modifier = Modifier.fillMaxWidth()) { Text("Use Chemical") }
    }
    notice?.let { Text(it, color = com.rork.vinetrack.ui.theme.VineColors.Warning) }
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(onClick = onBack, modifier = Modifier.weight(1f)) { Text("Back") }
        Button(
            enabled = evaluation.isSatisfied && !saving,
            onClick = {
                val saveIntelligence = reviewedIntelligence
                val existing = ChemicalSearchV2Duplicate.existing(
                    draft.master, saveIntelligence, draft.productName, state.savedChemicals,
                )
                if (existing != null) { duplicate = existing; notice = null; return@Button }
                val vineyardId = state.selectedVineyardId ?: run { notice = "Select a vineyard first."; return@Button }
                val rate = effectiveRates.firstOrNull() ?: return@Button
                saving = true
                val isArea = rate.basis == ChemicalLabelRateBasis.PER_HECTARE || rate.basis == ChemicalLabelRateBasis.RANGE_PER_HECTARE
                val display = rate.value ?: rate.minValue ?: 0.0
                val canonicalIntelligence = ChemicalLabelRateNormalizer.normalize(saveIntelligence)
                if (canonicalIntelligence == null) {
                    saving = false
                    notice = "Invalid stored rate. Correct the unit, amount and rate basis before saving."
                    return@Button
                }
                val details = draft.manualDetails
                val packSize = details.packSize.toDoubleOrNull()
                val pricePerPack = details.pricePerPack.toDoubleOrNull()
                val purchase = if (draft.isManual && (packSize != null || pricePerPack != null)) {
                    ChemicalPurchase(
                        brand = details.manufacturer.trim(),
                        activeIngredient = details.activeIngredient.trim(),
                        chemicalGroup = details.activityGroupCode.trim(),
                        labelUrl = details.labelUrl.trim(),
                        costDollars = pricePerPack ?: 0.0,
                        containerSizeML = packSize ?: 0.0,
                        containerUnit = draft.unit,
                    )
                } else null
                val input = SavedChemicalRepository.ChemicalInput(
                    name = draft.productName.trim(), unit = draft.unit,
                    ratePerHa = if (isArea && rate.value != null) display else null,
                    rates = rate.value?.let { fixed ->
                        listOf(ChemicalRate(
                            id = UUID.randomUUID().toString(), label = rate.label,
                            value = chemicalUnitToBase(draft.unit, fixed),
                            basis = if (isArea) CHEMICAL_RATE_PER_HECTARE else CHEMICAL_RATE_PER_100L,
                        ))
                    }.orEmpty(),
                    activeIngredient = canonicalIntelligence.legacyActiveIngredient,
                    chemicalGroup = canonicalIntelligence.legacyChemicalGroup,
                    use = null, problem = null,
                    manufacturer = if (draft.isManual) details.manufacturer else draft.intelligence.registration?.registrant,
                    notes = if (draft.isManual) details.notes else null, modeOfAction = null,
                    labelUrl = details.labelUrl.ifBlank { saveIntelligence.registration?.labelReference },
                    productUrl = if (draft.isManual) details.productUrl else draft.intelligence.registration?.manufacturerProductUrl,
                    purchase = purchase,
                    productCategory = saveIntelligence.productCategory,
                    productForm = details.productForm.ifBlank { draft.formType.orEmpty() },
                    packSize = if (draft.isManual) packSize else null,
                    packUnit = if (draft.isManual) details.packUnit else "",
                    pricePerPack = if (draft.isManual) pricePerPack else null,
                    inventoryQuantity = if (draft.isManual) details.inventoryQuantity.toDoubleOrNull() else null,
                    inventoryUnit = if (draft.isManual) details.inventoryUnit else "",
                    intelligence = canonicalIntelligence,
                    masterChemicalId = draft.master?.id ?: draft.masterMatch?.masterChemicalId,
                    masterSourceRevision = draft.master?.catalogueVersion ?: draft.masterMatch?.masterRevision,
                    defaultRates = ChemicalSearchV2OperationalDefaults.storedDefaults(
                        effectiveRates, java.time.Instant.now().toString(),
                    ),
                    entrySource = SavedChemicalEntrySource.reviewed(draft.isManual, draft.master != null || draft.masterMatch != null, canonicalIntelligence),
                )
                vm.createSavedChemicalV2(input, photoBytes) { created ->
                    saving = false
                    if (created == null) {
                        notice = "Couldn't save this chemical. Check your connection and try again."
                        return@createSavedChemicalV2
                    }
                    onSaved(created)
                    onDone()
                }
            },
            modifier = Modifier.weight(1f),
        ) { Text("Save") }
    }
}

@Composable
private fun ChemicalManualOptionalDetails(
    details: ChemicalSearchV2ManualDetails,
    onDetails: (ChemicalSearchV2ManualDetails) -> Unit,
) {
    var groupMenuExpanded by remember { mutableStateOf(false) }
    OutlinedTextField(details.manufacturer, { onDetails(details.copy(manufacturer = it)) }, label = { Text("Manufacturer / registrant") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.registrationNumber, { onDetails(details.copy(registrationNumber = it)) }, label = { Text("APVMA registration number") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.productCategory, { onDetails(details.copy(productCategory = it)) }, label = { Text("Category") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.productForm, { onDetails(details.copy(productForm = it)) }, label = { Text("Product form") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.activeIngredient, { onDetails(details.copy(activeIngredient = it)) }, label = { Text("Active ingredient(s), comma separated") }, modifier = Modifier.fillMaxWidth())
    TextButton(onClick = { groupMenuExpanded = true }, modifier = Modifier.fillMaxWidth()) {
        Text("Activity group: ${details.activityGroupScheme?.label ?: "Not specified"}")
    }
    DropdownMenu(expanded = groupMenuExpanded, onDismissRequest = { groupMenuExpanded = false }) {
        DropdownMenuItem(text = { Text("Not specified") }, onClick = {
            onDetails(details.copy(activityGroupScheme = null, activityGroupCode = ""))
            groupMenuExpanded = false
        })
        ChemicalActivityGroupScheme.entries.forEach { scheme ->
            DropdownMenuItem(text = { Text(scheme.label) }, onClick = {
                onDetails(details.copy(activityGroupScheme = scheme))
                groupMenuExpanded = false
            })
        }
    }
    if (details.activityGroupScheme != null) {
        OutlinedTextField(details.activityGroupCode, { onDetails(details.copy(activityGroupCode = it)) }, label = { Text("Group code") }, modifier = Modifier.fillMaxWidth())
    }
    OutlinedTextField(details.labelUrl, { onDetails(details.copy(labelUrl = it)) }, label = { Text("Label URL") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.productUrl, { onDetails(details.copy(productUrl = it)) }, label = { Text("Product URL") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.notes, { onDetails(details.copy(notes = it)) }, label = { Text("Notes") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.packSize, { onDetails(details.copy(packSize = it.filterRateChars())) }, label = { Text("Pack size") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.packUnit, { onDetails(details.copy(packUnit = it)) }, label = { Text("Pack unit") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.pricePerPack, { onDetails(details.copy(pricePerPack = it.filterRateChars())) }, label = { Text("Price per pack") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.inventoryQuantity, { onDetails(details.copy(inventoryQuantity = it.filterRateChars())) }, label = { Text("Inventory quantity") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
    OutlinedTextField(details.inventoryUnit, { onDetails(details.copy(inventoryUnit = it)) }, label = { Text("Inventory unit") }, modifier = Modifier.fillMaxWidth())
}

private fun String.filterRateChars(): String = filter { it.isDigit() || it == '.' || it == ',' }.replace(',', '.')
private fun String.toDisplayUnit(): String = when (lowercase()) { "ml" -> "mL"; "kg" -> "Kg"; "g" -> "g"; else -> "L" }
private fun String.toRateToken(): String = when (this) { "Kg" -> "kg"; else -> this }
