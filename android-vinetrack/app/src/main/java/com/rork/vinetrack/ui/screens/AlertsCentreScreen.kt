package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.BorderStroke
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Coronavirus
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.SyncProblem
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.AlertsRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.AlertAction
import com.rork.vinetrack.data.model.AlertSeverity
import com.rork.vinetrack.data.model.AlertType
import com.rork.vinetrack.data.model.AlertWithStatus
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * Android parity for the iOS `AlertsCentreView`. Shows the live list of active
 * vineyard alerts with severity icons, source badges, read/unread state, swipe-
 * free dismiss, mark-all-read, pull-to-refresh and tap-to-navigate. A gear
 * action opens the alert preferences editor; an info button explains alerts.
 *
 * Generation runs on the iOS client into the shared Supabase tables, so this
 * surfaces any alerts the team has produced.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlertsCentreScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenTool: (ToolRoute) -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val repo = remember { AlertsRepository(SessionStore(context)) }
    val canChangeSettings = state.currentRole == "owner" || state.currentRole == "manager"

    var alerts by remember { mutableStateOf<List<AlertWithStatus>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var lastChecked by remember { mutableStateOf<String?>(null) }
    var showInfo by remember { mutableStateOf(false) }

    suspend fun refresh() {
        val vid = state.selectedVineyardId ?: run {
            alerts = emptyList(); isLoading = false; return
        }
        errorMessage = null
        try {
            alerts = repo.fetchActiveAlerts(vid)
            lastChecked = nowShortTime()
        } catch (e: Exception) {
            errorMessage = e.message ?: "Couldn't load alerts."
        } finally {
            isLoading = false
        }
    }

    LaunchedEffect(state.selectedVineyardId) {
        isLoading = true
        refresh()
    }

    val unreadCount = alerts.count { !it.isRead }

    fun handleAction(item: AlertWithStatus) {
        scope.launch { repo.markStatus(item.id, read = true, dismissed = null) }
        alerts = alerts.map {
            if (it.id == item.id && !it.isRead) {
                it.copy(status = (it.status ?: com.rork.vinetrack.data.model.BackendAlertUserStatus(it.id)).copy(readAt = nowIso()))
            } else it
        }
        when (item.alert.typedAction) {
            AlertAction.OpenWorkTasks -> onOpenTool(ToolRoute.WorkTasks)
            AlertAction.OpenPaddocks -> onOpenTool(ToolRoute.Blocks)
            AlertAction.OpenIrrigationAdvisor, AlertAction.OpenWeather -> onOpenTool(ToolRoute.Irrigation)
            AlertAction.OpenDiseaseRisk -> onOpenTool(ToolRoute.DiseaseRisk)
            AlertAction.OpenCostReports -> onOpenTool(ToolRoute.CostReports)
            AlertAction.OpenPins -> onOpenTool(ToolRoute.Pins)
            AlertAction.OpenSprayProgram, AlertAction.OpenSprayRecord -> onOpenTool(ToolRoute.Spray)
            null -> Unit
        }
    }

    fun dismiss(item: AlertWithStatus) {
        scope.launch { repo.markStatus(item.id, read = null, dismissed = true) }
        alerts = alerts.filterNot { it.id == item.id }
    }

    fun markAllRead() {
        val unread = alerts.filter { !it.isRead }
        scope.launch { unread.forEach { repo.markStatus(it.id, read = true, dismissed = null) } }
        alerts = alerts.map {
            if (!it.isRead) it.copy(status = (it.status ?: com.rork.vinetrack.data.model.BackendAlertUserStatus(it.id)).copy(readAt = nowIso()))
            else it
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Alerts") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    IconButton(onClick = { showInfo = true }) {
                        Icon(Icons.Filled.Info, contentDescription = "About alerts")
                    }
                    IconButton(onClick = { scope.launch { refresh() } }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                    if (canChangeSettings) {
                        IconButton(onClick = onOpenSettings) {
                            Icon(Icons.Filled.Settings, contentDescription = "Alert settings")
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                alerts.isEmpty() -> EmptyAlertsState(lastChecked, errorMessage)
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    item {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(bottom = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "Active alerts (${alerts.size})",
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textSecondary,
                                modifier = Modifier.weight(1f),
                            )
                            if (unreadCount > 0) {
                                TextButton(onClick = { markAllRead() }) { Text("Mark all read") }
                            }
                        }
                    }
                    items(alerts, key = { it.id }) { item ->
                        AlertCard(item, onTap = { handleAction(item) }, onDismiss = { dismiss(item) })
                    }
                    lastChecked?.let { lc ->
                        item { LastCheckedRow(lc) }
                    }
                    errorMessage?.let { msg ->
                        item {
                            Text(msg, fontSize = 12.sp, color = VineColors.Destructive, modifier = Modifier.padding(top = 4.dp))
                        }
                    }
                }
            }
        }
    }

    if (showInfo) {
        AlertsInfoDialog(onDismiss = { showInfo = false })
    }
}

