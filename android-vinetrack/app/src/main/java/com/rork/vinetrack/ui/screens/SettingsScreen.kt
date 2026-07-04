package com.rork.vinetrack.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.AdminPanelSettings
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.FactCheck
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.GppGood
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PrecisionManufacturing
import androidx.compose.material.icons.filled.PrivacyTip
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.IrrigationDefaults
import com.rork.vinetrack.data.IrrigationPrefsStore
import com.rork.vinetrack.data.MapDefaults
import com.rork.vinetrack.data.MapPrefsStore
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.MapStyle
import com.rork.vinetrack.data.model.Vineyard
import java.util.Locale
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.StatusBadge
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import coil3.compose.AsyncImage

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTool: ((ToolRoute) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val prefsStore = remember { IrrigationPrefsStore(context) }
    var irrigationDefaults by remember { mutableStateOf(prefsStore.load()) }
    var showIrrigationEditor by remember { mutableStateOf(false) }
    val mapPrefsStore = remember { MapPrefsStore(context) }
    var mapDefaults by remember { mutableStateOf(mapPrefsStore.load()) }
    var showMapEditor by remember { mutableStateOf(false) }
    val operationPrefsStore = remember { OperationPrefsStore(context) }
    var fillTimerEnabled by remember { mutableStateOf(operationPrefsStore.load().fillTimerEnabled) }
    var showDisclaimer by remember { mutableStateOf(false) }
    var showVineyardSwitcher by remember { mutableStateOf(false) }
    var showNameEditor by remember { mutableStateOf(false) }
    var detailVineyard by remember { mutableStateOf<Vineyard?>(null) }
    val supportEmail = "jonathan@stockmansridge.com.au"
    fun openUrl(url: String) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    }
    fun sendEmail(subject: String) {
        val intent = Intent(Intent.ACTION_SENDTO).apply {
            data = Uri.parse("mailto:$supportEmail")
            putExtra(Intent.EXTRA_SUBJECT, subject)
        }
        runCatching { context.startActivity(intent) }
    }
    val versionLabel = remember {
        try {
            val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
            "Version ${pkg.versionName} (${pkg.longVersionCode})"
        } catch (e: Exception) {
            "Version 1.0"
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // Account
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Account", onLight = true)
                VineyardCard {
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable { showNameEditor = true },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Box(
                            modifier = Modifier.size(48.dp).clip(CircleShape).background(VineColors.Primary.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Filled.Person, contentDescription = null, tint = VineColors.Primary)
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            val accountName = state.userDisplayName?.takeIf { it.isNotBlank() } ?: vm.displayName
                            Text(accountName ?: vm.userEmail ?: "Signed in", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            Text(
                                if (accountName != null) (vm.userEmail ?: "VineTrack account") else "Tap to add your name",
                                fontSize = 13.sp,
                                color = vine.textSecondary,
                            )
                        }
                        Icon(Icons.Filled.Edit, contentDescription = "Edit name", tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                    }
                }
            }

            // Vineyard — shows the current vineyard, with an expandable switcher.
            if (state.vineyards.isNotEmpty()) {
                val activeRole = state.currentRole?.replaceFirstChar { it.uppercase() }
                val current = state.vineyards.firstOrNull { it.id == state.selectedVineyardId }
                    ?: state.vineyards.first()
                val others = state.vineyards.filter { it.id != current.id }
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Vineyard", onLight = true)
                    VineyardCard {
                        VineyardRow(
                            vineyard = current,
                            isSelected = true,
                            isDefault = current.id == state.defaultVineyardId,
                            roleLabel = activeRole,
                            onClick = { detailVineyard = current },
                            onToggleDefault = { vm.setDefaultVineyard(current.id) },
                        )
                        if (others.isNotEmpty()) {
                            Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(vine.cardBorder))
                            if (showVineyardSwitcher) {
                                others.forEach { vineyard ->
                                    VineyardRow(
                                        vineyard = vineyard,
                                        isSelected = false,
                                        isDefault = vineyard.id == state.defaultVineyardId,
                                        roleLabel = null,
                                        onClick = {
                                            vm.selectVineyard(vineyard.id)
                                            showVineyardSwitcher = false
                                        },
                                        onToggleDefault = { vm.setDefaultVineyard(vineyard.id) },
                                    )
                                    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(vine.cardBorder))
                                }
                            }
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { showVineyardSwitcher = !showVineyardSwitcher }
                                    .padding(vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Icon(
                                    Icons.Filled.SwapVert,
                                    contentDescription = null,
                                    tint = VineColors.Info,
                                    modifier = Modifier.size(20.dp),
                                )
                                Text(
                                    if (showVineyardSwitcher) "Hide" else "Change Vineyard",
                                    color = VineColors.Info,
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                        }
                    }
                }
            }

            // Operations — mirrors the iOS Settings "Operations" section: a small
            // set of grouped hubs rather than a flat list of every setup surface.
            if (onOpenTool != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Operations", onLight = true)
                    VineyardCard {
                        PreferenceRow(
                            Icons.Filled.Grass,
                            VineColors.LeafGreen,
                            "Vineyard Setup",
                            "Blocks, Region & Growth Stages",
                            onClick = { onOpenTool(ToolRoute.Blocks) },
                        )
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.WaterDrop,
                            VineColors.Info,
                            "Spray & Equipment",
                            "Spray Management, Equipment & Tractors, Chemicals",
                            onClick = { onOpenTool(ToolRoute.SprayEquipment) },
                        )
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.Group,
                            VineColors.Info,
                            "Team Operations",
                            "Operator Categories",
                            onClick = { onOpenTool(ToolRoute.OperatorCategories) },
                        )
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.Agriculture,
                            VineColors.EarthBrown,
                            "Trip Functions",
                            "Built-ins and custom vineyard trip functions",
                            onClick = { onOpenTool(ToolRoute.TripFunctions) },
                        )
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.Tune,
                            VineColors.Orange,
                            "Operation Preferences",
                            "Season E-L, spray/tank, yield",
                            onClick = { onOpenTool(ToolRoute.OperationPreferences) },
                        )
                    }
                }
            }

            // Team — members, roles & invitations
            if (onOpenTool != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Team", onLight = true)
                    VineyardCard {
                        PreferenceRow(
                            Icons.Filled.Group,
                            VineColors.Info,
                            "Team & Access",
                            "Members, roles & invitations",
                            onClick = { onOpenTool(ToolRoute.TeamAccess) },
                        )
                    }
                }
            }

            // App preferences (placeholders for upcoming settings)
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Preferences", onLight = true)
                VineyardCard {
                    if (onOpenTool != null) {
                        PreferenceRow(
                            Icons.Filled.Tune,
                            VineColors.Indigo,
                            "Preferences",
                            "Appearance, tracking, photos & AI",
                            onClick = { onOpenTool(ToolRoute.AppPreferences) },
                        )
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.NotificationsActive,
                            VineColors.Destructive,
                            "Alerts & Notifications",
                            "Irrigation, pins, weather & spray reminders",
                            onClick = { onOpenTool(ToolRoute.Alerts) },
                        )
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.CloudQueue,
                            VineColors.Info,
                            "Weather Data & Forecasting",
                            "Forecast source, station & sensors",
                            onClick = { onOpenTool(ToolRoute.WeatherData) },
                        )
                        RowDivider(vine.cardBorder)
                    }
                    if (onOpenTool != null) {
                        PreferenceRow(
                            Icons.Filled.Straighten,
                            VineColors.Indigo,
                            "Region & Units",
                            "Country, currency & units",
                            onClick = { onOpenTool(ToolRoute.RegionUnits) },
                        )
                        RowDivider(vine.cardBorder)
                    }
                    PreferenceRow(
                        Icons.Filled.WaterDrop,
                        VineColors.Cyan,
                        "Irrigation defaults",
                        irrigationSummary(irrigationDefaults),
                        onClick = { showIrrigationEditor = true },
                    )
                    RowDivider(vine.cardBorder)
                    PreferenceRow(
                        Icons.Filled.Map,
                        VineColors.LeafGreen,
                        "Map defaults",
                        mapSummary(mapDefaults),
                        onClick = { showMapEditor = true },
                    )
                    RowDivider(vine.cardBorder)
                    PreferenceToggleRow(
                        Icons.Filled.Timer,
                        VineColors.Cyan,
                        "Tank fill timer",
                        "Show Start/Stop Fill timing on spray trips. Saved on this device only.",
                        value = fillTimerEnabled,
                        onValueChange = {
                            fillTimerEnabled = it
                            operationPrefsStore.setFillTimerEnabled(it)
                        },
                    )
                }
            }

            // Data & sync
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Data & Sync", onLight = true)
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(
                            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(VineColors.Success.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Filled.CloudDone, contentDescription = null, tint = VineColors.Success, modifier = Modifier.size(20.dp))
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Online-first", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            Text("Your data syncs live with the server while connected.", fontSize = 12.sp, color = vine.textSecondary)
                        }
                    }
                    if (onOpenTool != null) {
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.Sync,
                            VineColors.Cyan,
                            "Sync",
                            "Cloud sync for pins, paddocks & trips",
                            onClick = { onOpenTool(ToolRoute.SyncStatus) },
                        )
                        RowDivider(vine.cardBorder)
                        PreferenceRow(
                            Icons.Filled.GppGood,
                            VineColors.Success,
                            "Offline Readiness",
                            "Check this device is ready for no-service areas",
                            onClick = { onOpenTool(ToolRoute.OfflineReadiness) },
                        )
                    }
                }
            }

            // Help & Support
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Help & Support", onLight = true)
                VineyardCard {
                    PreferenceRow(
                        Icons.Filled.Email,
                        VineColors.Success,
                        "Contact Support",
                        "Send feedback, feature requests or report an issue",
                        onClick = { onOpenTool?.invoke(ToolRoute.ContactSupport) ?: sendEmail("VineTrack Support") },
                    )
                }
                Text(
                    "We read every message \u2014 your feedback shapes what we build next.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            // Account & Privacy
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Account & Privacy", onLight = true)
                VineyardCard {
                    if (onOpenTool != null) {
                        PreferenceRow(
                            Icons.Filled.Fingerprint,
                            VineColors.LeafGreen,
                            "Sign-in",
                            if (vm.biometricEnabled) "Biometric unlock enabled" else "Sign in faster with biometric unlock",
                            onClick = { onOpenTool(ToolRoute.BiometricSettings) },
                        )
                        RowDivider(vine.cardBorder)
                    }
                    PreferenceRow(
                        Icons.Filled.PrivacyTip,
                        VineColors.Info,
                        "Privacy Policy",
                        "How we handle your data",
                        onClick = { openUrl("https://vinetrack.com.au/privacy") },
                    )
                    RowDivider(vine.cardBorder)
                    PreferenceRow(
                        Icons.AutoMirrored.Filled.Article,
                        VineColors.Stone,
                        "Terms of Use (EULA)",
                        "Apple standard end-user license",
                        onClick = { openUrl("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") },
                    )
                    RowDivider(vine.cardBorder)
                    PreferenceRow(
                        Icons.Filled.WarningAmber,
                        VineColors.Warning,
                        "Disclaimer",
                        "Important usage notes",
                        onClick = { showDisclaimer = true },
                    )
                    RowDivider(vine.cardBorder)
                    PreferenceRow(
                        Icons.Filled.DeleteForever,
                        VineColors.Destructive,
                        "Request Account Deletion",
                        "Permanently remove your account",
                        onClick = { onOpenTool?.invoke(ToolRoute.DeleteAccount) ?: sendEmail("VineTrack Account Deletion Request") },
                    )
                }
            }

            // About
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("About", onLight = true)
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(
                            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(VineColors.EarthBrown.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Filled.Info, contentDescription = null, tint = VineColors.EarthBrown, modifier = Modifier.size(20.dp))
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text("VineTrack", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            Text(versionLabel, fontSize = 12.sp, color = vine.textSecondary)
                        }
                    }
                    RowDivider(vine.cardBorder)
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Backend", color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                        Text("Connected", color = VineColors.Success, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }

            // Data tools — owner/manager only. Trip Audit repairs cross-vineyard
            // trip integrity (parity with iOS AdminTripAuditView).
            val canManageData = state.currentRole == "owner" || state.currentRole == "manager"
            if (canManageData && onOpenTool != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Data Tools", onLight = true)
                    VineyardCard {
                        PreferenceRow(
                            Icons.Filled.FactCheck,
                            VineColors.Orange,
                            "Trip Audit",
                            "Find & fix trips on the wrong vineyard",
                            onClick = { onOpenTool(ToolRoute.TripAudit) },
                        )
                    }
                }
            }

            // Platform admin — only for active system_admins (RPC-gated upstream).
            if (state.isSystemAdmin && onOpenTool != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Platform", onLight = true)
                    VineyardCard {
                        PreferenceRow(
                            Icons.Filled.AdminPanelSettings,
                            VineColors.Destructive,
                            "Admin",
                            "Users, vineyards, blocks & feature flags",
                            onClick = { onOpenTool(ToolRoute.Admin) },
                        )
                    }
                }
            }

            // Sign out
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(vine.cardBackground)
                    .clickable { vm.signOut() }
                    .padding(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = null, tint = VineColors.Destructive)
                    Text("Sign Out", color = VineColors.Destructive, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    if (showNameEditor) {
        var nameSaveFailed by remember { mutableStateOf(false) }
        DisplayNameEditor(
            currentName = state.userDisplayName?.takeIf { it.isNotBlank() } ?: vm.displayName ?: "",
            saveFailed = nameSaveFailed,
            onDismiss = { showNameEditor = false },
            onSave = { newName ->
                nameSaveFailed = false
                vm.updateDisplayName(newName) { ok ->
                    if (ok) showNameEditor = false else nameSaveFailed = true
                }
            },
        )
    }

    if (showDisclaimer) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showDisclaimer = false },
            title = { Text("Disclaimer") },
            text = {
                Text(
                    "VineTrack is a record-keeping and planning aid for vineyard work. " +
                        "Spray, irrigation and growth calculations are estimates only and must be " +
                        "verified against product labels, local regulations and professional advice. " +
                        "Always follow chemical label directions and your local authority's requirements.",
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { showDisclaimer = false }) { Text("Close") }
            },
        )
    }

    if (showMapEditor) {
        MapDefaultsEditor(
            current = mapDefaults,
            onDismiss = { showMapEditor = false },
            onSave = { updated ->
                mapPrefsStore.save(updated)
                mapDefaults = updated
                showMapEditor = false
            },
            onReset = {
                mapPrefsStore.reset()
                mapDefaults = mapPrefsStore.load()
                showMapEditor = false
            },
        )
    }

    if (showIrrigationEditor) {
        IrrigationDefaultsEditor(
            current = irrigationDefaults,
            onDismiss = { showIrrigationEditor = false },
            onSave = { updated ->
                prefsStore.save(updated)
                irrigationDefaults = updated
                showIrrigationEditor = false
            },
            onReset = {
                prefsStore.reset()
                irrigationDefaults = prefsStore.load()
                showIrrigationEditor = false
            },
        )
    }

    detailVineyard?.let { vy ->
        // Keep showing the sheet only while the vineyard still exists (it may be
        // archived from within the sheet, which removes it from the list).
        if (state.vineyards.any { it.id == vy.id }) {
            VineyardDetailSheet(
                vm = vm,
                state = state,
                vineyard = vy,
                onDismiss = { detailVineyard = null },
            )
        } else {
            detailVineyard = null
        }
    }
}

