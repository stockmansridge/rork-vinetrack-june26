import Foundation

nonisolated enum PendingManualSprayKind: String, Codable, Sendable {
    case save
    case delete
}

nonisolated struct PendingManualSprayOperation: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let kind: PendingManualSprayKind
    var payload: ManualSprayPayload
    var expectedVersion: Int?
    var attemptCount: Int
    var lastError: String?
}

protocol ManualSprayEntryStoring: Sendable {
    func load() -> [PendingManualSprayOperation]
    @discardableResult func save(_ operations: [PendingManualSprayOperation]) -> Bool
}

final class ManualSprayEntryStore: ManualSprayEntryStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard, key: String = "vinetrack_manual_spray_operations_v1") {
        self.defaults = defaults
        self.key = key
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [PendingManualSprayOperation] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? decoder.decode([PendingManualSprayOperation].self, from: data)) ?? []
    }

    @discardableResult func save(_ operations: [PendingManualSprayOperation]) -> Bool {
        guard let data = try? encoder.encode(operations) else { return false }
        defaults.set(data, forKey: key)
        return defaults.synchronize()
    }
}

final class ManualSprayDraftStore: @unchecked Sendable {
    static let shared = ManualSprayDraftStore()
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }
    private func key(_ vineyardId: UUID) -> String { "vinetrack_manual_spray_draft_v1_\(vineyardId.uuidString.lowercased())" }
    func load(vineyardId: UUID) -> ManualSprayPayload? { defaults.data(forKey: key(vineyardId)).flatMap { try? decoder.decode(ManualSprayPayload.self, from: $0) } }
    func save(_ payload: ManualSprayPayload) { if let data = try? encoder.encode(payload) { defaults.set(data, forKey: key(payload.vineyardId)) } }
    func clear(vineyardId: UUID) { defaults.removeObject(forKey: key(vineyardId)) }
}

@MainActor
final class ManualSprayEntryCoordinator {
    static let shared: ManualSprayEntryCoordinator = ManualSprayEntryCoordinator(
        repository: ManualSprayEntryRepository(),
        store: ManualSprayEntryStore()
    )

    private let repository: ManualSprayEntryRepositoryProtocol
    private let store: ManualSprayEntryStoring
    private(set) var operations: [PendingManualSprayOperation]

    init(repository: ManualSprayEntryRepositoryProtocol, store: ManualSprayEntryStoring) {
        self.repository = repository
        self.store = store
        operations = store.load()
    }

    var pendingPayloads: [ManualSprayPayload] {
        let deleted = Set(operations.filter { $0.kind == .delete }.map { $0.payload.manualEntryId })
        return operations.filter { $0.kind == .save && !deleted.contains($0.payload.manualEntryId) }.map(\.payload)
    }

    func save(payload: ManualSprayPayload, expectedVersion: Int?) async throws -> ManualSpraySaveResponse? {
        let valid = try payload.validated()
        let operation: PendingManualSprayOperation
        if let queued = operations.first(where: { $0.kind == .save && $0.payload.vineyardId == valid.vineyardId && $0.payload.manualEntryId == valid.manualEntryId }) {
            guard queued.payload == valid, queued.expectedVersion == expectedVersion else {
                throw ManualSprayPersistenceError.exactRetryRequired
            }
            operation = queued
        } else {
            operation = PendingManualSprayOperation(id: UUID(), kind: .save, payload: valid, expectedVersion: expectedVersion, attemptCount: 0, lastError: nil)
            try persist(operations + [operation], failure: .couldNotPersist)
        }
        do {
            let response = try await repository.save(operationId: operation.id, payload: operation.payload, expectedVersion: operation.expectedVersion)
            guard response.matches(operation) else {
                markFailed(operation.id, error: ManualSprayPersistenceError.serverDidNotConfirm)
                return nil
            }
            try persist(operations.filter { $0.id != operation.id }, failure: .couldNotPersistConfirmation)
            return response
        } catch let persistenceError as ManualSprayPersistenceError {
            throw persistenceError
        } catch {
            if let terminalError = ManualSprayMutationError.classify(error) {
                try persist(operations.filter { $0.id != operation.id }, failure: .couldNotPersistConfirmation)
                throw terminalError
            }
            markFailed(operation.id, error: error)
            return nil
        }
    }

