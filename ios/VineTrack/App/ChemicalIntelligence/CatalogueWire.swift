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
    var groupText: String {
        guard !["not_applicable", "unresolved"].contains(text("resistance_classification_state")?.lowercased() ?? "") else { return "" }
        return Self.resistanceText(scheme: text("activity_group_scheme"), codes: strings("activity_groups"))
    }
    var resistanceWarning: String? {
        text("resistance_classification_state")?.lowercased() == "unresolved" ? "Resistance group unknown" : nil
    }
    static func resistanceText(scheme: String?, codes: [String]) -> String {
        let scheme = (scheme ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["FRAC", "HRAC", "IRAC"].contains(scheme) else { return "" }
        let codes = codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && !["NOT_APPLICABLE", "UNRESOLVED", "CLASSIFIED"].contains($0.uppercased())
        }
        return codes.isEmpty ? "" : scheme + " " + codes.joined(separator: " + ")
    }
    var inventoryStatus: String {
        if text("tracking_status") == "needs_opening_stock" { return "Opening stock not set" }
        if text("tracking_status") == "finished" { return "Finished" }
        if text("tracking_status") == "out_of_stock" || bool("out_of_stock") { return "Out of stock" }
        if text("tracking_status") == "low_stock" || bool("low_stock") { return "Low stock" }
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
    /// Presentation only: retain each backend option and its complete range/basis.
    func registeredRateLines(_ key: String) -> [String] {
        rateRows(key).map { rate in
            let amount = rate.number("value").map(Self.displayNumber) ?? [rate.number("min_value"), rate.number("max_value")].compactMap { $0.map(Self.displayNumber) }.joined(separator: "–")
            let unit = rate.text("unit") ?? ""
            let basis = unit.contains("/") ? "" : (key == "per_hectare" ? "/ha" : "/100 L")
            let dose = amount.isEmpty ? (rate.text("raw_text") ?? "") : "\(amount) \(unit)\(basis)"
            return [dose, rate.strings("targets").joined(separator: ", "), rate.text("condition") ?? "", rate.strings("methods").joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: " · ")
        }.filter { !$0.isEmpty }
    }
    static func displayNumber(_ number: Double) -> String {
        let text = String(number)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    var activeIngredientLines: [String] {
        rows("active_ingredients").compactMap { active in
            guard let name = active.text("name"), !name.isEmpty else { return nil }
            return [name, active.number("concentration").map(Self.displayNumber) ?? "", active.text("concentration_unit") ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
    var rateText: String {
        let amount = number("value").map { String($0) } ?? [number("min_value"), number("max_value")].compactMap { $0.map { String($0) } }.joined(separator: "–")
        return [amount, text("unit") ?? "", strings("targets").joined(separator: ", "), text("condition") ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
