package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.ManualSprayPayload
import com.rork.vinetrack.data.model.ManualSprayWeather
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Serializable form state that keeps incomplete numeric text out of RPC payloads. */
@Serializable
data class ManualSprayFormDraft(
    val base: ManualSprayPayload,
    val startEngineHoursInput: String = base.startEngineHours?.toString().orEmpty(),
    val endEngineHoursInput: String = base.endEngineHours?.toString().orEmpty(),
    val waterInputs: Map<String, String> = base.tanks.associate { it.id to it.waterVolumeLitres.toString() },
    val chemicalInputs: Map<String, String> = base.tanks.flatMap { it.chemicals }.associate { it.id to displayManualAmount(it.actualAmountBase, it.unit).toString() },
    val hasManualWeather: Boolean = base.manualWeather != null,
    val weatherObservedAt: String? = base.manualWeather?.observedAt,
    val weatherSource: String? = base.manualWeather?.source,
    val temperatureInput: String = base.manualWeather?.temperatureC?.toString().orEmpty(),
    val humidityInput: String = base.manualWeather?.humidityPct?.toString().orEmpty(),
    val windInput: String = base.manualWeather?.windSpeedKmh?.toString().orEmpty(),
    val gustInput: String = base.manualWeather?.windGustKmh?.toString().orEmpty(),
    val directionInput: String = base.manualWeather?.windDirectionDeg?.toString().orEmpty(),
    val rainInput: String = base.manualWeather?.rainMm?.toString().orEmpty(),
) {
    /** Creates the only payload eligible for validation, queue persistence, and RPC encoding. */
    fun validatedPayload(): ManualSprayPayload {
        fun optionalNumber(raw: String, label: String): Double? {
            if (raw.isBlank()) return null
            return raw.toDoubleOrNull()?.takeIf(Double::isFinite)
                ?: throw IllegalArgumentException("$label is invalid.")
        }
        fun requiredNumber(raw: String?, label: String): Double =
            raw?.takeIf { it.isNotBlank() }?.toDoubleOrNull()?.takeIf(Double::isFinite)
                ?: throw IllegalArgumentException("$label is invalid.")

        val tanks = base.tanks.map { tank ->
            tank.copy(
                waterVolumeLitres = requiredNumber(waterInputs[tank.id], "Tank ${tank.tankNumber} water amount"),
                chemicals = tank.chemicals.map { chemical ->
                    chemical.copy(
                        actualAmountBase = toManualBase(
                            requiredNumber(chemicalInputs[chemical.id], "Tank ${tank.tankNumber} chemical amount"),
                            chemical.unit,
                        ),
                    )
                },
            )
        }
        val weather = if (hasManualWeather) {
            ManualSprayWeather(
                observedAt = weatherObservedAt ?: base.startUtc,
                source = weatherSource ?: "Operator observation",
                temperatureC = optionalNumber(temperatureInput, "Temperature"),
                humidityPct = optionalNumber(humidityInput, "Humidity"),
                windSpeedKmh = optionalNumber(windInput, "Wind speed"),
                windGustKmh = optionalNumber(gustInput, "Wind gust"),
                windDirectionDeg = optionalNumber(directionInput, "Wind direction"),
                rainMm = optionalNumber(rainInput, "Rain"),
            )
        } else null
        val payload = base.copy(
            startEngineHours = optionalNumber(startEngineHoursInput, "Start engine hours"),
            endEngineHours = optionalNumber(endEngineHoursInput, "End engine hours"),
            tanks = tanks,
            manualWeather = weather,
        )
        payload.validationError()?.let { throw IllegalArgumentException(it) }
        return payload
    }
}

internal data class ManualSprayCopiedInputs(
    val waterInputs: Map<String, String>,
    val chemicalInputs: Map<String, String>,
)

internal fun copyManualTankInputs(
    previous: com.rork.vinetrack.data.model.ManualSprayTank,
    copy: com.rork.vinetrack.data.model.ManualSprayTank,
    waterInputs: Map<String, String>,
    chemicalInputs: Map<String, String>,
): ManualSprayCopiedInputs {
    val copiedChemicals = copy.chemicals.associate { it.id to "" }.toMutableMap()
    previous.chemicals.zip(copy.chemicals).forEach { (old, new) -> copiedChemicals[new.id] = chemicalInputs[old.id].orEmpty() }
    return ManualSprayCopiedInputs(
        waterInputs = mapOf(copy.id to waterInputs[previous.id].orEmpty()),
        chemicalInputs = copiedChemicals,
    )
}

internal fun toManualBase(value: Double, unit: String): Double = if (unit == "Litres" || unit == "Kg") value * 1000.0 else value
internal fun displayManualAmount(value: Double, unit: String): Double = if (unit == "Litres" || unit == "Kg") value / 1000.0 else value

/** Vineyard-scoped durable form draft, separate from the mutation outbox. */
class ManualSprayDraftStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("vinetrack_manual_spray_drafts_v1", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun load(vineyardId: String): ManualSprayFormDraft? = preferences.getString(vineyardId, null)?.let { encoded ->
        runCatching { json.decodeFromString<ManualSprayFormDraft>(encoded) }.getOrNull()
            ?: runCatching { ManualSprayFormDraft(json.decodeFromString<ManualSprayPayload>(encoded)) }.getOrNull()
    }

    fun save(draft: ManualSprayFormDraft): Boolean = preferences.edit()
        .putString(draft.base.vineyardId, json.encodeToString(ManualSprayFormDraft.serializer(), draft))
        .commit()

    fun clear(vineyardId: String) { preferences.edit().remove(vineyardId).apply() }
}
