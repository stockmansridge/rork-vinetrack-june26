import Foundation

/// Bulk history indexing leaves irrigation row identity/count untouched, including reversed applications.
nonisolated enum FertigationHistory {
    static func index(_ applications: [FertigationDomain.Application], isSystemAdmin: Bool) -> [UUID: FertigationDomain.Application] {
        guard isSystemAdmin else { return [:] }
        var result: [UUID: FertigationDomain.Application] = [:]
        for application in applications {
            guard let session = application.sessionId else { continue }
            if result[session] == nil || application.isEditable { result[session] = application }
        }
        return result
    }
    /// Irrigation is the sole reversal authority. Only reload after its acknowledgement.
    @MainActor static func afterIrrigationReversal(reverse: () async throws -> Void, reload: () async throws -> Void) async throws {
        try await reverse()
        try await reload()
    }
    static func quantity(_ product: FertigationDomain.Object, key: String) -> String {
        guard let value = FertigationDomain.number(product, key), value.isFinite else { return key == "actual_quantity" ? "Actual not entered" : "Unavailable" }
        return "\(value.formatted(.number.grouping(.never))) \(FertigationDomain.string(product, "quantity_unit") ?? "")"
    }
    static func rate(_ product: FertigationDomain.Object) -> String {
        guard let rate = FertigationDomain.number(product, "planned_rate") else { return "Rate not set" }
        return "\(rate.formatted()) \(FertigationDomain.string(product, "rate_unit") ?? "")"
    }
}
