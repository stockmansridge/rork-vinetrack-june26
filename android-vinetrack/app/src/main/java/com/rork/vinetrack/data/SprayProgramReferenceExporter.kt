package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.spray.SprayProgramReferenceDataset
import com.rork.vinetrack.data.spray.SprayProgramReferenceRow
import java.io.File

/** Separate A4 reference report, leaving detailed operational/history exporters intact. */
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

    private fun render(rows: List<SprayProgramReferenceRow>, vineyard: String, logo: Bitmap?): PdfDocument {
        val document = PdfDocument()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 10f }
        val widths = listOf(74f, 290f, 178f, 228f)
        fun wrap(text: String, width: Float): List<String> = buildList {
            for (paragraph in text.split('\n')) {
                var line = ""
                for (character in paragraph) {
                    val next = line + character
                    if (line.isNotEmpty() && paint.measureText(next) > width - 12f) { add(line); line = character.toString() }
                    else line = next
                }
                add(line)
            }
        }
        var pageNumber = 0
        var page: PdfDocument.Page? = null
        var y = 118f
        fun newPage() {
            page?.let { document.finishPage(it) }
            pageNumber++
            val next = document.startPage(PdfDocument.PageInfo.Builder(842, 595, pageNumber).create())
            page = next; y = 118f
            paint.textSize = 18f; paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            next.canvas.drawText("$vineyard — Spray Program", 36f, 46f, paint)
            paint.textSize = 10f; paint.typeface = Typeface.DEFAULT
            next.canvas.drawText("VineTrack · Program reference", 36f, 69f, paint)
            logo?.let { next.canvas.drawBitmap(it, null, android.graphics.RectF(766f, 28f, 806f, 68f), paint) }
            var x = 36f
            paint.textSize = 9f; paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            listOf("E-L STAGE", "PROGRAM STEP / PURPOSE / INSTRUCTIONS", "PRODUCT", "RATE / RANGE").forEachIndexed { i, title ->
                next.canvas.drawText(title, x + 6f, 99f, paint); x += widths[i]
            }
            paint.textSize = 8f; paint.typeface = Typeface.DEFAULT
            wrap(SprayProgramReferenceDataset.FOOTER, 700f).forEachIndexed { i, text -> next.canvas.drawText(text, 36f, 563f + i * 10f, paint) }
            next.canvas.drawText("Page $pageNumber", 764f, 563f, paint)
            paint.textSize = 10f
        }
        newPage()
        for (row in rows) {
            val detail = listOf(row.name, row.description, row.targets, row.method, row.equipment, row.notes).filter { it.isNotBlank() }.joinToString("\n")
            val columns = listOf(row.stage, detail, row.product, row.rate).mapIndexed { i, text -> wrap(text, widths[i]) }
            repeat(columns.maxOf { it.size }) { line ->
                if (y + 14f > 536f) newPage()
                var x = 36f
                columns.forEachIndexed { i, lines ->
                    lines.getOrNull(line)?.let { page?.canvas?.drawText(it, x + 6f, y, paint) }; x += widths[i]
                }
                y += 14f
            }
            y += 12f
        }
        page?.let { document.finishPage(it) }
        return document
    }
}
