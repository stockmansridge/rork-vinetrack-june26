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
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Generates a local Pins report — CSV (Excel), PDF, or both — and shares it
 * through the Android share sheet. Mirrors the iOS Pins export (PinsPDFService):
 * an overview summary plus one row per pin (category, block, row/side, status,
 * coordinates, who dropped it). Files are written to the app cache
 * (`cache/exports`) and shared via [FileProvider]; nothing is uploaded to
 * Supabase. All functions return false on failure and never throw.
 */
object PinExporter {

    enum class Format { PDF, CSV, BOTH }

    /** Build the requested file(s), write to cache, and launch one share sheet. */
    fun exportAndShare(
        context: Context,
        pins: List<Pin>,
        vineyardName: String,
        paddocks: List<Paddock>,
        format: Format,
        logo: Bitmap? = null,
    ): Boolean {
        if (pins.isEmpty()) return false
        return try {
            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val base = fileBase(vineyardName)
            val uris = ArrayList<Uri>(2)

            if (format == Format.PDF || format == Format.BOTH) {
                val file = File(dir, "$base.pdf")
                writePdf(file, pins, vineyardName, paddocks, logo)
                uris.add(uriFor(context, file))
            }
            if (format == Format.CSV || format == Format.BOTH) {
                val file = File(dir, "$base.csv")
                file.writeText(buildCsv(pins, paddocks), Charsets.UTF_8)
                uris.add(uriFor(context, file))
            }
            if (uris.isEmpty()) return false

            val share = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = if (uris[0].toString().endsWith(".csv")) "text/csv" else "application/pdf"
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "*/*"
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
            context.startActivity(
                Intent.createChooser(share, "Share pins report").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("PinExporter", "Pins export failed", e)
            false
        }
    }

    private fun uriFor(context: Context, file: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)

    // MARK: - CSV

    private val csvHeaders = listOf(
        "Category", "Type", "Status", "Block", "Row", "Side",
        "Latitude", "Longitude", "Dropped By", "Dropped At", "Completed By", "Notes",
    )

    private fun buildCsv(pins: List<Pin>, paddocks: List<Paddock>): String {
        val sb = StringBuilder()
        sb.append(csvHeaders.joinToString(",") { escape(it) }).append("\n")
        for (pin in pins) {
            val cells = listOf(
                pin.displayTitle,
                modeLabel(pin),
                if (pin.isCompleted) "Completed" else "Open",
                paddockName(pin, paddocks),
                rowLabel(pin) ?: "",
                sideLabel(pin) ?: "",
                pin.latitude?.let { fmtCoord(it) } ?: "",
                pin.longitude?.let { fmtCoord(it) } ?: "",
                pin.buttonName?.takeIf { it.isNotBlank() && it != pin.displayTitle } ?: "",
                formatDateTime(pin.createdAt) ?: "",
                pin.completedBy ?: "",
                pin.notes ?: "",
            )
            sb.append(cells.joinToString(",") { escape(it) }).append("\n")
        }
        return sb.toString()
    }

    /** RFC-4180 escaping: wrap in quotes when the value contains comma/quote/newline. */
    private fun escape(value: String): String {
        if (value.isEmpty()) return ""
        val needsQuotes = value.contains(',') || value.contains('"') ||
            value.contains('\n') || value.contains('\r')
        if (!needsQuotes) return value
        return "\"" + value.replace("\"", "\"\"") + "\""
    }

    // MARK: - PDF

    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 40f
    private const val LABEL_WIDTH = 180f

    private val accent = Color.rgb(85, 107, 47)

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

        fun finish() = doc.finishPage(page)
    }

