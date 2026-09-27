package com.rork.vinetrack.data

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** A condition-only completion; daily temperatures, wind and rain remain with the primary provider. */
data class OpenMeteoDailyCondition(val description: String, val key: String) {
    companion object {
        fun from(code: Int): OpenMeteoDailyCondition? = when (code) {
            0 -> OpenMeteoDailyCondition("Clear", "clear")
            1 -> OpenMeteoDailyCondition("Mainly clear", "clear")
            2 -> OpenMeteoDailyCondition("Partly cloudy", "partly_cloudy")
            3 -> OpenMeteoDailyCondition("Overcast", "cloudy")
            45, 48 -> OpenMeteoDailyCondition("Fog", "fog")
            in 51..57 -> OpenMeteoDailyCondition("Drizzle", "drizzle")
            in 61..67, in 80..82 -> OpenMeteoDailyCondition("Rain", "rain")
            in 71..77, 85, 86 -> OpenMeteoDailyCondition("Snow", "snow")
            in 95..99 -> OpenMeteoDailyCondition("Thunderstorms", "storm")
            else -> null
        }

        fun byDate(root: JsonObject): Map<String, OpenMeteoDailyCondition> {
            val daily = root["daily"]?.jsonObject ?: return emptyMap()
            val times = daily["time"]?.jsonArray ?: return emptyMap()
            val codes = daily["weather_code"]?.jsonArray ?: return emptyMap()
            return times.mapIndexedNotNull { index, value ->
                val code = codes.getOrNull(index)?.jsonPrimitive?.intOrNull ?: return@mapIndexedNotNull null
                val condition = from(code) ?: return@mapIndexedNotNull null
                value.jsonPrimitive.content to condition
            }.toMap()
        }

        fun supplement(days: List<RainDay>, conditions: Map<String, OpenMeteoDailyCondition>, timezone: TimeZone): List<RainDay> {
            val format = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = timezone }
            return days.map { day ->
                if (listOf(day.condition, day.conditionKey, day.conditionCode).any { !it.isNullOrBlank() }) return@map day
                val extra = conditions[format.format(Date(day.dateEpochMs))] ?: return@map day
                day.copy(condition = extra.description, conditionKey = extra.key, conditionSource = "Open-Meteo")
            }
        }
    }
}
