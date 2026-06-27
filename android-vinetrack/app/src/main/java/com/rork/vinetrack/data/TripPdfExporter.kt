package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.net.Uri
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SavedInput
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.formatTripDuration
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Generates a local single-trip PDF and shares it through the Android share
 * sheet. Mirrors the iOS `TripPDFService` section order — header, trip details,
 * seeding details, rows/paths covered, tank sessions, completion notes, the
 * estimated trip cost, and a route map — using only the data Android has.
 *
 * The **Estimated Trip Cost** section is gated on [includeCostings]: the caller
 * MUST pass `false` for non-owner/manager roles so supervisors and operators
 * never see pricing in an exported PDF (the section is omitted entirely rather
 * than blanked). Costs are computed via the pure [TripCostEstimator], matching
 * the on-screen cost card. The PDF is written to the app cache (`cache/exports`)
 * and shared via [FileProvider]; it is never uploaded to Supabase.
 */
object TripPdfExporter {

    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 40f
    private const val LABEL_WIDTH = 180f

    private val accent = Color.rgb(85, 107, 47) // olive, matching iOS VineyardTheme

    private class PageState(val doc: PdfDocument) {
        var page: PdfDocument.Page = doc.startPage(pageInfo(1))
        var canvas = page.canvas
        var y = MARGIN
        private var pageNumber = 1

        private fun pageInfo(n: Int) =
            PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, n).create()

        fun ensure(needed: Float) {
            if (y + needed > PAGE_HEIGHT - MARGIN) newPage()
        }

        fun newPage() {
            doc.finishPage(page)
            pageNumber += 1
            page = doc.startPage(pageInfo(pageNumber))
            canvas = page.canvas
            y = MARGIN
        }

