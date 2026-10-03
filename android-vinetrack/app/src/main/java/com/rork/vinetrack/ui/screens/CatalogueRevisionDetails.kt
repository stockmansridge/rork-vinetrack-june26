package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.chemical.CatalogueRow
import com.rork.vinetrack.data.model.ProductCategories

/** Facts from the exact revision; never hydrated into the legacy editing draft. */
@Composable
internal fun CatalogueRevisionDetails(revision: CatalogueRow, modifier: Modifier = Modifier) {
    val uriHandler = LocalUriHandler.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val category = revision.text("product_category_key") ?: revision.text("product_category")
        ProductCategories.all.firstOrNull { it.first == category }?.second?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        if (revision.activeIngredientLines.isNotEmpty()) {
            Text("Active ingredients", style = MaterialTheme.typography.titleSmall)
            revision.activeIngredientLines.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        revision.resistanceWarning?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        Text("Registered grapevine rates", style = MaterialTheme.typography.titleSmall)
        listOf("per_hectare" to "Per hectare", "per_100_litres" to "Per 100 L").forEach { (key, title) ->
            val lines = revision.registeredRateLines(key)
            if (lines.isNotEmpty()) {
                Text(title, style = MaterialTheme.typography.labelLarge)
                lines.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        }
        if (revision.rateRows("per_hectare").isEmpty() && revision.rateRows("per_100_litres").isEmpty()) {
            Text("No registered grapevine rate available. Check the manufacturer label.", style = MaterialTheme.typography.bodySmall)
        }
        Text("Choose the exact dose when planning the spray. Follow the applicable label conditions.", style = MaterialTheme.typography.bodySmall)
        revision.rows("vineyard_uses").forEach { direction ->
            val statements = listOf("withholding_statement" to "Withholding", "re_entry_statement" to "Re-entry", "restrictions" to "Restrictions")
                .mapNotNull { (key, title) -> direction.text(key)?.takeIf(String::isNotBlank)?.let { "$title: $it" } }
            if (statements.isNotEmpty()) {
                Text(direction.strings("targets").joinToString(" · "), style = MaterialTheme.typography.labelMedium)
                statements.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        }
        Text("Label & references", style = MaterialTheme.typography.titleSmall)
        listOf("manufacturer_label_url" to "Manufacturer label", "manufacturer_product_url" to "Manufacturer product page").forEach { (key, title) ->
            revision.text(key)?.takeIf { it.startsWith("https://") || it.startsWith("http://") }?.let { url ->
                TextButton(onClick = { runCatching { uriHandler.openUri(url) } }) { Text(title) }
            }
        }
        Text("A product page is not an official label.", style = MaterialTheme.typography.bodySmall)
    }
}
