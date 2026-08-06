import Foundation
import SwiftUI

/// Vineyard-shared custom pin types + unified composer writes (sql/170),
/// with a persisted offline outbox — the iOS mirror of Android's
/// `CustomPinSync`.
///
/// Three op kinds replay in dependency order:
///  1. custom TYPE creates (idempotent by client id; duplicate active names
///     converge server-side),
///  2. Custom PIN creates (`create_custom_pin`, idempotent by client id),
///  3. row SEGMENTS for Repair/Growth pins saved with a ROW location
///     (`set_pin_row_segments`; retried while the parent pin insert hasn't
///     reached the server yet).
///
/// Custom pins ride the shared `pins` architecture (mode = ManualIssue), so
/// map markers arrive through the existing pin sync. This service upserts an
/// optimistic local `VinePin` so an offline save shows immediately.
@Observable
final class CustomPinTypeService {

    private let repository: CustomPinTypeRepository
    weak var store: MigratedDataStore?

    /// Vineyard-shared custom types (all vineyards; filter by vineyard id).
    private(set) var types: [CustomPinTypeRecord] = []
    private(set) var pendingOps: [CustomPinPendingOp] = []
    private(set) var isSyncing = false
    var errorMessage: String?

    private static let outboxKey = "vinetrack_custom_pin_outbox"
    private static let cacheKey = "vinetrack_custom_pin_types_cache"

    init(repository: CustomPinTypeRepository = CustomPinTypeRepository()) {
        self.repository = repository
        loadPersisted()
    }

    /// Active types for one vineyard, sorted by name — what the Custom tab shows.
    func activeTypes(vineyardId: UUID?) -> [CustomPinTypeRecord] {
        guard let vineyardId else { return [] }
        return types
            .filter { $0.vineyardId == vineyardId && $0.isActive }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Refresh

    /// Replays the outbox, then pulls the canonical shared catalogue so a
    /// custom item added on another device appears after normal refresh.
    func refresh(vineyardId: UUID) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await replayOutbox()
        do {
            let remote = try await repository.listTypes(vineyardId: vineyardId)
            let pendingIds = Set(pendingOps.compactMap { $0.typeParams?.id })
            let kept = types.filter { $0.vineyardId != vineyardId || pendingIds.contains($0.id) }
            types = kept + remote.filter { !pendingIds.contains($0.id) }
            errorMessage = nil
        } catch {
            // Offline or transient — keep the cached catalogue.
            #if DEBUG
            print("[CustomPinTypeService] refresh failed: \(error.localizedDescription)")
            #endif
        }
        persist()
    }

    // MARK: - Custom type create

    /// Add a vineyard-shared custom item. Duplicate ACTIVE names (trimmed,
    /// case-insensitive) converge on the existing entry. Offline: a stable
    /// client id is minted, the item appears immediately, and the create
    /// replays later — a pin may reference the id straight away.
    @discardableResult
    func addType(name: String, vineyardId: UUID) async -> CustomPinTypeRecord? {
        guard let trimmed = UnifiedPinContract.normalizeCustomTypeName(name) else {
            errorMessage = "A name is required."
            return nil
        }
        if let existing = types.first(where: {
            $0.vineyardId == vineyardId && $0.isActive
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased()
        }) {
            return existing
        }
        let params = CustomPinTypeCreateParams(id: UUID(), vineyardId: vineyardId, name: trimmed)
        do {
            let record = try await repository.createType(params)
            upsertType(record)
            persist()
            return record
        } catch where isPermanentRejection(error) {
            errorMessage = friendlyError(error)
            persist()
            return nil
        } catch {
            let optimistic = CustomPinTypeRecord(
                id: params.id, vineyardId: vineyardId, name: trimmed,
                color: nil, icon: nil, isActive: true,
                createdBy: nil, createdAt: nil, updatedAt: nil
            )
            enqueue(CustomPinPendingOp(
                id: UUID(), kind: .typeCreate,
                typeParams: params, pinParams: nil, pinId: nil, segments: nil,
                queuedAt: Date(), attempts: 0, lastError: nil
            ))
            upsertType(optimistic)
            persist()
            return optimistic
        }
    }

    // MARK: - Custom pin create

