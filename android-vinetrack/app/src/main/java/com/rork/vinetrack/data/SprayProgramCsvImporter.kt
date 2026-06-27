package com.rork.vinetrack.data

import android.content.Context
import android.net.Uri
import com.rork.vinetrack.data.model.SavedChemical
import java.util.Locale

/**
 * Parser for the Spray Program import CSV (the importable template / program
 * CSV produced by [SprayProgramCsvExporter]). Mirrors the iOS
 * `SprayProgramCSVService.parseCSV` contract:
 *
 * - Row 1 is an ignored description, row 2 is the header row, data starts row 3
 *   (the parser auto-detects the header row, so a plain header+data file also
 *   works).
 * - Required headers: "Spray Name" and a "Date" column (DD/MM/YYYY).
 * - Up to six chemicals per record, each with name/amount/rate-per-ha/
 *   rate-per-100L/unit/cost columns.
 *
 * Parsing is purely local (no network, no schema access) and tolerant: rows
 * with unrecoverable problems (e.g. an invalid date) are skipped with a
 * warning rather than aborting the whole import, up to a sane error ceiling.
 * Amounts are kept as-entered alongside the unit string, matching how Android
 * stores spray chemicals (no base-unit conversion).
 */
object SprayProgramCsvImporter {

    private const val MAX_CHEMICALS = 6
    private const val MAX_SKIPPED = 10

    /** A single chemical line parsed from one CSV record. */
    data class ImportedChemical(
        val name: String,
        val amountPerTank: Double,
        val ratePerHa: Double,
        val ratePer100L: Double,
        val unit: String,
        val costPerUnit: Double,
        /** Linked saved-chemical id when the name uniquely matched the library. */
        val savedChemicalId: String? = null,
    )

    /** A single spray record parsed from one CSV row. */
    data class ImportedSprayRow(
        val sprayName: String,
        val dateEpochMs: Long,
        val blockName: String,
        val operatorName: String,
        val equipment: String,
        val tractor: String,
        val gear: String,
        val fansJets: String,
        val waterVolume: Double,
        val sprayRate: Double,
        val concentrationFactor: Double,
        val temperature: Double?,
        val windSpeed: Double?,
        val windDirection: String,
        val humidity: Double?,
        val notes: String,
        val isTemplate: Boolean,
        val operationType: String,
        val chemicals: List<ImportedChemical>,
    )

    /** A non-fatal issue attached to a specific source row. */
    data class ImportWarning(val row: Int, val message: String)

    /**
     * Saved-chemical linking summary for the parsed file. Counts chemical *lines*
     * (not distinct names): how many were uniquely linked to the loaded library,
     * how many had no match, and how many matched more than one saved chemical
     * (ambiguous → left unlinked).
     */
    data class ChemicalLinkSummary(
        val matched: Int = 0,
        val unmatched: Int = 0,
        val ambiguous: Int = 0,
    ) {
        val hasLibrary: Boolean get() = matched + unmatched + ambiguous > 0
    }

    /** The outcome of a successful parse: the rows to import plus any warnings. */
    data class ImportResult(
        val rows: List<ImportedSprayRow>,
        val warnings: List<ImportWarning>,
        val chemicalLinks: ChemicalLinkSummary = ChemicalLinkSummary(),
    )

    /** A fatal parse failure with a user-friendly message. */
    sealed class ImportError(val userMessage: String) : Exception(userMessage) {
        data object EmptyFile : ImportError("The file is empty or couldn't be read.")
        data object NoDataRows : ImportError(
            "No data rows found after the header. Make sure spray records start below the column headers."
        )
        data class MissingHeaders(val missing: List<String>) : ImportError(
            "Required columns missing: ${missing.joinToString(", ")}. Please use the provided CSV template."
        )
        data class TooManyErrors(val count: Int) : ImportError(
            "Too many invalid rows ($count). Please check the file matches the template format."
        )
        data object WrongFileType : ImportError("This file doesn't look like a CSV. Please pick a .csv file.")
    }

