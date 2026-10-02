package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.chemical.CatalogueRepository
import com.rork.vinetrack.data.chemical.CatalogueRow
import com.rork.vinetrack.data.model.SavedChemical

@Composable
internal fun CatalogueSavedChemical(chemical: SavedChemical, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    var revision by remember(chemical.chemicalV3RevisionId) { mutableStateOf<CatalogueRow?>(null) }
    LaunchedEffect(chemical.chemicalV3RevisionId) {
        revision = chemical.chemicalV3RevisionId?.let { runCatching { CatalogueRepository(context).revision(it) }.getOrNull() }
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row {
            CatalogueLabel(revision?.text("front_label_image_path"), revision?.text("manufacturer_label_url") ?: chemical.labelUrl.takeIf { it.isNotBlank() })
            Column(Modifier.weight(1f).padding(start = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(chemical.displayName, style = MaterialTheme.typography.titleMedium)
                Text(CatalogueRow.compactManufacturer(chemical.manufacturer), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (revision != null) Text(revision!!.badge, style = MaterialTheme.typography.bodySmall)
                else if (chemical.chemicalV3RevisionId != null) Text("Catalogue information unavailable", style = MaterialTheme.typography.bodySmall)
                Text(revision?.groupText ?: listOf(chemical.activityGroupScheme?.uppercase().orEmpty(), chemical.activityGroups.orEmpty().joinToString(" + ")).filter { it.isNotBlank() }.joinToString(" "))
            }
        }
        revision?.let { row ->
            Text("Used for: ${row.targets.joinToString(" · ")}", style = MaterialTheme.typography.bodySmall)
            row.text("manufacturer_product_url")?.takeIf { it.startsWith("https://") }?.let { url ->
                TextButton(onClick = { uriHandler.openUri(url) }) { Text("Manufacturer product") }
            }
        }
        if (revision != null) Text(chemical.manufacturer, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