    private val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK; textSize = 22f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accent; textSize = 14f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val bodyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK; textSize = 11f
    }
    private val bodyBoldPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK; textSize = 11f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val captionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.DKGRAY; textSize = 9f
    }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(80, 85, 107, 47); strokeWidth = 0.5f
    }

    private fun writePdf(file: File, pins: List<Pin>, vineyardName: String, paddocks: List<Paddock>, logo: Bitmap?) {
        val doc = PdfDocument()
        val s = PageState(doc)
        render(s, pins, vineyardName, paddocks, logo)
        s.finish()
        file.outputStream().use { doc.writeTo(it) }
        doc.close()
    }

    private fun render(s: PageState, pins: List<Pin>, vineyardName: String, paddocks: List<Paddock>, logo: Bitmap?) {
        // Header
        val textX = PdfHeaderUtil.drawLogo(s.canvas, logo, MARGIN, s.y)
        s.canvas.drawText(vineyardName.ifBlank { "Vineyard" }, textX, s.y + 18f, titlePaint)
        s.y += 26f
        s.canvas.drawText("Pins Report", textX, s.y + 12f, headerPaint)
        s.y += 22f
        drawDivider(s); s.y += 8f

        // Overview
        val completed = pins.count { it.isCompleted }
        val active = pins.size - completed
        val growth = pins.count { it.mode?.contains("growth", ignoreCase = true) == true }
        val repairs = pins.size - growth
        sectionHeader(s, "Overview")
        row(s, "Total pins", pins.size.toString())
        row(s, "Active", active.toString())
        row(s, "Completed", completed.toString())
        row(s, "Repairs", repairs.toString())
        row(s, "Growth", growth.toString())

        // Per-pin detail
        sectionHeader(s, "Pins")
        for (pin in pins) {
            s.ensure(28f)
            s.y += 12f
            val status = if (pin.isCompleted) "Completed" else "Open"
            s.canvas.drawText(pin.displayTitle, MARGIN, s.y, bodyBoldPaint)
            s.canvas.drawText(status, PAGE_WIDTH - MARGIN - 70f, s.y, bodyPaint)
            s.y += 4f
            val detail = buildList {
                add(modeLabel(pin))
                paddockName(pin, paddocks).takeIf { it != "—" }?.let { add(it) }
                rowLabel(pin)?.let { r -> add("Row $r" + (sideLabel(pin)?.let { " · $it" } ?: "")) }
            }.joinToString("  •  ")
            text(s, detail, captionPaint)
            pin.notes?.takeIf { it.isNotBlank() }?.let { text(s, it, captionPaint) }
            s.y += 4f
            drawDivider(s)
        }

        // Footer
        s.y += 20f
        s.ensure(30f)
        drawDivider(s); s.y += 4f
        val generated = "Generated by VineTrack • " +
            SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(Date())
        text(s, generated, captionPaint)
    }

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

    private fun sectionHeader(s: PageState, title: String) {
        s.y += 16f
        s.ensure(28f)
        s.y += 4f
        s.canvas.drawText(title, MARGIN, s.y, headerPaint)
        s.y += 8f
        drawDivider(s); s.y += 4f
    }

    private fun drawDivider(s: PageState) {
        s.canvas.drawLine(MARGIN, s.y, PAGE_WIDTH - MARGIN, s.y, linePaint)
    }

    private fun wrap(text: String, paint: Paint, maxWidth: Float): List<String> {
        val out = mutableListOf<String>()
        for (rawLine in text.split("\n")) {
            if (rawLine.isEmpty()) { out.add(""); continue }
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

    // MARK: - Field helpers

    private fun modeLabel(pin: Pin): String =
        if (pin.mode?.contains("growth", ignoreCase = true) == true) "Growth" else "Repairs"

    private fun paddockName(pin: Pin, paddocks: List<Paddock>): String =
        pin.paddockId?.let { id -> paddocks.firstOrNull { it.id == id }?.name } ?: "—"

    private fun rowLabel(pin: Pin): String? {
        val row = pin.drivingRowNumber ?: pin.pinRowNumber ?: pin.rowNumber?.toDouble() ?: return null
        return if (row % 1.0 == 0.0) row.toInt().toString() else row.toString()
    }

    private fun sideLabel(pin: Pin): String? =
        (pin.pinSide ?: pin.side)?.lowercase()?.takeIf { it == "left" || it == "right" }

    private fun fmtCoord(value: Double): String = String.format(Locale.US, "%.6f", value)

    private fun formatDateTime(iso: String?): String? =
        parseIsoToEpochMs(iso)?.let {
            SimpleDateFormat("dd/MM/yyyy h:mm a", Locale.getDefault()).format(Date(it))
        }

    private fun fileBase(vineyardName: String): String {
        val safe = vineyardName.ifBlank { "Vineyard" }
            .replace(" ", "_")
            .replace("/", "-")
            .replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
            .ifBlank { "Vineyard" }
        val date = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        return "PinsReport_${safe}_$date"
    }
}