    func delete(payload: ManualSprayPayload) async throws -> Bool {
        let sameIdentity: (PendingManualSprayOperation) -> Bool = {
            $0.payload.vineyardId == payload.vineyardId && $0.payload.manualEntryId == payload.manualEntryId
        }
        let operation = operations.first(where: { $0.kind == .delete && sameIdentity($0) }) ??
            PendingManualSprayOperation(id: UUID(), kind: .delete, payload: payload, expectedVersion: nil, attemptCount: 0, lastError: nil)
        if !operations.contains(where: { $0.id == operation.id }) {
            try persist(operations.filter { !sameIdentity($0) } + [operation], failure: .couldNotPersist)
        }
        do {
            try await repository.delete(operationId: operation.id, payload: payload)
            try persist(operations.filter { $0.id != operation.id }, failure: .couldNotPersistConfirmation)
            return true
        } catch let persistenceError as ManualSprayPersistenceError {
            throw persistenceError
        } catch {
            markFailed(operation.id, error: error)
            return false
        }
    }

    func replayCandidateCount(currentVineyardId: UUID?, currentRole: BackendRole?) -> Int {
        guard currentRole?.canManageManualSprays == true else { return 0 }
        return operations.count { $0.payload.vineyardId == currentVineyardId }
    }

    func replay(currentVineyardId: UUID?, currentRole: BackendRole?) async {
        for operation in operations {
            guard operation.payload.vineyardId == currentVineyardId, currentRole?.canManageManualSprays == true else { continue }
            do {
                switch operation.kind {
                case .save:
                    if operations.contains(where: { $0.kind == .delete && $0.payload.manualEntryId == operation.payload.manualEntryId }) { continue }
                    let response = try await repository.save(operationId: operation.id, payload: operation.payload, expectedVersion: operation.expectedVersion)
                    guard response.matches(operation) else {
                        markFailed(operation.id, error: ManualSprayPersistenceError.serverDidNotConfirm)
                        continue
                    }
                case .delete:
                    try await repository.delete(operationId: operation.id, payload: operation.payload)
                }
                try persist(operations.filter { $0.id != operation.id }, failure: .couldNotPersistConfirmation)
            } catch {
                if ManualSprayMutationError.classify(error) != nil {
                    try? persist(operations.filter { $0.id != operation.id }, failure: .couldNotPersistConfirmation)
                } else {
                    markFailed(operation.id, error: error)
                }
            }
        }
    }

    private func persist(_ candidate: [PendingManualSprayOperation], failure: ManualSprayPersistenceError) throws {
        guard store.save(candidate) else { throw failure }
        operations = candidate
    }

    private func markFailed(_ id: UUID, error: Error) {
        let candidate = operations.map { operation -> PendingManualSprayOperation in
            guard operation.id == id else { return operation }
            var updated = operation
            updated.attemptCount += 1
            updated.lastError = error.localizedDescription
            return updated
        }
        if store.save(candidate) { operations = candidate }
    }
}

nonisolated enum ManualSprayMutationError: LocalizedError, Sendable {
    case staleVersion
    case deleted

    static func classify(_ error: Error) -> ManualSprayMutationError? {
        if let mutationError = error as? ManualSprayMutationError { return mutationError }
        let nsError = error as NSError
        let diagnostic = ([String(reflecting: error), error.localizedDescription, nsError.domain] + nsError.userInfo.values.map { String(describing: $0) }).joined(separator: " ")
        if diagnostic.contains("40001") { return .staleVersion }
        if diagnostic.contains("55000") { return .deleted }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .staleVersion: "This spray changed on another device. Reload it and reconcile your changes before saving again."
        case .deleted: "This manual spray has already been deleted. Its saved retry was discarded."
        }
    }
}

private extension ManualSpraySaveResponse {
    func matches(_ operation: PendingManualSprayOperation) -> Bool {
        serverConfirmed && source == "manual" && status == "completed" && operationId == operation.id &&
            manualEntryId == operation.payload.manualEntryId && sprayRecordId == operation.payload.sprayRecordId &&
            tripId == operation.payload.tripId
    }
}

nonisolated enum ManualSprayPersistenceError: LocalizedError, Sendable {
    case couldNotPersist
    case couldNotPersistConfirmation
    case exactRetryRequired
    case serverDidNotConfirm

    var errorDescription: String? {
        switch self {
        case .couldNotPersist: "The complete manual spray could not be saved on this device."
        case .couldNotPersistConfirmation: "The server saved the manual spray, but its confirmation could not be retained on this device."
        case .exactRetryRequired: "This manual spray already has an exact saved retry. Retry it before making further changes."
        case .serverDidNotConfirm: "The server did not confirm this exact manual spray. Its saved retry was retained."
        }
    }
}
