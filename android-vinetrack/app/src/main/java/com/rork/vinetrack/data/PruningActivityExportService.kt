package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.net.Uri
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.PruningActivityExport
import com.rork.vinetrack.data.model.PruningActivityRow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Writes and shares the Pruning Activity Report as CSV or PDF, mirroring the
 * iOS `PruningActivityExportService`.
 *
 * Both formats are built from [PruningActivityExport], so the allocation
 * breakdown, the allocated-share maths, the partial-activity marker and the
 * labour authority order are identical on the two platforms and identical
 * between the two formats.
 *
 * The caller passes the report's ALREADY filtered and sorted rows, so an export
 * always reflects exactly what is on screen — same date range, season, block,
 * worker, method, linked/unlinked and reversed options, same search, same sort.
 * It ALSO passes the canonical (unfiltered) rows, which supply the parent
 * activity context and the allocation-share denominator so a filtered extract
 * never hands one block 100% of a multi-block activity's cost.
 *
 * `includeCost = false` (supervisor/operator) removes BOTH the whole-activity
 * and the allocated cost columns from the CSV and the cost lines from the PDF
 * entirely; hours stay visible.
 *
 * Files are written to the app cache (`cache/exports`) and shared through
 * [FileProvider]. Nothing is uploaded.
 */
object PruningActivityExportService {

    // A4 portrait — the grouped layout reads as a document, not a spreadsheet.
    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 36f

    private val accent = Color.rgb(85, 107, 47)

    fun exportCsvAndShare(
        context: Context,
        rows: List<PruningActivityRow>,
        vineyardName: String,
        seasonLabel: String,
        includeCost: Boolean,
        canonicalRows: List<PruningActivityRow> = rows,
    ): Boolean = try {
        val csv = PruningActivityExport.csv(rows, includeCost, canonicalRows)
        val file = write(context, fileName(vineyardName, seasonLabel, "csv"), csv)
        share(context, file, "text/csv", "Export pruning activity report")
        true
    } catch (e: Exception) {
        android.util.Log.e("PruningActivityExport", "CSV export failed", e)
        false
    }

    fun exportPdfAndShare(
        context: Context,
        rows: List<PruningActivityRow>,
        vineyardName: String,
        seasonLabel: String,
        includeCost: Boolean,
        canonicalRows: List<PruningActivityRow> = rows,
    ): Boolean = try {
        val file = File(File(context.cacheDir, "exports").apply { mkdirs() }, fileName(vineyardName, seasonLabel, "pdf"))
        val document = PdfDocument()
        try {
            renderPdf(document, rows, vineyardName, seasonLabel, includeCost, canonicalRows)
            file.outputStream().use { document.writeTo(it) }
        } finally {
            document.close()
        }
        share(context, file, "application/pdf", "Export pruning activity report")
        true
    } catch (e: Exception) {
        android.util.Log.e("PruningActivityExport", "PDF export failed", e)
        false
    }

    // ------------------------------------------------------------------
    // PDF — grouped layout
    // ------------------------------------------------------------------

    private class PageState(val doc: PdfDocument) {
        private var pageNumber = 1
        var page: PdfDocument.Page = doc.startPage(info(1))
        var canvas = page.canvas
        var y = MARGIN

        private fun info(n: Int) = PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, n).create()

        /** Starts a new page when [needed] points would overflow the margin. */
        fun ensure(needed: Float) {
            if (y + needed > PAGE_HEIGHT - MARGIN) newPage()
        }

        fun newPage() {
            doc.finishPage(page)
            pageNumber += 1
            page = doc.startPage(info(pageNumber))
            canvas = page.canvas
            y = MARGIN
        }