private fun mapSummary(d: MapDefaults): String {
    val overlays = listOfNotNull(
        if (d.showPins) "pins" else null,
        if (d.showRowLines) "rows" else null,
        if (d.showBlockLabels) "labels" else null,
    )
    val view = if (d.overview3D) "3D" else "Top-down"
    val overlayText = if (overlays.isEmpty()) "no overlays" else overlays.joinToString(", ")
    return "${d.style.label} \u00B7 $view \u00B7 $overlayText"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MapDefaultsEditor(
    current: MapDefaults,
    onDismiss: () -> Unit,
    onSave: (MapDefaults) -> Unit,
    onReset: () -> Unit,
) {
    val vine = LocalVineColors.current
    var style by remember { mutableStateOf(current.style) }
    var overview3D by remember { mutableStateOf(current.overview3D) }
    var showPins by remember { mutableStateOf(current.showPins) }
    var showRowLines by remember { mutableStateOf(current.showRowLines) }
    var showBlockLabels by remember { mutableStateOf(current.showBlockLabels) }

    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Map Defaults") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "Used when opening the vineyard map. Saved on this device only.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                Text("Imagery", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 13.sp)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    MapStyle.entries.forEach { option ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { style = option }
                                .padding(vertical = 8.dp, horizontal = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(option.label, color = vine.textPrimary, modifier = Modifier.weight(1f))
                            if (style == option) {
                                Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Success)
                            }
                        }
                    }
                }
                MapToggleRow("3D overview by default", overview3D) { overview3D = it }
                MapToggleRow("Show pins", showPins) { showPins = it }
                MapToggleRow("Show row lines", showRowLines) { showRowLines = it }
                MapToggleRow("Show block labels", showBlockLabels) { showBlockLabels = it }
            }
        },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = {
                onSave(
                    MapDefaults(
                        style = style,
                        overview3D = overview3D,
                        showPins = showPins,
                        showRowLines = showRowLines,
                        showBlockLabels = showBlockLabels,
                    )
                )
            }) { Text("Save") }
        },
        dismissButton = {
            androidx.compose.material3.TextButton(onClick = onReset) {
                Text("Reset", color = VineColors.Destructive)
            }
        },
    )
}

