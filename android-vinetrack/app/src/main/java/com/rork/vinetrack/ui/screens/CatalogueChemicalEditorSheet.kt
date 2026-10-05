package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.rememberGuardedSheetState

/** Catalogue chemistry is immutable here; saving sends operator notes only. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CatalogueChemicalEditorSheet(vm: AppViewModel, chemical: SavedChemical, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    val state by vm.ui.collectAsStateWithLifecycle()
    var inventoryAction by remember { mutableStateOf<Boolean?>(null) }
    var notes by remember(chemical.id) { mutableStateOf(chemical.notes) }
    var isSaving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(onDismissRequest = { if (!isSaving) onDismiss() }, sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)) {
        Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Chemical details", style = MaterialTheme.typography.titleLarge)
            CatalogueSavedChemical(chemical, showsDetails = true)
            VineyardPreferredRateEditor(vm, chemical)
            OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Vineyard notes (optional)") }, minLines = 3, enabled = !isSaving, modifier = Modifier.fillMaxWidth())
            Text("Inventory & purchase", style = MaterialTheme.typography.titleMedium)
            Text("Stock and purchases are managed in Chemical Inventory.", style = MaterialTheme.typography.bodySmall)
            if (state.canViewInventory && chemical.vineyardId == state.selectedVineyardId) {
                TextButton(onClick = { inventoryAction = false }) { Text("View Inventory") }
                if (state.canRecordInventoryPurchase) TextButton(onClick = { inventoryAction = true }) { Text("Record Purchase") }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onDismiss, enabled = !isSaving, modifier = Modifier.weight(1f)) { Text("Cancel") }
                Button(onClick = {
                    isSaving = true
                    error = null
                    vm.updateSavedChemicalNotes(chemical, notes) { ok ->
                        isSaving = false
                        if (ok) onDismiss() else error = "Couldn't save notes. Check your connection and try again."
                    }
                }, enabled = !isSaving, modifier = Modifier.weight(1f)) { Text(if (isSaving) "Saving…" else "Save") }
            }
        }
    }
    inventoryAction?.let { purchaseMode ->
        androidx.compose.ui.window.Dialog(onDismissRequest = { inventoryAction = null }, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(Modifier.fillMaxSize()) {
                ChemicalInventoryScreen(state, onClose = { inventoryAction = null }, recordPurchase = purchaseMode, initialChemicalId = chemical.id)
            }
        }
    }
}
