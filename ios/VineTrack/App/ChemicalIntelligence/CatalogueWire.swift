import Foundation

/// Backend-owned Chemical Search payload, retained without field reconstruction.
nonisolated struct CatalogueWire: Codable, Sendable, Identifiable, Hashable {
    let fields: [String: SprayReportPayloadV1.JSONValue]
    init(fields: [String: SprayReportPayloadV1.JSONValue]) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try decoder.singleValueContainer().decode([String: SprayReportPayloadV1.JSONValue].self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(fields) }
    var id: String { text("revision_id") ?? text("id") ?? text("saved_chemical_id") ?? text("purchase_id") ?? "" }
    func text(_ key: String) -> String? { if case let .string(v) = fields[key] { return v }; return nil }
    func number(_ key: String) -> Double? { if case let .number(v) = fields[key] { return v }; return nil }
    func bool(_ key: String) -> Bool { fields[key] == .bool(true) }
    func strings(_ key: String) -> [String] { if case let .array(v) = fields[key] { return v.compactMap { if case let .string(s) = $0 { return s }; return nil } }; return [] }
    func rows(_ key: String) -> [CatalogueWire] { if case let .array(v) = fields[key] { return v.compactMap { if case let .object(o) = $0 { return CatalogueWire(fields: o) }; return nil } }; return [] }
    var targets: [String] {
        var seen = Set<String>()
        return rows("vineyard_uses").flatMap { $0.strings("targets") }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    static func manualTargets(problem: String, use: String) -> String {
        if !problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return problem }
        let categories = ["fungicide", "herbicide", "insecticide", "adjuvant", "fertiliser", "fertilizer", "biostimulant"]
        return categories.contains(use.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ? "" : use
    }
    var badge: String { text("review_status") == "approved" ? "VineTrack catalogue" : "Pending VineTrack review" }
    var isSuccess: Bool { ["completed", "pending_review", "needs_attention"].contains(text("status") ?? "") }
    var isTerminal: Bool { isSuccess || ["failed", "cancelled"].contains(text("status") ?? "") }
    var groupText: String { [text("activity_group_scheme")?.uppercased() ?? "", strings("activity_groups").joined(separator: " + ")].filter { !$0.isEmpty }.joined(separator: " ") }
    var inventoryStatus: String {
        if text("tracking_status") == "needs_opening_stock" { return "Opening stock not set" }
        if bool("out_of_stock") { return "Out of stock" }
        if bool("low_stock") { return "Low stock" }
        return "In stock"
    }
    static func compactManufacturer(_ name: String) -> String {
        name.replacingOccurrences(of: #"(?i)\s+(?:Australia\s+)?(?:Pty\s+)?(?:Ltd|Limited)\.?$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+Australia$"#, with: "", options: .regularExpression)
    }
    func rateRows(_ key: String) -> [CatalogueWire] {
        guard case let .object(options) = fields["default_rate_options"] else { return [] }
        return CatalogueWire(fields: options).rows(key)
    }
    var rateText: String {
        let amount = number("value").map { String($0) } ?? [number("min_value"), number("max_value")].compactMap { $0.map { String($0) } }.joined(separator: "–")
        return [amount, text("unit") ?? "", strings("targets").joined(separator: ", "), text("condition") ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
