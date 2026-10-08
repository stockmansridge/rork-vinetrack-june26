package com.rork.vinetrack.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskPlanning
import com.rork.vinetrack.data.model.VineyardExternalResource
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel

@Composable
fun WorkTaskAttribution(task: WorkTask, state: AppUiState, vm: AppViewModel? = null, showsAssignment: Boolean = false, modifier: Modifier = Modifier) {
    var resources by remember(state.currentUserId, task.vineyardId) { mutableStateOf<List<VineyardExternalResource>>(emptyList()) }
    LaunchedEffect(state.currentUserId, task.vineyardId, vm) {
        if (vm != null && state.currentUserId != null && state.selectedVineyardId == task.vineyardId) {
            try { resources = vm.listExternalResources(task.vineyardId) } catch (_: Exception) { resources = emptyList() }
        }
    }
    val members = state.members.filter { it.vineyardId == task.vineyardId }
    fun person(id: String): String = members.firstOrNull { it.userId == id }?.name ?: "Recorded person (name unavailable)"
    val assigned = task.assignedTo?.let(::person) ?: task.assignedExternalResourceId?.let { id ->
        resources.firstOrNull { it.id == id && it.vineyardId == task.vineyardId }?.let { it.name + if (it.isActive && it.deletedAt == null) "" else " · Inactive" } ?: "Historical resource (name unavailable)"
    } ?: "Unassigned"
    Column(modifier) {
        if (task.isFinalized || task.status == "completed") {
            val user = WorkTaskPlanning.completingUser(task, state.trips, members.map { it.userId }.toSet())
            Text(user?.let { "Completed by ${person(it)}" } ?: "Completed by unknown", style = MaterialTheme.typography.bodySmall)
            if (showsAssignment) Text("Assigned to: $assigned", style = MaterialTheme.typography.bodySmall)
        } else Text("Assigned to: $assigned", style = MaterialTheme.typography.bodySmall)
    }
}