        fun finish() = doc.finishPage(page)
    }

    private fun paint(size: Float, bold: Boolean = false, colour: Int = Color.BLACK) =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = size
            color = colour
            typeface = Typeface.create(Typeface.DEFAULT, if (bold) Typeface.BOLD else Typeface.NORMAL)
        }

    private fun renderPdf(
        doc: PdfDocument,
        rows: List<PruningActivityRow>,
        vineyardName: String,
        seasonLabel: String,
        includeCost: Boolean,
        canonicalRows: List<PruningActivityRow>,
    ) {
        val groups = PruningActivityExport.groups(rows, includeCost, canonicalRows)
        val state = PageState(doc)

        val title = paint(19f, bold = true)
        val subtitle = paint(10f, colour = Color.DKGRAY)
        val heading = paint(12.5f, bold = true, colour = accent)
        val detail = paint(10.5f)
        val detailMuted = paint(10.5f, colour = Color.DKGRAY)
        val badge = paint(9.5f, bold = true, colour = Color.rgb(150, 40, 40))
        val partialBadge = paint(9.5f, bold = true, colour = Color.rgb(176, 108, 20))
        val rule = Paint().apply { color = Color.rgb(220, 220, 220) }

        state.canvas.drawText("Pruning Activity Report", MARGIN, state.y + 16f, title)
        state.y += 26f
        state.canvas.drawText(
            listOf(vineyardName.ifBlank { "Vineyard" }, seasonLabel)
                .filter { it.isNotBlank() }
                .joinToString("  •  "),
            MARGIN,
            state.y,
            subtitle,
        )
        state.y += 14f
        val partialCount = groups.count { it.isPartialActivity }
        state.canvas.drawText(
            buildString {
                append("${groups.size} ${if (groups.size == 1) "activity" else "activities"}, ")
                append("${groups.sumOf { it.includedAllocationCount }} allocations")
                if (partialCount > 0) append("  •  $partialCount partially shown")
            },
            MARGIN,
            state.y,
            subtitle,
        )
        state.y += 18f

        for (group in groups) {
            // Header + labour block + the allocation list must not be split
            // across a page break: the allocations are meaningless without the
            // activity totals they belong to.
            val needed = 46f + (group.allocations.size * 13f) +
                (if (group.isPartialActivity) 13f else 0f) +
                (if (group.notes != null) 26f else 0f)
            state.ensure(needed.coerceAtMost(PAGE_HEIGHT - 2 * MARGIN))

            state.canvas.drawLine(MARGIN, state.y, PAGE_WIDTH - MARGIN, state.y, rule)
            state.y += 15f

            state.canvas.drawText("${group.activityLabel} — ${group.dateDisplay}", MARGIN, state.y, heading)
            if (group.isReversed) {
                val width = heading.measureText("${group.activityLabel} — ${group.dateDisplay}")
                state.canvas.drawText("REVERSED", MARGIN + width + 8f, state.y, badge)
            }
            state.y += 15f

            // A partial activity says so BEFORE its totals, so the whole-activity
            // figures below can never be mistaken for the filtered block's.
            group.partialLabel?.let { label ->
                state.ensure(13f)
                state.canvas.drawText(label, MARGIN + 6f, state.y, partialBadge)
                state.y += 13f
            }

            // Whole-activity values, stated exactly once.
            for (line in activityLines(group, includeCost)) {
                state.ensure(13f)
                state.canvas.drawText(line, MARGIN + 6f, state.y, detail)
                state.y += 13f
            }

            state.y += 4f
            state.ensure(13f)
            state.canvas.drawText(
                when {
                    group.isPartialActivity ->
                        "Allocations shown (${group.includedAllocationCount} of ${group.fullAllocationCount})"
                    group.isMultiBlock -> "Allocations (${group.includedAllocationCount})"
                    else -> "Allocation"
                },
                MARGIN + 6f,
                state.y,
                paint(10.5f, bold = true),
            )
            state.y += 13f

            for (allocation in group.allocations) {
                state.ensure(13f)
                state.canvas.drawText(
                    "${allocation.allocationNumber}. ${allocationLine(allocation)}",
                    MARGIN + 14f,
                    state.y,
                    detail,
                )
                state.y += 13f
                // This block's proportional slice, on its own indented line so it
                // is never confused with the whole-activity totals above.
                allocatedLine(allocation, includeCost)?.let { line ->
                    state.ensure(12f)
                    state.canvas.drawText(line, MARGIN + 26f, state.y, detailMuted)
                    state.y += 12f
                }
            }

            if (group.isPartialActivity) {
                allocatedSubtotal(group, includeCost)?.let { line ->
                    state.ensure(13f)
                    state.canvas.drawText(line, MARGIN + 14f, state.y, paint(10f, bold = true))
                    state.y += 13f
                }
            }

            group.notes?.let { notes ->
                state.y += 3f
                for (line in wrap("Notes: $notes", detailMuted, PAGE_WIDTH - 2 * MARGIN - 12f)) {
                    state.ensure(12f)
                    state.canvas.drawText(line, MARGIN + 6f, state.y, detailMuted)
                    state.y += 12f
                }
            }

            state.y += 10f
        }

        state.finish()
    }

    /**
     * The WHOLE activity's values — worker, hours, cost, task, timing. Blank
     * values are omitted rather than printed as zero.
     *
     * On a partial activity these are explicitly labelled "whole activity", so
     * a reader can never take them for the filtered block's cost.
     */
    private fun activityLines(group: PruningActivityExport.Group, includeCost: Boolean): List<String> {
        val scope = if (group.isPartialActivity) "Whole activity " else ""
        val lines = mutableListOf<String>()
        group.worker?.let { lines.add("Worker: $it") }
        lines.add("Method: ${group.method}")
        group.activityOperationalHours?.let {
            lines.add("${scope.ifEmpty { "" }}Operational hours: ${trim(it)}".replaceFirstChar(Char::uppercase))
        }
        group.activityPersonHours?.let {
            lines.add("${scope}person-hours: ${trim(it)}".replaceFirstChar(Char::uppercase))
        }
        if (includeCost) {
            group.activityLabourCost?.let {
                lines.add("${scope}labour cost: ${'$'}${PruningActivityExport.number(it, 2)}".replaceFirstChar(Char::uppercase))
            }
        }
        group.workTaskTitle?.let { title ->
            val status = group.workTaskStatus?.let { " ($it)" }.orEmpty()
            lines.add("Work Task: $title$status")
        }
        val start = group.startTime
        val finish = group.finishTime
        if (start != null || finish != null) {
            val span = listOfNotNull(start, finish).joinToString(" – ")
            val duration = group.activityDurationHours?.let { " (${trim(it)} h)" }.orEmpty()
            lines.add("Times: $span$duration")
        }
        return lines
    }

    /** "20.0% of the activity · 2.60 person-hours · $91.00". */
    private fun allocatedLine(row: PruningActivityExport.Row, includeCost: Boolean): String? {
        val parts = mutableListOf<String>()
        row.allocationShare?.let { parts.add("${PruningActivityExport.number(it * 100.0, 1)}% of the activity") }
        row.allocatedPersonHours?.let { parts.add("${trim(it)} person-hours") }
        if (includeCost) {
            row.allocatedLabourCost?.let { parts.add("${'$'}${PruningActivityExport.number(it, 2)}") }
        }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    /** The shown blocks' combined slice, printed only when blocks are missing. */
    private fun allocatedSubtotal(group: PruningActivityExport.Group, includeCost: Boolean): String? {
        val parts = mutableListOf<String>()
        group.allocatedPersonHours?.let { parts.add("${trim(it)} person-hours") }
        if (includeCost) {
            group.allocatedLabourCost?.let { parts.add("${'$'}${PruningActivityExport.number(it, 2)}") }
        }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")?.let { "Allocated to shown blocks: $it" }
    }

    /** "Pinot Noir — rows 90–108 · 4 quarters · 1.0 row eq · 210 vines". */
    private fun allocationLine(row: PruningActivityExport.Row): String {
        val parts = mutableListOf<String>()
        parts.add(buildString {
            append(row.blockName)
            row.variety?.let { append(" ($it)") }
        })
        row.rowRange?.let { parts.add("rows $it") }
        if (row.quarters > 0) parts.add("${row.quarters} quarters")
        if (row.rowEquivalents > 0) parts.add("${PruningActivityExport.number(row.rowEquivalents, 2)} row eq")
        row.estimatedVines?.let { parts.add("${PruningActivityExport.number(it, 0)} vines") }
        return parts.joinToString(" · ")
    }

    /** Drops a trailing ".0" so "6.0 h" reads as "6 h" where exact. */
    private fun trim(value: Double): String {
        val text = PruningActivityExport.number(value, 2)
        return text.trimEnd('0').trimEnd('.').ifEmpty { "0" }
    }

    private fun wrap(text: String, paint: Paint, maxWidth: Float): List<String> {
        if (paint.measureText(text) <= maxWidth) return listOf(text)
        val lines = mutableListOf<String>()
        var current = StringBuilder()
        for (word in text.split(" ")) {
            val candidate = if (current.isEmpty()) word else "$current $word"
            if (paint.measureText(candidate) > maxWidth && current.isNotEmpty()) {
                lines.add(current.toString())
                current = StringBuilder(word)
            } else {
                current = StringBuilder(candidate)
            }
        }
        if (current.isNotEmpty()) lines.add(current.toString())
        return lines
    }

    // ------------------------------------------------------------------
    // Files
    // ------------------------------------------------------------------

    private fun write(context: Context, name: String, contents: String): File {
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        return File(dir, name).apply { writeText(contents, Charsets.UTF_8) }
    }

    private fun share(context: Context, file: File, mime: String, chooserTitle: String) {
        val uri: Uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(
            Intent.createChooser(intent, chooserTitle).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    private fun fileName(vineyardName: String, seasonLabel: String, extension: String): String {
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val safe = "${vineyardName.ifBlank { "Vineyard" }}_${seasonLabel.ifBlank { today }}"
            .replace(" ", "_")
            .replace("/", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
        return "PruningActivityReport_$safe.$extension"
    }
}
