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
import com.rork.vinetrack.data.model.GrowthStage
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Generates the local, multi-page Growth Stage Report PDF and shares it through
 * the Android share sheet. Mirrors the iOS `GrowthStageReportPDFService`: for
 * each block it renders a portrait table page (Growth Stage rows × Vintage
 * columns, with the first observed date per stage) followed by a timeline graph
 * page that plots each vintage's E-L progression across a Jul–Jun season axis.
 *
 * The PDF is written to the app cache (`cache/exports`) and shared via
 * [FileProvider]; it is never uploaded to Supabase.
 */
object GrowthStageReportPdfExporter {

    /** One block's report payload — dates are stored as first-observed epoch ms per stage code. */
    data class BlockReport(
        val blockName: String,
        val vintages: List<Int>,
        val stageCodes: List<String>,
        val entries: Map<Int, Map<String, Long>>,
    )

    // A4 portrait (matches iOS 595 x 842).
    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 40f

    private val accent = Color.rgb(85, 107, 47) // olive, matching iOS VineyardTheme
    private val leafGreen = Color.rgb(106, 153, 78)

    // Vintage palette, mirroring iOS systemBlue/green/orange/purple/red/teal/pink/indigo/mint/cyan.
    private val vintagePalette = listOf(
        Color.rgb(0, 122, 255), Color.rgb(52, 199, 89), Color.rgb(255, 149, 0),
        Color.rgb(175, 82, 222), Color.rgb(255, 59, 48), Color.rgb(48, 176, 199),
        Color.rgb(255, 45, 85), Color.rgb(88, 86, 214), Color.rgb(0, 199, 190),
        Color.rgb(50, 173, 230),
    )

