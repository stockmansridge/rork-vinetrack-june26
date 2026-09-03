package com.rork.vinetrack.ui.main

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import com.rork.vinetrack.ui.screens.PinsViewMode
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
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
 * The outcome of binding the work context to an authenticated identity.
 *
 * Reported so the caller (and the tests) can distinguish "we deliberately kept
 * the restored state" from "we deliberately threw it away".
 */
sealed interface WorkContextBinding {
    /** No authenticated user yet — nothing was written or cleared. */
    data object Unbound : WorkContextBinding

    /** Same user and vineyard (or a first bind) — restored state was kept. */
    data object Retained : WorkContextBinding

    /** Same user, different vineyard — vineyard-scoped state was cleared. */
    data object VineyardChanged : WorkContextBinding

    /** A different user — the whole work context was cleared. */
    data object UserChanged : WorkContextBinding
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
 *
 * The context is scoped to an identity via [bindIdentity]: it belongs to one
 * user working one vineyard, and must never bleed across either boundary.
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
     *
     * This is the SINGLE source of truth for the launcher's Repairs/Growth
     * toggle. The launcher screen renders from it and writes straight back to
     * it, so switching mode mid-workflow is preserved across recreation and is
     * seen by the screen-awake controller.
     */
    val launcherMode: StateFlow<String?> = handle.getStateFlow(KEY_LAUNCHER_MODE, null)

    /**
     * The trip the operator currently has open — the authoritative answer to
     * "which trip am I in", not a one-shot navigation request.
     *
     * The Trips screen renders from this and writes straight back to it, so
     * being inside a trip (and inside its live HUD) survives recreation. It is
     * cleared by going back, by the trip disappearing, and by a vineyard or
     * user change — never by simply having been read.
     *
     * Declared before the HUD launcher because that launcher is derived from
     * it: a HUD mode is only real while a trip is there to host it.
     */
    val selectedTripId: StateFlow<String?> = handle.getStateFlow(KEY_SELECTED_TRIP, null)

    /**
     * The same Repairs/Growth launcher opened as an overlay on the live trip
     * HUD. Kept separate from [launcherMode] because it renders OVER the trip
     * map instead of replacing the whole surface.
     *
     * Only meaningful while [selectedTripId] names a trip to host it — see
     * [liveTripHudLauncherMode] and [TripContextRules].
     */
    val tripHudLauncherMode: StateFlow<String?> = handle.getStateFlow(KEY_TRIP_HUD_LAUNCHER, null)

    /**
     * The HUD launcher, but only while a trip is actually selected to draw it
     * over. A HUD mode with no selected trip is stale state: the launcher is
     * nowhere on screen, so it must not count as an active workflow.
     */
    private val liveTripHudLauncherMode: StateFlow<String?> =
        tripHudLauncherMode.combineState(selectedTripId) { mode, tripId ->
            mode?.takeIf { tripId != null }
        }

    /**
     * Which pin-drop workflow is active, if any. Read by the screen-awake
     * controller so Repairs/Growth pin dropping forces the display on.
     *
     * Covers the HUD launcher as well as the tab one: dropping pins from the
     * live trip HUD is the same job in the same weather, and must hold the
     * screen on the same way — but only while that HUD is really there, so a
     * stale HUD mode can never hold the display on invisibly.
     */
    val pinWorkflow: StateFlow<PinWorkflow?> =
        launcherMode.combineState(liveTripHudLauncherMode) { tabMode, hudMode ->
            PinWorkflow.fromModeName(tabMode ?: hudMode)
        }

    /**
     * Blocks the operator has narrowed the Pins map/list down to.
     *
     * Vineyard-scoped: these IDs are meaningless against another vineyard, so
     * [clearVineyardScopedState] drops them on a vineyard switch. Only the IDs
     * are stored — blocks themselves are resolved from the local/offline
     * paddock store on the way back in.
     */
    val pinsBlockIds: StateFlow<Set<String>> =
        handle.getStateFlow<ArrayList<String>?>(KEY_PINS_BLOCK_IDS, null)
            .mapState { ids -> ids?.toSet() ?: emptySet() }

    /** Map / List / Stats on the Pins surface. */
    val pinsViewMode: StateFlow<PinsViewMode> = handle.getStateFlow(KEY_PINS_VIEW_MODE, PinsViewMode.Map.name)
        .mapState { name -> PinsViewMode.entries.firstOrNull { it.name == name } ?: PinsViewMode.Map }

    /** Open the Program tab straight into the Spray Calculator. */
    val programOpenCalculator: StateFlow<Boolean> = handle.getStateFlow(KEY_PROGRAM_CALC, false)

    /** Spray record/template id pre-filling the Spray Calculator. */
    val programCalculatorPrefill: StateFlow<String?> = handle.getStateFlow(KEY_PROGRAM_PREFILL, null)

