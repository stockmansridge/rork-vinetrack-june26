package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*
import java.time.LocalDate
import android.app.DatePickerDialog

/** Inventory access follows selected-vineyard Owner/Manager membership. */
@Composable
internal fun ChemicalInventoryScreen(state: AppUiState, onClose: () -> Unit, modifier: Modifier = Modifier, recordPurchase: Boolean = false) {
    if (!state.canManageInventory) return
    val context = LocalContext.current
    val repository = remember { CatalogueRepository(context) }
    val overviewScope = rememberCoroutineScope()
    var loading by remember { mutableStateOf(false) }
    var summaries by remember { mutableStateOf<Map<String, CatalogueRow>>(emptyMap()) }
    var selected by remember { mutableStateOf<SavedChemical?>(null) }
    var search by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf("All") }
    var error by remember { mutableStateOf<String?>(null) }
    suspend fun refresh(id: String) {
        try { val row = repository.rows(repository.rpc("chemical_inventory_summary", buildJsonObject { put("p_saved_chemical_id", id) })).single(); summaries = summaries + (id to row) }
        catch (_: Exception) { error = "Unable to load inventory. Check access and try again." }
    }
    suspend fun loadSummaries() {
        loading = true; error = null
        try { state.savedChemicals.forEach { refresh(it.id) } } finally { loading = false }
    }
    LaunchedEffect(state.selectedVineyardId, state.savedChemicals.map { it.id }) { summaries = emptyMap(); loadSummaries() }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (recordPurchase) "Chemical Purchase" else "Chemical Inventory", style = MaterialTheme.typography.headlineSmall)
        if (recordPurchase) Text("Select a chemical to record a purchase.")
        TextButton(onClick = onClose) { Text("Close") }
        if (!recordPurchase) {
            Text("Tracked chemicals: ${summaries.values.count { it.bool("tracked") }}")
            Text("Low stock: ${summaries.values.count { it.bool("low_stock") }} · Out of stock: ${summaries.values.count { it.bool("out_of_stock") }}")
            val stockValues = summaries.values.mapNotNull { row -> row.number("estimated_stock_value")?.let { (row.text("currency") ?: "") to it } }
            if (stockValues.isEmpty()) Text("Estimated stock value: —")
            else stockValues.groupBy { it.first }.forEach { (currency, values) -> Text("Estimated stock value: ${values.sumOf { it.second }} $currency") }
        }
        OutlinedTextField(search, { search = it }, label = { Text("Chemical name or manufacturer") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("All", "In stock", "Low stock", "Out of stock", "Opening stock not set").forEach { option ->
                FilterChip(selected = filter == option, onClick = { filter = option }, label = { Text(option) })
            }
        }
        if (state.savedChemicals.isEmpty()) Text("No saved chemicals yet. Add a chemical to your vineyard to get started.")
        state.savedChemicals.filter { (search.isBlank() || "${it.name} ${it.manufacturer}".contains(search, true)) &&
            (filter == "All" || summaries[it.id]?.inventoryStatus == filter) }.forEach { chemical ->
            OutlinedCard(onClick = { selected = chemical }, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    CatalogueSavedChemical(chemical)
                    summaries[chemical.id]?.let { summary ->
                        Text(summary.inventoryStatus)
                        if (summary.inventoryStatus != "Opening stock not set") {
                            Text("${summary.number("current_quantity")?.toString() ?: "—"} ${summary.text("display_unit").orEmpty()}")
                            summary.number("percent_remaining")?.let { percent -> LinearProgressIndicator(progress = { (percent / 100).toFloat() }, modifier = Modifier.fillMaxWidth()); Text("${percent.toInt()}%") }
                        }
                        Text("Estimated stock value: ${summary.number("estimated_stock_value")?.toString() ?: "—"} ${summary.text("currency").orEmpty()}")
                        ChemicalInventoryTraceability.display(summary, latest = true).forEach { Text(it) }
                        Text("Latest purchase: ${summary.text("latest_purchase_date") ?: "—"}")
                    }
                }
            }
        }
        if (loading) CircularProgressIndicator()
        error?.let { message ->
            Text(message, color = MaterialTheme.colorScheme.error)
            TextButton(onClick = { overviewScope.launch { loadSummaries() } }) { Text("Retry") }
        }
    }
    selected?.let { chemical -> InventoryActions(chemical, summaries[chemical.id], canManageInventory = state.canManageInventory && chemical.vineyardId == state.selectedVineyardId, onDismiss = { selected = null }, onMutation = { refresh(chemical.id) }, recordPurchase = recordPurchase) }
}

