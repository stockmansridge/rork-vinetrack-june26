import Foundation

/// Planning selection only. No Trip state, coverage or row-completion authority is created here.
enum SprayWorkAreaSelection {
    typealias JSON = TripOccurrenceCoverage.JSON
    struct Choice: Identifiable, Equatable {
        let id: String
        let title: String
        let blockId: String
        let ordinal: Int
        let physicalEvidence: JSON
        let hasGeometry: Bool
    }
    struct Selected: Identifiable, Codable, Equatable {
        let id: String
        let choiceId: String
        let title: String
        let blockId: String
        let ordinal: Int
        let configuration: SprayPassConfiguration
        let physicalEvidence: JSON
        var travelPassCount: Int { 1 }
        var controllerRowEquivalents: Double { configuration.rowEquivalents }
    }
    static func choices(_ candidates: [TripOccurrencePlanner.Candidate]) -> [Choice] {
        var counts: [String: Int] = [:]
        return candidates.map { c in
            let ordinal = (counts[c.id] ?? 0) + 1; counts[c.id] = ordinal
            let resolved = !c.rows.isEmpty && c.rows.allSatisfy { row in
                row.hasStoredIdentity && [row.startPoint, row.endPoint].allSatisfy {
                    $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
                }
            }
            let evidence: JSON = .object(["blockId": .string(c.blockId.uuidString.lowercased()), "pathNumber": .number(c.label),
                "geometryStatus": .string(resolved ? "frozen_native_rows" : "unresolved"),
                "rows": .array(c.rows.map { row in .object([
                    "id": .string(row.id.uuidString.lowercased()), "storedIdentity": .bool(row.hasStoredIdentity),
                    "number": .number(row.calculationRowNumber),
                    "startLatitude": .number(row.startPoint.latitude), "startLongitude": .number(row.startPoint.longitude),
                    "endLatitude": .number(row.endPoint.latitude), "endLongitude": .number(row.endPoint.longitude)]) })])
            return Choice(id: c.id + "|pass:\(ordinal)", title: c.display + " · Pass \(ordinal)", blockId: c.blockId.uuidString.lowercased(), ordinal: ordinal, physicalEvidence: evidence, hasGeometry: resolved)
        }
    }
    static func select(_ c: Choice, configuration: SprayPassConfiguration) -> Selected {
        Selected(id: UUID().uuidString.lowercased(), choiceId: c.id, title: c.title, blockId: c.blockId,
                 ordinal: c.ordinal, configuration: configuration, physicalEvidence: c.physicalEvidence)
    }
    static func retained(_ s: Selected, choices: [Choice], configuration: SprayPassConfiguration?) -> Bool {
        configuration == s.configuration && choices.contains { $0.id == s.choiceId && $0.physicalEvidence == s.physicalEvidence }
    }
    static let routeAdmissionMessage = "Route binding unavailable: authoritative whole-pass treatment area and R2 reconciliation are not yet verified. No hectare tolerance or automatic pass allocation has been applied."
}