@Composable
private fun MapToggleRow(label: String, value: Boolean, onValueChange: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onValueChange(!value) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = onValueChange)
    }
}

private fun irrigationSummary(d: IrrigationDefaults): String {
    fun n(v: Double): String =
        if (v == v.toLong().toDouble()) v.toLong().toString() else String.format(Locale.US, "%.2f", v).trimEnd('0').trimEnd('.')
    return "Kc ${n(d.cropCoefficientKc)} \u00B7 Eff ${n(d.irrigationEfficiencyPercent)}% \u00B7 Buffer ${n(d.soilMoistureBufferMm)} mm"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun IrrigationDefaultsEditor(
    current: IrrigationDefaults,
    onDismiss: () -> Unit,
    onSave: (IrrigationDefaults) -> Unit,
    onReset: () -> Unit,
) {
    val vine = LocalVineColors.current
    fun n(v: Double): String =
        if (v == v.toLong().toDouble()) v.toLong().toString() else String.format(Locale.US, "%.2f", v).trimEnd('0').trimEnd('.')
    fun parse(t: String, default: Double): Double = t.replace(",", ".").trim().toDoubleOrNull() ?: default

    var kc by remember { mutableStateOf(n(current.cropCoefficientKc)) }
    var efficiency by remember { mutableStateOf(n(current.irrigationEfficiencyPercent)) }
    var rainEff by remember { mutableStateOf(n(current.rainfallEffectivenessPercent)) }
    var replacement by remember { mutableStateOf(n(current.replacementPercent)) }
    var buffer by remember { mutableStateOf(n(current.soilMoistureBufferMm)) }

    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Irrigation Defaults") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    "Used as the starting parameters in the irrigation calculator. Saved on this device only.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                DefaultField("Crop Coefficient (Kc)", kc) { kc = it }
                DefaultField("Irrigation Efficiency (%)", efficiency) { efficiency = it }
                DefaultField("Rainfall Effectiveness (%)", rainEff) { rainEff = it }
                DefaultField("Replacement (%)", replacement) { replacement = it }
                DefaultField("Soil Buffer (mm)", buffer) { buffer = it }
            }
        },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = {
                onSave(
                    IrrigationDefaults(
                        cropCoefficientKc = parse(kc, 0.65),
                        irrigationEfficiencyPercent = parse(efficiency, 90.0),
                        rainfallEffectivenessPercent = parse(rainEff, 80.0),
                        replacementPercent = parse(replacement, 100.0),
                        soilMoistureBufferMm = parse(buffer, 0.0),
                    )
                )
            }) { Text("Save") }
        },
        dismissButton = {
            androidx.compose.material3.TextButton(onClick = onReset) {
                Text("Reset", color = VineColors.Destructive)
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DefaultField(label: String, value: String, onValueChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        modifier = Modifier.fillMaxWidth(),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DisplayNameEditor(
    currentName: String,
    saveFailed: Boolean,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    var name by remember { mutableStateOf(currentName) }
    val trimmed = name.trim()
    val hasChanges = trimmed.isNotEmpty() && trimmed != currentName

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Display Name") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Your name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "This name appears on records you create, such as pins, trips, and spray jobs. It syncs to all your devices.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                if (saveFailed) {
                    Text(
                        "Couldn't save your name. Check your connection and try again.",
                        fontSize = 12.sp,
                        color = VineColors.Destructive,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(trimmed) }, enabled = hasChanges) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun PreferenceRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    comingSoon: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (onClick != null) it.clickable { onClick() } else it }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        if (comingSoon) {
            StatusBadge("Soon", VineColors.Stone)
        } else if (onClick != null) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun PreferenceToggleRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    value: Boolean,
    onValueChange: (Boolean) -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onValueChange(!value) }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Switch(checked = value, onCheckedChange = onValueChange)
    }
}

