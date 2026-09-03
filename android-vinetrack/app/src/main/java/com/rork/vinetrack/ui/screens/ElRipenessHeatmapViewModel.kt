package com.rork.vinetrack.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.ripeness.CivilDate
import com.rork.vinetrack.data.ripeness.ElRipenessCachePayload
import com.rork.vinetrack.data.ripeness.ElRipenessCachedBlock
import com.rork.vinetrack.data.ripeness.ElRipenessCachedRecord
import com.rork.vinetrack.data.ripeness.ElRipenessHeatRaster
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter
import com.rork.vinetrack.data.ripeness.ElRipenessObservationCaching
import com.rork.vinetrack.data.ripeness.ElRipenessSeason
import com.rork.vinetrack.data.ripeness.RipenessObservationRepositoryProtocol
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Calendar
import java.util.TimeZone

/** A block's heat surface ready for a Google Maps ground overlay. */
data class ElRipenessOverlay(
    val paddockId: String,
    val raster: ElRipenessHeatRaster.Raster,
    val bounds: ElRipenessHeatRaster.DrawBounds,
)

/** Why the map cannot show a normal surface. */
sealed interface ElRipenessLoadState {
    data object Idle : ElRipenessLoadState
    data object Loading : ElRipenessLoadState

    /** Observations exist and a surface (or an explained absence) is drawable. */
    data object Ready : ElRipenessLoadState

    /** The vineyard has observations, but none in the selected Vintage. */
    data object EmptyVintage : ElRipenessLoadState

    /** No network and nothing cached — there is genuinely nothing to draw. */
    data object UnavailableOffline : ElRipenessLoadState
    data class Failed(val message: String) : ElRipenessLoadState
}

/** Non-fatal things the operator needs told about the surface they're seeing. */
sealed interface ElRipenessNotice {
    /** Every observation in range is older than the recency window. */
    data object StaleOnly : ElRipenessNotice

    /** Blocks that cannot be painted because they have no boundary. */
    data class MissingPolygon(val blockNames: List<String>) : ElRipenessNotice

    /** Drawn from the offline cache written at this instant. */
    data class OfflineCache(val cachedAtEpochMs: Long) : ElRipenessNotice
}

/** Counts shown under the timeline. See contract section 9 — they do not balance. */
data class ElRipenessStatusCounts(
    val recorded: Int = 0,
    val influencing: Int = 0,
    val stale: Int = 0,
    val unassigned: Int = 0,
)

/** Everything the heatmap screen renders from. */
data class ElRipenessUiState(
    val loadState: ElRipenessLoadState = ElRipenessLoadState.Idle,
    val notices: List<ElRipenessNotice> = emptyList(),
    val availableVintages: List<Int> = emptyList(),
    val selectedVintage: Int? = null,
    val selectedBlockId: String? = null,
    val blocks: List<ElRipenessHeatmap.BlockInput> = emptyList(),
    val timelineDays: List<CivilDate> = emptyList(),
    val observationDayIndices: List<Int> = emptyList(),
    val timelineIndex: Int = 0,
    val isPlaying: Boolean = false,
    val isRendering: Boolean = false,
    val heatModel: ElRipenessHeatmap.HeatModel? = null,
    val overlays: List<ElRipenessOverlay> = emptyList(),
    val statusCounts: ElRipenessStatusCounts = ElRipenessStatusCounts(),
    val seasonRangeText: String? = null,
) {
    val currentDay: CivilDate? get() = timelineDays.getOrNull(timelineIndex)
    val currentDateIso: String? get() = currentDay?.iso
    val medianEl: Double? get() = heatModel?.medianEl
    val hasAnyHeat: Boolean get() = overlays.isNotEmpty()
    val canStepBack: Boolean get() = observationDayIndices.any { it < timelineIndex }
    val canStepForward: Boolean get() = observationDayIndices.any { it > timelineIndex }
}

/**
 * Drives the E-L Ripeness Heatmap.
 *
 * Fetches once per vineyard, then rebuilds the surface purely in memory as the
 * operator scrubs the timeline, switches Vintage or filters to a block —
 * scrubbing the whole season never issues a second network call.
 *
 * Mirrors the Swift `ELRipenessHeatmapModel`.
 */
