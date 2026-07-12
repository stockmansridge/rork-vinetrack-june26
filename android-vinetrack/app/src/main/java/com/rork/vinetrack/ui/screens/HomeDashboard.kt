package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Coronavirus
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.border
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import com.rork.vinetrack.data.AlertsRepository
import com.rork.vinetrack.data.HomePrefsStore
import com.rork.vinetrack.data.MapPrefsStore
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.AlertSeverity
import com.rork.vinetrack.data.model.AlertType
import com.rork.vinetrack.data.model.AlertWithStatus
import com.rork.vinetrack.data.model.AppNotice
import com.rork.vinetrack.data.model.AppNoticeType
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.OverviewStat
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

@Composable
fun HomeDashboard(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onOpenTab: (MainTab) -> Unit,
    onOpenTool: (ToolRoute) -> Unit,
    onOpenSetupWizard: () -> Unit,
    onOpenObservations: (String?) -> Unit,
    onOpenPinsList: () -> Unit,
) {
    var overlay by remember { mutableStateOf(HomeOverlay.None) }
    val context = LocalContext.current
    val mapDefaults = remember { MapPrefsStore(context).load() }

    AnimatedContent(
        targetState = overlay,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "home-overlay-nav",
        modifier = modifier,
    ) { current ->
        when (current) {
            HomeOverlay.Map -> VineyardMapScreen(state, defaults = mapDefaults, onBack = { overlay = HomeOverlay.Overview })
            HomeOverlay.Overview -> VineyardOverviewScreen(
                state,
                defaults = mapDefaults,
                onBack = { overlay = HomeOverlay.None },
                onOpenFullMap = { overlay = HomeOverlay.Map },
            )
            HomeOverlay.Rain -> RainAndForecastScreen(
                state,
                onBack = { overlay = HomeOverlay.None },
                onOpenWeatherSettings = {
                    overlay = HomeOverlay.None
                    onOpenTool(ToolRoute.WeatherData)
                },
            )
            HomeOverlay.None -> DashboardContent(
                vm = vm,
                state = state,
                onOpenTab = onOpenTab,
                onOpenTool = onOpenTool,
                onOpenSetupWizard = onOpenSetupWizard,
                onOpenObservations = onOpenObservations,
                onOpenPinsList = onOpenPinsList,
                onOpenMap = { overlay = HomeOverlay.Overview },
                onOpenRain = { overlay = HomeOverlay.Rain },
            )
        }
    }
}

/** Full-screen overlays reachable directly from the Home dashboard. */
private enum class HomeOverlay { None, Map, Overview, Rain }

