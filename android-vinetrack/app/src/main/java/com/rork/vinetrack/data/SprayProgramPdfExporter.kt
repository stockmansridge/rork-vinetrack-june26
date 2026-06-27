package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
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
import com.rork.vinetrack.data.model.formatTripDuration
import com.rork.vinetrack.data.model.resolveSprayTrip
import com.rork.vinetrack.data.model.sprayRecordStatus
import com.rork.vinetrack.data.model.SprayStatus
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Generates a local, program-level (multi-record) spray PDF and shares it
 * through the Android share sheet. Mirrors the iOS
 * `SprayProgramExportService.generateProgramPDF`: a landscape table — one row
 * per spray record (Date / Name / Block / Chemicals / Tanks / Rate / Temp /
 * Wind / Equipment / Operator / Status) — followed by a "Chemical Totals (All
 * Records)" summary.
 *
 * Scope matches the program CSV export: the current operational (non-template)
 * result set after filter/search/sort, passed in by the caller. Templates are
 * excluded.
 *
 * A "Cost Summary (All Records)" block — per-chemical cost, Chemical Subtotal,
 * Fuel (with litres), Labour, Total Cost, and a concise aggregate costing
 * status — is appended only when the caller is financially permitted
 * ([canViewFinancials], i.e. owner/manager, mirroring iOS `canViewFinancials`)
 * AND at least one record carries cost data. Fuel/labour/total are derived from
 * the pure [TripCostEstimator] for linked records only (Stage 3F-3c-iii); they
 * are never fabricated for unlinked records, which contribute chemical cost
 * only. Program-level cost/ha is intentionally omitted (iOS does not render it,
 * and the legacy `totalSprayArea` source differs from the estimator's trip
 * paddock area). Supervisors/operators export the same PDF without any cost
 * content. The PDF is written to the app cache (`cache/exports`) and shared via
 * [FileProvider]; it is never uploaded to Supabase.
 */
object SprayProgramPdfExporter {

    // A4 landscape (matches iOS 842 x 595).
    private const val PAGE_WIDTH = 842
    private const val PAGE_HEIGHT = 595
    private const val MARGIN = 36f

    private val accent = Color.rgb(85, 107, 47) // olive, matching iOS VineyardTheme

    /** Column layout: (title, x-offset from margin, width). Mirrors iOS columns. */
    private data class Column(val title: String, val x: Float, val width: Float)

    private val columns: List<Column> = listOf(
        Column("DATE", 0f, 68f),
        Column("NAME", 68f, 80f),
        Column("BLOCK", 148f, 80f),
        Column("CHEMICALS", 228f, 160f),
        Column("TANKS", 388f, 40f),
        Column("RATE (L/HA)", 428f, 60f),
        Column("TEMP", 488f, 42f),
        Column("WIND", 530f, 50f),
        Column("EQUIP.", 580f, 60f),
        Column("OPERATOR", 640f, 70f),
        Column("STATUS", 710f, 56f),
    )

    private class PageState(val doc: PdfDocument) {
        var page: PdfDocument.Page = doc.startPage(pageInfo(1))
        var canvas = page.canvas
        var y = MARGIN
        private var pageNumber = 1

        private fun pageInfo(n: Int) =
            PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, n).create()

