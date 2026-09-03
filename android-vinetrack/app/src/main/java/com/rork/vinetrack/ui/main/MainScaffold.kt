package com.rork.vinetrack.ui.main

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.rork.vinetrack.data.auth.BiometricAuth
import com.rork.vinetrack.data.auth.BiometricResult
import kotlinx.coroutines.launch
import com.rork.vinetrack.ui.theme.VineColors
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.KeepScreenAwake
import com.rork.vinetrack.ui.components.ScreenAwakeController
import com.rork.vinetrack.ui.screens.BlocksScreen
import com.rork.vinetrack.ui.screens.CostReportsScreen
import com.rork.vinetrack.ui.screens.CustomiseToolsScreen
import com.rork.vinetrack.ui.screens.DiseaseRiskScreen
import com.rork.vinetrack.ui.screens.EquipmentScreen
import com.rork.vinetrack.ui.screens.FertiliserCalculatorScreen
import com.rork.vinetrack.ui.screens.IrrigationRecordsScreen
import com.rork.vinetrack.ui.screens.FuelLogScreen
import com.rork.vinetrack.ui.screens.PruningTrackerScreen
import com.rork.vinetrack.ui.screens.GrowthScreen
import com.rork.vinetrack.ui.screens.GrowthStageConfigScreen
import com.rork.vinetrack.ui.screens.GrowthStageImagesScreen
import com.rork.vinetrack.ui.screens.HomeDashboard
import com.rork.vinetrack.ui.screens.IrrigationScreen
import com.rork.vinetrack.ui.screens.MaintenanceScreen
import com.rork.vinetrack.ui.screens.MoreScreen
import com.rork.vinetrack.ui.screens.OperationPreferencesScreen
import com.rork.vinetrack.ui.screens.OptimalRipenessScreen
import com.rork.vinetrack.ui.screens.PinCategoryLauncherScreen
import com.rork.vinetrack.ui.screens.PinsScreen
import com.rork.vinetrack.ui.screens.PinsViewMode
import com.rork.vinetrack.ui.screens.RegionUnitsSettingsScreen
import com.rork.vinetrack.ui.screens.ResistancePlannerScreen
import com.rork.vinetrack.ui.screens.RolesPermissionsScreen
import com.rork.vinetrack.ui.screens.SettingsScreen
import com.rork.vinetrack.ui.screens.SetupWizardScreen
import com.rork.vinetrack.ui.screens.OperatorCategoriesScreen
import com.rork.vinetrack.ui.screens.SprayEquipmentHubScreen
import com.rork.vinetrack.ui.screens.SprayManagementScreen
import com.rork.vinetrack.ui.screens.SpraysScreen
import com.rork.vinetrack.ui.screens.AccountDeletionScreen
import com.rork.vinetrack.ui.screens.AppPreferencesScreen
import com.rork.vinetrack.ui.screens.AdminDashboardScreen
import com.rork.vinetrack.ui.screens.BiometricSettingsScreen
import com.rork.vinetrack.ui.screens.AlertSettingsScreen
import com.rork.vinetrack.ui.screens.AlertsCentreScreen
import com.rork.vinetrack.ui.screens.SupportRequestScreen
import com.rork.vinetrack.ui.screens.OfflineReadinessScreen
import com.rork.vinetrack.ui.screens.SyncStatusScreen
import com.rork.vinetrack.ui.screens.TeamAccessScreen
import com.rork.vinetrack.ui.screens.TripAuditScreen
import com.rork.vinetrack.ui.screens.TripFunctionsSettingsScreen
import com.rork.vinetrack.ui.screens.TripsScreen
import com.rork.vinetrack.ui.screens.UnifiedPinComposerScreen
import com.rork.vinetrack.ui.screens.VineyardLocationScreen
import com.rork.vinetrack.ui.screens.WeatherDataScreen
import com.rork.vinetrack.ui.screens.WorkTasksScreen
import com.rork.vinetrack.ui.screens.YieldScreen