@Composable
private fun DashboardContent(
    vm: AppViewModel,
    state: AppUiState,
    onOpenTab: (MainTab) -> Unit,
    onOpenTool: (ToolRoute) -> Unit,
    onOpenSetupWizard: () -> Unit,
    onOpenObservations: (String?) -> Unit,
    onOpenPinsList: () -> Unit,
    onOpenMap: () -> Unit,
    onOpenRain: () -> Unit,
) {
    val context = LocalContext.current
    val wizardEnabled = remember { com.rork.vinetrack.data.SetupWizardStore(context).isEnabled() }
    Box(modifier = Modifier.fillMaxSize()) {
        // Vineyard gradient backdrop
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.linearGradient(
                        listOf(VineColors.LoginTop, VineColors.LoginMid, VineColors.LoginBottom)
                    )
                )
        )
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            HeaderRow(
                vineyard = state.selectedVineyard,
                logo = state.selectedVineyardLogo,
                vineyards = state.vineyards,
                syncing = state.isLoadingVineyardData,
                onRefresh = { vm.refresh() },
                onSelectVineyard = { vm.selectVineyard(it) },
            )

            state.activeTrip?.let { active ->
                ActiveTripCard(active, onClick = { onOpenTab(MainTab.Trip) })
            }

            val canChangeSettings = state.currentRole == "owner" || state.currentRole == "manager"

            if (canChangeSettings && wizardEnabled && shouldShowSetupWizard(state)) {
                SetupWizardCard(state = state, onClick = onOpenSetupWizard)
            }

            SyncStatusCard(state, onClick = { onOpenTool(ToolRoute.SyncStatus) })

            AppNoticesBanner(state = state, onDismiss = { vm.dismissNotice(it) })

            TodaySection(
                state,
                onOpenWeather = onOpenRain,
                onOpenAlerts = { onOpenTool(ToolRoute.Alerts) },
            )

            QuickActionsSection(
                onRepairs = { onOpenObservations("Repairs") },
                onGrowth = { onOpenObservations("Growth") },
            )

            OverviewSection(state, onOpenMap)

            OperationalToolsSection(onOpenTab = onOpenTab, onOpenTool = onOpenTool)

            if (canChangeSettings) {
                ManagementSection(onOpenTool = onOpenTool)
            }

            RecentSection(state)

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun HeaderRow(
    vineyard: Vineyard?,
    logo: android.graphics.Bitmap?,
    vineyards: List<Vineyard>,
    syncing: Boolean,
    onRefresh: () -> Unit,
    onSelectVineyard: (String) -> Unit,
) {
    // The switcher is only interactive when the user belongs to more than one
    // vineyard (matches the portal rule). Single-vineyard users see a plain,
    // finished-looking header with no dropdown affordance.
    val canSwitch = vineyards.size > 1
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (logo != null) {
            Image(
                bitmap = logo.asImageBitmap(),
                contentDescription = "Vineyard logo",
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(40.dp).clip(CircleShape),
            )
        } else {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(Brush.linearGradient(listOf(VineColors.LeafGreen, VineColors.DarkGreen))),
                contentAlignment = Alignment.Center,
            ) {
                Text("\uD83C\uDF47", fontSize = 20.sp)
            }
        }
        if (canSwitch) {
            Box(modifier = Modifier.weight(1f)) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .clickable { menuOpen = true }
                        .padding(vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        vineyard?.name ?: "Select vineyard",
                        color = Color.White,
                        fontSize = 22.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    Icon(
                        Icons.Filled.ArrowDropDown,
                        contentDescription = "Switch vineyard",
                        tint = Color.White.copy(alpha = 0.9f),
                        modifier = Modifier.size(26.dp),
                    )
                }
                DropdownMenu(
                    expanded = menuOpen,
                    onDismissRequest = { menuOpen = false },
                ) {
                    vineyards.forEach { v ->
                        val isCurrent = v.id == vineyard?.id
                        DropdownMenuItem(
                            text = {
                                Text(
                                    v.name,
                                    fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            leadingIcon = {
                                if (isCurrent) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = "Current vineyard",
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(20.dp),
                                    )
                                } else {
                                    Spacer(Modifier.size(20.dp))
                                }
                            },
                            onClick = {
                                menuOpen = false
                                if (!isCurrent) onSelectVineyard(v.id)
                            },
                        )
                    }
                }
            }
        } else {
            Text(
                vineyard?.name ?: "No Vineyard",
                color = Color.White,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        SyncStatusChip(syncing = syncing, onRefresh = onRefresh)
    }
}

