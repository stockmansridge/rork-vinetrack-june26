package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
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

/** Pilot access depends on System Admin, never vineyard Owner/Manager role. */
@Composable
internal fun ChemicalInventoryScreen(state: AppUiState, onClose: () -> Unit, modifier: Modifier = Modifier) {
    if (!CatalogueTerminalResolver.inventoryAllowed(state.isSystemAdmin)) return
    val context = LocalContext.current
    val repository = remember { CatalogueRepository(context) }
    val scope = rememberCoroutineScope()
    var summaries by remember { mutableStateOf<Map<String, CatalogueRow>>(emptyMap()) }
    var selected by remember { mutableStateOf<SavedChemical?>(null) }
    var search by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf("All") }
    var error by remember { mutableStateOf<String?>(null) }
    suspend fun refresh(id: String) {
        try { val row = repository.rows(repository.rpc("chemical_inventory_summary", buildJsonObject { put("p_saved_chemical_id", id) })).single(); summaries = summaries + (id to row) }
        catch (_: Exception) { error = "Unable to load inventory. Check access and try again." }
    }
    LaunchedEffect(state.selectedVineyardId) { summaries = emptyMap(); state.savedChemicals.forEach { refresh(it.id) } }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Chemical Inventory", style = MaterialTheme.typography.headlineSmall)
        TextButton(onClick = onClose) { Text("Close") }
        Text("Tracked chemicals: ${summaries.values.count { it.bool("tracked") }}")
        Text("Low stock: ${summaries.values.count { it.bool("low_stock") }} · Out of stock: ${summaries.values.count { it.bool("out_of_stock") }}")
        val stockValues = summaries.values.mapNotNull { row -> row.number("estimated_stock_value")?.let { (row.text("currency") ?: "") to it } }
        if (stockValues.isEmpty()) Text("Estimated stock value: —")
        else stockValues.groupBy { it.first }.forEach { (currency, values) -> Text("Estimated stock value: ${values.sumOf { it.second }} $currency") }
        OutlinedTextField(search, { search = it }, label = { Text("Chemical name or manufacturer") })
        Row(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            TextButton(onClick = { filter = if (filter == "All") "In stock" else "All" }) { Text(filter) }
        }
        listOf("All", "In stock", "Low stock", "Out of stock", "Opening stock not set").forEach { option ->
            FilterChip(selected = filter == option, onClick = { filter = option }, label = { Text(option) })
        }
        state.savedChemicals.filter { (search.isBlank() || "${it.name} ${it.manufacturer}".contains(search, true)) &&
            (filter == "All" || summaries[it.id]?.inventoryStatus == filter) }.forEach { chemical ->
            OutlinedCard(onClick = { selected = chemical }, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    CatalogueSavedChemical(chemical)
                    summaries[chemical.id]?.let { summary ->
                        Text(summary.inventoryStatus)
                        if (summary.inventoryStatus != "Opening stock not set") {
                            Text("${summary.number("current_quantity")?.toString() ?: "—"} ${summary.text("display_unit").orEmpty()}")
                            summary.number("percent_remaining")?.let { percent -> LinearProgressIndicator(progress = { (percent / 100).toFloat() }); Text("${percent.toInt()}%") }
                        }
                        Text("Estimated stock value: ${summary.number("estimated_stock_value")?.toString() ?: "—"} ${summary.text("currency").orEmpty()}")
                        Text("Latest purchase: ${summary.text("latest_purchase_date") ?: "—"} · Batch: ${summary.text("latest_batch_number") ?: "—"}")
                    }
                }
            }
        }
        error?.let { Text(it) }
    }
    selected?.let { chemical -> InventoryActions(chemical, summaries[chemical.id], onDismiss = { selected = null }, onMutation = { scope.launch { refresh(chemical.id) } }) }
}

