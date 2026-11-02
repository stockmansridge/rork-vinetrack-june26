package com.rork.vinetrack.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.ChemicalRemovalGuard
import com.rork.vinetrack.data.model.SavedChemical

/** Shared production confirmation; frozen record, archive default, deliberate second delete step. */
@Composable
fun ChemicalRemovalConfirmation(chemical: SavedChemical, inUse: Boolean, onCancel: () -> Unit, onConfirm: (ChemicalRemovalGuard.Action) -> Unit) {
    var permanent by remember(chemical.id) { mutableStateOf(false) }
    var typedName by remember(chemical.id) { mutableStateOf("") }
    val archived = !chemical.isActive || chemical.deletedAt != null
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(if (archived) "Reactivate chemical?" else if (permanent) "Delete Permanently?" else "Archive chemical?") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(chemical.displayName, style = MaterialTheme.typography.titleMedium)
            Text("Chemical ID: ${chemical.id}", style = MaterialTheme.typography.bodySmall)
            Text(if (archived) "Return this existing chemical to active lists. Historical records are not changed."
                else if (permanent) "This cannot be undone. The server must confirm this chemical is unused. Type the exact product name to continue."
                else "Hide this chemical from active lists, keeping its identity and historical records. You can reactivate it from Archived chemicals.")
            if (permanent) OutlinedTextField(value = typedName, onValueChange = { typedName = it }, label = { Text("Product name") }, modifier = Modifier.fillMaxWidth())
        } },
        confirmButton = { Column {
            Button(enabled = !permanent || typedName == chemical.displayName, onClick = {
                onConfirm(if (archived) ChemicalRemovalGuard.Action.RESTORE else if (permanent) ChemicalRemovalGuard.Action.DELETE else ChemicalRemovalGuard.Action.ARCHIVE)
            }) { Text(if (archived) "Reactivate" else if (permanent) "Confirm permanent deletion" else "Archive") }
            if (!archived && !inUse && !permanent) TextButton(onClick = { permanent = true }) { Text("Delete Permanently…") }
        } },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

/** Busy blocks navigation; an uncertain request may be hidden, but its durable removal lock remains. */
@Composable
fun ChemicalRemovalProgress(state: ChemicalRemovalGuard.State, onCheck: () -> Unit, onDismiss: () -> Unit, onRetry: (() -> Unit)? = null) {
    var visible by remember(state.target, state.busy, state.message) { mutableStateOf(true) }
    var confirmRetry by remember(state.target, state.busy) { mutableStateOf(false) }
    var typedName by remember(state.target) { mutableStateOf("") }
    if (state.target == null && state.message == null || (!visible && !confirmRetry)) return
    val target = state.target
    val retrying = confirmRetry && target != null && onRetry != null
    AlertDialog(
        onDismissRequest = { if (retrying) confirmRetry = false else if (!state.busy) { if (target == null && !state.unreadable) onDismiss() else visible = false } },
        title = { Text(if (retrying) "Retry original ${target!!.action.name.lowercase(java.util.Locale.ROOT)}?" else if (state.busy) "Processing chemical…" else if (target != null || state.unreadable) "Chemical action not confirmed" else "Chemical action") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            state.target?.let { Text(it.name, style = MaterialTheme.typography.titleMedium); Text("Chemical ID: ${it.id}", style = MaterialTheme.typography.bodySmall) }
            if (retrying) {
                Text("Only this original chemical and action can be retried. We will check its current server state first. Other products cannot be affected.")
                if (target!!.action == ChemicalRemovalGuard.Action.DELETE) {
                    Text("Permanent deletion cannot be undone. Type the exact original product name again.")
                    OutlinedTextField(value = typedName, onValueChange = { typedName = it }, label = { Text("Original product name") })
                }
            } else {
                if (state.busy) CircularProgressIndicator()
                Text(state.message ?: "Checking original record…")
                if (target != null && !state.busy && onRetry != null) OutlinedButton(onClick = { typedName = ""; confirmRetry = true }) { Text("Retry original action…") }
            }
        } },
        dismissButton = {
            if (retrying) TextButton(onClick = { confirmRetry = false }) { Text("Cancel") }
            else if (!state.busy && (target != null || state.unreadable)) TextButton(onClick = { visible = false }) { Text("Continue other work") }
        },
        confirmButton = {
            if (retrying) TextButton(enabled = target!!.action != ChemicalRemovalGuard.Action.DELETE || typedName == target.name,
                onClick = { confirmRetry = false; onRetry?.invoke() }) { Text("Retry this original action") }
            else if (target != null) TextButton(enabled = !state.busy, onClick = onCheck) { Text(if (state.busy) "Please wait…" else "Check with server") }
            else if (!state.unreadable) TextButton(onClick = onDismiss) { Text("Done") }
        },
    )
}