/** Compact iOS-style status chip: shows a spinner while syncing, otherwise a tappable Refresh pill. */
@Composable
private fun SyncStatusChip(syncing: Boolean, onRefresh: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.16f))
            .clickable(enabled = !syncing) { onRefresh() }
            .padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (syncing) {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = Color.White,
            )
            Text("Syncing", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        } else {
            Icon(Icons.Filled.Refresh, contentDescription = "Refresh", tint = Color.White, modifier = Modifier.size(15.dp))
            Text("Refresh", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun ActiveTripCard(trip: com.rork.vinetrack.data.model.Trip, onClick: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Active Trip")
        VineyardCard(modifier = Modifier.clickable { onClick() }) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(
                    modifier = Modifier.size(48.dp).clip(RoundedCornerShape(12.dp))
                        .background(VineColors.Warning.copy(alpha = 0.18f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.DirectionsCar, contentDescription = null, tint = VineColors.Warning)
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        trip.displayLabel,
                        fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                        color = LocalVineColors.current.textPrimary, maxLines = 1,
                    )
                    Text(
                        (if (trip.isPaused) "Paused" else "Recording now") +
                            (trip.paddockName?.takeIf { it.isNotBlank() }?.let { " · $it" } ?: ""),
                        fontSize = 12.sp, color = LocalVineColors.current.textSecondary,
                    )
                }
                Box(
                    modifier = Modifier.size(10.dp).clip(CircleShape)
                        .background(if (trip.isPaused) VineColors.Orange else VineColors.Warning),
                )
            }
        }
    }
}

/**
 * Home entry point to the Sync Status screen (Stage Q-1b). Read-only: it only
 * surfaces existing [AppUiState] signals (connection, pending outbox, cached
 * field data) and navigates to the existing Sync Status screen. It never
 * triggers a sync, replay, retry, or network call by rendering. Shown only when
 * there is something useful to report so it stays out of the way otherwise.
 */
@Composable
private fun SyncStatusCard(state: AppUiState, onClick: () -> Unit) {
    val offline = !state.isOnline
    val pending = state.pendingSyncCount
    val photos = state.pendingPhotoCount
    val needsAttention = state.pendingPhotoBlockedCount > 0 || state.blockedPinIds.isNotEmpty()
    val cached = state.isUsingCachedFieldData
    val hasSomethingToReport = offline || pending > 0 || photos > 0 || needsAttention || cached
    if (!hasSomethingToReport) return

    val vine = LocalVineColors.current
    val tint = when {
        needsAttention -> VineColors.Warning
        offline -> VineColors.Warning
        pending > 0 || photos > 0 -> VineColors.Info
        else -> VineColors.LeafGreen
    }
    val icon = when {
        offline -> Icons.Filled.CloudOff
        pending > 0 || photos > 0 || needsAttention -> Icons.Filled.Sync
        else -> Icons.Filled.CloudDone
    }
    val title = when {
        needsAttention -> "Some items need attention"
        offline -> "Offline"
        pending > 0 -> "$pending ${if (pending == 1) "item" else "items"} waiting to sync"
        photos > 0 -> "$photos ${if (photos == 1) "photo" else "photos"} waiting to upload"
        else -> "Showing saved field data"
    }
    val subtitle = when {
        offline -> "Some changes may wait until you reconnect"
        needsAttention || pending > 0 || photos > 0 -> "Tap to view sync status"
        else -> "Some records may be out of date until you reconnect"
    }

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Sync Status")
        VineyardCard(modifier = Modifier.clickable { onClick() }) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Box(
                    modifier = Modifier.size(48.dp).clip(RoundedCornerShape(12.dp))
                        .background(tint.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(icon, contentDescription = null, tint = tint)
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        title,
                        fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary, maxLines = 1,
                    )
                    Text(subtitle, fontSize = 12.sp, color = vine.textSecondary, maxLines = 2)
                }
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = vine.textSecondary,
                )
            }
        }
    }
}

/**
 * Active backend app notices ("system messages"), mirroring the iOS
 * `AppNoticesBanner`. A single notice renders directly; multiple notices are
 * paged horizontally (swipable) with page dots so none stack or get hidden.
 */
