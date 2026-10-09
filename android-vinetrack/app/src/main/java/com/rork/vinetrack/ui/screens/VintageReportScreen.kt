package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.rork.vinetrack.data.insights.VintageReportExport
import com.rork.vinetrack.data.insights.VintageReportViewModel
import com.rork.vinetrack.data.VintageResolver
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import kotlinx.coroutines.launch
import java.time.LocalDate

/** Native preview workspace; old saved content stays visible through request failures. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VintageReportScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: () -> Unit) {
    val context = LocalContext.current
    val account = state.currentUserId ?: return
    val vineyard = state.selectedVineyardId ?: return
    var vintage by rememberSaveable(account, vineyard) { mutableStateOf(VintageResolver.vintageYear(LocalDate.now(state.seasonZone), state.seasonStartMonth, state.seasonStartDay)) }
    val key = "$account/$vineyard/$vintage"
    val activeVintage = rememberUpdatedState(vintage)
    val reportVM: VintageReportViewModel = viewModel(key = key, factory = object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            val capturedVintage = vintage
            return VintageReportViewModel(context.applicationContext, account, vineyard, capturedVintage) {
                activeVintage.value == capturedVintage && vm.canUseVintageReport(account, vineyard)
            } as T
        }
    })
    val report by reportVM.ui.collectAsStateWithLifecycle()
    var through by rememberSaveable(key) { mutableStateOf("") }
    var selected by rememberSaveable(key) { mutableStateOf<String?>(null) }
    var editing by rememberSaveable(key) { mutableStateOf(false) }
    var narrative by rememberSaveable(key) { mutableStateOf("") }
    var editingRevisionID by rememberSaveable(key) { mutableStateOf<String?>(null) }
    var proposedAction by remember(key) { mutableStateOf<String?>(null) }
    var confirm by remember(key) { mutableStateOf(false) }
    var syncBusy by remember(key) { mutableStateOf(false) }
    var error by remember(key) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val revision = if (selected != null) report.cache.revisions.firstOrNull { it.id == selected } else report.current
    LaunchedEffect(key) { reportVM.refresh() }
    LaunchedEffect(key, report.cache.coverage?.report_through) { report.cache.coverage?.report_through?.let { through = it } }
    fun syncThenConfirm(action: String) {
        if (syncBusy || report.busy) return
        proposedAction = action; syncBusy = true
        scope.launch {
            try { vm.prepareVintageReportEvidence(account, vineyard) }
            catch (_: Exception) { error = "Sync did not finish. Unsynced records will not be included." }
            finally {
                syncBusy = false
                if (vm.canUseVintageReport(account, vineyard)) confirm = true
            }
        }
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false }, title = { Text("Generate from synced records?") },
        text = { Text(if (vm.hasPendingVintageReportEvidence(vineyard)) "This device still has pending work, possibly in another vineyard. Unsynced evidence is NOT included. Other devices' pending work cannot be detected. The previous report stays visible." else "Only synced evidence is included. Other devices' pending work is unknown. Regeneration is saved for review before confirmation as current.") },
        confirmButton = { TextButton(onClick = { confirm = false; proposedAction?.let { reportVM.submit(it, through) } }) { Text("Generate from synced records") } },
        dismissButton = { TextButton(onClick = { confirm = false; proposedAction?.let(::syncThenConfirm) }) { Text("Retry sync") } },
    )
    error?.let { message -> AlertDialog(onDismissRequest = { error = null }, title = { Text("Vintage Report") }, text = { Text(message) }, confirmButton = { TextButton(onClick = { error = null }) { Text("OK") } }) }
    Scaffold(modifier = modifier, topBar = { TopAppBar(title = { Text("Vintage Report") }, navigationIcon = { TextButton(onClick = onBack) { Text("Back") } }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("SYSTEM ADMIN PREVIEW", style = MaterialTheme.typography.labelMedium)
            Text(report.cache.coverage?.vineyard_name ?: state.selectedVineyard?.name ?: "Vineyard", style = MaterialTheme.typography.headlineSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = { if (vintage > 1900) vintage -= 1 }, enabled = !report.busy && !syncBusy) { Text("−") }
                Text("Vintage $vintage", style = MaterialTheme.typography.titleLarge)
                OutlinedButton(onClick = { if (vintage < 2200) vintage += 1 }, enabled = !report.busy && !syncBusy) { Text("+") }
            }
            report.cache.coverage?.let { coverage ->
                Text("Season ${state.regionFormatter.formatDate(coverage.season_start)} – ${state.regionFormatter.formatDate(coverage.season_end)}")
                if (coverage.not_started == true) Text("Not yet covered — this vintage has not started.")
            }
            OutlinedTextField(through, { through = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Report through (YYYY-MM-DD)") }, singleLine = true, enabled = !report.busy)
            OutlinedButton(onClick = { reportVM.updateThrough(through) }, enabled = !report.busy) { Text("Validate reporting date") }
            Text("Status: ${report.cache.request?.status ?: if (report.current == null) "Not generated" else "Saved"}")
            report.current?.let { Text("Current revision ${it.revision} • saved ${VintageReportExport.timestamp(it.created_at, state.regionFormatter)}") }
            report.history.firstOrNull { it.action != "edit" }?.let { Text("Last generated revision saved ${VintageReportExport.timestamp(it.created_at, state.regionFormatter)} (including candidates)", style = MaterialTheme.typography.bodySmall) }
            if (report.busy || syncBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
            report.message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            OutlinedButton(onClick = { reportVM.refresh() }, enabled = !report.busy) { Text("Refresh reports and coverage") }
            if (report.cache.pending != null) {
                OutlinedButton(onClick = { reportVM.recover() }, enabled = !report.busy) { Text("Recover same request / refresh status") }
                OutlinedButton(onClick = { reportVM.abandon() }, enabled = !report.busy) { Text("Safely cancel unsent / queued request") }
                if (report.cache.request?.status in listOf("succeeded", "failed", "unchanged")) {
                    OutlinedButton(onClick = { reportVM.acknowledge() }, enabled = !report.busy) { Text("Acknowledge result") }
                    Text("An uncertain paid call is never automatically repeated. Starting another request may incur another charge.", style = MaterialTheme.typography.bodySmall)
                }
            }
            Text("Generation requires connectivity. Downloaded revisions and exports remain readable offline.", style = MaterialTheme.typography.bodySmall)
            Text("Source coverage", style = MaterialTheme.typography.titleMedium)
            report.cache.coverage?.coverage?.toSortedMap()?.forEach { (name, count) -> Text("${name.replace('_', ' ')}: $count") }
            report.cache.coverage?.gaps?.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
            val generateEnabled = state.isOnline && !report.busy && !syncBusy && report.cache.pending == null && through.isNotBlank() && report.cache.coverage?.not_started != true
            Button(onClick = { syncThenConfirm(if (report.current == null) "generate" else "regenerate") }, enabled = generateEnabled, modifier = Modifier.fillMaxWidth()) { Text(if (report.current == null) "Generate Report" else "Re-generate Report") }
            OutlinedButton(onClick = { syncThenConfirm("append") }, enabled = generateEnabled && report.current != null, modifier = Modifier.fillMaxWidth()) { Text("Add to Existing Report") }
            revision?.let { saved ->
                HorizontalDivider()
                Text("Revision ${saved.revision} • ${saved.action}", style = MaterialTheme.typography.titleLarge)
                if (saved.evidence.season_to_date == true) Text("SEASON TO DATE", style = MaterialTheme.typography.labelLarge)
                if (editing) {
                    if (editingRevisionID != report.cache.currentID) {
                        Text("A newer revision is current. This draft still belongs to the revision you opened; its wording has not been replaced.", style = MaterialTheme.typography.bodySmall)
                    }
                    OutlinedTextField(narrative, { narrative = it }, modifier = Modifier.fillMaxWidth().heightIn(min = 300.dp), label = { Text("Narrative") })
                    Button(onClick = { reportVM.submit("edit", saved.report_through, narrative, editingRevisionID) }, enabled = !report.busy && report.cache.pending == null) { Text("Save as new revision") }
                    TextButton(onClick = { editing = false }) { Text("Finish review") }
                } else {
                    SelectionContainer {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            saved.content.narrative.lines().forEach { line ->
                                Text(line, style = if (line in VintageReportExport.headings) MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                    OutlinedButton(onClick = { selected = saved.id; editingRevisionID = saved.id; narrative = saved.content.narrative; editing = true }, enabled = saved.id == report.cache.currentID && report.cache.pending == null) { Text("Review / edit current narrative") }
                }
                if (saved.id != report.cache.currentID && saved.action == "regenerate") {
                    Button(onClick = { reportVM.activate(saved) }, enabled = !report.busy) { Text("Confirm regenerated revision as current") }
                }
                listOf(false to "Export PDF", true to "Export Word (.docx)").forEach { (word, label) ->
                    OutlinedButton(onClick = {
                        if (vm.canUseVintageReport(account, vineyard)) {
                            try { VintageReportExport.exportAndShare(context, saved, saved.evidence.vineyard_name ?: state.selectedVineyard?.name ?: "Vineyard", vintage, state.selectedVineyardLogo, account, word, state.regionFormatter) }
                            catch (_: Exception) { error = "Could not create or share export. Check device storage and an available PDF/Word app." }
                        }
                    }) { Text(label) }
                }
                Text("Key-event timeline", style = MaterialTheme.typography.titleMedium)
                saved.content.timeline.forEach { Text(it) }
                Text("Sources and coverage appendix", style = MaterialTheme.typography.titleMedium)
                saved.content.appendix.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
            HorizontalDivider()
            Text("Revision history", style = MaterialTheme.typography.titleMedium)
            if (selected != null && revision == null) {
                Text("Selected revision content is not downloaded.")
                TextButton(onClick = { selected?.let(reportVM::selectRevision) }, enabled = !report.busy) { Text("Download selected revision") }
            }
            report.history.forEach { saved ->
                TextButton(onClick = { selected = saved.id; editing = false; reportVM.selectRevision(saved.id) }, enabled = !report.busy) { Text("Revision ${saved.revision} • ${saved.action} • ${saved.created_at}${if (saved.id == report.cache.currentID) " • Current" else ""}") }
            }
            if (report.hasMoreHistory) TextButton(onClick = { reportVM.loadMoreHistory() }, enabled = !report.busy) { Text("Load older revision metadata") }
        }
    }
}