    /// Save a Custom-tab pin through the simplified sql/170 RPC. Online when
    /// possible; otherwise queued with the optimistic marker shown
    /// immediately. Returns false only on a permanent server rejection.
    @discardableResult
    func createCustomPin(_ params: CustomPinCreateParams) async -> Bool {
        do {
            let record = try await repository.createCustomPin(params)
            upsertLocalPin(from: record)
        } catch where isPermanentRejection(error) {
            errorMessage = friendlyError(error)
            persist()
            return false
        } catch {
            enqueue(CustomPinPendingOp(
                id: UUID(), kind: .pinCreate,
                typeParams: nil, pinParams: params, pinId: nil, segments: nil,
                queuedAt: Date(), attempts: 0, lastError: nil
            ))
            upsertOptimisticPin(from: params)
        }
        persist()
        return true
    }

    // MARK: - Row segments (Repair / Growth row-scope saves)

    /// Queue the structured ROW selection for a Repair/Growth pin created
    /// through the existing local-first pin path, then try to apply it. The
    /// RPC raises PIN_NOT_FOUND until the pin sync pushes the row — the op
    /// stays queued and replays on the next refresh/save.
    func queueRowSegments(pinId: UUID, segments: [ManualIssueSegment]) async {
        let canonical = ManualIssueContract.canonicalSegments(segments)
        guard !canonical.isEmpty else { return }
        pendingOps.removeAll { $0.kind == .segments && $0.pinId == pinId }
        enqueue(CustomPinPendingOp(
            id: UUID(), kind: .segments,
            typeParams: nil, pinParams: nil, pinId: pinId, segments: canonical,
            queuedAt: Date(), attempts: 0, lastError: nil
        ))
        persist()
        await replayOutbox()
    }

    // MARK: - Outbox replay

    /// Replays queued ops in dependency order (types → pins → segments).
    /// Permanent rejections drop the op with a message; transient failures
    /// (including PIN_NOT_FOUND while the pin insert is in flight) stay
    /// queued.
    func replayOutbox() async {
        guard !pendingOps.isEmpty else { return }
        let ordered = pendingOps.sorted {
            $0.kind.replayOrder != $1.kind.replayOrder
                ? $0.kind.replayOrder < $1.kind.replayOrder
                : $0.queuedAt < $1.queuedAt
        }
        for op in ordered {
            do {
                switch op.kind {
                case .typeCreate:
                    guard let params = op.typeParams else { break }
                    let record = try await repository.createType(params)
                    upsertType(record)
                case .pinCreate:
                    guard let params = op.pinParams else { break }
                    let record = try await repository.createCustomPin(params)
                    upsertLocalPin(from: record)
                case .segments:
                    guard let pinId = op.pinId, let segments = op.segments else { break }
                    _ = try await repository.setPinRowSegments(pinId: pinId, segments: segments)
                }
                pendingOps.removeAll { $0.id == op.id }
            } catch where isPermanentRejection(error) {
                pendingOps.removeAll { $0.id == op.id }
                errorMessage = friendlyError(error)
            } catch {
                if let index = pendingOps.firstIndex(where: { $0.id == op.id }) {
                    pendingOps[index].attempts += 1
                    pendingOps[index].lastError = error.localizedDescription
                }
                // PIN_NOT_FOUND means only this op's dependency is missing —
                // later ops may still succeed. A network failure stops the
                // whole queue so it isn't hammered while offline.
                if !String(describing: error).contains("PIN_NOT_FOUND") { break }
            }
        }
        persist()
    }

    // MARK: - Local application

    private func upsertType(_ record: CustomPinTypeRecord) {
        types.removeAll { $0.id == record.id }
        types.append(record)
    }

    /// Mirror the canonical server row onto the shared pin surfaces.
    private func upsertLocalPin(from record: ManualIssueRecord) {
        guard let store, let latitude = record.latitude, let longitude = record.longitude else { return }
        let existing = store.pins.first(where: { $0.id == record.id })
        let pin = VinePin(
            id: record.id,
            vineyardId: record.vineyardId,
            latitude: latitude,
            longitude: longitude,
            heading: nil,
            buttonName: record.title,
            buttonColor: "orange",
            side: nil, // the unified composer has no Left/Right selection
            mode: .manualIssue,
            paddockId: record.paddockId,
            timestamp: existing?.timestamp ?? Date(),
            createdBy: existing?.createdBy,
            createdByUserId: record.createdBy ?? existing?.createdByUserId,
            isCompleted: record.status == ManualIssueStatus.completed.rawValue,
            photoData: existing?.photoData,
            photoPath: record.photoPath,
            notes: record.description,
            pinRowNumber: record.pinRowNumber.map { Int($0.rounded()) },
            alongRowDistanceM: record.alongRowDistanceM,
            snappedLatitude: record.snappedLatitude,
            snappedLongitude: record.snappedLongitude,
            snappedToRow: record.snappedToRow ?? false,
            locationScope: record.locationScope
        )
        store.applyRemotePinUpsert(pin)
    }