@Composable
private fun AppNoticesBanner(state: AppUiState, onDismiss: (String) -> Unit) {
    val notices = state.visibleNotices
    if (notices.isEmpty()) return
    if (notices.size == 1) {
        Box(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            NoticeCard(notice = notices[0], onDismiss = { onDismiss(notices[0].id) })
        }
        return
    }
    val pagerState = rememberPagerState(pageCount = { notices.size })
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // beyondViewportPageCount composes every notice up front so the pager
        // sizes itself to the TALLEST card instead of clipping longer messages
        // to the height of the first page. Shorter cards then stretch to match
        // (fillMaxHeight) so all bars look evenly sized while swiping.
        HorizontalPager(
            state = pagerState,
            contentPadding = PaddingValues(horizontal = 16.dp),
            pageSpacing = 8.dp,
            verticalAlignment = Alignment.Top,
            beyondViewportPageCount = notices.size,
        ) { page ->
            val notice = notices[page]
            NoticeCard(
                notice = notice,
                onDismiss = { onDismiss(notice.id) },
                modifier = Modifier.fillMaxHeight(),
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            repeat(notices.size) { index ->
                val selected = pagerState.currentPage == index
                Box(
                    modifier = Modifier
                        .padding(horizontal = 3.dp)
                        .size(if (selected) 8.dp else 6.dp)
                        .clip(CircleShape)
                        .background(
                            if (selected) VineColors.LeafGreen
                            else LocalVineColors.current.textSecondary.copy(alpha = 0.35f)
                        ),
                )
            }
        }
    }
}

@Composable
private fun NoticeCard(
    notice: AppNotice,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val tint = when (notice.type) {
        AppNoticeType.INFO -> VineColors.Info
        AppNoticeType.WARNING -> VineColors.Warning
        AppNoticeType.SUCCESS -> VineColors.Success
        AppNoticeType.CRITICAL -> VineColors.Destructive
    }
    val icon = when (notice.type) {
        AppNoticeType.INFO -> Icons.Filled.Info
        AppNoticeType.WARNING -> Icons.Filled.Warning
        AppNoticeType.SUCCESS -> Icons.Filled.CheckCircle
        AppNoticeType.CRITICAL -> Icons.Filled.Error
    }
    // Min height keeps short notices visually even; the bar grows when the
    // message needs more room instead of clipping it (no hard height here).
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .border(1.dp, tint.copy(alpha = 0.28f), RoundedCornerShape(12.dp))
            .padding(start = 12.dp, top = 10.dp, bottom = 10.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(tint.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(17.dp))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                notice.title,
                fontSize = 14.sp,
                lineHeight = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                notice.message,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                color = vine.textSecondary,
            )
        }
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .clickable(onClick = onDismiss),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Dismiss notice",
                tint = vine.textSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

/**
 * Whether the Home Setup Wizard prompt should be shown. Mirrors iOS: prompt the
 * owner/manager to finish onboarding until they have at least one block, one
 * tractor and one spray rig configured.
 */
private fun shouldShowSetupWizard(state: AppUiState): Boolean {
    val hasBlock = state.paddocks.isNotEmpty()
    val hasTractor = state.machines.isNotEmpty()
    val hasRig = state.sprayEquipment.isNotEmpty()
    return !(hasBlock && hasTractor && hasRig)
}

private fun setupWizardSubtitle(state: AppUiState): String {
    val remaining = buildList {
        if (state.paddocks.isEmpty()) add("block")
        if (state.machines.isEmpty()) add("tractor")
        if (state.sprayEquipment.isEmpty()) add("spray rig")
    }
    if (remaining.isEmpty()) return "All set — tap to review"
    return "Add a " + remaining.joinToString(", ") + " to get started"
}

/**
 * Onboarding prompt mirroring the iOS Home "Setup Wizard" card. Shown to
 * owners/managers until the vineyard has its essential setup (a block, a
 * tractor and a spray rig). Tapping opens Vineyard Setup.
 */