@Composable
fun MainScaffold(vm: AppViewModel, state: AppUiState, work: WorkContextViewModel) {
    // Navigation / workflow context lives in a SavedStateHandle-backed
    // ViewModel, not in `remember`, so Activity recreation, "Don't keep
    // activities" and process death all return the operator to the same place.
    val tab by work.tab.collectAsStateWithLifecycle()
    // Secondary surface opened on top of the More hub. Null = showing a tab root.
    val tool by work.tool.collectAsStateWithLifecycle()
    // Optional Observations mode ("Repairs"/"Growth") when opening the Pins tool.
    val pinMode by work.pinMode.collectAsStateWithLifecycle()
    // Repairs/Growth quick-action category launcher ("Repairs"/"Growth"). Null = closed.
    val launcherMode by work.launcherMode.collectAsStateWithLifecycle()
    // The same launcher opened over the live trip HUD.
    val tripHudLauncherMode by work.tripHudLauncherMode.collectAsStateWithLifecycle()
    // A trip to auto-open on the Trips tab (e.g. a spray job just started from Spray Detail).
    val tripsSelection by work.tripsSelection.collectAsStateWithLifecycle()
    // When true, the Program tab opens straight into the Spray Calculator
    // (e.g. the "Spray Trip" option from the Trips start-trip chooser).
    val programOpenCalculator by work.programOpenCalculator.collectAsStateWithLifecycle()
    // Optional spray record/template id to pre-fill the Spray Calculator with
    // (e.g. "Start from Template" in the Spray Trip setup chooser).
    val programCalculatorPrefill by work.programCalculatorPrefill.collectAsStateWithLifecycle()
    // Map / List / Stats on the Pins surface, and the blocks the operator has
    // narrowed to. Both are real working state the operator set by hand, so
    // they live in the saved work context rather than in screen-local state.
    val pinsViewMode by work.pinsViewMode.collectAsStateWithLifecycle()
    val pinsBlockIds by work.pinsBlockIds.collectAsStateWithLifecycle()
    // When true, the Setup Wizard is shown as a full-screen overlay (opened from
    // the Home wizard card). Mirrors the iOS SetupWizardView sheet.
    val showSetupWizard by work.showSetupWizard.collectAsStateWithLifecycle()
    // Unified "Add Pin / Action" composer (sql/170): full-screen overlay
    // opened from the Home Quick Action. Mirrors the iOS composer.
    val showAddPinComposer by work.showAddPinComposer.collectAsStateWithLifecycle()

    // Live trip mode holds the screen awake app-wide — not just while the trip
    // detail screen is open — so the display never dims mid-trip while the
    // operator is on another tab (e.g. dropping Repairs/Growth pins). Gated by
    // the "Keep screen awake during trips" preference, like iOS. The flag
    // itself is owned solely by ScreenAwakeHost.
    KeepScreenAwake(
        enabled = state.activeTrip != null,
        reason = ScreenAwakeController.Reason.ActiveTrip,
    )

    // One-time reconciliation between this device's legacy local season start
    // and the shared vineyard value (owners/managers only — sql/108).
    state.seasonMigrationPrompt?.let { prompt ->
        val monthNames = remember { java.text.DateFormatSymbols(java.util.Locale.US).months }
        fun label(month: Int, day: Int) = "$day ${monthNames.getOrElse(month - 1) { "" }}"
        AlertDialog(
            onDismissRequest = { /* require an explicit choice */ },
            title = { Text("Shared Season Settings") },
            text = {
                Text(
                    "This vineyard's shared season start is ${label(prompt.sharedMonth, prompt.sharedDay)}, " +
                        "but this device was using ${label(prompt.localMonth, prompt.localDay)}. " +
                        "The season start is now shared with everyone in the vineyard and affects how " +
                        "records are grouped into vintages and \u201CThis Season\u201D reports."
                )
            },
            confirmButton = {
                TextButton(onClick = { vm.resolveSeasonMigration(useDeviceValue = false) }) {
                    Text("Keep shared (${label(prompt.sharedMonth, prompt.sharedDay)})")
                }
            },
            dismissButton = {
                TextButton(onClick = { vm.resolveSeasonMigration(useDeviceValue = true) }) {
                    Text("Use this device's (${label(prompt.localMonth, prompt.localDay)})")
                }
            },
        )
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                MainTab.entries.forEach { entry ->
                    NavigationBarItem(
                        selected = tab == entry && tool == null && launcherMode == null,
                        onClick = { work.openTab(entry) },
                        icon = {
                            if (entry == MainTab.Trip) {
                                SteeringWheelIcon(Modifier.size(24.dp))
                            } else {
                                Icon(entry.icon, contentDescription = entry.label)
                            }
                        },
                        label = { Text(entry.label) },
                    )
                }
            }
        }
    ) { padding ->
        // Only consume the bottom inset (for the navigation bar). Each tab screen
        // owns its own TopAppBar, which already handles the status-bar inset, so
        // applying the outer top padding here would double-count it and leave a
        // large blank strip at the top of every page.
        androidx.compose.foundation.layout.Column(
            modifier = Modifier.padding(bottom = padding.calculateBottomPadding()),
        ) {
        OfflineBanner(isOnline = state.isOnline)
        val modifier = Modifier

        // The one place the restored work context is turned into a screen.
        // Resolving through MainSurface (rather than re-deriving the branch
        // conditions inline) is what makes the restore path assertable off-device.
        val surface = MainSurface.of(
            WorkSnapshot(
                tab = tab,
                tool = tool,
                pinMode = pinMode,
                launcherMode = launcherMode,
                tripHudLauncherMode = tripHudLauncherMode,
                pinsBlockIds = pinsBlockIds,
                pinsViewMode = pinsViewMode,
                tripsSelection = tripsSelection,
                programOpenCalculator = programOpenCalculator,
                programCalculatorPrefill = programCalculatorPrefill,
                showSetupWizard = showSetupWizard,
                showAddPinComposer = showAddPinComposer,
            )
        )

        when (surface) {
            MainSurface.SetupWizard -> {
                BackHandler { work.setShowSetupWizard(false) }
                SetupWizardScreen(vm, state, modifier, onBack = { work.setShowSetupWizard(false) })
            }
            MainSurface.AddPinComposer -> UnifiedPinComposerScreen(
                vm = vm,
                state = state,
                modifier = modifier,
                onBack = { work.setShowAddPinComposer(false) },
                onSaved = {
                    // Return to the existing Pins map/list — the new pin shows
                    // through normal pin sync; no separate Manual Issues list.
                    work.setShowAddPinComposer(false)
                    work.openTab(MainTab.Pins)
                },
            )
            is MainSurface.PinLauncher -> {
                BackHandler { work.setLauncherMode(null) }
                PinCategoryLauncherScreen(
                    vm = vm,
                    state = state,
                    modifier = modifier,
                    // Controlled: the saved work context is the only home for
                    // the Repairs/Growth toggle, so switching mode mid-workflow
                    // survives recreation and is seen by the awake controller.
                    mode = surface.mode,
                    onModeChange = { work.setLauncherMode(it) },
                    onBack = { work.setLauncherMode(null) },
                    onOpenList = { work.openTab(MainTab.Pins) },
                )
            }
            is MainSurface.Tool -> {
                BackHandler { work.setTool(null) }
                ToolHost(
                    surface.route, vm, state, modifier,
                    onBack = { work.setTool(null) },
                    pinMode = surface.pinMode,
                    pins = surface.pins,
                    onPinsViewMode = { work.setPinsViewMode(it) },
                    onPinsBlockIds = { work.setPinsBlockIds(it) },
                    onOpenLauncher = { mode -> work.setLauncherMode(mode) },
                    onOpenTrip = { tripId ->
                        work.setTripsSelection(tripId)
                        work.openTab(MainTab.Trip)
                    },
                    onOpenTool = { route -> work.setTool(route); work.setPinMode(null) },
                )
            }
            MainSurface.HomeTab -> HomeDashboard(
                vm = vm,
                state = state,
                modifier = modifier,
                onOpenTab = { work.setTab(it); work.setTool(null); work.setPinMode(null) },
                onOpenTool = { work.setTool(it); work.setPinMode(null) },
                onOpenSetupWizard = { work.setShowSetupWizard(true) },
                onOpenAddPinAction = { work.setShowAddPinComposer(true) },
                onOpenObservations = { mode ->
                    if (mode == null) {
                        work.setTab(MainTab.Pins); work.setTool(null); work.setPinMode(null)
                    } else {
                        work.setLauncherMode(mode)
                    }
                },
                onOpenPinsList = {
                    work.openTab(MainTab.Pins)
                    work.setPinsViewMode(PinsViewMode.List)
                },
            )
            is MainSurface.PinsTab -> PinsScreen(
                vm, state, modifier,
                onBack = null,
                initialMode = surface.pinMode,
                viewMode = surface.pins.viewMode,
                onViewModeChange = { work.setPinsViewMode(it) },
                selectedBlockIds = surface.pins.selectedBlockIds,
                onSelectedBlockIdsChange = { work.setPinsBlockIds(it) },
                onOpenLauncher = { mode -> work.setLauncherMode(mode) },
            )
            is MainSurface.TripTab -> TripsScreen(
                vm, state, modifier,
                initialSelectedTripId = surface.selectedTripId,
                onSelectionConsumed = { work.setTripsSelection(null) },
                hudLauncherMode = surface.hudLauncherMode,
                onHudLauncherModeChange = { work.setTripHudLauncherMode(it) },
                onStartSprayTrip = { prefillId ->
                    work.setProgramCalculatorPrefill(prefillId)
                    work.setProgramOpenCalculator(true)
                    work.setTab(MainTab.Program)
                },
                // Emergency escape from the live trip HUD — the trip keeps
                // recording; the Trip tab re-opens it via the active banner.
                onGoHome = { work.openTab(MainTab.Home) },
            )
            is MainSurface.ProgramTab -> SpraysScreen(
                vm, state, modifier,
                onBack = null,
                initialOpenCalculator = surface.openCalculator,
                initialCalculatorPrefillId = surface.prefillId,
                onCalculatorConsumed = {
                    work.setProgramOpenCalculator(false)
                    work.setProgramCalculatorPrefill(null)
                },
                onOpenTrip = { tripId ->
                    work.setTripsSelection(tripId)
                    work.setTab(MainTab.Trip)
                },
            )
            MainSurface.SettingsTab -> SettingsScreen(
                vm, state, modifier,
                onBack = null,
                onOpenTool = { route -> work.setTool(route); work.setPinMode(null) },
            )
        }
        }
    }

    BiometricEnrollmentPrompt(vm)
}

