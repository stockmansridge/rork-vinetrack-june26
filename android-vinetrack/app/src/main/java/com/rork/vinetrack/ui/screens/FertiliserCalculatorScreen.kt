package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.FertiliserAllocation
import com.rork.vinetrack.data.model.FertiliserCalc
import com.rork.vinetrack.data.model.FertiliserRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.ProductCategories
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.analysisSummary
import com.rork.vinetrack.data.model.fertiliserUnit
import com.rork.vinetrack.data.model.isFertiliserLiquid
import com.rork.vinetrack.data.model.isFertiliserProduct
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.UUID
import kotlin.math.abs
import kotlin.math.ceil

/**
 * Fertiliser Calculator (in development — System Admin only). Mirrors the iOS
 * `FertiliserCalculatorView`: per-hectare and per-vine planning with pack,
 * cost and inventory maths, and planned/completed application records.
 *
 * The product library is the shared saved chemical database
 * (`state.savedChemicals`, sql/111) — products are added and edited through
 * the existing Chemicals screen, not a separate fertiliser library.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FertiliserCalculatorScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onOpenProducts: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val vineyardId = state.selectedVineyardId

    var records by remember(vineyardId) {
        mutableStateOf(vineyardId?.let { vm.fertiliserRecords(it) } ?: emptyList())
    }

    // Initial fetch + reconcile when the screen opens or the vineyard changes;
    // shows the local cache instantly and merges the server state on top.
    LaunchedEffect(vineyardId, state.isOnline) {
        val id = vineyardId ?: return@LaunchedEffect
        records = vm.refreshFertiliser(id)
    }
    var tab by rememberSaveable { mutableStateOf(0) }

    val paddocks = remember(state.paddocks) { state.paddocks.sortedBy { it.name.lowercase() } }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Fertiliser Calculator") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            FertTabBar(tab) { tab = it }
            when (tab) {
                0 -> FertCalculatorTab(
                    paddocks = paddocks,
                    products = state.savedChemicals.filter { it.deletedAt == null && it.isActive },
                    vineyardId = vineyardId,
                    onOpenProducts = onOpenProducts,
                    onSaveRecord = { record ->
                        vineyardId?.let { records = vm.addFertiliserRecord(it, record) }
                    },
                )
                else -> FertRecordsTab(
                    records = records,
                    onMarkCompleted = { id ->
                        vineyardId?.let { records = vm.completeFertiliserRecord(it, id, LocalDate.now().toString()) }
                    },
                    onDelete = { id ->
                        vineyardId?.let { records = vm.deleteFertiliserRecord(it, id) }
                    },
                )
            }
        }
    }
}

// MARK: - Helpers

private fun fertFmt(value: Double, decimals: Int = 2): String {
    if (value % 1.0 == 0.0 && decimals <= 2) return value.toInt().toString()
    return "%.${decimals}f".format(value).trimEnd('0').trimEnd('.')
}

private fun money(value: Double): String = "$%.2f".format(value)

private val fertDisplayDate: DateTimeFormatter = DateTimeFormatter.ofPattern("d MMM")

@Composable
private fun FertDevBanner() {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Filled.Grain, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(13.dp))
        Text("In development — visible to System Admins only", fontSize = 12.sp, color = vine.textSecondary)
    }
}

@Composable
private fun FertCard(content: @Composable ColumnScope.() -> Unit) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground),
        content = content,
    )
}

@Composable
private fun FertTabBar(selected: Int, onSelect: (Int) -> Unit) {
    val vine = LocalVineColors.current
    val tabs = listOf("Calculator", "Records")
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        tabs.forEachIndexed { index, label ->
            val isOn = index == selected
            Text(
                label,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (isOn) Color.White else vine.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (isOn) VineColors.Primary else Color.Transparent)
                    .clickable { onSelect(index) }
                    .padding(vertical = 8.dp),
            )
        }
    }
}

// MARK: - Calculator tab

@Composable
private fun FertCalculatorTab(
    paddocks: List<Paddock>,
    products: List<SavedChemical>,
    vineyardId: String?,
    onOpenProducts: (() -> Unit)?,
    onSaveRecord: (FertiliserRecord) -> Unit,
) {
    val vine = LocalVineColors.current

    var mode by rememberSaveable { mutableStateOf("perHectare") }
    var selectedPaddockIds by remember { mutableStateOf(setOf<String>()) }
    var areaText by rememberSaveable { mutableStateOf("") }
    var vinesText by rememberSaveable { mutableStateOf("") }
    var rateText by rememberSaveable { mutableStateOf("") }
    var labourText by rememberSaveable { mutableStateOf("") }
    var selectedProductId by rememberSaveable { mutableStateOf<String?>(null) }
    var showAllProducts by rememberSaveable { mutableStateOf(false) }
    var manualName by rememberSaveable { mutableStateOf("") }
    var manualLiquid by rememberSaveable { mutableStateOf(false) }
    var manualPackText by rememberSaveable { mutableStateOf("25") }
    var manualPriceText by rememberSaveable { mutableStateOf("") }
    var savedBanner by remember { mutableStateOf<String?>(null) }

    // Default the picker to fertiliser/nutrient categories; "Show all" (or an
    // entirely uncategorised library) surfaces every saved product.
    val sortedProducts = remember(products) { products.sortedBy { it.displayName.lowercase() } }
    val fertiliserProducts = remember(sortedProducts) { sortedProducts.filter { it.isFertiliserProduct } }
    val pickerProducts = if (showAllProducts || fertiliserProducts.isEmpty()) sortedProducts else fertiliserProducts

    val selectedProduct = sortedProducts.firstOrNull { it.id == selectedProductId }
    val isLiquid = selectedProduct?.isFertiliserLiquid ?: manualLiquid
    val unit = if (isLiquid) "L" else "kg"
    val perVineUnit = if (isLiquid) "mL" else "g"

    fun syncFromBlocks(ids: Set<String>) {
        val selected = paddocks.filter { ids.contains(it.id) }
        if (selected.isEmpty()) return
        val area = selected.sumOf { it.areaHectares }
        val vines = selected.sumOf { it.effectiveVineCount }
        if (area > 0) areaText = fertFmt(area, 2)
        if (vines > 0) vinesText = vines.toString()
    }

    // Calculation
    val rate = rateText.replace(',', '.').toDoubleOrNull() ?: 0.0
    val area = areaText.replace(',', '.').toDoubleOrNull() ?: 0.0
    val vines = vinesText.toIntOrNull() ?: 0
    val total: Double? = when {
        rate <= 0 -> null
        mode == "perHectare" && area > 0 -> FertiliserCalc.totalForPerHectare(area, rate)
        mode == "perVine" && vines > 0 -> FertiliserCalc.totalForPerVine(vines, rate)
        else -> null
    }
    val packSize = selectedProduct?.packSize ?: manualPackText.replace(',', '.').toDoubleOrNull()
    val price = selectedProduct?.pricePerPack ?: manualPriceText.replace(',', '.').toDoubleOrNull()
    val packs = if (total != null && packSize != null) FertiliserCalc.packsRequired(total, packSize) else null
    val cost = if (total != null && packSize != null) FertiliserCalc.productCost(total, packSize, price) else null
    val labour = labourText.replace(',', '.').toDoubleOrNull()
    val remainingAfter = if (total != null && selectedProduct?.inventoryQuantity != null &&
        selectedProduct.packSize != null && selectedProduct.packSize > 0
    ) {
        selectedProduct.inventoryQuantity * selectedProduct.packSize - total
    } else {
        null
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "dev") { FertDevBanner() }

        item(key = "mode") {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.cardBackground)
                    .padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                listOf("perHectare" to "Per hectare", "perVine" to "Per vine").forEach { (key, label) ->
                    val isOn = mode == key
                    Text(
                        label,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (isOn) Color.White else vine.textPrimary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (isOn) VineColors.Primary else Color.Transparent)
                            .clickable { mode = key }
                            .padding(vertical = 8.dp),
                    )
                }
            }
        }

        item(key = "blocks") {
            FertCard {
                Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Blocks", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    if (paddocks.isEmpty()) {
                        Text(
                            "No blocks yet — add blocks in Vineyard Setup, or enter the area/vines manually below.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    } else {
                        paddocks.chunked(3).forEach { rowItems ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                                rowItems.forEach { paddock ->
                                    val isOn = selectedPaddockIds.contains(paddock.id)
                                    Text(
                                        paddock.name,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        textAlign = TextAlign.Center,
                                        color = if (isOn) Color.White else vine.textPrimary,
                                        modifier = Modifier
                                            .weight(1f)
                                            .clip(CircleShape)
                                            .background(if (isOn) VineColors.Primary else vine.cardBorder.copy(alpha = 0.5f))
                                            .clickable {
                                                selectedPaddockIds = if (isOn) selectedPaddockIds - paddock.id else selectedPaddockIds + paddock.id
                                                syncFromBlocks(selectedPaddockIds)
                                            }
                                            .padding(horizontal = 10.dp, vertical = 7.dp),
                                    )
                                }
                                repeat(3 - rowItems.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                    }
                    if (mode == "perHectare") {
                        OutlinedTextField(
                            value = areaText,
                            onValueChange = { areaText = it },
                            label = { Text("Treated area (ha)") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                    } else {
                        OutlinedTextField(
                            value = vinesText,
                            onValueChange = { vinesText = it },
                            label = { Text("Number of vines") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                    }
                }
            }
        }

        item(key = "product") {
            FertCard {
                Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Product", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        if (onOpenProducts != null) {
                            Text(
                                if (sortedProducts.isEmpty()) "Add products" else "Manage",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.Primary,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable { onOpenProducts() }
                                    .padding(horizontal = 6.dp, vertical = 4.dp),
                            )
                        }
                    }
                    FertProductPicker(pickerProducts, selectedProductId) { selectedProductId = it }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "Show all saved products",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.weight(1f),
                        )
                        Switch(checked = showAllProducts, onCheckedChange = { showAllProducts = it })
                    }
                    if (selectedProduct != null) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(ProductCategories.label(selectedProduct.productCategory), fontSize = 12.sp, color = vine.textSecondary)
                                if (selectedProduct.organicCertified) {
                                    Text(
                                        "Organic",
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = VineColors.LeafGreen,
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(VineColors.LeafGreen.copy(alpha = 0.12f))
                                            .padding(horizontal = 7.dp, vertical = 2.dp),
                                    )
                                }
                            }
                            val parts = buildList {
                                val size = selectedProduct.packSize
                                if (size != null && size > 0) {
                                    add("Pack: ${fertFmt(size)} ${selectedProduct.fertiliserUnit}")
                                } else {
                                    add("No pack size saved")
                                }
                                selectedProduct.pricePerPack?.let { add("${money(it)}/pack") }
                                selectedProduct.analysisSummary?.let { add(it) }
                            }
                            Text(parts.joinToString(" · "), fontSize = 12.sp, color = vine.textSecondary)
                        }
                    } else {
                        OutlinedTextField(
                            value = manualName,
                            onValueChange = { manualName = it },
                            label = { Text("Product name") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Liquid product", fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                            Switch(checked = manualLiquid, onCheckedChange = { manualLiquid = it })
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedTextField(
                                value = manualPackText,
                                onValueChange = { manualPackText = it },
                                label = { Text("Pack size ($unit)") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                modifier = Modifier.weight(1f),
                                singleLine = true,
                            )
                            OutlinedTextField(
                                value = manualPriceText,
                                onValueChange = { manualPriceText = it },
                                label = { Text("Price per pack ($)") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                modifier = Modifier.weight(1f),
                                singleLine = true,
                            )
                        }
                    }
                }
            }
        }

        item(key = "rate") {
            FertCard {
                Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Application Rate", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(
                            value = rateText,
                            onValueChange = { rateText = it },
                            label = { Text(if (mode == "perHectare") "Rate ($unit/ha)" else "Rate ($perVineUnit/vine)") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                        )
                        OutlinedTextField(
                            value = labourText,
                            onValueChange = { labourText = it },
                            label = { Text("Labour & machinery ($)") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                        )
                    }
                }
            }
        }

        if (total != null) {
            item(key = "results") {
                FertCard {
                    Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Results", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(fertFmt(total, 1), fontSize = 32.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                            Text("$unit required", fontSize = 14.sp, color = vine.textSecondary, modifier = Modifier.padding(bottom = 5.dp))
                        }
                        if (packs != null && packSize != null) {
                            val wholePacks = packs.toInt()
                            val partial = packs - wholePacks
                            FertResultRow("Full packs", "$wholePacks")
                            FertResultRow(
                                "Partial pack",
                                if (partial > 0.001) "${fertFmt(partial * packSize, 1)} $unit (${(partial * 100).toInt()}%)" else "None",
                            )
                            FertResultRow("Packs to open", "${ceil(packs).toInt()}")
                        }
                        if (cost != null) {
                            FertResultRow("Product cost", money(cost))
                            if (area > 0) FertResultRow("Cost / ha", money(cost / area))
                            if (vines > 0) FertResultRow("Cost / vine", money(cost / vines))
                            if (labour != null) {
                                FertResultRow("Labour & machinery", money(labour))
                                FertResultRow("Total job cost", money(cost + labour))
                            }
                        }
                        if (remainingAfter != null) {
                            FertResultRow("Inventory after", "${fertFmt(remainingAfter, 1)} $unit")
                            if (remainingAfter < 0) {
                                Text(
                                    "Not enough stock on hand — short by ${fertFmt(abs(remainingAfter), 1)} $unit.",
                                    fontSize = 12.sp,
                                    color = VineColors.Warning,
                                )
                            }
                        }
                    }
                }
            }

            item(key = "save") {
                fun buildRecord(status: String): FertiliserRecord? {
                    val vid = vineyardId ?: return null
                    val selected = paddocks.filter { selectedPaddockIds.contains(it.id) }
                    // Per-block allocations: weighted by vine count (per-vine
                    // mode) or area so block-level costing stays accurate.
                    val weights = selected.map { if (mode == "perVine") it.effectiveVineCount.toDouble() else it.areaHectares }
                    val totalWeight = weights.sum()
                    val allocations = selected.mapIndexed { index, paddock ->
                        val share = if (totalWeight > 0) weights[index] / totalWeight else 1.0 / selected.size
                        FertiliserAllocation(
                            id = UUID.randomUUID().toString(),
                            paddockId = paddock.id,
                            areaHectares = paddock.areaHectares,
                            vineCount = paddock.effectiveVineCount,
                            rate = rate,
                            productRequired = total * share,
                            allocatedCost = cost?.let { it * share },
                        )
                    }
                    return FertiliserRecord(
                        id = UUID.randomUUID().toString(),
                        vineyardId = vid,
                        date = LocalDate.now().toString(),
                        status = status,
                        mode = mode,
                        productId = selectedProduct?.id,
                        productName = selectedProduct?.name ?: manualName.trim(),
                        form = if (isLiquid) "liquid" else "solid",
                        paddockIds = selected.map { it.id },
                        blockNames = selected.map { it.name },
                        areaHectares = area,
                        vineCount = vines,
                        rate = rate,
                        totalProduct = total,
                        packSize = packSize,
                        productCost = cost,
                        labourMachineryCost = labour,
                        allocations = allocations,
                        createdAtMs = System.currentTimeMillis(),
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedButton(
                            onClick = {
                                buildRecord("planned")?.let {
                                    onSaveRecord(it)
                                    savedBanner = "Saved as planned task"
                                }
                            },
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("Save as Planned Task", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                        }
                        Button(
                            onClick = {
                                buildRecord("completed")?.let {
                                    onSaveRecord(it)
                                    savedBanner = "Recorded"
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("Record as Completed", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                    savedBanner?.let {
                        Text(it, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Success)
                    }
                }
            }
        }

        item(key = "bottom-space") { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun FertResultRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row {
        Text(label, fontSize = 13.sp, color = vine.textSecondary)
        Spacer(Modifier.weight(1f))
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

@Composable
private fun FertProductPicker(
    products: List<SavedChemical>,
    selectedId: String?,
    onSelect: (String?) -> Unit,
) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }
    val selected = products.firstOrNull { it.id == selectedId }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(vine.cardBorder.copy(alpha = 0.4f))
                .clickable { expanded = true }
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Product", fontSize = 14.sp, color = vine.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(
                selected?.displayName ?: "Manual entry",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = VineColors.Primary,
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text("Manual entry") },
                onClick = {
                    onSelect(null)
                    expanded = false
                },
            )
            products.forEach { product ->
                DropdownMenuItem(
                    text = { Text(product.displayName) },
                    onClick = {
                        onSelect(product.id)
                        expanded = false
                    },
                )
            }
        }
    }
}

// MARK: - Records tab

@Composable
private fun FertRecordsTab(
    records: List<FertiliserRecord>,
    onMarkCompleted: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "dev") { FertDevBanner() }
        if (records.isEmpty()) {
            item(key = "empty") {
                FertCard {
                    Text(
                        "Saved calculations appear here as planned tasks or completed application records.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        } else {
            items(records.size, key = { records[it].id }) { index ->
                val record = records[index]
                val isCompleted = record.status == "completed"
                val statusTint = if (isCompleted) VineColors.LeafGreen else VineColors.Primary
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(vine.cardBackground)
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            record.productName.ifBlank { "Fertiliser application" },
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            if (isCompleted) "Completed" else "Planned",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = statusTint,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(statusTint.copy(alpha = 0.12f))
                                .padding(horizontal = 8.dp, vertical = 3.dp),
                        )
                    }
                    val detail = buildList {
                        com.rork.vinetrack.data.model.PruningCalculator.parseDate(record.date)?.let { add(it.format(fertDisplayDate)) }
                        add("${fertFmt(record.totalProduct, 1)} ${record.unit}")
                        add("${fertFmt(record.rate, 1)} ${record.rateUnit}")
                        record.totalCost?.let { add(money(it)) }
                    }.joinToString(" · ")
                    Text(detail, fontSize = 12.sp, color = vine.textSecondary)
                    if (record.blockNames.isNotEmpty()) {
                        Text(record.blockNames.joinToString(", "), fontSize = 12.sp, color = vine.textSecondary)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Spacer(Modifier.weight(1f))
                        if (!isCompleted) {
                            IconButton(onClick = { onMarkCompleted(record.id) }, modifier = Modifier.size(28.dp)) {
                                Icon(Icons.Filled.CheckCircle, contentDescription = "Mark completed", tint = VineColors.Success, modifier = Modifier.size(18.dp))
                            }
                        }
                        IconButton(onClick = { onDelete(record.id) }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Filled.Delete, contentDescription = "Delete record", tint = VineColors.Destructive, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
        }
        item(key = "bottom-space") { Spacer(Modifier.height(24.dp)) }
    }
}