        fun finish() {
            doc.finishPage(page)
        }
    }

    private val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        textSize = 22f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accent
        textSize = 14f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val subHeaderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accent
        textSize = 12f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val bodyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        textSize = 11f
    }
    private val bodyBoldPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        textSize = 11f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val captionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.DKGRAY
        textSize = 9f
    }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(80, 85, 107, 47)
        strokeWidth = 0.5f
    }

    /**
     * Build the PDF for [trip], write it to the cache, and launch the share
     * sheet. Returns false if generation failed; never throws.
     */
    fun exportAndShare(
        context: Context,
        trip: Trip,
        vineyardName: String,
        blockLabel: String,
        operatorName: String?,
        pinCount: Int,
        includeCostings: Boolean,
        linkedSpray: SprayRecord?,
        operatorCategories: List<OperatorCategory>,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        paddocks: List<Paddock>,
        yieldRecords: List<HistoricalYieldRecord> = emptyList(),
        savedInputs: List<SavedInput> = emptyList(),
        logo: Bitmap? = null,
    ): Boolean {
        return try {
            val doc = PdfDocument()
            val s = PageState(doc)
            render(
                s, trip, vineyardName, blockLabel, operatorName, pinCount,
                includeCostings, linkedSpray, operatorCategories, machines,
                fuelPurchases, paddocks, yieldRecords, savedInputs, logo,
            )
            s.finish()

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, fileName(trip, vineyardName))
            file.outputStream().use { doc.writeTo(it) }
            doc.close()

            val uri: Uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "application/pdf"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(
                Intent.createChooser(share, "Share trip report").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("TripPdfExporter", "PDF export failed", e)
            false
        }
    }

    private fun render(
        s: PageState,
        trip: Trip,
        vineyardName: String,
        blockLabel: String,
        operatorName: String?,
        pinCount: Int,
        includeCostings: Boolean,
        linkedSpray: SprayRecord?,
        operatorCategories: List<OperatorCategory>,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        paddocks: List<Paddock>,
        yieldRecords: List<HistoricalYieldRecord>,
        savedInputs: List<SavedInput>,
        logo: Bitmap?,
    ) {
        // Header
        val textX = PdfHeaderUtil.drawLogo(s.canvas, logo, MARGIN, s.y)
        s.canvas.drawText(vineyardName.ifBlank { "Vineyard" }, textX, s.y + 18f, titlePaint)
        s.y += 26f
        val reportTitle = trip.displayLabel.let { if (it == "Trip") "Trip Report" else "Trip Report — $it" }
        s.canvas.drawText(reportTitle, textX, s.y + 12f, headerPaint)
        s.y += 22f
        drawDivider(s)
        s.y += 8f

        // ── Trip Details ─────────────────────────────────────────────
        sectionHeader(s, "Trip Details")
        if (vineyardName.isNotBlank()) row(s, "Vineyard", vineyardName)
        if (blockLabel.isNotBlank()) row(s, "Block", blockLabel)
        if (trip.displayLabel.isNotBlank() && trip.displayLabel != "Trip") {
            row(s, "Trip type", trip.displayLabel)
        }
        operatorName?.takeIf { it.isNotBlank() }?.let { row(s, "Operator", it) }
            ?: trip.personName?.takeIf { it.isNotBlank() }?.let { row(s, "Operator", it) }
        formatDate(trip.startEpochMs)?.let { row(s, "Date", it) }
        timeOfDay(trip.startTime)?.let { row(s, "Start time", it) }
        timeOfDay(trip.endTime)?.let { row(s, "Finish time", it) }
        row(s, "Duration", formatTripDuration(trip.activeDurationSeconds ?: 0L))
        trip.totalDistance?.takeIf { it > 0 }?.let { row(s, "Distance", "${fmt(it)} m") }
        averageSpeedKmh(trip)?.let { row(s, "Average speed", "${fmt(it)} km/h") }
        row(s, "Pattern", TrackingPattern.fromRaw(trip.trackingPattern).title)
        if (pinCount > 0) row(s, "Pins logged", pinCount.toString())

        // ── Seeding Details ──────────────────────────────────────────
        val seeding = trip.seedingDetails
        if (seeding?.hasAnyValue == true) {
            sectionHeader(s, "Seeding Details")
            seeding.sowingDepthCm?.let { row(s, "Sowing depth", "${fmt(it)} cm") }
            val lines = seeding.mixLines.orEmpty().filter { it.hasAnyValue }
            lines.forEachIndexed { index, line ->
                val title = line.name?.takeIf { it.isNotBlank() }
                    ?.let { "Line ${index + 1} — $it" } ?: "Line ${index + 1}"
                s.y += 4f
                subHeader(s, title)
                line.percentOfMix?.let { rowIndented(s, "% of mix", "${fmt(it)}%") }
                line.seedBox?.takeIf { it.isNotBlank() }?.let { rowIndented(s, "Seed box", it) }
                line.kgPerHa?.let { rowIndented(s, "Kg/ha", "${fmt(it)} kg/ha") }
            }
        }

        // ── Rows / Paths Covered ─────────────────────────────────────
        if (trip.rowSequence.isNotEmpty()) {
            sectionHeader(s, "Rows / Paths")
            val done = trip.completedPaths?.toSet() ?: emptySet()
            val skip = trip.skippedPaths?.toSet() ?: emptySet()
            val completeCount = trip.rowSequence.count { done.contains(it) }
            val skipCount = trip.rowSequence.count { skip.contains(it) && !done.contains(it) }
            val notDone = trip.rowSequence.count { !done.contains(it) && !skip.contains(it) }
            row(s, "Total planned", "${trip.rowSequence.size}  (\u2705 $completeCount  \u23ED $skipCount  \u274C $notDone)")

            s.y += 6f
            s.ensure(24f)
            val c0 = MARGIN + 8f
            val c1 = MARGIN + 200f
            s.canvas.drawText("PATH", c0, s.y, captionPaint)
            s.canvas.drawText("STATUS", c1, s.y, captionPaint)
            s.y += 14f
            for (path in trip.rowSequence.sorted()) {
                s.ensure(18f)
                val status = when {
                    done.contains(path) -> "Completed"
                    skip.contains(path) -> "Skipped"
                    else -> "Not complete"
                }
                s.canvas.drawText("Row ${TripRowSequencePlanner.formatPath(path)}", c0, s.y, bodyPaint)
                s.canvas.drawText(status, c1, s.y, bodyBoldPaint)
                s.y += 18f
            }
        }

        // ── Tank Sessions ────────────────────────────────────────────
        val tankSessions = trip.tankSessions
        if (tankSessions.isNotEmpty()) {
            sectionHeader(s, "Tank Sessions")
            for (session in tankSessions.sortedBy { it.tankNumber }) {
                val status = if (session.isOpen) "Active" else "Complete"
                row(s, "Tank ${session.tankNumber}", status)
                if (session.rowRange.isNotBlank()) rowIndented(s, "Rows", session.rowRange)
                session.fillDurationSeconds?.let { rowIndented(s, "Fill duration", formatFillDuration(it)) }
            }
        }

        // ── Completion Notes ─────────────────────────────────────────
        trip.completionNotes?.trim()?.takeIf { it.isNotEmpty() }?.let { notes ->
            sectionHeader(s, "Completion Notes")
            text(s, notes, bodyPaint)
        }

        // ── Estimated Trip Cost (owner/manager only) ─────────────────
        if (includeCostings) {
            val cost = TripCostEstimator.estimate(
                trip, linkedSpray, operatorCategories, machines,
                fuelPurchases, paddocks, yieldRecords, savedInputs,
            )
            sectionHeader(s, "Estimated Trip Cost")
            val labour = cost.labour
            if (labour.warning != null && labour.cost <= 0) {
                row(s, "Labour", "—")
                rowIndented(s, "Note", labour.warning)
            } else {
                row(s, "Labour", money(labour.cost))
                val detail = if (labour.categoryName != null && (labour.costPerHour ?: 0.0) > 0) {
                    "${labour.categoryName} \u00b7 ${money(labour.costPerHour!!)}/hr \u00d7 ${fmt(labour.hours)} hr"
                } else "${fmt(labour.hours)} hr"
                rowIndented(s, detail, "")
            }

            val fuel = cost.fuel
            if (fuel.warning != null && fuel.fuelCost == null) {
                row(s, "Fuel", "—")
                rowIndented(s, "Note", fuel.warning)
            } else {
                fuel.litres?.let { row(s, "Fuel used (est.)", "${fmt(it)} L") }
                fuel.costPerLitre?.let { row(s, "Fuel cost per L", "${money(it)}/L") }
                fuel.fuelCost?.let { row(s, "Fuel cost", money(it)) }
            }

            cost.chemical?.let { chem ->
                if (chem.warning != null && chem.cost <= 0) {
                    row(s, "Chemical/Input", "—")
                    rowIndented(s, "Note", chem.warning)
                } else {
                    row(s, "Chemical/Input", money(chem.cost))
                    chem.warning?.let { rowIndented(s, "Note", it) }
                }
            }
            cost.seeding?.let { seed ->
                if (seed.cost > 0) {
                    row(s, "Seed/Input", money(seed.cost))
                    seed.warning?.let { rowIndented(s, "Note", it) }
                } else seed.warning?.let { row(s, "Seed/Input", it) }
            }

            s.y += 4f
            row(s, "Total estimated cost", money(cost.totalCost))
            row(s, "Costing status", cost.completeness.name)
            row(s, "Treated area", cost.treatedAreaHa?.let { "${fmt(it)} ha" } ?: "—")
            if (cost.costPerHa != null) {
                row(s, "Cost per ha", "${money(cost.costPerHa)}/ha")
            } else {
                row(s, "Cost per ha", "—")
                cost.areaWarning?.let { rowIndented(s, "Note", it) }
            }
            row(s, "Yield", cost.yieldTonnes?.let { "${fmt(it)} t" } ?: "—")
            if (cost.costPerTonne != null) {
                row(s, "Cost per tonne", "${money(cost.costPerTonne)}/t")
            } else {
                row(s, "Cost per tonne", "—")
                cost.yieldWarning?.let { rowIndented(s, "Note", it) }
            }
        }

        // ── Route Map (simple GPS trail diagram) ─────────────────────
        val coords = trip.pathPoints
            ?.mapNotNull { p -> p.latitude.let { lat -> p.longitude.let { lon -> lat to lon } } }
            ?: emptyList()
        if (coords.size >= 2) {
            drawRouteMap(s, coords)
        }

        // Footer
        s.y += 20f
        s.ensure(30f)
        drawDivider(s)
        s.y += 4f
        val generated = "Generated by VineTrack \u2022 " +
            SimpleDateFormat("dd/MM/yyyy h:mm a", Locale.getDefault()).format(Date())
        text(s, generated, captionPaint)
    }

    /** Draw the GPS trail as a normalised polyline in a bordered box. */
    private fun drawRouteMap(s: PageState, coords: List<Pair<Double, Double>>) {
        sectionHeader(s, "Route Map")
        val boxW = PAGE_WIDTH - MARGIN * 2
        val boxH = 260f
        s.ensure(boxH + 8f)
        val left = MARGIN
        val top = s.y
        val box = RectF(left, top, left + boxW, top + boxH)

        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(245, 247, 242) }
        s.canvas.drawRoundRect(box, 8f, 8f, bg)
        val border = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1f
            color = Color.rgb(210, 210, 210)
        }
        s.canvas.drawRoundRect(box, 8f, 8f, border)

        val lats = coords.map { it.first }
        val lons = coords.map { it.second }
        val minLat = lats.min(); val maxLat = lats.max()
        val minLon = lons.min(); val maxLon = lons.max()
        val latRange = (maxLat - minLat).takeIf { it > 1e-9 } ?: 1e-9
        val lonRange = (maxLon - minLon).takeIf { it > 1e-9 } ?: 1e-9
        // Preserve aspect ratio within an inset drawing area.
        val pad = 16f
        val drawW = boxW - pad * 2
        val drawH = boxH - pad * 2
        val scale = minOf(drawW / lonRange.toFloat(), drawH / latRange.toFloat())
        val offsetX = left + pad + (drawW - lonRange.toFloat() * scale) / 2f
        val offsetY = top + pad + (drawH - latRange.toFloat() * scale) / 2f

        fun pointFor(lat: Double, lon: Double): Pair<Float, Float> {
            val x = offsetX + ((lon - minLon).toFloat() * scale)
            // Latitude grows north → invert Y so north is up.
            val yy = offsetY + ((maxLat - lat).toFloat() * scale)
            return x to yy
        }

        val path = Path()
        val first = pointFor(coords.first().first, coords.first().second)
        path.moveTo(first.first, first.second)
        for (i in 1 until coords.size) {
            val pt = pointFor(coords[i].first, coords[i].second)
            path.lineTo(pt.first, pt.second)
        }
        val trail = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            color = accent
        }
        s.canvas.drawPath(path, trail)

        // Start (green) / end (red) markers.
        val last = pointFor(coords.last().first, coords.last().second)
        val startDot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(52, 199, 89) }
        val endDot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(255, 59, 48) }
        s.canvas.drawCircle(first.first, first.second, 5f, startDot)
        s.canvas.drawCircle(last.first, last.second, 5f, endDot)

        s.y = top + boxH + 6f
        text(s, "Start \u25CF  \u2192  Finish \u25CF", captionPaint)
    }

    // MARK: drawing helpers

    private fun text(s: PageState, value: String, paint: Paint) {
        val maxWidth = PAGE_WIDTH - MARGIN * 2
        for (line in wrap(value, paint, maxWidth)) {
            s.ensure(paint.textSize + 4f)
            s.y += paint.textSize
            s.canvas.drawText(line, MARGIN, s.y, paint)
            s.y += 4f
        }
    }

    private fun row(s: PageState, label: String, value: String) {
        s.ensure(18f)
        s.y += 12f
        s.canvas.drawText(label, MARGIN, s.y, bodyPaint)
        s.canvas.drawText(value, MARGIN + LABEL_WIDTH, s.y, bodyBoldPaint)
        s.y += 6f
    }

    private fun rowIndented(s: PageState, label: String, value: String) {
        s.ensure(18f)
        s.y += 12f
        s.canvas.drawText(label, MARGIN + 12f, s.y, bodyPaint)
        if (value.isNotEmpty()) s.canvas.drawText(value, MARGIN + LABEL_WIDTH, s.y, bodyBoldPaint)
        s.y += 6f
    }

    private fun subHeader(s: PageState, title: String) {
        s.ensure(20f)
        s.y += 6f
        s.canvas.drawText(title, MARGIN, s.y, subHeaderPaint)
        s.y += 6f
    }

    private fun sectionHeader(s: PageState, title: String) {
        s.y += 16f
        s.ensure(28f)
        s.y += 4f
        s.canvas.drawText(title, MARGIN, s.y, headerPaint)
        s.y += 8f
        drawDivider(s)
        s.y += 4f
    }

    private fun drawDivider(s: PageState) {
        s.canvas.drawLine(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y, linePaint)
    }

    private fun wrap(text: String, paint: Paint, maxWidth: Float): List<String> {
        val out = mutableListOf<String>()
        for (rawLine in text.split("\n")) {
            if (rawLine.isEmpty()) {
                out.add("")
                continue
            }
            var current = StringBuilder()
            for (word in rawLine.split(" ")) {
                val candidate = if (current.isEmpty()) word else "$current $word"
                if (paint.measureText(candidate) > maxWidth && current.isNotEmpty()) {
                    out.add(current.toString())
                    current = StringBuilder(word)
                } else {
                    current = StringBuilder(candidate)
                }
            }
            out.add(current.toString())
        }
        return out
    }

    // MARK: value formatting

    private fun money(value: Double): String {
        val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong())
        else "%,.2f".format(value)
        return "$$rounded"
    }

    private fun fmt(value: Double): String =
        if (value % 1.0 == 0.0) value.toLong().toString()
        else String.format(Locale.getDefault(), "%.2f", value).trimEnd('0').trimEnd('.')

    private fun averageSpeedKmh(trip: Trip): Double? {
        val seconds = trip.activeDurationSeconds ?: return null
        val distance = trip.totalDistance ?: return null
        if (seconds <= 0 || distance <= 0) return null
        return (distance / seconds) * 3.6
    }

    private fun formatFillDuration(seconds: Long): String {
        val mins = (seconds / 60).toInt()
        val secs = (seconds % 60).toInt()
        return if (mins > 0) "${mins}m ${secs}s" else "${secs}s"
    }

    private fun formatDate(epochMs: Long?): String? =
        epochMs?.let { SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(Date(it)) }

    private fun timeOfDay(iso: String?): String? =
        parseIsoToEpochMs(iso)?.let { SimpleDateFormat("h:mm a", Locale.getDefault()).format(Date(it)) }

    private fun fileName(trip: Trip, vineyardName: String): String {
        val date = trip.startEpochMs?.let {
            SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(it))
        } ?: SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        val safe = "${vineyardName.ifBlank { "Vineyard" }}_$date"
            .replace(" ", "_")
            .replace("/", "-")
            .replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
        return "TripReport_$safe.pdf"
    }
}
