package com.rork.vinetrack.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.VineyardExternalResource
import com.rork.vinetrack.ui.AppViewModel
import kotlinx.coroutines.launch
import java.util.UUID

@Composable
fun ExternalResourceDirectory(vm: AppViewModel, vineyardId: String, canManage: Boolean, modifier: Modifier = Modifier) {
    var resources by remember(vineyardId) { mutableStateOf<List<VineyardExternalResource>>(emptyList()) }
    var error by remember(vineyardId) { mutableStateOf<String?>(null) }
    var editing by remember(vineyardId) { mutableStateOf<VineyardExternalResource?>(null) }
    var creating by remember(vineyardId) { mutableStateOf(false) }
    var refresh by remember(vineyardId) { mutableStateOf(0) }
    LaunchedEffect(vineyardId, refresh) {
        try { resources = vm.listExternalResources(vineyardId); error = null }
        catch (_: Exception) { error = "Directory unavailable. Reconnect and retry." }
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Crew / External Contractors", style = MaterialTheme.typography.titleMedium)
        Text("Resources are not login accounts. Assignments do not create labour charges; Worker Types govern rates.", style = MaterialTheme.typography.bodySmall)
        if (canManage) TextButton(onClick = { creating = true }) { Text("Add resource") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error); TextButton(onClick = { refresh++ }) { Text("Retry") } }
        resources.filter { it.deletedAt == null }.forEach { resource ->
            TextButton(onClick = { if (canManage) editing = resource }, modifier = Modifier.fillMaxWidth()) {
                Text("${resource.name} · ${if (resource.kind == "crew") "Crew" else "Contractor"}${if (resource.isActive) "" else " · Inactive"}")
            }
        }
    }
    if (creating || editing != null) ExternalResourceEditor(vm, vineyardId, editing, onSaved = { refresh++; creating = false; editing = null }, onDismiss = { creating = false; editing = null })
}

/** A nested editor leaves the parent task/pruning form alive; success requires a returned canonical row. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExternalResourceEditor(
    vm: AppViewModel,
    vineyardId: String,
    existing: VineyardExternalResource? = null,
    onSaved: (VineyardExternalResource) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val id = remember(existing?.id) { existing?.id ?: UUID.randomUUID().toString() }
    var name by remember(id) { mutableStateOf(existing?.name ?: "") }
    var kind by remember(id) { mutableStateOf(existing?.kind ?: "crew") }
    var contact by remember(id) { mutableStateOf(existing?.contactName ?: "") }
    var phone by remember(id) { mutableStateOf(existing?.phone ?: "") }
    var email by remember(id) { mutableStateOf(existing?.email ?: "") }
    var notes by remember(id) { mutableStateOf(existing?.notes ?: "") }
    var active by remember(id) { mutableStateOf(existing?.isActive ?: true) }
    var saving by remember(id) { mutableStateOf(false) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    fun optional(text: String): String? = text.trim().ifBlank { null }
    ModalBottomSheet(onDismissRequest = { if (!saving) onDismiss() }, modifier = modifier) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(if (existing == null) "Add Resource" else "Edit Resource", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
            Row { TextButton(onClick = { kind = "crew" }) { Text(if (kind == "crew") "Crew (selected)" else "Crew") }; TextButton(onClick = { kind = "contractor" }) { Text(if (kind == "contractor") "Contractor (selected)" else "External contractor") } }
            Row { Text("Active", Modifier.weight(1f)); Switch(active, { active = it }) }
            OutlinedTextField(contact, { contact = it }, label = { Text("Contact name") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(phone, { phone = it }, label = { Text("Phone") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(email, { email = it }, label = { Text("Email") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(notes, { notes = it }, label = { Text("Notes") }, modifier = Modifier.fillMaxWidth())
            Text("Online confirmation required. Your unfinished task or pruning activity remains open underneath.", style = MaterialTheme.typography.bodySmall)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(onClick = {
                saving = true
                scope.launch {
                    try {
                        val desired = VineyardExternalResource(id, vineyardId, name.trim(), kind, optional(contact), optional(phone), optional(email), optional(notes), active)
                        val saved = vm.saveExternalResource(desired, existing)
                        onSaved(saved)
                    } catch (_: Exception) { error = "Save not confirmed or resource changed. Form retained. Reopen to review current directory before retrying an edit." }
                    finally { saving = false }
                }
            }, enabled = !saving && name.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text(if (saving) "Saving…" else "Save") }
            TextButton(onClick = onDismiss, enabled = !saving) { Text("Cancel") }
        }
    }
}