@Composable
private fun InventoryActions(chemical: SavedChemical, summary: CatalogueRow?, onDismiss: () -> Unit, onMutation: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val repository = remember { CatalogueRepository(context) }
    val scope = rememberCoroutineScope()
    var action by remember { mutableStateOf("Set / adjust stock") }
    var quantity by remember { mutableStateOf("") }
    var unit by remember { mutableStateOf("L") }
    var cost by remember { mutableStateOf("") }
    var currency by remember { mutableStateOf("AUD") }
    var batch by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }
    var date by remember { mutableStateOf(LocalDate.now().toString()) }
    var warnings by remember { mutableStateOf(true) }
    var history by remember { mutableStateOf<List<CatalogueRow>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(modifier = modifier, onDismissRequest = onDismiss, title = { Text(chemical.name) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("Record purchase", "Set / adjust stock", "Mark finished", "Low-stock settings", "Purchase history").forEach { option -> TextButton(onClick = { action = option }) { Text(option) } }
            Text(action)
            if (action == "Purchase history") {
                TextButton(onClick = { scope.launch { try { history = repository.rows(repository.rpc("chemical_inventory_purchase_history", buildJsonObject { put("p_saved_chemical_id", chemical.id) })) } catch (_: Exception) { error = "Unable to load history." } } }) { Text("Load history") }
                history.forEach { Text("${it.text("purchase_date")} · ${it.number("quantity")} ${it.text("unit")} · ${it.number("total_cost")} ${it.text("currency")} · ${it.text("batch_number").orEmpty()}") }
            } else {
                if (action != "Mark finished") {
                    OutlinedTextField(quantity, { quantity = it }, label = { Text(if (action == "Low-stock settings") "Low stock percent" else "Quantity") })
                    if (action != "Low-stock settings") Row { listOf("L", "mL", "kg", "g").forEach { value -> TextButton(onClick = { unit = value }) { Text(value) } } }
                }
                if (action == "Record purchase") {
                    OutlinedTextField(cost, { cost = it }, label = { Text("Total cost") })
                    OutlinedTextField(currency, { currency = it }, label = { Text("Currency") })
                    OutlinedTextField(date, { date = it }, label = { Text("Purchase date YYYY-MM-DD") })
                    OutlinedTextField(batch, { batch = it }, label = { Text("Batch") })
                }
                if (action == "Low-stock settings") Row { Checkbox(warnings, { warnings = it }); Text("Low-stock warnings") }
                OutlinedTextField(notes, { notes = it }, label = { Text("Notes") })
            }
            error?.let { Text(it) }
        }
    }, confirmButton = {
        TextButton(enabled = !busy && action != "Purchase history", onClick = {
            val value = quantity.toDoubleOrNull()
            val total = cost.toDoubleOrNull()
            if (action != "Mark finished" && (value == null || !value.isFinite() || value < 0 || (action == "Low-stock settings" && value > 100))) { error = "Enter a valid quantity or percent."; return@TextButton }
            if (action == "Record purchase" && (total == null || !total.isFinite() || total < 0 || value!! <= 0 || runCatching { LocalDate.parse(date) }.isFailure)) { error = "Enter a valid purchase quantity, cost and date."; return@TextButton }
            val name = when (action) { "Record purchase" -> "chemical_inventory_record_purchase"; "Set / adjust stock" -> "chemical_inventory_record_stocktake"; "Low-stock settings" -> "chemical_inventory_set_settings"; else -> "chemical_inventory_mark_finished" }
            val args = buildJsonObject {
                put("p_saved_chemical_id", chemical.id)
                if (action == "Low-stock settings") { put("p_low_stock_percent", value!!); put("p_warnings_enabled", warnings) }
                else {
                    put("p_notes", notes)
                    if (action != "Mark finished") { put("p_quantity", value!!); put("p_unit", unit) }
                    if (action == "Record purchase") { put("p_total_cost", total!!); put("p_currency", currency.uppercase()); put("p_batch_number", batch); put("p_purchase_date", date) }
                    if (action == "Set / adjust stock") put("p_reason", if (summary?.text("tracking_status") == "needs_opening_stock") "opening_stock" else "correction")
                }
            }
            scope.launch { busy = true; try {
                CatalogueInventoryMutation.perform(systemAdmin = true, operation = name, chemicalId = chemical.id,
                    mutate = { repository.rpc(name, args); Unit }, refresh = { onMutation() })
                onDismiss()
            }
                catch (_: Exception) { error = "Inventory was not confirmed. Check access; verify history before repeating an uncertain purchase." }
                finally { busy = false } }
        }) { Text("Save") }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } })
}
