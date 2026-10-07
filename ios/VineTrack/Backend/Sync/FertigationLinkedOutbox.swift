import Foundation

/// Persisted dependent write. The irrigation payload and frozen Fertigation draft share one atomic file.
@MainActor
final class FertigationLinkedOutbox {
    nonisolated enum Phase: String, Codable, Sendable { case irrigationPending, fertigationPending, acknowledged, permanentError }
    nonisolated struct Entry: Codable, Sendable, Identifiable {
        let id: UUID
        let ownerId: UUID
        let irrigation: IrrigationPendingSession
        let step: FertigationDomain.ProgramStep
        let products: [FertigationDomain.DraftProduct]
        let notes: String?
        var phase: Phase = .irrigationPending
        var acknowledgedTotals: FertigationDomain.Totals? = nil
        var acknowledgedProducts: [FertigationDomain.Object]? = nil
        var error: String? = nil
        var message: String {
            switch phase {
            case .irrigationPending: "Irrigation and Fertigation saved on this device — waiting to sync."
            case .fertigationPending: "Irrigation recorded — Fertigation still needs to be saved."
            case .acknowledged: "Irrigation and Fertigation recorded."
            case .permanentError: "Irrigation recorded — Fertigation needs attention. \(error ?? "Contact a System Admin, then retry Fertigation.")"
            }
        }
    }
    private let file: URL
    private var isFlushing: Bool = false
    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appending(path: "vinetrack-fertigation-linked-outbox.json")
    }
    func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
    }
    private func persist(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
    func enqueue(_ entry: Entry) throws {
        var all = try entries()
        guard !all.contains(where: { $0.id == entry.id || $0.irrigation.id == entry.irrigation.id }) else { return }
        all.append(entry)
        try persist(all)
    }
    private func replace(_ entry: Entry) throws {
        var all = try entries()
        guard let index = all.firstIndex(where: { $0.id == entry.id }) else { return }
        all[index] = entry
        try persist(all)
    }
    func retry(id: UUID) throws {
        guard var entry = try entries().first(where: { $0.id == id }), entry.phase == .permanentError else { return }
        entry.phase = entry.acknowledgedTotals == nil ? .irrigationPending : .fertigationPending
        entry.error = nil
        try replace(entry)
    }
    /// Only an affirmative matching server identity releases the dependent write.
    func flush(vineyardId: UUID, ownerId: UUID,
               record: (IrrigationPendingSession) async throws -> IrrigationSession,
               upsert: (Entry, [FertigationDomain.Object]) async throws -> FertigationDomain.Application,
               permanent: (Error) -> Bool) async throws {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        for var entry in try entries() where entry.irrigation.vineyardId == vineyardId && entry.ownerId == ownerId && entry.phase != .acknowledged && entry.phase != .permanentError {
            do {
                if entry.phase == .irrigationPending {
                    let saved = try await record(entry.irrigation)
                    guard saved.id == entry.irrigation.id, saved.vineyardId == vineyardId, ["completed", "corrected", "imported", "estimated"].contains(saved.status) else { throw FertigationDomain.Failure.invalidStep }
                    let totals = FertigationDomain.Totals(allocations: saved.blocks.map {
                        .init(areaM2: $0.servicedAreaM2, vines: $0.servicedVineCount.map(Double.init))
                    })
                    entry.acknowledgedTotals = totals
                    entry.phase = .fertigationPending
                    entry.error = nil
                    try replace(entry)
                }
                if entry.acknowledgedProducts == nil {
                    guard let totals = entry.acknowledgedTotals else { throw FertigationDomain.Failure.invalidStep }
                    entry.acknowledgedProducts = try entry.products.map { try $0.payload(totals: totals, step: entry.step) }
                    try replace(entry)
                }
                guard let products = entry.acknowledgedProducts else { throw FertigationDomain.Failure.invalidStep }
                let saved = try await upsert(entry, products)
                guard saved.id == entry.id, saved.sessionId == entry.irrigation.id else { throw FertigationDomain.Failure.invalidStep }
                entry.phase = .acknowledged
                entry.error = nil
                try replace(entry)
            } catch {
                // Persistence failures must escape; never erase or claim an acknowledgement that was not stored.
                entry.error = entry.phase == .irrigationPending ? "Irrigation is waiting to sync. Retry when connected." : "Check vineyard access and the Program Step, then retry Fertigation."
                if entry.phase == .fertigationPending && permanent(error) { entry.phase = .permanentError }
                try replace(entry)
            }
        }
    }
}
