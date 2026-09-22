package com.rork.vinetrack.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Credential-free evidence for one Davis archive record used by Optimal Ripeness. */
data class DavisTemperatureRecordDiagnostic(
    val localDate: String,
    val timestamp: Long,
    val sensorType: Int?,
    val highField: String,
    val lowField: String,
    val rawHighF: Double,
    val rawLowF: Double,
    val highC: Double,
    val lowC: Double,
)

data class DavisHistoricTemperatureParseResult(
    val dailyTemps: Map<String, DailyTemp>,
    val records: List<DavisTemperatureRecordDiagnostic>,
)

/**
 * Decodes only genuine Davis archive high/low fields. Missing values, current
 * values and interval averages are never substituted for a daily extremum.
 */
fun parseDavisHistoricTemperatures(
    sensors: JsonArray,
    timeZone: TimeZone,
): DavisHistoricTemperatureParseResult {
    val formatter = SimpleDateFormat("yyyyMMdd", Locale.US).apply { this.timeZone = timeZone }
    val internalSensorTypes = setOf(27)
    val highFields = listOf("temp_hi", "temp_out_hi", "temp_last_hi")
    val lowFields = listOf("temp_lo", "temp_out_lo", "temp_last_lo")
    val records = mutableListOf<DavisTemperatureRecordDiagnostic>()

    sensors.forEach sensorLoop@{ sensorElement ->
        val sensor = sensorElement.jsonObject
        val sensorType = sensor["sensor_type"]?.jsonPrimitive?.intOrNull
        if (sensorType != null && sensorType in internalSensorTypes) return@sensorLoop
        sensor["data"]?.jsonArray?.forEach recordLoop@{ recordElement ->
            val record = recordElement.jsonObject
            val timestamp = record["ts"]?.jsonPrimitive?.longOrNull ?: return@recordLoop
            val highField = highFields.firstOrNull { record[it]?.jsonPrimitive?.doubleOrNull != null } ?: return@recordLoop
            val lowField = lowFields.firstOrNull { record[it]?.jsonPrimitive?.doubleOrNull != null } ?: return@recordLoop
            val rawHigh = record[highField]?.jsonPrimitive?.doubleOrNull ?: return@recordLoop
            val rawLow = record[lowField]?.jsonPrimitive?.doubleOrNull ?: return@recordLoop
            if (rawHigh !in -100.0..200.0 || rawLow !in -100.0..200.0) return@recordLoop
            val highF = maxOf(rawHigh, rawLow)
            val lowF = minOf(rawHigh, rawLow)
            records += DavisTemperatureRecordDiagnostic(
                localDate = formatter.format(Date(timestamp * 1000L)),
                timestamp = timestamp,
                sensorType = sensorType,
                highField = highField,
                lowField = lowField,
                rawHighF = highF,
                rawLowF = lowF,
                highC = (highF - 32.0) * 5.0 / 9.0,
                lowC = (lowF - 32.0) * 5.0 / 9.0,
            )
        }
    }

    val dailyTemps = records.groupBy { it.localDate }.mapValues { (_, dayRecords) ->
        DailyTemp(
            high = dayRecords.maxOf { it.highC },
            low = dayRecords.minOf { it.lowC },
        )
    }
    return DavisHistoricTemperatureParseResult(dailyTemps, records)
}
