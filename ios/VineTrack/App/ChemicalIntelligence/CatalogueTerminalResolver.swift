import Foundation

nonisolated enum CatalogueTerminalResolver {
    @MainActor static func result(job: CatalogueWire, fetch: (String) async throws -> CatalogueWire) async throws -> CatalogueWire {
        guard job.isSuccess, let id = job.text("revision_id") else { throw BackendRepositoryError.emptyResponse }
        let exact = try await fetch(id)
        guard exact.id.lowercased() == id.lowercased(),
              job.text("stage") != "catalogue_match" || exact.text("review_status") == "approved" else { throw BackendRepositoryError.emptyResponse }
        return exact
    }
    static func inventoryAllowed(systemAdmin: Bool) -> Bool { systemAdmin }
}
