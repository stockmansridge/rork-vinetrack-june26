package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.insights.ScoutItem
import com.rork.vinetrack.data.insights.ScoutStatus
import com.rork.vinetrack.data.insights.ScoutVisit
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.screens.VintageYearText
import java.io.File

/** Local, offline Scout PDF generated from the same saved visit used by the preview. */
object ScoutReportPdfExporter {
    private const val WIDTH = 595
    private const val HEIGHT = 842
    private const val MARGIN = 40f

    fun exportAndShare(
        context: Context,
        visit: ScoutVisit,
        vineyard: Vineyard?,
        blocks: List<Paddock>,
        photoBytes: (String) -> ByteArray?,
        logo: android.graphics.Bitmap?,
        growthRecords: List<GrowthStageRecord>,
        pins: List<Pin>,
    ): Boolean = runCatching {
        val document = PdfDocument()
        val state = PageState(document)
        logo?.let {
            val scale = minOf(64f / it.width, 64f / it.height)
            val width = it.width * scale; val height = it.height * scale
            state.canvas.drawBitmap(it, null, android.graphics.RectF(554f - width, 38f, 554f, 38f + height), null)
        }
        state.text(vineyard?.name ?: "Vineyard", 22f, true)
        state.text(if (visit.status == ScoutStatus.DRAFT) "DRAFT SCOUT REPORT" else "SCOUT REPORT", 12f, true,
            if (visit.status == ScoutStatus.DRAFT) Color.rgb(230, 126, 34) else Color.rgb(52, 125, 60))
        state.text("Visit: ${visit.scoutDateIso}   Vintage: ${VintageYearText.format(visit.vintageYear)}")
        state.text("Observer: ${visit.scoutNameSnapshot ?: "Unavailable"}   Status: ${visit.status.label}")
        state.y = maxOf(state.y, 108f)
        state.heading("Weather")
        state.text(weatherText(visit))
        state.heading("Visit summary")
        state.text(visit.visitSummary ?: "Not assessed")
        state.ensure(190f)
        drawDiagram(state, blocks, visit, growthRecords, pins)
        state.y += 190f
        visit.assessments.forEach { assessment ->
            val block = blocks.firstOrNull { it.id == assessment.paddockId }
            state.heading(block?.name ?: "Block", 16f)
            val varieties = block?.varietyAllocations.orEmpty().mapNotNull { it.displayName }.distinct()
            state.text(if (varieties.isEmpty()) "Variety details unavailable" else varieties.joinToString(", "), color = Color.DKGRAY)
            ScoutItem.entries.forEach { item ->
                val observation = assessment.observation(item)
                state.text(item.label, 11f, true)
                val value = when {
                    item == ScoutItem.GROWTH_STAGE -> observation?.linkedGrowthStageRecordId?.let { id -> growthRecords.firstOrNull { it.id == id }?.displayStage } ?: observation?.valueLabel?.let { "$it (saved snapshot)" }
                    item.isFreeText -> observation?.notes
                    else -> observation?.valueLabel
                }
                state.text(value?.takeIf { it.isNotBlank() } ?: "Not assessed")
                if (!item.isFreeText && !observation?.notes.isNullOrBlank()) state.text(observation?.notes.orEmpty())
                observation?.photos.orEmpty().forEach { photo ->
                    state.ensure(126f)
                    val bytes = photoBytes(photo.id)
                    val bitmap = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                    if (bitmap == null) state.text("Photograph not downloaded to this device", color = Color.DKGRAY)
                    else {
                        val scale = minOf(160f / bitmap.width, 110f / bitmap.height)
                        val width = bitmap.width * scale; val height = bitmap.height * scale
                        state.canvas.drawBitmap(bitmap, null, android.graphics.RectF(MARGIN, state.y, MARGIN + width, state.y + height), null); state.y += maxOf(height, 110f) + 8f
                    }
                }
            }
        }
        state.finish()
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val file = File(dir, "Scout-${visit.scoutDateIso}-${visit.id.take(8)}.pdf")
        file.outputStream().use { document.writeTo(it) }
        document.close()
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "application/pdf"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }, "Share Scout report").apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
        true
    }.getOrDefault(false)

    private fun weatherText(visit: ScoutVisit): String {
        val weather = visit.weather ?: return "Not captured"
        if (weather.isUnavailable) return "Unavailable at observation time • ${weather.source ?: "source unavailable"}"
        val parts = mutableListOf<String>()
        weather.temperatureCelsius?.let { parts += "${it.toInt()}°C" }
        weather.humidityPercent?.let { parts += "${it.toInt()}% RH" }
        weather.windSpeedKph?.let { parts += "wind ${it.toInt()} km/h" }
        parts += weather.source ?: "source unavailable"
        parts += weather.observedAtIso?.let { "observed $it" } ?: "observation time unavailable"
        if (weather.isStale) parts += "STALE"
        return parts.joinToString(" • ")
    }

    private class PageState(private val document: PdfDocument) {
        private var pageNumber = 1
        private var page = document.startPage(PdfDocument.PageInfo.Builder(WIDTH, HEIGHT, pageNumber).create())
        var canvas = page.canvas
        var y = MARGIN
        fun ensure(height: Float) { if (y + height > HEIGHT - MARGIN) newPage() }
        private fun newPage() { document.finishPage(page); pageNumber++; page = document.startPage(PdfDocument.PageInfo.Builder(WIDTH, HEIGHT, pageNumber).create()); canvas = page.canvas; y = MARGIN }
        fun finish() = document.finishPage(page)
        fun heading(value: String, size: Float = 14f) = text(value, size, true, Color.rgb(85, 107, 47))
        fun text(value: String, size: Float = 10f, bold: Boolean = false, color: Int = Color.BLACK) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = size; this.color = color; typeface = Typeface.create(Typeface.DEFAULT, if (bold) Typeface.BOLD else Typeface.NORMAL) }
            val words = value.replace("\n", " \n ").split(" ")
            var line = ""
            val lines = mutableListOf<String>()
            words.forEach { word -> val candidate = if (line.isEmpty()) word else "$line $word"; if (word == "\n" || paint.measureText(candidate) > WIDTH - MARGIN * 2) { lines += line; line = if (word == "\n") "" else word } else line = candidate }
            if (line.isNotEmpty()) lines += line
            lines.forEach { line -> ensure(size + 3f); canvas.drawText(line, MARGIN, y + size, paint); y += size + 3f }
            y += 5f
        }
    }

    private fun drawDiagram(state: PageState, blocks: List<Paddock>, visit: ScoutVisit, growthRecords: List<GrowthStageRecord>, pins: List<Pin>) {
        val points = blocks.flatMap { it.polygonPoints.orEmpty() }
        val rect = android.graphics.RectF(MARGIN, state.y, WIDTH - MARGIN, state.y + 180f)
        state.canvas.drawColor(Color.TRANSPARENT)
        if (points.size < 3) { state.text("Map imagery unavailable — no mapped block boundaries", color = Color.DKGRAY); return }
        val minLat = points.minOf { it.latitude }; val maxLat = points.maxOf { it.latitude }
        val minLon = points.minOf { it.longitude }; val maxLon = points.maxOf { it.longitude }
        if (maxLat == minLat || maxLon == minLon) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(52, 125, 60); style = Paint.Style.STROKE; strokeWidth = 2f }
        blocks.forEach { block ->
            val polygon = block.polygonPoints.orEmpty(); if (polygon.size < 3) return@forEach
            fun x(lon: Double) = rect.left + ((lon - minLon) / (maxLon - minLon) * rect.width()).toFloat()
            fun y(lat: Double) = rect.bottom - ((lat - minLat) / (maxLat - minLat) * rect.height()).toFloat()
            val path = Path().apply { moveTo(x(polygon.first().longitude), y(polygon.first().latitude)); polygon.drop(1).forEach { lineTo(x(it.longitude), y(it.latitude)) }; close() }
            state.canvas.drawPath(path, paint)
        }
        val markerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(88, 86, 214); style = Paint.Style.FILL }
        fun x(lon: Double) = rect.left + ((lon - minLon) / (maxLon - minLon) * rect.width()).toFloat()
        fun y(lat: Double) = rect.bottom - ((lat - minLat) / (maxLat - minLat) * rect.height()).toFloat()
        visit.assessments.forEach { assessment ->
            val blockName = blocks.firstOrNull { it.id == assessment.paddockId }?.name ?: "Block"
            assessment.observations.forEach { observation ->
                observation.photos.forEach { photo ->
                    if (photo.latitude != null && photo.longitude != null) {
                        state.canvas.drawCircle(x(photo.longitude), y(photo.latitude), 4f, markerPaint)
                        state.canvas.drawText("$blockName • ${observation.item.label}", x(photo.longitude) + 6f, y(photo.latitude), Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 7f })
                    }
                }
                if (observation.item == ScoutItem.GROWTH_STAGE) {
                    val record = observation.linkedGrowthStageRecordId?.let { id -> growthRecords.firstOrNull { it.id == id } }
                    val pin = observation.linkedPinId?.let { id -> pins.firstOrNull { it.id == id } }
                    val latitude = record?.latitude ?: pin?.latitude; val longitude = record?.longitude ?: pin?.longitude
                    if (latitude != null && longitude != null) {
                        state.canvas.drawCircle(x(longitude), y(latitude), 4f, markerPaint)
                        state.canvas.drawText("$blockName • ${observation.item.label}", x(longitude) + 6f, y(latitude), Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 7f })
                    }
                }
            }
        }
    }
}
