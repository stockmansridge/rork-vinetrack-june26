package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.formatTripDuration
import com.rork.vinetrack.data.model.resolveSprayTrip
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Exports a program-level CSV of spray records and shares it through the Android
 * share sheet. The column layout mirrors the iOS `SprayProgramCSVService`
 * importable template (one row per spray record, up to six consolidated
 * chemicals each) so a file exported on Android stays compatible with the iOS
 * importer.
 *
 * Per-chemical cost (`Cost Per Unit`) is emitted when a record carries it
 * (e.g. from a costed CSV import); records without cost data leave those
 * fields blank rather than fabricating values. Two trailing summary columns
 * (`Total Chemical Cost`, `Cost Per Ha`) plus the cost-rollup columns
 * (`active_hours`, `labour_cost`, `fuel_litres_estimated`, `fuel_cost`,
 * `chemical_cost`, `total_estimated_cost`, `costing_status`, `treated_area_ha`,
 * `cost_per_ha`) are appended for owner/manager exports only and are ignored by
 * the importer (which matches columns by name). The cost-rollup columns mirror
 * the iOS `SprayProgramCSVService` `includeCostings` layout and are computed via
 * the pure [TripCostEstimator] for the linked trip; `yield_tonnes` /
 * `cost_per_tonne` remain parked. Supervisor/operator exports omit every
 * financial column entirely (never blanked). The CSV is written to the app
 * cache (`cache/exports`) and shared via [FileProvider]; it is never uploaded
 * to Supabase.
 */
object SprayProgramCsvExporter {

    private const val MAX_CHEMICALS = 6

    /** Non-financial core columns: base fields + the six per-chemical blocks. */
    private val coreHeaders: List<String> = buildList {
        addAll(
            listOf(
                "Spray Name", "Date (DD/MM/YYYY)", "Block", "Operator",
                "Equipment", "Tractor", "Gear", "Fans/Jets",
                "Water Volume (L)", "Spray Rate (L/Ha)", "Concentration Factor",
                "Growth Stage",
                "Temperature (\u00B0C)", "Wind Speed (km/h)", "Wind Direction", "Humidity (%)",
                "Notes", "Template (Yes/No)", "Operation Type",
            )
        )
        for (i in 1..MAX_CHEMICALS) {
            add("Chemical $i Name")
            add("Chemical $i Amount Per Tank")
            add("Chemical $i Rate Per Ha")
            add("Chemical $i Rate Per 100L")
            add("Chemical $i Unit (Litres/mL/Kg/g)")
            add("Chemical $i Cost Per Unit")
        }
    }

    /**
     * Per-chemical-cost summary columns. Financial — emitted for owner/manager
     * only. Ignored by the importer (name-matched parsing).
     */
    private val summaryHeaders: List<String> = listOf("Total Chemical Cost", "Cost Per Ha")

    /** Export-only row-coverage + tank fill-timer columns (ignored by importer). */
    private val coverageHeaders: List<String> = listOf(
        "Tracking Pattern", "Paths Planned", "Paths Completed", "Paths Skipped", "Paths Not Complete",
        "Tank Sessions", "Total Fill Time", "Active Tank",
    )

    /**
     * Cost-rollup columns mirroring the iOS `includeCostings` layout. Financial —
     * emitted for owner/manager only, computed via [TripCostEstimator] when a
     * trip is linked. `yield_tonnes` / `cost_per_tonne` remain parked.
     */
    private val costRollupHeaders: List<String> = listOf(
        "active_hours", "labour_cost", "fuel_litres_estimated", "fuel_cost",
        "chemical_cost", "total_estimated_cost", "costing_status",
        "treated_area_ha", "cost_per_ha",
    )

    /**
     * Full importable template layout (role-agnostic): core + summary + coverage.
     * The cost-rollup columns are export-only and intentionally absent here.
     */
    private val templateHeaders: List<String> = coreHeaders + summaryHeaders + coverageHeaders

