package com.rork.vinetrack.ui.screens

import android.net.Uri
import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.PinPhotoImageUtil
import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.chemical.ChemicalLabelAttachmentV2Repository
import com.rork.vinetrack.data.chemical.ChemicalLabelIdentityOCR
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLabelRateNormalizer
import com.rork.vinetrack.data.chemical.ChemicalManualDraft
import com.rork.vinetrack.data.chemical.ChemicalManualEntry
import com.rork.vinetrack.data.chemical.ChemicalManualRateDraft
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.ChemicalSearchV2Duplicate
import com.rork.vinetrack.data.chemical.ChemicalSearchV2OperationalDefaults
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.MasterChemicalV2
import com.rork.vinetrack.data.chemical.MasterChemicalV2Repository
import com.rork.vinetrack.data.chemical.ViticultureRates
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.chemicalUnitToBase
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.components.rememberPhotoCaptureCoordinator
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.UUID

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
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChemicalSearchV2Sheet(
    vm: AppViewModel,
    state: AppUiState,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val repository = remember { MasterChemicalV2Repository() }
    val externalService = remember { ChemicalInfoService() }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<MasterChemicalV2>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var searchJob by remember { mutableStateOf<Job?>(null) }
    var requestId by remember { mutableStateOf<String?>(null) }
    var review by remember { mutableStateOf<ChemicalReviewV2Draft?>(null) }
    var photoBytes by remember { mutableStateOf<ByteArray?>(null) }
    var externalBusy by remember { mutableStateOf(false) }

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
        val automatic = ChemicalSearchV2OperationalDefaults.unambiguousRates(master.viticultureRates)
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

    fun runSearch(searchQuery: String = query) {
        val trimmed = searchQuery.trim()
        if (trimmed.length < 2) return
        searchJob?.cancel()
        val token = UUID.randomUUID().toString()
        requestId = token
        searching = true
        message = null
        searchJob = scope.launch {
            try {
                val found = repository.search(trimmed)
                if (requestId != token) return@launch
                results = found
                message = if (found.isEmpty()) "No Master Catalogue match. Use a deliberate fallback below." else null
            } catch (_: CancellationException) {
            } catch (error: Exception) {
                if (requestId == token) { results = emptyList(); message = error.message ?: "Master search failed." }
            } finally {
                if (requestId == token) searching = false
            }
        }
    }

    fun acceptPhoto(uri: Uri) {
        scope.launch {
            message = "Reading visible label identity…"
            try {
                photoBytes = PinPhotoImageUtil.compress(context, uri)
                val evidence = ChemicalLabelIdentityOCR.recognise(context, uri)
                val identity = evidence.searchQuery
                if (identity == null) {
                    message = "No clear product identity was found. Search by name or APVMA number."
                    return@launch
                }
                query = identity
                val found = repository.search(identity)
                results = found
                val exact = evidence.apvmaNumber?.let { number ->
                    found.firstOrNull { it.registrationNumber.filter(Char::isDigit) == number }
                }
                Log.d("ChemicalSearchV2", "photo_match=${found.isNotEmpty()} apvma_present=${evidence.apvmaNumber != null}")
                if (exact != null) {
                    message = "Suggested Master match from APVMA number. Please confirm."
                    openMaster(exact)
                } else {
                    message = if (found.isEmpty()) "No Master match from the visible identity. You may explicitly search the label online."
                    else "Possible Master matches found. Please confirm one."
                }
            } catch (error: Exception) {
                message = error.message ?: "The label photo could not be read."
            }
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
            Text("Chemical Search V2", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            if (review == null) {
                OutlinedTextField(
                    value = query, onValueChange = { query = it },
                    label = { Text("Product, APVMA number, active or manufacturer") },
                    modifier = Modifier.fillMaxWidth(), singleLine = true,
                )
                Button(onClick = { runSearch() }, enabled = query.trim().length >= 2 && !searching, modifier = Modifier.fillMaxWidth()) {
                    if (searching) CircularProgressIndicator() else Text("Search VineTrack Master")
                }
                Text("Master Catalogue only. No AI or external lookup runs during normal search.", fontSize = 12.sp)
                message?.let { Text(it, fontSize = 13.sp) }
                results.forEach { result ->
                    HorizontalDivider()
                    Text(result.registeredProductName, fontWeight = FontWeight.SemiBold)
                    result.registrant?.let { Text(it, fontSize = 13.sp) }
                    Text("APVMA ${result.registrationNumber}", fontSize = 12.sp)
                    if (result.activeIngredients.isNotEmpty()) Text(result.activeIngredients.joinToString { it.name }, fontSize = 12.sp)
                    result.productCategory?.takeIf(String::isNotBlank)?.let { Text(it.replaceFirstChar(Char::uppercase), fontSize = 12.sp) }
                    Button(onClick = { openMaster(result) }) { Text("Use this chemical") }
                }
                HorizontalDivider()
                TextButton(
                    onClick = {
                        val trimmed = query.trim()
                        if (trimmed.length < 2 || externalBusy) return@TextButton
                        externalBusy = true
                        Log.d("ChemicalSearchV2", "fallback_invoked=true type=label_lookup")
                        scope.launch {
                            try {
                                val lookup = externalService.lookupStructured(trimmed, "AU", null)
                                val intel = lookup.intelligence()
                                val viticultureRates = ViticultureRates.fromRegisteredUses(intel.registeredUses)
                                val automatic = ChemicalSearchV2OperationalDefaults.unambiguousRates(viticultureRates)
                                val selected = automatic[ChemicalDefaultRateBasis.PER_HECTARE]
                                    ?: automatic[ChemicalDefaultRateBasis.PER_100_LITRES]
                                val initial = selected?.let(::draftRate) ?: ChemicalManualRateDraft()
                                review = ChemicalReviewV2Draft(
                                    source = "Label lookup", master = null, intelligence = intel,
                                    formType = lookup.formType, productName = lookup.productName ?: trimmed,
                                    unit = initial.unit.toDisplayUnit(), rate = initial,
                                    viticultureRates = viticultureRates,
                                    selectedRateId = selected?.id, automaticRates = automatic,
                                )
                                Log.d("ChemicalSearchV2", "external_lookup=success")
                            } catch (error: Exception) {
                                message = "Label lookup failed. ${error.message.orEmpty()}"
                                Log.d("ChemicalSearchV2", "external_lookup=failure")
                            } finally { externalBusy = false }
                        }
                    },
                    enabled = query.trim().length >= 2 && !externalBusy,
                ) { Text("Can't find it? Search label online") }
                OutlinedButton(onClick = capture.takePhoto, modifier = Modifier.fillMaxWidth()) { Text("Take Photo of Label") }
                OutlinedButton(onClick = capture.chooseFromGallery, modifier = Modifier.fillMaxWidth()) { Text("Choose Label Photo") }
                TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
            } else {
                ChemicalReviewV2(
                    draft = review!!,
                    state = state,
                    vm = vm,
                    photoBytes = photoBytes,
                    onDraft = { review = it },
                    onBack = { review = null },
                    onDone = onDismiss,
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
) {
    val scope = rememberCoroutineScope()
    var saving by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
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
    val registeredRates = draft.viticultureRates.all

    Text("Review Chemical", fontSize = 22.sp, fontWeight = FontWeight.Bold)
    Text("Source: ${draft.source}", fontWeight = FontWeight.SemiBold)
    OutlinedTextField(
        value = draft.productName,
        onValueChange = { onDraft(draft.copy(productName = it)) },
        label = { Text("Chemical / product name *") },
        modifier = Modifier.fillMaxWidth(),
    )
    Text("Registrant: ${draft.intelligence.registration?.registrant ?: "—"}")
    Text("APVMA: ${draft.intelligence.registration?.registrationNumber ?: "—"}")
    Text("Active ingredients: ${draft.intelligence.activeIngredients.joinToString { it.name }.ifBlank { "—" }}")
    draft.intelligence.productCategory.takeIf(String::isNotBlank)?.let { Text("Category: $it") }

    Text("Registered vineyard rates", fontWeight = FontWeight.Bold)
    if (registeredRates.isEmpty()) {
        Text("No registered vineyard rate is currently recorded in VineTrack.", fontSize = 13.sp)
    }
    if (draft.viticultureRates.perHectare.isNotEmpty()) {
        Text("Per hectare", fontWeight = FontWeight.SemiBold)
        draft.viticultureRates.perHectare.forEach { Text(it.displayRate) }
    }
    if (draft.viticultureRates.per100Litres.isNotEmpty()) {
        Text("Per 100 L", fontWeight = FontWeight.SemiBold)
        draft.viticultureRates.per100Litres.forEach { Text(it.displayRate) }
    }
    if (registeredRates.isNotEmpty()) {
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
                    automaticRates = if (basis == null) draft.automaticRates
                    else draft.automaticRates + (basis to rate),
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
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                draft.rate.minText, { onDraft(draft.copy(rate = draft.rate.copy(minText = it.filterRateChars()))) },
                label = { Text("Minimum *") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                draft.rate.maxText, { onDraft(draft.copy(rate = draft.rate.copy(maxText = it.filterRateChars()))) },
                label = { Text("Maximum *") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    } else {
        OutlinedTextField(
            draft.rate.valueText, { onDraft(draft.copy(rate = draft.rate.copy(valueText = it.filterRateChars()))) },
            label = { Text("Rate *") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth(),
        )
    }
    Text("Product / rate unit *")
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        listOf("L", "mL", "Kg", "g").forEach { unit ->
            OutlinedButton(onClick = { onDraft(draft.copy(unit = unit, rate = draft.rate.copy(unit = unit.toRateToken()))) }) {
                Text(if (draft.unit == unit) "✓ $unit" else unit)
            }
        }
    }
    evaluation.violations.forEach { Text(it.message, color = com.rork.vinetrack.ui.theme.VineColors.Warning, fontSize = 12.sp) }
    notice?.let { Text(it, color = com.rork.vinetrack.ui.theme.VineColors.Warning) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) { Text("Back") }
        Button(
            enabled = evaluation.isSatisfied && !saving,
            onClick = {
                val duplicate = ChemicalSearchV2Duplicate.existing(
                    draft.master, draft.intelligence, draft.productName, state.savedChemicals,
                )
                if (duplicate != null) { notice = "Already in Vineyard Chemicals: ${duplicate.displayName}"; return@Button }
                val vineyardId = state.selectedVineyardId ?: run { notice = "Select a vineyard first."; return@Button }
                val rate = effectiveRates.firstOrNull() ?: return@Button
                saving = true
                val isArea = rate.basis == ChemicalLabelRateBasis.PER_HECTARE || rate.basis == ChemicalLabelRateBasis.RANGE_PER_HECTARE
                val display = rate.value ?: rate.minValue ?: 0.0
                val canonicalIntelligence = ChemicalLabelRateNormalizer.normalize(draft.intelligence)
                if (canonicalIntelligence == null) {
                    saving = false
                    notice = "Invalid stored rate. Correct the unit, amount and rate basis before saving."
                    return@Button
                }
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
                    activeIngredient = draft.intelligence.legacyActiveIngredient,
                    chemicalGroup = draft.intelligence.legacyChemicalGroup,
                    use = null, problem = null,
                    manufacturer = draft.intelligence.registration?.registrant,
                    notes = null, modeOfAction = null,
                    labelUrl = draft.intelligence.registration?.labelReference,
                    productUrl = draft.intelligence.registration?.manufacturerProductUrl,
                    purchase = null, productCategory = draft.intelligence.productCategory,
                    productForm = draft.formType.orEmpty(), intelligence = canonicalIntelligence,
                    masterChemicalId = draft.master?.id, masterSourceRevision = draft.master?.catalogueVersion,
                    defaultRates = ChemicalSearchV2OperationalDefaults.storedDefaults(
                        effectiveRates, java.time.Instant.now().toString(),
                    ),
                    entrySource = if (draft.master == null) "label_lookup_v2" else "master_catalogue_v2",
                )
                vm.createSavedChemical(input) { ok ->
                    saving = false
                    if (!ok) return@createSavedChemical
                    val created = vm.ui.value.savedChemicals.firstOrNull {
                        (draft.master != null && it.masterChemicalId == draft.master.id) ||
                            ChemicalStoreMatching.namesMatch(it.displayName, draft.productName)
                    }
                    if (photoBytes == null || created == null) { onDone(); return@createSavedChemical }
                    scope.launch {
                        try {
                            ChemicalLabelAttachmentV2Repository().upload(photoBytes, vineyardId, created.id)
                        } catch (_: Exception) {
                            Log.w("ChemicalSearchV2", "chemical saved but label photo upload failed")
                            notice = "Chemical saved, but the label photo could not be uploaded."
                            return@launch
                        }
                        onDone()
                    }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Save") }
    }
}

private fun String.filterRateChars(): String = filter { it.isDigit() || it == '.' || it == ',' }.replace(',', '.')
private fun String.toDisplayUnit(): String = when (lowercase()) { "ml" -> "mL"; "kg" -> "Kg"; "g" -> "g"; else -> "L" }
private fun String.toRateToken(): String = when (this) { "Kg" -> "kg"; else -> this }
