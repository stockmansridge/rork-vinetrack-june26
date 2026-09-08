package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import android.net.Uri
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.reporting.SprayReportPayloadV1
import com.rork.vinetrack.data.reporting.SprayReportRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.resolveSprayEquipmentName
import com.rork.vinetrack.data.model.SprayEquipment
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import com.rork.vinetrack.data.spray.SprayBlockAttributionDisplay
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Generates a local, single spray-record PDF and shares it through the Android
 * share sheet. Mirrors the iOS `SprayRecordPDFService` section order — header,
 * spray reference, trip info, conditions, equipment, per-tank chemicals,
 * chemical totals, notes, links — using only the data Android actually has.
 *
 * A read-only **Cost Breakdown** section (labour, fuel, chemicals, total,
 * treated area, cost/ha) is included only for owner/manager roles
 * (`canViewFinancials == true`) when a linked trip exists, mirroring the
 * on-screen cost card via [TripCostEstimator]. Non-financial roles never get
 * the section — it is omitted entirely rather than blanked. The PDF is
 * written to the app cache (`cache/exports`) and shared via [FileProvider]; it
 * is never uploaded to Supabase.
 */
object SprayRecordPdfExporter {

    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 40f
    private const val LABEL_WIDTH = 180f

    private val accent = Color.rgb(85, 107, 47) // olive, matching iOS VineyardTheme