    /**
     * Build the export header row. Financial columns (summary + cost rollup) are
     * included only when [includeCostings] is true; otherwise they are omitted
     * entirely so cost data never leaves the app for supervisor/operator.
     */
    private fun exportHeaders(includeCostings: Boolean): List<String> = buildList {
        addAll(coreHeaders)
        if (includeCostings) addAll(summaryHeaders)
        addAll(coverageHeaders)
        if (includeCostings) addAll(costRollupHeaders)
    }

    /**
     * Description row (row 1) mirroring the iOS importer. Row 1 is ignored on
     * import; row 2 is the header row; the example row (row 3) is meant to be
     * deleted before importing.
     */
    private const val DESCRIPTION_ROW =
        "VineTrack Spray Program Import Template \u2014 Row 1 is this description (ignored on import). " +
        "Row 2 contains column headers. Enter one spray record per row starting from Row 3. " +
        "Dates must be DD/MM/YYYY. Chemical units: Litres, mL, Kg, or g. Growth Stage uses E-L codes (e.g. EL12). " +
        "Operation Type: Foliar Spray, Banded Spray, or Spreader. Delete the example row before importing. " +
        "Up to 6 chemicals per record."

    /**
     * Build the blank importable CSV template (description row + headers +
     * one example row), write it to cache, and launch the share sheet. The
     * column layout matches [baseHeaders] / the program CSV export so a
     * downloaded template can be filled in and re-imported on iOS. Returns
     * false on failure; never throws.
     */
    fun exportTemplateAndShare(context: Context): Boolean {
        return try {
            val csv = buildTemplateCsv()

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, "SprayProgram_Template.csv")
            file.writeText(csv, Charsets.UTF_8)

            val uri: Uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(
                Intent.createChooser(share, "Spray program template").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("SprayProgramCsvExporter", "CSV template export failed", e)
            false
        }
    }

    private fun buildTemplateCsv(): String {
        val sb = StringBuilder()
        // Row 1: description spanning the full column width.
        sb.append(escape(DESCRIPTION_ROW))
        repeat(templateHeaders.size - 1) { sb.append(",") }
        sb.append("\n")
        // Row 2: headers.
        sb.append(templateHeaders.joinToString(",") { escape(it) }).append("\n")
        // Row 3: example row (delete before importing) — mirrors iOS.
        val example = ArrayList<String>(templateHeaders.size)
        example.addAll(
            listOf(
                "Spray 1", "15/01/2025", "Block A", "John",
                "Air Blast Sprayer", "John Deere 5075", "3", "12",
                "2000", "1000", "1.5",
                "EL12",
                "22", "10", "NW", "65",
                "Example row - delete before importing", "No", "Foliar Spray",
            )
        )
        // Chemical 1
        example.addAll(listOf("Mancozeb 750 WG", "600", "200", "20", "g", "0.02"))
        // Chemical 2
        example.addAll(listOf("Copper Oxychloride", "2250", "150", "15", "mL", "0.01"))
        // Chemicals 3..6 blank
        for (i in 3..MAX_CHEMICALS) {
            repeat(6) { example.add("") }
        }
        // Trailing summary columns (Total Chemical Cost, Cost Per Ha) — left blank.
        example.add("")
        example.add("")
        // Trailing row-coverage columns (export-only) — left blank in the template.
        repeat(5) { example.add("") }
        // Trailing tank fill-timer columns (export-only) — left blank in the template.
        repeat(3) { example.add("") }
        sb.append(example.joinToString(",") { escape(it) }).append("\n")
        return sb.toString()
    }

