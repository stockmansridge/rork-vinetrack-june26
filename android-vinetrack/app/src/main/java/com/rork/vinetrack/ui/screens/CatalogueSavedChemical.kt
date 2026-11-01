package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.chemical.CatalogueRepository
import com.rork.vinetrack.data.chemical.CatalogueRow
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.CancellationException

/** Live approved master facts; no automatic applied dose or saved-row mutation. */
@Composable
internal fun CatalogueSavedChemical(chemical: SavedChemical, modifier: Modifier = Modifier, showsDetails: Boolean = false) {
    val context = LocalContext.current
    val repository = remember(context) { CatalogueRepository(context) }
    var revision by remember(chemical) { mutableStateOf<CatalogueRow?>(null) }
    var frontLabelPath by remember(chemical) { mutableStateOf<String?>(null) }
    var loading by remember(chemical) { mutableStateOf(chemical.chemicalV3ProductId != null || chemical.chemicalV3RevisionId != null) }
    var isCurrentApproved by remember(chemical) { mutableStateOf(false) }

    LaunchedEffect(chemical) {
        try {
            // Resolve the approved product head FIRST. An old pinned revision
            // may no longer be visible through RLS to normal vineyard members.
            val current = try {
                chemical.chemicalV3ProductId?.let { repository.approvedRevisionForProduct(it) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) { null }
            val fallback = if (current == null) {
                chemical.chemicalV3RevisionId?.let { repository.revision(it) }
            } else null
            val effective = current ?: fallback
            revision = effective
            isCurrentApproved = current != null
            if (effective != null) {
                frontLabelPath = repository.resolvedFrontLabelPath(effective)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Keep an already received master fact if image retrieval fails.
        } finally {
            loading = false
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row {
            CatalogueLabel(frontLabelPath, revision?.text("manufacturer_label_url"))
            Column(Modifier.weight(1f).padding(start = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(revision?.text("product_name") ?: chemical.displayName,
                    style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(CatalogueRow.compactManufacturer(revision?.text("manufacturer") ?: chemical.manufacturer),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("VineTrack catalogue · linked", style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary)
                Text(
                    if (isCurrentApproved) "Latest approved catalogue information · automatic"
                    else revision?.badge ?: if (loading) "Loading approved catalogue information…"
                    else "Catalogue unavailable · saved vineyard details retained",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (showsDetails) Text(
                    "Label rates are references, not an automatically chosen dose. Follow current registered-use conditions.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        if (revision != null) {
            val effective = revision!!
            if (effective.targets.isNotEmpty()) Text("Used for: ${effective.targets.joinToString(" · ")}",
                style = MaterialTheme.typography.bodySmall,
                maxLines = if (showsDetails) Int.MAX_VALUE else 2,
                overflow = TextOverflow.Ellipsis)
            if (effective.groupText.isNotBlank()) Text(effective.groupText, style = MaterialTheme.typography.labelMedium)
            if (showsDetails) CatalogueRevisionDetails(effective)
        } else {
            val group = CatalogueRow.resistanceText(chemical.activityGroupScheme, chemical.activityGroups.orEmpty())
            if (group.isNotBlank()) Text(group, style = MaterialTheme.typography.bodySmall)
        }
    }
}
