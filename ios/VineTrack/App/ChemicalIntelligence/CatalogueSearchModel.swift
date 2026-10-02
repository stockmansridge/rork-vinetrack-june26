import Foundation
import Observation
import Supabase

/// Durable online discovery: reopening only polls the recorded job identity.
@MainActor @Observable
final class CatalogueSearchModel {
    var query: String = ""
    var matches: [CatalogueWire] = []
    var result: CatalogueWire?
    var job: CatalogueWire?
    var busy: Bool = false
    var searched: Bool = false
    var error: String?
    private(set) var context: CatalogueDiscoveryContext?
    private let repository: any CatalogueBackendProtocol
    private let persistence: PersistenceStore
    private var pollTask: Task<Void, Never>?
    private var requestId: UUID = UUID()
    init(persistence: PersistenceStore = .shared, repository: (any CatalogueBackendProtocol)? = nil) {
        self.persistence = persistence; self.repository = repository ?? CatalogueRepository()
    }
    private func key(_ user: String, _ vineyard: UUID) -> String { "chemical_catalogue_discovery_\(user)_\(vineyard)" }

    func restore(vineyard: UUID) async {
        guard let user = try? await SupabaseClientProvider.shared.client.auth.session.user.id.uuidString else { return }
        restore(vineyard: vineyard, user: user)
    }
    func restore(vineyard: UUID, user: String) {
        if context == nil {
            context = persistence.load(key: key(user, vineyard)); query = context?.query ?? query
            if context == nil { result = persistence.load(key: "chemical_catalogue_result_\(user)_\(vineyard)") }
        }
        if context != nil { poll() }
    }
    func search(country: String) async {
        guard !busy, context == nil else { return }
        let token = UUID(); requestId = token
        busy = true; error = nil; result = nil; searched = false
        defer { if requestId == token { busy = false } }
        do {
            let rows = try await repository.search(query: query, country: country)
            guard requestId == token else { return }
            matches = rows; searched = true
        } catch { self.error = "Catalogue search is unavailable. Try again." }
    }
    func select(_ match: CatalogueWire) async {
        guard context == nil, let id = match.text("revision_id") else { return }
        busy = true; error = nil
        defer { busy = false }
        do { result = try await repository.revision(id) }
        catch { self.error = "Unable to load this result. Try again." }
    }
    func discover(vineyard: UUID, country: String, photo: Data? = nil) async {
        guard !busy else { return }
        if context != nil { poll(); return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let user = try await SupabaseClientProvider.shared.client.auth.session.user.id.uuidString
            let path = try await photo.mapAsync { try await repository.photo($0) }
            let kind = photo == nil ? "text" : "photo"
            let rows = try await repository.rpc("start_chemical_v3_discovery", ["p_query": query.isEmpty ? .null : .string(query), "p_country_code": country.isEmpty ? .null : .string(country), "p_input_kind": .string(kind), "p_photo_path": path.map { .string($0) } ?? .null])
            guard let id = rows.first?.text("job_id") else { throw BackendRepositoryError.emptyResponse }
            let saved = CatalogueDiscoveryContext(jobId: id, userId: user, vineyardId: vineyard, query: query, country: country, inputKind: kind, photoPath: path, startedAt: Date())
            context = saved; try persistence.saveOrThrow(saved, key: key(user, vineyard))
            // A lost invocation acknowledgement must not lose the job or restart it.
            if !rows[0].isTerminal {
                do { try await repository.invoke(id) } catch { self.error = "Discovery is saved. Resume to check progress." }
            }
            poll()
        } catch { self.error = "Unable to start discovery. Check your connection and try again." }
    }
    func poll() {
        guard let context, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pollTask = nil }
            var invokedQueued = false
            for _ in 0..<150 {
                if Task.isCancelled { return }
                do {
                    let current = try await self.repository.job(context.jobId)
                    self.job = current
                    if current.text("status") == "queued", !invokedQueued {
                        invokedQueued = true
                        try await self.repository.invoke(context.jobId)
                    }
                    if current.isTerminal {
                        if current.isSuccess {
                            let exact = try await CatalogueTerminalResolver.result(job: current, fetch: self.repository.revision)
                            // Persist the presented result BEFORE removing the pending context.
                            try self.persistence.saveOrThrow(exact, key: "chemical_catalogue_result_\(context.userId)_\(context.vineyardId)")
                            self.result = exact
                        } else { self.error = "Discovery could not finish. You can search again." }
                        self.persistence.remove(key: self.key(context.userId, context.vineyardId))
                        self.context = nil
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    self.error = "Discovery is saved. Resume when connected to retrieve the result."
                    return
                }
            }
            self.error = "Discovery is still running. Resume to check the same job."
        }
    }
    func add(vineyard: UUID, store: MigratedDataStore) async throws -> SavedChemical {
        guard let result else { throw BackendRepositoryError.emptyResponse }
        busy = true; defer { busy = false }
        let saved = try await repository.add(revisionId: result.id, vineyardId: vineyard)
        store.applyRemoteSavedChemicalUpsert(saved)
        return saved
    }
}

private extension Optional where Wrapped == Data {
    @MainActor func mapAsync(_ transform: (Data) async throws -> String) async rethrows -> String? {
        guard let self else { return nil }; return try await transform(self)
    }
}
