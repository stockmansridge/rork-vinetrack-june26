package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.net.Uri
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.resolveSprayEquipmentName
import com.rork.vinetrack.data.model.SprayEquipment
import com.rork.vinetrack.data.model.parseIsoToEpochMs
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
    fun exportAndShare(
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
    ): Boolean {
        return try {
            val doc = PdfDocument()
            val s = PageState(doc)
            render(
                s, record, vineyardName, machines, equipment, trip, workTask,
                canViewFinancials, fuelPurchases, operatorCategories, paddocks, logo,
            )
            s.finish()

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, fileName(record))
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
    ) {
        // Header
        val textX = PdfHeaderUtil.drawLogo(s.canvas, logo, MARGIN, s.y)
        s.canvas.drawText(vineyardName.ifBlank { "Vineyard" }, textX, s.y + 18f, titlePaint)
        s.y += 26f
        s.canvas.drawText("Spray Record", textX, s.y + 12f, headerPaint)
        s.y += 22f
        drawDivider(s)
        s.y += 8f

        record.sprayReference?.takeIf { it.isNotBlank() }?.let {
            text(s, it, sprayNamePaint)
        }
        trip?.paddockName?.takeIf { it.isNotBlank() }?.let {
            text(s, "Block: $it", bodyPaint)
        }

        // Trip Information
        if (trip != null) {
            sectionHeader(s, "Trip Information")
            tripDateTime(trip.startTime)?.let { row(s, "Start Time", it) }
            tripDateTime(trip.endTime)?.let { row(s, "End Time", it) }
            trip.personName?.takeIf { it.isNotBlank() }?.let { row(s, "Operator", it) }
            trip.totalDistance?.takeIf { it > 0 }?.let {
                row(s, "Total Distance", "${fmt(it)} m")
            }
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
            val done = trip.completedPaths?.toSet() ?: emptySet()
            val skip = trip.skippedPaths?.toSet() ?: emptySet()
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

        // Conditions
        sectionHeader(s, "Conditions")
        formatDate(record.dateEpochMs)?.let { row(s, "Date", it) }
        timeOfDay(record.startTime)?.let { row(s, "Start Time", it) }
        timeOfDay(record.endTime)?.let { row(s, "End Time", it) }
        if (trip == null) {
            // Android records carry no standalone operator field; only show via trip.
        }
        record.temperature?.let { row(s, "Temperature", "${fmt(it)}\u00B0C") }
        record.windSpeed?.let { row(s, "Wind Speed", "${fmt(it)} km/h") }
        record.windDirection?.takeIf { it.isNotBlank() }?.let { row(s, "Wind Direction", it) }
        record.humidity?.let { row(s, "Humidity", "${fmt(it)}%") }
        record.sprayReference?.takeIf { it.isNotBlank() }?.let { row(s, "Spray Ref #", it) }

        // Equipment
        val machineName = record.displayMachine(machines)
        val sprayEquipName = resolveSprayEquipmentName(record, equipment)
        val hasEquipment = !machineName.isNullOrBlank() || !sprayEquipName.isNullOrBlank() ||
            !record.tractorGear.isNullOrBlank() || !record.numberOfFansJets.isNullOrBlank() ||
            record.averageSpeed != null
        if (hasEquipment) {
            sectionHeader(s, "Equipment")
            sprayEquipName?.takeIf { it.isNotBlank() }?.let { row(s, "Spray Equipment", it) }
            machineName?.takeIf { it.isNotBlank() }?.let { row(s, "Tractor / Machine", it) }
            record.tractorGear?.takeIf { it.isNotBlank() }?.let { row(s, "Tractor Gear", it) }
            record.numberOfFansJets?.takeIf { it.isNotBlank() }?.let { row(s, "No. Fans/Jets", it) }
            record.averageSpeed?.let { row(s, "Average Speed", "${fmt(it)} km/h") }
        }

        // Tanks
        val tanks = record.tanks.orEmpty()
        for (tank in tanks) {
            sectionHeader(s, "Tank ${tank.tankNumber}")
            if (tank.waterVolume > 0) row(s, "Water Volume", "${fmt(tank.waterVolume)} L")
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
                    if (chem.volumePerTank > 0) {
                        s.canvas.drawText("${fmt(chem.volumePerTank)} $unit", c1, s.y, bodyBoldPaint)
                    }
                    if (chem.ratePerHa > 0) {
                        s.canvas.drawText("${fmt(chem.ratePerHa)} $unit/ha", c2, s.y, bodyBoldPaint)
                    }
                    s.y += 18f
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
            )
            val fuel = cost.fuel
            val hasAnyValue = cost.totalCost > 0 ||
                cost.labour.cost > 0 ||
                fuel.fuelCost != null ||
                fuel.litres != null ||
                (cost.chemical?.cost ?: 0.0) > 0
            if (hasAnyValue) {
                sectionHeader(s, "Cost Breakdown")
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

    private fun fileName(record: SprayRecord): String {
        val ref = record.sprayReference?.takeIf { it.isNotBlank() } ?: "Record"
        val date = record.dateEpochMs?.let {
            SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(it))
        } ?: SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        val safe = "${ref}_$date"
            .replace(" ", "_")
            .replace("/", "-")
            .replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
        return "SprayRecord_$safe.pdf"
    }
}