    /** Setup Wizard shown as a full-screen overlay. */
    val showSetupWizard: StateFlow<Boolean> = handle.getStateFlow(KEY_SETUP_WIZARD, false)

    /** Unified "Add Pin / Action" composer shown as a full-screen overlay. */
    val showAddPinComposer: StateFlow<Boolean> = handle.getStateFlow(KEY_ADD_PIN, false)

    fun setTab(value: MainTab) { handle[KEY_TAB] = value.name }
    fun setTool(value: ToolRoute?) { handle[KEY_TOOL] = value?.name }
    fun setPinMode(value: String?) { handle[KEY_PIN_MODE] = value }
    fun setLauncherMode(value: String?) { handle[KEY_LAUNCHER_MODE] = value }
    fun setTripHudLauncherMode(value: String?) { handle[KEY_TRIP_HUD_LAUNCHER] = value }
    fun setPinsBlockIds(value: Set<String>) { handle[KEY_PINS_BLOCK_IDS] = ArrayList(value) }
    fun setPinsViewMode(value: PinsViewMode) { handle[KEY_PINS_VIEW_MODE] = value.name }

    /**
     * Open [value] as the current trip, or clear the selection with null.
     *
     * Leaving a trip (or moving to a different one) always drops the HUD
     * launcher with it: that launcher belongs to the trip it was drawn over.
     */
    fun setSelectedTripId(value: String?) {
        if (handle.get<String?>(KEY_SELECTED_TRIP) == value) return
        handle[KEY_SELECTED_TRIP] = value
        handle[KEY_TRIP_HUD_LAUNCHER] = null
    }
    fun setProgramOpenCalculator(value: Boolean) { handle[KEY_PROGRAM_CALC] = value }
    fun setProgramCalculatorPrefill(value: String?) { handle[KEY_PROGRAM_PREFILL] = value }
    fun setShowSetupWizard(value: Boolean) { handle[KEY_SETUP_WIZARD] = value }
    fun setShowAddPinComposer(value: Boolean) { handle[KEY_ADD_PIN] = value }

    /** Switch to [value] as a tab root, closing any tool/launcher overlay. */
    fun openTab(value: MainTab) {
        setTab(value)
        setTool(null)
        setPinMode(null)
        setLauncherMode(null)
        setTripHudLauncherMode(null)
        setShowAddPinComposer(false)
    }

    /**
     * Everything MainScaffold needs to decide what to show, as one immutable
     * snapshot. Exposed so the surface decision can be exercised without a
     * device (see [MainSurface]).
     */
    fun snapshot(): WorkSnapshot = WorkSnapshot(
        tab = tab.value,
        tool = tool.value,
        pinMode = pinMode.value,
        launcherMode = launcherMode.value,
        tripHudLauncherMode = tripHudLauncherMode.value,
        pinsBlockIds = pinsBlockIds.value,
        pinsViewMode = pinsViewMode.value,
        selectedTripId = selectedTripId.value,
        programOpenCalculator = programOpenCalculator.value,
        programCalculatorPrefill = programCalculatorPrefill.value,
        showSetupWizard = showSetupWizard.value,
        showAddPinComposer = showAddPinComposer.value,
    )

    /**
     * Re-check the trip context against what is now known about the trip list.
     *
     * Called as the trip list loads and changes, so a selected trip that was
     * deleted, or a HUD launcher whose trip has ended, is dropped rather than
     * left holding the screen awake for a workflow that is no longer on screen.
     * Writes only when something actually changes.
     */
    fun reconcileTripContext(knowledge: TripsKnowledge) {
        val resolved = TripContextRules.reconcile(
            selectedTripId = selectedTripId.value,
            hudLauncherMode = tripHudLauncherMode.value,
            knowledge = knowledge,
        )
        // Written field-by-field rather than through setSelectedTripId: this is
        // a correction of existing state, not the operator opening a trip.
        if (resolved.selectedTripId != selectedTripId.value) {
            handle[KEY_SELECTED_TRIP] = resolved.selectedTripId
        }
        if (resolved.hudLauncherMode != tripHudLauncherMode.value) {
            handle[KEY_TRIP_HUD_LAUNCHER] = resolved.hudLauncherMode
        }
    }

    // ---- Identity scoping ---------------------------------------------------

