import SwiftUI

/// Read-only facts from the exact linked revision, not a newer approved revision.
struct CatalogueRevisionDetailsView: View {
    let revision: CatalogueWire
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let category = ProductCategory(rawValue: revision.text("product_category_key") ?? revision.text("product_category") ?? "") {
                Text(category.label).font(.caption)
            }
            if !revision.activeIngredientLines.isEmpty {
                Text("Active ingredients").font(.subheadline.bold())
                ForEach(revision.activeIngredientLines, id: \.self) { Text($0).font(.caption) }
            }
            if let warning = revision.resistanceWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Text("Registered grapevine rates").font(.subheadline.bold())
            rates(key: "per_hectare", title: "Per hectare")
            rates(key: "per_100_litres", title: "Per 100 L")
            if revision.rateRows("per_hectare").isEmpty && revision.rateRows("per_100_litres").isEmpty {
                Text("No registered grapevine rate available. Check the manufacturer label.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Choose the exact dose when planning the spray. Follow the applicable label conditions.").font(.caption).foregroundStyle(.secondary)
            ForEach(revision.rows("vineyard_uses"), id: \.self) { direction in
                let supported = ["withholding_statement", "re_entry_statement", "restrictions"].contains { !(direction.text($0) ?? "").isEmpty }
                if supported {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(direction.strings("targets").joined(separator: " · ")).font(.caption.bold())
                        statement(direction, key: "withholding_statement", title: "Withholding")
                        statement(direction, key: "re_entry_statement", title: "Re-entry")
                        statement(direction, key: "restrictions", title: "Restrictions")
                    }
                }
            }
            Text("Label & references").font(.subheadline.bold())
            reference("Manufacturer label", key: "manufacturer_label_url")
            reference("Manufacturer product page", key: "manufacturer_product_url")
            Text("A product page is not an official label.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func rates(key: String, title: String) -> some View {
        let lines = revision.registeredRateLines(key)
        if !lines.isEmpty {
            Text(title).font(.caption.bold())
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
        }
    }
    @ViewBuilder private func statement(_ direction: CatalogueWire, key: String, title: String) -> some View {
        if let text = direction.text(key), !text.isEmpty { Text("\(title): \(text)").font(.caption) }
    }
    @ViewBuilder private func reference(_ title: String, key: String) -> some View {
        if let raw = revision.text(key), let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" {
            Link(title, destination: url).font(.subheadline)
        }
    }
}
