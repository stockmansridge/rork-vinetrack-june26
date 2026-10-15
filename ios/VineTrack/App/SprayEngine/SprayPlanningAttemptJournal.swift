import Foundation

/// One atomic, account-incarnation/vineyard document owns every original request and its receipt.
/// No Trip/tank/coverage side effects are performed by this journal.
@MainActor final class SprayPlanningAttemptJournal {
    typealias Wire = SprayPlanningProtocol
    enum Stage: String, Codable { case intentDurable, outcomeUnknown, receiptVerified, localStateRepaired, complete, held, quarantined }
    struct Attempt: Codable, Equatable {
        let request: Wire.Request
        var stage: Stage = .intentDurable
        var receipt: Wire.Receipt?
        var reason: String?
    }
    struct Document: Codable {
        let schemaVersion: Int
        let scope: Wire.Scope
        var attempts: [Attempt]
    }
    private let file: URL
    private let scope: Wire.Scope
    /// Optional fault injection exercises failure before atomic replacement without an alternate authority.
    private let beforeWrite: (() throws -> Void)?
    init(scope: Wire.Scope, root: URL? = nil, beforeWrite: (() throws -> Void)? = nil) throws {
        guard [scope.actorId, scope.vineyardId, scope.incarnation].allSatisfy(TripOccurrenceCoverage.canonicalUUID) else { throw Wire.Failure.scope }
        self.scope = scope; self.beforeWrite = beforeWrite
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SprayPlanningAttempts-v1")
        let directory = base.appendingPathComponent(scope.actorId).appendingPathComponent(scope.vineyardId).appendingPathComponent(scope.incarnation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("attempts.json")
    }
    func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: file.path) else { return Document(schemaVersion: 1, scope: scope, attempts: []) }
        let d = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard d.schemaVersion == 1, d.scope == scope, Set(d.attempts.map { $0.request.operationId }).count == d.attempts.count else { throw Wire.Failure.scope }
        for a in d.attempts {
            try Wire.validate(a.request)
            guard a.request.actorId == scope.actorId, a.request.vineyardId == scope.vineyardId else { throw Wire.Failure.scope }
            if let receipt = a.receipt { try Wire.verify(receipt, for: a.request) }
        }
        return d
    }
    @discardableResult func prepare(_ request: Wire.Request, currentScope: Wire.Scope) throws -> Attempt {
        try fence(currentScope); try Wire.validate(request)
        guard request.actorId == scope.actorId, request.vineyardId == scope.vineyardId else { throw Wire.Failure.scope }
        var d = try load()
        if let existing = d.attempts.first(where: { $0.request.operationId == request.operationId }) {
            guard existing.request == request else { throw Wire.Failure.conflict }; return existing
        }
        guard !d.attempts.contains(where: { $0.request.snapshot.recordId == request.snapshot.recordId && $0.stage != .complete }) else { throw Wire.Failure.conflict }
        if let previous = d.attempts.last(where: { $0.request.snapshot.recordId == request.snapshot.recordId })?.receipt {
            guard request.snapshot.expectedPreviousRevisionId == previous.result.recipeRevisionId,
                  request.snapshot.expectedRecipeDigest == previous.recipeSHA256 else { throw Wire.Failure.conflict }
        }
        let attempt = Attempt(request: request); d.attempts.append(attempt); try save(d); return attempt
    }
    func pending(currentScope: Wire.Scope) throws -> [Attempt] {
        try fence(currentScope)
        return try load().attempts.filter { $0.stage != .complete }
    }
    func markSent(_ id: String, currentScope: Wire.Scope) throws {
        try fence(currentScope)
        try mutate(id) { a in
            guard [.intentDurable, .outcomeUnknown].contains(a.stage) else { throw Wire.Failure.conflict }
            a.stage = .outcomeUnknown
        }
    }
    func accept(_ receipt: Wire.Receipt, currentScope: Wire.Scope) throws {
        try fence(currentScope)
        try mutate(receipt.operationId) { a in
            try Wire.verify(receipt, for: a.request)
            if let old = a.receipt { guard old == receipt else { throw Wire.Failure.conflict }; return }
            guard [.intentDurable, .outcomeUnknown].contains(a.stage) else { throw Wire.Failure.conflict }
            a.receipt = receipt; a.stage = .receiptVerified; a.reason = nil
        }
    }
    /// Caller must durably repair from the receipt, idempotently and with a current-revision CAS.
    /// A false result retains the receipt and all established factual effects for explicit repair.
    func repair(_ id: String, currentScope: Wire.Scope, apply: (Wire.Receipt) throws -> Bool) throws {
        try fence(currentScope)
        guard let a = try load().attempts.first(where: { $0.request.operationId == id }), let receipt = a.receipt else { throw Wire.Failure.repairRequired }
        if a.stage == .complete { return }
        guard [.receiptVerified, .localStateRepaired].contains(a.stage) else { throw Wire.Failure.conflict }
        if a.stage == .receiptVerified {
            guard try apply(receipt) else { throw Wire.Failure.repairRequired }
            try mutate(id) { $0.stage = .localStateRepaired }
        }
        try mutate(id) { $0.stage = .complete }
    }
    func hold(_ id: String, currentScope: Wire.Scope, reason: String) throws {
        try fence(currentScope)
        try mutate(id) { if $0.stage != .complete { $0.stage = .held; $0.reason = reason } }
    }
    private func fence(_ current: Wire.Scope) throws {
        guard current == scope else {
            var d = try load()
            for index in d.attempts.indices where d.attempts[index].stage != .complete {
                d.attempts[index].stage = .quarantined; d.attempts[index].reason = "scope_changed"
            }
            try save(d); throw Wire.Failure.scope
        }
    }
    private func mutate(_ id: String, _ change: (inout Attempt) throws -> Void) throws {
        var d = try load()
        guard let index = d.attempts.firstIndex(where: { $0.request.operationId == id }) else { throw Wire.Failure.invalidReceipt }
        try change(&d.attempts[index]); try save(d)
    }
    private func save(_ d: Document) throws {
        try beforeWrite?()
        try JSONEncoder().encode(d).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Controlled transports return HTTP status separately; 409 can never be interpreted as acceptance.
@MainActor protocol SprayPlanningTransport {
    func call(_ rpc: String, body: Data) async throws -> (status: Int, data: Data)
}

/// Recovery never fabricates missing receipts or repairs a current projection from an older acknowledgement.
@MainActor final class SprayPlanningClient {
    typealias Wire = SprayPlanningProtocol
    private let journal: SprayPlanningAttemptJournal
    private let transport: any SprayPlanningTransport
    private let currentScope: () throws -> Wire.Scope
    private var running: Bool = false
    init(journal: SprayPlanningAttemptJournal, transport: any SprayPlanningTransport, currentScope: @escaping () throws -> Wire.Scope) {
        self.journal = journal; self.transport = transport; self.currentScope = currentScope
    }
    func recover() async throws {
        guard !running else { throw Wire.Failure.conflict }; running = true; defer { running = false }
        let scope = try currentScope(); let attempts = try journal.pending(currentScope: scope)
        guard !attempts.isEmpty else { return }
        let params: Wire.JSON = .object(["p_vineyard_id": .string(scope.vineyardId), "p_operation_ids": .array(attempts.map { .string($0.request.operationId) }),
            "p_record_ids": .array(Array(Set(attempts.map { $0.request.snapshot.recordId })).sorted().map { .string($0) }),
            "p_trip_ids": .array(Array(Set(attempts.compactMap { $0.request.snapshot.tripId })).sorted().map { .string($0) })])
        let response = try await transport.call("get_spray_planning_recovery_v1", body: JSONEncoder().encode(params))
        _ = try journal.pending(currentScope: currentScope())
        guard response.status == 200 else { throw Wire.Failure.unavailable }
        let recovery = try JSONDecoder().decode(Wire.Recovery.self, from: response.data)
        guard recovery.contract == Wire.contract, recovery.schemaVersion == 1, recovery.actorId == scope.actorId, recovery.vineyardId == scope.vineyardId,
              Set(recovery.receipts.map(\.operationId)).count == recovery.receipts.count else { throw Wire.Failure.invalidReceipt }
        let raw = try JSONDecoder().decode(Wire.JSON.self, from: response.data)
        guard case .array(let receipts) = raw[occurrence: "receipts"] else { throw Wire.Failure.invalidReceipt }
        for receipt in receipts {
            guard let id = receipt[occurrence: "operationId"]?.occurrenceString,
                  let original = attempts.first(where: { $0.request.operationId == id })?.request else { throw Wire.Failure.invalidReceipt }
            try journal.accept(verifiedReceipt(receipt, request: original), currentScope: currentScope())
        }
        // Missing receipt means outcome unknown, never failure or permission to mint another operation.
    }
    func send(_ request: Wire.Request) async throws {
        guard !running else { throw Wire.Failure.conflict }; running = true; defer { running = false }
        let scope = try currentScope(); _ = try journal.prepare(request, currentScope: scope)
        let capabilityBody: Wire.JSON = .object(["p_vineyard_id": .string(scope.vineyardId)])
        let c = try await transport.call("get_spray_planning_capability_v1", body: JSONEncoder().encode(capabilityBody))
        _ = try journal.pending(currentScope: currentScope())
        guard c.status == 200, let capability = try? JSONDecoder().decode(Wire.Capability.self, from: c.data), capability.supports(request) else { throw Wire.Failure.unavailable }
        // The independent production operational gate is intentionally NOT replaced by capability alone.
        try journal.markSent(request.operationId, currentScope: currentScope())
        let params: Wire.JSON = .object(["p_operation_id": .string(request.operationId), "p_request": try JSONDecoder().decode(Wire.JSON.self, from: JSONEncoder().encode(request))])
        let result = try await transport.call(request.kind.rpc, body: JSONEncoder().encode(params))
        _ = try journal.pending(currentScope: currentScope())
        if result.status == 409 { try journal.hold(request.operationId, currentScope: currentScope(), reason: "http_409"); throw Wire.Failure.conflict }
        guard (200..<300).contains(result.status) else { throw Wire.Failure.unavailable }
        do { try journal.accept(verifiedReceipt(JSONDecoder().decode(Wire.JSON.self, from: result.data), request: request), currentScope: currentScope()) }
        catch { try journal.hold(request.operationId, currentScope: currentScope(), reason: "unverified_receipt"); throw error }
    }
    private func verifiedReceipt(_ raw: Wire.JSON, request: Wire.Request) throws -> Wire.Receipt {
        let original = try JSONDecoder().decode(Wire.JSON.self, from: JSONEncoder().encode(request))
        guard raw[occurrence: "request"] == original,
              raw[occurrence: "result"]?[occurrence: "snapshot"] == original[occurrence: "snapshot"] else { throw Wire.Failure.invalidReceipt }
        let receipt = try JSONDecoder().decode(Wire.Receipt.self, from: JSONEncoder().encode(raw))
        try Wire.verify(receipt, for: request)
        return receipt
    }
}
