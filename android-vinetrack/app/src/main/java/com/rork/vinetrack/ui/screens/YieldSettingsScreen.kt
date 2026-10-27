package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.CurrentYieldEstimate
import com.rork.vinetrack.data.YieldBunchWeightRow
import com.rork.vinetrack.data.YieldBunchWeightsRepository
import com.rork.vinetrack.data.YieldMasterWeightRepository
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.util.Locale

private data class BunchWeightEdit(val key: String, val name: String, val block: String?, val blockName: String?, val grams: Double?)

@Composable
fun YieldSettingsScreen(state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val context = LocalContext.current
    val repository = remember { YieldBunchWeightsRepository(context) }
    val epoch by repository.session.retentionGuard.identityEpoch.collectAsState()
    val locked by repository.session.retentionGuard.state.collectAsState()
    key(state.selectedVineyardId, repository.session.userId, epoch, locked) {
        BunchWeightsContent(state, repository, locked, modifier, onBack)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BunchWeightsContent(state: AppUiState, repository: YieldBunchWeightsRepository, locked: Boolean, modifier: Modifier, onBack: (() -> Unit)?) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val vineyard = state.selectedVineyardId
    val account = remember { repository.session.retentionGuard.captureAccount(repository.session.userId) }
    fun isCurrent() = !locked && vineyard != null && repository.session.selectedVineyardId.equals(vineyard, true) &&
        account != null && repository.session.retentionGuard.isAccountCurrent(account, repository.session.userId)
    val canEdit = !locked && state.currentRole in listOf("owner", "manager", "supervisor")
    val latestCanEdit by rememberUpdatedState(canEdit)
    val plantings = remember(state.paddocks, vineyard) {
        state.paddocks.filter { it.vineyardId.equals(vineyard, true) }.flatMap { CurrentYieldEstimate.plantings(it) }
            .filter { it.key.isNotBlank() }.distinctBy { it.key }.sortedBy { it.name }
    }
    var rows by remember { mutableStateOf<List<YieldBunchWeightRow>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var expanded by remember { mutableStateOf(emptySet<String>()) }
    var edit by remember { mutableStateOf<BunchWeightEdit?>(null) }
    var deleting by remember { mutableStateOf<YieldBunchWeightRow?>(null) }
    var deleteError by remember(deleting) { mutableStateOf<String?>(null) }
    val resolver = remember { YieldMasterWeightRepository.get(context) }
    suspend fun reload(afterMutation: Boolean = false) {
        val id = vineyard ?: return
        if (!isCurrent()) return
        busy = true
        try {
            val fresh = repository.fetch(id)
            if (!isCurrent()) return
            withContext(Dispatchers.IO) { resolver.installConfirmedRows(id, state.paddocks, fresh, account ?: return@withContext) }
            if (!isCurrent()) return
            rows = fresh
            message = "Shared weights refreshed. Current estimates use these weights; historical trip evidence is unchanged."
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
          catch (_: Exception) { if (isCurrent()) message = if (afterMutation) "Change confirmed by the server, but the list could not refresh. Last confirmed list retained; refresh before making another change." else "Could not refresh. Showing only last server-confirmed weights; no offline changes are queued." }
        finally { busy = false }
    }
    LaunchedEffect(vineyard) {
        if (vineyard != null && isCurrent()) {
            val cached = repository.cached(vineyard)
            if (isCurrent()) rows = cached
            reload()
        }
    }
    Scaffold(modifier = modifier, containerColor = vine.appBackground,
        topBar = { TopAppBar(title = { Text("Bunch Weights") }, navigationIcon = { if (onBack != null) BackNavIcon(onBack) }) },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Text("Shared variety masters apply to every planted block unless a block override is set. Weights are grams per bunch; no default is assumed.")
                if (!canEdit) Text("Owners, Managers and Supervisors can change shared bunch weights.", style = MaterialTheme.typography.bodySmall)
                message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                TextButton(onClick = { scope.launch { reload() } }, enabled = !busy && isCurrent()) { Text("Refresh shared weights") }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            if (plantings.isEmpty()) item { Text("Add varieties to your planted blocks to configure bunch weights.") }
            items(plantings, key = { it.key }) { planting ->
                val master = rows?.firstOrNull { it.paddockId == null && it.varietyKey == planting.key }
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row {
                            Column(Modifier.weight(1f)) {
                                Text(planting.name, style = MaterialTheme.typography.titleMedium)
                                Text(planting.key, style = MaterialTheme.typography.labelSmall)
                                Text(master?.let { "${String.format(Locale.US, "%.1f", it.grams)} g · Variety master" } ?: if (rows == null) "Not confirmed" else "Not configured")
                            }
                            if (canEdit) TextButton(onClick = { edit = BunchWeightEdit(planting.key, planting.name, null, null, master?.grams) }, enabled = !busy && rows != null) { Text(if (master == null) "Set" else "Edit") }
                        }
                        if (master != null && canEdit) TextButton(onClick = { deleting = master }, enabled = !busy) { Text("Remove variety master") }
                        TextButton(onClick = { expanded = if (planting.key in expanded) expanded - planting.key else expanded + planting.key }) {
                            Text(if (planting.key in expanded) "Hide planted blocks & overrides" else "Planted blocks & overrides")
                        }
                        if (planting.key in expanded) state.paddocks.filter { block -> block.vineyardId.equals(vineyard, true) && CurrentYieldEstimate.plantings(block).any { it.key == planting.key } }.forEach { block ->
                            val override = rows?.firstOrNull { it.paddockId.equals(block.id, true) && it.varietyKey == planting.key }
                            HorizontalDivider()
                            Text(block.name, style = MaterialTheme.typography.titleSmall)
                            Text(override?.let { "${String.format(Locale.US, "%.1f", it.grams)} g · Block override" }
                                ?: master?.let { "${String.format(Locale.US, "%.1f", it.grams)} g · Inherited variety master" }
                                ?: if (rows == null) "Not confirmed" else "Not configured", style = MaterialTheme.typography.bodySmall)
                            if (canEdit) {
                                TextButton(onClick = { edit = BunchWeightEdit(planting.key, planting.name, block.id, block.name, override?.grams) }, enabled = !busy && rows != null) { Text(if (override == null) "Set override" else "Edit override") }
                                if (override != null) TextButton(onClick = { deleting = override }, enabled = !busy) { Text("Remove override") }
                            }
                        }
                    }
                }
            }
        }
    }
    edit?.let { target ->
        BunchWeightEditor(target, confirmed = rows?.firstOrNull { it.varietyKey == target.key && it.paddockId == target.block }?.let { "Latest confirmed: ${it.grams} g" } ?: if (rows == null) "Not confirmed" else "Not configured", onDismiss = { edit = null }, onRefresh = { reload() }, onSave = { grams ->
            check(isCurrent() && latestCanEdit) { "Vineyard or account changed" }
            repository.save(vineyard!!, target.block, target.key, target.name, grams)
            if (isCurrent()) { reload(afterMutation = true); edit = null }
        })
    }
    deleting?.let { row ->
        AlertDialog(onDismissRequest = { if (!busy) deleting = null }, title = { Text("Remove shared bunch weight?") },
            text = {
                Column {
                    Text("Removing an override restores the variety master. Without a master, the weight becomes Not configured.")
                    deleteError?.let { error ->
                        Text(error, color = MaterialTheme.colorScheme.error)
                        TextButton(enabled = !busy, onClick = { scope.launch { reload(); deleting = null } }) { Text("Refresh shared weights") }
                    }
                }
            },
            confirmButton = { TextButton(enabled = !busy && canEdit, onClick = {
                if (!isCurrent() || !latestCanEdit) return@TextButton
                scope.launch {
                    busy = true
                    try {
                        check(isCurrent() && latestCanEdit) { "Vineyard, account or permission changed" }
                        repository.remove(row)
                        if (isCurrent()) { reload(afterMutation = true); deleting = null }
                    }
                    catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                    catch (_: Exception) { if (isCurrent()) deleteError = "Removal not confirmed. Refresh before retrying; the last confirmed weights are retained." }
                    finally { busy = false }
                }
            }) { Text("Remove") } },
            dismissButton = { TextButton(enabled = !busy, onClick = { deleting = null }) { Text("Cancel") } })
    }
}

@Composable
private fun BunchWeightEditor(target: BunchWeightEdit, confirmed: String, onDismiss: () -> Unit, onRefresh: suspend () -> Unit, onSave: suspend (Double) -> Unit) {
    var input by remember(target) { mutableStateOf(target.grams?.toString() ?: "") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val grams = input.replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() && it > 0 && it <= 5000 }
    AlertDialog(onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(target.blockName ?: "Vineyard variety master") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(target.name)
                Text(confirmed, style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(value = input, onValueChange = { input = it }, label = { Text("Grams per bunch") }, enabled = !busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                Text("Enter more than 0 and at most 5,000 g.")
                error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error)
                    TextButton(enabled = !busy, onClick = { scope.launch { busy = true; try { onRefresh() } finally { busy = false } } }) {
                        Text("Refresh shared weights without discarding entry")
                    }
                }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        },
        confirmButton = { TextButton(enabled = !busy && grams != null, onClick = {
            val value = grams ?: return@TextButton
            busy = true
            scope.launch {
                try { onSave(value) }
                catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (_: Exception) { error = "Save not confirmed. Your entry is retained. Refresh before retrying; a lost response may already have been applied." }
                finally { busy = false }
            }
        }) { Text("Save") } },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancel") } })
}
