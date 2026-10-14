package com.rork.vinetrack.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.chemical.SpraySelectableRate

/** Uses already hydrated rates; no reads, automatic selection or dose recalculation on opening. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayLabelRateSheet(rates: List<SpraySelectableRate>, selectedId: String?, onSelect: (SpraySelectableRate) -> Unit,
    onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Select label rate", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Close") }
            }
            LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(rates, key = { it.id }) { rate ->
                    val selected = selectedId == rate.id
                    OutlinedCard(onClick = { onSelect(rate); onDismiss() }, enabled = rate.isSelectable,
                        modifier = Modifier.fillMaxWidth(),
                        border = BorderStroke(if (selected) 2.dp else 0.5.dp,
                            if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline),
                        colors = CardDefaults.outlinedCardColors(containerColor = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface)) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(rate.displayText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                            rate.selectionDetails.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
                            if (selected) Text("Selected", style = MaterialTheme.typography.labelMedium)
                            if (!rate.isSelectable) Text("Reference only — not a resolved application rate", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
    }
}
