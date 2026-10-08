import SwiftUI

struct FertigationApplicationView: View {
    let application: FertigationDomain.Application
    let formatter: RegionFormatter
    var showSession: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FertigationDomain.string(application.raw, "program_step_name") ?? "Program Step").font(.headline)
            Text("Growth Stage: \(FertigationDomain.string(application.raw, "growth_stage_code") ?? "—")")
            Text(FertigationDomain.string(application.raw, "status") == "reversed" ? "Reversed" : (FertigationDomain.string(application.raw, "status") ?? "Unknown").capitalized)
                .foregroundStyle(application.isEditable ? Color.green : Color.secondary)
            if showSession {
                Text(formatter.formatDate(FertigationDomain.string(application.raw, "session_date") ?? ""))
                Text("\(FertigationDomain.string(application.raw, "system_name") ?? "—") · \(FertigationDomain.string(application.raw, "valve_name") ?? "—")")
                if case .array(let blocks) = application.raw["block_names"] {
                    Text(blocks.compactMap { if case .string(let name) = $0 { return name }; return nil }.joined(separator: ", "))
                }
                if let minutes = FertigationDomain.number(application.raw, "duration_minutes") { Text(IrrigationFormat.duration(minutes: Int(minutes))) }
                if let litres = FertigationDomain.number(application.raw, "total_volume_litres") { Text("Total irrigation water: \(formatter.formatVolume(litres: litres))") }
            }
            ForEach(Array(application.products.enumerated()), id: \.offset) { _, product in
                VStack(alignment: .leading, spacing: 3) {
                    Text(FertigationDomain.string(product, "product_name") ?? "Product").font(.subheadline.weight(.semibold))
                    Text("Planned rate: \(FertigationHistory.rate(product))")
                    Text("Planned quantity: \(FertigationHistory.quantity(product, key: "planned_quantity"))")
                    Text(FertigationHistory.quantity(product, key: "actual_quantity") == "Actual not entered" ? "Actual not entered" : "Actual: \(FertigationHistory.quantity(product, key: "actual_quantity"))")
                    Text(FertigationDomain.frozenCost(product: product).map { "Cost: \(formatter.formatCurrency($0))" } ?? "Cost unavailable")
                }
            }
            if let notes = FertigationDomain.string(application.raw, "notes"), !notes.isEmpty { Text(notes) }
        }.font(.footnote)
    }
}
