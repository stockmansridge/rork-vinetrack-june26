package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.data.chemical.VineyardPreferredRate
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.AppViewModel

/** Operational preference editor, independent of registered/default-rate decisions. */
@Composable
internal fun VineyardPreferredRateEditor(vm: AppViewModel, chemical: SavedChemical, modifier: Modifier = Modifier) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val context = androidx.compose.ui.platform.LocalContext.current
    var revision by remember(chemical.id) { mutableStateOf<com.rork.vinetrack.data.chemical.CatalogueRow?>(null) }
    LaunchedEffect(chemical.chemicalV3RevisionId) {
        val id = chemical.chemicalV3RevisionId ?: return@LaunchedEffect
        try { revision = com.rork.vinetrack.data.chemical.CatalogueRepository(context).revision(id) }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { revision = null }
    }
    val current = state.savedChemicals.firstOrNull { it.id == chemical.id } ?: chemical
    val vineyard = state.vineyards.firstOrNull { it.id == chemical.vineyardId }?.name ?: "Vineyard"
    var amount by remember(chemical.id) { mutableStateOf(chemical.vineyardPreferredRate?.amount?.toString().orEmpty()) }
    var unit by remember(chemical.id) { mutableStateOf(chemical.vineyardPreferredRate?.unit ?: "L") }
    var basis by remember(chemical.id) { mutableStateOf(chemical.vineyardPreferredRate?.basis ?: "per_hectare") }
    var note by remember(chemical.id) { mutableStateOf(chemical.vineyardPreferredRate?.note.orEmpty()) }
    var message by remember { mutableStateOf<String?>(null) }
    val draft = amount.replace(',', '.').toDoubleOrNull()?.let { VineyardPreferredRate(it, unit, basis, note.takeIf { n -> n.isNotBlank() }) }?.takeIf { it.isValid }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("$vineyard Preferred Rate", style = MaterialTheme.typography.titleMedium)
        Text(current.vineyardPreferredRate?.takeIf { it.isValid }?.text ?: "No preferred vineyard rate set")
        Text("Used as the first choice when planning sprays, unless the Program Step has its own rate. Vineyard-defined, not a registered label rate.", style = MaterialTheme.typography.bodySmall)
        if (state.canManageSprayProgram && state.selectedVineyardId == chemical.vineyardId) {
            OutlinedTextField(amount, { amount = it }, label = { Text("Amount") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) { listOf("L", "mL", "kg", "g").forEach { option -> FilterChip(unit == option, { unit = option }, label = { Text(option) }) } }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FilterChip(basis == "per_hectare", { basis = "per_hectare" }, label = { Text("Per hectare") })
                FilterChip(basis == "per_100_litres", { basis = "per_100_litres" }, label = { Text("Per 100 L") })
            }
            OutlinedTextField(note, { note = it }, label = { Text("Note (optional)") }, modifier = Modifier.fillMaxWidth())
            Button(onClick = { vm.setVineyardPreferredRate(current, draft) { ok -> message = if (ok) "Saved; queued for vineyard sync." else "Couldn't save preferred rate." } }, enabled = draft != null) { Text("Save preferred rate") }
            if (current.vineyardPreferredRate != null) TextButton(onClick = { vm.setVineyardPreferredRate(current, null) { ok -> if (ok) amount = ""; message = if (ok) "Preferred rate cleared; queued for sync." else "Couldn't clear rate." } }) { Text("Clear preferred rate") }
        }
        draft?.let { rate -> revision?.let { com.rork.vinetrack.data.chemical.OperationalRateResolver.warning(rate, it) } ?: com.rork.vinetrack.data.chemical.OperationalRateResolver.warning(rate, current) }?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}
