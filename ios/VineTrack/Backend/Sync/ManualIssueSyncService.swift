import Foundation
import SwiftUI

/// Manual-issue state + offline outbox.
///
/// Writes go through the sql/169 RPCs; when offline (or a transient failure
/// occurs) the operation is queued in a persisted outbox and replayed on the
/// next refresh. Idempotency comes from the client-generated issue id — the
/// create RPC returns the existing row on replay, and update/status carry a
/// `client_updated_at` stamp so a stale replay can never clobber a newer
/// edit (server-side last-write-wins).
///
/// Map markers ride the existing shared pin sync: every manual issue is a
/// `pins` row (mode = ManualIssue), so `PinSyncService.pullRemotePins`
/// delivers it to every existing map surface. This service additionally
/// upserts an optimistic local `VinePin` so an offline-created issue shows
/// on the map immediately; the canonical server row (with any
/// server-adjusted coordinates) replaces it after sync.
@Observable
final class ManualIssueSyncService {

    private let repository: ManualIssueRepository
    weak var store: MigratedDataStore?

    private(set) var issues: [ManualIssueRecord] = []
    private(set) var pendingOps: [ManualIssuePendingOp] = []
    private(set) var isSyncing = false
    var errorMessage: String?
    private(set) var lastRefreshedVineyardId: UUID?

    private static let outboxKey = "vinetrack_manual_issue_outbox"
    private static let cacheKey = "vinetrack_manual_issue_cache"

    init(repository: ManualIssueRepository = ManualIssueRepository()) {
        self.repository = repository
        loadPersisted()
    }

    var pendingCount: Int { pendingOps.count }

    func isPending(_ issueId: UUID) -> Bool {
        pendingOps.contains { $0.issueId == issueId }
    }

    // MARK: - Refresh

    /// Replays the outbox, then pulls the canonical list. `includeFinished`
    /// widens the default open/in-progress filter to all statuses.
    func refresh(vineyardId: UUID, includeFinished: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        lastRefreshedVineyardId = vineyardId
        await replayOutbox()
        do {
            let statuses = includeFinished
                ? ManualIssueStatus.allCases.map(\.rawValue)
                : nil
            let remote = try await repository.list(vineyardId: vineyardId, statuses: statuses)
            mergeRemote(remote, vineyardId: vineyardId, authoritative: includeFinished)
            errorMessage = nil
        } catch {
            // Offline or transient — keep the cached list; the outbox holds
            // any unsynced writes.
            #if DEBUG
            print("[ManualIssueSync] refresh failed: \(error.localizedDescription)")
            #endif
        }
        persist()
    }

    /// Merge a remote page into the local cache. When the page is the full
    /// status set it is authoritative for the vineyard; a default
    /// (active-only) page must not evict cached completed/cancelled records.
    private func mergeRemote(_ remote: [ManualIssueRecord], vineyardId: UUID, authoritative: Bool) {
        let pendingIds = Set(pendingOps.map(\.issueId))
        if authoritative {
            let kept = issues.filter { $0.vineyardId != vineyardId || pendingIds.contains($0.id) }
            let incoming = remote.filter { !pendingIds.contains($0.id) }
            issues = sortIssues(kept + incoming)
        } else {
            var byId = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for record in remote where !pendingIds.contains(record.id) {
                byId[record.id] = record
            }
            // Drop active-cached records the server no longer returns as
            // active (they were completed/cancelled/deleted elsewhere) —
            // unless they're pending locally.
            let remoteIds = Set(remote.map(\.id))
            issues = sortIssues(byId.values.filter { record in
                record.vineyardId != vineyardId
                    || record.statusValue.isActive == false
                    || remoteIds.contains(record.id)
                    || pendingIds.contains(record.id)
            })
        }
        for record in remote { upsertLocalPin(from: record) }
    }

