package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.*
import kotlinx.serialization.json.JsonObject

@Composable
internal fun FertigationProgramHistory(repo: FertigationRepository, vineyardId: String, stepId: String, isSystemAdmin: Boolean, fmt: RegionFormatter, modifier: Modifier = Modifier) {
    var applications by remember(vineyardId, stepId) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(vineyardId, stepId, isSystemAdmin) {
        applications = emptyList()
        if (!isSystemAdmin) return@LaunchedEffect
        runCatching { applications = repo.applications(vineyardId, programStepId = stepId, includeReversed = true) }
            .onFailure { error = "Application History could not be loaded." }
    }
    if (isSystemAdmin) Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Application History", style = MaterialTheme.typography.titleMedium)
        if (applications.isEmpty()) Text(error ?: "No applications yet.")
        applications.forEach { application -> FertigationApplicationContent(application, fmt, showSession = true); HorizontalDivider() }
    }
}
