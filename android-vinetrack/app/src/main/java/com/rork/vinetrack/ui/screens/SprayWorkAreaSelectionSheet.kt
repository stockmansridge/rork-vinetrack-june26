package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.spray.SprayWorkAreaSelection
import com.rork.vinetrack.data.spray.SprayPassConfiguration

/** Complete travel passes only; no automatic hectare matching, coverage or operational effects. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayWorkAreaSelectionSheet(choices: List<SprayWorkAreaSelection.Choice>, configuration: SprayPassConfiguration,
    selected: List<SprayWorkAreaSelection.Selected>, onChange: (List<SprayWorkAreaSelection.Selected>) -> Unit,
    onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    ModalBottomSheet(onDismissRequest = onDismiss, modifier = modifier) {
        LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f, fill = false), contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                Text("Select Work Area", style = MaterialTheme.typography.titleLarge)
                Text("Select complete machine travel passes. Selection never marks a pass as sprayed.")
                if (configuration == SprayPassConfiguration.OVER_ROW)
                    Text("Over-Row: one travel pass, two controller row equivalents; no second completed occurrence.")
            }
            if (choices.isEmpty()) item { Text("No physical passes available. Check the selected blocks and stored row geometry.") }
            items(choices, key = { it.id }) { choice ->
                val current = selected.firstOrNull { it.choiceId == choice.id }
                Row(modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Checkbox(checked = current != null, onCheckedChange = {
                        onChange(if (current != null) selected.filterNot { it.id == current.id }
                            else selected + SprayWorkAreaSelection.select(choice, configuration))
                    }, modifier = Modifier.testTag("spray.work.${choice.id}"))
                    Column(Modifier.weight(1f)) {
                        Text(choice.title)
                        Text(if (choice.hasGeometry) "Frozen row geometry • treatment area not certified" else "Missing or uncertain geometry", style = MaterialTheme.typography.bodySmall)
                        if (current != null && !SprayWorkAreaSelection.retained(current, choices, configuration))
                            Text("Selection changed: remove and explicitly select again.", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
            items(selected.filter { s -> choices.none { it.id == s.choiceId } }, key = { "retained:${it.id}" }) { s ->
                TextButton(onClick = { onChange(selected.filterNot { it.id == s.id }) }) { Text("Remove unavailable ${s.title}") }
            }
            item { Text(SprayWorkAreaSelection.ROUTE_MESSAGE, style = MaterialTheme.typography.bodySmall) }
            item { Button(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text("Done") } }
        }
    }
}