/**
 * One-time offer to enable biometric sign-in, shown on the first reach of the
 * main app when the device supports it and the user hasn't already chosen.
 * Mirrors the iOS BiometricEnrollmentSheet.
 */
@Composable
private fun BiometricEnrollmentPrompt(vm: AppViewModel) {
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    val scope = rememberCoroutineScope()
    val capability = remember { BiometricAuth.capability(context) }

    var visible by remember {
        mutableStateOf(
            capability.canUseAnyAuth &&
                !vm.biometricEnabled &&
                !vm.biometricEnrollmentPromptShown &&
                activity != null,
        )
    }
    var isWorking by remember { mutableStateOf(false) }

    if (!visible) return

    AlertDialog(
        onDismissRequest = {
            if (!isWorking) {
                vm.markBiometricEnrollmentPromptShown()
                visible = false
            }
        },
        icon = { Icon(Icons.Filled.Fingerprint, contentDescription = null, tint = VineColors.LeafGreen) },
        title = { Text("Use biometric unlock?") },
        text = {
            Text("Sign in faster without retyping your password. Biometric login uses your device's secure authentication \u2014 your password is never stored.")
        },
        confirmButton = {
            TextButton(
                enabled = !isWorking,
                onClick = {
                    val act = activity ?: return@TextButton
                    isWorking = true
                    scope.launch {
                        val result = BiometricAuth.authenticate(
                            activity = act,
                            title = "Enable biometric sign-in",
                            subtitle = vm.userEmail,
                            reason = "Confirm it's you to enable faster sign-in.",
                        )
                        isWorking = false
                        if (result is BiometricResult.Success) {
                            vm.setBiometricEnabled(true)
                            visible = false
                        } else if (result is BiometricResult.Cancelled) {
                            vm.markBiometricEnrollmentPromptShown()
                            visible = false
                        }
                    }
                },
            ) { Text("Enable") }
        },
        dismissButton = {
            TextButton(
                enabled = !isWorking,
                onClick = {
                    vm.markBiometricEnrollmentPromptShown()
                    visible = false
                },
            ) { Text("Not now") }
        },
    )
}

