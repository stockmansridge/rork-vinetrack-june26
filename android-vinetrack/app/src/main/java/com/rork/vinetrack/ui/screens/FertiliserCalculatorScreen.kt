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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.FertiliserStore
import com.rork.vinetrack.data.model.FertiliserCalc
import com.rork.vinetrack.data.model.FertiliserCategories
import com.rork.vinetrack.data.model.FertiliserProduct
import com.rork.vinetrack.data.model.FertiliserRecord
import com.rork.vinetrack.data.model.Paddock
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
 * cost and inventory maths, a saved product library, and planned/completed
 * application records.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FertiliserCalculatorScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { FertiliserStore(context) }
    val vineyardId = state.selectedVineyardId

    var products by remember(vineyardId) {
        mutableStateOf(vineyardId?.let { store.loadProducts(it) } ?: emptyList())
    }
    var records by remember(vineyardId) {
        mutableStateOf(vineyardId?.let { store.loadRecords(it) } ?: emptyList())
    }
    var tab by rememberSaveable { mutableStateOf(0) }
    var editingProduct by remember { mutableStateOf<FertiliserProduct?>(null) }
    var showAddProduct by remember { mutableStateOf(false) }

    val paddocks = remember(state.paddocks) { state.paddocks.sortedBy { it.name.lowercase() } }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Fertiliser Calculator") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    if (tab == 1) {
                        IconButton(onClick = { showAddProduct = true }) {
                            Icon(Icons.Filled.Add, contentDescription = "Add product", tint = vine.textPrimary)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            FertTabBar(tab) { tab = it }
            when (tab) {
                0 -> FertCalculatorTab(
                    paddocks = paddocks,
                    products = products,
                    vineyardId = vineyardId,
                    onSaveRecord = { record ->
                        vineyardId?.let { records = store.addRecord(it, record) }
                    },
                )
                1 -> FertProductsTab(
                    products = products,
                    onEdit = { editingProduct = it },
                    onAdd = { showAddProduct = true },
                )
                else -> FertRecordsTab(
                    records = records,
                    onMarkCompleted = { id ->
                        vineyardId?.let { records = store.markCompleted(it, id, LocalDate.now().toString()) }
                    },
                    onDelete = { id ->
                        vineyardId?.let { records = store.deleteRecord(it, id) }
                    },
                )
            }
        }
    }

    if (showAddProduct || editingProduct != null) {
        FertProductEditorSheet(
            vineyardId = vineyardId,
            existing = editingProduct,
            onDismiss = {
                showAddProduct = false
                editingProduct = null
            },
            onSave = { product ->
                vineyardId?.let { products = store.upsertProduct(it, product) }
                showAddProduct = false
                editingProduct = null
            },
            onDelete = { productId ->
                vineyardId?.let { products = store.deleteProduct(it, productId) }
                showAddProduct = false
                editingProduct = null
            },
        )
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
    val tabs = listOf("Calculator", "Products", "Records")
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
    products: List<FertiliserProduct>,
    vineyardId: String?,
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
    var manualName by rememberSaveable { mutableStateOf("") }
    var manualLiquid by rememberSaveable { mutableStateOf(false) }
    var manualPackText by rememberSaveable { mutableStateOf("25") }
    var manualPriceText by rememberSaveable { mutableStateOf("") }
    var savedBanner by remember { mutableStateOf<String?>(null) }

    val selectedProduct = products.firstOrNull { it.id == selectedProductId }
    val isLiquid = selectedProduct?.isLiquid ?: manualLiquid
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
    val remainingAfter = if (total != null && selectedProduct?.inventoryPacks != null) {
        selectedProduct.inventoryPacks * selectedProduct.packSize - total
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
                    Text("Product", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    FertProductPicker(products, selectedProductId) { selectedProductId = it }
                    if (selectedProduct != null) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(FertiliserCategories.label(selectedProduct.category), fontSize = 12.sp, color = vine.textSecondary)
                            val parts = mutableListOf("Pack: ${fertFmt(selectedProduct.packSize)} ${selectedProduct.unit}")
                            selectedProduct.pricePerPack?.let { parts.add("${money(it)}/pack") }
                            selectedProduct.analysisSummary?.let { parts.add(it) }
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
    products: List<FertiliserProduct>,
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
                selected?.name ?: "Manual entry",
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
                    text = { Text(product.name) },
                    onClick = {
                        onSelect(product.id)
                        expanded = false
                    },
                )
            }
        }
    }
}