@Composable
private fun RowDivider(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(color))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VineyardDetailSheet(
    vm: AppViewModel,
    state: AppUiState,
    vineyard: Vineyard,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    // Owner/manager may edit name + country; only the owner may archive.
    val canEdit = state.currentRole == "owner" || state.currentRole == "manager"
    val isOwner = state.currentRole == "owner"
    // Re-resolve the live vineyard so optimistic edits reflect immediately.
    val live = state.vineyards.firstOrNull { it.id == vineyard.id } ?: vineyard

    var country by remember(live.id) { mutableStateOf(live.country ?: "") }
    var countryMenu by remember { mutableStateOf(false) }
    var showRename by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf(live.name) }
    var showArchive by remember { mutableStateOf(false) }
    var archiveConfirm by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var showRemoveLogo by remember { mutableStateOf(false) }

    // Resolve a short-lived signed URL for the private logo so Coil can load it.
    var logoUrl by remember(live.id, live.logoPath, live.logoUpdatedAt) { mutableStateOf<String?>(null) }
    LaunchedEffect(live.id, live.logoPath, live.logoUpdatedAt) {
        logoUrl = null
        val path = live.logoPath
        if (!path.isNullOrBlank()) {
            vm.requestVineyardLogoUrl(path) { url -> logoUrl = url }
        }
    }
    val logoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) vm.uploadVineyardLogo(live.id, uri) {}
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Grass, contentDescription = null, tint = VineColors.LeafGreen) }
                Column(Modifier.weight(1f)) {
                    Text(live.name, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    Text("Vineyard info", fontSize = 13.sp, color = vine.textSecondary)
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Vineyard Logo", onLight = true)
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Box(
                            modifier = Modifier.size(64.dp).clip(RoundedCornerShape(10.dp))
                                .background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            val url = logoUrl
                            when {
                                url != null -> AsyncImage(
                                    model = url,
                                    contentDescription = "Vineyard logo",
                                    contentScale = ContentScale.Fit,
                                    modifier = Modifier.fillMaxSize(),
                                )
                                !live.logoPath.isNullOrBlank() -> CircularProgressIndicator(
                                    color = VineColors.LeafGreen, modifier = Modifier.size(22.dp),
                                )
                                else -> Icon(Icons.Filled.Grass, contentDescription = null, tint = VineColors.LeafGreen)
                            }
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                if (live.logoPath.isNullOrBlank()) "No logo" else "Logo set",
                                color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                "Logos appear on exported PDFs and reports, and sync to all members of this vineyard.",
                                color = vine.textSecondary, fontSize = 12.sp,
                            )
                        }
                        if (state.vineyardLogoBusy) {
                            CircularProgressIndicator(color = VineColors.PrimaryAccent, modifier = Modifier.size(20.dp))
                        }
                    }
                    if (canEdit) {
                        RowDivider(vine.cardBorder)
                        OutlinedButton(
                            onClick = {
                                logoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                            },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !working && !state.vineyardLogoBusy,
                        ) {
                            Icon(Icons.Filled.AddPhotoAlternate, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text(if (live.logoPath.isNullOrBlank()) "  Add Logo" else "  Change Logo")
                        }
                        if (!live.logoPath.isNullOrBlank()) {
                            TextButton(
                                onClick = { showRemoveLogo = true },
                                modifier = Modifier.fillMaxWidth(),
                                enabled = !working && !state.vineyardLogoBusy,
                            ) {
                                Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                                Text("  Remove Logo", color = VineColors.Destructive)
                            }
                        }
                    }
                }
                Text(
                    if (canEdit) "The logo is shared across everyone with access to this vineyard."
                    else "Only owners and managers can change the vineyard logo.",
                    fontSize = 12.sp, color = vine.textSecondary,
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Vineyard Info", onLight = true)
                VineyardCard {
                    InfoLine(Icons.Filled.Grass, "Name", live.name, VineColors.LeafGreen)
                    formatCreated(live.createdAt)?.let {
                        RowDivider(vine.cardBorder)
                        InfoLine(Icons.Filled.CalendarToday, "Created", it, VineColors.Cyan)
                    }
                    RowDivider(vine.cardBorder)
                    if (canEdit) {
                        ExposedDropdownMenuBox(expanded = countryMenu, onExpandedChange = { countryMenu = it }) {
                            OutlinedTextField(
                                value = country.ifBlank { "Not Set" },
                                onValueChange = {},
                                readOnly = true,
                                label = { Text("Country") },
                                leadingIcon = { Icon(Icons.Filled.Public, contentDescription = null, tint = VineColors.Indigo) },
                                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = countryMenu) },
                                modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                            )
                            ExposedDropdownMenu(expanded = countryMenu, onDismissRequest = { countryMenu = false }) {
                                DropdownMenuItem(text = { Text("Not Set") }, onClick = {
                                    countryMenu = false
                                    if (country.isNotBlank()) { country = ""; vm.updateVineyard(live.id, live.name, null) {} }
                                })
                                WINE_COUNTRIES.forEach { c ->
                                    DropdownMenuItem(text = { Text(c) }, onClick = {
                                        countryMenu = false
                                        if (c != country) { country = c; vm.updateVineyard(live.id, live.name, c) {} }
                                    })
                                }
                            }
                        }
                    } else {
                        InfoLine(Icons.Filled.Public, "Country", country.ifBlank { "Not Set" }, VineColors.Indigo)
                    }
                }
                if (country.isNotBlank()) {
                    Text(
                        "Chemical searches will prioritise products available in $country.",
                        fontSize = 12.sp, color = vine.textSecondary,
                    )
                }
            }

            if (canEdit) {
                Button(
                    onClick = { renameText = live.name; showRename = true },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
                    enabled = !working,
                ) {
                    Icon(Icons.Filled.Edit, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Rename Vineyard")
                }
            }

            if (canEdit) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = { archiveConfirm = ""; showArchive = true },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = isOwner && !working,
                    ) {
                        Icon(Icons.Filled.Archive, contentDescription = null, tint = if (isOwner) VineColors.Destructive else vine.textSecondary)
                        Text("  Archive Vineyard", color = if (isOwner) VineColors.Destructive else vine.textSecondary)
                    }
                    Text(
                        if (isOwner) "Archiving hides this vineyard for everyone. Records are kept and can be restored by support."
                        else "Only the owner can archive this vineyard.",
                        fontSize = 12.sp, color = vine.textSecondary,
                    )
                }
            }
        }
    }

    if (showRename) {
        AlertDialog(
            onDismissRequest = { showRename = false },
            title = { Text("Rename Vineyard") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    label = { Text("Vineyard name") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    enabled = renameText.trim().isNotBlank(),
                    onClick = {
                        showRename = false
                        working = true
                        vm.updateVineyard(live.id, renameText.trim(), country.ifBlank { null }) { working = false }
                    },
                ) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { showRename = false }) { Text("Cancel") } },
        )
    }

    if (showRemoveLogo) {
        AlertDialog(
            onDismissRequest = { showRemoveLogo = false },
            title = { Text("Remove Logo?") },
            text = { Text("This will remove the logo for everyone in this vineyard.") },
            confirmButton = {
                TextButton(onClick = {
                    showRemoveLogo = false
                    vm.removeVineyardLogo(live.id) {}
                }) { Text("Remove", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showRemoveLogo = false }) { Text("Cancel") } },
        )
    }

    if (showArchive) {
        AlertDialog(
            onDismissRequest = { showArchive = false },
            title = { Text("Archive Vineyard?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("This hides the vineyard for everyone with access. Type DELETE to confirm.")
                    OutlinedTextField(
                        value = archiveConfirm,
                        onValueChange = { archiveConfirm = it },
                        label = { Text("Type DELETE") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = archiveConfirm == "DELETE",
                    onClick = {
                        showArchive = false
                        working = true
                        vm.archiveVineyard(live.id) { ok -> working = false; if (ok) onDismiss() }
                    },
                ) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showArchive = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun InfoLine(icon: ImageVector, label: String, value: String, tint: Color) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(28.dp).clip(CircleShape).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp)) }
        Text(label, color = vine.textSecondary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

private val WINE_COUNTRIES: List<String> = listOf(
    "Australia", "Argentina", "Austria", "Brazil", "Canada", "Chile", "China",
    "France", "Germany", "Greece", "Hungary", "India", "Israel", "Italy",
    "Japan", "Mexico", "New Zealand", "Portugal", "Romania", "South Africa",
    "Spain", "Switzerland", "United Kingdom", "United States", "Uruguay",
)

private fun formatCreated(iso: String?): String? {
    iso ?: return null
    return try {
        val instant = java.time.Instant.parse(iso)
        val fmt = java.time.format.DateTimeFormatter.ofPattern("d MMM yyyy", Locale.getDefault())
            .withZone(java.time.ZoneId.systemDefault())
        fmt.format(instant)
    } catch (_: Exception) {
        null
    }
}

@Composable
private fun VineyardRow(
    vineyard: Vineyard,
    isSelected: Boolean,
    isDefault: Boolean,
    roleLabel: String?,
    onClick: () -> Unit,
    onToggleDefault: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Map, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(vineyard.name, color = vine.textPrimary, fontWeight = FontWeight.Medium)
                if (isSelected) {
                    Text("Active", fontSize = 11.sp, color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold)
                }
            }
            val subtitle = listOfNotNull(
                vineyard.country?.takeIf { it.isNotBlank() },
                roleLabel,
            ).joinToString(" · ")
            if (subtitle.isNotEmpty()) {
                Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
            }
            if (isDefault) {
                Text("Opens by default", fontSize = 11.sp, color = VineColors.Warning, fontWeight = FontWeight.Medium)
            }
        }
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .clickable { onToggleDefault() },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (isDefault) Icons.Filled.Star else Icons.Filled.StarBorder,
                contentDescription = if (isDefault) "Default vineyard" else "Set as default vineyard",
                tint = if (isDefault) VineColors.Warning else vine.textSecondary,
                modifier = Modifier.size(20.dp),
            )
        }
        if (isSelected) {
            Icon(Icons.Filled.Check, contentDescription = "Currently open", tint = VineColors.Success)
        } else {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}
