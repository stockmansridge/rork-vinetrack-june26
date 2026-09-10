package com.rork.vinetrack.ui.screens

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.rork.vinetrack.data.ManualSprayDraftStore
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.ManualSprayBlock
import com.rork.vinetrack.data.model.ManualSprayChemical
import com.rork.vinetrack.data.model.ManualSprayPayload
import com.rork.vinetrack.data.model.ManualSprayPhysicalForm
import com.rork.vinetrack.data.model.ManualSprayTank
import com.rork.vinetrack.data.model.ManualSprayWeather
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.canManageManualSprays
import com.rork.vinetrack.data.reporting.SprayReportRepository
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManualSprayEntrySheet(
    vm: AppViewModel,
    state: AppUiState,
    existing: SprayRecord? = null,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!canManageManualSprays(state.currentRole)) {
        AlertDialog(onDismissRequest = onDismiss, confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } }, title = { Text("Manual spray entry unavailable") }, text = { Text("Only Owners, Managers and Supervisors can add, edit or delete completed manual sprays.") })
        return
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val vineyardId = state.selectedVineyardId ?: return
    val zone = state.seasonZone
    val session = remember { SessionStore(context) }
    val draftStore = remember { ManualSprayDraftStore(context) }
    val existingTrip = existing?.tripId?.let { id -> state.trips.firstOrNull { it.id == id } }
    val seed = remember(existing?.id, existingTrip, state.sprayTankActuals) { existing?.toManualPayload(existingTrip, state, zone) ?: if (existing == null) draftStore.load(vineyardId) else null }
    if (existing != null && seed == null) {
        AlertDialog(
            onDismissRequest = onDismiss,
            confirmButton = { TextButton(onClick = { vm.refresh() }) { Text("Retry") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
            title = { Text("Edit unavailable") },
            text = { Text("The exact trip, tank and actual identities have not finished loading. Sync and retry; no replacement draft will be created.") },
        )
        return
    }
    val identities = remember(seed?.manualEntryId) { seed?.let { Triple(it.manualEntryId, it.sprayRecordId, it.tripId) } ?: Triple(UUID.randomUUID().toString(), UUID.randomUUID().toString(), UUID.randomUUID().toString()) }
    var reference by remember { mutableStateOf(seed?.reference.orEmpty()) }
    var startInstant by remember { mutableStateOf(seed?.startUtc?.let(Instant::parse) ?: Instant.now().minusSeconds(3600)) }
    var endInstant by remember { mutableStateOf(seed?.endUtc?.let(Instant::parse) ?: Instant.now()) }
    var tractorId by remember { mutableStateOf(seed?.tractorId) }
    var operatorId by remember { mutableStateOf(seed?.operatorUserId) }
    var unitId by remember { mutableStateOf(seed?.sprayEquipmentId) }
    var startHours by remember { mutableStateOf(seed?.startEngineHours?.toString().orEmpty()) }
    var endHours by remember { mutableStateOf(seed?.endEngineHours?.toString().orEmpty()) }
    var notes by remember { mutableStateOf(seed?.notes.orEmpty()) }
    val clientUpdatedAt = remember { seed?.clientUpdatedAt ?: Instant.now().toString() }
    var isReviewing by remember { mutableStateOf(false) }
    var isSaving by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var savedTripId by remember { mutableStateOf<String?>(null) }
    var expectedVersion by remember { mutableStateOf(existing?.syncVersion?.toInt() ?: 0) }
    val blockIds = remember { mutableStateListOf<String>().apply { addAll(seed?.blocks?.map { it.blockId }.orEmpty()) } }
    val tanks = remember { mutableStateListOf<ManualSprayTank>().apply { addAll(seed?.tanks ?: listOf(ManualSprayTank(tankNumber = 1, waterVolumeLitres = 0.0, chemicals = emptyList()))) } }
    val waterInputs = remember { mutableStateMapOf<String, String>().apply { seed?.tanks?.forEach { put(it.id, it.waterVolumeLitres.toString()) } } }
    val chemicalInputs = remember { mutableStateMapOf<String, String>().apply { seed?.tanks?.flatMap { it.chemicals }?.forEach { put(it.id, displayAmount(it).toString()) } } }
    var hasManualWeather by remember { mutableStateOf(seed?.manualWeather != null) }
    var temperature by remember { mutableStateOf(seed?.manualWeather?.temperatureC?.toString().orEmpty()) }
    var humidity by remember { mutableStateOf(seed?.manualWeather?.humidityPct?.toString().orEmpty()) }
    var wind by remember { mutableStateOf(seed?.manualWeather?.windSpeedKmh?.toString().orEmpty()) }
    var gust by remember { mutableStateOf(seed?.manualWeather?.windGustKmh?.toString().orEmpty()) }
    var direction by remember { mutableStateOf(seed?.manualWeather?.windDirectionDeg?.toString().orEmpty()) }
    var rain by remember { mutableStateOf(seed?.manualWeather?.rainMm?.toString().orEmpty()) }
    var weatherEdited by remember { mutableStateOf(false) }

    LaunchedEffect(existing?.id) {
        val tripId = existing?.tripId ?: return@LaunchedEffect
        runCatching { SprayReportRepository(session).fetch(tripId) }.getOrNull()?.weather
            ?.firstOrNull { it.provider == "manual_entry" && it.sourceKind == "manual" }?.let { weather ->
                if (weatherEdited) return@let
                hasManualWeather = true
                temperature = weather.temperatureC?.toString().orEmpty(); humidity = weather.humidityPct?.toString().orEmpty()
                wind = weather.windSpeedKmh?.toString().orEmpty(); gust = weather.windGustKmh?.toString().orEmpty()
                direction = weather.windDirectionDeg?.toString().orEmpty(); rain = weather.rainMm?.toString().orEmpty()
            }
    }

    fun payload(): ManualSprayPayload = ManualSprayPayload(
        vineyardId = vineyardId, manualEntryId = identities.first, sprayRecordId = identities.second, tripId = identities.third,
        reference = reference, operationType = existing?.operationType ?: "Foliar Spray", startUtc = startInstant.toString(), endUtc = endInstant.toString(),
        vineyardTimeZone = zone.id, tractorId = tractorId, operatorUserId = operatorId, sprayEquipmentId = unitId,
        startEngineHours = startHours.toDoubleOrNull(), endEngineHours = endHours.toDoubleOrNull(), notes = notes.takeIf { it.isNotBlank() }, clientUpdatedAt = clientUpdatedAt,
        blocks = state.paddocks.filter { it.id in blockIds }.map { ManualSprayBlock(it.id, it.name) },
        tanks = tanks.map { tank -> tank.copy(
            waterVolumeLitres = waterInputs[tank.id]?.toDoubleOrNull() ?: Double.NaN,
            chemicals = tank.chemicals.map { chemical -> chemical.copy(
                actualAmountBase = chemicalInputs[chemical.id]?.toDoubleOrNull()?.let { toBase(it, chemical.unit) } ?: Double.NaN,
            ) },
        ) },
        manualWeather = if (hasManualWeather) ManualSprayWeather(startInstant.toString(), temperatureC = temperature.toDoubleOrNull(), humidityPct = humidity.toDoubleOrNull(), windSpeedKmh = wind.toDoubleOrNull(), windGustKmh = gust.toDoubleOrNull(), windDirectionDeg = direction.toDoubleOrNull(), rainMm = rain.toDoubleOrNull()) else null,
    )

    val currentDraft = payload()
    LaunchedEffect(currentDraft, existing?.id, savedTripId) {
        if (existing == null && savedTripId == null) draftStore.save(currentDraft)
    }

    Dialog(onDismissRequest = onDismiss) {
        Column(modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(if (isReviewing) "Review manual spray" else if (existing == null) "Add manual spray" else "Edit manual spray")
            if (!isReviewing) {
                OutlinedTextField(reference, { reference = it }, label = { Text("Name or reference") }, modifier = Modifier.fillMaxWidth())
                DateTimeField("Start", startInstant, zone) { startInstant = it }
                DateTimeField("End", endInstant, zone) { endInstant = it }
                Text("Times use ${zone.id}")
                ChoiceField("Tractor", tractorId, state.machines.filter { it.isLegacyTractor }.mapNotNull { it.legacyTractorId?.let { id -> Triple(id, it.displayName, id) } }, { tractorId = it })
                ChoiceField("Operator", operatorId, state.members.map { Triple(it.userId, it.name, it.userId) }, { operatorId = it })
                ChoiceField("Spray unit", unitId, state.sprayEquipment.map { Triple(it.id, it.name, it.id) }, { unitId = it })
                OutlinedTextField(startHours, { startHours = it }, label = { Text("Start engine hours (optional)") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(endHours, { endHours = it }, label = { Text("End engine hours (optional)") }, modifier = Modifier.fillMaxWidth())
                Text("Blocks")
                state.paddocks.forEach { block -> Row { Checkbox(block.id in blockIds, { checked -> if (checked) blockIds.add(block.id) else blockIds.remove(block.id) }); Text(block.name) } }
                tanks.toList().forEachIndexed { index, tank ->
                    Text("Tank ${tank.tankNumber}")
                    OutlinedTextField(waterInputs[tank.id].orEmpty(), { value -> waterInputs[tank.id] = value }, label = { Text("Actual water (L)") }, modifier = Modifier.fillMaxWidth())
                    tank.chemicals.forEachIndexed { chemicalIndex, chemical ->
                        Text("${chemical.name} · ${chemical.productCategory} · ${chemical.physicalForm.name}")
                        OutlinedTextField(chemicalInputs[chemical.id].orEmpty(), { value -> chemicalInputs[chemical.id] = value }, label = { Text("Actual amount (${chemical.unit})") }, modifier = Modifier.fillMaxWidth())
                    }
                    ChemicalChoice(state.savedChemicals) { product -> tanks[index] = tanks[index].copy(chemicals = tanks[index].chemicals + product.toManualChemical()) }
                    if (tanks.size > 1) TextButton(onClick = { tanks.removeAt(index); tanks.indices.forEach { i -> tanks[i] = tanks[i].copy(tankNumber = i + 1) } }) { Text("Remove tank") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Button(onClick = { tanks += ManualSprayTank(tankNumber = tanks.size + 1, waterVolumeLitres = 0.0, chemicals = emptyList()) }) { Text("Add tank") }; Button(onClick = { tanks.lastOrNull()?.let { tanks += it.copied(tanks.size + 1) } }) { Text("Copy previous") } }
                OutlinedTextField(notes, { notes = it }, label = { Text("Notes (optional)") }, modifier = Modifier.fillMaxWidth())
                Row { Checkbox(hasManualWeather, { weatherEdited = true; hasManualWeather = it }); Text("Enter weather manually") }
                if (hasManualWeather) {
                    WeatherField("Temperature °C", temperature) { weatherEdited = true; temperature = it }; WeatherField("Humidity %", humidity) { weatherEdited = true; humidity = it }
                    WeatherField("Wind km/h", wind) { weatherEdited = true; wind = it }; WeatherField("Gust km/h", gust) { weatherEdited = true; gust = it }
                    WeatherField("Direction °", direction) { weatherEdited = true; direction = it }; WeatherField("Rain mm", rain) { weatherEdited = true; rain = it }
                }
                Text("Manual weather is optional and remains authoritative. Station availability never blocks saving.")
            } else {
                Text("Completed · Manual entry")
                Text("$reference\n${formatLocal(startInstant, zone)} — ${formatLocal(endInstant, zone)}\n${blockIds.size} blocks · ${tanks.size} tanks · ${tanks.sumOf { it.waterVolumeLitres }} L")
                savedTripId?.let { tripId ->
                    Button(onClick = { scope.launch {
                        val result = runCatching { SprayReportRepository(session).recoverWeather(tripId, endInstant) }.getOrNull()
                        message = when { result == null -> "Station weather could not be retrieved. The spray remains saved."; result.captured > 0 -> "Captured ${result.captured} historical station observation(s)."; result.pending > 0 -> "Station weather is pending or not configured. The spray remains saved."; else -> "Historical station weather was unavailable. The spray remains saved." }
                        runCatching { SprayReportRepository(session).fetch(tripId) }
                    } }) { Text("Retrieve historical station weather") }
                }
            }
            message?.let { Text(it) }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = if (isReviewing && savedTripId == null) ({ isReviewing = false }) else onDismiss) { Text(if (isReviewing && savedTripId == null) "Back" else "Cancel") }
                if (savedTripId == null) Button(enabled = !isSaving, onClick = {
                    val candidate = payload(); val error = candidate.validationError()
                    if (error != null) message = error else if (!isReviewing) isReviewing = true else scope.launch {
                        isSaving = true
                        try {
                            val response = vm.saveManualSpray(candidate, expectedVersion)
                            if (response?.serverConfirmed == true) { expectedVersion = response.syncVersion; savedTripId = response.tripId; draftStore.clear(vineyardId); message = "Manual spray saved. Historical station weather is optional." }
                            else message = "Saved on this device — awaiting sync"
                        } catch (error: Exception) {
                            message = error.message ?: "The manual spray could not be saved."
                        } finally {
                            isSaving = false
                        }
                    }
                }) { Text(if (isReviewing) "Save manual spray" else "Review") }
                else Button(onClick = onSaved) { Text("Done") }
            }
        }
    }
}

internal fun SprayRecord.toManualPayload(trip: Trip?, state: AppUiState, zone: ZoneId): ManualSprayPayload? {
    val manualId = manualEntryId ?: return null
    val actuals = state.sprayTankActuals.filter { it.sprayRecordId == id && it.tripId == tripId }.sortedBy { it.tankNumber }
    if (trip == null || actuals.isEmpty()) return null
    return ManualSprayPayload(
        vineyardId = vineyardId, manualEntryId = manualId, sprayRecordId = id, tripId = trip.id,
        reference = sprayReference.orEmpty(), operationType = operationType ?: "Foliar Spray", startUtc = trip.startTime ?: startTime ?: date ?: return null,
        endUtc = trip.endTime ?: endTime ?: return null, vineyardTimeZone = zone.id, tractorId = trip.tractorId, operatorUserId = trip.operatorUserId,
        sprayEquipmentId = sprayEquipmentId, startEngineHours = trip.startEngineHours, endEngineHours = trip.endEngineHours, notes = notes,
        blocks = applicationBlocks.orEmpty().map { ManualSprayBlock(it.blockId, it.blockName ?: state.paddocks.firstOrNull { p -> p.id == it.blockId }?.name.orEmpty()) },
        tanks = actuals.map { actual -> ManualSprayTank(actual.tankSessionId, actual.id, actual.tankNumber, actual.waterVolumeL ?: 0.0, actual.chemicals.map { line -> ManualSprayChemical(line.id, line.savedChemicalId ?: "", line.name, line.actualAmountBase, line.unit, line.productCategory.orEmpty(), ManualSprayPhysicalForm.entries.firstOrNull { it.name == line.physicalForm } ?: if (line.unit in setOf("Kg", "g")) ManualSprayPhysicalForm.solid else ManualSprayPhysicalForm.liquid, line.snapshotAt ?: "") }) },
    )
}

@Composable private fun DateTimeField(label: String, instant: Instant, zone: ZoneId, onChange: (Instant) -> Unit) {
    val context = LocalContext.current
    Button(onClick = {
        val current = LocalDateTime.ofInstant(instant, zone)
        DatePickerDialog(context, { _, year, month, day ->
            TimePickerDialog(context, { _, hour, minute -> onChange(LocalDateTime.of(year, month + 1, day, hour, minute).atZone(zone).toInstant()) }, current.hour, current.minute, true).show()
        }, current.year, current.monthValue - 1, current.dayOfMonth).show()
    }, modifier = Modifier.fillMaxWidth()) { Text("$label: ${formatLocal(instant, zone)}") }
}
private fun formatLocal(instant: Instant, zone: ZoneId): String = DateTimeFormatter.ofPattern("dd MMM yyyy, HH:mm").format(LocalDateTime.ofInstant(instant, zone))
@Composable private fun WeatherField(label: String, value: String, onChange: (String) -> Unit) { OutlinedTextField(value, onChange, label = { Text(label) }, modifier = Modifier.fillMaxWidth()) }

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun ChoiceField(label: String, selected: String?, choices: List<Triple<String, String, String>>, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded, { expanded = !expanded }) { OutlinedTextField(choices.firstOrNull { it.first == selected }?.second.orEmpty(), {}, readOnly = true, label = { Text(label) }, trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) }, modifier = Modifier.menuAnchor().fillMaxWidth()); ExposedDropdownMenu(expanded, { expanded = false }) { choices.forEach { choice -> DropdownMenuItem({ Text(choice.second) }, { onSelect(choice.first); expanded = false }) } } }
}
@Composable private fun ChemicalChoice(products: List<SavedChemical>, onSelect: (SavedChemical) -> Unit) { var expanded by remember { mutableStateOf(false) }; TextButton(onClick = { expanded = true }) { Text("Add chemical from store") }; DropdownMenu(expanded, { expanded = false }) { products.forEach { product -> DropdownMenuItem({ Text(product.name) }, { onSelect(product); expanded = false }) } } }
private fun SavedChemical.toManualChemical(): ManualSprayChemical { val form = if (productForm.lowercase() == "solid" || unit in setOf("Kg", "g")) ManualSprayPhysicalForm.solid else ManualSprayPhysicalForm.liquid; return ManualSprayChemical(savedChemicalId = id, name = name, actualAmountBase = 0.0, unit = unit, productCategory = productCategory.ifBlank { use }, physicalForm = form) }
private fun toBase(value: Double, unit: String): Double = if (unit == "Litres" || unit == "Kg") value * 1000.0 else value
private fun displayAmount(chemical: ManualSprayChemical): Double = if (chemical.unit == "Litres" || chemical.unit == "Kg") chemical.actualAmountBase / 1000.0 else chemical.actualAmountBase
