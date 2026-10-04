package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.chemical.OperationalRateResolver
import com.rork.vinetrack.data.spray.SprayProgramProductDraft
import com.rork.vinetrack.data.spray.SprayProductRateBasis

/** Edits the existing Program product-line amount/unit/basis, never the Chemical Store. */
@Composable
internal fun ProgramPlannedRateEditor(product: SprayProgramProductDraft, vineyardName: String, enabled: Boolean, modifier: Modifier = Modifier, chemical: com.rork.vinetrack.data.model.SavedChemical? = null, onChange: (SprayProgramProductDraft) -> Unit) {
    var text by remember(product.lineKey, product.savedChemicalId) { mutableStateOf(product.rate.takeIf { it > 0 }?.toString().orEmpty()) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(text, { value -> text = value; onChange(product.copy(rate = if (value.isBlank()) 0.0 else value.replace(',', '.').toDoubleOrNull() ?: Double.NaN, rateSource = OperationalRateResolver.Source.PROGRAM_STEP)) }, label = { Text("Planned rate (optional)") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), enabled = enabled, modifier = Modifier.fillMaxWidth())
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("Litres" to "L", "mL" to "mL", "Kg" to "kg", "g" to "g").forEach { (raw, label) -> FilterChip(product.unitRaw == raw, { onChange(product.copy(unitRaw = raw, rateSource = OperationalRateResolver.Source.PROGRAM_STEP)) }, label = { Text(label) }, enabled = enabled) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FilterChip(product.basis == SprayProductRateBasis.WHOLE_BLOCK_AREA, { onChange(product.copy(basis = SprayProductRateBasis.WHOLE_BLOCK_AREA, rateSource = OperationalRateResolver.Source.PROGRAM_STEP)) }, label = { Text("Per hectare") }, enabled = enabled)
            FilterChip(product.basis == SprayProductRateBasis.PER_100_LITRES, { onChange(product.copy(basis = SprayProductRateBasis.PER_100_LITRES, rateSource = OperationalRateResolver.Source.PROGRAM_STEP)) }, label = { Text("Per 100 L") }, enabled = enabled)
        }
        if (product.rate > 0) Text(if (product.rateSource == OperationalRateResolver.Source.VINEYARD_PREFERRED) "From $vineyardName preferred rate" else "Program Step rate", style = MaterialTheme.typography.bodySmall)
        if (chemical != null && product.rate.isFinite() && product.rate > 0) {
            val unit = com.rork.vinetrack.data.chemical.ChemicalDefaultRateValidity.canonicalUnit(product.unitRaw)
            if (unit != null) {
                val preferred = com.rork.vinetrack.data.chemical.VineyardPreferredRate(product.rate, unit, if (product.basis == SprayProductRateBasis.PER_100_LITRES) "per_100_litres" else "per_hectare")
                OperationalRateResolver.warning(preferred, chemical)?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        }
        Text("Saving remembers this step's intended rate without changing the vineyard preference. Clear the amount to choose it when planning.", style = MaterialTheme.typography.bodySmall)
    }
}