// MARK: - Products tab

@Composable
private fun FertProductsTab(
    products: List<FertiliserProduct>,
    onEdit: (FertiliserProduct) -> Unit,
    onAdd: () -> Unit,
) {
    val vine = LocalVineColors.current
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "dev") { FertDevBanner() }
        if (products.isEmpty()) {
            item(key = "empty") {
                FertCard {
                    Column(
                        modifier = Modifier.padding(24.dp).fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Filled.Grain, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(32.dp))
                        Text("No products yet", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        Text(
                            "Save compost, pelletised fertiliser, foliar nutrition and other products with pack sizes, prices and nutrient analysis.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                            textAlign = TextAlign.Center,
                        )
                        Button(onClick = onAdd, colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary)) {
                            Text("Add Product")
                        }
                    }
                }
            }
        } else {
            items(products.size, key = { products[it].id }) { index ->
                val product = products[index]
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(vine.cardBackground)
                        .clickable { onEdit(product) }
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(product.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        if (product.organicCertified) {
                            Text(
                                "Organic",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.LeafGreen,
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(VineColors.LeafGreen.copy(alpha = 0.12f))
                                    .padding(horizontal = 7.dp, vertical = 3.dp),
                            )
                        }
                    }
                    val subtitle = buildList {
                        add(FertiliserCategories.label(product.category))
                        if (product.manufacturer.isNotBlank()) add(product.manufacturer)
                    }.joinToString(" · ")
                    Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
                    val detail = buildList {
                        add("${fertFmt(product.packSize)} ${product.unit}")
                        product.pricePerPack?.let { add(money(it)) }
                        product.analysisSummary?.let { add(it) }
                        product.inventoryPacks?.let { add("${fertFmt(it, 1)} packs on hand") }
                    }.joinToString(" · ")
                    Text(detail, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
        }
        item(key = "bottom-space") { Spacer(Modifier.height(24.dp)) }
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

// MARK: - Product editor

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FertProductEditorSheet(
    vineyardId: String?,
    existing: FertiliserProduct?,
    onDismiss: () -> Unit,
    onSave: (FertiliserProduct) -> Unit,
    onDelete: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var manufacturer by remember { mutableStateOf(existing?.manufacturer ?: "") }
    var isLiquid by remember { mutableStateOf(existing?.isLiquid ?: false) }
    var category by remember { mutableStateOf(existing?.category ?: "conventional") }
    var packText by remember { mutableStateOf(existing?.packSize?.let { fertFmt(it) } ?: "25") }
    var priceText by remember { mutableStateOf(existing?.pricePerPack?.let { fertFmt(it) } ?: "") }
    var densityText by remember { mutableStateOf(existing?.density?.let { fertFmt(it) } ?: "") }
    var nText by remember { mutableStateOf(existing?.nitrogenPercent?.let { fertFmt(it) } ?: "") }
    var pText by remember { mutableStateOf(existing?.phosphorusPercent?.let { fertFmt(it) } ?: "") }
    var kText by remember { mutableStateOf(existing?.potassiumPercent?.let { fertFmt(it) } ?: "") }
    var oxideBasis by remember { mutableStateOf(existing?.analysisBasis == "oxide") }
    var organic by remember { mutableStateOf(existing?.organicCertified ?: false) }
    var inventoryText by remember { mutableStateOf(existing?.inventoryPacks?.let { fertFmt(it, 1) } ?: "") }
    var notes by remember { mutableStateOf(existing?.applicationNotes ?: "") }
    var categoryExpanded by remember { mutableStateOf(false) }

    val unit = if (isLiquid) "L" else "kg"

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.appBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                if (existing == null) "New Product" else "Edit Product",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Product name") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            OutlinedTextField(
                value = manufacturer,
                onValueChange = { manufacturer = it },
                label = { Text("Manufacturer") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )

            Box {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(vine.cardBackground)
                        .clickable { categoryExpanded = true }
                        .padding(horizontal = 12.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Category", fontSize = 14.sp, color = vine.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Text(
                        FertiliserCategories.label(category),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Primary,
                    )
                }
                DropdownMenu(expanded = categoryExpanded, onDismissRequest = { categoryExpanded = false }) {
                    FertiliserCategories.all.forEach { (key, label) ->
                        DropdownMenuItem(
                            text = { Text(label) },
                            onClick = {
                                category = key
                                categoryExpanded = false
                            },
                        )
                    }
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Liquid product", fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                Switch(checked = isLiquid, onCheckedChange = { isLiquid = it })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Organic certified", fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                Switch(checked = organic, onCheckedChange = { organic = it })
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = packText,
                    onValueChange = { packText = it },
                    label = { Text("Pack size ($unit)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = priceText,
                    onValueChange = { priceText = it },
                    label = { Text("Price per pack ($)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (isLiquid) {
                    OutlinedTextField(
                        value = densityText,
                        onValueChange = { densityText = it },
                        label = { Text("Density (kg/L)") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                    )
                }
                OutlinedTextField(
                    value = inventoryText,
                    onValueChange = { inventoryText = it },
                    label = { Text("Stock on hand (packs)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
            }

            Text("Nutrient analysis (%)", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = nText,
                    onValueChange = { nText = it },
                    label = { Text("N") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = pText,
                    onValueChange = { pText = it },
                    label = { Text("P") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = kText,
                    onValueChange = { kText = it },
                    label = { Text("K") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Oxide label values (P₂O₅ / K₂O)", fontSize = 14.sp, color = vine.textPrimary)
                    Text(
                        "Record which basis the label uses — mixing them up causes major rate errors.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
                Switch(checked = oxideBasis, onCheckedChange = { oxideBasis = it })
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Application notes (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )

            Button(
                onClick = {
                    val vid = vineyardId ?: existing?.vineyardId ?: return@Button
                    onSave(
                        FertiliserProduct(
                            id = existing?.id ?: UUID.randomUUID().toString(),
                            vineyardId = vid,
                            name = name.trim(),
                            manufacturer = manufacturer.trim(),
                            form = if (isLiquid) "liquid" else "solid",
                            category = category,
                            packSize = packText.replace(',', '.').toDoubleOrNull() ?: 25.0,
                            pricePerPack = priceText.replace(',', '.').toDoubleOrNull(),
                            density = densityText.replace(',', '.').toDoubleOrNull(),
                            nitrogenPercent = nText.replace(',', '.').toDoubleOrNull(),
                            phosphorusPercent = pText.replace(',', '.').toDoubleOrNull(),
                            potassiumPercent = kText.replace(',', '.').toDoubleOrNull(),
                            analysisBasis = if (oxideBasis) "oxide" else "elemental",
                            organicCertified = organic,
                            applicationNotes = notes.trim(),
                            inventoryPacks = inventoryText.replace(',', '.').toDoubleOrNull(),
                        )
                    )
                },
                enabled = name.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Save", fontWeight = FontWeight.SemiBold)
            }

            if (existing != null) {
                OutlinedButton(
                    onClick = { onDelete(existing.id) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Delete Product", color = VineColors.Destructive)
                }
            }
        }
    }
}