    /** Read the document the user picked through the Storage Access Framework. */
    fun readBytes(context: Context, uri: Uri): ByteArray? =
        try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            android.util.Log.e("SprayProgramCsvImporter", "Couldn't read import file", e)
            null
        }

    /**
     * Parse CSV [data] into an [ImportResult]. Throws [ImportError] on fatal
     * problems (empty file, missing required headers, wrong file type, or too
     * many invalid rows).
     *
     * @param savedChemicals the loaded saved-chemical library used to auto-link
     *   imported chemical names to `savedChemicalId`. Pass an empty list to skip
     *   linking (iOS-equivalent behaviour). Matching is case-insensitive exact on
     *   the saved chemical's display name; duplicate names are treated as
     *   ambiguous and left unlinked with a warning.
     * @param allowCostPrefill when true (owner/manager), a blank/zero CSV cost is
     *   backfilled from a uniquely-matched saved chemical's cost-per-unit. CSV
     *   cost always wins when explicitly present. Never affects rate/unit.
     */
    @Throws(ImportError::class)
    fun parseCsv(
        data: ByteArray,
        savedChemicals: List<SavedChemical> = emptyList(),
        allowCostPrefill: Boolean = false,
    ): ImportResult {
        val content = decode(data) ?: throw ImportError.EmptyFile
        val trimmed = content.trim()
        if (trimmed.isEmpty()) throw ImportError.EmptyFile
        // Reject obviously-wrong binary/structured files early (PDF, zip/xlsx, JSON).
        if (trimmed.startsWith("PK") || trimmed.startsWith("%PDF") ||
            trimmed.startsWith("{") || trimmed.startsWith("[")
        ) {
            throw ImportError.WrongFileType
        }

        val lines = parseCsvLines(content)
        if (lines.isEmpty()) throw ImportError.EmptyFile

        val headerIndex = findHeaderLine(lines)
            ?: throw ImportError.MissingHeaders(listOf("Spray Name", "Date (DD/MM/YYYY)"))

        val headers = lines[headerIndex].map { it.trim().lowercase(Locale.getDefault()) }
        val missing = buildList {
            if (headers.none { it.contains("spray name") }) add("Spray Name")
            if (headers.none { it.contains("date") }) add("Date (DD/MM/YYYY)")
        }
        if (missing.isNotEmpty()) throw ImportError.MissingHeaders(missing)

        val dataStart = headerIndex + 1
        if (dataStart >= lines.size) throw ImportError.NoDataRows

        // Index the active saved-chemical library by normalised display name so we
        // can detect unique vs ambiguous (duplicate-name) matches in O(1) per line.
        val chemicalIndex: Map<String, List<SavedChemical>> = savedChemicals
            .filter { it.deletedAt == null }
            .groupBy { it.displayName.trim().lowercase(Locale.getDefault()) }

        val rows = ArrayList<ImportedSprayRow>()
        val warnings = ArrayList<ImportWarning>()
        var skipped = 0
        var matchedLines = 0
        var unmatchedLines = 0
        var ambiguousLines = 0

        for (lineIndex in dataStart until lines.size) {
            val fields = lines[lineIndex]
            if (fields.all { it.trim().isEmpty() }) continue
            val rowNum = lineIndex + 1

            fun field(partial: String): String {
                val idx = headers.indexOfFirst { it.contains(partial) }
                if (idx < 0 || idx >= fields.size) return ""
                return fields[idx].trim()
            }

            val sprayName = field("spray name")
            if (sprayName.isEmpty()) {
                warnings.add(ImportWarning(rowNum, "Spray Name is empty"))
            }

            val dateStr = field("date")
            val dateMs = parseDate(dateStr)
            if (dateMs == null) {
                warnings.add(
                    if (dateStr.isEmpty()) ImportWarning(rowNum, "Date is empty — row skipped")
                    else ImportWarning(rowNum, "Invalid date '$dateStr' — row skipped. Use DD/MM/YYYY")
                )
                skipped++
                if (skipped >= MAX_SKIPPED) throw ImportError.TooManyErrors(skipped)
                continue
            }
            if (dateMs > System.currentTimeMillis()) {
                warnings.add(ImportWarning(rowNum, "Date is in the future"))
            }

            val blockName = field("block")
            if (blockName.isEmpty()) warnings.add(ImportWarning(rowNum, "Block name is empty"))

            val waterStr = field("water volume")
            val waterVolume = waterStr.toDoubleOrNullSafe() ?: 0.0
            if (waterStr.isNotEmpty() && waterVolume <= 0) {
                warnings.add(ImportWarning(rowNum, "Water Volume '$waterStr' is not a valid number"))
            }

            val rateStr = field("spray rate")
            val sprayRate = rateStr.toDoubleOrNullSafe() ?: 0.0
            if (rateStr.isNotEmpty() && sprayRate <= 0) {
                warnings.add(ImportWarning(rowNum, "Spray Rate '$rateStr' is not a valid number"))
            }

            val cfStr = field("concentration")
            val concentrationFactor = cfStr.toDoubleOrNullSafe() ?: 1.0
            if (cfStr.isNotEmpty() && concentrationFactor <= 0) {
                warnings.add(ImportWarning(rowNum, "Concentration Factor '$cfStr' is not a valid number"))
            }

            val chemicals = ArrayList<ImportedChemical>()
            for (i in 1..MAX_CHEMICALS) {
                val prefix = "chemical $i"
                val name = field("$prefix name")
                if (name.isEmpty()) continue
                val amountStr = field("$prefix amount")
                val amount = amountStr.toDoubleOrNullSafe() ?: 0.0
                val rateHaStr = field("$prefix rate per ha")
                val rateHa = rateHaStr.toDoubleOrNullSafe() ?: 0.0
                val rate100LStr = field("$prefix rate per 100l")
                val rate100L = rate100LStr.toDoubleOrNullSafe() ?: 0.0
                val unitStr = field("$prefix unit")
                val unit = parseUnit(unitStr)
                val costStr = field("$prefix cost")
                val cost = costStr.toDoubleOrNullSafe() ?: 0.0

                if (amountStr.isNotEmpty() && amount <= 0) {
                    warnings.add(ImportWarning(rowNum, "Chemical $i '$name' has an invalid amount"))
                }
                if (rateHaStr.isNotEmpty() && rateHa <= 0) {
                    warnings.add(ImportWarning(rowNum, "Chemical $i '$name' has an invalid rate per ha"))
                }
                if (rate100LStr.isNotEmpty() && rate100L <= 0) {
                    warnings.add(ImportWarning(rowNum, "Chemical $i '$name' has an invalid rate per 100L"))
                }
                // Cost may legitimately be 0/blank, so only flag genuinely
                // unparseable values — never let "abc" silently become 0.
                if (costStr.isNotEmpty() && costStr.toDoubleOrNullSafe() == null) {
                    warnings.add(ImportWarning(rowNum, "Chemical $i '$name' has an invalid cost '$costStr' — treated as no cost"))
                }
                if (unitStr.isEmpty()) {
                    warnings.add(ImportWarning(rowNum, "Chemical $i '$name' has no unit — defaulting to Litres"))
                }

                // Auto-link to the saved-chemical library by case-insensitive exact
                // name. Unique match links; duplicate names stay unlinked (ambiguous).
                val key = name.trim().lowercase(Locale.getDefault())
                val candidates = chemicalIndex[key].orEmpty()
                var linkedId: String? = null
                var resolvedCost = cost
                when {
                    candidates.size == 1 -> {
                        val saved = candidates.first()
                        linkedId = saved.id
                        matchedLines++
                        // CSV cost wins when present; otherwise backfill from the
                        // matched saved chemical (owner/manager only).
                        if (allowCostPrefill && cost <= 0.0) {
                            saved.costPerUnit?.takeIf { it > 0.0 }?.let { resolvedCost = it }
                        }
                    }
                    candidates.size > 1 -> {
                        ambiguousLines++
                        warnings.add(ImportWarning(rowNum, "Chemical $i '$name' matches ${candidates.size} saved chemicals — left unlinked"))
                    }
                    else -> unmatchedLines++
                }

                chemicals.add(
                    ImportedChemical(
                        name = name,
                        amountPerTank = amount,
                        ratePerHa = rateHa,
                        ratePer100L = rate100L,
                        unit = unit,
                        costPerUnit = resolvedCost,
                        savedChemicalId = linkedId,
                    )
                )
            }
            if (chemicals.isEmpty()) warnings.add(ImportWarning(rowNum, "No chemicals listed"))

            val notes = field("notes")
            if (notes.contains("example row", ignoreCase = true) ||
                notes.contains("delete before importing", ignoreCase = true)
            ) {
                warnings.add(ImportWarning(rowNum, "Looks like the template example row — consider removing it"))
            }

            val templateStr = field("template").lowercase(Locale.getDefault())
            val isTemplate = templateStr == "yes" || templateStr == "true" || templateStr == "1"

            rows.add(
                ImportedSprayRow(
                    sprayName = sprayName,
                    dateEpochMs = dateMs,
                    blockName = blockName,
                    operatorName = field("operator"),
                    equipment = field("equipment"),
                    tractor = field("tractor"),
                    gear = field("gear"),
                    fansJets = field("fans"),
                    waterVolume = waterVolume,
                    sprayRate = sprayRate,
                    concentrationFactor = concentrationFactor,
                    temperature = field("temperature").toDoubleOrNullSafe(),
                    windSpeed = field("wind speed").toDoubleOrNullSafe(),
                    windDirection = field("wind direction"),
                    humidity = field("humidity").toDoubleOrNullSafe(),
                    notes = notes,
                    isTemplate = isTemplate,
                    operationType = parseOperationType(field("operation type")),
                    chemicals = chemicals,
                )
            )
        }

        if (rows.isEmpty()) throw ImportError.NoDataRows
        return ImportResult(
            rows = rows,
            warnings = warnings,
            chemicalLinks = ChemicalLinkSummary(
                matched = matchedLines,
                unmatched = unmatchedLines,
                ambiguous = ambiguousLines,
            ),
        )
    }

    // MARK: - Helpers

    private fun decode(data: ByteArray): String? {
        val text = try {
            String(data, Charsets.UTF_8)
        } catch (_: Exception) {
            try { String(data, Charsets.ISO_8859_1) } catch (_: Exception) { return null }
        }
        // Strip a leading UTF-8 BOM (Excel's "CSV UTF-8" export adds one), which
        // would otherwise prefix the first header/description cell.
        return text.removePrefix("\uFEFF")
    }

    /** Locate the header row by looking for a line containing both Spray Name and a Date column. */
    private fun findHeaderLine(lines: List<List<String>>): Int? {
        for ((index, line) in lines.withIndex()) {
            val joined = line.map { it.trim().lowercase(Locale.getDefault()) }
            if (joined.any { it.contains("spray name") } && joined.any { it.contains("date") }) {
                return index
            }
        }
        return null
    }

    /** Parse DD/MM/YYYY (and the lenient D/M/YYYY variant) into epoch millis at local midnight. */
    private fun parseDate(value: String): Long? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return null
        val parts = trimmed.split("/", "-")
        if (parts.size != 3) return null
        val day = parts[0].trim().toIntOrNull() ?: return null
        val month = parts[1].trim().toIntOrNull() ?: return null
        val year = parts[2].trim().toIntOrNull() ?: return null
        if (month !in 1..12 || day !in 1..31 || year < 1900 || year > 3000) return null
        return try {
            val cal = java.util.Calendar.getInstance()
            cal.clear()
            cal.set(year, month - 1, day, 12, 0, 0)
            cal.timeInMillis
        } catch (_: Exception) {
            null
        }
    }

    /** Normalise a unit string to the Android `SprayChemical.unit` raw value. */
    private fun parseUnit(value: String): String = when (value.trim().lowercase(Locale.getDefault())) {
        "litres", "litre", "l", "ltr" -> "Litres"
        "ml", "millilitres", "millilitre" -> "mL"
        "kg", "kilograms", "kilogram" -> "Kg"
        "g", "grams", "gram" -> "g"
        else -> "Litres"
    }

    /** Normalise the operation type to a built-in raw value, defaulting to Foliar Spray. */
    private fun parseOperationType(value: String): String = when (value.trim().lowercase(Locale.getDefault())) {
        "foliar spray", "foliar" -> "Foliar Spray"
        "banded spray", "banded" -> "Banded Spray"
        "spreader" -> "Spreader"
        else -> "Foliar Spray"
    }

    private fun String.toDoubleOrNullSafe(): Double? =
        replace(",", "").trim().takeIf { it.isNotEmpty() }?.toDoubleOrNull()

    /** RFC-4180-tolerant CSV reader (quoted commas, escaped quotes, CRLF/LF). */
    private fun parseCsvLines(content: String): List<List<String>> {
        val result = ArrayList<List<String>>()
        var currentField = StringBuilder()
        var currentRow = ArrayList<String>()
        var inQuotes = false
        var i = 0
        val n = content.length
        while (i < n) {
            val c = content[i]
            if (inQuotes) {
                if (c == '"') {
                    if (i + 1 < n && content[i + 1] == '"') {
                        currentField.append('"')
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(c)
                }
            } else {
                when (c) {
                    '"' -> inQuotes = true
                    ',' -> {
                        currentRow.add(currentField.toString())
                        currentField = StringBuilder()
                    }
                    '\n', '\r' -> {
                        if (c == '\r' && i + 1 < n && content[i + 1] == '\n') i++
                        currentRow.add(currentField.toString())
                        currentField = StringBuilder()
                        if (currentRow.any { it.isNotEmpty() }) result.add(currentRow)
                        currentRow = ArrayList()
                    }
                    else -> currentField.append(c)
                }
            }
            i++
        }
        if (currentField.isNotEmpty() || currentRow.isNotEmpty()) {
            currentRow.add(currentField.toString())
            if (currentRow.any { it.isNotEmpty() }) result.add(currentRow)
        }
        return result
    }
}
