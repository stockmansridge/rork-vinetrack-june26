import Foundation

/// Retains the whole document, including unsupported versions and unknown fields.
nonisolated enum TripOccurrenceCoverage {
    typealias JSON = SprayReportPayloadV1.JSONValue
    enum Basis: Sendable { case legacy, occurrence, updateRequired }
    struct Item: Codable, Sendable, Hashable {
        let occurrenceId: String
        let blockId: String
        let blockNameSnapshot: String
        let physicalPathRef: PhysicalReference
        let pathNumber: Double
        let passOrdinal: Int
    }
    struct PhysicalReference: Codable, Sendable, Hashable {
        let pathId: String
        let rowIds: [String]
        let geometryRevision: String
    }
    struct State: Codable, Sendable, Hashable {
        let status: String
        let lastOperationId: String?
        let source: String?
        let tankSessionIds: [String]
    }
    struct Document: Codable, Sendable, Hashable {
        let contract: String
        let schemaVersion: Int
        let planId: String
        let revision: Int
        let planRevision: Int
        let items: [Item]
        let activeOrder: [String]
        let retired: [String]
        let states: [String: State]
        let plannedCursorId: String?
        let selectedOccurrenceId: String?
        var targetId: String? { selectedOccurrenceId ?? plannedCursorId }
        func count(_ status: String) -> Int { activeOrder.filter { states[$0]?.status == status }.count }
    }
    static func basis(_ raw: JSON?) -> Basis {
        guard let raw, raw != .null else { return .legacy }
        return read(raw) == nil ? .updateRequired : .occurrence
    }
    static func read(_ raw: JSON?) -> Document? {
        guard let raw, let data = try? JSONEncoder().encode(raw),
              let d = try? JSONDecoder().decode(Document.self, from: data),
              d.contract == "vinetrack.planned-occurrence", d.schemaVersion == 1,
              canonicalUUID(d.planId), d.revision >= 0, d.planRevision >= 1,
              !d.items.isEmpty, d.items.count <= 5000,
              Set(d.items.map(\.occurrenceId)).count == d.items.count,
              d.activeOrder.count + d.retired.count == d.items.count,
              Set(d.activeOrder + d.retired) == Set(d.items.map(\.occurrenceId)),
              Set(d.states.keys) == Set(d.items.map(\.occurrenceId)),
              d.selectedOccurrenceId.map({ d.activeOrder.contains($0) }) ?? true,
              d.plannedCursorId.map({ d.activeOrder.contains($0) }) ?? true else { return nil }
        for item in d.items {
            guard canonicalUUID(item.occurrenceId), canonicalUUID(item.blockId),
                  canonicalUUID(item.physicalPathRef.pathId), item.pathNumber.isFinite, item.passOrdinal > 0,
                  Set(item.physicalPathRef.rowIds).count == item.physicalPathRef.rowIds.count,
                  item.physicalPathRef.rowIds.allSatisfy(canonicalUUID) else { return nil }
        }
        for state in d.states.values {
            guard ["incomplete", "done", "skipped"].contains(state.status),
                  state.lastOperationId.map(canonicalUUID) ?? true,
                  state.source.map({ ["manual", "automatic", "endReview", "correction"].contains($0) }) ?? true,
                  state.tankSessionIds.allSatisfy(canonicalUUID) else { return nil }
        }
        return d
    }
    static func requireDocument(_ raw: JSON) throws -> Document {
        guard let d = read(raw) else { throw Failure.updateRequired }
        return d
    }
    static func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    enum Failure: Error, LocalizedError {
        case updateRequired, scopeConflict, reconciliation, storage, missing, invalidAction
        var errorDescription: String? {
            switch self {
            case .updateRequired: return "Update required. Occurrence coverage cannot use numeric path history."
            case .scopeConflict: return "Saved occurrence work belongs to a different account, vineyard or trip."
            case .reconciliation: return "Occurrence sync needs review. Saved actions have been retained."
            case .storage: return "The occurrence action could not be saved. Retry before leaving this trip."
            case .missing: return "Saved occurrence evidence is unavailable. Do not replace this trip."
            case .invalidAction: return "This occurrence action is unavailable. Select the exact planned pass."
            }
        }
    }
}

extension SprayReportPayloadV1.JSONValue {
    nonisolated var occurrenceObject: [String: Self]? { if case .object(let v) = self { return v }; return nil }
    nonisolated var occurrenceString: String? { if case .string(let v) = self { return v }; return nil }
    nonisolated subscript(occurrence key: String) -> Self? { occurrenceObject?[key] }
}
