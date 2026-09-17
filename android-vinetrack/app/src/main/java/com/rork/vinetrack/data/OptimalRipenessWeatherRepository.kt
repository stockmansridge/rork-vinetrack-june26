package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore

/** Authoritative weather source identity shared by every Optimal Ripeness surface. */
sealed interface OptimalRipenessWeatherSource {
    val sourceKey: String
    val label: String
    val latitude: Double

    data class Davis(
        val stationId: String,
        override val latitude: Double,
    ) : OptimalRipenessWeatherSource {
        override val sourceKey: String = DegreeDayService.davisKey(stationId)
        override val label: String = "Davis WeatherLink"
    }

    data class OpenMeteo(
        override val latitude: Double,
        val longitude: Double,
    ) : OptimalRipenessWeatherSource {
        override val sourceKey: String = DegreeDayService.openMeteoKey(latitude, longitude)
        override val label: String = "Open-Meteo Archive"
    }
}

data class OptimalRipenessWeatherResult(
    val source: OptimalRipenessWeatherSource,
    val hadUsableLocalData: Boolean,
    val hasUsableData: Boolean,
    val requestedWindows: List<WeatherDateWindow>,
)

/**
 * One provider-aware weather path for the Optimal Ripeness hub, detail, charts,
 * dashboard tile, block chip and projection calculations.
 */
class OptimalRipenessWeatherRepository(
    private val degreeDays: DegreeDayService,
    private val integrationRepository: VineyardWeatherIntegrationRepository,
    private val davisRepository: DavisWeatherLinkRepository,
) {
    suspend fun refresh(
        vineyardId: String,
        latitude: Double,
        longitude: Double,
        fromEpochMs: Long,
        toEpochMs: Long,
        cachedSourceFingerprint: String?,
    ): OptimalRipenessWeatherResult {
        val integrationRead = runCatching {
            integrationRepository.fetch(vineyardId, WeatherIntegrationProvider.DAVIS)
        }
        val source = resolveOptimalRipenessSource(
            integrationRead = integrationRead,
            latitude = latitude,
            longitude = longitude,
            cachedSourceFingerprint = cachedSourceFingerprint,
        )
        val hadLocal = degreeDays.hasUsableData(source.sourceKey)
        if (integrationRead.isFailure) {
            return OptimalRipenessWeatherResult(source, hadLocal, hadLocal, emptyList())
        }

        val windows = degreeDays.refreshWindows(
            sourceKey = source.sourceKey,
            fromMs = fromEpochMs,
            toMs = toEpochMs,
        )
        if (windows.isNotEmpty()) {
            when (source) {
                is OptimalRipenessWeatherSource.Davis -> {
                    windows.forEach { window ->
                        val rows = runCatching {
                            davisRepository.fetchHistoricDailyTemps(
                                vineyardId = vineyardId,
                                stationId = source.stationId,
                                fromEpochMs = window.startEpochMs,
                                toEpochMs = window.endEpochMs,
                            )
                        }.getOrNull().orEmpty()
                        degreeDays.installDailyTemps(source.sourceKey, rows)
                    }
                }
                is OptimalRipenessWeatherSource.OpenMeteo -> {
                    degreeDays.fetchOpenMeteoWindows(source.latitude, source.longitude, windows)
                }
            }
        }
        return OptimalRipenessWeatherResult(
            source = source,
            hadUsableLocalData = hadLocal,
            hasUsableData = degreeDays.hasUsableData(source.sourceKey),
            requestedWindows = windows,
        )
    }
}

internal fun resolveOptimalRipenessSource(
    integrationRead: Result<VineyardWeatherIntegration?>,
    latitude: Double,
    longitude: Double,
    cachedSourceFingerprint: String?,
): OptimalRipenessWeatherSource {
    if (integrationRead.isFailure) {
        val cachedDavis = cachedSourceFingerprint
            ?.takeIf { it.startsWith("davis:") }
            ?.removePrefix("davis:")
            ?.takeIf { it.isNotBlank() }
        return if (cachedDavis != null) {
            OptimalRipenessWeatherSource.Davis(cachedDavis, latitude)
        } else {
            OptimalRipenessWeatherSource.OpenMeteo(latitude, longitude)
        }
    }
    val davis = integrationRead.getOrNull()?.takeIf {
        it.isActive && it.hasApiKey && it.hasApiSecret && !it.stationId.isNullOrBlank()
    }
    return if (davis != null) {
        OptimalRipenessWeatherSource.Davis(
            stationId = requireNotNull(davis.stationId),
            latitude = davis.stationLatitude ?: latitude,
        )
    } else {
        OptimalRipenessWeatherSource.OpenMeteo(latitude, longitude)
    }
}