    /**
     * Bind this context to the signed-in [userId] and active [vineyardId],
     * clearing only what the identity change actually invalidates.
     *
     * Deliberately NOT `LaunchedEffect(userId) { reset() }`: the binding is
     * itself part of the saved state, so the first bind after process death
     * sees the SAME identity it was saved with and keeps the restored work
     * context. Only a genuine change to a different user or vineyard clears
     * anything, and re-binding the same identity (a cache rehydrate, a
     * refresh, a reconnect) writes nothing at all.
     */
    fun bindIdentity(userId: String?, vineyardId: String?): WorkContextBinding {
        // Never bind a half-known identity: during Restoring / hydration the
        // user is transiently null, and treating that as "signed out" is the
        // exact bug this whole pass exists to prevent.
        if (userId == null) return WorkContextBinding.Unbound

        val boundUser = handle.get<String?>(KEY_BOUND_USER)
        if (boundUser != null && boundUser != userId) {
            reset()
            handle[KEY_BOUND_USER] = userId
            handle[KEY_BOUND_VINEYARD] = vineyardId
            return WorkContextBinding.UserChanged
        }
        if (boundUser == null) handle[KEY_BOUND_USER] = userId

        // A null vineyard is "not resolved yet", not "no vineyard" — hold the
        // existing binding rather than dropping the operator's block context.
        if (vineyardId == null) return WorkContextBinding.Retained

        val boundVineyard = handle.get<String?>(KEY_BOUND_VINEYARD)
        if (boundVineyard != null && boundVineyard != vineyardId) {
            clearVineyardScopedState()
            handle[KEY_BOUND_VINEYARD] = vineyardId
            return WorkContextBinding.VineyardChanged
        }
        if (boundVineyard == null) handle[KEY_BOUND_VINEYARD] = vineyardId
        return WorkContextBinding.Retained
    }

    /** The identity this context currently belongs to, for diagnostics/tests. */
    fun boundIdentity(): Pair<String?, String?> =
        handle.get<String?>(KEY_BOUND_USER) to handle.get<String?>(KEY_BOUND_VINEYARD)

    /**
     * Drop everything tied to the previous vineyard while keeping the operator
     * on a safe top-level surface (tab / tool / Repairs-Growth launcher), which
     * is meaningful in any vineyard.
     */
    private fun clearVineyardScopedState() {
        setPinsBlockIds(emptySet())
        setTripHudLauncherMode(null)
        setSelectedTripId(null)
        setProgramOpenCalculator(false)
        setProgramCalculatorPrefill(null)
        setShowSetupWizard(false)
        setShowAddPinComposer(false)
    }

    /** Explicit logout: clear the context AND its identity binding. */
    fun resetForSignOut() {
        reset()
        handle[KEY_BOUND_USER] = null
        handle[KEY_BOUND_VINEYARD] = null
    }

    /** Clear the whole work context (sign-out, or switching user). */
    fun reset() {
        setTab(MainTab.Home)
        setTool(null)
        setPinMode(null)
        setLauncherMode(null)
        setTripHudLauncherMode(null)
        setPinsBlockIds(emptySet())
        setPinsViewMode(PinsViewMode.Map)
        setSelectedTripId(null)
        setProgramOpenCalculator(false)
        setProgramCalculatorPrefill(null)
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

    /**
     * Combine two [StateFlow]s into a derived one, again without a coroutine
     * scope. Deliberately not `stateIn(viewModelScope)`: that would make the
     * derived value depend on a Main dispatcher existing and on a coroutine
     * having been scheduled, which is exactly the kind of timing this class is
     * supposed to be free of — the screen-awake controller reads
     * [pinWorkflow] synchronously during composition.
     */
    private fun <A, B, R> StateFlow<A>.combineState(
        other: StateFlow<B>,
        transform: (A, B) -> R,
    ): StateFlow<R> = object : StateFlow<R> {
        override val value: R get() = transform(this@combineState.value, other.value)
        override val replayCache: List<R> get() = listOf(value)
        override suspend fun collect(collector: kotlinx.coroutines.flow.FlowCollector<R>): Nothing {
            combine(this@combineState, other, transform).distinctUntilChanged().collect { collector.emit(it) }
            error("StateFlow collection never completes")
        }
    }

    private companion object {
        const val KEY_TAB = "work_tab"
        const val KEY_TOOL = "work_tool"
        const val KEY_PIN_MODE = "work_pin_mode"
        const val KEY_LAUNCHER_MODE = "work_launcher_mode"
        const val KEY_TRIP_HUD_LAUNCHER = "work_trip_hud_launcher"
        const val KEY_PINS_BLOCK_IDS = "work_pins_block_ids"
        const val KEY_PINS_VIEW_MODE = "work_pins_view_mode"
        const val KEY_SELECTED_TRIP = "work_selected_trip"
        const val KEY_PROGRAM_CALC = "work_program_calc"
        const val KEY_PROGRAM_PREFILL = "work_program_prefill"
        const val KEY_SETUP_WIZARD = "work_setup_wizard"
        const val KEY_ADD_PIN = "work_add_pin"
        const val KEY_BOUND_USER = "work_bound_user"
        const val KEY_BOUND_VINEYARD = "work_bound_vineyard"
    }
}
