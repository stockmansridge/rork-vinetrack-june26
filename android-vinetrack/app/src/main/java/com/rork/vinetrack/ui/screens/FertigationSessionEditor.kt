package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.*
import com.rork.vinetrack.ui.AppUiState
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

@Composable
internal fun FertigationSessionEditor(repo: IrrigationRepository, session: IrrigationSessionRow, application: JsonObject?, state: AppUiState, onDone: () -> Unit, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val owner = remember(session.id) { state.currentUserId }
    var draft by remember(session.id) { mutableStateOf(FertigationSessionDraft.from(application)) }
    var steps by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var pending by remember { mutableStateOf<FertigationLinkedOutbox.Entry?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    val allowed = session.deletedAt == null && owner != null && owner == state.currentUserId && FertigationSessionDraft.canAttach(session.vineyardId, state.selectedVineyardId, session.status, state.isSystemAdmin) && (application == null || FertigationDomain.isEditable(application))
    val totals = remember(session) { FertigationDomain.Totals.from(session.blocks.map { FertigationDomain.Allocation(it.servicedAreaM2, it.servicedVineCount?.toDouble()) }) }
    LaunchedEffect(owner, session.id) {
        if (!allowed) return@LaunchedEffect
        pending = repo.fertigationOutbox.entries().firstOrNull { it.ownerId == owner && it.irrigation.id == session.id && it.phase != FertigationLinkedOutbox.Phase.ACKNOWLEDGED }
        runCatching { steps = repo.fertigationRepository.programSteps(session.vineyardId) }
            .onFailure { message = "Program Steps unavailable. Existing frozen quantities can still be saved for retry." }
    }
    fun save(retry: Boolean) {
        if (!allowed || saving) return
        scope.launch {
            saving = true
            runCatching {
                if (retry) pending?.let { repo.fertigationOutbox.retry(it.id) }
                else {
                    val entry = draft.entry(session, checkNotNull(owner))
                    repo.fertigationOutbox.enqueueExisting(entry)
                    pending = entry
                }
                repo.flushFertigation(session.vineyardId)
                val result = repo.fertigationOutbox.entries().firstOrNull { it.id == (pending?.id ?: draft.id) }
                message = result?.message
                pending = result?.takeIf { it.phase != FertigationLinkedOutbox.Phase.ACKNOWLEDGED }
                if (pending == null) onDone()
            }.onFailure { message = "Fertigation is retained on this device if saved. Check access and retry; irrigation has not changed." }
            saving = false
        }
    }
    AlertDialog(onDismissRequest = onDone, title = { Text(if (application == null) "Add Fertigation" else "View / Edit Fertigation") },
        text = {
            Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (allowed) {
                    Text(FertigationDomain.string(draft.step ?: JsonObject(emptyMap()), "name") ?: "Select a Program Step")
                    steps.forEach { step ->
                        TextButton(onClick = { draft = draft.select(step, totals) }, enabled = !saving && pending == null) { Text(FertigationDomain.string(step, "name") ?: "Program Step") }
                    }
                    Text("Existing frozen product fields are retained. Selecting another step changes its provenance on the server.", style = MaterialTheme.typography.bodySmall)
                    draft.products.forEachIndexed { index, product ->
                        Text(FertigationDomain.string(product, "product_name") ?: "Product")
                        Text("Planned: ${FertigationHistory.quantity(product, "planned_quantity")}")
                        OutlinedTextField(draft.actuals[index], { value -> draft = draft.copy(actuals = draft.actuals.mapIndexed { i, old -> if (i == index) value else old }) }, label = { Text("Actual used (${FertigationDomain.string(product, "quantity_unit") ?: "saved unit"})") }, enabled = !saving && pending == null)
                    }
                    OutlinedTextField(draft.notes, { draft = draft.copy(notes = it) }, label = { Text("Fertigation notes") }, enabled = !saving && pending == null)
                    pending?.let { Text(it.message) }
                } else if (application != null && state.isSystemAdmin) FertigationApplicationContent(application, state.regionFormatter)
                message?.let { Text(it) }
            }
        }, confirmButton = { if (allowed) TextButton(onClick = { save(pending != null) }, enabled = !saving && draft.step != null) { Text(if (pending != null) "Retry Fertigation only" else "Save Fertigation") } },
        dismissButton = { TextButton(onClick = onDone) { Text("Close") } })
}
