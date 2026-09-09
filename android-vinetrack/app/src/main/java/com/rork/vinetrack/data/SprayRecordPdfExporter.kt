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
import com.rork.vinetrack.R
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
import kotlinx.coroutines.withTimeout
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
    private class PageState(val doc: PdfDocument, private val officialLogo: Bitmap?, private val isManualEntry: Boolean) {
        var page: PdfDocument.Page = doc.startPage(pageInfo(1))
        var canvas = page.canvas
        var y = MARGIN
        private var pageNumber = 1

        init { drawManualWatermark() }

        private fun drawManualWatermark() {
            if (!isManualEntry) return
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.rgb(111, 45, 168)
                alpha = 24
                textSize = 58f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                textAlign = Paint.Align.CENTER
            }
            canvas.save()
            canvas.rotate(-32f, PAGE_WIDTH / 2f, PAGE_HEIGHT / 2f)
            canvas.drawText("MANUAL ENTRY", PAGE_WIDTH / 2f, PAGE_HEIGHT / 2f, paint)
            canvas.restore()
        }

        private fun pageInfo(n: Int) =
            PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, n).create()

        fun ensure(needed: Float) {
            if (y + needed > PAGE_HEIGHT - MARGIN - 18f) newPage()
        }

        private fun drawFooter() {
            officialLogo?.let { logo ->
                val maxWidth = 58f
                val maxHeight = 20f
                val scale = minOf(maxWidth / logo.width, maxHeight / logo.height)
                val width = logo.width * scale
                val height = logo.height * scale
                canvas.drawBitmap(logo, null, RectF(MARGIN, PAGE_HEIGHT - 30f, MARGIN + width, PAGE_HEIGHT - 30f + height), Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
            }
            val pageLabel = "Page $pageNumber"
            canvas.drawText(pageLabel, PAGE_WIDTH - MARGIN - captionPaint.measureText(pageLabel), PAGE_HEIGHT - 18f, captionPaint)
        }

        fun newPage() {
            drawFooter()
            doc.finishPage(page)
            pageNumber += 1
            page = doc.startPage(pageInfo(pageNumber))
            canvas = page.canvas
            drawManualWatermark()
            y = MARGIN
        }

        fun finish() {
            drawFooter()
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
        vineyardLogoPath: String? = null,
        regionFormatter: RegionFormatter = RegionFormatter(),
        vineyardTimeZone: String = regionFormatter.settings.timezone ?: "UTC",
        pinCount: Int = 0,
    ): Boolean {
        return try {
            require(trip != null) { "Spray record not available yet—sync and retry" }
            val session = SessionStore(context)
            val resolvedVineyardLogo = if (!vineyardLogoPath.isNullOrBlank()) {
                val bytes = withTimeout(5_000) { VineyardLogoRepository(session).download(vineyardLogoPath) }
                requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)) { "Configured vineyard logo could not be decoded" }
            } else logo
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
            val repository = SprayReportRepository(session)
            repository.captureUnavailableIfDue(trip, trip.endTime?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() } ?: java.time.Instant.now(), isFinal = trip.endTime != null)
            val payload = runCatching { repository.fetch(trip.id) }.getOrDefault(offlinePayload)
            val resolvedRoute = payload.route ?: runCatching { repository.ensureRoute(trip) }.getOrNull()
            val sharedRoute = resolvedRoute?.let { route ->
                runCatching {
                    val bytes = repository.downloadRoute(route)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }.getOrNull()
            }
            val doc = PdfDocument()
            val officialLogo = BitmapFactory.decodeResource(context.resources, R.drawable.vinetrack_logo)
            val s = PageState(doc, officialLogo, payload.provenance?.isManualEntry == true || record.isManualEntry)
            render(
                s, payload, record, vineyardName, machines, equipment, trip, workTask,
                canViewFinancials, fuelPurchases, operatorCategories, paddocks, resolvedVineyardLogo,
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
        if (payload.provenance?.isManualEntry == true || record.isManualEntry) {
            val manualPaint = Paint(headerPaint).apply { color = Color.rgb(111, 45, 168) }
            s.canvas.drawText("Manual entry", textX, s.y + 12f, manualPaint)
            s.y += 22f
        }
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
        val treatedBlocks = payload.blocks
        if (treatedBlocks == null) text(s, SprayBlockAttributionDisplay.NOT_RECORDED, bodyPaint)
        else treatedBlocks.forEach { block -> text(s, "\u2022 ${block.name}", bodyPaint) }

        // Trip Information
        if (trip != null) {
            sectionHeader(s, "Trip Information")
            tripDateTime(trip.startTime)?.let { row(s, "Start Time", it) }
            tripDateTime(trip.endTime)?.let { row(s, "End Time", it) }
            row(s, "Operator", payload.trip.operatorName ?: "Not recorded")
            row(s, "Active Duration", payload.trip.activeDurationSeconds?.let { com.rork.vinetrack.data.model.formatTripDuration(it) } ?: "Not recorded")
            payload.trip.elapsedDurationSeconds?.let { row(s, "Elapsed Duration", com.rork.vinetrack.data.model.formatTripDuration(it)) }
            payload.trip.pausedDurationSeconds?.let { row(s, "Paused Duration", com.rork.vinetrack.data.model.formatTripDuration(it)) }
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
            !payload.equipment.tractorGear.isNullOrBlank() || !payload.equipment.numberOfFansJets.isNullOrBlank() || payload.equipment.averageSpeedKmh != null
        if (hasEquipment) {
            sectionHeader(s, "Equipment")
            row(s, "Tractor", payload.equipment.tractorName ?: "Not recorded")
            row(s, "Engine hours start", payload.equipment.startEngineHours?.let { "${fmt(it)} h" } ?: "Not recorded")
            row(s, "Engine hours end", payload.equipment.endEngineHours?.let { "${fmt(it)} h" } ?: "Not recorded")
            row(s, "Engine hours used", payload.equipment.engineHoursUsed?.let { "${fmt(it)} h" } ?: "Not recorded")
            row(s, "Spray Unit", payload.equipment.sprayUnitName ?: "Not recorded")
            payload.equipment.tractorGear?.takeIf { it.isNotBlank() }?.let { row(s, "Tractor Gear", it) }
            payload.equipment.numberOfFansJets?.takeIf { it.isNotBlank() }?.let { row(s, "No. Fans/Jets", it) }
            payload.equipment.averageSpeedKmh?.let { row(s, "Average Speed", regionFormatter.formatSpeed(it)) }
            row(s, "Fuel consumption", payload.equipment.fuelConsumptionLPerHour?.let { "${fmt(it)} L/hr · ${payload.equipment.fuelConsumptionSource?.replace('_', ' ')}" } ?: "Not recorded")
        }

        payload.application?.let { application ->
            sectionHeader(s, "Application")
            row(s, "Operation", application.operationType ?: "Not recorded")
            row(s, "Application mode", application.applicationMode?.replace('_', ' ')?.replaceFirstChar { it.uppercase() } ?: "Not recorded")
            row(s, "Treated area", application.treatedAreaHa?.let { regionFormatter.formatArea(it) } ?: "Not recorded")
            row(s, "Carrier total", application.totalCarrierLitres?.let { regionFormatter.formatVolume(it) } ?: "Not recorded")
            application.notes?.let { text(s, "Notes: $it", bodyPaint) }
        }
        payload.programStep?.let { step ->
            sectionHeader(s, "Program / Step")
            row(s, "Link", step.linkState.replace('_', ' ').replaceFirstChar { it.uppercase() })
            row(s, "Step", step.name ?: "Not recorded")
            step.target?.let { row(s, "Target", it) }
        }

        // Canonical one-table-per-tank worksheet with wrapping names.
        val tanks = record.tanks.orEmpty()
        payload.tanks.sortedBy { it.tankNumber }.forEach { reportTank ->
            sectionHeader(s, "Tank ${reportTank.tankNumber} — Planned / Actual")
            drawPlannedActualTable(s, reportTank, regionFormatter)
            tanks.firstOrNull { it.tankNumber == reportTank.tankNumber }?.chemicals?.takeIf { it.isNotEmpty() }?.let { lines ->
                text(s, "Rate / basis", bodyBoldPaint)
                lines.forEach { chemical ->
                    val unit = chemUnitAbbrev(chemical.unit)
                    val rate = when { chemical.ratePer100L > 0 -> "${fmt(chemical.ratePer100L)} $unit/100 L"; chemical.ratePerHa > 0 -> "${fmt(chemical.ratePerHa)} $unit/ha"; else -> "Not recorded" }
                    text(s, "${chemical.name}: $rate", captionPaint)
                }
            }
        }

        if (payload.amendments.isNotEmpty()) {
            sectionHeader(s, "Amendment History")
            payload.amendments.forEach { amendment ->
                val before = amendment.previousValue.toString().takeUnless { it == "null" } ?: "Not recorded"
                val after = amendment.newValue.toString().takeUnless { it == "null" } ?: "Not recorded"
                text(s, "Tank ${amendment.tankNumber} · ${amendment.field}: $before → $after", bodyPaint)
                text(s, "Updated by ${amendment.editorName} · ${amendment.editedAt} (${payload.identity.vineyardTimeZone})", captionPaint)
            }
        }

        // Chemical Totals (All Tanks)
        val totals = payload.plannedChemicalTotals.ifEmpty {
            payload.tanks.flatMap { it.chemicals }.filter { it.plannedAmountBase != null }
                .groupBy { it.savedChemicalId ?: "${it.name.trim().lowercase()}|${if (it.unit.equals("Litres", true) || it.unit.equals("mL", true)) "liquid" else "mass"}" }
                .map { (key, lines) -> SprayReportPayloadV1.ChemicalTotal(key, lines.first().name, if (lines.first().unit.equals("Litres", true) || lines.first().unit.equals("mL", true)) "Litres" else "Kg", lines.sumOf { it.plannedAmountBase ?: 0.0 }) }
        }
        if (totals.isNotEmpty()) {
            sectionHeader(s, "Planned Chemical Totals (All Tanks)")
            totals.forEach { total -> row(s, total.name, "${fmt(chemicalUnitFromBase(total.unit, total.actualAmountBase))} ${chemUnitAbbrev(total.unit)}") }
        }
        if (payload.actualChemicalTotals.isNotEmpty()) {
            sectionHeader(s, "Actual Chemical Totals (All Tanks)")
            payload.actualChemicalTotals.forEach { total ->
                row(s, total.name, "${fmt(chemicalUnitFromBase(total.unit, total.actualAmountBase))} ${chemUnitAbbrev(total.unit)}")
            }
        }

        // Tank Sessions (read-only; only when the linked trip recorded fills) — Stage 3F-2d.
        val tankSessions = payload.tankSessions
        if (tankSessions.isNotEmpty()) {
            sectionHeader(s, "Tank Sessions")
            for (session in tankSessions.sortedBy { it.tankNumber }) {
                row(s, "Tank ${session.tankNumber}", session.status)
                if (session.startRow != null && session.endRow != null) rowIndented(s, "Recorded range", "${fmt(session.startRow)}–${fmt(session.endRow)}")
                rowIndented(s, "Assignment evidence", session.assignmentSource.replace('_', ' ').replaceFirstChar { it.uppercase() })
            }
        }

        // Cost Breakdown (owner/manager only, linked trip only) — Stage 3F-3c-i.
        // Mirrors the on-screen cost card via the pure TripCostEstimator. The
        // whole section is omitted for non-financial roles or when no trip is
        // linked (chemical-only behaviour elsewhere is unchanged).
        if (canViewFinancials && payload.cost != null) {
            val cost = payload.cost
            sectionHeader(s, "Authorized Cost Summary")
            row(s, "Fuel used", cost.fuelLitres?.let { regionFormatter.formatVolume(it) } ?: "Not recorded")
            row(s, "Fuel cost", cost.fuelCost?.let(::money) ?: "Not recorded")
            row(s, "Chemical cost", cost.chemicalCost?.let(::money) ?: "Not recorded")
            row(s, "Labour cost", cost.labourCost?.let(::money) ?: "Not recorded")
            row(s, "Total", cost.totalCost?.let(::money) ?: "Incomplete")
            if (!cost.isComplete) text(s, cost.basis, captionPaint)
        } else if (canViewFinancials && trip != null) {
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

    private fun drawPlannedActualTable(s: PageState, tank: SprayReportPayloadV1.Tank, formatter: RegionFormatter) {
        val itemWidth = 285f
        val valueWidth = (PAGE_WIDTH - MARGIN * 2 - itemWidth) / 2f
        fun header() {
            s.ensure(20f)
            s.canvas.drawText("ITEM", MARGIN, s.y + 12f, captionPaint)
            s.canvas.drawText("PLANNED", MARGIN + itemWidth, s.y + 12f, captionPaint)
            s.canvas.drawText("ACTUAL", MARGIN + itemWidth + valueWidth, s.y + 12f, captionPaint)
            s.y += 20f
        }
        fun tableRow(item: String, planned: String, actual: String) {
            val itemLines = wrap(item, bodyPaint, itemWidth - 8f)
            val rowHeight = maxOf(24f, itemLines.size * 15f + 8f)
            if (s.y + rowHeight > PAGE_HEIGHT - MARGIN - 18f) { s.newPage(); header() }
            itemLines.forEachIndexed { index, line -> s.canvas.drawText(line, MARGIN, s.y + 14f + index * 15f, bodyPaint) }
            s.canvas.drawText(planned, MARGIN + itemWidth, s.y + 14f, bodyBoldPaint)
            s.canvas.drawText(actual, MARGIN + itemWidth + valueWidth, s.y + 14f, bodyBoldPaint)
            s.y += rowHeight
            drawDivider(s)
        }
        header()
        tableRow("Water", tank.plannedWaterLitres?.let(formatter::formatVolume) ?: "Not planned", tank.actualWaterLitres?.let { if (it == 0.0) "0 L" else formatter.formatVolume(it) } ?: "Not recorded")
        tank.chemicals.forEach { chemical ->
            val unit = chemUnitAbbrev(chemical.unit)
            val planned = chemical.plannedAmountBase?.let { "${fmt(chemicalUnitFromBase(chemical.unit, it))} $unit" } ?: "—"
            val actual = chemical.actualAmountBase?.let { if (it == 0.0) "Not added" else "${fmt(chemicalUnitFromBase(chemical.unit, it))} $unit" } ?: "Not recorded"
            val prefix = when (chemical.usageKind) { "substitution" -> "Substitution: "; "additional" -> "Additional: "; else -> "" }
            tableRow(prefix + chemical.name, planned, actual)
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
