import Foundation
import Observation

/// Screen-local read cache. A single worker serializes RPCs, including scope replacements.
@MainActor @Observable
final class ChemicalInventorySummaryState {
    private(set) var summaries: [UUID: CatalogueWire] = [:]
    private(set) var loading: Bool = false
    private(set) var error: String?
    private var scope: String?
    private var chemicals: [UUID: SavedChemical] = [:]
    private var pending: Set<UUID> = []
    private var revisions: [UUID: Int] = [:]
    private var generation: Int = 0
    private var worker: Task<Void, Never>?
    private let fetch: @MainActor (UUID) async throws -> CatalogueWire?

    init(fetch: @escaping @MainActor (UUID) async throws -> CatalogueWire? = { id in
        try await CatalogueRepository().rpc("chemical_inventory_summary", ["p_saved_chemical_id": .string(id.uuidString)]).first
    }) { self.fetch = fetch }

    func update(scope: String?, chemicals rows: [SavedChemical], force: Set<UUID> = []) {
        if self.scope != scope {
            generation += 1
            self.scope = scope
            chemicals = [:]; summaries = [:]; pending = []; revisions = [:]; error = nil
        }
        let active = scope == nil ? [] : ChemicalStorePresentation.active(rows)
        let incoming = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let changed = Set(incoming.keys.filter { incoming[$0] != chemicals[$0] }).union(force.intersection(incoming.keys))
        chemicals = incoming
        summaries = summaries.filter { incoming[$0.key] != nil && !changed.contains($0.key) }
        pending.formIntersection(incoming.keys)
        for id in changed { revisions[id, default: 0] += 1; pending.insert(id) }
        startWorker()
    }

    func values(for scope: String?) -> [UUID: CatalogueWire] { self.scope == scope ? summaries : [:] }

    func retry() { error = nil; update(scope: scope, chemicals: Array(chemicals.values), force: Set(chemicals.keys)) }

    func waitForRefresh() async { await worker?.value }

    private func startWorker() {
        guard worker == nil, !pending.isEmpty else { return }
        loading = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.loading = false }
            while let id = self.pending.sorted(by: { $0.uuidString < $1.uuidString }).first {
                self.pending.remove(id)
                let generation = self.generation
                let revision = self.revisions[id]
                do {
                    let row = try await self.fetch(id)
                    guard generation == self.generation, revision == self.revisions[id], self.chemicals[id] != nil else { continue }
                    self.summaries[id] = row
                } catch {
                    guard generation == self.generation, revision == self.revisions[id], self.chemicals[id] != nil else { continue }
                    self.error = "Unable to load inventory. Check access and try again."
                }
            }
        }
    }
}
