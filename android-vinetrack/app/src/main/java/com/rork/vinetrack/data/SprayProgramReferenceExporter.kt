package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.spray.*
import java.io.File
import kotlin.math.max
import kotlin.math.min

/** Separate A4 reference report, leaving operational/history exporters and CSV intact. */
object SprayProgramReferenceExporter {
    fun exportAndShare(context: Context, rows: List<SprayProgramReferenceRow>, vineyard: String, pdf: Boolean, logo: Bitmap? = null): Boolean = runCatching {
        require(rows.isNotEmpty())
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val file = File(dir, "${vineyard.replace('/', '-')} - Spray Program.${if (pdf) "pdf" else "csv"}")
        if (pdf) {
            val document = render(rows, vineyard, logo)
            try { file.outputStream().use { document.writeTo(it) } } finally { document.close() }
        } else file.writeText(SprayProgramReferenceDataset.csv(rows), Charsets.UTF_8)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = if (pdf) "application/pdf" else "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "Program Export").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }.isSuccess

    private data class Line(val text: String, val size: Float, val bold: Boolean, val y: Float)
    private data class Cell(val column: ProgramPDFColumn, val x: Float, val width: Float, val lines: List<Line>)

    internal fun render(rows: List<SprayProgramReferenceRow>, vineyard: String, logo: Bitmap?): PdfDocument {
        val blocks = ProgramStepExportBlock.grouped(rows)
        val columns = ProgramPDFLayout.columns(blocks)
        val widths = ProgramPDFLayout.widths(columns).map { it.toFloat() }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val green = Color.rgb(41, 74, 56)
        fun configure(size: Float, bold: Boolean = false, color: Int = Color.BLACK) {
            paint.textSize = size; paint.typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
            paint.color = color; paint.style = Paint.Style.FILL
        }
        fun lines(text: String, width: Float, size: Float = 8f, bold: Boolean = false, y: Float = 4f): List<Line> {
            configure(size, bold)
            return ProgramPDFLayout.wrap(text, (width - 8f).toDouble()) { paint.measureText(it).toDouble() }
                .mapIndexed { i, value -> Line(value, size, bold, y + i * 10f) }
        }
        val titleX = if (logo == null) 36f else 76f
        val title = lines("$vineyard — Spray Program", 806f - titleX, 17f, true, 26f)
        val headerTop = 50f + title.size * 20f
        val bodyTop = headerTop + 24f
        require(bodyTop < 508f) { "The vineyard heading is too long to fit this report." }
        val document = PdfDocument()
        var pageNumber = 0
        var page: PdfDocument.Page? = null
        var y = bodyTop
        fun text(canvas: Canvas, value: String, x: Float, top: Float, size: Float = 8f, bold: Boolean = false, color: Int = Color.BLACK) {
            configure(size, bold, color)
            canvas.drawText(value, x, top - paint.fontMetrics.ascent, paint)
        }
        fun rule(canvas: Canvas, x: Float, top: Float, right: Float, bottom: Float, strong: Boolean = false) {
            paint.color = if (strong) green else Color.rgb(191, 191, 191)
            paint.strokeWidth = if (strong) 1f else .35f
            canvas.drawLine(x, top, right, bottom, paint)
        }
        fun newPage() {
            page?.let { document.finishPage(it) }
            pageNumber++
            val next = document.startPage(PdfDocument.PageInfo.Builder(842, 595, pageNumber).create())
            page = next; y = bodyTop
            val canvas = next.canvas
            logo?.let {
                val scale = min(32f / it.width, 32f / it.height)
                canvas.drawBitmap(it, null, RectF(36f, 27f, 36f + it.width * scale, 27f + it.height * scale), paint)
            }
            title.forEachIndexed { index, line -> text(canvas, line.text, titleX, 26f + index * 20f, line.size, line.bold, green) }
            text(canvas, "VineTrack · Program reference", titleX, headerTop - 17f, 7f, color = green)
            paint.color = green; canvas.drawRect(36f, headerTop, 806f, bodyTop, paint)
            var x = 36f
            columns.forEachIndexed { i, column ->
                lines(column.title, widths[i], 8f, true, headerTop + 4f).forEach { text(canvas, it.text, x + 4f, it.y, it.size, it.bold, Color.WHITE) }
                x += widths[i]
            }
            lines(SprayProgramReferenceDataset.FOOTER, 708f, 7f, y = 559f).forEach { text(canvas, it.text, 36f, it.y, it.size) }
            text(canvas, "Page $pageNumber", 765f, 559f, 7f)
        }
        try {
            newPage()
            for (block in blocks) {
                val row = block.reference
                val cells = mutableListOf<Cell>()
                val boundaries = mutableListOf<Float>()
                var sharedHeight = 0f
                var x = 36f
                columns.forEachIndexed { i, column ->
                    if (column.shared) {
                        val contents = mutableListOf<Line>()
                        when (column) {
                            ProgramPDFColumn.TIMING -> {
                                contents += lines(block.timing, widths[i], bold = true)
                                contents += lines(block.stage, widths[i], 7f, y = contents.size * 10f + 4f)
                                contents += lines(block.growthDescription, widths[i], 7f, y = contents.size * 10f + 4f)
                            }
                            ProgramPDFColumn.TARGETS -> contents += lines(row.targets, widths[i])
                            ProgramPDFColumn.METHOD -> {
                                contents += lines(row.method, widths[i], bold = true)
                                contents += lines(row.equipment, widths[i], 7f, y = contents.size * 10f + 4f)
                            }
                            ProgramPDFColumn.COMMENTS -> contents += lines(block.comments, widths[i])
                            else -> Unit
                        }
                        sharedHeight = max(sharedHeight, contents.size * 10f + 10f)
                        cells += Cell(column, x, widths[i], contents)
                    }
                    x += widths[i]
                }
                var productTop = 0f
                for (product in block.products) {
                    x = 36f
                    var rowHeight = 20f
                    columns.forEachIndexed { i, column ->
                        if (!column.shared) {
                            val value = when (column) {
                                ProgramPDFColumn.PRODUCT -> product.name.ifEmpty { "No product configured" }
                                ProgramPDFColumn.PER100L -> product.per100L
                                ProgramPDFColumn.PERHA -> product.perHa
                                ProgramPDFColumn.MOA -> product.moa
                                ProgramPDFColumn.COST -> product.estimatedCost
                                else -> ""
                            }
                            val contents = lines(value, widths[i], bold = column == ProgramPDFColumn.PRODUCT, y = productTop + 4f).toMutableList()
                            if (column == ProgramPDFColumn.PRODUCT && product.unknownRate) {
                                contents += lines(SprayProgramReferenceDataset.UNPLANNED_RATE, widths[i], 7f, y = productTop + 4f + contents.size * 10f)
                            }
                            rowHeight = max(rowHeight, contents.size * 10f + 10f)
                            cells += Cell(column, x, widths[i], contents)
                        }
                        x += widths[i]
                    }
                    productTop += rowHeight; boundaries += productTop
                }
                val height = max(sharedHeight, productTop)
                if (ProgramPDFLayout.needsFreshPage(height.toDouble(), y.toDouble(), bodyTop.toDouble())) newPage()
                var offset = 0f
                while (offset < height) {
                    if (offset > 0) {
                        newPage()
                        val heading = lines("${block.stage} (continued)\n${block.timing}", 770f, 7f, y = y + 2f).take(3)
                        heading.forEach { text(requireNotNull(page).canvas, it.text, 40f, it.y, it.size, color = green) }
                        y += heading.size * 10f + 8f
                    }
                    val available = 548f - y
                    val slice = ProgramPDFLayout.slice(height.toDouble(), offset.toDouble(), available.toDouble(), boundaries.map { it.toDouble() }).toFloat()
                    val canvas = requireNotNull(page).canvas
                    cells.filter { it.column == ProgramPDFColumn.METHOD }.forEach { cell ->
                        paint.color = when (ProgramPDFLayout.methodStyle(row.method)) {
                            "gold" -> Color.rgb(255, 232, 140)
                            "green" -> Color.rgb(191, 227, 173)
                            else -> Color.rgb(242, 242, 242)
                        }
                        canvas.drawRect(cell.x, y, cell.x + cell.width, y + slice, paint)
                    }
                    for (cell in cells) {
                        canvas.save(); canvas.clipRect(cell.x + 2f, y, cell.x + cell.width - 2f, y + slice)
                        cell.lines.filter { it.y + 8f > offset && it.y < offset + slice }.forEach { text(canvas, it.text, cell.x + 4f, y + it.y - offset, it.size, it.bold) }
                        canvas.restore()
                    }
                    x = 36f; rule(canvas, x, y, x, y + slice)
                    widths.forEach { x += it; rule(canvas, x, y, x, y + slice) }
                    boundaries.filter { it > offset && it < offset + slice }.forEach { boundary ->
                        cells.filter { !it.column.shared }.forEach { rule(canvas, it.x, y + boundary - offset, it.x + it.width, y + boundary - offset) }
                    }
                    rule(canvas, 36f, y, 806f, y, true)
                    rule(canvas, 36f, y + slice, 806f, y + slice, true)
                    y += slice; offset += slice
                }
            }
            page?.let { document.finishPage(it) }
            return document
        } catch (error: Exception) {
            document.close()
            throw error
        }
    }
}
