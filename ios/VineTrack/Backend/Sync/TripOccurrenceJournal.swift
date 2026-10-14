import Foundation

/// A single atomic file owns acknowledged coverage, ordered intents and reversible operation evidence.
/// Local publication happens only after replacement succeeds; no numeric replay is involved.
@MainActor final class TripOccurrenceJournal {
    typealias JSON = TripOccurrenceCoverage.JSON
    typealias Failure = TripOccurrenceCoverage.Failure
    nonisolated struct Scope: Codable, Sendable, Equatable {
        let ownerId: String
        let vineyardId: String
        let tripId: String
    }
    nonisolated struct Operation: Codable, Sendable, Equatable {
        let id: String
        let action: JSON
        let before: JSON
        let after: JSON
        let params: JSON
    }
    nonisolated struct Snapshot: Codable, Sendable, Equatable {
        let scope: Scope
        var acknowledged: JSON
        var pending: [Operation] = []
        var history: [Operation] = []
        var heldReason: String? = nil
        var projected: JSON { pending.last?.after ?? acknowledged }
    }
    private let scope: Scope
    private let fileURL: URL

    init(scope: Scope, directory: URL? = nil) throws {
        guard [scope.ownerId, scope.vineyardId, scope.tripId].allSatisfy(TripOccurrenceCoverage.canonicalUUID) else { throw Failure.scopeConflict }
        self.scope = scope
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TripOccurrenceJournals", isDirectory: true)
        let scoped = root.appendingPathComponent(scope.ownerId, isDirectory: true)
            .appendingPathComponent(scope.vineyardId, isDirectory: true)
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        fileURL = scoped.appendingPathComponent(scope.tripId + ".json")
    }
    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let state = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard state.scope == scope else { throw Failure.scopeConflict }
        _ = try TripOccurrenceCoverage.requireDocument(state.acknowledged)
        for op in state.pending { _ = try TripOccurrenceCoverage.requireDocument(op.after) }
        return state
    }
    func initialize(_ coverage: JSON) throws {
        _ = try TripOccurrenceCoverage.requireDocument(coverage)
        guard try load() == nil else { throw Failure.reconciliation }
        try save(Snapshot(scope: scope, acknowledged: coverage))
    }
    func undoTarget() throws -> Operation? {
        guard let state = try load() else { throw Failure.missing }
        let d = try TripOccurrenceCoverage.requireDocument(state.projected)
        return state.history.reversed().first { op in
            guard let id = op.action[occurrence: "occurrenceId"]?.occurrenceString,
                  let kind = op.action[occurrence: "kind"]?.occurrenceString else { return false }
            return ["setStatus", "undo"].contains(kind) && d.activeOrder.contains(id) && d.states[id]?.lastOperationId == op.id
        }
    }
    @discardableResult func setStatus(_ id: String, status: String, tankSessionIds: [String] = [], source: String = "manual") throws -> Operation {
        guard ["incomplete", "done", "skipped"].contains(status), ["manual", "correction", "endReview"].contains(source) else { throw Failure.invalidAction }
        return try append { d, raw in
            guard let item = d.items.first(where: { $0.occurrenceId == id }),
                  let before = raw[occurrence: "states"]?[occurrence: id] else { throw Failure.invalidAction }
            return .object(["kind": .string("setStatus"), "planId": .string(d.planId), "occurrenceId": .string(id),
                            "blockId": .string(item.blockId), "expectedBeforeState": before,
                            "toStatus": .string(status), "source": .string(source),
                            "tankSessionIds": .array(tankSessionIds.map { .string($0) })])
        }
    }
    @discardableResult func select(_ id: String) throws -> Operation {
        try append { d, _ in
            guard let item = d.items.first(where: { $0.occurrenceId == id }) else { throw Failure.invalidAction }
            return .object(["kind": .string("selectOccurrence"), "planId": .string(d.planId),
                            "occurrenceId": .string(id), "blockId": .string(item.blockId)])
        }
    }
    @discardableResult func reorder(_ order: [String]) throws -> Operation {
        try append { d, raw in
            guard order.count == d.activeOrder.count, Set(order) == Set(d.activeOrder),
                  let items = raw[occurrence: "items"], let retired = raw[occurrence: "retired"] else { throw Failure.invalidAction }
            return .object(["kind": .string("editPlan"), "planId": .string(d.planId), "items": items,
                            "activeOrder": .array(order.map { .string($0) }), "retired": retired])
        }
    }
    @discardableResult func undo(_ operationId: String) throws -> Operation {
        guard let state = try load(), let previous = state.history.first(where: { $0.id == operationId }),
              let id = previous.action[occurrence: "occurrenceId"]?.occurrenceString else { throw Failure.missing }
        return try append { d, _ in
            guard d.states[id]?.lastOperationId == operationId,
                  let item = d.items.first(where: { $0.occurrenceId == id }) else { throw Failure.reconciliation }
            return .object(["kind": .string("undo"), "planId": .string(d.planId), "occurrenceId": .string(id),
                            "blockId": .string(item.blockId), "undoOfOperationId": .string(operationId)])
        }
    }
    private func append(_ build: (TripOccurrenceCoverage.Document, JSON) throws -> JSON) throws -> Operation {
        guard var state = try load() else { throw Failure.missing }
        guard state.heldReason == nil else { throw Failure.reconciliation }
        let before = state.projected
        let d = try TripOccurrenceCoverage.requireDocument(before)
        let action = try build(d, before)
        let id = UUID().uuidString.lowercased()
        let after = try reduce(raw: before, d: d, action: action, id: id, history: state.history)
        let params: JSON = .object(["p_operation_id": .string(id), "p_trip_id": .string(scope.tripId),
                                   "p_expected_revision": .number(Double(d.revision)), "p_expected_plan_revision": .number(Double(d.planRevision)),
                                   "p_action": action])
        let op = Operation(id: id, action: action, before: before, after: after, params: params)
        state.pending.append(op); state.history.append(op)
        try save(state)
        return op
    }
    func acknowledge(_ result: JSON) throws {
        guard var state = try load() else { throw Failure.missing }
        guard result[occurrence: "tripId"]?.occurrenceString == scope.tripId else { throw Failure.scopeConflict }
        guard let op = state.pending.first, result[occurrence: "operationId"]?.occurrenceString == op.id else { return }
        guard let coverage = result[occurrence: "coverage"] else { throw Failure.updateRequired }
        _ = try TripOccurrenceCoverage.requireDocument(coverage)
        guard coverage == op.after else { state.heldReason = Failure.reconciliation.localizedDescription; try save(state); return }
        state.acknowledged = coverage; state.pending.removeFirst()
        try save(state)
    }
    func reconcile(_ remote: JSON) throws {
        guard var state = try load() else { throw Failure.missing }
        let incoming = try TripOccurrenceCoverage.requireDocument(remote)
        let base = try TripOccurrenceCoverage.requireDocument(state.acknowledged)
        guard incoming.planId == base.planId else { throw Failure.scopeConflict }
        if incoming.revision < base.revision || remote == state.acknowledged { return }
        if !state.pending.isEmpty || incoming.revision == base.revision { state.heldReason = Failure.reconciliation.localizedDescription }
        else { state.acknowledged = remote }
        try save(state)
    }
    func hold(_ code: String) throws {
        guard var state = try load() else { throw Failure.missing }
        state.heldReason = code.contains("UPDATE_REQUIRED") || code.contains("UNSUPPORTED")
            ? Failure.updateRequired.localizedDescription : Failure.reconciliation.localizedDescription
        try save(state)
    }
    private func save(_ state: Snapshot) throws {
        do { try JSONEncoder().encode(state).write(to: fileURL, options: .atomic) }
        catch { throw Failure.storage }
    }
    private func reduce(raw: JSON, d: TripOccurrenceCoverage.Document, action: JSON, id: String, history: [Operation]) throws -> JSON {
        guard var fields = raw.occurrenceObject, var states = fields["states"]?.occurrenceObject,
              let kind = action[occurrence: "kind"]?.occurrenceString else { throw Failure.invalidAction }
        let target = action[occurrence: "occurrenceId"]?.occurrenceString
        if let target, !d.activeOrder.contains(target) { throw Failure.invalidAction }
        switch kind {
        case "setStatus":
            guard let target, let status = action[occurrence: "toStatus"], let source = action[occurrence: "source"],
                  let tanks = action[occurrence: "tankSessionIds"] else { throw Failure.invalidAction }
            states[target] = .object(["status": status, "source": source, "lastOperationId": .string(id), "tankSessionIds": tanks])
        case "undo":
            guard let target, let prior = history.first(where: { $0.id == action[occurrence: "undoOfOperationId"]?.occurrenceString }),
                  ["setStatus", "undo"].contains(prior.action[occurrence: "kind"]?.occurrenceString ?? ""),
                  var before = prior.before[occurrence: "states"]?[occurrence: target]?.occurrenceObject else { throw Failure.invalidAction }
            before["lastOperationId"] = .string(id); before["source"] = .string("correction"); states[target] = .object(before)
        case "selectOccurrence": fields["selectedOccurrenceId"] = target.map { .string($0) } ?? .null
        case "editPlan":
            fields["activeOrder"] = action[occurrence: "activeOrder"]; fields["selectedOccurrenceId"] = .null
            fields["planRevision"] = .number(Double(d.planRevision + 1))
        default: throw Failure.invalidAction
        }
        if ["setStatus", "undo"].contains(kind), fields["selectedOccurrenceId"]?.occurrenceString == target { fields["selectedOccurrenceId"] = .null }
        fields["states"] = .object(states); fields["revision"] = .number(Double(d.revision + 1))
        guard case .array(let order) = fields["activeOrder"] else { throw Failure.invalidAction }
        let cursor = order.compactMap(\.occurrenceString).first { states[$0]?[occurrence: "status"]?.occurrenceString == "incomplete" }
        fields["plannedCursorId"] = cursor.map { .string($0) } ?? .null
        let result: JSON = .object(fields)
        _ = try TripOccurrenceCoverage.requireDocument(result)
        return result
    }
}
