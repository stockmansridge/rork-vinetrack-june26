package com.rork.vinetrack.data.insights

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.RegionFormatter
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Genuine OOXML Word / paginated PDF exports, using exactly the saved screen content. */
object VintageReportExport {
    val headings: Set<String> = setOf("Season opening and winter conditions", "Pruning and early vineyard activity", "Budburst, frost and spring development", "Flowering, fruit set and canopy development", "Summer weather, water and disease pressure", "Veraison and ripening", "Harvest timing, yield and fruit condition", "Overall vintage summary", "Key-event timeline", "Sources and coverage")
    fun timestamp(value: String, formatter: RegionFormatter): String = com.rork.vinetrack.data.model.parseIsoToEpochMs(value)?.let { formatter.formatDateTime(it) } ?: value
    fun lines(revision: VintageReportRevision, vineyard: String, vintage: Int, formatter: RegionFormatter): List<String> =
        listOf(vineyard, "Vintage $vintage — ${if (revision.evidence.season_to_date == true) "Season to date" else "Vintage Report"}",
            "Season ${formatter.formatDate(revision.evidence.season_start)} to ${formatter.formatDate(revision.evidence.season_end)}; report through ${formatter.formatDate(revision.report_through)}",
            "Revision ${revision.revision} • saved ${timestamp(revision.created_at, formatter)} • evidence collected ${timestamp(revision.collected_at, formatter)}") +
            revision.content.narrative.lines() + listOf("Key-event timeline") + revision.content.timeline +
            listOf("Sources and coverage") + revision.content.appendix

    fun exportAndShare(context: Context, revision: VintageReportRevision, vineyard: String, vintage: Int, logo: Bitmap?, account: String, word: Boolean, formatter: RegionFormatter) {
        val directory = File(context.filesDir, "vintage-report-exports/$account").apply { check(mkdirs() || isDirectory) }
        val output = File(directory, "Vintage-$vintage-${revision.id}.${if (word) "docx" else "pdf"}")
        val temporary = File(directory, "${output.name}.pending")
        val content = lines(revision, vineyard, vintage, formatter)
        if (word) writeWord(temporary, content, logo) else writePDF(temporary, content, logo, revision.revision)
        check(temporary.renameTo(output)) { "Could not save export" }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", output)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = if (word) "application/vnd.openxmlformats-officedocument.wordprocessingml.document" else "application/pdf"
            putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "Share Vintage Report").apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
    }
    private fun escape(value: String): String = value.map { ch ->
        if (ch.code < 32 && ch != '\t' && ch != '\n' && ch != '\r') '\uFFFD' else ch
    }.joinToString("").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
    private fun writeWord(file: File, lines: List<String>, logo: Bitmap?) {
        val jpeg = logo?.let { bitmap -> ByteArrayOutputStream().use { bytes -> check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, bytes)); bytes.toByteArray() } }
        val drawing = if (logo == null) "" else {
            val scale = minOf(64.0 / logo.width, 64.0 / logo.height)
            val width = (logo.width * scale * 12700).toInt(); val height = (logo.height * scale * 12700).toInt()
            """<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="$width" cy="$height"/><wp:docPr id="1" name="Vineyard logo"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="Logo"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$width" cy="$height"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"""
        }
        val paragraphs = lines.mapIndexed { index, line ->
            val heading = index < 2 || line in headings || line.startsWith("Seasonal update —")
            "<w:p><w:pPr>${if (heading) "<w:keepNext/>" else ""}<w:spacing w:after=\"120\"/></w:pPr><w:r><w:rPr>${if (heading) "<w:b/><w:sz w:val=\"28\"/>" else "<w:sz w:val=\"22\"/>"}</w:rPr><w:t xml:space=\"preserve\">${escape(line)}</w:t></w:r></w:p>"
        }.joinToString("")
        val document = """<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>$drawing$paragraphs<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body></w:document>"""
        ZipOutputStream(file.outputStream()).use { zip ->
            fun add(name: String, bytes: ByteArray) { zip.putNextEntry(ZipEntry(name)); zip.write(bytes); zip.closeEntry() }
            add("[Content_Types].xml", """<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>""".toByteArray())
            add("_rels/.rels", """<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>""".toByteArray())
            add("word/document.xml", document.toByteArray())
            if (jpeg != null) {
                add("word/media/logo.jpg", jpeg)
                add("word/_rels/document.xml.rels", """<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/logo.jpg"/></Relationships>""".toByteArray())
            }
        }
    }
    private fun writePDF(file: File, lines: List<String>, logo: Bitmap?, revision: Int) {
        val document = PdfDocument()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 11f }
        var page: PdfDocument.Page? = null; var number = 0; var y = 40f
        fun newPage() {
            page?.let(document::finishPage)
            number += 1; page = document.startPage(PdfDocument.PageInfo.Builder(595, 842, number).create()); y = 40f
            val footer = Paint(paint).apply { textSize = 9f }
            page?.canvas?.drawText("Vintage Report • Revision $revision • Page $number", 40f, 816f, footer)
        }
        try {
            newPage()
            logo?.let { image ->
                val scale = minOf(64f / image.width, 64f / image.height)
                page?.canvas?.drawBitmap(image, null, RectF(40f, y, 40f + image.width * scale, y + image.height * scale), null); y += 74
            }
            lines.forEachIndexed { index, paragraph ->
                val heading = paragraph in headings || paragraph.startsWith("Seasonal update —")
                paint.textSize = if (index < 2) 18f else if (heading) 14f else 11f
                paint.typeface = if (index < 2 || heading) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
                val lineHeight = paint.fontSpacing + 3f
                var remaining = paragraph
                while (remaining.isNotEmpty()) {
                    var count = paint.breakText(remaining, true, 515f, null).coerceAtLeast(1)
                    if (count < remaining.length) {
                        val space = remaining.lastIndexOf(' ', count - 1)
                        if (space > 0) count = space
                    }
                    if (y + lineHeight > 785f) newPage()
                    page?.canvas?.drawText(remaining.take(count), 40f, y, paint); y += lineHeight
                    remaining = remaining.drop(count).trimStart()
                }
                y += 9f
            }
            page?.let(document::finishPage); page = null
            file.outputStream().use(document::writeTo)
        } finally { document.close() }
    }
}