    /// Optimistic marker for an offline-queued custom pin so it renders on
    /// the existing map/list immediately; the canonical row replaces it.
    private func upsertOptimisticPin(from params: CustomPinCreateParams) {
        guard let store, let latitude = params.latitude, let longitude = params.longitude else { return }
        let pin = VinePin(
            id: params.id,
            vineyardId: params.vineyardId,
            latitude: latitude,
            longitude: longitude,
            heading: nil,
            buttonName: params.title,
            buttonColor: "orange",
            side: nil,
            mode: .manualIssue,
            paddockId: params.paddockId,
            timestamp: Date(),
            isCompleted: false,
            notes: params.notes,
            pinRowNumber: params.pinRowNumber.map { Int($0.rounded()) },
            alongRowDistanceM: params.alongRowDistanceM,
            snappedLatitude: params.snappedLatitude,
            snappedLongitude: params.snappedLongitude,
            snappedToRow: params.snappedToRow,
            locationScope: params.locationScope
        )
        store.applyRemotePinUpsert(pin)
    }

    // MARK: - Errors

    /// True when the server rejected the write outright — retrying can never
    /// succeed. PIN_NOT_FOUND is deliberately NOT permanent: it clears once
    /// the parent pin insert lands.
    private func isPermanentRejection(_ error: Error) -> Bool {
        let message = String(describing: error)
        let codes = [
            "NAME_REQUIRED", "TITLE_REQUIRED", "LOCATION_REQUIRED", "SEGMENTS_REQUIRED",
            "SEGMENTS_INVALID", "BLOCK_REQUIRED", "INVALID_SCOPE", "PERMISSION_DENIED",
            "NOT_A_CUSTOM_PIN", "TYPE_VINEYARD_MISMATCH", "TYPE_NOT_FOUND"
        ]
        return codes.contains { message.contains($0) }
    }

    private func friendlyError(_ error: Error) -> String {
        let message = String(describing: error)
        if message.contains("PERMISSION_DENIED") { return "You don't have permission to do that." }
        if message.contains("NAME_REQUIRED") { return "A name is required." }
        if message.contains("TITLE_REQUIRED") { return "A name is required." }
        if message.contains("LOCATION_REQUIRED") { return "A map location is required." }
        if message.contains("SEGMENTS_REQUIRED") { return "Select at least one row." }
        if message.contains("BLOCK_REQUIRED") { return "Select a block." }
        return "The pin couldn't be saved."
    }

    // MARK: - Persistence

    private func loadPersisted() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.outboxKey),
           let ops = try? decoder.decode([CustomPinPendingOp].self, from: data) {
            pendingOps = ops
        }
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? decoder.decode([CustomPinTypeRecord].self, from: data) {
            types = cached
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        // A failed encode must never wipe previously persisted state.
        if let data = try? encoder.encode(pendingOps) {
            UserDefaults.standard.set(data, forKey: Self.outboxKey)
        }
        if let data = try? encoder.encode(types) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func enqueue(_ op: CustomPinPendingOp) {
        pendingOps.append(op)
    }
}

/// One queued offline composer operation. Client-generated ids double as the
/// idempotency keys on replay.
nonisolated struct CustomPinPendingOp: Codable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case typeCreate, pinCreate, segments

        /// A referenced custom type must land before its pin; segments last.
        var replayOrder: Int {
            switch self {
            case .typeCreate: return 0
            case .pinCreate: return 1
            case .segments: return 2
            }
        }
    }

    let id: UUID
    let kind: Kind
    var typeParams: CustomPinTypeCreateParams?
    var pinParams: CustomPinCreateParams?
    var pinId: UUID?
    var segments: [ManualIssueSegment]?
    let queuedAt: Date
    var attempts: Int
    var lastError: String?
}
