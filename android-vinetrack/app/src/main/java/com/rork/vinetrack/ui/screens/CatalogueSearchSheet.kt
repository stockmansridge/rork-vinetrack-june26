package com.rork.vinetrack.ui.screens

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import com.rork.vinetrack.ui.components.rememberPhotoCaptureCoordinator
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Science
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CatalogueSearchSheet(vm: AppViewModel, state: AppUiState, onDismiss: () -> Unit,
    onOpenExisting: (SavedChemical) -> Unit = {}, onSaved: (SavedChemical) -> Unit = {}, modifier: Modifier = Modifier, prefillQuery: String = "") {
    val model: CatalogueSearchViewModel = viewModel(key = "catalogue:${state.selectedVineyardId}")
    val search by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var photoError by remember { mutableStateOf<String?>(null) }
    val vineyard = state.selectedVineyardId ?: return
    val country = ChemicalRegistration.normaliseCountry(state.selectedVineyard?.country.orEmpty())
    val scrollState = rememberScrollState()
    val capture = rememberPhotoCaptureCoordinator(
        onPhoto = { uri, receipt ->
            if (uri != null && receipt != null) scope.launch {
                val bytes = runCatching {
                    if (!receipt.admitted { }) return@runCatching null
                    context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }?.let { bitmap ->
                        ByteArrayOutputStream().use { out ->
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                            out.toByteArray()
                        }
                    }
                }.getOrNull()
                if (bytes != null && receipt.admitted { }) {
                    model.discover(vineyard, country, bytes)
                    // Discovery launches asynchronously; wait for its durable
                    // vineyard-scoped job receipt, not the immediate call return.
                    val committed = withTimeoutOrNull(30_000) {
                        model.state.first { snapshot ->
                            snapshot.context?.vineyardId == vineyard &&
                                snapshot.context?.inputKind == "photo" && snapshot.context.photoPath != null
                        }
                    } != null
                    if (committed) {
                        if (!receipt.persisted()) photoError = "The search started, but camera evidence needs recovery."
                    } else photoError = "Photo discovery is unfinished. The original capture has been retained."
                } else photoError = "Camera evidence is retained or unavailable. Try again after checking your account."
            }
        },
        onError = { photoError = it },
    )
    LaunchedEffect(search.result?.text("revision_id")) {
        if (search.result != null) scrollState.animateScrollTo(scrollState.maxValue)
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            val bytes = runCatching { context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }?.let { bitmap ->
                ByteArrayOutputStream().use { out -> bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out); out.toByteArray() }
            } }.getOrNull()
            if (bytes != null) { photoError = null; model.discover(vineyard, country, bytes) }
            else photoError = "Unable to read this photo. Please choose another image."
        }
    }
    LaunchedEffect(vineyard) { model.restore(vineyard); if (prefillQuery.isNotBlank() && model.state.value.context == null) model.query(prefillQuery) }
    ModalBottomSheet(onDismissRequest = onDismiss, modifier = modifier, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(scrollState).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Chemical Search", style = MaterialTheme.typography.headlineSmall)
            OutlinedTextField(value = search.query, onValueChange = model::query, label = { Text("Product name or registration number") }, modifier = Modifier.fillMaxWidth())
            Button(onClick = { model.search(country) }, enabled = !search.busy && search.query.isNotBlank() && search.context == null,
                modifier = Modifier.fillMaxWidth()) { Text("Search Chemicals") }
            OutlinedButton(onClick = capture.takePhoto, enabled = !search.busy && search.context == null,
                modifier = Modifier.fillMaxWidth()) { Text("Take Photo of Label") }
            OutlinedButton(onClick = { picker.launch("image/*") }, enabled = !search.busy && search.context == null,
                modifier = Modifier.fillMaxWidth()) { Text("Choose Existing Photo") }
            if (search.context != null) {
                Text("Finding your product", style = MaterialTheme.typography.titleMedium)
                LinearProgressIndicator(progress = { ((search.job?.number("progress_percent") ?: 0.0) / 100).toFloat() }, modifier = Modifier.fillMaxWidth())
                Text(search.job?.text("user_message") ?: "Finding product information…")
                TextButton(onClick = model::poll) { Text("Resume discovery") }
                Text("You can close this screen. This search is saved.", style = MaterialTheme.typography.bodySmall)
                Text(search.context?.query.orEmpty(), style = MaterialTheme.typography.bodySmall)
            }
            if (search.matches.isNotEmpty()) {
                Text("Matches in the VineTrack catalogue", style = MaterialTheme.typography.titleMedium)
                search.matches.forEach { row ->
                    OutlinedCard(onClick = { model.select(row) }, enabled = search.context == null && !search.busy, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
                        Row(Modifier.padding(12.dp)) {
                            CatalogueLabel(row.text("front_label_image_path"), row.text("manufacturer_label_url"))
                            Column(Modifier.weight(1f).padding(start = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(row.text("product_name") ?: "Product", style = MaterialTheme.typography.titleSmall)
                                Text(CatalogueRow.compactManufacturer(row.text("manufacturer").orEmpty()), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text("VineTrack catalogue", style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                }
                Text("Can't find the right product?", style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = { model.discover(vineyard, country) }, enabled = !search.busy && search.context == null) { Text("Find a different product") }
            } else if (search.searched) {
                Text("We haven't seen this product before")
                Button(onClick = { model.discover(vineyard, country) }, enabled = !search.busy && search.context == null) { Text("Find this product") }
            }
            search.result?.let { result ->
                Text("Selected product — review and add", style = MaterialTheme.typography.titleMedium)
                Text(result.badge, style = MaterialTheme.typography.titleSmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CatalogueLabel(result.text("front_label_image_path"), result.text("manufacturer_label_url"))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(result.text("product_name").orEmpty(), style = MaterialTheme.typography.titleMedium)
                        Text(result.text("manufacturer").orEmpty(), style = MaterialTheme.typography.bodyMedium)
                        Text(result.groupText, style = MaterialTheme.typography.bodyMedium)
                        Text(result.targets.joinToString(" · "), style = MaterialTheme.typography.bodySmall)
                    }
                }
                listOf("per_hectare" to "Per hectare", "per_100_litres" to "Per 100 L").forEach { (key, title) ->
                    val rates = result.rateRows(key)
                    if (rates.isNotEmpty()) { Text(title, style = MaterialTheme.typography.titleSmall); rates.forEach { Text(it.rateText) } }
                }
                Button(onClick = {
                    model.add(vineyard) { saved -> vm.acceptCatalogueChemical(saved); onSaved(saved); onDismiss() }
                }, enabled = !search.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(if (search.busy) "Adding…" else "Add to Vineyard")
                }
            }
            if (search.busy) CircularProgressIndicator()
            search.error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
            photoError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            TextButton(onClick = onDismiss) { Text("Close") }
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
internal fun CatalogueLabel(path: String?, labelUrl: String?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    var image by remember(path) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(path) { image = path?.let { runCatching { CatalogueRepository(context).media(it).let { bytes -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size) } }.getOrNull() } }
    TextButton(onClick = { if (labelUrl?.startsWith("https://") == true) uriHandler.openUri(labelUrl) },
        contentPadding = PaddingValues(0.dp), shape = RoundedCornerShape(8.dp),
        modifier = modifier.size(64.dp, 82.dp).background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))) {
        image?.let { Image(it.asImageBitmap(), "Product label", Modifier.fillMaxSize()) } ?: Icon(Icons.Filled.Science, "No label image")
    }
}