@Composable
private fun SetupWizardCard(state: AppUiState, onClick: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(
                    Brush.linearGradient(listOf(VineColors.LeafGreen, VineColors.DarkGreen))
                )
                .clickable { onClick() }
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(
                modifier = Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.22f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
            }
            Column(modifier = Modifier.weight(1f)) {
                Text("Setup Wizard", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    setupWizardSubtitle(state),
                    color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp,
                )
            }
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun TodaySection(
    state: AppUiState,
    onOpenWeather: () -> Unit,
    onOpenAlerts: () -> Unit,
) {
    val context = LocalContext.current
    val alertsRepo = remember { AlertsRepository(SessionStore(context)) }
    var alerts by remember { mutableStateOf<List<AlertWithStatus>>(emptyList()) }
    LaunchedEffect(state.selectedVineyardId) {
        val vid = state.selectedVineyardId
        alerts = if (vid == null) emptyList() else try {
            alertsRepo.fetchActiveAlerts(vid)
        } catch (_: Exception) {
            emptyList()
        }
    }
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Today")
        WeatherCard(onClick = onOpenWeather)
        if (alerts.isNotEmpty()) {
            HomeAlertsCard(alerts = alerts, onClick = onOpenAlerts)
        }
    }
}

/**
 * Home alerts summary, mirroring the iOS `HomeAlertsCard`. Shows the highest
 * active severity tint, the active/unread count and a preview of the top alert,
 * tapping into the Alerts Centre.
 */
@Composable
private fun HomeAlertsCard(alerts: List<AlertWithStatus>, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val topSeverity = alerts.maxByOrNull { it.alert.typedSeverity.rank }?.alert?.typedSeverity ?: AlertSeverity.Info
    val tint = alertSeverityColor(topSeverity)
    val unread = alerts.count { !it.isRead }
    val top = alerts.sortedByDescending { it.alert.typedSeverity.rank }.firstOrNull()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .border(BorderStroke(1.dp, tint.copy(alpha = 0.25f)), RoundedCornerShape(12.dp))
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(30.dp).clip(RoundedCornerShape(8.dp))
                .background(tint.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(alertSeverityIcon(top?.alert?.typedAlertType), contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                if (unread > 0) "$unread alert${if (unread == 1) "" else "s"} need attention"
                else "${alerts.size} active alert${if (alerts.size == 1) "" else "s"}",
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, maxLines = 1,
            )
            Text(
                top?.alert?.title ?: "Open Alerts Centre",
                fontSize = 12.sp, color = vine.textSecondary, maxLines = 1,
            )
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
    }
}

private fun alertSeverityColor(severity: AlertSeverity): Color = when (severity) {
    AlertSeverity.Info -> VineColors.Info
    AlertSeverity.Warning -> VineColors.Warning
    AlertSeverity.Critical -> VineColors.Destructive
}

private fun alertSeverityIcon(type: AlertType?): ImageVector = when (type) {
    AlertType.IrrigationNeeded -> Icons.Filled.WaterDrop
    AlertType.AgedPins, AlertType.ManyOpenPins -> Icons.Filled.LocationOn
    AlertType.WeatherRisk -> Icons.Filled.WbSunny
    AlertType.SprayJobDue -> Icons.Filled.WaterDrop
    AlertType.SyncIssue -> Icons.Filled.Sync
    AlertType.DiseaseDownyMildew, AlertType.DiseasePowderyMildew, AlertType.DiseaseBotrytis -> Icons.Filled.Coronavirus
    AlertType.RainStarted, AlertType.Rain24hSummary, AlertType.RainTodayThresholdExceeded -> Icons.Filled.WaterDrop
    AlertType.WorkTaskOverdue -> Icons.Filled.Group
    AlertType.ForecastSetupMissingGeometry, AlertType.CostingSetupIncomplete -> Icons.Filled.Warning
    null -> Icons.Filled.Info
}

/**
 * Today's Rain entry point, mirroring the iOS `HomeRainSummaryCard`. Opens the
 * Rain & Forecast page (rainfall outlook + recent rainfall history from
 * Open-Meteo).
 */
