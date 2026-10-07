import Foundation

/// SQL 266 Fertigation values. These are linked irrigation applications, never spray records.
nonisolated enum FertigationDomain {
    typealias JSON = SprayReportPayloadV1.JSONValue
    typealias Object = [String: JSON]

    enum Failure: LocalizedError {
        case systemAdminRequired, invalidStep, reversed, invalidActual
        var errorDescription: String? {
            switch self {
            case .systemAdminRequired: "System Admin required."
            case .invalidStep: "Select an active Fertigation Program Step in this vineyard."
            case .reversed: "Reversed Fertigation cannot be edited."
            case .invalidActual: "Actual used must be blank or a finite, non-negative quantity."
            }
        }
    }

    enum Basis: String, CaseIterable, Codable, Sendable {
        case perHectare = "per_hectare"
        case perVine = "per_vine"
        case perCycle = "per_irrigation_cycle"
        var label: String {
            switch self {
            case .perHectare: "Per hectare"
            case .perVine: "Per vine"
            case .perCycle: "Per irrigation cycle"
            }
        }
        var units: [String] {
            switch self {
            case .perHectare: ["kg/ha", "L/ha"]
            case .perVine: ["g/vine", "mL/vine"]
            case .perCycle: ["kg", "L"]
            }
        }
    }

    struct Allocation: Sendable {
        let areaM2: Double?
        let vines: Double?
    }

    struct Totals: Codable, Sendable {
        let areaHa: Double?
        let vines: Double?
        init(allocations: [Allocation]) {
            func total(_ values: [Double?]) -> Double? {
                guard !values.isEmpty, values.allSatisfy({ $0.map { $0.isFinite && $0 > 0 } == true }) else { return nil }
                let sum = values.compactMap { $0 }.reduce(0, +)
                return sum.isFinite ? sum : nil
            }
            areaHa = total(allocations.map(\.areaM2)).map { $0 / 10_000 }
            vines = total(allocations.map(\.vines))
        }
    }

    struct ProgramStep: Codable, Sendable, Identifiable {
        var raw: Object
        var id: UUID? { uuid(raw, "id") }
        var name: String? { string(raw, "name") }
        var growthStageCode: String? { string(raw, "growth_stage_code") }
        var lines: [Object] {
            guard case .array(let values) = raw["chemical_lines"] else { return [] }
            return values.compactMap { if case .object(let value) = $0 { return value }; return nil }
        }
        func isSelectable(vineyardId: UUID, isSystemAdmin: Bool) -> Bool {
            isSystemAdmin && id != nil && uuid(raw, "vineyard_id") == vineyardId
                && raw["is_template"] == .bool(true)
                && (raw["deleted_at"] == nil || raw["deleted_at"] == .null)
                && string(raw, "operation_type")?.lowercased() == "fertigation"
        }
        init(raw: Object) { self.raw = raw }
        init(from decoder: Decoder) throws { raw = try Object(from: decoder) }
        func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
    }

    /// Frozen SQL application. Historical presentation must use this payload, not its provenance step.
    struct Application: Codable, Sendable, Identifiable {
        var raw: Object
        var id: UUID? { uuid(raw, "id") }
        var sessionId: UUID? { uuid(raw, "irrigation_session_id") }
        var isEditable: Bool { string(raw, "status") == "active" }
        var products: [Object] {
            guard case .array(let values) = raw["products"] else { return [] }
            return values.compactMap { if case .object(let value) = $0 { return value }; return nil }
        }
        init(raw: Object) { self.raw = raw }
        init(from decoder: Decoder) throws { raw = try Object(from: decoder) }
        func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
    }

    struct DraftProduct: Codable, Sendable, Identifiable {
        let id: UUID
        var line: Object
        var actual: String
        init(id: UUID = UUID(), line: Object, actual: String = "") {
            self.id = id; self.line = line; self.actual = actual
        }
        func payload(totals: Totals, step: ProgramStep) throws -> Object {
            let text = actual.trimmingCharacters(in: .whitespacesAndNewlines)
            let entered = text.isEmpty ? nil : Double(text)
            guard text.isEmpty || entered.map({ $0.isFinite && $0 >= 0 }) == true else { throw Failure.invalidActual }
            let planned = plannedQuantity(line: line, totals: totals)
            return [
                "id": .string(id.uuidString),
                "saved_chemical_id": line["savedChemicalId"] ?? line["chemical_id"] ?? .null,
                "product_name": line["name"] ?? .string(""),
                "product_category": line["product_category"] ?? .null,
                "product_form": line["product_form"] ?? .null,
                "planned_rate": line["rate"] ?? .null,
                "rate_basis": line["fertigation_rate_basis"] ?? .null,
                "rate_unit": line["fertigation_rate_unit"] ?? .null,
                "planned_quantity": planned.quantity.map(JSON.number) ?? .null,
                "actual_quantity": entered.map(JSON.number) ?? .null,
                "quantity_unit": planned.unit.map(JSON.string) ?? .null,
                "cost_per_unit": number(line, "costPerUnit").flatMap { $0.isFinite && $0 > 0 ? JSON.number($0) : nil } ?? .null,
                "product_snapshot": .object([
                    "program_step_id": step.raw["id"] ?? .null,
                    "program_step_name": step.raw["name"] ?? .null,
                    "growth_stage_code": step.raw["growth_stage_code"] ?? .null,
                    "saved_chemical_id": line["savedChemicalId"] ?? line["chemical_id"] ?? .null,
                    "product_name": line["name"] ?? .null,
                    "rate": line["rate"] ?? .null,
                    "rate_basis": line["fertigation_rate_basis"] ?? .null,
                    "rate_unit": line["fertigation_rate_unit"] ?? .null,
                    "serviced_area_ha": totals.areaHa.map(JSON.number) ?? .null,
                    "serviced_vines": totals.vines.map(JSON.number) ?? .null
                ])
            ]
        }
    }

    static func string(_ object: Object, _ key: String) -> String? {
        if case .string(let value) = object[key] { return value }; return nil
    }
    static func uuid(_ object: Object, _ key: String) -> UUID? { string(object, key).flatMap(UUID.init(uuidString:)) }
    static func number(_ object: Object, _ key: String) -> Double? {
        if case .number(let value) = object[key] { return value }
        return string(object, key).flatMap(Double.init)
    }
    static func rateText(line: Object) -> String {
        guard let rate = number(line, "rate"), rate.isFinite, rate > 0,
              let unit = string(line, "fertigation_rate_unit"), !unit.isEmpty else { return "Rate not set" }
        let amount = rate.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never))
        return "\(amount) \(unit)" + (string(line, "fertigation_rate_basis") == Basis.perCycle.rawValue ? " per irrigation cycle" : "")
    }
    static func plannedQuantity(line: Object, totals: Totals) -> (quantity: Double?, unit: String?) {
        let unit = string(line, "fertigation_rate_unit")
        let quantityUnit: String? = ["kg/ha", "g/vine", "kg"].contains(unit ?? "") ? "kg"
            : (["L/ha", "mL/vine", "L"].contains(unit ?? "") ? "L" : nil)
        guard let rate = number(line, "rate"), rate.isFinite, rate > 0,
              let basis = string(line, "fertigation_rate_basis").flatMap(Basis.init(rawValue:)),
              let unit, basis.units.contains(unit) else { return (nil, quantityUnit) }
        let result: Double?
        switch basis {
        case .perHectare: result = totals.areaHa.map { rate * $0 }
        case .perVine: result = totals.vines.map { rate * $0 / 1000 }
        case .perCycle: result = rate
        }
        guard let result, result.isFinite, (result * 1000).isFinite else { return (nil, quantityUnit) }
        return ((result * 1000).rounded() / 1000, quantityUnit)
    }
    static func frozenCost(product: Object) -> Double? {
        guard let cost = number(product, "cost_per_unit"), cost.isFinite, cost > 0,
              let actual = number(product, "actual_quantity"), actual.isFinite, actual > 0 else { return nil }
        let total = cost * actual
        return total.isFinite && total > 0 ? total : nil
    }
}
