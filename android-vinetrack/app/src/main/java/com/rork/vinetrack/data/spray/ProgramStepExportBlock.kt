package com.rork.vinetrack.data.spray

/** One PDF group per template identity; never group by product or timing name. */
data class ProgramStepExportBlock(val reference: SprayProgramReferenceRow, val products: List<ProgramPDFProduct>) {
    private val stagePattern get() = Regex("(?i)\\bE-?L\\s*(?:Stage\\s*)?-?\\s*([0-9]+(?:\\s*[-–]\\s*[0-9]+)?)")
    val stage: String get() = stagePattern.find(reference.name)?.groupValues?.get(1)?.let { "E-L Stage $it" }
        ?: reference.stage.replace("EL", "E-L Stage ")
    val timing: String get() = reference.name.replace(stagePattern, "").trim { it.isWhitespace() || it in "—–-/()" }.ifEmpty { reference.name }
    val growthDescription: String get() = reference.description.removePrefix("${reference.stage} - ")
    val comments: String get() = ProgramPDFLayout.comments(reference.notes)
    companion object {
        fun grouped(rows: List<SprayProgramReferenceRow>): List<ProgramStepExportBlock> {
            val blocks = mutableListOf<ProgramStepExportBlock>()
            for (row in rows) {
                val product = row.pdfProduct ?: ProgramPDFProduct(row.product)
                val index = if (row.pdfStepId.isEmpty()) -1 else blocks.indexOfFirst { it.reference.pdfStepId == row.pdfStepId }
                if (index < 0) blocks.add(ProgramStepExportBlock(row, listOf(product)))
                else blocks[index] = blocks[index].copy(products = blocks[index].products + product)
            }
            return blocks
        }
    }
}

enum class ProgramPDFColumn(val title: String, val weight: Double, val reclaim: Double = 0.0, val shared: Boolean = false) {
    TIMING("TIMING", 15.0, 2.0, true), TARGETS("TARGET / PURPOSE", 20.0, 3.0, true),
    PRODUCT("PRODUCT", 12.0, 2.0), PER100L("RATE /100 L", 9.0), MOA("MOA", 6.0),
    COST("EST $/HA", 7.0), METHOD("APPLICATION METHOD", 8.0, shared = true),
    PERHA("RATE /HA", 8.0), COMMENTS("COMMENTS", 15.0, 3.0, true),
}

/** Document-wide column decisions and word wrapping, kept equivalent to the Swift report. */
object ProgramPDFLayout {
    fun columns(blocks: List<ProgramStepExportBlock>): List<ProgramPDFColumn> {
        val products = blocks.flatMap { it.products }
        return ProgramPDFColumn.entries.filter { column -> when (column) {
            ProgramPDFColumn.TIMING, ProgramPDFColumn.PRODUCT -> true
            ProgramPDFColumn.TARGETS -> blocks.any { it.reference.targets.isNotBlank() }
            ProgramPDFColumn.METHOD -> blocks.any { it.reference.method.isNotBlank() }
            ProgramPDFColumn.COMMENTS -> blocks.any { it.comments.isNotEmpty() }
            ProgramPDFColumn.PER100L -> products.any { it.per100L.isNotEmpty() }
            ProgramPDFColumn.PERHA -> products.any { it.perHa.isNotEmpty() }
            ProgramPDFColumn.MOA -> products.any { it.moa.isNotEmpty() }
            ProgramPDFColumn.COST -> products.any { it.estimatedCost.isNotEmpty() }
        } }
    }
    fun widths(columns: List<ProgramPDFColumn>, total: Double = 770.0): List<Double> {
        val freed = 100.0 - columns.sumOf { it.weight }
        val reclaim = columns.sumOf { it.reclaim }.coerceAtLeast(1.0)
        return columns.map { total * (it.weight + freed * it.reclaim / reclaim) / 100.0 }
    }
    fun needsFreshPage(height: Double, y: Double, top: Double, bottom: Double = 548.0): Boolean = y > top && y + height > bottom
    fun slice(height: Double, offset: Double, available: Double, boundaries: List<Double>): Double {
        if (height - offset <= available) return height - offset
        return boundaries.map { it + 4.0 }.lastOrNull { it > offset && it <= offset + available }?.minus(offset)
            ?: (kotlin.math.floor((offset + available - 4.0) / 10.0) * 10.0 + 4.0 - offset)
    }
    fun methodStyle(value: String): String = when (value.trim().lowercase()) {
        "foliar" -> "gold"
        "banded" -> "green"
        else -> "neutral"
    }
    /** Display-only removal of recognised metadata; unknown instructions remain. */
    fun comments(raw: String): String {
        val marked = raw.replace(Regex("(?i)product details\\s*[-–—]\\s*([^:\\n]+):"), "\u001F$1:\u001E")
        val fields = Regex("(?i)^(?:rate\\s*(?:/\\s*100\\s*l|/\\s*ha|per\\s*100\\s*l|per\\s*ha)?|moa|est\\s*\\$\\s*/\\s*ha)\\s*[:=]?\\s*[MU$]?[0-9][0-9.,–+MU\\- /]*\\s*(?:kg|g|ml|l)?\\s*(?:/\\s*(?:100\\s*l|treated\\s*ha|ha))?$")
        return marked.split('\u001F').flatMapIndexed { index, part ->
            val text = if (index > 0) {
                val heading = part.substringBefore('\u001E')
                val instructions = part.substringAfter('\u001E', "").split(Regex("[;|\\n]"))
                    .map { it.trim() }.filter { it.isNotEmpty() && !fields.matches(it) }
                if (instructions.isEmpty()) "" else heading + " " + instructions.joinToString("\n")
            } else part
            text.lines().filter { it.trim().lowercase() !in listOf("", "rate set when planning", "no data", "n/a", "none", "unknown", "-") }
        }.joinToString("\n").trim()
    }
    fun wrap(text: String, width: Double, measure: (String) -> Double): List<String> {
        if (text.isEmpty()) return emptyList()
        return buildList {
            for (paragraph in text.split('\n')) {
                var line = ""
                for (word in paragraph.split(Regex("\\s+")).filter { it.isNotEmpty() }) {
                    if (line.isNotEmpty() && measure("$line $word") > width) { add(line); line = "" }
                    if (measure(word) <= width) line += (if (line.isEmpty()) "" else " ") + word
                    else {
                        if (line.isNotEmpty()) { add(line); line = "" }
                        for (character in word) {
                            if (line.isNotEmpty() && measure(line + character) > width) { add(line); line = "" }
                            line += character
                        }
                    }
                }
                add(line)
            }
        }
    }
}
