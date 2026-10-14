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
        var rpc: String {
            switch action[occurrence: "kind"]?.occurrenceString {
            case "create": return "create_trip_with_occurrences_v1"
            case "activate": return "activate_trip_occurrences_v1"
            case "finalize": return "finalize_trip_occurrences_v1"
            default: return "apply_trip_occurrence_action_v1"
            }
        }
    }
    nonisolated struct Snapshot: Codable, Sendable, Equatable {
        let scope: Scope
        var acknowledged: JSON
        var pending: [Operation] = []
        var history: [Operation] = []
        var heldReason: String? = nil
        var creationConfirmed: Bool? = nil
        var serverActive: Bool? = nil
        var projected: JSON { pending.last?.after ?? acknowledged }
    }
    /// A retained create/activation chain permits offline work, never an unresolved identity or hold.
    func canOperate(_ state: Snapshot) -> Bool {
        guard state.heldReason == nil,
              !state.pending.contains(where: { $0.action[occurrence: "kind"]?.occurrenceString == "finalize" }) else { return false }
        if let activation = state.pending.firstIndex(where: { $0.action[occurrence: "kind"]?.occurrenceString == "activate" }) {
            let parents = state.pending.prefix(activation)
            return parents.allSatisfy { $0.rpc == "create_trip_with_occurrences_v1" } &&
                (state.creationConfirmed != false || parents.count == 1)
        }
        return state.creationConfirmed != false && state.serverActive != false
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
    func initialize(_ coverage: JSON, requiresRecovery: Bool = false) throws {
        _ = try TripOccurrenceCoverage.requireDocument(coverage)
        guard try load() == nil else { throw Failure.reconciliation }
        var state = Snapshot(scope: scope, acknowledged: coverage)
        if requiresRecovery { state.creationConfirmed = false; state.serverActive = false }
        try save(state)
    }
    @discardableResult func prepareCreation(trip: JSON, coverage: JSON) throws -> Operation {
        guard trip[occurrence: "id"]?.occurrenceString?.lowercased() == scope.tripId,
              trip[occurrence: "vineyard_id"]?.occurrenceString?.lowercased() == scope.vineyardId else { throw Failure.scopeConflict }
        let d = try TripOccurrenceCoverage.requireDocument(coverage)
        guard d.revision == 0, d.planRevision == 1, d.states.values.allSatisfy({ $0.status == "incomplete" }),
              try load() == nil else { throw Failure.reconciliation }
        let id = UUID().uuidString.lowercased()
        let action: JSON = .object(["kind": .string("create"), "planId": .string(d.planId), "trip": trip])
        let params: JSON = .object(["p_operation_id": .string(id), "p_trip": trip, "p_coverage": coverage])
        let op = Operation(id: id, action: action, before: coverage, after: coverage, params: params)
        var state = Snapshot(scope: scope, acknowledged: coverage)
        state.pending = [op]; state.history = [op]; state.creationConfirmed = false; state.serverActive = false
        try save(state)
        return op
    }
    @discardableResult func activate(_ start: JSON) throws -> Operation { try lifecycle("activate", metadata: start) }
    @discardableResult func finalize(_ end: JSON) throws -> Operation { try lifecycle("finalize", metadata: end) }
    private func lifecycle(_ kind: String, metadata: JSON) throws -> Operation {
        guard var state = try load(), state.heldReason == nil,
              kind == "finalize" || state.creationConfirmed != false || (kind == "activate" && state.pending.count == 1 && state.pending.first?.rpc == "create_trip_with_occurrences_v1"),
              !state.pending.contains(where: { $0.action[occurrence: "kind"]?.occurrenceString == "finalize" || (kind == "activate" && $0.action[occurrence: "kind"]?.occurrenceString == "activate") }) else { throw Failure.reconciliation }
        if kind == "activate" { guard state.serverActive == false, state.pending.allSatisfy({ $0.rpc == "create_trip_with_occurrences_v1" }) else { throw Failure.reconciliation } }
        else { guard canOperate(state) else { throw Failure.reconciliation } }
        let before = state.projected; let d = try TripOccurrenceCoverage.requireDocument(before)
        guard var fields = before.occurrenceObject else { throw Failure.updateRequired }
        let id = UUID().uuidString.lowercased()
        fields["revision"] = .number(Double(d.revision + 1))
        if kind == "finalize" { fields["selectedOccurrenceId"] = .null }
        var params: [String: JSON] = ["p_operation_id": .string(id), "p_trip_id": .string(scope.tripId),
            "p_expected_revision": .number(Double(d.revision)), "p_expected_plan_revision": .number(Double(d.planRevision))]
        if kind == "activate" { params["p_start"] = metadata }
        else { params["p_reviewed_states"] = before[occurrence: "states"]; params["p_end"] = metadata }
        let op = Operation(id: id, action: .object(["kind": .string(kind), "planId": .string(d.planId), "metadata": metadata]),
            before: before, after: .object(fields), params: .object(params))
        state.pending.append(op); state.history.append(op); try save(state)
        return op
    }

    /// Server evidence is scoped and validated before replacing any local base or history.
    func recover(_ response: JSON) throws {
        guard response[occurrence: "contract"] == .string("vinetrack.occurrence-recovery"), response[occurrence: "schemaVersion"] == .number(1),
              response[occurrence: "tripId"] == .string(scope.tripId), response[occurrence: "vineyardId"] == .string(scope.vineyardId),
              let remote = response[occurrence: "coverage"], case .bool(let active) = response[occurrence: "isActive"],
              case .array(let receipts) = response[occurrence: "receipts"],
              case .array(let reversible) = response[occurrence: "reversibleOperations"] else { throw Failure.scopeConflict }
        let d = try TripOccurrenceCoverage.requireDocument(remote)
        if let initial = try load() {
            guard try TripOccurrenceCoverage.requireDocument(initial.acknowledged).planId == d.planId else { throw Failure.scopeConflict }
        } else {
            var initial = Snapshot(scope: scope, acknowledged: remote)
            initial.creationConfirmed = true; initial.serverActive = active; try save(initial)
        }
        for _ in 0..<256 {
            guard let op = try load()?.pending.first,
                  let receipt = receipts.first(where: { $0[occurrence: "operationId"] == .string(op.id) }) else { break }
            guard receipt[occurrence: "actorId"] == .string(scope.ownerId), receipt[occurrence: "request"] == serverRequest(op),
                  let result = receipt[occurrence: "result"] else { throw Failure.scopeConflict }
            try acknowledge(result)
        }
        guard var state = try load() else { throw Failure.missing }
        let base = try TripOccurrenceCoverage.requireDocument(state.acknowledged)
        if d.revision < base.revision { return }
        if (!state.pending.isEmpty || d.revision == base.revision) && remote != state.acknowledged {
            state.heldReason = Failure.reconciliation.localizedDescription; try save(state); return
        }
        var recovered: [Operation] = []
        for row in reversible {
            guard let id = row[occurrence: "operationId"]?.occurrenceString,
                  row[occurrence: "tripId"] == .string(scope.tripId),
                  let result = row[occurrence: "result"], result[occurrence: "tripId"] == .string(scope.tripId), result[occurrence: "operationId"] == .string(id),
                  let after = result[occurrence: "coverage"], let action = row[occurrence: "request"]?[occurrence: "action"],
                  let target = action[occurrence: "occurrenceId"]?.occurrenceString,
                  ["setStatus", "undo"].contains(action[occurrence: "kind"]?.occurrenceString ?? ""),
                  d.activeOrder.contains(target), d.states[target]?.lastOperationId == id,
                  row[occurrence: "resultingState"] == remote[occurrence: "states"]?[occurrence: target],
                  let previous = row[occurrence: "previousState"], var before = after.occurrenceObject,
                  var states = before["states"]?.occurrenceObject else { throw Failure.reconciliation }
            let accepted = try TripOccurrenceCoverage.requireDocument(after)
            guard accepted.planId == d.planId, accepted.revision <= d.revision,
                  after[occurrence: "states"]?[occurrence: target] == remote[occurrence: "states"]?[occurrence: target] else { throw Failure.reconciliation }
            states[target] = previous; before["states"] = .object(states); before["revision"] = .number(Double(accepted.revision - 1))
            _ = try TripOccurrenceCoverage.requireDocument(.object(before))
            recovered.append(Operation(id: id, action: action, before: .object(before), after: after, params: .object([:])))
        }
        let pendingIds = Set(state.pending.map(\.id))
        var history = state.history.filter { pendingIds.contains($0.id) || ["create", "activate", "finalize"].contains($0.action[occurrence: "kind"]?.occurrenceString ?? "") }
        for op in recovered where !history.contains(where: { $0.id == op.id }) { history.append(op) }
        history.sort { (TripOccurrenceCoverage.read($0.after)?.revision ?? 0) < (TripOccurrenceCoverage.read($1.after)?.revision ?? 0) }
        state.acknowledged = remote; state.history = history; state.serverActive = active
        state.creationConfirmed = !state.pending.contains(where: { $0.rpc == "create_trip_with_occurrences_v1" })
        try save(state)
    }
    private func serverRequest(_ op: Operation) -> JSON {
        let kind = op.action[occurrence: "kind"]?.occurrenceString
        if kind == "create" {
            return .object(["kind": .string("create"), "trip": op.params[occurrence: "p_trip"] ?? .null, "coverage": op.params[occurrence: "p_coverage"] ?? .null])
        }
        var request: [String: JSON] = ["tripId": .string(scope.tripId),
            "expectedRevision": op.params[occurrence: "p_expected_revision"] ?? .null,
            "expectedPlanRevision": op.params[occurrence: "p_expected_plan_revision"] ?? .null]
        if kind == "activate" { request["kind"] = .string("activate"); request["start"] = op.params[occurrence: "p_start"] }
        else if kind == "finalize" {
            request["kind"] = .string("finalize"); request["reviewedStates"] = op.params[occurrence: "p_reviewed_states"]; request["end"] = op.params[occurrence: "p_end"]
        } else { request["action"] = op.action }
        return .object(request)
    }

    func undoTarget() throws -> Operation? {
        guard let state = try load() else { throw Failure.missing }
        guard canOperate(state) else { return nil }
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
    /// Retires the old item and preserves its audit state. The replacement must have a new UUID.
    @discardableResult func replaceOccurrence(_ oldId: String, newItem: JSON) throws -> Operation {
        try append { d, raw in
            guard d.activeOrder.contains(oldId), let newId = newItem[occurrence: "occurrenceId"]?.occurrenceString,
                  !d.items.contains(where: { $0.occurrenceId == newId }), case .array(let items) = raw[occurrence: "items"] else { throw Failure.invalidAction }
            return .object(["kind": .string("editPlan"), "planId": .string(d.planId), "items": .array(items + [newItem]),
                "activeOrder": .array(d.activeOrder.map { .string($0 == oldId ? newId : $0) }),
                "retired": .array((d.retired + [oldId]).map { .string($0) })])
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
        guard canOperate(state) else { throw Failure.reconciliation }
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
        switch op.action[occurrence: "kind"]?.occurrenceString {
        case "create":
            if case .bool(let active) = op.action[occurrence: "trip"]?[occurrence: "is_active"] { state.serverActive = active }
            else { state.serverActive = false }
        case "activate": state.serverActive = true
        case "finalize": state.serverActive = false
        default: break
        }
        state.creationConfirmed = true
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
            guard case .array(let items) = action[occurrence: "items"], case .array(let oldItems) = raw[occurrence: "items"] else { throw Failure.invalidAction }
            for old in oldItems {
                guard items.filter({ $0[occurrence: "occurrenceId"] == old[occurrence: "occurrenceId"] }) == [old] else { throw Failure.invalidAction }
            }
            for item in items {
                guard let key = item[occurrence: "occurrenceId"]?.occurrenceString else { throw Failure.invalidAction }
                if states[key] == nil { states[key] = .object(["status": .string("incomplete"), "lastOperationId": .null, "source": .null, "tankSessionIds": .array([])]) }
            }
            fields["items"] = .array(items); fields["retired"] = action[occurrence: "retired"]
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
