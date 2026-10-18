package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.model.*
import java.util.Locale

/** One local-only nutrient input; no repository, ViewModel, write callbacks or nutrient-entry list. */
@Composable
internal fun TargetNutrientPreview(
    products: List<SavedChemical>, paddocks: List<Paddock>, formatter: RegionFormatter,
    isSystemAdmin: Boolean, modifier: Modifier = Modifier,
) {
    if (!TargetNutrient.canPreview(isSystemAdmin)) {
        Text("Target Nutrient is a System Admin-only preview.", modifier.padding(16.dp)); return
    }
    var draft by rememberSaveable(stateSaver = nutrientDraftSaver) { mutableStateOf(TargetNutrient.Draft()) }
    var productId by rememberSaveable { mutableStateOf<String?>(null) }
    var manualName by rememberSaveable { mutableStateOf("") }
    var manualLiquid by rememberSaveable { mutableStateOf(false) }
    var selectedIds by rememberSaveable(stateSaver = listSaver<Set<String>, String>(save = { it.toList() }, restore = { it.toSet() })) { mutableStateOf(setOf<String>()) }
    var countBasis by rememberSaveable { mutableStateOf(FertiliserVineCounts.ACTUAL) }
    var vinesText by rememberSaveable { mutableStateOf("") }
    var areaText by rememberSaveable { mutableStateOf("") }
    var information by remember { mutableStateOf<String?>(null) }
    var showPackaging by rememberSaveable { mutableStateOf(false) }
    var packSizeText by rememberSaveable { mutableStateOf("") }
    var packPriceText by rememberSaveable { mutableStateOf("") }
    val product = products.firstOrNull { it.id == productId }
    val liquid = product?.isFertiliserLiquid ?: manualLiquid
    val blocks = paddocks.filter { it.id in selectedIds }
    val vines = if (blocks.isEmpty()) vinesText.toIntOrNull() else FertiliserVineCounts.total(blocks, countBasis)
    val area = if (blocks.isEmpty()) TargetNutrient.number(areaText)?.let { formatter.areaToCanonical(it) }
        else blocks.takeIf { it.all { b -> b.areaHectares.isFinite() && b.areaHectares > 0 } }?.sumOf { it.areaHectares }
    val result = TargetNutrient.calculate(draft, liquid, vines, area)
    val inputs: @Composable () -> Unit = {
        Card {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Calculator", style = MaterialTheme.typography.titleMedium)
                NutrientChoice("Product", productId ?: "manual", listOf("manual" to "Manual entry") + products.map { it.id to it.displayName }) {
                    productId = it.takeUnless { key -> key == "manual" }
                    draft = draft.copy(analysisBasis = "unknown", concentrationBasis = "unknown", density = "", densityReference = "")
                }
                if (product == null) {
                    NutrientField("Product name", manualName, { manualName = it }, numeric = false)
                    Row { Text("Liquid product", Modifier.weight(1f)); Switch(manualLiquid, {
                        manualLiquid = it; draft = draft.copy(concentrationBasis = "unknown", density = "", densityReference = "")
                    }) }
                } else Text("Enter the percentage from the label. Legacy N/P/K values are not verified analysis.", style = MaterialTheme.typography.bodySmall)
                NutrientChoice("Nutrient", draft.nutrient, TargetNutrient.nutrients.map { it.first to "${it.first} — ${it.second}" }) { draft = draft.selectNutrient(it) }
                if (draft.nutrient == "other") NutrientField("Nutrient name", draft.otherName, { draft = draft.copy(otherName = it) }, numeric = false)
                Row {
                    Text("Product nutrient (%)", Modifier.weight(1f))
                    IconButton(onClick = { information = "Elemental means the actual nutrient. Oxide values such as P₂O₅ and K₂O are different and are not converted. w/w means grams per 100 g product; w/v means grams per 100 mL product." }) { Icon(Icons.Default.Info, "About percentage") }
                }
                NutrientField("Nutrient percent", draft.percent, {
                    draft = draft.copy(percent = it, analysisBasis = if (draft.nutrient == "N") "elemental" else draft.analysisBasis, concentrationBasis = if (!liquid) "w/w" else draft.concentrationBasis)
                }, tag = "nutrient.percent")
                if (draft.nutrient in TargetNutrient.oxideKeys || draft.analysisBasis != "elemental") {
                    NutrientChoice("Percentage declared as", draft.analysisBasis, listOf("unknown" to "Confirm from label", "elemental" to "Elemental — actual nutrient", "oxide" to "Oxide — conversion unavailable")) { draft = draft.copy(analysisBasis = it) }
                }
                if (liquid) {
                    NutrientChoice("Concentration basis", draft.concentrationBasis, listOf("unknown" to "Confirm from label", "w/w" to "w/w — weight / weight", "w/v" to "w/v — weight / volume")) { draft = draft.copy(concentrationBasis = it) }
                    if (draft.concentrationBasis == "w/w") {
                        Row {
                            Text("Documented density", Modifier.weight(1f))
                            IconButton(onClick = { information = "Only w/w liquids need density to convert mass to litres. Enter kg/L and the label or technical-sheet reference. w/v already expresses nutrient mass per product volume." }) { Icon(Icons.Default.Info, "About density") }
                        }
                        NutrientField("Density (kg/L)", draft.density, { draft = draft.copy(density = it) })
                        NutrientField("Density source — label / technical sheet", draft.densityReference, { draft = draft.copy(densityReference = it) }, numeric = false)
                    }
                }
                NutrientChoice("Target basis", if (draft.perVine) "vine" else "area", listOf("vine" to "g nutrient/vine", "area" to "kg nutrient/ha")) { draft = draft.copy(perVine = it == "vine") }
                NutrientField("Target amount", draft.target, { draft = draft.copy(target = it) }, tag = "nutrient.target")
                if (blocks.isEmpty()) {
                    if (draft.perVine) NutrientField("Number of vines", vinesText, { vinesText = it }, tag = "nutrient.vines")
                    else NutrientField("Treated area (${formatter.areaUnitAbbreviation})", areaText, { areaText = it })
                } else Text(if (draft.perVine) "${vines ?: "Unavailable"} vines selected" else formatter.formatArea(area ?: 0.0))
            }
        }
    }
    val results: @Composable () -> Unit = {
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
            Column(Modifier.fillMaxWidth().padding(16.dp).testTag("nutrient.results"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Live Results", style = MaterialTheme.typography.titleMedium)
                result.rate?.let { NutrientMetric("Product required", "${nutrientNumber(it)} ${result.rateUnit}", "nutrient.rate") }
                    ?: Text("Product rate — waiting for label information")
                result.totalProduct?.let { NutrientMetric("Total product required", if (result.productUnit == "L") "${nutrientNumber(formatter.volumeValue(it))} ${formatter.volumeUnitAbbreviation}" else "${nutrientNumber(it)} kg", "nutrient.total") }
                    ?: Text("Total product — enter quantity or select blocks")
                result.totalNutrientKg?.let { NutrientMetric("Total actual ${if (draft.nutrient == "other") draft.otherName else draft.nutrient} delivered", "${nutrientNumber(it)} kg", "nutrient.delivered") }
                result.issues.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
                Text("Preview only · No records, inventory or product analyses are changed.", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
    BoxWithConstraints(modifier.fillMaxSize()) {
        val wide = maxWidth >= 700.dp
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("System Admin preview · Nothing is saved", style = MaterialTheme.typography.labelMedium)
            if (wide) Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                Column(Modifier.weight(1f)) { inputs() }; Column(Modifier.weight(1f)) { results() }
            } else { inputs(); results() }
            Card {
                Column(Modifier.padding(14.dp).testTag("nutrient.blockDetails"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Blocks & vine counts", style = MaterialTheme.typography.titleMedium)
                    Text("Choose existing blocks, or leave unselected to use manual quantities above.", style = MaterialTheme.typography.bodySmall)
                    if (draft.perVine) NutrientChoice("Vine count basis", countBasis, listOf(FertiliserVineCounts.ACTUAL to "Actual", FertiliserVineCounts.ASSUMED_FULL to "Assumed full")) { countBasis = it }
                    paddocks.forEach { block ->
                        Row {
                            Column(Modifier.weight(1f)) {
                                Text(block.name)
                                Text(if (draft.perVine) "${FertiliserVineCounts.count(block, countBasis) ?: "Unavailable"} vines · ${FertiliserVineCounts.label(countBasis)}" else formatter.formatArea(block.areaHectares), style = MaterialTheme.typography.bodySmall)
                            }
                            Checkbox(block.id in selectedIds, { selectedIds = if (it) selectedIds + block.id else selectedIds - block.id }, Modifier.testTag("nutrient.block.${block.id}"))
                        }
                    }
                }
            }
            TextButton(onClick = { showPackaging = !showPackaging }) { Text("Packaging & costs (optional)") }
            if (showPackaging) Card {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    val unit = if (liquid) "L" else "kg"
                    val size = product?.packSize ?: TargetNutrient.number(packSizeText)
                    if (product?.packSize != null) Text("Saved pack size: ${nutrientNumber(product.packSize)} $unit")
                    else NutrientField("Pack size ($unit)", packSizeText, { packSizeText = it })
                    if (product == null) NutrientField("Price per pack (${formatter.currencyCode})", packPriceText, { packPriceText = it })
                    if (result.productUnit == unit && result.totalProduct != null && size != null) {
                        FertiliserCalc.packsRequired(result.totalProduct, size)?.takeIf { it.isFinite() }?.let { Text("Packs required: ${nutrientNumber(it)} · Open ${nutrientNumber(kotlin.math.ceil(it))}") }
                        if (product == null) FertiliserCalc.productCost(result.totalProduct, size, TargetNutrient.number(packPriceText))?.takeIf { it.isFinite() }?.let { Text("Estimated product cost: ${formatter.formatCurrency(it)}") }
                    }
                    Text("No stock is reserved or deducted. Saved-product pricing remains in the existing purchase history.", style = MaterialTheme.typography.bodySmall)
                }
            }
            Button(onClick = {}, enabled = false, modifier = Modifier.testTag("nutrient.saveDisabled")) { Text("Save unavailable in preview") }
        }
    }
    information?.let { message -> AlertDialog(onDismissRequest = { information = null }, title = { Text("About this calculation") }, text = { Text(message) }, confirmButton = { TextButton(onClick = { information = null }) { Text("OK") } }) }
}

private val nutrientDraftSaver = listSaver<TargetNutrient.Draft, String>(
    save = { listOf(it.nutrient, it.otherName, it.percent, it.target, it.perVine.toString(), it.analysisBasis, it.concentrationBasis, it.density, it.densityReference) },
    restore = { TargetNutrient.Draft(it[0], it[1], it[2], it[3], it[4].toBoolean(), it[5], it[6], it[7], it[8]) },
)

@Composable
private fun NutrientField(label: String, value: String, onChange: (String) -> Unit, numeric: Boolean = true, tag: String = label) {
    OutlinedTextField(value, onChange, label = { Text(label) }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = if (numeric) KeyboardType.Decimal else KeyboardType.Text), modifier = Modifier.fillMaxWidth().testTag(tag))
}

@Composable
private fun NutrientChoice(label: String, value: String, options: List<Pair<String, String>>, onChange: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.fillMaxWidth().testTag("nutrient.choice.$label")) { Text("$label: ${options.firstOrNull { it.first == value }?.second ?: value}") }
        DropdownMenu(expanded, { expanded = false }) { options.forEach { (key, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { onChange(key); expanded = false }) } }
    }
}

@Composable
private fun NutrientMetric(label: String, value: String, tag: String) {
    Column { Text(label, style = MaterialTheme.typography.labelMedium); Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, modifier = Modifier.testTag(tag)) }
}
private fun nutrientNumber(value: Double): String = String.format(Locale.getDefault(), "%.3f", value).trimEnd('0').trimEnd('.', ',')
