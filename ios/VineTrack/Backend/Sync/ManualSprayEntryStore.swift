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
    static let shared: ManualSprayEntryCoordinator = ManualSprayEntryCoordinator()

    private let repository: ManualSprayEntryRepositoryProtocol
    private let store: ManualSprayEntryStoring
    private(set) var operations: [PendingManualSprayOperation]

    init(repository: ManualSprayEntryRepositoryProtocol = ManualSprayEntryRepository(), store: ManualSprayEntryStoring = ManualSprayEntryStore()) {
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
        if let queued = operations.first(where: { $0.kind == .save && $0.payload == valid && $0.expectedVersion == expectedVersion }) {
            operation = queued
        } else {
            operation = PendingManualSprayOperation(id: UUID(), kind: .save, payload: valid, expectedVersion: expectedVersion, attemptCount: 0, lastError: nil)
            replaceSave(with: operation)
            guard store.save(operations) else { throw ManualSprayPersistenceError.couldNotPersist }
        }
        do {
            let response = try await repository.save(operationId: operation.id, payload: valid, expectedVersion: expectedVersion)
            operations.removeAll { $0.id == operation.id }
            guard store.save(operations) else { throw ManualSprayPersistenceError.couldNotPersistConfirmation }
            return response
        } catch {
            if let terminalError = ManualSprayMutationError.classify(error) {
                operations.removeAll { $0.id == operation.id }
                guard store.save(operations) else { throw ManualSprayPersistenceError.couldNotPersistConfirmation }
                throw terminalError
            }
            markFailed(operation.id, error: error)
            return nil
        }
    }

    func delete(payload: ManualSprayPayload) async throws -> Bool {
        operations.removeAll { $0.kind == .save && $0.payload.manualEntryId == payload.manualEntryId }
        let operation = PendingManualSprayOperation(id: UUID(), kind: .delete, payload: payload, expectedVersion: nil, attemptCount: 0, lastError: nil)
        operations.removeAll { $0.kind == .delete && $0.payload.manualEntryId == payload.manualEntryId }
        operations.append(operation)
        guard store.save(operations) else { throw ManualSprayPersistenceError.couldNotPersist }
        do {
            try await repository.delete(operationId: operation.id, payload: payload)
            operations.removeAll { $0.id == operation.id }
            guard store.save(operations) else { throw ManualSprayPersistenceError.couldNotPersistConfirmation }
            return true
        } catch {
            markFailed(operation.id, error: error)
            return false
        }
    }

    func replay(currentRole: BackendRole?) async {
        guard currentRole?.canManageManualSprays == true else { return }
        for operation in operations {
            do {
                switch operation.kind {
                case .save:
                    if operations.contains(where: { $0.kind == .delete && $0.payload.manualEntryId == operation.payload.manualEntryId }) { continue }
                    _ = try await repository.save(operationId: operation.id, payload: operation.payload, expectedVersion: operation.expectedVersion)
                case .delete:
                    try await repository.delete(operationId: operation.id, payload: operation.payload)
                }
                operations.removeAll { $0.id == operation.id }
                _ = store.save(operations)
            } catch {
                if ManualSprayMutationError.classify(error) != nil {
                    operations.removeAll { $0.id == operation.id }
                    _ = store.save(operations)
                } else {
                    markFailed(operation.id, error: error)
                }
            }
        }
    }

    private func replaceSave(with operation: PendingManualSprayOperation) {
        operations.removeAll { $0.kind == .save && $0.payload.manualEntryId == operation.payload.manualEntryId }
        operations.append(operation)
    }

    private func markFailed(_ id: UUID, error: Error) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].attemptCount += 1
        operations[index].lastError = error.localizedDescription
        _ = store.save(operations)
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

nonisolated enum ManualSprayPersistenceError: LocalizedError, Sendable {
    case couldNotPersist
    case couldNotPersistConfirmation

    var errorDescription: String? {
        switch self {
        case .couldNotPersist: "The complete manual spray could not be saved on this device."
        case .couldNotPersistConfirmation: "The server saved the manual spray, but its confirmation could not be retained on this device."
        }
    }
}
