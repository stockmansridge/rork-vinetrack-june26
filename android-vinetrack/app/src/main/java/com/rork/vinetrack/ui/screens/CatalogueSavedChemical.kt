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

@Composable
internal fun CatalogueSavedChemical(chemical: SavedChemical, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var revision by remember(chemical.chemicalV3RevisionId) { mutableStateOf<CatalogueRow?>(null) }
    LaunchedEffect(chemical.chemicalV3RevisionId) {
        revision = chemical.chemicalV3RevisionId?.let { runCatching { CatalogueRepository(context).revision(it) }.getOrNull() }
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row {
            CatalogueLabel(revision?.text("front_label_image_path"), chemical.labelUrl.takeIf { it.isNotBlank() } ?: revision?.text("manufacturer_label_url"))
            Column(Modifier.padding(8.dp)) {
                Text(chemical.displayName, style = MaterialTheme.typography.titleMedium)
                Text(CatalogueRow.compactManufacturer(chemical.manufacturer))
                Text(revision?.badge ?: "VineTrack catalogue")
                Text(revision?.groupText ?: listOf(chemical.activityGroupScheme?.uppercase().orEmpty(), chemical.activityGroups.orEmpty().joinToString(" + ")).filter { it.isNotBlank() }.joinToString(" "))
            }
        }
        revision?.let { Text("Used for: ${it.targets.joinToString(" · ")}") }
        Text(chemical.manufacturer, style = MaterialTheme.typography.bodySmall)
    }
}