    private val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK; textSize = 20f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val subtitlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.DKGRAY; textSize = 14f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val headerCellPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textSize = 9f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val bodyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 9f }
    private val bodyBoldPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK; textSize = 9f
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val dashPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.LTGRAY; textSize = 9f }
    private val captionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.GRAY; textSize = 8f }
    private val headerBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = accent }
    private val rowBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(245, 245, 245) }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.LTGRAY; strokeWidth = 0.5f }

    /**
     * Build the report PDF for [blocks], write it to the cache, and launch the
     * share sheet. Returns false if there is nothing to export or generation
     * failed; never throws.
     */
    fun exportAndShare(
        context: Context,
        blocks: List<BlockReport>,
        vineyardName: String,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        dateFormat: RegionDateFormat,
        logo: Bitmap? = null,
    ): Boolean {
        if (blocks.isEmpty()) return false
        return try {
            val df = SimpleDateFormat(dateTemplate(dateFormat), Locale.getDefault())
            val vintageColors = vintageColorMap(blocks)
            val doc = PdfDocument()
            var pageNumber = 1
            blocks.forEach { block ->
                pageNumber = drawTablePage(doc, pageNumber, block, vineyardName, df, vintageColors, logo)
                pageNumber = drawGraphPage(doc, pageNumber, block, vineyardName, df, vintageColors, seasonStartMonth, seasonStartDay, logo)
            }

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, fileName(vineyardName))
            file.outputStream().use { doc.writeTo(it) }
            doc.close()

            val uri: Uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "application/pdf"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(
                Intent.createChooser(share, "Share growth stage report").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("GrowthReportPdf", "Growth report PDF export failed", e)
            false
        }
    }

    private fun vintageColorMap(blocks: List<BlockReport>): Map<Int, Int> {
        val allVintages = blocks.flatMap { it.vintages }.toSortedSet(compareByDescending { it }).toList()
        return allVintages.mapIndexed { idx, v -> v to vintagePalette[idx % vintagePalette.size] }.toMap()
    }

    private fun drawTablePage(
        doc: PdfDocument,
        startPageNumber: Int,
        block: BlockReport,
        vineyardName: String,
        df: SimpleDateFormat,
        vintageColors: Map<Int, Int>,
        logo: Bitmap?,
    ): Int {
        var pageNumber = startPageNumber
        var page = doc.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, pageNumber).create())
        var canvas = page.canvas
        var y = MARGIN
        val contentWidth = PAGE_WIDTH - MARGIN * 2

        val textX = PdfHeaderUtil.drawLogo(canvas, logo, MARGIN, y)
        canvas.drawText(vineyardName.ifBlank { "Vineyard" }, textX, y + 16f, titlePaint)
        y += 22f
        canvas.drawText("Growth Stage Report", textX, y + 4f, subtitlePaint)
        y += 24f
        canvas.drawText(block.blockName, MARGIN, y + 10f, subtitlePaint)
        y += 22f

        val sortedVintages = block.vintages.sortedDescending()
        val stageColWidth = 160f
        val availableWidth = contentWidth - stageColWidth
        val vintageColWidth = if (sortedVintages.isNotEmpty())
            minOf(availableWidth / sortedVintages.size, 130f) else 100f
        val headerHeight = 22f

        fun drawHeader() {
            canvas.drawRect(RectF(MARGIN, y, MARGIN + contentWidth, y + headerHeight), headerBgPaint)
            canvas.drawText("GROWTH STAGE", MARGIN + 8f, y + 15f, headerCellPaint)
            sortedVintages.forEachIndexed { i, vintage ->
                val x = MARGIN + stageColWidth + i * vintageColWidth
                canvas.drawText("VINTAGE $vintage", x + 4f, y + 15f, headerCellPaint)
            }
            y += headerHeight
        }
        drawHeader()

        val rowHeight = 20f
        block.stageCodes.forEachIndexed { rowIndex, code ->
            if (y + rowHeight > PAGE_HEIGHT - MARGIN - 30) {
                doc.finishPage(page)
                pageNumber += 1
                page = doc.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, pageNumber).create())
                canvas = page.canvas
                y = MARGIN
                canvas.drawText("${block.blockName} — continued", MARGIN, y + 8f, captionPaint)
                y += 16f
                drawHeader()
            }

            if (rowIndex % 2 == 0) {
                rowBgPaint.color = Color.rgb(245, 245, 245)
                canvas.drawRect(RectF(MARGIN, y, MARGIN + contentWidth, y + rowHeight), rowBgPaint)
            }
            val stage = GrowthStage.allStages.firstOrNull { it.code == code }
            val stageLabel = if (stage != null) "$code — ${stage.description}" else code
            canvas.drawText(ellipsize(stageLabel, bodyBoldPaint, stageColWidth - 16f), MARGIN + 8f, y + 14f, bodyBoldPaint)

            sortedVintages.forEachIndexed { i, vintage ->
                val x = MARGIN + stageColWidth + i * vintageColWidth
                val epoch = block.entries[vintage]?.get(code)
                if (epoch != null) {
                    canvas.drawText(df.format(Date(epoch)), x + 4f, y + 14f, bodyPaint)
                } else {
                    canvas.drawText("\u2014", x + 4f, y + 14f, dashPaint)
                }
            }
            y += rowHeight
        }

        canvas.drawLine(MARGIN, y, PAGE_WIDTH - MARGIN, y, linePaint)
        y += 16f
        canvas.drawText("Generated by VineTrack \u2022 ${df.format(Date())}", MARGIN, minOf(y, PAGE_HEIGHT - MARGIN - 4f), captionPaint)

        doc.finishPage(page)
        return pageNumber + 1
    }

    private fun drawGraphPage(
        doc: PdfDocument,
        startPageNumber: Int,
        block: BlockReport,
        vineyardName: String,
        df: SimpleDateFormat,
        vintageColors: Map<Int, Int>,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        logo: Bitmap?,
    ): Int {
        val page = doc.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, startPageNumber).create())
        val canvas = page.canvas
        var y = MARGIN
        val contentWidth = PAGE_WIDTH - MARGIN * 2

        val textX = PdfHeaderUtil.drawLogo(canvas, logo, MARGIN, y)
        canvas.drawText(vineyardName.ifBlank { "Vineyard" }, textX, y + 16f, titlePaint)
        y += 22f
        canvas.drawText("Growth Stage Timeline", textX, y + 4f, subtitlePaint)
        y += 22f
        canvas.drawText(block.blockName, MARGIN, y + 10f, subtitlePaint)
        y += 20f

        val sortedVintages = block.vintages.sortedDescending()
        val elIndices = GrowthStage.allStages.mapIndexed { i, s -> s.code to i }.toMap()
        val orderedCodes = GrowthStage.allStages.map { it.code }.filter { code ->
            block.stageCodes.contains(code) && sortedVintages.any { block.entries[it]?.get(code) != null }
        }

        if (orderedCodes.size < 2) {
            canvas.drawText("Not enough data points to generate graph.", MARGIN, y + 12f, bodyPaint)
            doc.finishPage(page)
            return startPageNumber + 1
        }

        val graphLeft = MARGIN + 50f
        val graphRight = PAGE_WIDTH - MARGIN - 20f
        val graphTop = y + 10f
        val graphBottom = PAGE_HEIGHT - MARGIN - 80f
        val graphWidth = graphRight - graphLeft
        val graphHeight = graphBottom - graphTop

        val minIndex = orderedCodes.mapNotNull { elIndices[it] }.min()
        val maxIndex = orderedCodes.mapNotNull { elIndices[it] }.max()
        val indexRange = maxOf(maxIndex - minIndex, 1)

        // Graph background + border.
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(242, 242, 242) }
        canvas.drawRect(RectF(graphLeft, graphTop, graphRight, graphBottom), bgPaint)
        val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; color = Color.rgb(217, 217, 217); strokeWidth = 0.5f
        }
        canvas.drawRect(RectF(graphLeft, graphTop, graphRight, graphBottom), borderPaint)

        // Y-axis stage gridlines + labels.
        val yLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.DKGRAY; textSize = 7f }
        val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(224, 224, 224); strokeWidth = 0.3f }
        GrowthStage.allStages.forEach { stage ->
            val idx = elIndices[stage.code] ?: return@forEach
            if (idx < minIndex || idx > maxIndex) return@forEach
            val yPos = graphBottom - (idx - minIndex).toFloat() / indexRange * graphHeight
            canvas.drawLine(graphLeft, yPos, graphRight, yPos, gridPaint)
            val w = yLabelPaint.measureText(stage.code)
            canvas.drawText(stage.code, graphLeft - w - 4f, yPos + 2.5f, yLabelPaint)
        }

        // X-axis month ticks (Jul→Jun season).
        val monthNames = listOf("Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun")
        val xLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.DKGRAY; textSize = 7f }
        val tickPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.GRAY; strokeWidth = 0.5f }
        monthNames.forEachIndexed { i, label ->
            val fraction = i / 12.0
            val xPos = graphLeft + (fraction * graphWidth).toFloat()
            canvas.drawLine(xPos, graphBottom, xPos, graphBottom + 4f, tickPaint)
            canvas.drawLine(xPos, graphTop, xPos, graphBottom, gridPaint)
            val w = xLabelPaint.measureText(label)
            canvas.drawText(label, xPos - w / 2f, graphBottom + 13f, xLabelPaint)
        }

        // Plot each vintage line.
        val cal = Calendar.getInstance(TimeZone.getDefault()).apply { firstDayOfWeek = Calendar.MONDAY }
        sortedVintages.forEach { vintage ->
            val seasonStart = dateFor(cal, vintage - 1, seasonStartMonth, seasonStartDay)
            val seasonEnd = dateFor(cal, vintage, seasonStartMonth, seasonStartDay)
            val totalDays = (seasonEnd - seasonStart).toDouble()
            if (totalDays <= 0) return@forEach

            val points = orderedCodes.mapNotNull { code ->
                val epoch = block.entries[vintage]?.get(code) ?: return@mapNotNull null
                val normalized = (epoch - seasonStart).toDouble() / totalDays
                Triple(code, normalized, elIndices[code] ?: 0)
            }.sortedBy { it.second }
            if (points.size < 2) return@forEach

            val color = vintageColors[vintage] ?: Color.BLUE
            val linePathPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE; this.color = color; strokeWidth = 2f
                strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
            }
            val path = Path()
            points.forEachIndexed { i, (_, normX, idx) ->
                val xPos = graphLeft + (normX * graphWidth).toFloat()
                val yPos = graphBottom - (idx - minIndex).toFloat() / indexRange * graphHeight
                if (i == 0) path.moveTo(xPos, yPos) else path.lineTo(xPos, yPos)
            }
            canvas.drawPath(path, linePathPaint)

            val dotFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
            val dotInner = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = Color.WHITE }
            points.forEach { (_, normX, idx) ->
                val xPos = graphLeft + (normX * graphWidth).toFloat()
                val yPos = graphBottom - (idx - minIndex).toFloat() / indexRange * graphHeight
                canvas.drawCircle(xPos, yPos, 3f, dotFill)
                canvas.drawCircle(xPos, yPos, 1.5f, dotInner)
                canvas.drawCircle(xPos, yPos, 1f, dotFill)
            }
        }

        // Legend.
        val legendY = PAGE_HEIGHT - MARGIN - 40f
        val legendPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.DKGRAY; textSize = 9f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        var legendX = MARGIN
        sortedVintages.forEach { vintage ->
            val color = vintageColors[vintage] ?: Color.BLUE
            canvas.drawCircle(legendX + 5f, legendY + 9f, 5f, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
            legendX += 14f
            val label = "Vintage $vintage"
            canvas.drawText(label, legendX, legendY + 12f, legendPaint)
            legendX += legendPaint.measureText(label) + 20f
        }

        canvas.drawText("Generated by VineTrack \u2022 ${df.format(Date())}", MARGIN, PAGE_HEIGHT - MARGIN - 4f, captionPaint)

        doc.finishPage(page)
        return startPageNumber + 1
    }

    /** Epoch ms for the given year/month(1-12)/day in the local calendar. */
    private fun dateFor(cal: Calendar, year: Int, month: Int, day: Int): Long {
        cal.clear()
        cal.set(year, month - 1, day, 0, 0, 0)
        return cal.timeInMillis
    }

    private fun dateTemplate(format: RegionDateFormat): String = when (format) {
        RegionDateFormat.DayMonthYear -> "d MMM yyyy"
        RegionDateFormat.MonthDayYear -> "MMM d, yyyy"
        RegionDateFormat.IsoYearMonthDay -> "yyyy-MM-dd"
    }

    private fun ellipsize(text: String, paint: Paint, maxWidth: Float): String {
        if (paint.measureText(text) <= maxWidth) return text
        var end = text.length
        while (end > 0 && paint.measureText(text.substring(0, end) + "\u2026") > maxWidth) end--
        return if (end <= 0) "\u2026" else text.substring(0, end) + "\u2026"
    }

    private fun fileName(vineyardName: String): String {
        val safe = vineyardName.ifBlank { "Vineyard" }
            .replace(" ", "_").replace("/", "-").replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
            .ifBlank { "Vineyard" }
        val stamp = SimpleDateFormat("yyyyMMdd", Locale.getDefault()).format(Date())
        return "GrowthStageReport_${safe}_$stamp.pdf"
    }
}