@Composable
private fun WeatherCard(onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(30.dp).clip(RoundedCornerShape(8.dp))
                .background(VineColors.Info.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Cloud, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(18.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text("Today's Rain", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, maxLines = 1)
            Text("Rainfall & 7-day forecast", fontSize = 12.sp, color = vine.textSecondary, maxLines = 1)
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun QuickActionsSection(onRepairs: () -> Unit, onGrowth: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Quick Actions")
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            QuickActionCard(
                title = "Repairs",
                icon = Icons.Filled.Build,
                colors = listOf(VineColors.Orange, VineColors.Orange.copy(alpha = 0.75f)),
                modifier = Modifier.weight(1f),
                onClick = onRepairs,
            )
            QuickActionCard(
                title = "Growth",
                icon = Icons.Filled.Grass,
                colors = listOf(VineColors.LeafGreen, VineColors.DarkGreen),
                modifier = Modifier.weight(1f),
                onClick = onGrowth,
            )
        }
    }
}

@Composable
private fun QuickActionCard(
    title: String,
    icon: ImageVector,
    colors: List<Color>,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Column(
        modifier = modifier
            .heightIn(min = 76.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Brush.linearGradient(colors))
            .clickable { onClick() }
            .padding(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Spacer(Modifier.height(4.dp))
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Spacer(Modifier.height(4.dp))
    }
}

@Composable
private fun OverviewSection(state: AppUiState, onOpenMap: () -> Unit) {
    val totalHectares = state.totalHectares
    val totalVines = state.paddocks.sumOf { it.effectiveVineCount }
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Vineyard Overview")
        VineyardCard(modifier = Modifier.clickable { onOpenMap() }) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                val logo = state.selectedVineyardLogo
                if (logo != null) {
                    Image(
                        bitmap = logo.asImageBitmap(),
                        contentDescription = "Vineyard logo",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.size(48.dp).clip(RoundedCornerShape(12.dp)),
                    )
                } else {
                    Box(
                        modifier = Modifier.size(48.dp).clip(RoundedCornerShape(12.dp))
                            .background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.Map, contentDescription = null, tint = VineColors.LeafGreen)
                    }
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        state.selectedVineyard?.name ?: "No vineyard selected",
                        fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                        color = LocalVineColors.current.textPrimary,
                    )
                    Text("View map & summary", fontSize = 12.sp, color = LocalVineColors.current.textSecondary)
                }
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = LocalVineColors.current.textSecondary)
            }
            Spacer(Modifier.height(14.dp))
            Row(modifier = Modifier.fillMaxWidth()) {
                OverviewStat("${state.paddocks.size}", "Blocks", Icons.Filled.Grass, VineColors.LeafGreen, Modifier.weight(1f))
                OverviewStat(
                    if (totalHectares >= 100) "%.0f".format(totalHectares) else "%.1f".format(totalHectares),
                    "Hectares", Icons.Filled.Map, VineColors.Orange, Modifier.weight(1f),
                )
                OverviewStat(formattedCount(totalVines), "Vines", Icons.Filled.Spa, VineColors.DarkGreen, Modifier.weight(1f))
            }
        }
    }
}

private fun formattedCount(value: Int): String =
    if (value >= 1000) "%.1fk".format(value / 1000.0) else "$value"

private data class ToolItem(
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val tint: Color,
    val comingSoon: Boolean = false,
    val onClick: (() -> Unit)? = null,
)