class ElRipenessHeatmapViewModel(
    private val repository: RipenessObservationRepositoryProtocol,
    private val cache: ElRipenessObservationCaching,
) : ViewModel() {

    private val _ui = MutableStateFlow(ElRipenessUiState())
    val ui: StateFlow<ElRipenessUiState> = _ui.asStateFlow()

    private var allObservations: List<ElRipenessHeatmap.Observation> = emptyList()
    private var vintageObservations: List<ElRipenessHeatmap.Observation> = emptyList()
    private var remoteSources: List<ElRipenessObservationAdapter.SourceRecord> = emptyList()
    private var pendingSources: List<ElRipenessObservationAdapter.SourceRecord> = emptyList()
    private var loadedVineyardId: String? = null
    private var seasonStartMonth: Int = ElRipenessSeason.DEFAULT_SEASON_START_MONTH
    private var seasonStartDay: Int = ElRipenessSeason.DEFAULT_SEASON_START_DAY
    private var today: CivilDate = CivilDate(2000, 1, 1)
    private var renderJob: Job? = null

    /** Set once per vineyard. Safe to call again; re-fetches. */
    fun load(
        vineyardId: String,
        paddocks: List<Paddock>,
        pendingRecords: List<GrowthStageRecord>,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone,
        isOnline: Boolean,
    ) {
        this.seasonStartMonth = seasonStartMonth
        this.seasonStartDay = seasonStartDay
        this.today = civilToday(timeZone)
        this.loadedVineyardId = vineyardId
        _ui.value = _ui.value.copy(loadState = ElRipenessLoadState.Loading, notices = emptyList())

        viewModelScope.launch {
            var resolvedBlocks = ElRipenessObservationAdapter.blockInputs(paddocks)
            pendingSources = ElRipenessObservationAdapter.pendingRecords(
                records = pendingRecords,
                vineyardId = vineyardId,
                timeZone = timeZone,
            )

            var notices = mutableListOf<ElRipenessNotice>()
            var loadedFromNetwork = false

            if (isOnline) {
                try {
                    val rows = withContext(Dispatchers.IO) {
                        repository.fetchObservations(vineyardId)
                    }
                    remoteSources = rows.map { it.sourceRecord() }
                    loadedFromNetwork = true
                } catch (e: Exception) {
                    remoteSources = emptyList()
                }
            }

            if (!loadedFromNetwork) {
                val cached = withContext(Dispatchers.IO) { cache.load(vineyardId) }
                if (cached != null) {
                    remoteSources = cached.sourceRecords
                    if (resolvedBlocks.isEmpty()) resolvedBlocks = cached.blockInputs
                    notices.add(ElRipenessNotice.OfflineCache(cached.cachedAtEpochMs))
                } else if (pendingSources.isEmpty()) {
                    _ui.value = _ui.value.copy(
                        loadState = ElRipenessLoadState.UnavailableOffline,
                        blocks = resolvedBlocks,
                    )
                    return@launch
                }
            }

            _ui.value = _ui.value.copy(blocks = resolvedBlocks, notices = notices)
            rebuildObservationSet(vineyardId)
            if (loadedFromNetwork) persistCache(vineyardId, resolvedBlocks)
            selectDefaultVintage()
        }
    }

    /** Re-merges local records without touching the network. */
    fun refreshPending(records: List<GrowthStageRecord>, timeZone: TimeZone) {
        val vineyardId = loadedVineyardId ?: return
        pendingSources = ElRipenessObservationAdapter.pendingRecords(records, vineyardId, timeZone)
        rebuildObservationSet(vineyardId)
        vintageDidChange()
    }

    private fun rebuildObservationSet(vineyardId: String) {
        allObservations = ElRipenessObservationAdapter.observations(
            sources = remoteSources + pendingSources,
            selectedVineyardId = vineyardId,
        )
    }

    private fun persistCache(vineyardId: String, blocks: List<ElRipenessHeatmap.BlockInput>) {
        val payload = ElRipenessCachePayload(
            vineyardId = vineyardId.lowercase(),
            cachedAtEpochMs = System.currentTimeMillis(),
            records = remoteSources.map { ElRipenessCachedRecord.from(it) },
            blocks = blocks.map { ElRipenessCachedBlock.from(it) },
        )
        viewModelScope.launch(Dispatchers.IO) { cache.save(payload) }
    }

    private fun selectDefaultVintage() {
        val available = ElRipenessSeason.availableVintages(allObservations, seasonStartMonth, seasonStartDay)
        val default = ElRipenessSeason.defaultVintage(allObservations, seasonStartMonth, seasonStartDay, today)
        _ui.value = _ui.value.copy(availableVintages = available, selectedVintage = default)
        vintageDidChange()
    }

    fun selectVintage(vintage: Int?) {
        if (_ui.value.selectedVintage == vintage) return
        _ui.value = _ui.value.copy(selectedVintage = vintage, isPlaying = false)
        vintageDidChange()
    }

    fun selectBlock(blockId: String?) {
        if (_ui.value.selectedBlockId == blockId) return
        _ui.value = _ui.value.copy(selectedBlockId = blockId)
        scheduleRebuild()
    }

    fun setTimelineIndex(index: Int) {
        val days = _ui.value.timelineDays
        if (days.isEmpty()) return
        val clamped = index.coerceIn(0, days.size - 1)
        if (clamped == _ui.value.timelineIndex) return
        _ui.value = _ui.value.copy(timelineIndex = clamped)
        scheduleRebuild()
    }

    private fun vintageDidChange() {
        val vintage = _ui.value.selectedVintage
        if (vintage == null) {
            vintageObservations = emptyList()
            _ui.value = _ui.value.copy(
                loadState = if (allObservations.isEmpty()) ElRipenessLoadState.EmptyVintage
                else ElRipenessLoadState.EmptyVintage,
                timelineDays = emptyList(),
                observationDayIndices = emptyList(),
                heatModel = null,
                overlays = emptyList(),
                seasonRangeText = null,
            )
            return
        }
        vintageObservations =
            ElRipenessSeason.filterToVintage(allObservations, vintage, seasonStartMonth, seasonStartDay)
        rebuildTimeline(vintage)
        scheduleRebuild()
    }

    private fun rebuildTimeline(vintage: Int) {
        val range = ElRipenessSeason.seasonRangeForVintage(seasonStartMonth, seasonStartDay, vintage)
        val start: CivilDate = CivilDate.parse(range.startIso) ?: return
        val end: CivilDate = CivilDate.parse(range.endIso) ?: return

        // The timeline stops at today when the season is still running, so the
        // operator cannot scrub into a future they have no data for.
        val last: CivilDate = if (today >= start && today <= end) today else end

        val days = ArrayList<CivilDate>()
        var cursor: CivilDate = start
        while (cursor <= last) {
            days.add(cursor)
            cursor = cursor.adding(1)
        }
        if (days.isEmpty()) days.add(start)

        val observationKeys = vintageObservations.map { ElRipenessHeatmap.dayKey(it.dateIso) }.toSet()
        val indices = days.indices.filter { observationKeys.contains(days[it].iso) }

        _ui.value = _ui.value.copy(
            timelineDays = days,
            observationDayIndices = indices,
            // Land on the most recent day that actually has an observation.
            timelineIndex = indices.lastOrNull() ?: (days.size - 1),
            seasonRangeText = "${range.startIso} — ${range.endIso}",
        )
    }

    fun stepToPreviousObservation() {
        val target = _ui.value.observationDayIndices.filter { it < _ui.value.timelineIndex }.maxOrNull()
        if (target != null) setTimelineIndex(target)
    }

    fun stepToNextObservation() {
        val target = _ui.value.observationDayIndices.firstOrNull { it > _ui.value.timelineIndex }
        if (target != null) setTimelineIndex(target)
    }

    fun togglePlayback() {
        val state = _ui.value
        if (state.isPlaying) {
            _ui.value = state.copy(isPlaying = false)
            return
        }
        if (state.timelineDays.isEmpty()) return
        // Restart from the beginning when parked at the end.
        val restart = state.timelineIndex >= state.timelineDays.size - 1
        _ui.value = state.copy(
            isPlaying = true,
            timelineIndex = if (restart) 0 else state.timelineIndex,
        )
        if (restart) scheduleRebuild()
    }

    /**
     * Advances one playback tick.
     *
     * With Reduce Motion on, playback jumps observation-to-observation instead
     * of sweeping every day, so the surface changes in discrete steps.
     */
    fun advancePlayback(reduceMotion: Boolean) {
        val state = _ui.value
        if (!state.isPlaying) return
        if (reduceMotion) {
            val next = state.observationDayIndices.firstOrNull { it > state.timelineIndex }
            if (next == null) {
                _ui.value = state.copy(isPlaying = false)
            } else {
                setTimelineIndex(next)
            }
            return
        }
        val next = state.timelineIndex + 1
        if (next >= state.timelineDays.size) {
            _ui.value = state.copy(isPlaying = false)
        } else {
            setTimelineIndex(next)
        }
    }

    /**
     * Rebuilds the heat model and rasters off the main thread, cancelling any
     * render still in flight so a fast scrub never queues work it will discard.
     */
    fun scheduleRebuild() {
        renderJob?.cancel()
        val state = _ui.value
        val dateIso = state.currentDateIso ?: return
        val blocks = state.blocks
        val filter = state.selectedBlockId
        val observations = vintageObservations

        _ui.value = state.copy(isRendering = true)
        renderJob = viewModelScope.launch {
            val result = withContext(Dispatchers.Default) {
                val model = ElRipenessHeatmap.buildHeatModel(
                    observations = observations,
                    blocks = blocks,
                    atDateIso = dateIso,
                    blockFilter = filter,
                )
                if (!isActive) return@withContext null
                val overlays = model.blocks.mapNotNull { block ->
                    val raster = ElRipenessHeatRaster.raster(block) ?: return@mapNotNull null
                    val bounds = ElRipenessHeatRaster.drawBounds(block) ?: return@mapNotNull null
                    ElRipenessOverlay(block.paddockId, raster, bounds)
                }
                model to overlays
            } ?: return@launch

            val (model, overlays) = result
            _ui.value = _ui.value.copy(
                heatModel = model,
                overlays = overlays,
                isRendering = false,
                loadState = if (vintageObservations.isEmpty()) ElRipenessLoadState.EmptyVintage
                else ElRipenessLoadState.Ready,
                statusCounts = ElRipenessStatusCounts(
                    recorded = model.qualifying.size,
                    influencing = model.influencing.size,
                    stale = model.stale.size,
                    unassigned = model.unassigned.size,
                ),
                notices = recomputeNotices(model),
            )
        }
    }

    private fun recomputeNotices(model: ElRipenessHeatmap.HeatModel): List<ElRipenessNotice> {
        // The offline banner survives every rebuild; the rest are recomputed.
        val next = _ui.value.notices.filterIsInstance<ElRipenessNotice.OfflineCache>().toMutableList<ElRipenessNotice>()

        if (model.influencing.isEmpty() && model.stale.isNotEmpty()) {
            next.add(ElRipenessNotice.StaleOnly)
        }
        val missing = model.blocks
            .filter { it.mode == ElRipenessHeatmap.Mode.NO_POLYGON }
            .mapNotNull { it.paddockName }
        if (missing.isNotEmpty()) next.add(ElRipenessNotice.MissingPolygon(missing))
        return next
    }

    /** Drops rasters and cancels rendering when the screen goes away. */
    fun teardown() {
        renderJob?.cancel()
        renderJob = null
        _ui.value = _ui.value.copy(
            overlays = emptyList(),
            heatModel = null,
            isPlaying = false,
            isRendering = false,
        )
    }

    override fun onCleared() {
        super.onCleared()
        renderJob?.cancel()
    }

    companion object {
        /** Today in the vineyard's own timezone — never the device's. */
        fun civilToday(timeZone: TimeZone): CivilDate {
            val calendar = Calendar.getInstance(timeZone)
            return CivilDate(
                calendar.get(Calendar.YEAR),
                calendar.get(Calendar.MONTH) + 1,
                calendar.get(Calendar.DAY_OF_MONTH),
            )
        }
    }
}
