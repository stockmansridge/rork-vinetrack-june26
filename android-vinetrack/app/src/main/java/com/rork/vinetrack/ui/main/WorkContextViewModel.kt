package com.rork.vinetrack.ui.main

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map

/** Which quick-action pin-drop workflow the operator is in. */
enum class PinWorkflow(val modeName: String) {
    Repairs("Repairs"),
    Growth("Growth"),
    ;

    companion object {
        fun fromModeName(name: String?): PinWorkflow? = when (name) {
            "Growth" -> Growth
            "Repairs" -> Repairs
            else -> null
        }
    }
}

/**
 * The authoritative owner of "where the user is" in VineTrack.
 *
 * Everything here is a small ID, flag or enum name held in a
 * [SavedStateHandle], so it survives configuration change, Activity
 * recreation, Developer Options "Don't keep activities" and full process
 * death. Plain `remember` survives none of those, and `rememberSaveable` only
 * survives them while its host composable is actually in composition — which
 * `MainScaffold` is not during the `Restoring` phase after a process restart.
 *
 * Deliberately NO large objects: vineyards, blocks, pin collections, map state
 * and database models are never written to the saved-state Bundle. Screens are
 * reconstructed from these identifiers against VineTrack's offline/local data.
 */
class WorkContextViewModel(private val handle: SavedStateHandle) : ViewModel() {

    /** Bottom-navigation section the user was last on. */
    val tab: StateFlow<MainTab> = handle.getStateFlow(KEY_TAB, MainTab.Home.name)
        .mapState { name -> MainTab.entries.firstOrNull { it.name == name } ?: MainTab.Home }

    /** Secondary tool surface opened on top of a tab root, if any. */
    val tool: StateFlow<ToolRoute?> = handle.getStateFlow<String?>(KEY_TOOL, null)
        .mapState { name -> ToolRoute.entries.firstOrNull { it.name == name } }

    /** Observations mode ("Repairs"/"Growth") the Pins tool was opened with. */
    val pinMode: StateFlow<String?> = handle.getStateFlow(KEY_PIN_MODE, null)

    /**
     * The Repairs/Growth quick-action launcher currently open — i.e. the user
     * IS in the pin-drop workflow. Null when closed.
     */
    val launcherMode: StateFlow<String?> = handle.getStateFlow(KEY_LAUNCHER_MODE, null)

    /**
     * Which pin-drop workflow is active, if any. Read by the screen-awake
     * controller so Repairs/Growth pin dropping forces the display on.
     */
    val pinWorkflow: StateFlow<PinWorkflow?> = launcherMode.mapState { PinWorkflow.fromModeName(it) }

    /** Block/paddock the current workflow is scoped to, when one was chosen. */
    val selectedBlockId: StateFlow<String?> = handle.getStateFlow(KEY_BLOCK_ID, null)

    /** Trip to auto-open on the Trips tab. */
    val tripsSelection: StateFlow<String?> = handle.getStateFlow(KEY_TRIP_SELECTION, null)

    /** Open the Program tab straight into the Spray Calculator. */
    val programOpenCalculator: StateFlow<Boolean> = handle.getStateFlow(KEY_PROGRAM_CALC, false)

    /** Spray record/template id pre-filling the Spray Calculator. */
    val programCalculatorPrefill: StateFlow<String?> = handle.getStateFlow(KEY_PROGRAM_PREFILL, null)

    /** Open the Pins tab in List view rather than Map. */
    val pinsOpenInList: StateFlow<Boolean> = handle.getStateFlow(KEY_PINS_LIST, false)

    /** Setup Wizard shown as a full-screen overlay. */
    val showSetupWizard: StateFlow<Boolean> = handle.getStateFlow(KEY_SETUP_WIZARD, false)

    /** Unified "Add Pin / Action" composer shown as a full-screen overlay. */
    val showAddPinComposer: StateFlow<Boolean> = handle.getStateFlow(KEY_ADD_PIN, false)

    fun setTab(value: MainTab) { handle[KEY_TAB] = value.name }
    fun setTool(value: ToolRoute?) { handle[KEY_TOOL] = value?.name }
    fun setPinMode(value: String?) { handle[KEY_PIN_MODE] = value }
    fun setLauncherMode(value: String?) { handle[KEY_LAUNCHER_MODE] = value }
    fun setSelectedBlockId(value: String?) { handle[KEY_BLOCK_ID] = value }
    fun setTripsSelection(value: String?) { handle[KEY_TRIP_SELECTION] = value }
    fun setProgramOpenCalculator(value: Boolean) { handle[KEY_PROGRAM_CALC] = value }
    fun setProgramCalculatorPrefill(value: String?) { handle[KEY_PROGRAM_PREFILL] = value }
    fun setPinsOpenInList(value: Boolean) { handle[KEY_PINS_LIST] = value }
    fun setShowSetupWizard(value: Boolean) { handle[KEY_SETUP_WIZARD] = value }
    fun setShowAddPinComposer(value: Boolean) { handle[KEY_ADD_PIN] = value }

    /** Switch to [value] as a tab root, closing any tool/launcher overlay. */
    fun openTab(value: MainTab) {
        setTab(value)
        setTool(null)
        setPinMode(null)
        setLauncherMode(null)
        setPinsOpenInList(false)
        setShowAddPinComposer(false)
    }

    /** Clear the whole work context (sign-out, or switching user). */
    fun reset() {
        setTab(MainTab.Home)
        setTool(null)
        setPinMode(null)
        setLauncherMode(null)
        setSelectedBlockId(null)
        setTripsSelection(null)
        setProgramOpenCalculator(false)
        setProgramCalculatorPrefill(null)
        setPinsOpenInList(false)
        setShowSetupWizard(false)
        setShowAddPinComposer(false)
    }

    /**
     * Map a [StateFlow] while keeping it a [StateFlow] with an eagerly-derived
     * current value — no coroutine scope, no initial-value flicker.
     */
    private fun <T, R> StateFlow<T>.mapState(transform: (T) -> R): StateFlow<R> =
        object : StateFlow<R> {
            override val value: R get() = transform(this@mapState.value)
            override val replayCache: List<R> get() = listOf(value)
            override suspend fun collect(collector: kotlinx.coroutines.flow.FlowCollector<R>): Nothing {
                this@mapState.map(transform).collect { collector.emit(it) }
                error("StateFlow collection never completes")
            }
        }

    private companion object {
        const val KEY_TAB = "work_tab"
        const val KEY_TOOL = "work_tool"
        const val KEY_PIN_MODE = "work_pin_mode"
        const val KEY_LAUNCHER_MODE = "work_launcher_mode"
        const val KEY_BLOCK_ID = "work_block_id"
        const val KEY_TRIP_SELECTION = "work_trip_selection"
        const val KEY_PROGRAM_CALC = "work_program_calc"
        const val KEY_PROGRAM_PREFILL = "work_program_prefill"
        const val KEY_PINS_LIST = "work_pins_list"
        const val KEY_SETUP_WIZARD = "work_setup_wizard"
        const val KEY_ADD_PIN = "work_add_pin"
    }
}
