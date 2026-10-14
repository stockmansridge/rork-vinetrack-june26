package com.rork.vinetrack.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.spray.SprayPlanningOperationalGate

/** View-local advisory; showing/dismissing details never changes calculator inputs. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayConcentrationWarning(products: List<String>, modifier: Modifier = Modifier) {
    var showing by remember { mutableStateOf(false) }
    if (products.isEmpty()) return
    TextButton(onClick = { showing = true }, modifier = modifier.heightIn(min = 44.dp),
        contentPadding = PaddingValues(horizontal = 0.dp),
        colors = ButtonDefaults.textButtonColors(contentColor = Color(0xFFC77710))) {
        Icon(Icons.Filled.Warning, contentDescription = null, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text("WARNING", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
    }
    if (showing) {
        ModalBottomSheet(onDismissRequest = { showing = false }) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(SprayPlanningOperationalGate.WARNING_TITLE, style = MaterialTheme.typography.titleLarge)
                Text(SprayPlanningOperationalGate.WARNING_MESSAGE)
                Text("Affected chemicals", style = MaterialTheme.typography.titleSmall)
                products.forEach { Text(it) }
                TextButton(onClick = { showing = false }) { Text("Close") }
            }
        }
    }
}
