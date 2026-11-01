package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.chemical.CatalogueRepository
import com.rork.vinetrack.data.chemical.CatalogueRow
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.CancellationException

@Composable
internal fun CatalogueSavedChemical(chemical: SavedChemical, modifier: Modifier = Modifier, showsDetails: Boolean = false) {
    val context = LocalContext.current
    val repository = remember(context) { CatalogueRepository(context) }
    var revision by remember(chemical.chemicalV3RevisionId) { mutableStateOf<CatalogueRow?>(null) }
    var frontLabelPath by remember(chemical.chemicalV3RevisionId) { mutableStateOf<String?>(null) }
    var loading by remember(chemical.chemicalV3RevisionId) { mutableStateOf(chemical.chemicalV3RevisionId != null) }
    LaunchedEffect(chemical.chemicalV3RevisionId) {
        val id = chemical.chemicalV3RevisionId ?: return@LaunchedEffect
        try {
            val exactRevision = repository.revision(id)
            revision = exactRevision
            frontLabelPath = repository.resolvedFrontLabelPath(exactRevision)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Keep loaded exact facts even if the image fallback is unavailable.
        } finally {
            loading = false
        }
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row {
            CatalogueLabel(frontLabelPath, revision?.text("manufacturer_label_url"))
            Column(Modifier.weight(1f).padding(start = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(revision?.text("product_name") ?: chemical.displayName, style = MaterialTheme.typography.titleMedium)
                Text(CatalogueRow.compactManufacturer(revision?.text("manufacturer") ?: chemical.manufacturer), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("VineTrack catalogue · linked", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                Text(revision?.badge ?: if (loading) "Loading linked catalogue details…" else "Basic details · linked revision unavailable. Reconnect and reopen to retry.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (showsDetails) Text("Catalogue linkage is not label approval. Follow the current product label and registered-use conditions.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        val exact = revision
        if (exact != null) {
            if (exact.targets.isNotEmpty()) Text("Used for: ${exact.targets.joinToString(" · ")}", style = MaterialTheme.typography.bodySmall)
            if (exact.groupText.isNotBlank()) Text(exact.groupText, style = MaterialTheme.typography.labelMedium)
            if (showsDetails) CatalogueRevisionDetails(exact)
        } else {
            val group = CatalogueRow.resistanceText(chemical.activityGroupScheme, chemical.activityGroups.orEmpty())
            if (group.isNotBlank()) Text(group, style = MaterialTheme.typography.bodySmall)
        }
    }
}