        fun ensure(needed: Float, onNewPage: (PageState) -> Unit = {}) {
            if (y + needed > PAGE_HEIGHT - MARGIN) {
                newPage()
                onNewPage(this)
            }
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
        textSize = 20f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val captionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.GRAY
        textSize = 9f
    }
    private val headerCellPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 8f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val bodyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        textSize = 8f
    }
    private val bodyBoldPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        textSize = 8f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val summaryTitlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accent
        textSize = 10f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val headerBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = accent }
    private val rowBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(245, 245, 245) }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(80, 85, 107, 47)
        strokeWidth = 0.5f
    }

    /**
     * Build the program PDF for [records], write it to the cache, and launch the
     * share sheet. Returns false if generation failed (the caller can surface a
     * message) or if [records] is empty; never throws.
     */
    fun exportAndShare(
        context: Context,
        records: List<SprayRecord>,
        trips: List<Trip>,
        vineyardName: String,
        canViewFinancials: Boolean = false,
        machines: List<VineyardMachine> = emptyList(),
        fuelPurchases: List<FuelPurchase> = emptyList(),
        operatorCategories: List<OperatorCategory> = emptyList(),
        paddocks: List<Paddock> = emptyList(),
        logo: Bitmap? = null,
    ): Boolean {
        if (records.isEmpty()) return false
        return try {
            val doc = PdfDocument()
            val s = PageState(doc)
            render(s, records, trips, vineyardName, canViewFinancials, machines, fuelPurchases, operatorCategories, paddocks, logo)
            s.finish()

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, fileName(vineyardName))
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
                Intent.createChooser(share, "Share spray program").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("SprayProgramPdfExporter", "Program PDF export failed", e)
            false
        }
    }

    private fun render(
        s: PageState,
        records: List<SprayRecord>,
        trips: List<Trip>,
        vineyardName: String,
        canViewFinancials: Boolean,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        operatorCategories: List<OperatorCategory>,
        paddocks: List<Paddock>,
        logo: Bitmap?,
    ) {
        // Header
        val textX = PdfHeaderUtil.drawLogo(s.canvas, logo, MARGIN, s.y)
        s.canvas.drawText(vineyardName.ifBlank { "Vineyard" }, textX, s.y + 18f, titlePaint)
        s.y += 24f
        s.canvas.drawText("Spray Program", textX, s.y + 12f, summaryTitlePaint)
        s.y += 20f

        val now = Date()
        val generated = "Generated: " +
            SimpleDateFormat("dd/MM/yyyy h:mm a", Locale.getDefault()).format(now) +
            " \u2022 ${records.size} record${if (records.size == 1) "" else "s"} (templates excluded)"
        s.canvas.drawText(generated, MARGIN, s.y + 9f, captionPaint)
        s.y += 16f

        // Status summary line
        val completed = records.count { sprayRecordStatus(it, trips) == SprayStatus.COMPLETED }
        val inProgress = records.count { sprayRecordStatus(it, trips) == SprayStatus.IN_PROGRESS }
        val notStarted = records.count { sprayRecordStatus(it, trips) == SprayStatus.NOT_STARTED }
        val summary = "Completed: $completed   \u2022   In Progress: $inProgress   \u2022   Not Started: $notStarted"
        s.canvas.drawText(summary, MARGIN, s.y + 9f, captionPaint)
        s.y += 16f

        drawTableHeader(s)

        records.forEachIndexed { index, record ->
            s.ensure(20f) { drawTableHeader(it) }
            drawRow(s, index, record, trips)
        }

        drawChemicalTotals(s, records)

        drawRowCoverage(s, records, trips)

        drawTankFills(s, records, trips)

        if (canViewFinancials) {
            drawCostSummary(s, records, trips, machines, fuelPurchases, operatorCategories, paddocks)
        }

        // Footer
        s.y += 16f
        s.ensure(24f)
        s.canvas.drawLine(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y, linePaint)
        s.y += 6f
        val footer = "Generated by VineTrack \u2022 " +
            SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(now)
        s.canvas.drawText(footer, MARGIN, s.y + 8f, captionPaint)
    }

    private fun drawTableHeader(s: PageState) {
        val contentWidth = PAGE_WIDTH - MARGIN * 2
        s.canvas.drawRect(RectF(MARGIN, s.y, MARGIN + contentWidth, s.y + 18f), headerBgPaint)
        for (col in columns) {
            s.canvas.drawText(col.title, MARGIN + col.x + 3f, s.y + 12f, headerCellPaint)
        }
        s.y += 18f
    }

    private fun drawRow(s: PageState, index: Int, record: SprayRecord, trips: List<Trip>) {
        val contentWidth = PAGE_WIDTH - MARGIN * 2
        if (index % 2 == 0) {
            s.canvas.drawRect(RectF(MARGIN, s.y, MARGIN + contentWidth, s.y + 20f), rowBgPaint)
        }
        val rowY = s.y + 13f
        val trip = resolveSprayTrip(record, trips)

        cell(s, 0, dash(record.dateEpochMs?.let { dateFmt.format(Date(it)) }), rowY, bodyPaint)
        cell(s, 1, dash(record.displayLabel), rowY, bodyBoldPaint)
        cell(s, 2, dash(trip?.paddockName), rowY, bodyPaint)

        val chemicals = record.chemicalNames.joinToString(", ")
        cell(s, 3, dash(chemicals.takeIf { it.isNotBlank() }), rowY, bodyPaint)

        cell(s, 4, "${record.tankCount}", rowY, bodyPaint)

        val tanks = record.tanks.orEmpty()
        val avgRate = if (tanks.isEmpty()) 0.0 else tanks.sumOf { it.sprayRatePerHa } / tanks.size
        cell(s, 5, if (avgRate > 0) String.format(Locale.getDefault(), "%.0f", avgRate) else "\u2013", rowY, bodyPaint)

        cell(s, 6, record.temperature?.let { String.format(Locale.getDefault(), "%.0f\u00B0C", it) } ?: "\u2013", rowY, bodyPaint)
        cell(s, 7, record.windSpeed?.let { String.format(Locale.getDefault(), "%.0f km/h", it) } ?: "\u2013", rowY, bodyPaint)
        cell(s, 8, dash(record.equipmentType), rowY, bodyPaint)
        cell(s, 9, dash(trip?.personName), rowY, bodyPaint)

        val status = when (sprayRecordStatus(record, trips)) {
            SprayStatus.COMPLETED -> "Done"
            SprayStatus.IN_PROGRESS -> "Active"
            SprayStatus.NOT_STARTED -> "Pending"
        }
        val statusPaint = Paint(bodyBoldPaint).apply {
            color = if (sprayRecordStatus(record, trips) == SprayStatus.COMPLETED) accent else Color.rgb(200, 40, 40)
        }
        cell(s, 10, status, rowY, statusPaint)

        s.y += 20f
    }

    private fun drawChemicalTotals(s: PageState, records: List<SprayRecord>) {
        val totals = records
            .flatMap { it.tanks.orEmpty() }
            .flatMap { it.chemicals }
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
        if (totals.isEmpty()) return

        s.y += 16f
        s.ensure(40f)
        s.canvas.drawLine(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y, linePaint)
        s.y += 14f
        s.canvas.drawText("Chemical Totals (All Records)", MARGIN, s.y, summaryTitlePaint)
        s.y += 16f
        for ((name, total, unit) in totals) {
            s.ensure(14f)
            s.canvas.drawText(name, MARGIN + 8f, s.y, bodyPaint)
            s.canvas.drawText(String.format(Locale.getDefault(), "%.2f%s", total, unit), MARGIN + 220f, s.y, bodyBoldPaint)
            s.y += 14f
        }
    }

    /**
     * Concise per-record row-coverage summary for planned spray trips. One line
     * per record whose linked trip carries a row sequence; Free Drive / no-plan
     * records are omitted. Avoids a large per-row table to keep the program
     * report readable. Read-only.
     */
    private fun drawRowCoverage(s: PageState, records: List<SprayRecord>, trips: List<Trip>) {
        val lines = records.mapNotNull { record ->
            val trip = resolveSprayTrip(record, trips)
            if (trip == null || !trip.hasRowPlan) return@mapNotNull null
            val pattern = TrackingPattern.fromRaw(trip.trackingPattern).title
            val label = record.displayLabel.ifBlank { "Spray" }
            label to "$pattern  \u2022  Planned ${trip.plannedPathCount}  \u2022  Done ${trip.completedRowCount}" +
                "  \u2022  Skipped ${trip.skippedRowCount}  \u2022  Pending ${trip.notCompletedRowCount}"
        }
        if (lines.isEmpty()) return

        s.y += 16f
        s.ensure(40f)
        s.canvas.drawLine(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y, linePaint)
        s.y += 14f
        s.canvas.drawText("Row Coverage (Planned Trips)", MARGIN, s.y, summaryTitlePaint)
        s.y += 16f
        for ((name, detail) in lines) {
            s.ensure(14f)
            s.canvas.drawText(name, MARGIN + 8f, s.y, bodyBoldPaint)
            s.canvas.drawText(detail, MARGIN + 200f, s.y, bodyPaint)
            s.y += 14f
        }
    }

    /**
     * Concise per-record tank fill-timer summary for spray trips that recorded
     * tank sessions. One line per record: tank count, total recorded fill time,
     * and the active tank if one is still open. Records without tank sessions
     * are omitted; avoids a large per-tank table to keep the report readable.
     * Read-only.
     */
    private fun drawTankFills(s: PageState, records: List<SprayRecord>, trips: List<Trip>) {
        val lines = records.mapNotNull { record ->
            val trip = resolveSprayTrip(record, trips)
            val sessions = trip?.tankSessions.orEmpty()
            if (sessions.isEmpty()) return@mapNotNull null
            val totalFill = sessions.sumOf { it.fillDurationSeconds ?: 0L }
            val label = record.displayLabel.ifBlank { "Spray" }
            val parts = buildList {
                add("${sessions.size} tanks")
                if (totalFill > 0) add("fill ${formatTripDuration(totalFill)}")
                trip?.activeTankNumber?.let { add("active tank $it") }
            }
            label to parts.joinToString("  \u2022  ")
        }
        if (lines.isEmpty()) return

        s.y += 16f
        s.ensure(40f)
        s.canvas.drawLine(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y, linePaint)
        s.y += 14f
        s.canvas.drawText("Tank Fills", MARGIN, s.y, summaryTitlePaint)
        s.y += 16f
        for ((name, detail) in lines) {
            s.ensure(14f)
            s.canvas.drawText(name, MARGIN + 8f, s.y, bodyBoldPaint)
            s.canvas.drawText(detail, MARGIN + 200f, s.y, bodyPaint)
            s.y += 14f
        }
    }

    /**
     * Gated full cost summary (Stage 3F-3c-iii): per-chemical cost (grouped by
     * product name across all records), Chemical Subtotal, aggregate Fuel (cost
     * + litres), Labour, and Total Cost, plus a concise aggregate costing status
     * line. Fuel/labour are summed from the pure [TripCostEstimator] over linked
     * records only; unlinked records contribute chemical cost only and never
     * fabricate fuel/labour/total trip data. Program-level cost/ha is
     * intentionally omitted. Rendered only when the caller is financially
     * permitted and at least one record carries cost data.
     */
    private fun drawCostSummary(
        s: PageState,
        records: List<SprayRecord>,
        trips: List<Trip>,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        operatorCategories: List<OperatorCategory>,
        paddocks: List<Paddock>,
    ) {
        // Per-chemical costs across all records (covers records without a
        // linked trip, mirroring the existing grouped behaviour).
        val chemCosts = records
            .flatMap { it.tanks.orEmpty() }
            .flatMap { it.chemicals }
            .filter { it.name.isNotBlank() && it.costPerTank > 0 }
            .groupBy { it.name.trim().lowercase(Locale.getDefault()) }
            .map { (_, chems) -> chems.first().name to chems.sumOf { it.costPerTank } }
            .sortedBy { it.first.lowercase(Locale.getDefault()) }
        val chemicalSubtotal = chemCosts.sumOf { it.second }

        // Aggregate fuel + labour from the estimator over linked records only.
        var fuelLitres = 0.0
        var fuelCost = 0.0
        var labourCost = 0.0
        var complete = 0
        var partial = 0
        var unavailable = 0
        var linkedCount = 0

        records.forEach { record ->
            val trip = resolveSprayTrip(record, trips) ?: return@forEach
            linkedCount++
            val est = TripCostEstimator.estimate(
                trip = trip,
                sprayRecord = record,
                operatorCategories = operatorCategories,
                machines = machines,
                fuelPurchases = fuelPurchases,
                paddocks = paddocks,
            )
            est.fuel.litres?.let { fuelLitres += it }
            est.fuel.fuelCost?.let { fuelCost += it }
            labourCost += est.labour.cost
            when (est.completeness) {
                TripCostEstimator.Completeness.Complete -> complete++
                TripCostEstimator.Completeness.Partial -> partial++
                TripCostEstimator.Completeness.Unavailable -> unavailable++
            }
        }

        // Grand total composed from distinct sources to avoid double-counting:
        // chemical subtotal spans all records, fuel + labour come from linked
        // trips only.
        val grandTotal = chemicalSubtotal + fuelCost + labourCost

        // Nothing meaningful to show.
        if (chemCosts.isEmpty() && fuelCost <= 0 && labourCost <= 0) return

        s.y += 8f
        s.ensure(40f)
        s.canvas.drawLine(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y, linePaint)
        s.y += 14f
        s.canvas.drawText("Cost Summary (All Records)", MARGIN, s.y, summaryTitlePaint)
        s.y += 16f

        for ((name, cost) in chemCosts) {
            s.ensure(14f)
            s.canvas.drawText(name, MARGIN + 8f, s.y, bodyPaint)
            s.canvas.drawText(formatCurrency(cost), MARGIN + 200f, s.y, bodyBoldPaint)
            s.y += 14f
        }

        if (chemCosts.isNotEmpty()) {
            s.ensure(14f)
            s.canvas.drawText("Chemical Subtotal", MARGIN + 8f, s.y, bodyPaint)
            s.canvas.drawText(formatCurrency(chemicalSubtotal), MARGIN + 200f, s.y, bodyBoldPaint)
            s.y += 14f
        }

        if (fuelCost > 0) {
            s.ensure(14f)
            val value = if (fuelLitres > 0) {
                "${formatCurrency(fuelCost)} \u00B7 ${String.format(Locale.getDefault(), "%.1f", fuelLitres)} L"
            } else {
                formatCurrency(fuelCost)
            }
            s.canvas.drawText("Fuel Cost", MARGIN + 8f, s.y, bodyPaint)
            s.canvas.drawText(value, MARGIN + 200f, s.y, bodyBoldPaint)
            s.y += 14f
        }

        if (labourCost > 0) {
            s.ensure(14f)
            s.canvas.drawText("Labour", MARGIN + 8f, s.y, bodyPaint)
            s.canvas.drawText(formatCurrency(labourCost), MARGIN + 200f, s.y, bodyBoldPaint)
            s.y += 14f
        }

        if (grandTotal > 0) {
            s.ensure(14f)
            s.canvas.drawText("Total Cost", MARGIN + 8f, s.y, bodyBoldPaint)
            s.canvas.drawText(formatCurrency(grandTotal), MARGIN + 200f, s.y, bodyBoldPaint)
            s.y += 14f
        }

        // Concise aggregate costing status for linked records.
        if (linkedCount > 0) {
            val statusParts = buildList {
                if (complete > 0) add("$complete complete")
                if (partial > 0) add("$partial partial")
                if (unavailable > 0) add("$unavailable unavailable")
            }
            if (statusParts.isNotEmpty()) {
                s.ensure(14f)
                s.y += 2f
                s.canvas.drawText(
                    "Costing: " + statusParts.joinToString("  \u2022  "),
                    MARGIN + 8f,
                    s.y,
                    captionPaint,
                )
                s.y += 14f
            }
        }
    }

    // MARK: helpers

    private fun formatCurrency(value: Double): String {
        val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
        return "$$rounded"
    }

    private val dateFmt get() = SimpleDateFormat("dd/MM/yyyy", Locale.getDefault())

    private fun dash(value: String?): String = value?.takeIf { it.isNotBlank() } ?: "\u2013"

    private fun cell(s: PageState, columnIndex: Int, value: String, rowY: Float, paint: Paint) {
        val col = columns[columnIndex]
        val clipped = ellipsize(value, paint, col.width - 6f)
        s.canvas.drawText(clipped, MARGIN + col.x + 3f, rowY, paint)
    }

    private fun ellipsize(text: String, paint: Paint, maxWidth: Float): String {
        if (paint.measureText(text) <= maxWidth) return text
        var end = text.length
        while (end > 0 && paint.measureText(text.substring(0, end) + "\u2026") > maxWidth) {
            end--
        }
        return if (end <= 0) "\u2026" else text.substring(0, end) + "\u2026"
    }

    private fun chemUnitAbbrev(unit: String): String = when (unit.lowercase(Locale.getDefault())) {
        "litres", "l" -> "L"
        "ml" -> "mL"
        "kilograms", "kg" -> "Kg"
        "g", "grams" -> "g"
        else -> unit
    }

    private fun fileName(vineyardName: String): String {
        val safe = vineyardName.ifBlank { "Vineyard" }
            .replace(" ", "_")
            .replace("/", "-")
            .replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
            .ifBlank { "Vineyard" }
        return "SprayProgram_$safe.pdf"
    }
}