/**
 * Slim banner shown only while the device is offline. Since no write queue
 * exists yet, the copy avoids promising queued/auto-synced writes. It sits
 * above the tab content and does not block navigation.
 */
@Composable
private fun OfflineBanner(isOnline: Boolean) {
    AnimatedVisibility(visible = !isOnline) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(VineColors.Warning)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Filled.CloudOff,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.padding(0.dp),
            )
            Text(
                "Offline — changes may not sync until connection returns",
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
private fun ToolHost(
    route: ToolRoute,
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier,
    onBack: () -> Unit,
    pinMode: String?,
    pins: PinsInputs,
    onPinsViewMode: (PinsViewMode) -> Unit,
    onPinsBlockIds: (Set<String>) -> Unit,
    onOpenLauncher: (String) -> Unit,
    onOpenTrip: (String) -> Unit,
    onOpenTool: (ToolRoute) -> Unit,
) {
    when (route) {
        ToolRoute.Pins -> PinsScreen(
            vm, state, modifier, onBack,
            initialMode = pinMode,
            viewMode = pins.viewMode,
            onViewModeChange = onPinsViewMode,
            selectedBlockIds = pins.selectedBlockIds,
            onSelectedBlockIdsChange = onPinsBlockIds,
            onOpenLauncher = onOpenLauncher,
        )
        ToolRoute.Blocks -> BlocksScreen(vm, state, modifier, onBack = onBack, onOpenTool = onOpenTool)
        ToolRoute.WorkTasks -> WorkTasksScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.Growth -> GrowthScreen(vm, state, modifier, onBack, onOpenStageImages = { onOpenTool(ToolRoute.GrowthStageImages) })
        ToolRoute.GrowthStageImages -> GrowthStageImagesScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.GrowthStageConfig -> GrowthStageConfigScreen(modifier, onBack = onBack)
        ToolRoute.Irrigation -> IrrigationScreen(state, modifier, onBack)
        ToolRoute.DiseaseRisk -> DiseaseRiskScreen(state, modifier, onBack, onOpenTool = onOpenTool)
        ToolRoute.Spray -> SpraysScreen(vm, state, modifier, onBack, onOpenTrip = onOpenTrip)
        ToolRoute.SprayEquipment -> SprayEquipmentHubScreen(vm, state, modifier, onBack, onOpenFuelLog = { onOpenTool(ToolRoute.FuelLog) })
        ToolRoute.SprayManagement -> SprayManagementScreen(vm, state, modifier, onBack, onOpenFuelLog = { onOpenTool(ToolRoute.FuelLog) })
        ToolRoute.OperatorCategories -> OperatorCategoriesScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.OptimalRipeness -> OptimalRipenessScreen(vm, state, modifier, onBack, onOpenTool = onOpenTool)
        ToolRoute.Yield -> YieldScreen(vm, state, modifier, onBack)
        ToolRoute.CostReports -> CostReportsScreen(vm, state, modifier, onBack, onOpenTool = onOpenTool)
        ToolRoute.Maintenance -> MaintenanceScreen(vm, state, modifier, onBack)
        ToolRoute.FuelLog -> FuelLogScreen(vm, state, modifier, onBack)
        ToolRoute.FertiliserCalculator -> FertiliserCalculatorScreen(vm, state, modifier, onBack, onOpenProducts = { onOpenTool(ToolRoute.SprayManagement) })
        ToolRoute.PruningTracker -> PruningTrackerScreen(vm, state, modifier, onBack, onOpenWorkTasks = { onOpenTool(ToolRoute.WorkTasks) })
        ToolRoute.IrrigationRecords -> IrrigationRecordsScreen(vm, state, modifier, onBack)
        ToolRoute.ResistancePlanner -> ResistancePlannerScreen(vm, state, modifier, onBack)
        ToolRoute.CustomiseTools -> CustomiseToolsScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.Equipment -> EquipmentScreen(vm, state, modifier, onBack, onOpenFuelLog = { onOpenTool(ToolRoute.FuelLog) })
        ToolRoute.TeamAccess -> TeamAccessScreen(vm, state, modifier, onBack = onBack, onOpenTool = onOpenTool)
        ToolRoute.RolesPermissions -> RolesPermissionsScreen(modifier, onBack = onBack)
        ToolRoute.Alerts -> {
            var showAlertSettings by rememberSaveable { mutableStateOf(false) }
            if (showAlertSettings) {
                androidx.activity.compose.BackHandler { showAlertSettings = false }
                AlertSettingsScreen(
                    vm, state, modifier,
                    onBack = { showAlertSettings = false },
                    onOpenWeatherData = { onOpenTool(ToolRoute.WeatherData) },
                )
            } else {
                AlertsCentreScreen(
                    vm, state, modifier,
                    onBack = onBack,
                    onOpenSettings = { showAlertSettings = true },
                    onOpenTool = onOpenTool,
                )
            }
        }
        ToolRoute.OperationPreferences -> OperationPreferencesScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.AppPreferences -> AppPreferencesScreen(modifier, onBack = onBack)
        ToolRoute.TripFunctions -> TripFunctionsSettingsScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.TripAudit -> TripAuditScreen(vm, modifier, onBack = onBack)
        ToolRoute.WeatherData -> WeatherDataScreen(state, modifier, onBack = onBack, onOpenTool = onOpenTool)
        ToolRoute.VineyardLocation -> VineyardLocationScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.Settings -> SettingsScreen(vm, state, modifier, onBack, onOpenTool = onOpenTool)
        ToolRoute.RegionUnits -> RegionUnitsSettingsScreen(vm, state, modifier, onBack = onBack)
        ToolRoute.SyncStatus -> SyncStatusScreen(vm, state, modifier, onBack)
        ToolRoute.OfflineReadiness -> OfflineReadinessScreen(
            state,
            userEmail = vm.userEmail,
            hasLocationPermission = vm.hasLocationPermission(),
            modifier = modifier,
            onBack = onBack,
            onRefresh = {
                vm.refresh()
                vm.retryPendingSync()
            },
        )
        ToolRoute.BiometricSettings -> BiometricSettingsScreen(vm, modifier, onBack = onBack)
        ToolRoute.ContactSupport -> SupportRequestScreen(vm, modifier, onBack = onBack)
        ToolRoute.DeleteAccount -> AccountDeletionScreen(vm, modifier, onBack = onBack)
        ToolRoute.Admin -> AdminDashboardScreen(vm, modifier, onBack = onBack)
    }
}
