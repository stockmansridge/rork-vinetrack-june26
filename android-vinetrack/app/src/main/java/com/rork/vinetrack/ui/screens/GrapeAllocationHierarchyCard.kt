package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.GrapeAllocation
import com.rork.vinetrack.data.model.GrapeAllocationCalculator
import com.rork.vinetrack.data.model.GrapeAllocationHierarchy
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale
import kotlin.math.abs

/** Native stacked metrics avoid squeezing five numerical columns on phones. */
@Composable
fun GrapeAllocationHierarchyCard(
    parent: GrapeAllocationCalculator.CanonicalVarietyRow,
    children: List<GrapeAllocationHierarchy.BlockRow>,
    allocations: List<GrapeAllocation>,
    expanded: Boolean,
    onToggle: () -> Unit,
    onEdit: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(onClick = onToggle, modifier = Modifier.fillMaxWidth().semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }) {
                Icon(if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, contentDescription = if (expanded) "Collapse ${parent.displayName} blocks" else "Expand ${parent.displayName} blocks")
                Text(parent.displayName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            }
            HierarchyMetrics(parent.estimatedTonnes, parent.ownUseTonnes, parent.externalTonnes, parent.balanceTonnes)
            if (parent.isSupplyUnknown) Text("Estimate incomplete", color = vine.textSecondary)
            AnimatedVisibility(visible = expanded) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    children.forEach { child ->
                        HorizontalDivider()
                        Column(modifier = Modifier.padding(start = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(if (child.paddockId == null) child.name else "Block: ${child.name}", fontWeight = FontWeight.Medium, color = vine.textPrimary)
                            HierarchyMetrics(child.estimatedTonnes, child.ownUseTonnes, child.externalTonnes, child.balanceTonnes)
                            if (child.hasUnspecifiedQuantity) Text("Block quantity not recorded. Unmatched tonnes appear under No block specified.", color = vine.textSecondary)
                            if (child.paddockId == null && child.allocatedTonnes < 0) Text("Recorded block quantities exceed the allocation total. Edit the allocation to reconcile them.", color = VineColors.Orange)
                            val editable = allocations.filter { it.id in child.allocationIds }
                            var choosing by remember(child.key) { mutableStateOf(false) }
                            if (editable.isNotEmpty()) {
                                Column {
                                    TextButton(onClick = { if (editable.size == 1) onEdit(editable.first().id) else choosing = true }) {
                                        Text(if (editable.size == 1) "Edit allocation" else "Edit allocation (${editable.size})")
                                    }
                                    DropdownMenu(expanded = choosing, onDismissRequest = { choosing = false }) {
                                        editable.forEach { allocation ->
                                            DropdownMenuItem(text = {
                                                val destination = if (allocation.isExternal) allocation.purchaserName else allocation.destinationName
                                                Text("${if (allocation.isExternal) "External" else "Own Use"} · ${destination ?: "Unnamed destination"} · ${hierarchyTonnes(allocation.quantityTonnes)} · ${allocation.id.take(8)}")
                                            }, onClick = { choosing = false; onEdit(allocation.id) })
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HierarchyMetrics(estimate: Double?, own: Double, external: Double, balance: Double?, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    val shortfall = balance != null && balance < -GrapeAllocationCalculator.SHORTFALL_TOLERANCE
    val metrics = listOf("Estimated" to estimate, "Own Use" to own, "External" to external,
        "Total allocated" to own + external, (if (shortfall) "Shortfall" else "Available") to balance?.let { abs(it) })
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        metrics.forEach { (label, value) ->
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(label, color = vine.textSecondary, modifier = Modifier.weight(1f))
                Text(hierarchyTonnes(value), fontWeight = FontWeight.Medium, color = if (label == "Shortfall") VineColors.Destructive else vine.textPrimary)
            }
        }
    }
}

private fun hierarchyTonnes(value: Double?): String = value?.let { String.format(Locale.getDefault(), "%.2f t", it) } ?: "—"