    /**
     * Build a CSV from [records] (already filtered/sorted by the caller — the
     * current visible result set), write it to cache, and launch the share
     * sheet. Returns false on failure; never throws.
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
    ): Boolean {
        return try {
            val csv = buildCsv(
                records = records,
                trips = trips,
                includeCostings = canViewFinancials,
                machines = machines,
                fuelPurchases = fuelPurchases,
                operatorCategories = operatorCategories,
                paddocks = paddocks,
            )

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, fileName(vineyardName))
            file.writeText(csv, Charsets.UTF_8)

            val uri: Uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(
                Intent.createChooser(share, "Export spray program").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("SprayProgramCsvExporter", "CSV export failed", e)
            false
        }
    }

    private fun buildCsv(
        records: List<SprayRecord>,
        trips: List<Trip>,
        includeCostings: Boolean,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        operatorCategories: List<OperatorCategory>,
        paddocks: List<Paddock>,
    ): String {
        val sb = StringBuilder()
        sb.append(exportHeaders(includeCostings).joinToString(",") { escape(it) }).append("\n")

        val dateFmt = SimpleDateFormat("dd/MM/yyyy", Locale.getDefault())

        for (record in records) {
            val trip = resolveSprayTrip(record, trips)
            val row = ArrayList<String>(exportHeaders(includeCostings).size)

            row.add(record.sprayReference.orEmpty())
            row.add(record.dateEpochMs?.let { dateFmt.format(Date(it)) } ?: "")
            row.add(trip?.paddockName ?: "")
            row.add(trip?.personName ?: "")
            row.add(record.equipmentType.orEmpty())
            row.add(record.tractor.orEmpty())
            row.add(record.tractorGear.orEmpty())
            row.add(record.numberOfFansJets.orEmpty())

            val tanks = record.tanks.orEmpty()
            val avgWater = if (tanks.isEmpty()) 0.0 else tanks.sumOf { it.waterVolume } / tanks.size
            val avgRate = if (tanks.isEmpty()) 0.0 else tanks.sumOf { it.sprayRatePerHa } / tanks.size
            val avgCf = if (tanks.isEmpty()) 0.0 else tanks.sumOf { it.concentrationFactor } / tanks.size

            row.add(if (avgWater > 0) String.format(Locale.US, "%.0f", avgWater) else "")
            row.add(if (avgRate > 0) String.format(Locale.US, "%.0f", avgRate) else "")
            row.add(if (avgCf > 0) String.format(Locale.US, "%.2f", avgCf) else "")

            // Growth stage isn't surfaced on Android spray records yet.
            row.add("")

            row.add(record.temperature?.let { String.format(Locale.US, "%.1f", it) } ?: "")
            row.add(record.windSpeed?.let { String.format(Locale.US, "%.1f", it) } ?: "")
            row.add(record.windDirection.orEmpty())
            row.add(record.humidity?.let { String.format(Locale.US, "%.0f", it) } ?: "")
            row.add(record.notes.orEmpty())
            row.add(if (record.isTemplate) "Yes" else "No")
            row.add(record.operationType.orEmpty())

            val chemicals = consolidateChemicals(tanks.flatMap { it.chemicals })
            for (i in 0 until MAX_CHEMICALS) {
                val chem = chemicals.getOrNull(i)
                if (chem != null) {
                    row.add(chem.name)
                    row.add(String.format(Locale.US, "%.2f", chem.volumePerTank))
                    row.add(String.format(Locale.US, "%.2f", chem.ratePerHa))
                    row.add(if (chem.ratePer100L > 0) String.format(Locale.US, "%.2f", chem.ratePer100L) else "")
                    row.add(chem.unit)
                    row.add(if (chem.costPerUnit > 0) String.format(Locale.US, "%.2f", chem.costPerUnit) else "")
                } else {
                    repeat(6) { row.add("") }
                }
            }

            // Summary columns (financial) — owner/manager only; populated when
            // cost data is defensible.
            if (includeCostings) {
                row.add(if (record.hasCostData) String.format(Locale.US, "%.2f", record.totalChemicalCost) else "")
                row.add(record.costPerHectare?.let { String.format(Locale.US, "%.2f", it) } ?: "")
            }

            // Row-coverage columns — populated only for planned trips; blank otherwise.
            if (trip != null && trip.hasRowPlan) {
                row.add(TrackingPattern.fromRaw(trip.trackingPattern).title)
                row.add("${trip.plannedPathCount}")
                row.add("${trip.completedRowCount}")
                row.add("${trip.skippedRowCount}")
                row.add("${trip.notCompletedRowCount}")
            } else {
                repeat(5) { row.add("") }
            }

            // Tank fill-timer columns — populated only when the trip recorded
            // tank sessions; blank otherwise.
            val sessions = trip?.tankSessions.orEmpty()
            if (sessions.isNotEmpty()) {
                val totalFill = sessions.sumOf { it.fillDurationSeconds ?: 0L }
                row.add("${sessions.size}")
                row.add(if (totalFill > 0) formatTripDuration(totalFill) else "")
                row.add(trip?.activeTankNumber?.toString() ?: "")
            } else {
                repeat(3) { row.add("") }
            }

            // Cost-rollup columns (financial) — owner/manager only. Computed via
            // the pure TripCostEstimator when a trip is linked; blank otherwise
            // (mirrors iOS, which appends empty cost cells for trip-less records).
            if (includeCostings) {
                if (trip != null) {
                    val est = TripCostEstimator.estimate(
                        trip = trip,
                        sprayRecord = record,
                        operatorCategories = operatorCategories,
                        machines = machines,
                        fuelPurchases = fuelPurchases,
                        paddocks = paddocks,
                    )
                    // active_hours
                    row.add(String.format(Locale.US, "%.2f", est.activeHours))
                    // labour_cost — blank when the labour estimate is incomplete.
                    row.add(if (est.labour.warning == null) String.format(Locale.US, "%.2f", est.labour.cost) else "")
                    // fuel_litres_estimated / fuel_cost — blank when fuel is incomplete.
                    row.add(if (est.fuel.warning == null) String.format(Locale.US, "%.2f", est.fuel.litres ?: 0.0) else "")
                    row.add(if (est.fuel.warning == null) String.format(Locale.US, "%.2f", est.fuel.fuelCost ?: 0.0) else "")
                    // chemical_cost — blank when unavailable/unpriced (cost 0 + warning).
                    row.add(
                        est.chemical?.let { c ->
                            if (c.warning != null && c.cost <= 0.0) "" else String.format(Locale.US, "%.2f", c.cost)
                        } ?: ""
                    )
                    // total_estimated_cost
                    row.add(String.format(Locale.US, "%.2f", est.totalCost))
                    // costing_status (iOS rawValue: complete/partial/unavailable)
                    row.add(est.completeness.name.lowercase(Locale.US))
                    // treated_area_ha / cost_per_ha — blank when unavailable.
                    row.add(est.treatedAreaHa?.let { String.format(Locale.US, "%.2f", it) } ?: "")
                    row.add(est.costPerHa?.let { String.format(Locale.US, "%.2f", it) } ?: "")
                } else {
                    repeat(costRollupHeaders.size) { row.add("") }
                }
            }

            sb.append(row.joinToString(",") { escape(it) }).append("\n")
        }

        return sb.toString()
    }

    /** Keep first occurrence per name (case-insensitive), sorted by name — mirrors iOS. */
    private fun consolidateChemicals(chemicals: List<SprayChemical>): List<SprayChemical> {
        val seen = LinkedHashMap<String, SprayChemical>()
        for (chem in chemicals) {
            val key = chem.name.trim().lowercase(Locale.getDefault())
            if (key.isEmpty()) continue
            if (!seen.containsKey(key)) seen[key] = chem
        }
        return seen.values.sortedBy { it.name.lowercase(Locale.getDefault()) }
    }

    /** RFC-4180 escaping: wrap in quotes when the value contains comma/quote/newline. */
    private fun escape(value: String): String {
        if (value.isEmpty()) return ""
        val needsQuotes = value.contains(',') || value.contains('"') ||
            value.contains('\n') || value.contains('\r')
        if (!needsQuotes) return value
        return "\"" + value.replace("\"", "\"\"") + "\""
    }

    private fun fileName(vineyardName: String): String {
        val safe = vineyardName.ifBlank { "Vineyard" }
            .replace(" ", "_")
            .replace("/", "-")
            .replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
            .ifBlank { "Vineyard" }
        return "SprayProgram_Export_$safe.csv"
    }
}