@Composable
private fun EmptyAlertsState(lastChecked: String?, errorMessage: String?) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = VineColors.LeafGreen,
            modifier = Modifier.size(48.dp),
        )
        Spacer(Modifier.size(12.dp))
        Text("Your vineyard is up to date", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        Spacer(Modifier.size(6.dp))
        Text(
            "We'll flag irrigation needs, aged pins, spray jobs and weather risks here.",
            fontSize = 13.sp,
            color = vine.textSecondary,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        errorMessage?.let {
            Spacer(Modifier.size(16.dp))
            Text(it, fontSize = 12.sp, color = VineColors.Destructive)
        }
        lastChecked?.let {
            Spacer(Modifier.size(16.dp))
            Text("Last checked $it", fontSize = 11.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun LastCheckedRow(lastChecked: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Refresh, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(13.dp))
        Spacer(Modifier.size(6.dp))
        Text("Last checked $lastChecked", fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun AlertCard(item: AlertWithStatus, onTap: () -> Unit, onDismiss: () -> Unit) {
    val vine = LocalVineColors.current
    val severityColor = severityColor(item.alert.typedSeverity)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground)
            .border(BorderStroke(0.5.dp, vine.cardBorder), RoundedCornerShape(14.dp))
            .clickable { onTap() }
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(severityColor.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(severityIcon(item.alert.typedAlertType), contentDescription = null, tint = severityColor, modifier = Modifier.size(20.dp))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    item.alert.title,
                    fontSize = 15.sp,
                    fontWeight = if (item.isRead) FontWeight.Normal else FontWeight.SemiBold,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (!item.isRead) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(VineColors.Info))
                }
            }
            Text(item.alert.message, fontSize = 13.sp, color = vine.textSecondary)
            sourceBadge(item.alert.typedAlertType, item.alert.message)?.let { badge ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(vine.textSecondary.copy(alpha = 0.12f))
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                ) {
                    Text(badge, fontSize = 11.sp, color = vine.textSecondary)
                }
            }
            actionLabel(item.alert.typedAction)?.let { label ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, tint = severityColor, modifier = Modifier.size(12.dp))
                    Text(label, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = severityColor)
                }
            }
        }
        IconButton(onClick = onDismiss, modifier = Modifier.size(28.dp)) {
            Icon(Icons.Filled.Close, contentDescription = "Dismiss", tint = vine.textSecondary, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun AlertsInfoDialog(onDismiss: () -> Unit) {
    val vine = LocalVineColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("About alerts") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text("What shows up here", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                AlertsInfoRow(Icons.Filled.WaterDrop, VineColors.Info, "Rain forecast", "Days within your forecast window where forecast rainfall meets the rain threshold.")
                AlertsInfoRow(Icons.Filled.Grain, VineColors.Info, "Rain recorded today", "Today's recorded rainfall (from your station, persisted daily row, or forecast fallback) meets the rain threshold.")
                AlertsInfoRow(Icons.Filled.Thunderstorm, VineColors.Info, "Rain started / recorded", "Rain currently falling at your station, plus a 9 AM summary of the past 24 hours.")
                AlertsInfoRow(Icons.Filled.Air, VineColors.Cyan, "Wind, frost & heat", "Forecast days exceeding your wind, low-temperature (frost) or high-temperature (heat) thresholds.")
                AlertsInfoRow(Icons.Filled.WaterDrop, VineColors.Cyan, "Irrigation", "When the forecast water deficit over the next few days exceeds your irrigation threshold.")
                AlertsInfoRow(Icons.Filled.Coronavirus, VineColors.LeafGreen, "Disease risk", "Downy mildew, powdery mildew and botrytis assessments based on hourly weather and (when available) measured leaf wetness.")
                AlertsInfoRow(Icons.Filled.LocationOn, VineColors.Orange, "Aged pins", "Unresolved pins older than your aged-pin threshold.")
                AlertsInfoRow(Icons.Filled.Groups, VineColors.Indigo, "Overdue work tasks", "Work tasks past their scheduled date that haven't been archived or finalised.")
                AlertsInfoRow(Icons.Filled.AutoAwesome, VineColors.Purple, "Spray jobs due", "Spray records scheduled for today or tomorrow.")

                Spacer(Modifier.size(2.dp))
                Text("How it works", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                AlertsInfoNote(Icons.Filled.Sync, "Alerts are generated automatically when the app refreshes for the selected vineyard.")
                AlertsInfoNote(Icons.Filled.Tune, "Thresholds and which alert types are enabled live in Settings → Alerts.")
                AlertsInfoNote(Icons.Filled.CalendarToday, "Each day with risks gets its own alert so future rain or weather shows up before it happens.")
                AlertsInfoNote(Icons.Filled.CheckCircle, "“All clear” means no enabled rule currently meets its threshold for this vineyard.")
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun AlertsInfoRow(icon: ImageVector, tint: Color, title: String, detail: String) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(detail, fontSize = 12.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun AlertsInfoNote(icon: ImageVector, text: String) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
        Text(text, fontSize = 13.sp, color = vine.textSecondary)
    }
}

private fun severityColor(severity: AlertSeverity): Color = when (severity) {
    AlertSeverity.Info -> VineColors.Info
    AlertSeverity.Warning -> VineColors.Warning
    AlertSeverity.Critical -> VineColors.Destructive
}

private fun severityIcon(type: AlertType?): ImageVector = when (type) {
    AlertType.IrrigationNeeded -> Icons.Filled.WaterDrop
    AlertType.AgedPins, AlertType.ManyOpenPins -> Icons.Filled.LocationOn
    AlertType.WeatherRisk -> Icons.Filled.WbSunny
    AlertType.SprayJobDue -> Icons.Filled.WaterDrop
    AlertType.SyncIssue -> Icons.Filled.SyncProblem
    AlertType.DiseaseDownyMildew, AlertType.DiseasePowderyMildew, AlertType.DiseaseBotrytis -> Icons.Filled.Coronavirus
    AlertType.RainStarted, AlertType.Rain24hSummary, AlertType.RainTodayThresholdExceeded -> Icons.Filled.Grain
    AlertType.WorkTaskOverdue -> Icons.Filled.Assignment
    AlertType.ForecastSetupMissingGeometry -> Icons.Filled.Map
    AlertType.CostingSetupIncomplete -> Icons.Filled.Payments
    null -> Icons.Filled.Notifications
}

private fun sourceBadge(type: AlertType?, message: String): String? {
    val msg = message.lowercase()
    return when (type) {
        AlertType.DiseaseDownyMildew, AlertType.DiseaseBotrytis ->
            if (msg.contains("measured leaf wetness") && !msg.contains("no measured")) "Measured wetness"
            else "Estimated wetness"
        AlertType.DiseasePowderyMildew -> "Temp + RH model"
        else -> null
    }
}

private fun actionLabel(action: AlertAction?): String? = when (action) {
    AlertAction.OpenIrrigationAdvisor -> "Open Irrigation Advisor"
    AlertAction.OpenWeather -> "Open Weather"
    AlertAction.OpenPins -> "View Pins"
    AlertAction.OpenSprayProgram -> "Open Spray Program"
    AlertAction.OpenSprayRecord -> "Open Spray Record"
    AlertAction.OpenDiseaseRisk -> "Open Disease Risk"
    AlertAction.OpenWorkTasks -> "Open Work Tasks"
    AlertAction.OpenPaddocks -> "Open Blocks"
    AlertAction.OpenCostReports -> "Open Cost Reports"
    null -> null
}

private fun nowIso(): String = java.time.Instant.now().toString()

private fun nowShortTime(): String =
    java.time.LocalTime.now().format(java.time.format.DateTimeFormatter.ofPattern("h:mm a"))
