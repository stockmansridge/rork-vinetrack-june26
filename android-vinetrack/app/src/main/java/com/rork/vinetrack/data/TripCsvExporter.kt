package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SavedInput
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Single-trip CSV export, mirroring the iOS `TripCSVService`. Costing columns
 * are gated on [includeCostings]: the caller MUST pass `false` for
 * non-owner/manager roles so supervisors and operators never receive cost data
 * in an exported file (the columns are omitted entirely rather than blanked).
 * Cost values are computed via the pure [TripCostEstimator] for the linked
 * spray record. The CSV is written to the app cache (`cache/exports`) and shared
 * via [FileProvider]; it is never uploaded to Supabase.
 */
object TripCsvExporter {

    private val coreHeaders = listOf(
        "vineyard", "block", "trip_type", "operator", "date",
        "start_time", "end_time", "duration_minutes", "distance_metres",
        "rows_planned", "rows_completed",
    )

    private val costHeaders = listOf(
        "active_hours", "labour_cost", "fuel_litres_estimated", "fuel_cost_per_litre",
        "fuel_cost", "chemical_cost", "total_estimated_cost", "costing_status",
        "treated_area_ha", "cost_per_ha", "yield_tonnes", "cost_per_tonne",
    )

    fun exportAndShare(
        context: Context,
        trip: Trip,
        vineyardName: String,
        blockLabel: String,
        operatorName: String?,
        includeCostings: Boolean,
        linkedSpray: SprayRecord?,
        operatorCategories: List<OperatorCategory>,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        paddocks: List<Paddock>,
        yieldRecords: List<HistoricalYieldRecord> = emptyList(),
        savedInputs: List<SavedInput> = emptyList(),
    ): Boolean {
        return try {
            val csv = buildCsv(
                trip, vineyardName, blockLabel, operatorName, includeCostings,
                linkedSpray, operatorCategories, machines, fuelPurchases,
                paddocks, yieldRecords, savedInputs,
            )

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, fileName(trip, vineyardName))
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
                Intent.createChooser(share, "Export trip").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("TripCsvExporter", "CSV export failed", e)
            false
        }
    }

    private fun buildCsv(
        trip: Trip,
        vineyardName: String,
        blockLabel: String,
        operatorName: String?,
        includeCostings: Boolean,
        linkedSpray: SprayRecord?,
        operatorCategories: List<OperatorCategory>,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        paddocks: List<Paddock>,
        yieldRecords: List<HistoricalYieldRecord>,
        savedInputs: List<SavedInput>,
    ): String {
        val dateFmt = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val timeFmt = SimpleDateFormat("HH:mm", Locale.getDefault())

        val headers = if (includeCostings) coreHeaders + costHeaders else coreHeaders
        val row = ArrayList<String>(headers.size)
        row.add(vineyardName)
        row.add(blockLabel)
        row.add(trip.displayLabel.takeIf { it != "Trip" } ?: "")
        row.add(operatorName ?: trip.personName ?: "")
        row.add(trip.startEpochMs?.let { dateFmt.format(Date(it)) } ?: "")
        row.add(trip.startEpochMs?.let { timeFmt.format(Date(it)) } ?: "")
        row.add(trip.endEpochMs?.let { timeFmt.format(Date(it)) } ?: "")
        row.add(((trip.activeDurationSeconds ?: 0L) / 60L).toString())
        row.add(trip.totalDistance?.let { String.format(Locale.US, "%.0f", it) } ?: "")
        row.add("${trip.rowSequence.size}")
        row.add("${trip.completedRowCount}")

        if (includeCostings) {
            val est = TripCostEstimator.estimate(
                trip, linkedSpray, operatorCategories, machines,
                fuelPurchases, paddocks, yieldRecords, savedInputs,
            )
            row.add(String.format(Locale.US, "%.2f", est.activeHours))
            row.add(if (est.labour.warning == null) String.format(Locale.US, "%.2f", est.labour.cost) else "")
            row.add(if (est.fuel.warning == null) String.format(Locale.US, "%.2f", est.fuel.litres ?: 0.0) else "")
            row.add(est.fuel.costPerLitre?.let { String.format(Locale.US, "%.4f", it) } ?: "")
            row.add(if (est.fuel.warning == null) String.format(Locale.US, "%.2f", est.fuel.fuelCost ?: 0.0) else "")
            row.add(
                est.chemical?.let { c ->
                    if (c.warning != null && c.cost <= 0.0) "" else String.format(Locale.US, "%.2f", c.cost)
                } ?: ""
            )
            row.add(String.format(Locale.US, "%.2f", est.totalCost))
            row.add(est.completeness.name.lowercase(Locale.US))
            row.add(est.treatedAreaHa?.let { String.format(Locale.US, "%.2f", it) } ?: "")
            row.add(est.costPerHa?.let { String.format(Locale.US, "%.2f", it) } ?: "")
            row.add(est.yieldTonnes?.let { String.format(Locale.US, "%.2f", it) } ?: "")
            row.add(est.costPerTonne?.let { String.format(Locale.US, "%.2f", it) } ?: "")
        }

        return headers.joinToString(",") { escape(it) } + "\n" +
            row.joinToString(",") { escape(it) } + "\n"
    }

    private fun escape(value: String): String {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return ""
        val needsQuotes = trimmed.contains(',') || trimmed.contains('"') ||
            trimmed.contains('\n') || trimmed.contains('\r')
        if (!needsQuotes) return trimmed
        return "\"" + trimmed.replace("\"", "\"\"") + "\""
    }

    private fun fileName(trip: Trip, vineyardName: String): String {
        val date = trip.startEpochMs?.let {
            SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(it))
        } ?: SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        val safe = "${vineyardName.ifBlank { "Vineyard" }}_$date"
            .replace(" ", "_")
            .replace("/", "-")
            .replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
        return "TripReport_$safe.csv"
    }
}
