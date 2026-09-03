package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.data.GrowthStageReportPdfExporter
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock
import java.util.Calendar
import java.util.TimeZone

/**
 * Payload builders for the Growth Stage vintage-timeline PDF.
 *
 * Extracted from the old report screen so the export can be triggered straight
 * from the Growth Stage Records toolbar. A share control is only worth keeping
 * if it actually exports something; routing it through a report screen just to
 * reach this code was the reason it behaved like a navigation control.
 *
 * Read-only: reads records and paddocks, writes a temporary file. Never touches
 * the Growth Stage write or sync path.
 */
private fun calendar(): Calendar = Calendar.getInstance(TimeZone.getDefault())

/** Vintage year for an observation date relative to the season start (month/day). */
internal fun vintageYear(epochMs: Long, seasonMonth: Int, seasonDay: Int): Int {
    val cal = calendar().apply { timeInMillis = epochMs }
    val month = cal.get(Calendar.MONTH) + 1
    val day = cal.get(Calendar.DAY_OF_MONTH)
    val year = cal.get(Calendar.YEAR)
    return if (month > seasonMonth || (month == seasonMonth && day >= seasonDay)) year + 1 else year
}

/** Inclusive [start, end] epoch ms for a vintage's season window. */
internal fun vintageRange(vintage: Int, seasonMonth: Int, seasonDay: Int): Pair<Long, Long> {
    val cal = calendar()
    cal.clear(); cal.set(vintage - 1, seasonMonth - 1, seasonDay, 0, 0, 0)
    val start = cal.timeInMillis
    cal.clear(); cal.set(vintage, seasonMonth - 1, seasonDay, 0, 0, 0)
    cal.add(Calendar.DAY_OF_MONTH, -1)
    cal.set(Calendar.HOUR_OF_DAY, 23); cal.set(Calendar.MINUTE, 59); cal.set(Calendar.SECOND, 59)
    return start to cal.timeInMillis
}

/** Build per-block report payloads (first-observed date per stage/vintage) for the PDF. */
internal fun buildBlockReports(
    paddocks: List<Paddock>,
    filteredRecords: List<GrowthStageRecord>,
    selectedPaddockId: String?,
    seasonMonth: Int,
    seasonDay: Int,
): List<GrowthStageReportPdfExporter.BlockReport> {
    val targetPaddocks =
        if (selectedPaddockId != null) paddocks.filter { it.id == selectedPaddockId } else paddocks
    return targetPaddocks.mapNotNull { paddock ->
        val recs = filteredRecords.filter { it.paddockId == paddock.id }
        if (recs.isEmpty()) return@mapNotNull null
        val vintages = recs
            .mapNotNull { it.observedEpochMs?.let { ms -> vintageYear(ms, seasonMonth, seasonDay) } }
            .toSortedSet(compareByDescending { it }).toList()
        val usedCodes = recs.map { it.stageCode }.toSet()
        val stageCodes = GrowthStage.allStages.map { it.code }.filter { usedCodes.contains(it) }
        val entries = vintages.associateWith { vintage ->
            val (start, end) = vintageRange(vintage, seasonMonth, seasonDay)
            val codeMap = mutableMapOf<String, Long>()
            recs.filter { (it.observedEpochMs ?: return@filter false) in start..end }.forEach { rec ->
                val ms = rec.observedEpochMs ?: return@forEach
                val existing = codeMap[rec.stageCode]
                // First observation of each stage wins.
                if (existing == null || ms < existing) codeMap[rec.stageCode] = ms
            }
            codeMap.toMap()
        }
        GrowthStageReportPdfExporter.BlockReport(paddock.name, vintages, stageCodes, entries)
    }
}
