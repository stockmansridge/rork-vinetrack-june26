import Foundation

/// Single-trip CSV export. Costing columns are gated on `includeCostings`:
/// the caller MUST pass `false` for non-owner/manager roles so supervisors
/// and operators never receive cost data in an exported file.
struct TripCSVService {

    static func exportTrip(
        trip: Trip,
        vineyardName: String,
        paddockName: String,
        tripFunctionLabel: String?,
        tripCostResult: TripCostService.Result?,
        includeCostings: Bool,
        timeZone: TimeZone = .current
    ) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = timeZone
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        tf.timeZone = timeZone

        var headers: [String] = [
            "vineyard",
            "block",
            "trip_type",
            "operator",
            "date",
            "start_time",
            "end_time",
            "duration_minutes",
            "distance_metres",
            "rows_planned",
            "rows_completed",
        ]

        var row: [String] = [
            esc(vineyardName),
            esc(paddockName),
            esc(tripFunctionLabel ?? ""),
            esc(trip.personName),
            df.string(from: trip.startTime),
            tf.string(from: trip.startTime),
            trip.endTime.map { tf.string(from: $0) } ?? "",
            String(Int(trip.activeDuration / 60.0)),
            String(format: "%.0f", trip.totalDistance),
            "\(trip.rowSequence.count)",
            "\(trip.completedPaths.count)",
        ]

        if includeCostings, let r = tripCostResult {
            headers.append(contentsOf: [
                "active_hours",
                "labour_cost",
                "fuel_litres_estimated",
                "fuel_cost_per_litre",
                "fuel_cost",
                "chemical_cost",
                "total_estimated_cost",
                "costing_status",
                "treated_area_ha",
                "cost_per_ha",
                "yield_tonnes",
                "cost_per_tonne",
            ])
            row.append(contentsOf: [
                String(format: "%.2f", r.activeHours),
                r.labour.warning == nil ? String(format: "%.2f", r.labour.cost) : "",
                r.fuel.warning == nil ? String(format: "%.2f", r.fuel.litres) : "",
                (r.fuel.costPerLitre.map { String(format: "%.4f", $0) }) ?? "",
                r.fuel.warning == nil ? String(format: "%.2f", r.fuel.cost) : "",
                (r.chemical.map { c -> String in
                    if let w = c.warning, c.cost <= 0, !w.isEmpty { return "" }
                    return String(format: "%.2f", c.cost)
                }) ?? "",
                String(format: "%.2f", r.totalCost),
                r.completeness.rawValue,
                (r.treatedAreaHa.map { String(format: "%.2f", $0) }) ?? "",
                (r.costPerHa.map { String(format: "%.2f", $0) }) ?? "",
                (r.yieldTonnes.map { String(format: "%.2f", $0) }) ?? "",
                (r.costPerTonne.map { String(format: "%.2f", $0) }) ?? "",
            ])
        }

        let csv = headers.joined(separator: ",") + "\n" + row.joined(separator: ",") + "\n"
        let tempDir = FileManager.default.temporaryDirectory
        let safeVy = vineyardName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        let datePart = df.string(from: trip.startTime)
        let url = tempDir.appendingPathComponent("TripReport_\(safeVy)_\(datePart).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func esc(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(",") || trimmed.contains("\"") || trimmed.contains("\n") {
            return "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return trimmed
    }
}
