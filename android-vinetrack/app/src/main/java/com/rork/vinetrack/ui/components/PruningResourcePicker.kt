package com.rork.vinetrack.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.VineyardExternalResource

/** Selection is scoped to members/resources, never inferred from administrator status. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PruningResourcePicker(
    vineyardId: String,
    members: List<VineyardMember>,
    currentName: String,
    loadExternal: suspend (String) -> List<VineyardExternalResource>,
    onSelect: (String?, String?, String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    allowsManualName: Boolean = true,
    onQuickAdd: (() -> Unit)? = null,
) {
    var search by remember { mutableStateOf("") }
    var resources by remember(vineyardId) { mutableStateOf<List<VineyardExternalResource>>(emptyList()) }
    var error by remember(vineyardId) { mutableStateOf<String?>(null) }
    LaunchedEffect(vineyardId) {
        try { resources = loadExternal(vineyardId) }
        catch (_: Exception) { error = "Directory unavailable. Your current selection is retained; reconnect to choose another resource." }
    }
    fun choose(external: String?, user: String?, name: String) {
        onSelect(external, user, name)
        onDismiss()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, modifier = modifier) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Assigned to", style = MaterialTheme.typography.titleLarge)
            if (currentName.isNotBlank()) Text("Current: $currentName")
            OutlinedTextField(search, { search = it }, label = { Text("Search people, crews and contractors") }, modifier = Modifier.fillMaxWidth())
        }
        LazyColumn(Modifier.padding(horizontal = 16.dp)) {
            item {
                TextButton(onClick = { choose(null, null, "") }) { Text("Unassigned") }
                if (allowsManualName) TextButton(onClick = { choose(null, null, currentName) }) { Text("Other / manual name") }
                onQuickAdd?.let { add -> TextButton(onClick = add) { Text("Add Crew / External Contractor") } }
                Text("Internal resources", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(vertical = 12.dp))
            }
            items(members.filter { it.vineyardId == vineyardId && it.name.contains(search, ignoreCase = true) }, key = { "member-${it.userId}" }) { member ->
                TextButton(onClick = { choose(null, member.userId, member.name) }, modifier = Modifier.fillMaxWidth()) { Text(member.name) }
            }
            item { Text("Crew / External contractors", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(vertical = 12.dp)) }
            items(resources.filter { com.rork.vinetrack.data.model.WorkTaskPlanning.canSelect(it, vineyardId) && it.name.contains(search, ignoreCase = true) }, key = { "resource-${it.id}" }) { resource ->
                TextButton(onClick = { choose(resource.id, null, resource.name) }, modifier = Modifier.fillMaxWidth()) { Text(resource.name + if (resource.kind == "crew") " · Crew" else " · Contractor") }
            }
            item {
                if (error != null) Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
                Text("Assignments do not create labour charges. Worker Types control labour classifications and frozen rates.", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 16.dp))
            }
        }
    }
}
