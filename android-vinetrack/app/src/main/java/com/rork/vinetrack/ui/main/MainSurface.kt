package com.rork.vinetrack.ui.main

import com.rork.vinetrack.ui.screens.PinsViewMode

/**
 * An immutable read of [WorkContextViewModel]'s saved state — everything
 * MainScaffold consults to decide what to render.
 */
data class WorkSnapshot(
    val tab: MainTab,
    val tool: ToolRoute?,
    val pinMode: String?,
    val launcherMode: String?,
    val tripHudLauncherMode: String?,
    val pinsBlockIds: Set<String>,
    val pinsViewMode: PinsViewMode,
    val selectedTripId: String?,
    val programOpenCalculator: Boolean,
    val programCalculatorPrefill: String?,
    val showSetupWizard: Boolean,
    val showAddPinComposer: Boolean,
)

/**
 * The screen MainScaffold shows, together with the values it hands that
 * screen.
 *
 * MainScaffold renders by exhaustively matching on [MainSurface.of] rather
 * than re-deriving the branch conditions inline, so this type IS the routing
 * decision — not a parallel description of it. That makes the restored work
 * context testable end to end on the JVM: a test can restore a
 * [WorkContextViewModel] from a Bundle and assert the exact screen and
 * arguments the operator is about to be shown.
 */
sealed interface MainSurface {
    data object SetupWizard : MainSurface
    data object AddPinComposer : MainSurface

    /**
     * The Repairs/Growth quick-action pin-drop launcher.
     *
     * [mode] comes straight from the saved work context, so the launcher can
     * hold no mode state of its own.
     */
    data class PinLauncher(val mode: String) : MainSurface

    data class Tool(val route: ToolRoute, val pinMode: String?, val pins: PinsInputs) : MainSurface

    data class PinsTab(val pinMode: String?, val pins: PinsInputs) : MainSurface
    /**
     * [selectedTripId] is the trip the operator has open, so a recreation
     * returns to that trip's detail/HUD rather than to the trip list.
     *
     * [hudLauncherMode] is the Repairs/Growth launcher drawn over the live trip
     * map, so a recreation mid-workflow returns to the launcher rather than to
     * a bare HUD. It is never non-null without a [selectedTripId] — see [of].
     */
    data class TripTab(val selectedTripId: String?, val hudLauncherMode: String?) : MainSurface
    data class ProgramTab(val openCalculator: Boolean, val prefillId: String?) : MainSurface
    data object HomeTab : MainSurface
    data object SettingsTab : MainSurface

    companion object {
        /**
         * Resolve the surface in MainScaffold's real precedence order:
         * full-screen overlays first, then the pin-drop launcher, then a tool
         * opened on top of a tab, and finally the tab root itself.
         */
        fun of(work: WorkSnapshot): MainSurface {
            val pins = PinsInputs(viewMode = work.pinsViewMode, selectedBlockIds = work.pinsBlockIds)
            return when {
                work.showSetupWizard -> SetupWizard
                work.showAddPinComposer -> AddPinComposer
                // Normalised here so the launcher screen never has to defend
                // against an unexpected saved value.
                work.launcherMode != null ->
                    PinLauncher(if (work.launcherMode == "Growth") "Growth" else "Repairs")
                work.tool != null -> Tool(work.tool, work.pinMode, pins)
                else -> when (work.tab) {
                    MainTab.Home -> HomeTab
                    MainTab.Pins -> PinsTab(work.pinMode, pins)
                    // The HUD launcher is drawn over a trip's live map, so it
                    // fails safe here as well as in the work context: without a
                    // trip to host it there is no launcher to restore.
                    MainTab.Trip -> TripTab(
                        selectedTripId = work.selectedTripId,
                        hudLauncherMode = work.tripHudLauncherMode?.takeIf { work.selectedTripId != null },
                    )
                    MainTab.Program -> ProgramTab(work.programOpenCalculator, work.programCalculatorPrefill)
                    MainTab.Settings -> SettingsTab
                }
            }
        }
    }
}

/** The block/view state the Pins surface is opened with. */
data class PinsInputs(
    val viewMode: PinsViewMode,
    val selectedBlockIds: Set<String>,
)
