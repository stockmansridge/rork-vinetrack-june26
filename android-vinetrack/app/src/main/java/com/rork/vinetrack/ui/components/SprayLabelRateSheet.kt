package com.rork.vinetrack.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.chemical.SpraySelectableRate

/** Compact rates are independently selectable; long label directions stay behind See details. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayLabelRateSheet(
    rates: List<SpraySelectableRate>,
    selectedId: String?,
    onSelect: (SpraySelectableRate) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(setOf<String>()) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(modifier.fillMaxWidth()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Select label rate", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Close") }
            }
            LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(rates, key = { it.id }) { rate ->
                    val selected = selectedId == rate.id
                    OutlinedCard(
                        modifier = Modifier.fillMaxWidth(),
                        border = BorderStroke(
                            if (selected) 2.dp else 0.5.dp,
                            if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                        ),
                        colors = CardDefaults.outlinedCardColors(
                            containerColor = if (selected) MaterialTheme.colorScheme.primaryContainer
                            else MaterialTheme.colorScheme.surface,
                        ),
                    ) {
                        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(
                                    onClick = { onSelect(rate); onDismiss() },
                                    enabled = rate.isSelectable,
                                    modifier = Modifier.weight(1f).heightIn(min = 44.dp),
                                    contentPadding = PaddingValues(horizontal = 6.dp),
                                ) {
                                    Text(
                                        rate.displayText,
                                        fontSize = 16.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = MaterialTheme.colorScheme.onSurface,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                }
                                TextButton(onClick = {
                                    expanded = if (rate.id in expanded) expanded - rate.id else expanded + rate.id
                                }) {
                                    Text(if (rate.id in expanded) "Hide details" else "See details", fontSize = 12.sp)
                                }
                            }
                            if (!rate.isSelectable) {
                                Text("Reference only — no resolved application rate", style = MaterialTheme.typography.bodySmall)
                            }
                            if (rate.id in expanded) {
                                HorizontalDivider()
                                rate.selectionDetails.forEach { detail ->
                                    Text(detail, style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