    /** Drawing cursor + paging state for a single export. */
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
    private val sprayNamePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.DKGRAY
        textSize = 16f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accent
        textSize = 14f
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
     * Build the PDF for [record], write it to the cache, and launch the share
     * sheet. Returns false if generation failed (the caller can surface a
     * message); never throws.
     */
    suspend fun exportAndShare(
        context: Context,
        record: SprayRecord,
        vineyardName: String,
        machines: List<VineyardMachine>,
        equipment: List<SprayEquipment>,
        trip: Trip?,
        workTask: WorkTask?,
        canViewFinancials: Boolean = false,
        fuelPurchases: List<FuelPurchase> = emptyList(),
        operatorCategories: List<OperatorCategory> = emptyList(),
        paddocks: List<Paddock> = emptyList(),
        logo: Bitmap? = null,
        regionFormatter: RegionFormatter = RegionFormatter(),
        vineyardTimeZone: String = regionFormatter.settings.timezone ?: "UTC",
        pinCount: Int = 0,
    ): Boolean {
        return try {
            require(trip != null) { "Spray record not available yet—sync and retry" }
            val actuals = SprayTankActualStore(context).load().filter { it.sprayRecordId == record.id }
            val offlinePayload = SprayReportPayloadV1.offlineProjection(
                trip = trip,
                record = record,
                vineyardName = vineyardName,
                vineyardTimeZone = vineyardTimeZone,
                paddocks = paddocks,
                machines = machines,
                sprayEquipment = equipment,
                tankActuals = actuals,
                pinCount = pinCount,
            )
            val repository = SprayReportRepository(SessionStore(context))
            val payload = runCatching { repository.fetch(trip.id) }.getOrDefault(offlinePayload)
            val sharedRoute = payload.route?.let { route ->
                runCatching {
                    val bytes = repository.downloadRoute(route)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }.getOrNull()
            }
            val doc = PdfDocument()
            val s = PageState(doc)
            render(
                s, payload, record, vineyardName, machines, equipment, trip, workTask,
                canViewFinancials, fuelPurchases, operatorCategories, paddocks, logo,
                actuals, regionFormatter, sharedRoute,
            )
            s.finish()

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, payload.exportFileName("android"))
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
                Intent.createChooser(share, "Share spray record").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("SprayRecordPdfExporter", "PDF export failed", e)
            false
        }
    }

    private fun render(
        s: PageState,
        payload: SprayReportPayloadV1,
        record: SprayRecord,
        vineyardName: String,
        machines: List<VineyardMachine>,
        equipment: List<SprayEquipment>,
        trip: Trip?,
        workTask: WorkTask?,
        canViewFinancials: Boolean,
        fuelPurchases: List<FuelPurchase>,
        operatorCategories: List<OperatorCategory>,
        paddocks: List<Paddock>,
        logo: Bitmap?,
        actuals: List<com.rork.vinetrack.data.model.SprayTankActual>,
        regionFormatter: RegionFormatter,
        sharedRoute: Bitmap?,
    ) {
        // Header
        val textX = PdfHeaderUtil.drawLogo(s.canvas, logo, MARGIN, s.y)
        s.canvas.drawText(vineyardName.ifBlank { "Vineyard" }, textX, s.y + 18f, titlePaint)
        s.y += 26f
        s.canvas.drawText("Spray Report", textX, s.y + 12f, headerPaint)
        s.y += 22f
        drawDivider(s)
        s.y += 8f

        record.sprayReference?.takeIf { it.isNotBlank() }?.let {
            text(s, it, sprayNamePaint)
        }
        trip?.paddockName?.takeIf { it.isNotBlank() }?.let {
            text(s, "Block: $it", bodyPaint)
        }

        // Blocks Treated — the AUTHORITATIVE sql/195 attribution.
        //
        // Deliberately separate from the line above, which is the linked TRIP's
        // block label and describes where the machine drove. This section states
        // which blocks the APPLICATION treated, which is what a compliance reader
        // and a resistance strategy need.
        //
        // A record whose attribution was never recorded says exactly that. It never
        // falls back to the vineyard's current blocks: naming a block that may never
        // have been sprayed would be worse than admitting the record is silent.
        sectionHeader(s, "Blocks Treated")
        val treatedBlocks = SprayBlockAttributionDisplay.resolve(
            record.applicationGeometry?.blocks,
            paddocks,
        )
        if (treatedBlocks == null) {
            text(s, SprayBlockAttributionDisplay.NOT_RECORDED, bodyPaint)
        } else {
            for (block in treatedBlocks) {
                text(s, "\u2022 ${block.name}", bodyPaint)
            }
        }

        // Trip Information
        if (trip != null) {
            sectionHeader(s, "Trip Information")
            tripDateTime(trip.startTime)?.let { row(s, "Start Time", it) }
            tripDateTime(trip.endTime)?.let { row(s, "End Time", it) }
            payload.trip.operatorName?.let { row(s, "Operator", it) }
            row(s, "Active Duration", payload.trip.activeDurationSeconds?.let { com.rork.vinetrack.data.model.formatTripDuration(it) } ?: "Not recorded")
            row(s, "Total Distance", payload.trip.distanceMetres?.let { regionFormatter.formatDistance(it) } ?: "Not recorded")
        }

        // Row Coverage (planned-trip row sequence). Read-only summary + per-row table.
        if (trip != null && trip.hasRowPlan) {
            sectionHeader(s, "Row Coverage")
            val pattern = TrackingPattern.fromRaw(trip.trackingPattern)
            row(s, "Tracking Pattern", pattern.title)
            row(s, "Paths Planned", "${trip.plannedPathCount}")
            row(s, "Completed", "${trip.completedRowCount}")
            if (trip.skippedRowCount > 0) row(s, "Skipped", "${trip.skippedRowCount}")
            row(s, "Not Complete", "${trip.notCompletedRowCount}")

            // Compact per-row table: Path / Status.
            s.y += 6f
            s.ensure(24f)
            val c0 = MARGIN + 8f
            val c1 = MARGIN + 105f
            val c2 = MARGIN + 220f
            val c3 = MARGIN + 355f
            s.canvas.drawText("ROW / BLOCK", c0, s.y, captionPaint)
            s.canvas.drawText("STATUS", c1, s.y, captionPaint)
            s.canvas.drawText("SOURCE", c2, s.y, captionPaint)
            s.canvas.drawText("TANK", c3, s.y, captionPaint)
            s.y += 14f
            for (reportRow in payload.rows) {
                s.ensure(18f)
                val rowAndBlock = "${TripRowSequencePlanner.formatPath(reportRow.rowNumber)} · ${reportRow.blockName ?: "Not recorded"}"
                s.canvas.drawText(rowAndBlock, c0, s.y, bodyPaint)
                s.canvas.drawText(reportRow.status, c1, s.y, bodyBoldPaint)
                s.canvas.drawText(reportRow.source, c2, s.y, captionPaint)
                s.canvas.drawText(reportRow.tankLabel, c3, s.y, bodyPaint)
                s.y += 18f
            }
        }

        sectionHeader(s, "Hourly Weather")
        if (payload.weather.isEmpty()) {
            text(s, "No hourly observations recorded.", bodyPaint)
        } else {
            payload.weather.forEach { observation ->
                val time = timeOfDay(observation.sampleSlot) ?: observation.sampleSlot
                val temperature = observation.temperatureC?.let { regionFormatter.formatTemperature(it) } ?: "—"
                val humidity = observation.humidityPct?.let { "${fmt(it)}%" } ?: "—"
                val wind = observation.windSpeedKmh?.let { regionFormatter.formatSpeed(it) } ?: "—"
                val gust = observation.windGustKmh?.let { regionFormatter.formatSpeed(it) } ?: "—"
                val rain = observation.rainMm?.let { regionFormatter.formatRainfall(it) } ?: "—"
                text(s, "$time  $temperature  RH $humidity  Wind $wind  Gust $gust  Rain $rain", bodyPaint)
                text(s, "${observation.source} · ${observation.sourceKind}${if (observation.isStale) " · stale" else ""}", captionPaint)
            }
        }

        // Equipment
        val hasEquipment = payload.equipment.tractorName != null || payload.equipment.sprayUnitName != null ||
            payload.equipment.startEngineHours != null || payload.equipment.endEngineHours != null ||
            !record.tractorGear.isNullOrBlank() || !record.numberOfFansJets.isNullOrBlank() || record.averageSpeed != null
        if (hasEquipment) {
            sectionHeader(s, "Equipment")
            row(s, "Tractor", payload.equipment.tractorName ?: "Not recorded")
            row(s, "Engine hours start", payload.equipment.startEngineHours?.let { "${fmt(it)} h" } ?: "Not recorded")
            row(s, "Engine hours end", payload.equipment.endEngineHours?.let { "${fmt(it)} h" } ?: "Not recorded")
            row(s, "Engine hours used", payload.equipment.engineHoursUsed?.let { "${fmt(it)} h" } ?: "Not recorded")
            row(s, "Spray Unit", payload.equipment.sprayUnitName ?: "Not recorded")
            record.tractorGear?.takeIf { it.isNotBlank() }?.let { row(s, "Tractor Gear", it) }
            record.numberOfFansJets?.takeIf { it.isNotBlank() }?.let { row(s, "No. Fans/Jets", it) }
            record.averageSpeed?.let { row(s, "Average Speed", regionFormatter.formatSpeed(it)) }
        }

        // Tanks
        val tanks = record.tanks.orEmpty()
        for (tank in tanks) {
            sectionHeader(s, "Tank ${tank.tankNumber}")
            val reportTank = payload.tanks.firstOrNull { it.tankNumber == tank.tankNumber }
            row(s, "Water — Planned", reportTank?.let { regionFormatter.formatVolume(it.plannedWaterLitres) } ?: "Not recorded")
            row(s, "Water — Actual", reportTank?.actualWaterLitres?.let { regionFormatter.formatVolume(it) } ?: "Not recorded")
            if (reportTank?.actualWaterLitres != null && kotlin.math.abs(reportTank.actualWaterLitres - reportTank.plannedWaterLitres) > 0.0000001) {
                row(s, "Water Difference", String.format(Locale.US, "%+.3f L", reportTank.actualWaterLitres - reportTank.plannedWaterLitres))
            }
            if (tank.sprayRatePerHa > 0) row(s, "Spray Rate", "${fmt(tank.sprayRatePerHa)} L/ha")
            if (tank.concentrationFactor > 0) row(s, "Concentration Factor", fmt(tank.concentrationFactor))
            if (tank.areaPerTank > 0) row(s, "Area per Tank", "${fmt(tank.areaPerTank)} ha")

            val chemicals = tank.chemicals.filter { it.name.isNotBlank() || it.volumePerTank > 0 }
            if (chemicals.isNotEmpty()) {
                s.y += 6f
                s.ensure(24f)
                val c0 = MARGIN + 8f
                val c1 = MARGIN + 200f
                val c2 = MARGIN + 320f
                s.canvas.drawText("CHEMICAL", c0, s.y, captionPaint)
                s.canvas.drawText("VOL/TANK", c1, s.y, captionPaint)
                s.canvas.drawText("RATE/HA", c2, s.y, captionPaint)
                s.y += 14f
                for (chem in chemicals) {
                    s.ensure(18f)
                    val unit = chemUnitAbbrev(chem.unit)
                    s.canvas.drawText(chem.name.ifBlank { "Unnamed" }, c0, s.y, bodyPaint)
                    val reportChemical = reportTank?.chemicals?.firstOrNull { it.plannedChemicalId == chem.id }
                    val actualText = when {
                        reportChemical?.actualAmountBase == null -> "Not recorded"
                        reportChemical.actualAmountBase == 0.0 -> "Not added"
                        else -> "${fmt(chemicalUnitFromBase(chem.unit, reportChemical.actualAmountBase))} $unit"
                    }
                    val plannedAmount = reportChemical?.plannedAmountBase ?: chem.volumePerTank
                    s.canvas.drawText("P ${fmt(chemicalUnitFromBase(chem.unit, plannedAmount))} $unit / A $actualText", c1, s.y, bodyBoldPaint)
                    if (chem.ratePerHa > 0) {
                        s.canvas.drawText("${fmt(chem.ratePerHa)} $unit/ha", c2, s.y, bodyBoldPaint)
                    }
                    s.y += 18f
                    if (reportChemical?.actualAmountBase != null && kotlin.math.abs(reportChemical.actualAmountBase - plannedAmount) > 0.000_001) {
                        val difference = chemicalUnitFromBase(chem.unit, reportChemical.actualAmountBase - plannedAmount)
                        rowIndented(s, "Difference", "${if (difference > 0) "+" else ""}${fmt(difference)} ${chem.unit}")
                    }
                }
            }
        }

        // Chemical Totals (All Tanks)
        val totals = tanks.flatMap { it.chemicals }
            .filter { it.name.isNotBlank() }
            .groupBy { it.name.trim().lowercase(Locale.getDefault()) }
            .map { (_, chems) ->
                Triple(
                    chems.first().name,
                    chems.sumOf { it.volumePerTank },
                    chemUnitAbbrev(chems.first().unit),
                )
            }
            .sortedBy { it.first.lowercase(Locale.getDefault()) }
        if (totals.isNotEmpty()) {
            sectionHeader(s, "Chemical Totals (All Tanks)")
            for ((name, total, unit) in totals) {
                row(s, name, "${fmt(total)}$unit")
            }
        }

        // Tank Sessions (read-only; only when the linked trip recorded fills) — Stage 3F-2d.
        val tankSessions = trip?.tankSessions.orEmpty()
        if (tankSessions.isNotEmpty()) {
            sectionHeader(s, "Tank Sessions")
            for (session in tankSessions.sortedBy { it.tankNumber }) {
                val status = if (session.isOpen) "In progress" else "Complete"
                row(s, "Tank ${session.tankNumber}", status)
                if (session.rowRange.isNotBlank()) {
                    rowIndented(s, "Rows", session.rowRange)
                }
                session.fillDurationSeconds?.let { rowIndented(s, "Fill Duration", formatFillDuration(it)) }
            }
        }

        // Cost Breakdown (owner/manager only, linked trip only) — Stage 3F-3c-i.
        // Mirrors the on-screen cost card via the pure TripCostEstimator. The
        // whole section is omitted for non-financial roles or when no trip is
        // linked (chemical-only behaviour elsewhere is unchanged).
        if (canViewFinancials && trip != null) {
            val cost = TripCostEstimator.estimate(
                trip = trip,
                sprayRecord = record,
                operatorCategories = operatorCategories,
                machines = machines,
                fuelPurchases = fuelPurchases,
                paddocks = paddocks,
                tankActuals = actuals,
            )
            val fuel = cost.fuel
            val hasAnyValue = cost.totalCost > 0 ||
                cost.labour.cost > 0 ||
                fuel.fuelCost != null ||
                fuel.litres != null ||
                (cost.chemical?.cost ?: 0.0) > 0
            if (hasAnyValue) {
                sectionHeader(s, if (cost.chemical?.basis == TripCostEstimator.ChemicalCostBasis.Actual) "Cost Breakdown — Actual Chemicals" else "Cost Breakdown — Estimated Chemicals")
                if (cost.labour.cost > 0) row(s, "Labour", money(cost.labour.cost))
                fuel.fuelCost?.let { fc ->
                    val value = fuel.litres?.let { "${money(fc)} \u00B7 ${fmt(it)} L" } ?: money(fc)
                    row(s, "Fuel", value)
                }
                cost.chemical?.takeIf { it.cost > 0 }?.let { row(s, "Chemicals", money(it.cost)) }
                if (cost.totalCost > 0) row(s, "Total Cost", money(cost.totalCost))
                cost.treatedAreaHa?.let { row(s, "Treated Area", "${fmt(it)} ha") }
                cost.costPerHa?.let { row(s, "Cost / ha", money(it)) }

                // Completeness + warnings in small caption text so the totals
                // are never mistaken for final when inputs are missing.
                if (cost.completeness != TripCostEstimator.Completeness.Complete) {
                    val label = when (cost.completeness) {
                        TripCostEstimator.Completeness.Partial -> "Estimate incomplete \u2014 some inputs are missing."
                        TripCostEstimator.Completeness.Unavailable -> "Cost estimate unavailable."
                        TripCostEstimator.Completeness.Complete -> null
                    }
                    label?.let {
                        s.y += 4f
                        text(s, it, captionPaint)
                    }
                }
                cost.warnings.forEach { warning ->
                    s.y += 2f
                    text(s, "\u2022 $warning", captionPaint)
                }
                cost.areaWarning?.takeIf { cost.costPerHa == null }?.let {
                    s.y += 2f
                    text(s, "\u2022 $it", captionPaint)
                }
            }
        }

        if (sharedRoute != null) {
            drawSharedRouteMap(s, sharedRoute)
        } else {
            trip?.takeIf { it.pathPoints.orEmpty().size >= 2 }?.let { drawRouteMap(s, it) }
        }

        if (payload.warnings.isNotEmpty()) {
            sectionHeader(s, "Completeness")
            payload.warnings.forEach { text(s, "• $it", captionPaint) }
        }

        // Notes (strip the legacy "Paddocks:" prefix line like iOS)
        val notes = record.notes.orEmpty()
            .split("\n")
            .filterNot { it.startsWith("Paddocks:") }
            .joinToString("\n")
            .trim()
        if (notes.isNotEmpty()) {
            sectionHeader(s, "Notes")
            text(s, notes, bodyPaint)
        }

        // Links
        if (trip != null || workTask != null) {
            sectionHeader(s, "Links")
            trip?.let { row(s, "Trip", it.displayLabel) }
            workTask?.let { row(s, "Work Task", it.displayLabel) }
        }

        // Footer
        s.y += 20f
        s.ensure(30f)
        drawDivider(s)
        s.y += 4f
        val generated = "Generated by VineTrack \u2022 " +
            SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(Date())
        text(s, generated, captionPaint)
    }

    private fun drawSharedRouteMap(s: PageState, bitmap: Bitmap) {
        sectionHeader(s, "Route Map")
        val height = 250f
        s.ensure(height + 12f)
        val destination = RectF(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y + height)
        s.canvas.drawBitmap(bitmap, null, destination, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
        s.y += height + 12f
    }

    private fun drawRouteMap(s: PageState, trip: Trip) {
        val points = trip.pathPoints.orEmpty()
        if (points.size < 2) return
        sectionHeader(s, "Route Map")
        val height = 250f
        s.ensure(height + 12f)
        val rect = RectF(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y + height)
        s.canvas.drawRoundRect(rect, 8f, 8f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(42, 48, 42) })
        val minLat = points.minOf { it.latitude }
        val maxLat = points.maxOf { it.latitude }
        val minLon = points.minOf { it.longitude }
        val maxLon = points.maxOf { it.longitude }
        val latSpan = (maxLat - minLat).takeIf { it > 0.000001 } ?: 0.000001
        val lonSpan = (maxLon - minLon).takeIf { it > 0.000001 } ?: 0.000001
        fun x(index: Int): Float = rect.left + 12f + (((points[index].longitude - minLon) / lonSpan) * (rect.width() - 24f)).toFloat()
        fun y(index: Int): Float = rect.bottom - 12f - (((points[index].latitude - minLat) / latSpan) * (rect.height() - 24f)).toFloat()
        val colors = intArrayOf(
            Color.rgb(219, 26, 26), Color.rgb(245, 82, 15), Color.rgb(250, 173, 13),
            Color.rgb(166, 194, 20), Color.rgb(26, 158, 56),
        )
        val routePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeWidth = 4f; strokeCap = Paint.Cap.ROUND }
        for (index in 0 until points.lastIndex) {
            val progress = index.toDouble() / points.lastIndex.coerceAtLeast(1)
            routePaint.color = colors[(progress * colors.size).toInt().coerceIn(0, colors.lastIndex)]
            s.canvas.drawLine(x(index), y(index), x(index + 1), y(index + 1), routePaint)
        }
        val markerPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        markerPaint.color = Color.RED
        s.canvas.drawCircle(x(0), y(0), 7f, markerPaint)
        markerPaint.color = Color.GREEN
        s.canvas.drawCircle(x(points.lastIndex), y(points.lastIndex), 7f, markerPaint)
        s.y += height + 12f
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
        s.canvas.drawText(value, MARGIN + LABEL_WIDTH, s.y, bodyBoldPaint)
        s.y += 6f
    }

    /** Compact fill-duration label (e.g. "2m 5s" / "45s"), mirroring the iOS PDF wording. */
    private fun formatFillDuration(seconds: Long): String {
        val mins = (seconds / 60).toInt()
        val secs = (seconds % 60).toInt()
        return if (mins > 0) "${mins}m ${secs}s" else "${secs}s"
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

    /** Compact currency label (e.g. "$1,250", "$42.50"), matching the on-screen formatter. */
    private fun money(value: Double): String {
        val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong())
        else "%,.2f".format(value)
        return "$$rounded"
    }

    private fun fmt(value: Double): String =
        if (value % 1.0 == 0.0) value.toLong().toString()
        else String.format(Locale.getDefault(), "%.2f", value).trimEnd('0').trimEnd('.')

    private fun chemUnitAbbrev(unit: String): String = when (unit.lowercase(Locale.getDefault())) {
        "litres", "l" -> "L"
        "ml" -> "mL"
        "kilograms", "kg" -> "Kg"
        "g", "grams" -> "g"
        else -> unit
    }

    private fun formatDate(epochMs: Long?): String? =
        epochMs?.let { SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(Date(it)) }

    private fun timeOfDay(iso: String?): String? =
        parseIsoToEpochMs(iso)?.let { SimpleDateFormat("h:mm a", Locale.getDefault()).format(Date(it)) }

    private fun tripDateTime(iso: String?): String? =
        parseIsoToEpochMs(iso)?.let {
            SimpleDateFormat("dd/MM/yyyy h:mm a", Locale.getDefault()).format(Date(it))
        }

}
