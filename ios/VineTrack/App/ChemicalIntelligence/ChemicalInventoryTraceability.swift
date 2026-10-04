import Foundation

/// Audit metadata only; independent of quantities, registered rates and purchase costing.
nonisolated enum ChemicalInventoryTraceability {
    static func nullableText(_ value: String) -> SprayReportPayloadV1.JSONValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .null : .string(trimmed)
    }
    static func fields(batch: String, batchDate: String?, serial: String) -> [String: SprayReportPayloadV1.JSONValue] {
        ["p_batch_number": nullableText(batch), "p_batch_date": batchDate.map { .string($0) } ?? .null,
         "p_serial_number": nullableText(serial)]
    }
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func display(_ row: CatalogueWire, latest: Bool = false) -> [String] {
        let prefix = latest ? "latest_" : ""
        return [("batch_number", "Batch / Lot number"), ("batch_date", "Production / Batch date"), ("serial_number", "Serial number (if applicable)")].compactMap { key, label in
            guard let value = row.text(prefix + key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "\(label): \(value)"
        }
    }
}