@Composable
private fun InventoryActions(chemical: SavedChemical, summary: CatalogueRow?, canManageInventory: Boolean, onDismiss: () -> Unit, onMutation: suspend () -> Unit, modifier: Modifier = Modifier, recordPurchase: Boolean = false) {
    val context = LocalContext.current
    val repository = remember { CatalogueRepository(context) }
    val scope = rememberCoroutineScope()
    val opening = summary?.text("tracking_status") == "needs_opening_stock"
    val stockAction = if (opening) "Set Opening Stock" else "Stocktake / Adjust"
    var action by remember { mutableStateOf(if (recordPurchase) "Record purchase" else stockAction) }
    var quantity by remember { mutableStateOf(if (opening) "" else summary?.number("current_quantity")?.let(CatalogueInventoryContainer::number).orEmpty()) }
    var physicalEdited by remember { mutableStateOf(false) }
    var lowStockPercent by remember { mutableStateOf(summary?.number("low_stock_percent")?.let(CatalogueInventoryContainer::number).orEmpty()) }
    val knownUnits = remember(chemical) { CatalogueInventoryContainer.units(chemical.productForm, chemical.packUnit) }
    var family by remember { mutableStateOf(if (knownUnits.firstOrNull() == "kg") "solid" else "liquid") }
    val preferredUnit = if (opening) chemical.packUnit else summary?.text("display_unit") ?: chemical.packUnit
    var unit by remember { mutableStateOf(preferredUnit.takeIf { it in knownUnits } ?: knownUnits.firstOrNull() ?: "L") }
    var containerCount by remember { mutableStateOf("1") }
    var containerSize by remember { mutableStateOf(chemical.packSize?.takeIf { it.isFinite() && it > 0 }?.let(CatalogueInventoryContainer::number).orEmpty()) }
    var supplier by remember { mutableStateOf("") }
    var invoice by remember { mutableStateOf("") }
    var expiry by remember { mutableStateOf("") }
    var cost by remember { mutableStateOf("") }
    var currency by remember { mutableStateOf("AUD") }
    var batch by remember { mutableStateOf("") }
    var batchDate by remember { mutableStateOf<String?>(null) }
    var serialNumber by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }
    var date by remember { mutableStateOf(LocalDate.now().toString()) }
    var warnings by remember { mutableStateOf(if (summary?.fields?.containsKey("warnings_enabled") == true) summary.bool("warnings_enabled") else true) }
    var history by remember { mutableStateOf<List<CatalogueRow>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    suspend fun loadHistory() {
        if (!canManageInventory) return
        try { history = repository.rows(repository.rpc(CatalogueInventoryMutation.HISTORY, buildJsonObject { put("p_saved_chemical_id", chemical.id) })) }
        catch (_: Exception) { error = "Unable to load purchase history." }
    }
    LaunchedEffect(containerCount, containerSize) {
        if (opening) quantity = CatalogueInventoryContainer.openingQuantity(containerCount, containerSize, quantity, physicalEdited)
    }
    LaunchedEffect(action) { if (action == "Purchase history") loadHistory() }
    fun chooseDate(value: String, onSelected: (String) -> Unit) {
        val initial = runCatching { LocalDate.parse(value) }.getOrElse { LocalDate.now() }
        DatePickerDialog(context, { _, year, month, day ->
            onSelected(LocalDate.of(year, month + 1, day).toString())
        }, initial.year, initial.monthValue - 1, initial.dayOfMonth).show()
    }
    AlertDialog(modifier = modifier, onDismissRequest = { if (!busy) onDismiss() }, title = { Text(chemical.name) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            var choosingAction by remember { mutableStateOf(false) }
            Box {
                OutlinedButton(enabled = !busy, onClick = { choosingAction = true }, modifier = Modifier.fillMaxWidth()) { Text(action) }
                DropdownMenu(expanded = choosingAction, onDismissRequest = { choosingAction = false }) {
                    listOf("Record purchase", stockAction, "Mark finished", "Low-stock settings", "Purchase history").forEach { option ->
                        DropdownMenuItem(text = { Text(option) }, onClick = { action = option; choosingAction = false; error = null })
                    }
                }
            }
            summary?.let { row ->
                Text(row.inventoryStatus)
                if (row.inventoryStatus != "Opening stock not set") Text("${row.number("current_quantity") ?: "—"} ${row.text("display_unit").orEmpty()}")
                Text("Last stocktake: ${row.text("last_stocktake_at") ?: "—"}")
                Text("Used since stocktake: ${row.number("used_since_stocktake") ?: "—"}")
                Text("Low-stock threshold: ${row.number("low_stock_threshold_quantity") ?: "—"} ${row.text("display_unit").orEmpty()}")
            }
            if (action == "Purchase history") {
                if (history.isEmpty() && error == null) Text("No purchases recorded.", style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = { scope.launch { loadHistory() } }) { Text("Load history") }
                history.forEach { row ->
                    Text("${row.text("purchase_date").orEmpty()} · ${CatalogueInventoryContainer.historyText(row)}")
                    Text("${row.number("total_cost") ?: "—"} ${row.text("currency").orEmpty()}")
                    ChemicalInventoryTraceability.display(row).forEach { Text(it) }
                    row.number("unit_cost")?.let { Text("Unit cost: $it ${row.text("currency").orEmpty()}") }
                    Text(listOfNotNull(row.text("supplier"), row.text("invoice_reference")).filter { it.isNotBlank() }.joinToString(" · "))
                    HorizontalDivider()
                }
            } else {
                if (action == "Low-stock settings") OutlinedTextField(lowStockPercent, { lowStockPercent = it }, label = { Text("Low stock percent (0–100)") })
                if (action == "Record purchase") {
                    OutlinedButton(enabled = !busy, onClick = { chooseDate(date) { date = it } }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text("Purchase date: $date") }
                }
                if (action == "Record purchase" || action == stockAction) {
                    if (knownUnits.isEmpty()) Row {
                        listOf("liquid", "solid").forEach { value -> FilterChip(selected = family == value, onClick = { family = value; unit = if (value == "solid") "kg" else "L" }, label = { Text(value) }) }
                    }
                    if (action == "Record purchase" || opening) {
                        OutlinedTextField(containerCount, { containerCount = it }, label = { Text("Number of containers") })
                        OutlinedTextField(containerSize, { containerSize = it }, label = { Text("Container size") })
                    }
                    Row { CatalogueInventoryContainer.units(family, "").forEach { value -> FilterChip(selected = unit == value, onClick = { unit = value }, label = { Text(value) }) } }
                    val count = containerCount.toDoubleOrNull(); val size = containerSize.toDoubleOrNull()
                    if ((action == "Record purchase" || opening) && count != null && size != null && CatalogueInventoryContainer.valid(count, size)) Text(CatalogueInventoryContainer.preview(count, size, unit))
                    if (action == stockAction) {
                        OutlinedTextField(quantity, { quantity = it; physicalEdited = true }, label = { Text("Current physical quantity ($unit)") })
                        Text("Container capacity and physically remaining stock are recorded separately. Remaining percentage is supplied by the backend.")
                    }
                }
                if (action == "Record purchase") {
                    OutlinedTextField(cost, { cost = it }, label = { Text("Total cost") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(currency, { currency = it }, label = { Text("Currency") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(batch, { batch = it }, label = { Text("Batch / Lot number") })
                    OutlinedButton(enabled = !busy, onClick = { chooseDate(batchDate.orEmpty()) { batchDate = it } }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text("Production / Batch date: ${batchDate ?: "Not set"}") }
                    if (batchDate != null) TextButton(enabled = !busy, onClick = { batchDate = null }) { Text("Clear Production / Batch date") }
                    OutlinedTextField(serialNumber, { serialNumber = it }, label = { Text("Serial number (if applicable)") })
                    OutlinedTextField(supplier, { supplier = it }, label = { Text("Supplier") })
                    OutlinedTextField(invoice, { invoice = it }, label = { Text("Invoice / reference") })
                    OutlinedButton(enabled = !busy, onClick = { chooseDate(expiry) { expiry = it } }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text("Expiry date: ${expiry.ifBlank { "Not set (optional)" }}") }
                    if (expiry.isNotBlank()) TextButton(enabled = !busy, onClick = { expiry = "" }) { Text("Clear expiry date") }
                }
                if (action == "Low-stock settings") Row { Checkbox(warnings, { warnings = it }); Text("Low-stock warnings") }
                OutlinedTextField(notes, { notes = it }, label = { Text("Notes") })
            }
            error?.let { Text(it) }
        }
    }, confirmButton = {
        TextButton(enabled = canManageInventory && !busy && action != "Purchase history", onClick = {
            if (!canManageInventory) return@TextButton
            val value = (if (action == "Low-stock settings") lowStockPercent else quantity).toDoubleOrNull()
            val total = cost.toDoubleOrNull()
            val count = containerCount.toDoubleOrNull(); val size = containerSize.toDoubleOrNull()
            val containerAction = action == "Record purchase" || (action == stockAction && opening)
            if (containerAction && (count == null || size == null || !CatalogueInventoryContainer.valid(count, size))) { error = "Enter a positive whole container count and positive size."; return@TextButton }
            if ((action == stockAction || action == "Low-stock settings") && (value == null || !value.isFinite() || value < 0 || (action == "Low-stock settings" && value > 100))) { error = "Enter a valid quantity or percent."; return@TextButton }
            if (action == "Record purchase" && (total == null || !total.isFinite() || total < 0 || runCatching { LocalDate.parse(date) }.isFailure || (expiry.isNotBlank() && runCatching { LocalDate.parse(expiry) }.isFailure))) { error = "Enter a valid purchase quantity, cost and date."; return@TextButton }
            val name = when (action) { "Record purchase" -> CatalogueInventoryMutation.PURCHASE; stockAction -> CatalogueInventoryMutation.STOCKTAKE; "Low-stock settings" -> "chemical_inventory_set_settings"; else -> "chemical_inventory_mark_finished" }
            val args = buildJsonObject {
                put("p_saved_chemical_id", chemical.id)
                if (action == "Low-stock settings") { put("p_low_stock_percent", value!!); put("p_warnings_enabled", warnings) }
                else {
                    put("p_notes", ChemicalInventoryTraceability.nullableText(notes))
                    if (containerAction) CatalogueInventoryContainer.fields(count!!, size!!, unit).forEach { (key, field) -> put(key, field) }
                    if (action == "Record purchase") {
                        put("p_total_cost", total!!); put("p_currency", currency.trim().uppercase()); ChemicalInventoryTraceability.fields(batch, batchDate, serialNumber).forEach { (key, field) -> put(key, field) }; put("p_purchase_date", date)
                        put("p_supplier", ChemicalInventoryTraceability.nullableText(supplier))
                        put("p_invoice_reference", ChemicalInventoryTraceability.nullableText(invoice))
                        put("p_expiry_date", expiry.takeIf { it.isNotBlank() }?.let(::JsonPrimitive) ?: JsonNull)
                    }
                    if (action == stockAction) {
                        CatalogueInventoryContainer.stockFields(value!!, unit).forEach { (key, field) -> put(key, field) }
                        put("p_reason", if (summary?.text("tracking_status") == "needs_opening_stock") "opening_stock" else "correction")
                        put("p_effective_at", java.time.Instant.now().toString())
                    }
                }
            }
            scope.launch { busy = true; try {
                CatalogueInventoryMutation.perform(canManageInventory = canManageInventory, operation = name, chemicalId = chemical.id,
                    mutate = { repository.rpc(name, args); Unit }, refresh = { onMutation() })
                if (name == CatalogueInventoryMutation.PURCHASE) loadHistory()
                onDismiss()
            }
                catch (_: Exception) { error = "Inventory was not confirmed. Check access; verify history before repeating an uncertain purchase." }
                finally { busy = false } }
        }) { Text("Save") }
    }, dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Close") } })
}