    private func sortIssues(_ records: [ManualIssueRecord]) -> [ManualIssueRecord] {
        records.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    // MARK: - Writes

    /// Create online when possible, otherwise queue and show an optimistic
    /// local record + map marker immediately.
    func create(_ params: ManualIssueCreateParams) async {
        do {
            let record = try await repository.create(params)
            applyCanonical(record)
        } catch where isPermanentRejection(error) {
            errorMessage = friendlyError(error)
        } catch {
            enqueue(ManualIssuePendingOp(
                id: UUID(), issueId: params.id, kind: .create,
                createParams: params, updateParams: nil, status: nil,
                queuedAt: Date(), attempts: 0, lastError: nil
            ))
            applyOptimistic(from: params)
        }
        persist()
    }

    func update(_ params: ManualIssueUpdateParams) async {
        do {
            let record = try await repository.update(params)
            applyCanonical(record)
        } catch where isPermanentRejection(error) {
            errorMessage = friendlyError(error)
        } catch {
            // Coalesce: the latest queued edit for an issue wins.
            pendingOps.removeAll { $0.issueId == params.id && $0.kind == .update }
            enqueue(ManualIssuePendingOp(
                id: UUID(), issueId: params.id, kind: .update,
                createParams: nil, updateParams: params, status: nil,
                queuedAt: Date(), attempts: 0, lastError: nil
            ))
            applyOptimisticUpdate(params)
        }
        persist()
    }

    func setStatus(issueId: UUID, status: ManualIssueStatus) async {
        let stamp = ManualIssueTimestamp.now()
        do {
            let record = try await repository.setStatus(id: issueId, status: status.rawValue, clientUpdatedAt: stamp)
            applyCanonical(record)
        } catch where isPermanentRejection(error) {
            errorMessage = friendlyError(error)
        } catch {
            pendingOps.removeAll { $0.issueId == issueId && $0.kind == .status }
            enqueue(ManualIssuePendingOp(
                id: UUID(), issueId: issueId, kind: .status,
                createParams: nil, updateParams: nil, status: status.rawValue,
                queuedAt: Date(), attempts: 0, lastError: nil
            ))
            applyOptimisticStatus(issueId: issueId, status: status)
        }
        persist()
    }

    /// action "cancel" keeps history; "delete" soft-deletes (managers only).
    func cancelOrDelete(issueId: UUID, action: String) async {
        do {
            let record = try await repository.deleteOrCancel(id: issueId, action: action)
            if action == "delete" {
                issues.removeAll { $0.id == issueId }
                removeLocalPin(issueId)
            } else {
                applyCanonical(record)
            }
        } catch where isPermanentRejection(error) {
            errorMessage = friendlyError(error)
        } catch {
            let kind: ManualIssuePendingOp.Kind = action == "delete" ? .delete : .cancel
            pendingOps.removeAll { $0.issueId == issueId && $0.kind == kind }
            enqueue(ManualIssuePendingOp(
                id: UUID(), issueId: issueId, kind: kind,
                createParams: nil, updateParams: nil, status: nil,
                queuedAt: Date(), attempts: 0, lastError: nil
            ))
            if action == "delete" {
                issues.removeAll { $0.id == issueId }
                removeLocalPin(issueId)
            } else {
                applyOptimisticStatus(issueId: issueId, status: .cancelled)
            }
        }
        persist()
    }

    private func enqueue(_ op: ManualIssuePendingOp) {
        pendingOps.append(op)
    }

    // MARK: - Outbox replay

    /// Replays queued ops in dependency order (creates → updates → status →
    /// cancel/delete). Permanent rejections drop the op with a message;
    /// transient failures stay queued.
    func replayOutbox() async {
        guard !pendingOps.isEmpty else { return }
        let ordered = pendingOps.sorted { $0.kind.replayOrder != $1.kind.replayOrder
            ? $0.kind.replayOrder < $1.kind.replayOrder
            : $0.queuedAt < $1.queuedAt
        }
        for op in ordered {
            do {
                switch op.kind {
                case .create:
                    guard let params = op.createParams else { break }
                    let record = try await repository.create(params)
                    applyCanonical(record)
                case .update:
                    guard let params = op.updateParams else { break }
                    let record = try await repository.update(params)
                    applyCanonical(record)
                case .status:
                    guard let status = op.status else { break }
                    let record = try await repository.setStatus(
                        id: op.issueId, status: status, clientUpdatedAt: ManualIssueTimestamp.now()
                    )
                    applyCanonical(record)
                case .cancel:
                    let record = try await repository.deleteOrCancel(id: op.issueId, action: "cancel")
                    applyCanonical(record)
                case .delete:
                    _ = try await repository.deleteOrCancel(id: op.issueId, action: "delete")
                    issues.removeAll { $0.id == op.issueId }
                    removeLocalPin(op.issueId)
                }
                pendingOps.removeAll { $0.id == op.id }
            } catch where isPermanentRejection(error) {
                // Server refused it outright (permission/validation) — a
                // retry can never succeed, so drop it and surface why.
                pendingOps.removeAll { $0.id == op.id }
                errorMessage = friendlyError(error)
            } catch {
                if let index = pendingOps.firstIndex(where: { $0.id == op.id }) {
                    pendingOps[index].attempts += 1
                    pendingOps[index].lastError = error.localizedDescription
                }
                // Still offline — stop hammering the rest of the queue.
                break
            }
        }
        persist()
    }

    // MARK: - Local application

    private func applyCanonical(_ record: ManualIssueRecord) {
        if let index = issues.firstIndex(where: { $0.id == record.id }) {
            issues[index] = record
        } else {
            issues = sortIssues(issues + [record])
        }
        // Server canonical coordinates replace the optimistic marker.
        upsertLocalPin(from: record)
    }

    private func applyOptimistic(from params: ManualIssueCreateParams) {
        let record = ManualIssueRecord(
            id: params.id, vineyardId: params.vineyardId, paddockId: params.paddockId,
            title: params.title, description: params.description,
            category: params.category, priority: params.priority,
            status: ManualIssueContract.defaultStatus.rawValue,
            locationScope: params.locationScope,
            latitude: params.latitude, longitude: params.longitude,
            snappedLatitude: params.snappedLatitude, snappedLongitude: params.snappedLongitude,
            drivingRowNumber: params.drivingRowNumber, pinRowNumber: params.pinRowNumber,
            pinSide: params.pinSide, alongRowDistanceM: params.alongRowDistanceM,
            snappedToRow: params.snappedToRow,
            assignedUserId: params.assignedUserId, dueDate: params.dueDate,
            linkedWorkTaskId: nil, photoPath: nil, createdBy: nil,
            createdAt: params.clientUpdatedAt, updatedAt: params.clientUpdatedAt,
            clientUpdatedAt: params.clientUpdatedAt, deletedAt: nil,
            completedAt: nil, completedByUserId: nil, completedBy: nil,
            segments: params.locationScope == ManualIssueLocationScope.row.rawValue
                ? ManualIssueContract.canonicalSegments(params.segments ?? [])
                : nil
        )
        applyCanonical(record)
    }

    private func applyOptimisticUpdate(_ params: ManualIssueUpdateParams) {
        guard let index = issues.firstIndex(where: { $0.id == params.id }) else { return }
        let old = issues[index]
        let record = ManualIssueRecord(
            id: old.id, vineyardId: old.vineyardId, paddockId: params.paddockId,
            title: params.title, description: params.description,
            category: params.category, priority: params.priority,
            status: old.status, locationScope: params.locationScope,
            latitude: params.latitude, longitude: params.longitude,
            snappedLatitude: params.snappedLatitude, snappedLongitude: params.snappedLongitude,
            drivingRowNumber: params.drivingRowNumber, pinRowNumber: params.pinRowNumber,
            pinSide: params.pinSide, alongRowDistanceM: params.alongRowDistanceM,
            snappedToRow: params.snappedToRow,
            assignedUserId: params.assignedUserId, dueDate: params.dueDate,
            linkedWorkTaskId: old.linkedWorkTaskId, photoPath: old.photoPath,
            createdBy: old.createdBy, createdAt: old.createdAt,
            updatedAt: params.clientUpdatedAt, clientUpdatedAt: params.clientUpdatedAt,
            deletedAt: old.deletedAt, completedAt: old.completedAt,
            completedByUserId: old.completedByUserId, completedBy: old.completedBy,
            segments: params.locationScope == ManualIssueLocationScope.row.rawValue
                ? ManualIssueContract.canonicalSegments(params.segments ?? [])
                : nil
        )
        applyCanonical(record)
    }

    private func applyOptimisticStatus(issueId: UUID, status: ManualIssueStatus) {
        guard let index = issues.firstIndex(where: { $0.id == issueId }) else { return }
        let old = issues[index]
        let stamp = ManualIssueTimestamp.now()
        let record = ManualIssueRecord(
            id: old.id, vineyardId: old.vineyardId, paddockId: old.paddockId,
            title: old.title, description: old.description,
            category: old.category, priority: old.priority,
            status: status.rawValue, locationScope: old.locationScope,
            latitude: old.latitude, longitude: old.longitude,
            snappedLatitude: old.snappedLatitude, snappedLongitude: old.snappedLongitude,
            drivingRowNumber: old.drivingRowNumber, pinRowNumber: old.pinRowNumber,
            pinSide: old.pinSide, alongRowDistanceM: old.alongRowDistanceM,
            snappedToRow: old.snappedToRow,
            assignedUserId: old.assignedUserId, dueDate: old.dueDate,
            linkedWorkTaskId: old.linkedWorkTaskId, photoPath: old.photoPath,
            createdBy: old.createdBy, createdAt: old.createdAt,
            updatedAt: stamp, clientUpdatedAt: stamp, deletedAt: old.deletedAt,
            completedAt: status == .completed ? stamp : nil,
            completedByUserId: status == .completed ? old.completedByUserId : nil,
            completedBy: status == .completed ? old.completedBy : nil,
            segments: old.segments
        )
        applyCanonical(record)
    }

    // MARK: - Shared pin surfaces

    /// Mirror a record onto the shared map surfaces as a `VinePin` so it
    /// renders on every existing pin map/list immediately. Pull sync later
    /// replaces it with the canonical server row.
    private func upsertLocalPin(from record: ManualIssueRecord) {
        guard let store, let latitude = record.latitude, let longitude = record.longitude else { return }
        guard record.deletedAt == nil else {
            removeLocalPin(record.id)
            return
        }
        let existing = store.pins.first(where: { $0.id == record.id })
        let pin = VinePin(
            id: record.id,
            vineyardId: record.vineyardId,
            latitude: latitude,
            longitude: longitude,
            heading: nil,
            buttonName: record.title,
            buttonColor: "orange",
            side: nil, // manual issues never carry an operator side
            mode: .manualIssue,
            paddockId: record.paddockId,
            timestamp: existing?.timestamp ?? Date(),
            createdBy: existing?.createdBy,
            createdByUserId: record.createdBy ?? existing?.createdByUserId,
            isCompleted: record.status == ManualIssueStatus.completed.rawValue,
            completedBy: record.completedBy,
            completedByUserId: record.completedByUserId,
            photoData: existing?.photoData,
            photoPath: record.photoPath,
            notes: record.description,
            drivingRowNumber: record.drivingRowNumber,
            pinRowNumber: record.pinRowNumber.map { Int($0.rounded()) },
            pinSide: record.pinSide.flatMap { PinSide(rawValue: $0) },
            alongRowDistanceM: record.alongRowDistanceM,
            snappedLatitude: record.snappedLatitude,
            snappedLongitude: record.snappedLongitude,
            snappedToRow: record.snappedToRow ?? false
        )
        store.applyRemotePinUpsert(pin)
    }

    private func removeLocalPin(_ issueId: UUID) {
        guard let store else { return }
        store.pins.removeAll { $0.id == issueId && $0.mode == .manualIssue }
    }

    // MARK: - Errors

    /// True when the server rejected the write outright (validation or
    /// permission) — retrying can never succeed.
    private func isPermanentRejection(_ error: Error) -> Bool {
        let message = String(describing: error)
        let codes = [
            "TITLE_REQUIRED", "LOCATION_REQUIRED", "SEGMENTS_REQUIRED", "SEGMENTS_INVALID",
            "BLOCK_REQUIRED", "INVALID_CATEGORY", "INVALID_PRIORITY", "INVALID_STATUS",
            "INVALID_SCOPE", "INVALID_SIDE", "INVALID_ACTION", "ASSIGNEE_NOT_MEMBER",
            "PERMISSION_DENIED", "NOT_A_MANUAL_ISSUE", "ISSUE_NOT_FOUND"
        ]
        return codes.contains { message.contains($0) }
    }

    private func friendlyError(_ error: Error) -> String {
        let message = String(describing: error)
        if message.contains("PERMISSION_DENIED") { return "You don't have permission to do that." }
        if message.contains("ASSIGNEE_NOT_MEMBER") { return "The assigned user isn't a member of this vineyard." }
        if message.contains("TITLE_REQUIRED") { return "A title is required." }
        if message.contains("LOCATION_REQUIRED") { return "A map location is required." }
        if message.contains("SEGMENTS_REQUIRED") { return "Select at least one row." }
        if message.contains("BLOCK_REQUIRED") { return "Select a block." }
        if message.contains("ISSUE_NOT_FOUND") { return "That issue no longer exists." }
        return "The issue couldn't be saved."
    }

    // MARK: - Persistence

    private func loadPersisted() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.outboxKey),
           let ops = try? decoder.decode([ManualIssuePendingOp].self, from: data) {
            pendingOps = ops
        }
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? decoder.decode([ManualIssueRecord].self, from: data) {
            issues = cached
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        // A failed encode must never wipe previously persisted state.
        if let data = try? encoder.encode(pendingOps) {
            UserDefaults.standard.set(data, forKey: Self.outboxKey)
        }
        if let data = try? encoder.encode(issues) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

/// One queued offline operation. `issueId` is the stable client-generated
/// issue id, which doubles as the idempotency key on replay.
nonisolated struct ManualIssuePendingOp: Codable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case create, update, status, cancel, delete

        /// Creates must land before dependent edits/status changes.
        var replayOrder: Int {
            switch self {
            case .create: return 0
            case .update: return 1
            case .status: return 2
            case .cancel: return 3
            case .delete: return 4
            }
        }
    }

    let id: UUID
    let issueId: UUID
    let kind: Kind
    var createParams: ManualIssueCreateParams?
    var updateParams: ManualIssueUpdateParams?
    var status: String?
    let queuedAt: Date
    var attempts: Int
    var lastError: String?
}
