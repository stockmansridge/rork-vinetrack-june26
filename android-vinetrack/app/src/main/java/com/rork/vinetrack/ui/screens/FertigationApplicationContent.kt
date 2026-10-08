package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.*
import kotlinx.serialization.json.*

@Composable
internal fun FertigationApplicationContent(application: JsonObject, fmt: RegionFormatter, modifier: Modifier = Modifier, showSession: Boolean = false) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(FertigationDomain.string(application, "program_step_name") ?: "Program Step", style = MaterialTheme.typography.titleSmall)
        Text("Growth Stage: ${FertigationDomain.string(application, "growth_stage_code") ?: "—"}")
        Text(if (FertigationDomain.string(application, "status") == "reversed") "Reversed" else FertigationDomain.string(application, "status") ?: "Unknown")
        if (showSession) {
            Text(fmt.formatDate(FertigationDomain.string(application, "session_date") ?: ""))
            Text("${FertigationDomain.string(application, "system_name") ?: "—"} · ${FertigationDomain.string(application, "valve_name") ?: "—"}")
            Text((application["block_names"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.joinToString(", "))
            FertigationDomain.number(application, "duration_minutes")?.let { Text("Duration: $it min") }
            FertigationDomain.number(application, "total_volume_litres")?.let { Text("Total irrigation water: ${fmt.formatVolume(it)}") }
        }
        (application["products"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.forEach { product ->
            Text(FertigationDomain.string(product, "product_name") ?: "Product", style = MaterialTheme.typography.titleSmall)
            Text("Planned rate: ${FertigationHistory.rate(product)}")
            Text("Planned quantity: ${FertigationHistory.quantity(product, "planned_quantity")}")
            val actual = FertigationHistory.quantity(product, "actual_quantity")
            Text(if (actual == "Actual not entered") actual else "Actual: $actual")
            Text(FertigationDomain.frozenCost(product)?.let { "Cost: ${fmt.formatCurrency(it)}" } ?: "Cost unavailable")
        }
        FertigationDomain.string(application, "notes")?.takeIf { it.isNotBlank() }?.let { Text(it) }
    }
}
