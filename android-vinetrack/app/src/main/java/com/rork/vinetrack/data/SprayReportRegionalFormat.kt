package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.parseIsoToEpochMs

/** Customer report presentation only; recorded product units and costing remain unchanged. */
class SprayReportRegionalFormat(private val formatter: RegionFormatter) {
    fun money(value: Double): String = formatter.formatCompactCurrency(value)
    fun water(litres: Double): String = formatter.formatVolume(litres)
    fun area(hectares: Double): String = formatter.formatArea(hectares)
    fun carrier(litresPerHectare: Double): String = formatter.formatVolumePerArea(litresPerHectare)
    fun difference(litres: Double): String = "${if (litres > 0) "+" else ""}${water(litres)}"
    fun dateTime(iso: String?): String? = parseIsoToEpochMs(iso)?.let(formatter::formatDateTime)
    fun time(iso: String?): String? = parseIsoToEpochMs(iso)?.let(formatter::formatTime)
}