@Composable
private fun OperationalToolsSection(onOpenTab: (MainTab) -> Unit, onOpenTool: (ToolRoute) -> Unit) {
    val tools = listOf(
        ToolItem("Work Tasks", "Log & calculate", Icons.Filled.Group, VineColors.Indigo) { onOpenTool(ToolRoute.WorkTasks) },
        ToolItem("Maintenance Log", "Repairs & jobs", Icons.Filled.Build, VineColors.EarthBrown) { onOpenTool(ToolRoute.Maintenance) },
        ToolItem("Fuel Log", "Purchases & refuelling", Icons.Filled.LocalGasStation, VineColors.Pink) { onOpenTool(ToolRoute.FuelLog) },
        ToolItem("Irrigation Advisor", "Water planning", Icons.Filled.Opacity, VineColors.Cyan) { onOpenTool(ToolRoute.Irrigation) },
        ToolItem("Disease Risk", "Downy/Powdery/Botrytis", Icons.Filled.Coronavirus, VineColors.LeafGreen) { onOpenTool(ToolRoute.DiseaseRisk) },
        ToolItem("Yields", "Forecasting, Sampling & Recording", Icons.Filled.Scale, VineColors.Orange) { onOpenTool(ToolRoute.Yield) },
        ToolItem("Growth Stage Records", "Phenology records", Icons.Filled.Spa, VineColors.LeafGreen) { onOpenTool(ToolRoute.Growth) },
        ToolItem("Optimal Ripeness", "GDD & harvest window", Icons.Filled.Thermostat, VineColors.Orange) { onOpenTool(ToolRoute.OptimalRipeness) },
        ToolItem("Cost Reports", "Season, block & variety", Icons.Filled.Payments, VineColors.Indigo) { onOpenTool(ToolRoute.CostReports) },
    )
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Operational Tools")
        tools.chunked(2).forEach { rowItems ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                rowItems.forEach { item ->
                    ToolCard(item, modifier = Modifier.weight(1f))
                }
                if (rowItems.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ToolCard(item: ToolItem, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    val alpha = if (item.comingSoon) 0.55f else 1f
    Column(
        modifier = modifier
            .height(138.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground)
            .then(if (item.onClick != null) Modifier.clickable { item.onClick.invoke() } else Modifier)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp))
                .background(item.tint.copy(alpha = 0.15f * alpha)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(item.icon, contentDescription = null, tint = item.tint.copy(alpha = alpha), modifier = Modifier.size(22.dp))
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                item.title,
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary.copy(alpha = alpha), maxLines = 2,
            )
            Text(item.subtitle, fontSize = 12.sp, color = vine.textSecondary.copy(alpha = alpha), maxLines = 2)
        }
    }
}

/**
 * Owner/manager-only Management grid mirroring the iOS Home "Management"
 * section: team members and vineyard setup.
 */
@Composable
private fun ManagementSection(onOpenTool: (ToolRoute) -> Unit) {
    val tools = listOf(
        ToolItem("Manage Users", "Team & roles", Icons.Filled.Group, VineColors.Info) { onOpenTool(ToolRoute.TeamAccess) },
        ToolItem("Vineyard Setup", "Blocks & rows", Icons.Filled.Settings, VineColors.TextSecondaryLight) { onOpenTool(ToolRoute.Blocks) },
    )
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Management")
        tools.chunked(2).forEach { rowItems ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                rowItems.forEach { item -> ToolCard(item, modifier = Modifier.weight(1f)) }
                if (rowItems.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/**
 * "Recent" summary card mirroring the iOS Home summary section: a compact
 * tally of the key record types for the current vineyard.
 */
@Composable
private fun RecentSection(state: AppUiState) {
    val vine = LocalVineColors.current
    val rows = listOf(
        Triple("Pins", state.pins.size, Icons.Filled.LocationOn) to VineColors.Orange,
        Triple("Trips", state.trips.size, Icons.Filled.Map) to VineColors.Info,
        Triple("Spray records", state.sprayRecords.size, Icons.Filled.Science) to VineColors.Indigo,
        Triple("Blocks", state.paddocks.size, Icons.Filled.Grass) to VineColors.LeafGreen,
    )
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SectionHeader("Recent")
        VineyardCard {
            rows.forEachIndexed { index, (data, tint) ->
                val (label, value, icon) = data
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
                    Text(label, color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    Text(
                        "$value",
                        color = vine.textSecondary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                if (index < rows.lastIndex) {
                    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                }
            }
        }
    }
}
