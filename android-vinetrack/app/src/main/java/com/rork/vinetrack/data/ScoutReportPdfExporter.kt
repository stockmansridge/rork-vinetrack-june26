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
import com.rork.vinetrack.data.insights.ScoutReportPresentation
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
        locationBlocks: List<Paddock> = blocks,
        deletionStatus: String? = null,
    ): Boolean = runCatching {
        val locations = ScoutReportPresentation.locations(visit, locationBlocks, growthRecords, pins)
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
        deletionStatus?.let { state.text(it, color = Color.rgb(230, 126, 34)) }
        state.y = maxOf(state.y, 108f)
        state.heading("Weather")
        state.text(weatherText(visit))
        state.heading("Visit summary")
        state.text(visit.visitSummary ?: "Not assessed")
        state.ensure(190f)
        drawDiagram(state, blocks, locations.markers)
        state.y += 190f
        state.text("Offline location diagram — not aerial imagery", color = Color.DKGRAY)
        state.text(ScoutReportPresentation.LEGEND, color = Color.DKGRAY)
        locations.boundaryUnavailable.forEach { state.text(it, color = Color.DKGRAY) }
        locations.markers.forEach { state.text(it.label + " • %.6f, %.6f".format(java.util.Locale.ROOT, it.latitude, it.longitude)) }
        if (locations.unavailable.isNotEmpty()) {
            state.heading("Location unavailable")
            locations.unavailable.forEach { state.text(it, color = Color.DKGRAY) }
        }
        visit.assessments.forEach { assessment ->
            val block = blocks.firstOrNull { it.id == assessment.paddockId }
            state.heading(block?.name ?: "Block ${assessment.paddockId}", 16f)
            val varieties = block?.varietyAllocations.orEmpty().mapNotNull { it.displayName }.distinct()
            state.text(if (varieties.isEmpty()) "Variety details unavailable" else varieties.joinToString(", "), color = Color.DKGRAY)
            ScoutItem.entries.forEach { item ->
                val observation = assessment.observation(item)
                state.text(item.label, 11f, true)
                val value = when {
                    item == ScoutItem.GROWTH_STAGE -> ScoutReportPresentation.growthValue(observation, visit.vineyardId, growthRecords)
                    item.isFreeText -> observation?.notes
                    else -> observation?.valueLabel
                }
                state.text(value?.takeIf { it.isNotBlank() } ?: "Not assessed")
                locations.markers.filter { it.observationId == observation?.id && it.photoId == null }.forEach { state.text("Location: ${it.reference}", color = Color.DKGRAY) }
                if (!item.isFreeText && !observation?.notes.isNullOrBlank()) state.text(observation?.notes.orEmpty())
                observation?.photos.orEmpty().forEach { photo ->
                    val caption = "${locations.photoReferences[photo.id] ?: "Photograph"} • ${block?.name ?: assessment.paddockId} • ${item.label}"
                    state.ensure(state.textHeight(caption) + 126f)
                    state.text(caption, color = Color.DKGRAY)
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
        parts += "Temp: ${weather.temperatureCelsius?.let { "%.1f °C".format(it) } ?: "Unavailable"}"
        parts += "Humidity: ${weather.humidityPercent?.let { "${it.toInt()}%" } ?: "Unavailable"}"
        parts += "Wind: ${weather.windSpeedKph?.let { "${it.toInt()} km/h" } ?: "Unavailable"}"
        parts += "Source: ${weather.source ?: "Unavailable"}"
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
        private fun wrappedLines(value: String, paint: Paint): List<String> {
            var line = ""
            val lines = mutableListOf<String>()
            value.lines().forEach { paragraph ->
                paragraph.split(" ").filter { it.isNotEmpty() }.forEach { word ->
                    val candidate = if (line.isEmpty()) word else "$line $word"
                    if (paint.measureText(candidate) > WIDTH - MARGIN * 2 && line.isNotEmpty()) { lines += line; line = "" }
                    if (line.isNotEmpty()) line += " "
                    word.forEach { character ->
                        val candidate = line + character
                        if (paint.measureText(candidate) > WIDTH - MARGIN * 2 && line.isNotEmpty()) { lines += line; line = "" }
                        line += character
                    }
                }
                lines += line; line = ""
            }
            return lines
        }
        fun textHeight(value: String): Float = wrappedLines(value, Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 10f; typeface = Typeface.DEFAULT }).size * 13f + 5f
        fun text(value: String, size: Float = 10f, bold: Boolean = false, color: Int = Color.BLACK) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = size; this.color = color; typeface = Typeface.create(Typeface.DEFAULT, if (bold) Typeface.BOLD else Typeface.NORMAL) }
            wrappedLines(value, paint).forEach { line -> ensure(size + 3f); canvas.drawText(line, MARGIN, y + size, paint); y += size + 3f }
            y += 5f
        }
    }

    private fun drawDiagram(state: PageState, blocks: List<Paddock>, markers: List<ScoutReportPresentation.Location>) {
        val points = blocks.flatMap { it.polygonPoints.orEmpty() }.filter { ScoutReportPresentation.valid(it.latitude, it.longitude) }
            .map { it.latitude to it.longitude } + markers.map { it.latitude to it.longitude }
        val rect = android.graphics.RectF(MARGIN, state.y, WIDTH - MARGIN, state.y + 180f)
        state.canvas.drawRect(rect, Paint().apply { color = Color.rgb(242, 242, 242) })
        if (points.isEmpty()) {
            state.canvas.drawText("No valid boundaries or recorded locations available", rect.left + 12f, rect.centerY(), Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 10f; color = Color.DKGRAY })
            return
        }
        val minLat = points.minOf { it.first }; val maxLat = points.maxOf { it.first }
        val minLon = points.minOf { it.second }; val maxLon = points.maxOf { it.second }
        val latitudeSpan = maxOf(maxLat - minLat, 0.0002) * 1.3
        val longitudeSpan = maxOf(maxLon - minLon, 0.0002) * 1.3
        val bottom = (minLat + maxLat - latitudeSpan) / 2
        val left = (minLon + maxLon - longitudeSpan) / 2
        fun x(lon: Double) = rect.left + ((lon - left) / longitudeSpan * rect.width()).toFloat()
        fun y(lat: Double) = rect.bottom - ((lat - bottom) / latitudeSpan * rect.height()).toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(52, 125, 60); style = Paint.Style.STROKE; strokeWidth = 2f }
        blocks.forEach { block ->
            val polygon = block.polygonPoints.orEmpty().filter { ScoutReportPresentation.valid(it.latitude, it.longitude) }
            if (polygon.size >= 3 && polygon.size == block.polygonPoints.orEmpty().size) {
                val path = Path().apply { moveTo(x(polygon.first().longitude), y(polygon.first().latitude)); polygon.drop(1).forEach { lineTo(x(it.longitude), y(it.latitude)) }; close() }
                state.canvas.drawPath(path, paint)
            }
        }
        val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 8f; typeface = Typeface.DEFAULT_BOLD }
        markers.forEach { marker ->
            val markerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (marker.photoId != null) Color.rgb(230, 126, 34) else if (marker.reference.startsWith("E")) Color.rgb(52, 125, 60) else Color.rgb(0, 122, 255)
            }
            state.canvas.drawCircle(x(marker.longitude), y(marker.latitude), 4f, markerPaint)
            state.canvas.drawText(marker.reference, minOf(x(marker.longitude) + 6f, rect.right - labelPaint.measureText(marker.reference) - 2f), maxOf(rect.top + 10f, y(marker.latitude) - 4f), labelPaint)
        }
    }
}
