package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Paddock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.TimeZone

/** Selected-vineyard weather inputs, supplied after normal vineyard hydration. */
data class OptimalRipenessWeatherRequest(
    val vineyardId: String,
    val latitude: Double,
    val longitude: Double,
    val timeZone: TimeZone,
    val seasonStartMs: Long,
    val paddocks: List<Paddock>,
    val globalResetMode: GddResetMode,
)

/** Shared local weather state consumed without initiating provider work. */
data class OptimalRipenessWeatherState(
    val vineyardId: String? = null,
    val service: DegreeDayService? = null,
    val sourceKey: String? = null,
    val sourceLabel: String = "Weather source required",
    val timeZoneId: String? = null,
    val coverageStartMs: Long? = null,
    val completedEndMs: Long? = null,
    val hasCachedData: Boolean = false,
    val isUpdating: Boolean = false,
    val lastRefreshMs: Long? = null,
    val error: String? = null,
)

/**
 * Application-scoped owner of Optimal Ripeness source resolution, durable cache
 * hydration, union coverage, refresh throttling, and the single in-flight job.
 */
class OptimalRipenessWeatherCoordinator(
    context: Context,
    private val session: SessionStore,
    private val scope: CoroutineScope,
) {
    private val appContext: Context = context.applicationContext
    private val sourceStore = OptimalRipenessSourceStore(appContext)
    private val integrationRepository = VineyardWeatherIntegrationRepository(session)
    private val davisRepository = DavisWeatherLinkRepository(session)
    private val _state = MutableStateFlow(OptimalRipenessWeatherState())
    val state: StateFlow<OptimalRipenessWeatherState> = _state.asStateFlow()

    private var currentRequest: OptimalRipenessWeatherRequest? = null
    private var refreshJob: Job? = null
    private var requestIdentity: String? = null

    fun prepare(request: OptimalRipenessWeatherRequest, isOnline: Boolean, force: Boolean = false) {
        currentRequest = request
        val cachedSource = sourceStore.load(session.userId, request.vineyardId)
        val existing = _state.value
        val service = if (existing.vineyardId == request.vineyardId &&
            existing.service != null && existing.timeZoneId == request.timeZone.id
        ) existing.service else DegreeDayService(
            DailyWeatherCacheStore(appContext, request.timeZone.id),
            request.timeZone,
        )
        val sourceKey = cachedSource?.sourceFingerprint
        val hasCache = sourceKey != null && service.hasUsableData(sourceKey)
        val earliest = request.paddocks.mapNotNull { block ->
            block.resetDateMs(block.effectiveResetMode(request.globalResetMode), request.seasonStartMs)
        }.minOrNull()
        val completedEnd = completedCalendarDayStart(System.currentTimeMillis(), request.timeZone)
        _state.value = OptimalRipenessWeatherState(
            vineyardId = request.vineyardId,
            service = service,
            sourceKey = sourceKey,
            sourceLabel = cachedSource?.sourceLabel ?: "Checking weather source…",
            timeZoneId = request.timeZone.id,
            coverageStartMs = earliest,
            completedEndMs = completedEnd,
            hasCachedData = hasCache,
            isUpdating = existing.isUpdating && existing.vineyardId == request.vineyardId,
            lastRefreshMs = existing.lastRefreshMs.takeIf { existing.vineyardId == request.vineyardId },
            error = existing.error.takeIf { existing.vineyardId == request.vineyardId },
        )
        if (!isOnline || earliest == null) return
        val identity = refreshIdentity(request, cachedSource?.sourceFingerprint, earliest, completedEnd)
        val isFresh = !force && requestIdentity == identity &&
            existing.lastRefreshMs?.let { System.currentTimeMillis() - it < REFRESH_THROTTLE_MS } == true
        if (isFresh) return
        if (refreshJob?.isActive == true) {
            if (requestIdentity == identity) return
            refreshJob?.cancel()
        }
        requestIdentity = identity
        refreshJob = scope.launch { refresh(request, service, cachedSource, earliest, completedEnd, identity) }
    }

    fun refreshIfNeeded(isOnline: Boolean) {
        val request = currentRequest ?: return
        prepare(request, isOnline = isOnline, force = false)
    }

    private suspend fun refresh(
        request: OptimalRipenessWeatherRequest,
        service: DegreeDayService,
        cachedSource: OptimalRipenessSourceSelection?,
        earliest: Long,
        completedEnd: Long,
        identity: String,
    ) {
        _state.value = _state.value.copy(isUpdating = true, error = null)
        val result = runCatching {
            OptimalRipenessWeatherRepository(service, integrationRepository, davisRepository).refresh(
                vineyardId = request.vineyardId,
                latitude = request.latitude,
                longitude = request.longitude,
                fromEpochMs = earliest,
                toEpochMs = completedEnd,
                cachedSourceFingerprint = cachedSource?.sourceFingerprint,
                timeZoneId = request.timeZone.id,
            )
        }
        if (requestIdentity != identity || currentRequest != request) return
        result.onSuccess { weather ->
            sourceStore.save(OptimalRipenessSourceSelection(
                ownerId = session.userId.orEmpty(),
                vineyardId = request.vineyardId,
                sourceFingerprint = weather.source.sourceKey,
                sourceLabel = weather.source.label,
            ))
            _state.value = _state.value.copy(
                sourceKey = weather.source.sourceKey,
                sourceLabel = weather.source.label,
                hasCachedData = weather.hasUsableData,
                isUpdating = false,
                lastRefreshMs = System.currentTimeMillis(),
                error = if (weather.hasUsableData) null else "Weather history could not be updated.",
            )
        }.onFailure {
            _state.value = _state.value.copy(
                isUpdating = false,
                hasCachedData = _state.value.sourceKey?.let(service::hasUsableData) == true,
                error = "Weather history could not be updated.",
            )
        }
    }

    companion object {
        internal const val REFRESH_THROTTLE_MS: Long = 15 * 60 * 1000L

        fun completedCalendarDayStart(nowMs: Long, timeZone: TimeZone): Long =
            optimalRipenessStartOfDay(nowMs, timeZone)

        fun refreshIdentity(
            request: OptimalRipenessWeatherRequest,
            sourceFingerprint: String?,
            earliestRequiredMs: Long,
            completedEndMs: Long,
        ): String = listOf(
            request.vineyardId,
            sourceFingerprint.orEmpty(),
            "%.4f".format(java.util.Locale.US, request.latitude),
            "%.4f".format(java.util.Locale.US, request.longitude),
            request.timeZone.id,
            optimalRipenessStartOfDay(earliestRequiredMs, request.timeZone),
            completedCalendarDayStart(completedEndMs, request.timeZone),
        ).joinToString("|")
    }
}
